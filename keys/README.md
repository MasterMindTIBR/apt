# Chave do repositório APT

Este diretório guarda **só a parte pública** da chave que assina o índice:

    keys/mastermind-archive.asc   (ASCII-armored, Ed25519)

Ela é usada pelo `publish.yml` (confere se o secret assina com esta chave e
publica `/mastermind-archive.gpg`) e pelo `release.yml` (vai dentro do pacote
`mastermind-apt-config`). Enquanto o arquivo não existir, esses dois workflows
falham de propósito com uma mensagem clara.

A chave privada **nunca** entra neste repositório. Ela fica no secret
`APT_SIGNING_KEY` do environment `apt-publish` e numa cópia no cofre da
MasterMind. Como gerar e onde guardar: README.md, seção "Configuração no
GitHub".

Chaves de teste (`make test-key`) ficam em `work/test-key/`, que está no
`.gitignore`, e nunca vêm para cá.
