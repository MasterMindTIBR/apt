#!/usr/bin/env bash
# Verificações estáticas do repositório (rodam no CI e em "make lint"):
#   * bash -n / sh -n em todos os scripts e shellcheck (se instalado);
#   * py_compile nos scripts Python;
#   * YAML de workflows, dependabot e sources.yml;
#   * regras do repositório: actions de terceiros fixadas por SHA, nada de
#     ${{ inputs.* }} / ${{ github.event.* }} dentro de run:, mesma imagem
#     debian:13 (digest) em todo lugar, mesmo hash da chave da Proxmox nos
#     scripts, todo pacote aceito coberto pelo depcheck, nenhuma chave
#     privada versionada.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
export LC_ALL=C.UTF-8 # mensagens com acento no shellcheck/python
fail=0
bad() { echo "FALHA: $*" >&2; fail=1; }

bash_scripts=(bootstrap-cluster.sh scripts/*.sh tests/*.sh)
sh_scripts=(mastermind-apt-config/mastermind-apt-channel mastermind-apt-config/postinst
	mastermind-apt-config/postrm scripts/install-build-deps.sh)

for f in "${bash_scripts[@]}"; do
	bash -n "$f" || bad "bash -n $f"
done
for f in "${sh_scripts[@]}"; do
	sh -n "$f" || bad "sh -n $f"
done
echo "sintaxe shell: ok (${#bash_scripts[@]} bash, ${#sh_scripts[@]} sh)"

if command -v shellcheck >/dev/null 2>&1; then
	shellcheck -x "${bash_scripts[@]}" "${sh_scripts[@]}" || bad "shellcheck"
	echo "shellcheck: $(shellcheck --version | sed -n 's/^version: //p')"
else
	echo "AVISO: shellcheck ausente; pulei (o container de build tem)." >&2
fi

python3 -m py_compile scripts/fetch-releases.py scripts/sort-packages.py || bad "py_compile"
rm -rf scripts/__pycache__

python3 - <<'PY' || fail=1
import glob, re, sys, yaml

ok = True
def bad(msg):
    global ok
    ok = False
    print("FALHA: " + msg, file=sys.stderr)

docs = {}
for path in sorted(glob.glob(".github/workflows/*.yml")) + [".github/dependabot.yml", "sources.yml"]:
    try:
        with open(path, encoding="utf-8") as fh:
            docs[path] = yaml.safe_load(fh)
    except Exception as exc:  # noqa: BLE001
        bad("%s: YAML inválido: %s" % (path, exc))
print("yaml: %d arquivo(s) ok" % len(docs))

make = open("Makefile", encoding="utf-8").read()
m = re.search(r"^DEBIAN_IMAGE \?= (\S+)$", make, re.M)
image = m.group(1) if m else None
if not image or not re.match(r"^debian:13@sha256:[0-9a-f]{64}$", image):
    bad("Makefile: DEBIAN_IMAGE precisa ser debian:13@sha256:<digest>")

uses_re = re.compile(r"^[^./][^@]*@[0-9a-f]{40}$")
expr_re = re.compile(r"\$\{\{[^}]*\b(inputs\.|github\.event\.|github\.head_ref)[^}]*\}\}")
for path, doc in docs.items():
    if not path.startswith(".github/workflows/"):
        continue
    if "permissions" not in doc:
        bad("%s: falta 'permissions:' no topo" % path)
    for jid, job in (doc.get("jobs") or {}).items():
        if "permissions" not in job:
            bad("%s: job %s sem 'permissions:'" % (path, jid))
        cont = job.get("container")
        if cont is not None:
            img = cont if isinstance(cont, str) else cont.get("image")
            if img != image:
                bad("%s: job %s usa %s, Makefile usa %s" % (path, jid, img, image))
        if job.get("runs-on") not in (None, "ubuntu-24.04"):
            bad("%s: job %s fora do ubuntu-24.04" % (path, jid))
        for step in job.get("steps") or []:
            use = step.get("uses")
            if use and not use.startswith("./") and not uses_re.match(use):
                bad("%s: %s não está fixada por SHA" % (path, use))
            run = step.get("run")
            if run and expr_re.search(run):
                bad("%s: job %s passa inputs/event direto no run: (use env:)" % (path, jid))

src = docs.get("sources.yml") or {}
accepted = {p for s in src.get("sources", []) for p in s.get("packages", [])}
covered = {p for names in (src.get("depcheck") or {}).values() for p in names}
for p in sorted(accepted - covered):
    bad("sources.yml: %s não está em nenhum perfil do depcheck" % p)
for p in sorted(covered - accepted):
    bad("sources.yml: depcheck cita %s, que não é aceito de nenhuma origem" % p)
if set((src.get("depcheck") or {}).keys()) - {"node", "gateway"}:
    bad("sources.yml: perfis do depcheck aceitos: node, gateway")

hashes = set()
for path in ("bootstrap-cluster.sh", "scripts/check-deps.sh"):
    m = re.search(r"PMX_KEYRING_SHA256=([0-9a-f]{64})", open(path, encoding="utf-8").read())
    hashes.add(m.group(1) if m else None)
if len(hashes) != 1 or None in hashes:
    bad("PMX_KEYRING_SHA256 diferente (ou ausente) em bootstrap-cluster.sh e check-deps.sh")

sys.exit(0 if ok else 1)
PY

# Nenhuma chave privada versionada (nem por engano). O marcador é montado em
# partes para este próprio arquivo não casar com a busca.
private_marker="-----BEGIN PGP PRIVATE"" KEY BLOCK-----"
if git ls-files -z 2>/dev/null | xargs -0 -r grep -l -F -- "$private_marker" 2>/dev/null; then
	bad "chave privada versionada"
fi
if [[ -f keys/mastermind-archive.asc ]] && grep -q 'PRIVATE KEY' keys/mastermind-archive.asc; then
	bad "keys/mastermind-archive.asc contém chave privada"
fi
[[ -f keys/mastermind-archive.asc ]] || echo "AVISO: keys/mastermind-archive.asc ainda não existe (o publish e o release vão falhar até o admin versionar a chave pública)." >&2

if command -v actionlint >/dev/null 2>&1; then
	actionlint || bad "actionlint"
fi

if [[ $fail -ne 0 ]]; then
	echo "lint: FALHOU" >&2
	exit 1
fi
echo "lint: ok"
