#!/usr/bin/env bash
# Gera uma chave Ed25519 DESCARTÁVEL para testar a assinatura localmente.
#
#   scripts/make-test-key.sh [dir]     (padrão: work/test-key)
#
# Saída: <dir>/public.asc e <dir>/private.asc. O diretório work/ está no
# .gitignore. Esta chave nunca vai para keys/, para o CI ou para um .deb
# publicado: a chave real é criada e guardada pelo administrador.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DIR=${1:-$ROOT/work/test-key}
mkdir -p "$DIR"
DIR=$(cd "$DIR" && pwd)
case $DIR in
"$ROOT"/keys | "$ROOT"/keys/*) echo "ERRO: não gere chave de teste dentro de keys/" >&2; exit 1 ;;
esac

GNUPGHOME=$(mktemp -d)
export GNUPGHOME
trap 'gpgconf --kill all >/dev/null 2>&1 || true; rm -rf "$GNUPGHOME"' EXIT
gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
	--quick-generate-key "MasterMind APT TESTE LOCAL (descartavel) <teste@invalid>" ed25519 sign 1d
gpg --batch --armor --export >"$DIR/public.asc"
umask 077
gpg --batch --armor --export-secret-keys >"$DIR/private.asc"
echo "Chave de teste em $DIR (expira em 1 dia; não publique)."
