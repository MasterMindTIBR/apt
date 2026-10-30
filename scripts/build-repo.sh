#!/usr/bin/env bash
# Monta o repositório APT da MasterMind (ainda sem assinatura) em <out>/,
# reconstruindo tudo a partir das GitHub Releases listadas no sources.yml.
#
# Usado igual pelo CI (publish.yml) e localmente (make repo). A assinatura é
# um passo separado (scripts/sign-repo.sh), feito só no job com o secret.
#
# Layout gerado:
#   <out>/debian/{dists,pool}      índice e pacotes (apt-ftparchive)
#   <out>/mastermind-archive.gpg   chave pública (binária), se disponível
#   <out>/index.html               instruções (site/index.html renderizado)
#   <out>/CNAME                    domínio do GitHub Pages
#   <out>/bootstrap-cluster.sh     cópia do script de bootstrap
#   <out>/manifest.json            o que foi publicado e de qual release
#   <out>/content-digest.txt       hash do conteúdo (sem Release/InRelease)
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=public
WORK=work
PUBLIC_KEY=keys/mastermind-archive.asc
REQUIRE_KEY=0
CODENAME=trixie

usage() {
	cat <<EOF
Uso: $(basename "$0") [opções]

  --out DIR          diretório do site (padrão: public)
  --work DIR         diretório de trabalho e cache (padrão: work)
  --public-key ARQ   chave pública ASCII-armored (padrão: keys/mastermind-archive.asc)
  --require-key      falha se a chave pública não existir (modo CI)
  -h, --help         esta ajuda

Variáveis: GITHUB_TOKEN (opcional, só aumenta o limite da API do GitHub).
EOF
}

die() {
	if [[ ${GITHUB_ACTIONS:-} == true ]]; then echo "::error::$*" >&2; else echo "ERRO: $*" >&2; fi
	exit 1
}
note() {
	if [[ ${GITHUB_ACTIONS:-} == true ]]; then echo "::warning::$*"; else echo "AVISO: $*"; fi
}

while [[ $# -gt 0 ]]; do
	case $1 in
	--out) OUT=${2:?}; shift 2 ;;
	--work) WORK=${2:?}; shift 2 ;;
	--public-key) PUBLIC_KEY=${2:?}; shift 2 ;;
	--require-key) REQUIRE_KEY=1; shift ;;
	-h | --help) usage; exit 0 ;;
	*) usage >&2; exit 2 ;;
	esac
done

cd "$ROOT"
for cmd in apt-ftparchive python3 dpkg-deb gpg sha256sum gzip xz; do
	command -v "$cmd" >/dev/null 2>&1 ||
		die "comando ausente: $cmd. Rode pelo Makefile (usa o container debian:13) ou instale com scripts/install-build-deps.sh."
done
case $OUT in "" | / | . | "$ROOT") die "--out inválido: '$OUT'" ;; esac
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd)

# Chave pública: obrigatória no CI, opcional no build local.
if [[ ! -f $PUBLIC_KEY ]]; then
	if [[ $REQUIRE_KEY == 1 ]]; then
		die "chave pública ausente: $PUBLIC_KEY. O administrador precisa versionar a parte pública da chave de assinatura (ASCII-armored) nesse caminho antes de publicar. Veja README.md, seção 'Configuração no GitHub'."
	fi
	note "chave pública $PUBLIC_KEY ausente: o site sai sem mastermind-archive.gpg (build de teste)."
	PUBLIC_KEY=""
fi

GNUPGHOME=$(mktemp -d)
export GNUPGHOME
trap 'rm -rf "$GNUPGHOME"' EXIT

# 1. Releases -> work/incoming, plan.tsv, manifest.json
python3 scripts/fetch-releases.py --sources sources.yml --work "$WORK"

# 2. Pool e índice (do zero a cada execução).
#    O reprepro do Debian 13 (5.3.x) guarda só uma versão por pacote em cada
#    componente; o apt-ftparchive indexa todas as versões que estão no pool.
rm -rf "$OUT"
mkdir -p "$OUT/debian"
count=0
while IFS=$'\t' read -r component package file; do
	[[ -n $component ]] || continue
	case $package in lib?*) prefix=${package:0:4} ;; *) prefix=${package:0:1} ;; esac
	dest="$OUT/debian/pool/$component/$prefix/$package"
	mkdir -p "$dest"
	cp "$file" "$dest/"
	count=$((count + 1))
done <"$WORK/plan.tsv"

for component in stable testing; do
	bindir="$OUT/debian/dists/$CODENAME/$component/binary-amd64"
	mkdir -p "$bindir" "$OUT/debian/pool/$component"
	# Caminhos do Filename relativos à raiz do repositório (debian/).
	(cd "$OUT/debian" && apt-ftparchive --arch amd64 packages "pool/$component") |
		python3 scripts/sort-packages.py >"$bindir/Packages"
	gzip -9nc "$bindir/Packages" >"$bindir/Packages.gz"
	xz -9c "$bindir/Packages" >"$bindir/Packages.xz"
	echo "$component: $(grep -c '^Package:' "$bindir/Packages" || true) pacote(s) no índice"
done
(cd "$OUT/debian/dists/$CODENAME" &&
	apt-ftparchive -c "$ROOT/archive/apt-ftparchive.conf" release . >"$WORK/Release.tmp")
mv "$WORK/Release.tmp" "$OUT/debian/dists/$CODENAME/Release"
echo "índice: $count arquivo(s) no pool."

# 3. Site
cp site/CNAME "$OUT/CNAME"
cp bootstrap-cluster.sh "$OUT/bootstrap-cluster.sh"
cp "$WORK/manifest.json" "$OUT/manifest.json"

fingerprint="(chave pública ainda não configurada: build de teste, sem assinatura)"
if [[ -n $PUBLIC_KEY ]]; then
	gpg --batch --quiet --dearmor <"$PUBLIC_KEY" >"$OUT/mastermind-archive.gpg"
	fpr=$(gpg --batch --quiet --show-keys --with-colons "$OUT/mastermind-archive.gpg" |
		awk -F: '$1 == "fpr" && !n++ { print $10 }')
	[[ $fpr =~ ^[0-9A-F]{40}$ ]] || die "não consegui ler a impressão digital de $PUBLIC_KEY"
	fingerprint=$(sed -E 's/(.{4})/\1 /g; s/ $//' <<<"$fpr")
fi

python3 - "$ROOT/site/index.html" "$WORK/packages.html" "$fingerprint" >"$OUT/index.html" <<'PY'
import html, sys
page, table, fpr = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(page, encoding="utf-8").read()
text = text.replace("@FINGERPRINT@", html.escape(fpr))
text = text.replace("<!-- @PACKAGES@ -->", open(table, encoding="utf-8").read())
sys.stdout.write(text)
PY

# 4. Hash do conteúdo, sem os arquivos que mudam a cada export/assinatura
#    (Release tem a data; .gz/.xz podem ter timestamp no cabeçalho).
(
	cd "$OUT"
	find . -type f \
		! -path "./debian/dists/$CODENAME/Release" \
		! -path "./debian/dists/$CODENAME/InRelease" \
		! -path "./debian/dists/$CODENAME/Release.gpg" \
		! -name '*.gz' ! -name '*.xz' ! -name content-digest.txt -print0 |
		LC_ALL=C sort -z | xargs -0 sha256sum
) | sha256sum | cut -d' ' -f1 >"$OUT/content-digest.txt"

echo
echo "Repositório montado em $OUT/ (sem assinatura)."
echo "  Release: $OUT/debian/dists/$CODENAME/Release"
echo "  digest:  $(cat "$OUT/content-digest.txt")"
echo "Próximo passo: scripts/sign-repo.sh (CI) ou teste com [trusted=yes] (local)."
