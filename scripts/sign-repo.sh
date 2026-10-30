#!/usr/bin/env bash
# Assina o índice montado por build-repo.sh: gera InRelease e Release.gpg
# (SHA-512) e confere as assinaturas com sqv, o mesmo verificador do apt do
# Debian 13.
#
# A chave privada vem da variável APT_SIGNING_KEY (ASCII-armored; no CI é o
# secret do environment apt-publish) ou de --key-file (teste local com chave
# descartável). Ela só existe num GNUPGHOME temporário, apagado no fim, e
# nunca é impressa.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=public
PUBLIC_KEY=keys/mastermind-archive.asc
KEY_FILE=""
CODENAME=trixie

usage() {
	cat <<EOF
Uso: $(basename "$0") [--out DIR] [--public-key ARQ] [--key-file ARQ]

  --out DIR         site montado por build-repo.sh (padrão: public)
  --public-key ARQ  chave pública versionada (padrão: keys/mastermind-archive.asc)
  --key-file ARQ    chave privada ASCII-armored (só para teste local).
                    Sem esta opção, a chave vem de APT_SIGNING_KEY.
EOF
}

die() {
	if [[ ${GITHUB_ACTIONS:-} == true ]]; then echo "::error::$*" >&2; else echo "ERRO: $*" >&2; fi
	exit 1
}

while [[ $# -gt 0 ]]; do
	case $1 in
	--out) OUT=${2:?}; shift 2 ;;
	--public-key) PUBLIC_KEY=${2:?}; shift 2 ;;
	--key-file) KEY_FILE=${2:?}; shift 2 ;;
	-h | --help) usage; exit 0 ;;
	*) usage >&2; exit 2 ;;
	esac
done

cd "$ROOT"
dists="$OUT/debian/dists/$CODENAME"
[[ -f $dists/Release ]] || die "$dists/Release não existe. Rode build-repo.sh antes."
[[ -f $PUBLIC_KEY ]] ||
	die "chave pública ausente: $PUBLIC_KEY. O administrador precisa versionar a parte pública da chave (ASCII-armored) antes de publicar."
if [[ -z $KEY_FILE && -z ${APT_SIGNING_KEY:-} ]]; then
	die "chave privada ausente: defina o secret APT_SIGNING_KEY no environment apt-publish (ou use --key-file para teste local)."
fi
command -v gpg >/dev/null 2>&1 || die "gpg ausente"

GNUPGHOME=$(mktemp -d)
export GNUPGHOME
chmod 700 "$GNUPGHOME"
tmp=$(mktemp -d)
trap 'gpgconf --kill all >/dev/null 2>&1 || true; rm -rf "$GNUPGHOME" "$tmp"' EXIT

# Chave pública: impressão digital e algoritmo.
gpg --batch --quiet --dearmor <"$PUBLIC_KEY" >"$tmp/public.gpg"
pubinfo=$(gpg --batch --quiet --show-keys --with-colons "$tmp/public.gpg")
fpr=$(awk -F: '$1 == "fpr" { print $10; exit }' <<<"$pubinfo")
algo=$(awk -F: '$1 == "pub" { print $4; exit }' <<<"$pubinfo")
[[ $fpr =~ ^[0-9A-F]{40}$ ]] || die "não consegui ler a impressão digital de $PUBLIC_KEY"
if [[ $algo != 22 ]]; then
	echo "AVISO: a chave primária não é Ed25519 (algoritmo OpenPGP $algo)." >&2
fi

# Chave privada (stdin ou arquivo; nunca em linha de comando nem no log).
if [[ -n $KEY_FILE ]]; then
	gpg --batch --quiet --import <"$KEY_FILE" 2>/dev/null || die "falha ao importar $KEY_FILE"
else
	printf '%s\n' "$APT_SIGNING_KEY" | gpg --batch --quiet --import 2>/dev/null ||
		die "falha ao importar APT_SIGNING_KEY (precisa ser a chave privada ASCII-armored, sem senha)"
fi
gpg --batch --list-secret-keys --with-colons | awk -F: '$1 == "fpr" { print $10 }' | grep -qx "$fpr" ||
	die "a chave privada não corresponde a $PUBLIC_KEY (impressão digital $fpr)."

sign() { gpg --batch --yes --quiet --pinentry-mode error --digest-algo SHA512 --local-user "$fpr" "$@"; }
rm -f "$dists/InRelease" "$dists/Release.gpg"
sign --clearsign --output "$dists/InRelease" "$dists/Release"
sign --armor --detach-sign --output "$dists/Release.gpg" "$dists/Release"

# A chave publicada no site tem que ser a mesma que assinou.
cp "$tmp/public.gpg" "$OUT/mastermind-archive.gpg"

# Verificação com a política do apt do Debian 13 (Sequoia).
if command -v sqv >/dev/null 2>&1; then
	sqv --keyring "$OUT/mastermind-archive.gpg" --signature-file "$dists/Release.gpg" "$dists/Release" >/dev/null ||
		die "sqv rejeitou Release.gpg"
	sqv --keyring "$OUT/mastermind-archive.gpg" --cleartext --output "$tmp/inrelease.txt" "$dists/InRelease" >/dev/null ||
		die "sqv rejeitou InRelease"
	# O texto assinado perde só o \n final (é parte do delimitador da assinatura).
	[[ "$(<"$tmp/inrelease.txt")" == "$(<"$dists/Release")" ]] || die "conteúdo do InRelease difere do Release"
	echo "Assinatura conferida com sqv (política do apt do Debian 13)."
elif [[ ${GITHUB_ACTIONS:-} == true ]]; then
	die "sqv ausente no CI"
else
	gpgv --keyring "$OUT/mastermind-archive.gpg" "$dists/InRelease" 2>/dev/null || die "gpgv rejeitou InRelease"
	echo "AVISO: sqv ausente; conferido só com gpgv." >&2
fi

echo "Assinado com $fpr."
