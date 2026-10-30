# AGENTS.md: regras para agentes neste repositório

Repositório **público** (`MasterMindTIBR/apt`) que monta o APT da MasterMind
em `https://apt.mastermindti.cloud/debian`. Leia o `README.md` antes de mudar
qualquer coisa.

## Nunca

- Versionar segredo: chave privada, token, senha. A única chave aqui é a
  **pública** `keys/mastermind-archive.asc`. A privada vive só no secret
  `APT_SIGNING_KEY` (environment `apt-publish`) e no cofre da MasterMind.
- Gerar ou trocar a chave real de assinatura. Para teste use `make test-key`
  (vai para `work/test-key/`, no `.gitignore`) e nunca publique nada assinado
  ou empacotado com ela.
- Colocar dado de cliente em qualquer lugar (código, fixture, issue, PR, log,
  captura): nome, IP, VLAN, hostname, domínio. Testes usam dados sintéticos.
- Fazer push, criar/editar/promover release, mexer em secrets, environments,
  Pages ou settings do GitHub sem pedido explícito do Jung.
- Promover para `stable` sem aprovação do Jung e sem teste no lab.
- Fazer outro repositório escrever o índice. Este é o único que publica; os
  repositórios de código só publicam GitHub Releases.

## Contrato das releases (não mudar sem combinar com os repositórios de origem)

- Contam só tags `<componente>/<versão>` (e `v<semver>` onde o `sources.yml`
  permitir). O resto é ignorado.
- Assets: `<pacote>_<versão>_<arch>.deb` + `SHA256SUMS`. Hash divergente ou a
  mesma versão com conteúdo diferente = run falha, nada é publicado.
- A versão real é o campo `Version` de dentro do `.deb` (idem `Package` e
  `Architecture`); nunca derivar do nome do arquivo ou da tag.
- Pre-release = `testing`; release = `stable`. Release promovida não se edita:
  correção é versão nova.
- Por canal ficam as últimas `keep_versions` (5) versões de cada pacote.

## Como o código está organizado

- `scripts/fetch-releases.py`: releases -> `work/` (aplica o contrato).
- `scripts/build-repo.sh`: pool + índice (`apt-ftparchive`) + site em `public/`.
  O `reprepro` do Debian 13 não guarda várias versões; não volte para ele.
- `scripts/check-deps.sh`: gate de dependências por canal; stable quebrado
  bloqueia a publicação e abre issue.
- `scripts/sign-repo.sh`: assinatura SHA-512, conferida com `sqv`.
- `scripts/build-deb.sh`: pacote `mastermind-apt-config` (dpkg-deb, sem debconf).
- `bootstrap-cluster.sh`: roda nos nodes do cliente. Scripts remotos vão pelo
  stdin de `bash -s` (nada é expandido localmente); argumentos remotos são
  validados contra `^[A-Za-z0-9._/+~:=-]+$`. Mantenha idempotente e com
  `--check`/`--dry-run` realmente sem alteração.

## Regras de workflow

- Actions de terceiros fixadas por SHA de commit (com o tag em comentário).
- `permissions: {}` no topo e o mínimo por job.
- `${{ inputs.* }}` e `${{ github.event.* }}` só via `env:`, nunca dentro de `run:`.
- Build e verificação em `debian:13@sha256:...`, o mesmo digest do `Makefile`.
- O `make lint` (e o `ci.yml`) confere tudo isso; rode antes de entregar.

## Verificação mínima antes de entregar

```sh
make lint
make repo && make depcheck
make test-bootstrap      # se mexeu no bootstrap ou no mastermind-apt-config
```

Commits seguem a regra do repositório da organização; o coordenador revisa e
faz o commit.
