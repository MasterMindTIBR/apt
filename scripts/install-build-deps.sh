#!/bin/sh
# Ferramentas de build do repositório APT (Debian 13). Usado pelo CI dentro do
# container debian:13 e por scripts/in-container.sh para montar a imagem local.
#   install-build-deps.sh          instala (root)
#   install-build-deps.sh --list   só imprime a lista
set -eu

PKGS="apt-utils ca-certificates curl debian-archive-keyring git gnupg gpgv jq python3 python3-yaml shellcheck sqv xz-utils"

if [ "${1:-}" = "--list" ]; then
	echo "$PKGS"
	exit 0
fi
[ "$(id -u)" = 0 ] || { echo "ERRO: precisa de root" >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
# shellcheck disable=SC2086 # lista separada por espaço, de propósito
apt-get install -y -q --no-install-recommends $PKGS
