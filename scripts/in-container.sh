#!/usr/bin/env bash
# Roda um comando dentro do container debian:13 fixado por digest (o mesmo do
# CI), com as ferramentas de build instaladas. O repositório é montado no
# mesmo caminho do host, e os arquivos gerados voltam para o seu usuário.
#
#   scripts/in-container.sh scripts/build-repo.sh --out public
#
# A imagem (DEBIAN_IMAGE) vem do Makefile. GITHUB_TOKEN, GH_TOKEN e
# APT_SIGNING_KEY, se definidos, são repassados pelo nome (o valor não
# aparece na linha de comando).
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
IMAGE=${DEBIAN_IMAGE:-$(sed -n 's/^DEBIAN_IMAGE ?= *//p' "$ROOT/Makefile")}
[[ $IMAGE == debian:13@sha256:* ]] || { echo "ERRO: DEBIAN_IMAGE inválida: '$IMAGE'" >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "ERRO: docker ausente (ou rode com NATIVE=1 num Debian 13)" >&2; exit 1; }
[[ $# -gt 0 ]] || { echo "Uso: $0 <comando> [args...]" >&2; exit 2; }

pkgs=$("$ROOT/scripts/install-build-deps.sh" --list)
tag="mastermind-apt-build:$(printf '%s|%s' "$IMAGE" "$pkgs" | sha256sum | cut -c1-12)"
if ! docker image inspect "$tag" >/dev/null 2>&1; then
	echo "Montando imagem local $tag a partir de $IMAGE..." >&2
	docker build -q -t "$tag" - >/dev/null <<DOCKERFILE
FROM $IMAGE
RUN apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends $pkgs && rm -rf /var/lib/apt/lists/*
DOCKERFILE
fi

env_args=(-e "HOST_UID=$(id -u)" -e "HOST_GID=$(id -g)" -e "ROOT_DIR=$ROOT")
for v in GITHUB_TOKEN GH_TOKEN APT_SIGNING_KEY; do
	if [[ -n ${!v:-} ]]; then env_args+=(-e "$v"); fi
done
tty=()
if [[ -t 0 && -t 1 ]]; then tty=(-t); fi

# shellcheck disable=SC2016 # expandido dentro do container
exec docker run --rm -i "${tty[@]}" -v "$ROOT:$ROOT" -w "$ROOT" "${env_args[@]}" "$tag" \
	bash -c 'rc=0; "$@" || rc=$?
		for d in public work dist; do
			if [ -e "$ROOT_DIR/$d" ]; then chown -R "$HOST_UID:$HOST_GID" "$ROOT_DIR/$d"; fi
		done
		exit "$rc"' in-container "$@"
