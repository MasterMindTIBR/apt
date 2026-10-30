# Repositório APT da MasterMind TI

Repositório APT público em **https://apt.mastermindti.cloud/debian**
(distribuição `trixie`, componentes `stable` e `testing`), servido pelo
GitHub Pages deste repositório e montado a partir das GitHub Releases dos
projetos de código.

Este repositório contém:

- `publish.yml` e os scripts que montam, verificam, assinam e publicam o índice;
- o pacote `mastermind-apt-config` (chave, `.sources`, canal e pin);
- `bootstrap-cluster.sh`, que configura um cluster Proxmox VE inteiro (ou o
  gateway de restore) e instala o `mm-pve-tools`.

Nenhum pacote leva segredo nem configuração de cliente. O repositório é
público: nada de nome de cliente, IP, VLAN ou hostname em código, issue, PR,
log ou captura.

## Estrutura

```
.github/workflows/
  publish.yml        monta, verifica, assina e publica (único que escreve o índice)
  release.yml        tag mastermind-apt-config/<versão> -> pre-release + publish
  promote.yml        pre-release -> release (stable), com aprovação
  ci.yml             lint em PR/push
  keepalive.yml      impede o GitHub de desligar o schedule do publish
archive/apt-ftparchive.conf   campos do Release (Origin/Label MasterMind)
bootstrap-cluster.sh          instalação em todos os nodes (ou no gateway)
keys/                         só a chave PÚBLICA (mastermind-archive.asc)
mastermind-apt-config/        fontes do pacote de configuração
scripts/                      build-repo, sign-repo, check-deps, build-deb, lint...
site/                         index.html (instruções) e CNAME
sources.yml                   repositórios de origem e pacotes aceitos
tests/bootstrap-e2e.sh        teste ponta a ponta do bootstrap (container)
```

## Como a sincronização funciona

- Os repositórios de código (`MasterMindTIBR/mm-pve-tools`,
  `junglivre/pve-file-restore-ntfs3g` e este, para o `mastermind-apt-config`)
  **nunca escrevem aqui**. Eles só publicam GitHub Releases com os `.deb` e o
  `SHA256SUMS`.
- Este repositório é o **único** que monta e publica o índice. A cada execução
  do `publish.yml` tudo é reconstruído do zero a partir das releases, então o
  índice não tem como divergir do que foi lançado.
- Gatilhos do `publish.yml`:
  - `repository_dispatch` tipo `release-published`: enviado pelo `release.yml`
    e pelo `promote.yml` do `mm-pve-tools` (token do GitHub App), e a release
    aparece no APT em poucos minutos;
  - `schedule` de hora em hora (minuto 17): pega o ntfs3g, que não avisa, e
    qualquer dispatch perdido;
  - `workflow_dispatch`: manual (opção `force` publica mesmo sem mudança). O
    `release.yml` e o `promote.yml` deste repositório disparam o publish por
    aqui.
- `concurrency: apt-publish`: uma publicação por vez.

O que cada execução faz:

1. `scripts/fetch-releases.py` lista as releases de cada origem do
   `sources.yml` pela API pública (sem credencial; no CI o `GITHUB_TOKEN` só
   aumenta o limite da API), baixa os `.deb` e o `SHA256SUMS`, confere os
   hashes e aceita só os pacotes listados para aquela origem;
2. `scripts/build-repo.sh` monta o pool e o índice com `apt-ftparchive`
   (guardando as últimas `keep_versions` = 5 versões de cada pacote por canal)
   e o site (`index.html`, `CNAME`, `mastermind-archive.gpg`,
   `bootstrap-cluster.sh`, `manifest.json`);
3. `scripts/check-deps.sh` simula a instalação de cada pacote de cada canal num
   Debian 13 com só este repositório + Debian trixie + Proxmox
   (`pve-no-subscription` para o perfil node, `pbs-client` para o gateway). Se
   o **stable** quebrar, o run falha, **nada é publicado** e uma issue é aberta
   (uma só por título). Problema no `testing` vira só aviso;
4. `scripts/sign-repo.sh` assina (`InRelease` e `Release.gpg`, SHA-512) no job
   com o environment `apt-publish` e confere com `sqv`, o verificador do apt do
   Debian 13;
5. se o conteúdo mudou (`content-digest.txt` diferente do publicado), envia com
   `actions/upload-pages-artifact` e publica com `actions/deploy-pages` (sem
   branch `gh-pages`).

Por que `apt-ftparchive` e não `reprepro`: o `reprepro` do Debian 13
(`5.4.6+really5.3.2`) guarda uma versão só de cada pacote por componente (o
Debian reverteu o suporte a várias versões). O `apt-ftparchive` indexa todas
as versões que estão no pool, e o número de versões é controlado pelo
`keep_versions` do `sources.yml`.

## Contrato das releases

Vale para todo repositório de origem:

- só contam tags `<componente>/<versão>` (ex.: `file-restore/4.2.8-1+ntfs3g1`)
  e, onde o `sources.yml` permitir (`tags: [component, semver]`, hoje só o
  `mm-pve-tools`), `v<semver>`. Outras tags são ignoradas (ex.: a antiga
  `v1.0.0-pve9.2.11` do ntfs3g);
- a release tem os `.deb` e um `SHA256SUMS`; `.deb` fora do `SHA256SUMS` é
  ignorado, e hash divergente faz o run falhar sem publicar nada;
- o nome do asset deve ser `<pacote>_<versão>_<arch>.deb`, mas **o que vale é
  o que está dentro do `.deb`** (`Package`, `Version`, `Architecture`); o nome
  do arquivo e a tag nunca são usados como versão;
- pre-release = `testing`; release = `stable`; rascunho é ignorado;
- uma release promovida nunca é editada: correção vira versão nova. A mesma
  versão de um pacote com conteúdo diferente em duas releases faz o run falhar.

## Canais

| Canal | O que entra | Quem usa |
|---|---|---|
| `stable` | releases (promovidas) | clientes |
| `testing` | pre-releases | lab (`Components: stable testing`) |

Promover é tirar o pre-release, sempre com aprovação do Jung e depois do teste
no lab. No node, o canal fica em `/etc/mastermind-apt/channel` e muda com
`mastermind-apt-channel <stable|testing>` (seguido de `apt update`).

## Instalação nos nodes (bootstrap)

Como root, em qualquer node do cluster:

```sh
curl -fsSLO https://apt.mastermindti.cloud/bootstrap-cluster.sh
bash bootstrap-cluster.sh --check              # só leitura: node -> config -> canal -> mm-pve-tools
bash bootstrap-cluster.sh --dry-run            # mostra o plano, não muda nada
bash bootstrap-cluster.sh                      # canal stable
bash bootstrap-cluster.sh --channel testing    # lab
```

Em cada node online (descobertos com `pvesh get /cluster/status`), por
`ssh -o BatchMode=yes root@<node>`: instala o `mastermind-apt-config` da
release mais recente do canal (SHA256 conferido com o `SHA256SUMS` da release
antes e depois da cópia), ajusta o canal, roda `apt-get update`,
`apt-get install -y mm-pve-tools` (o ntfs3g vem pela dependência) e
`mm-pve status`. É idempotente: rodar de novo não muda o que já está certo.
Nodes offline são listados e ignorados. Com `--channel testing`, o
`mastermind-apt-config` instalado é o mais novo entre pre-releases e releases
(o canal testing enxerga os dois).

Gateway de restore (VM Debian 13), a partir de um node:

```sh
bash bootstrap-cluster.sh --gateway <ip-ou-nome>
```

Instala o `mastermind-apt-config`, a chave da Proxmox (a do próprio node, ou a
oficial conferida por hash), o repositório `pbs-client` da Proxmox e o
`mm-gw-restore`. Recusa host que não seja Debian 13 ou que seja um node do PVE.

Depois do bootstrap, tudo é `apt full-upgrade`.

Instalação manual de um host: ver https://apt.mastermindti.cloud/.

## Voltar aos pacotes oficiais da Proxmox

```sh
apt purge mm-pve-tools pve-file-restore-ntfs3g   # o meta precisa sair antes
apt purge mastermind-apt-config                  # remove .sources, chave e pin
apt update
apt-cache policy proxmox-backup-file-restore proxmox-backup-restore-image
apt install --allow-downgrades \
  proxmox-backup-file-restore=<versão-oficial> \
  proxmox-backup-restore-image=<versão-oficial>
```

Sem o pin, um `apt upgrade` também troca pelo oficial assim que a Proxmox
publicar uma versão maior que a nossa.

## Cloudflare

O registro `apt.mastermindti.cloud` deve ficar **DNS only** até o GitHub
emitir o certificado. Se depois o proxy for ligado:

- **não** cachear `/debian/dists/*` (bypass ou TTL de 1 minuto): um `InRelease`
  velho em cache com pacotes novos já publicados gera "Hash Sum mismatch" nos
  nodes. O mesmo vale para `/content-digest.txt` (o publish compara com ele);
- `/debian/pool/*` pode ser cacheado à vontade (arquivo com versão no nome nunca muda).

## Adicionar um repositório de origem

1. O repositório precisa ser **público** e seguir o contrato acima.
2. Acrescente no `sources.yml`:
   ```yaml
   - repo: Dono/projeto
     packages: [pacote-a, pacote-b]
     # tags: [component, semver]   # só se usar tags vX.Y.Z
   ```
   e coloque cada pacote em pelo menos um perfil do `depcheck` (`node` e/ou
   `gateway`). O `make lint` confere isso.
3. `make repo && make depcheck` localmente.
4. Para aparecer no APT em minutos (e não só na próxima hora), o
   `release.yml`/`promote.yml` do projeto envia
   `POST /repos/MasterMindTIBR/apt/dispatches` com
   `{"event_type": "release-published"}` usando um token do GitHub App (abaixo).

## Release do `mastermind-apt-config`

1. Ajuste `mastermind-apt-config/VERSION` e a seção `## [<versão>]` do
   `CHANGELOG.md`; merge na `main`.
2. `git tag mastermind-apt-config/<versão> && git push origin mastermind-apt-config/<versão>`.
3. O `release.yml` monta o `.deb` no `debian:13`, confere tag = `VERSION` =
   `Version` do `.deb`, cria a **pre-release** com exatamente
   `mastermind-apt-config_<versão>_all.deb` e `SHA256SUMS`, e dispara o
   publish (canal `testing`).
4. Depois do teste no lab: Actions → promote → tag
   `mastermind-apt-config/<versão>`. Pede a aprovação do environment
   `production`, tira o pre-release e dispara o publish (canal `stable`).

Os dois disparam o publish com `workflow_dispatch` na `main`, e não com
`workflow_call`: uma release criada com o `GITHUB_TOKEN` não dispara outros
workflows (o `workflow_dispatch` é exceção), e um workflow chamado a partir da
tag herdaria a ref da tag, que os environments restritos à `main` recusam.

## Desenvolvimento local

Tudo roda no mesmo container `debian:13` (digest fixado) do CI; precisa de
docker. Num Debian 13 com as ferramentas (`scripts/install-build-deps.sh`),
use `NATIVE=1`.

```sh
make repo          # public/ a partir das releases atuais, sem assinatura
make depcheck      # dependências dos dois canais (relatórios em work/)
make lint          # bash -n, shellcheck, YAML, regras dos workflows
make check         # lint + depcheck
make deb           # dist/mastermind-apt-config_<versão>_all.deb (exige keys/mastermind-archive.asc)
make serve         # http://localhost:8080 para testar com apt ([trusted=yes] se sem assinatura)

# Assinatura e pacote com uma chave DESCARTÁVEL (work/test-key, no .gitignore):
make test-key
make repo SIGNING_KEY_FILE=work/test-key/private.asc PUBLIC_KEY_FILE=work/test-key/public.asc
make deb PUBLIC_KEY_FILE=work/test-key/public.asc     # NUNCA publique esse .deb
make test-bootstrap                                   # bootstrap ponta a ponta em container
```

`GITHUB_TOKEN` no ambiente (opcional) é repassado ao container só para subir
o limite da API do GitHub (60 consultas por hora sem token).

## Configuração no GitHub (administrador)

Nada disso é feito pelos workflows; precisa ser configurado uma vez.

1. **Chave de assinatura** (Ed25519, sem senha; o apt do Debian 13 verifica com
   Sequoia e rejeita SHA-1 e chaves fracas). Numa máquina confiável:
   ```sh
   export GNUPGHOME=$(mktemp -d)
   gpg --batch --pinentry-mode loopback --passphrase '' \
     --quick-generate-key "MasterMind TI APT <EMAIL>" ed25519 sign never
   gpg --armor --export > keys/mastermind-archive.asc          # versionar
   gpg --armor --export-secret-keys > /caminho/do/cofre.asc     # NUNCA no repo
   gh secret set APT_SIGNING_KEY --env apt-publish --repo MasterMindTIBR/apt < /caminho/do/cofre.asc
   gpgconf --kill all; rm -rf "$GNUPGHOME"
   ```
   Guarde também um certificado de revogação no cofre. Trocar a chave exige
   publicar antes um `mastermind-apt-config` com as duas chaves.
2. **Pages**: Settings → Pages → Source: **GitHub Actions**; custom domain
   `apt.mastermindti.cloud`; **Enforce HTTPS**. DNS: `CNAME apt` →
   `mastermindtibr.github.io` (DNS only na Cloudflare até o certificado sair).
3. **Domínio verificado** na organização (Organization settings → Pages →
   Add a domain, registro TXT), para ninguém assumir o subdomínio se o Pages
   for desativado.
4. **Environments**:
   - `github-pages` (criado pelo Pages): deployment branches só `main`;
   - `apt-publish`: deployment branches só `main`; secret `APT_SIGNING_KEY`;
     sem revisor (o publish roda de hora em hora);
   - `production`: revisor obrigatório **Jung**; deployment branches só `main`.
5. **Tags**: ruleset para `mastermind-apt-config/*` restringindo quem cria
   tag (uma tag gera release).
6. **Actions**: Settings → Actions → Workflow permissions **read**; PRs de fork
   exigem aprovação para rodar workflows.
7. **GitHub App** (ex.: `mastermind-apt-bot`), só para o `repository_dispatch`:
   permissão **Contents: write** (repository) e instalado **só** no
   `MasterMindTIBR/apt`. No `mm-pve-tools`, o `App ID` e a chave privada do app
   ficam como secrets do job de dispatch (ex.: `actions/create-github-app-token`
   com `repositories: apt`). Esse é o único uso do app: as releases de origem
   são lidas sem token.
8. **Agendamento**: o GitHub desliga workflows agendados após 60 dias sem
   atividade no repositório. O `keepalive.yml` reativa o `publish.yml` todo mês
   pela API; se mesmo assim parar, reative em Actions → publish.

## Segurança

- Actions de terceiros fixadas por SHA (Dependabot atualiza); `permissions:`
  mínimas por job; inputs vão para o shell só por `env:`.
- O secret de assinatura só existe no job `sign` (environment `apt-publish`).
  A coleta das releases e a verificação de dependências rodam no job `build`,
  sem secret; o `sign` só recebe o índice já montado.
- O `sign-repo.sh` recusa assinar se a chave privada não corresponder a
  `keys/mastermind-archive.asc` e confere o resultado com `sqv`.
