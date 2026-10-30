# Repositório APT da MasterMind: atalhos de build local.
#
# Por padrão tudo roda no mesmo container debian:13 do CI (precisa de
# docker). Num Debian 13 com as ferramentas instaladas, use NATIVE=1.
#
#   make repo        monta public/ a partir das releases atuais (sem assinatura)
#   make repo SIGNING_KEY_FILE=work/test-key/private.asc PUBLIC_KEY_FILE=work/test-key/public.asc
#                    idem, assinado com uma chave descartável (make test-key)
#   make deb         monta dist/mastermind-apt-config_<versão>_all.deb
#   make check       lint + verificação de dependências dos dois canais
#   make test-bootstrap  teste ponta a ponta do bootstrap-cluster.sh (container)
#   make serve       serve public/ em http://localhost:8080 (teste com apt)

# Imagem fixada por digest. A mesma string aparece nos workflows; o lint
# confere que estão iguais. Para atualizar:
#   curl -s https://hub.docker.com/v2/repositories/library/debian/tags/13 | jq -r .digest
DEBIAN_IMAGE ?= debian:13@sha256:2dc419c6d7fe3dad0a2f9fd469c34cc90b0f9ba642d8fde837fe3d7d34a0e7f1

PUBLIC_KEY_FILE ?= keys/mastermind-archive.asc
SIGNING_KEY_FILE ?=
NATIVE ?= 0

ifeq ($(NATIVE),1)
RUN :=
else
RUN := DEBIAN_IMAGE=$(DEBIAN_IMAGE) scripts/in-container.sh
endif

.PHONY: help repo deb lint depcheck check test-key test-bootstrap serve clean

help:
	@sed -n '3,14p' Makefile | sed 's/^# \{0,1\}//'

repo:
	$(RUN) scripts/build-repo.sh --out public --public-key $(PUBLIC_KEY_FILE)
ifneq ($(strip $(SIGNING_KEY_FILE)),)
	$(RUN) scripts/sign-repo.sh --out public --public-key $(PUBLIC_KEY_FILE) --key-file $(SIGNING_KEY_FILE)
else
	@echo "AVISO: repositório sem assinatura (teste local com [trusted=yes])."
endif

deb:
	$(RUN) scripts/build-deb.sh --out dist --public-key $(PUBLIC_KEY_FILE)

lint:
	$(RUN) scripts/lint.sh

public/manifest.json:
	$(MAKE) repo

depcheck: public/manifest.json
	$(RUN) scripts/check-deps.sh --repo public --channel stable --report work/depcheck-stable.md
	$(RUN) scripts/check-deps.sh --repo public --channel testing --report work/depcheck-testing.md

check: lint depcheck

test-key:
	scripts/make-test-key.sh work/test-key

# Usa só a chave descartável (work/test-key). O dist/ gerado aqui NÃO é publicável.
test-bootstrap:
	test -f work/test-key/private.asc || scripts/make-test-key.sh work/test-key
	$(MAKE) repo SIGNING_KEY_FILE=work/test-key/private.asc PUBLIC_KEY_FILE=work/test-key/public.asc
	$(MAKE) deb PUBLIC_KEY_FILE=work/test-key/public.asc
	scripts/in-container.sh tests/bootstrap-e2e.sh

serve: public/manifest.json
	cd public && python3 -m http.server 8080

clean:
	rm -rf public work dist
