# Changelog

Versões do pacote `mastermind-apt-config` (tag `mastermind-apt-config/<versão>`).
O `release.yml` usa a seção `## [<versão>]` como notas da release, e a versão
precisa ser igual à de `mastermind-apt-config/VERSION`.

Mudanças no repositório APT em si (workflows, scripts) não geram versão.

## [Unreleased]

## [1.0.0] - ainda não lançada

### Adicionado

- Chave pública do repositório em `/usr/share/keyrings/mastermind-archive.gpg`.
- `/etc/apt/sources.list.d/mastermind.sources` (deb822), gerado a partir do
  canal em `/etc/mastermind-apt/channel` (conffile, padrão `stable`).
- `mastermind-apt-channel <stable|testing>` para trocar o canal sem editar
  arquivos; `testing` usa `Components: stable testing`.
- Pin 990 (`/etc/apt/preferences.d/mastermind`) para
  `proxmox-backup-file-restore` e `proxmox-backup-restore-image` vindos de
  `o=MasterMind`.
