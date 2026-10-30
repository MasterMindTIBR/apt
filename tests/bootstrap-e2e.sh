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
# localhost (via ssh de verdade) e nodeC (offline). Roda --check, --dry-run,
# a instalação, uma segunda execução (idempotência) e o --gateway.
set -euo pipefail
cd "$ROOT_DIR"
[ -f /.dockerenv ] || { echo "ERRO: rode só em container (make test-bootstrap)" >&2; exit 1; }
for f in public/debian/dists/trixie/InRelease work/test-key/public.asc work/test-key/private.asc dist/SHA256SUMS; do
	[ -f "$f" ] || { echo "ERRO: falta $f (use make test-bootstrap)" >&2; exit 1; }
done
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq --no-install-recommends openssh-server openssh-client perl openssl >/dev/null

# 1. Cópia do repositório + mm-pve-tools falso (sem dependências, com mm-pve)
R=/srv/repo; rm -rf "$R"; cp -a public "$R"
P=$(mktemp -d); mkdir -p "$P/DEBIAN" "$P/usr/sbin"
printf '#!/bin/sh\necho "mm-pve status: ok (pacote falso de teste)"\n' > "$P/usr/sbin/mm-pve"; chmod 755 "$P/usr/sbin/mm-pve"
printf 'Package: mm-pve-tools\nVersion: 0.0.1\nArchitecture: all\nMaintainer: teste <teste@invalid>\nDescription: falso\n' > "$P/DEBIAN/control"
mkdir -p "$R/debian/pool/testing/m/mm-pve-tools"
dpkg-deb --root-owner-group --build "$P" "$R/debian/pool/testing/m/mm-pve-tools/mm-pve-tools_0.0.1_all.deb" >/dev/null
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

# 3. sshd + chave root para "localhost"
mkdir -p /run/sshd /root/.ssh && ssh-keygen -A >/dev/null && /usr/sbin/sshd
ssh-keygen -q -t ed25519 -N '' -f /root/.ssh/id_ed25519 && cat /root/.ssh/id_ed25519.pub >> /root/.ssh/authorized_keys
ssh-keyscan -q localhost >> /root/.ssh/known_hosts 2>/dev/null

# 4. pvesh falso: nodeA (local), localhost (via ssh), nodeC (offline)
cat > /usr/local/bin/pvesh <<'J'
#!/bin/sh
echo '[{"type":"cluster","name":"lab","quorate":1},{"type":"node","name":"nodeA","online":1,"local":1},{"type":"node","name":"localhost","online":1,"local":0},{"type":"node","name":"nodeC","online":0,"local":0}]'
J
chmod 755 /usr/local/bin/pvesh

B=./bootstrap-cluster.sh
debs=(dist/mastermind-apt-config_*_all.deb)
DEB=${debs[0]}
echo; echo "############ --check (antes)"; $B --check
echo; echo "############ --dry-run --channel testing"; $B --dry-run --channel testing --deb "$DEB"
echo; echo "############ instalação --channel testing"; $B --channel testing --deb "$DEB" || echo "exit=$?"
echo; echo "############ segunda execução (idempotente)"; { $B --channel testing --deb "$DEB" || true; } 2>&1 | grep -E '^\s+\[|^==|^Pronto|ERRO|AVISO|^NODE|^node|^localhost'
echo; echo "############ --gateway localhost (sem mm-gw-restore publicado: deve falhar com mensagem clara)"
rc=0; $B --gateway localhost --channel testing --deb "$DEB" || rc=$?; echo "exit=$rc"
cat /etc/apt/sources.list.d/proxmox-pbs-client.sources
echo; echo "############ argumentos inválidos"
$B --channel prod 2>&1 | tail -1 || true
$B --gateway 'x;rm -rf /' 2>&1 | tail -1 || true
