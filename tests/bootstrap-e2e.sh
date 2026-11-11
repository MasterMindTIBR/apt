#!/usr/bin/env bash
# Teste ponta a ponta do bootstrap-cluster.sh, num container descartável.
# Rode com "make test-bootstrap" (que prepara os pré-requisitos):
#   * public/ assinado com a chave descartável de work/test-key;
#   * dist/ com o mastermind-apt-config montado com a mesma chave.
#
# Dentro do container (como root): copia public/ e acrescenta um mm-pve-tools
# FALSO (sem dependências, só um /usr/sbin/mm-pve), serve tudo por HTTPS como
# se fosse apt.mastermindti.cloud (certificado autoassinado + /etc/hosts, só
# no container), sobe um sshd e um pvesh falso com 3 nodes: nodeA (local),
# nodeB (via ssh de verdade) e nodeC (offline). Como num PVE 9, o nome nodeB não
# resolve e a chave dele só está em /etc/pve/nodes/nodeB/ssh_known_hosts: o
# bootstrap tem que chegar nele pelo IP do /cluster/status, como o PVE faz.
# Roda --check, --dry-run, a instalação, uma segunda execução (idempotência) e
# o --gateway.
set -euo pipefail
cd "$ROOT_DIR"
[ -f /.dockerenv ] || { echo "ERRO: rode só em container (make test-bootstrap)" >&2; exit 1; }
for f in public/debian/dists/trixie/InRelease work/test-key/public.asc work/test-key/private.asc dist/SHA256SUMS; do
	[ -f "$f" ] || { echo "ERRO: falta $f (use make test-bootstrap)" >&2; exit 1; }
done
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq --no-install-recommends openssh-server openssh-client perl openssl >/dev/null

# 1. Cópia do repositório + mm-pve-tools falso (sem dependências, com mm-pve).
#    A versão fica acima de qualquer release real, senão o apt escolhe a real
#    (que exige pve-manager) e a instalação no container não tem como passar.
R=/srv/repo; rm -rf "$R"; cp -a public "$R"
P=$(mktemp -d); mkdir -p "$P/DEBIAN" "$P/usr/sbin"
printf '#!/bin/sh\necho "mm-pve status: ok (pacote falso de teste)"\n' > "$P/usr/sbin/mm-pve"; chmod 755 "$P/usr/sbin/mm-pve"
printf 'Package: mm-pve-tools\nVersion: 999.0.0\nArchitecture: all\nMaintainer: teste <teste@invalid>\nDescription: falso\n' > "$P/DEBIAN/control"
mkdir -p "$R/debian/pool/testing/m/mm-pve-tools"
dpkg-deb --root-owner-group --build "$P" "$R/debian/pool/testing/m/mm-pve-tools/mm-pve-tools_999.0.0_all.deb" >/dev/null
d="$R/debian/dists/trixie"
(cd "$R/debian" && apt-ftparchive --arch amd64 packages pool/testing) > "$d/testing/binary-amd64/Packages"
gzip -9nc "$d/testing/binary-amd64/Packages" > "$d/testing/binary-amd64/Packages.gz"
xz -9c "$d/testing/binary-amd64/Packages" > "$d/testing/binary-amd64/Packages.xz"
(cd "$d" && apt-ftparchive -c "$ROOT_DIR/archive/apt-ftparchive.conf" release . > /tmp/Release) && mv /tmp/Release "$d/Release"
scripts/sign-repo.sh --out "$R" --public-key work/test-key/public.asc --key-file work/test-key/private.asc | tail -1

# 2. HTTPS local fingindo ser apt.mastermindti.cloud (só dentro deste container)
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 -subj "/CN=apt.mastermindti.cloud" \
  -addext "subjectAltName=DNS:apt.mastermindti.cloud" -keyout /tmp/tls.key -out /usr/local/share/ca-certificates/teste.crt 2>/dev/null
update-ca-certificates >/dev/null 2>&1
echo "127.0.0.1 apt.mastermindti.cloud" >> /etc/hosts
python3 - <<'PY' &
import http.server, ssl, functools
class H(http.server.SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
h = functools.partial(H, directory="/srv/repo")
s = http.server.ThreadingHTTPServer(("127.0.0.1", 443), h)
c = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); c.load_cert_chain("/usr/local/share/ca-certificates/teste.crt", "/tmp/tls.key")
s.socket = c.wrap_socket(s.socket, server_side=True); s.serve_forever()
PY
sleep 1

# 3. sshd + chave root. O gateway (localhost) usa o known_hosts comum; o nodeB,
# como num PVE 9, só tem a chave no known_hosts do cluster, pelo nome do node.
mkdir -p /run/sshd /root/.ssh && ssh-keygen -A >/dev/null && /usr/sbin/sshd
ssh-keygen -q -t ed25519 -N '' -f /root/.ssh/id_ed25519 && cat /root/.ssh/id_ed25519.pub >> /root/.ssh/authorized_keys
ssh-keyscan -q localhost >> /root/.ssh/known_hosts 2>/dev/null
mkdir -p /etc/pve/nodes/nodeB
ssh-keyscan -q 127.0.0.1 2>/dev/null | sed 's/^127\.0\.0\.1 /nodeB /' > /etc/pve/nodes/nodeB/ssh_known_hosts

# 4. pvesh falso: nodeA (local), nodeB (via ssh pelo IP), nodeC (offline)
cat > /usr/local/bin/pvesh <<'J'
#!/bin/sh
echo '[{"type":"cluster","name":"lab","quorate":1},{"type":"node","name":"nodeA","online":1,"local":1,"ip":"127.0.0.1"},{"type":"node","name":"nodeB","online":1,"local":0,"ip":"127.0.0.1"},{"type":"node","name":"nodeC","online":0,"local":0,"ip":"127.0.0.2"}]'
J
chmod 755 /usr/local/bin/pvesh

# 5. Outro repositório quebrado, como o enterprise da Proxmox num node sem
#    assinatura: responde 401. O bootstrap tem que avisar e instalar mesmo assim.
python3 - <<'PY' &
import http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(401); self.send_header("Content-Length", "0"); self.end_headers()
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("127.0.0.1", 8081), H).serve_forever()
PY
echo "127.0.0.1 repo-quebrado.invalid" >> /etc/hosts
printf 'Types: deb\nURIs: http://repo-quebrado.invalid:8081/debian\nSuites: trixie\nComponents: main\n' \
	> /etc/apt/sources.list.d/quebrado.sources
sleep 1

# Controle: o ssh comum pelo nome falha aqui, como num cluster PVE 9.
if ssh -o BatchMode=yes -o ConnectTimeout=5 root@nodeB true 2>/dev/null; then
	echo "ERRO: ssh comum para nodeB não devia funcionar neste teste" >&2; exit 1
fi

B=./bootstrap-cluster.sh
debs=(dist/mastermind-apt-config_*_all.deb)
DEB=${debs[0]}
echo; echo "############ --check (antes)"; $B --check | tee /tmp/check-antes.txt
grep -q '^nodeB ' /tmp/check-antes.txt || { echo "ERRO: nodeB fora do --check" >&2; exit 1; }
if grep -q 'sem acesso' /tmp/check-antes.txt; then echo "ERRO: node sem acesso via ssh no --check" >&2; exit 1; fi
echo; echo "############ --dry-run --channel testing"; $B --dry-run --channel testing --deb "$DEB"
echo; echo "############ instalação --channel testing (com um repositório 401)"
$B --channel testing --deb "$DEB" 2>&1 | tee /tmp/install.txt
grep -q 'AVISO: apt-get update falhou só em outro' /tmp/install.txt \
	|| { echo "ERRO: o repositório 401 não gerou o aviso esperado" >&2; exit 1; }
grep -q 'corrija ou desligue: http://repo-quebrado.invalid:8081/debian' /tmp/install.txt \
	|| { echo "ERRO: o aviso não nomeou o repositório quebrado" >&2; exit 1; }
for n in nodeA nodeB; do
	if ! grep -Eq "^$n .* 999\.0\.0$" /tmp/install.txt; then
		echo "ERRO: $n sem mm-pve-tools 999.0.0 depois da instalação" >&2; exit 1
	fi
done
echo; echo "############ segunda execução (idempotente)"; { $B --channel testing --deb "$DEB" || true; } 2>&1 | grep -E '^\s+\[|^==|^Pronto|ERRO|AVISO|^NODE|^node|^localhost'
echo; echo "############ --gateway localhost (ssh comum, fora do cluster)"
rc=0; $B --gateway localhost --channel testing --deb "$DEB" || rc=$?; echo "exit=$rc"
cat /etc/apt/sources.list.d/proxmox-pbs-client.sources
echo; echo "############ argumentos inválidos"
$B --channel prod 2>&1 | tail -1 || true
$B --gateway 'x;rm -rf /' 2>&1 | tail -1 || true
