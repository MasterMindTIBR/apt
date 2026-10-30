#!/usr/bin/env bash
# Monta o pacote mastermind-apt-config (Architecture: all) com dpkg-deb.
#
#   scripts/build-deb.sh [--out dist] [--public-key keys/mastermind-archive.asc]
#                        [--version X.Y.Z]
#
# Saída: <out>/mastermind-apt-config_<versão>_all.deb e <out>/SHA256SUMS
# (exatamente os dois assets de uma release, conforme o contrato).
#
# A versão vem de mastermind-apt-config/VERSION. Com --version (usado pelo
# release.yml com a versão da tag), as duas precisam ser iguais.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SRC="$ROOT/mastermind-apt-config"
OUT=dist
PUBLIC_KEY=keys/mastermind-archive.asc
WANT_VERSION=""
PACKAGE=mastermind-apt-config
# TODO(admin): confirmar o endereço de contato do mantenedor.
MAINTAINER="MasterMind TI <apt@mastermindti.cloud>"

die() {
	if [[ ${GITHUB_ACTIONS:-} == true ]]; then echo "::error::$*" >&2; else echo "ERRO: $*" >&2; fi
	exit 1
}

while [[ $# -gt 0 ]]; do
	case $1 in
	--out) OUT=${2:?}; shift 2 ;;
	--public-key) PUBLIC_KEY=${2:?}; shift 2 ;;
	--version) WANT_VERSION=${2:?}; shift 2 ;;
	-h | --help) sed -n '2,12p' "$0"; exit 0 ;;
	*) die "opção desconhecida: $1" ;;
	esac
done

cd "$ROOT"
for cmd in dpkg-deb gpg md5sum sha256sum; do
	command -v "$cmd" >/dev/null 2>&1 || die "comando ausente: $cmd (rode pelo Makefile, que usa o container debian:13)"
done

VERSION=$(tr -d '[:space:]' <"$SRC/VERSION")
[[ $VERSION =~ ^[0-9][A-Za-z0-9.+~]*(-[A-Za-z0-9.+~]+)?$ ]] || die "versão inválida em VERSION: '$VERSION'"
if [[ -n $WANT_VERSION && $WANT_VERSION != "$VERSION" ]]; then
	die "a tag pede a versão $WANT_VERSION, mas mastermind-apt-config/VERSION diz $VERSION"
fi

if [[ ! -f $PUBLIC_KEY ]]; then
	die "chave pública ausente: $PUBLIC_KEY. O pacote leva essa chave em /usr/share/keyrings/mastermind-archive.gpg. Para teste local use PUBLIC_KEY_FILE=<chave descartável> (e nunca publique esse .deb)."
fi
if [[ $(realpath "$PUBLIC_KEY") != "$ROOT/keys/mastermind-archive.asc" ]]; then
	echo "AVISO: montando com a chave $PUBLIC_KEY, não com keys/mastermind-archive.asc. Só para teste local: NÃO publique este .deb." >&2
fi

GNUPGHOME=$(mktemp -d)
export GNUPGHOME
stage=$(mktemp -d)
trap 'rm -rf "$GNUPGHOME" "$stage"' EXIT
pkgroot="$stage/$PACKAGE"

# Reprodutível: datas fixas a partir do último commit (ou 0 fora do git).
SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git -c safe.directory="$ROOT" -C "$ROOT" log -1 --format=%ct 2>/dev/null || echo 0)}
export SOURCE_DATE_EPOCH

install -d -m0755 "$pkgroot/DEBIAN"
install -D -m0644 "$SRC/channel" "$pkgroot/etc/mastermind-apt/channel"
install -D -m0644 "$SRC/mastermind.pref" "$pkgroot/etc/apt/preferences.d/mastermind"
install -D -m0755 "$SRC/mastermind-apt-channel" "$pkgroot/usr/sbin/mastermind-apt-channel"
install -D -m0644 "$SRC/copyright" "$pkgroot/usr/share/doc/$PACKAGE/copyright"
install -d -m0755 "$pkgroot/usr/share/keyrings"
gpg --batch --quiet --dearmor <"$PUBLIC_KEY" >"$pkgroot/usr/share/keyrings/mastermind-archive.gpg"
chmod 0644 "$pkgroot/usr/share/keyrings/mastermind-archive.gpg"
gpg --batch --show-keys "$pkgroot/usr/share/keyrings/mastermind-archive.gpg" >/dev/null 2>&1 ||
	die "$PUBLIC_KEY não é uma chave OpenPGP válida"

install -m0755 "$SRC/postinst" "$SRC/postrm" "$pkgroot/DEBIAN/"
printf '%s\n' /etc/apt/preferences.d/mastermind /etc/mastermind-apt/channel >"$pkgroot/DEBIAN/conffiles"

size=$(du -sk --exclude=DEBIAN "$pkgroot" | cut -f1)
sed -e "s|@VERSION@|$VERSION|" -e "s|@MAINTAINER@|$MAINTAINER|" -e "s|@INSTALLED_SIZE@|$size|" \
	"$SRC/control.in" >"$pkgroot/DEBIAN/control"
(cd "$pkgroot" && find . -path ./DEBIAN -prune -o -type f -printf '%P\0' | LC_ALL=C sort -z |
	xargs -0 md5sum) >"$pkgroot/DEBIAN/md5sums"
find "$pkgroot" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +

mkdir -p "$OUT"
deb="$OUT/${PACKAGE}_${VERSION}_all.deb"
rm -f "$deb" "$OUT/SHA256SUMS"
dpkg-deb --root-owner-group -Zxz --build "$pkgroot" "$deb" >/dev/null

# Confere o que saiu: nome do arquivo = Package_Version_Architecture.
# shellcheck disable=SC2016 # formato do dpkg-deb, não expansão do shell
read -r f_pkg f_ver f_arch < <(dpkg-deb --show --showformat='${Package} ${Version} ${Architecture}\n' "$deb")
[[ "${f_pkg}_${f_ver}_${f_arch}.deb" == "$(basename "$deb")" ]] || die "nome do .deb não bate com os campos de controle"
(cd "$OUT" && sha256sum "$(basename "$deb")" >SHA256SUMS)

echo "Gerado: $deb"
cat "$OUT/SHA256SUMS"
