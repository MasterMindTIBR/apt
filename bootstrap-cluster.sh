#!/usr/bin/env bash
# bootstrap-cluster.sh: configura o repositório APT da MasterMind e instala o
# mm-pve-tools em todos os nodes online de um cluster Proxmox VE 9, ou o
# mm-gw-restore num gateway Debian 13 (--gateway).
#
# Rode como root em qualquer node do cluster:
#   bash bootstrap-cluster.sh --check            # só leitura: tabela de versões
#   bash bootstrap-cluster.sh --dry-run          # mostra o plano, não muda nada
#   bash bootstrap-cluster.sh                    # canal stable
#   bash bootstrap-cluster.sh --channel testing  # lab
#   bash bootstrap-cluster.sh --gateway <host>   # gateway de restore (Debian 13)
#
# O que faz em cada node (SSH root entre os nodes, como o próprio PVE usa):
#   1. baixa (uma vez, neste node) o mastermind-apt-config da GitHub Release
#      mais recente do canal e confere o SHA256 com o SHA256SUMS da release;
#   2. copia para o node, confere o SHA256 de novo e instala, se precisar;
#   3. ajusta o canal (mastermind-apt-channel), apt-get update e
#      apt-get install -y mm-pve-tools (o ntfs3g vem pela dependência);
#   4. roda "mm-pve status", se existir.
# Idempotente: rodar de novo não muda nada que já esteja certo.
set -euo pipefail

readonly REPO_SLUG=MasterMindTIBR/apt
readonly RELEASES_API="https://api.github.com/repos/$REPO_SLUG/releases?per_page=100"
readonly CONFIG_PKG=mastermind-apt-config
readonly SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5)
# Chave da Proxmox para trixie (mesmo hash da documentação do PVE 9). Usada só
# no --gateway, quando este node não tiver a chave instalada pelo pacote.
readonly PMX_KEYRING=/usr/share/keyrings/proxmox-archive-keyring.gpg
readonly PMX_KEYRING_URL=https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg
readonly PMX_KEYRING_SHA256=136673be77aba35dcce385b28737689ad64fd785a797e57897589aed08db6e45

MODE=install # install | check | dry-run
CHANNEL=stable
GATEWAY=""
DEB_FILE=""
LOCAL_NODE=""
WORKDIR=""

usage() {
	cat <<'EOF'
Uso: bootstrap-cluster.sh [opções]

  --check             só leitura: node -> mastermind-apt-config -> canal -> mm-pve-tools
  --dry-run           mostra o que seria feito, sem nenhuma alteração nos nodes
  --channel CANAL     stable (padrão) ou testing (lab: inclui pre-releases)
  --gateway HOST      em vez dos nodes do cluster, prepara o gateway de restore
                      (Debian 13): mastermind-apt-config, repositório pbs-client
                      da Proxmox e mm-gw-restore
  --deb ARQUIVO       usa um mastermind-apt-config local em vez da release
                      (precisa de um SHA256SUMS no mesmo diretório)
  -h, --help          esta ajuda
EOF
}

log() { printf '%s\n' "$*"; }
warn() { printf 'AVISO: %s\n' "$*" >&2; }
die() {
	printf 'ERRO: %s\n' "$*" >&2
	exit 1
}

# --------------------------------------------------------------------------
# Scripts executados nos nodes. Vão pelo stdin de "bash -s", então nada aqui
# é expandido localmente nem passa por aspas do ssh (ex.: '${Version}' chega
# literal ao dpkg-query do node). Argumentos vão como $1..$n.
# --------------------------------------------------------------------------

# Saída: cfg|canal|mm-pve-tools|mm-gw-restore|codename|pve(yes/no)|pbs-client(yes/no)
read -r -d '' REMOTE_STATUS <<'REMOTE' || true
set -u
installed() {
	# dpkg-query sai com 1 se o pacote não existe: não pode derrubar o set -e.
	{ dpkg-query -W -f='${db:Status-Abbrev}|${Version}\n' "$1" 2>/dev/null || true; } |
		awk -F'|' '$1 ~ /^ii/ { print $2 }'
}
cfg=$(installed mastermind-apt-config)
tools=$(installed mm-pve-tools)
gw=$(installed mm-gw-restore)
channel=""
if [ -r /etc/mastermind-apt/channel ]; then
	channel=$(sed -e 's/#.*//' -e 's/[[:space:]]//g' /etc/mastermind-apt/channel | awk 'NF && !n++')
fi
codename=$(. /etc/os-release 2>/dev/null && printf '%s' "${VERSION_CODENAME:-}")
pve=no
if command -v pveversion >/dev/null 2>&1; then pve=yes; fi
pbs=no
if [ -f /etc/apt/sources.list.d/proxmox-pbs-client.sources ]; then pbs=yes; fi
printf '%s|%s|%s|%s|%s|%s|%s\n' "${cfg:--}" "${channel:--}" "${tools:--}" "${gw:--}" \
	"${codename:-?}" "$pve" "$pbs"
REMOTE

read -r -d '' REMOTE_MKTEMP <<'REMOTE' || true
set -eu
d=$(mktemp -d /tmp/mastermind-bootstrap.XXXXXX)
chmod 0755 "$d"
printf '%s\n' "$d"
REMOTE

# Args: tmpdir deb_name deb_sha256 versão_cfg canal papel(node|gateway)
# O corpo fica dentro de main(): o bash lê a função inteira do stdin antes de
# executar, e main roda com stdin em /dev/null, então nenhum comando (apt,
# dpkg, mm-pve) consome o resto do script.
read -r -d '' REMOTE_INSTALL <<'REMOTE' || true
set -euo pipefail
main() {
tmp=$1 deb_name=$2 deb_sha=$3 want=$4 channel=$5 role=$6
case $tmp in
/tmp/mastermind-bootstrap.*) ;;
*) echo "diretório temporário inesperado: $tmp" >&2; exit 1 ;;
esac
trap 'rm -rf "$tmp"' EXIT
export DEBIAN_FRONTEND=noninteractive
host=$(uname -n)
say() { printf '  [%s] %s\n' "$host" "$*"; }
apt_get() {
	apt-get -y -q -o Dpkg::Use-Pty=0 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}
installed() {
	# dpkg-query sai com 1 se o pacote não existe: não pode derrubar o set -e.
	{ dpkg-query -W -f='${db:Status-Abbrev}|${Version}\n' "$1" 2>/dev/null || true; } |
		awk -F'|' '$1 ~ /^ii/ { print $2 }'
}

# 1. mastermind-apt-config
printf '%s  %s\n' "$deb_sha" "$tmp/$deb_name" | sha256sum -c --quiet - ||
	{ say "ERRO: SHA256 do $deb_name não confere depois da cópia"; exit 1; }
have=$(installed mastermind-apt-config)
if [ -z "$have" ] || dpkg --compare-versions "$have" lt "$want"; then
	say "instalando mastermind-apt-config $want (antes: ${have:-nenhum})"
	dpkg --force-confdef --force-confold -i "$tmp/$deb_name" >/dev/null
else
	say "mastermind-apt-config $have já instalado"
fi

# 2. canal (o helper só grava se mudar)
mastermind-apt-channel "$channel" | sed "s/^/  [$host] /"

# 3. gateway: repositório pbs-client da Proxmox
if [ "$role" = gateway ]; then
	key=/usr/share/keyrings/proxmox-archive-keyring.gpg
	if ! cmp -s "$tmp/proxmox-archive-keyring.gpg" "$key"; then
		install -D -m0644 "$tmp/proxmox-archive-keyring.gpg" "$key"
		say "chave da Proxmox instalada em $key"
	fi
	src=/etc/apt/sources.list.d/proxmox-pbs-client.sources
	other=$(grep -rlsF download.proxmox.com/debian/pbs-client /etc/apt/sources.list /etc/apt/sources.list.d/ | grep -vxF "$src" || true)
	if [ -n "$other" ]; then
		say "pbs-client já configurado em: $other (mantido)"
		src=""
	fi
	want_src="Types: deb
URIs: http://download.proxmox.com/debian/pbs-client
Suites: trixie
Components: main
Signed-By: $key"
	if [ -n "$src" ] && { [ ! -f "$src" ] || [ "$(cat "$src")" != "$want_src" ]; }; then
		printf '%s\n' "$want_src" >"$src.tmp"
		chmod 0644 "$src.tmp"
		mv -f "$src.tmp" "$src"
		say "repositório pbs-client configurado em $src"
	fi
	target=mm-gw-restore
else
	target=mm-pve-tools
fi

# 4. apt
say "apt-get update"
apt-get -q update >/dev/null 2>"$tmp/update.err" || { cat "$tmp/update.err" >&2; say "ERRO: apt-get update falhou"; exit 1; }
if grep -q '^[WE]:' "$tmp/update.err"; then
	sed "s/^/  [$host] /" "$tmp/update.err" >&2
fi
cand=$(apt-cache policy "$target" | awk '/Candidate:/ && !c { print $2; c = 1 }')
if [ -z "$cand" ] || [ "$cand" = "(none)" ]; then
	say "ERRO: $target não está disponível no canal $channel (ainda não há release nele?)"
	exit 3
fi
now=$(installed "$target")
if [ "$now" = "$cand" ]; then
	say "$target $now já instalado"
else
	say "instalando $target $cand (antes: ${now:-nenhum})"
	apt_get install "$target"
fi

# 5. status
if [ "$role" = node ] && command -v mm-pve >/dev/null 2>&1; then
	mm-pve status || say "AVISO: mm-pve status retornou erro"
fi
}
main "$@" </dev/null
REMOTE

# --------------------------------------------------------------------------
# Execução local / remota
# --------------------------------------------------------------------------

# on_host HOST SCRIPT [ARGS...]: roda SCRIPT com bash no host (local sem ssh).
# Os argumentos são validados (sem espaço nem metacaractere), então podem ir
# na linha de comando do ssh sem aspas.
on_host() {
	local host=$1 script=$2 a args=""
	shift 2
	for a in "$@"; do
		[[ $a =~ ^[A-Za-z0-9._/+~:=-]+$ ]] || die "argumento inseguro para execução remota: '$a'"
		args+=" $a"
	done
	if [[ $host == "$LOCAL_NODE" ]]; then
		bash -s -- "$@" <<<"$script"
	else
		# shellcheck disable=SC2029 # args validados acima; expandir aqui é o objetivo
		ssh "${SSH_OPTS[@]}" "root@$host" "bash -s --$args" <<<"$script"
	fi
}

# copy_to HOST ARQUIVO_LOCAL CAMINHO_REMOTO
copy_to() {
	local host=$1 src=$2 dest=$3
	[[ $dest =~ ^/tmp/mastermind-bootstrap\.[A-Za-z0-9]+/[A-Za-z0-9._+~-]+$ ]] || die "destino inválido: $dest"
	if [[ $host == "$LOCAL_NODE" ]]; then
		cp "$src" "$dest"
	else
		# shellcheck disable=SC2029 # $dest validado acima
		ssh "${SSH_OPTS[@]}" "root@$host" "cat > $dest" <"$src"
	fi
}

fetch() { # fetch URL ARQUIVO
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --retry 3 --connect-timeout 10 -o "$2" "$1"
	elif command -v wget >/dev/null 2>&1; then
		wget -q -O "$2" "$1"
	else
		die "curl ou wget necessário"
	fi
}

# --------------------------------------------------------------------------
# Pacote de configuração
# --------------------------------------------------------------------------

DEB_PATH="" DEB_NAME="" DEB_SHA256="" CFG_VERSION="" CFG_SOURCE=""

verify_sums() { # verify_sums DIR NOME
	local dir=$1 name=$2 expected got
	expected=$(awk -v n="$name" '$2 == n || $2 == "*" n { print $1 }' "$dir/SHA256SUMS")
	[[ $expected =~ ^[0-9a-f]{64}$ ]] || die "$name não está no SHA256SUMS"
	got=$(sha256sum "$dir/$name" | cut -d' ' -f1)
	[[ $got == "$expected" ]] || die "SHA256 de $name não confere (esperado $expected, obtido $got)"
	DEB_SHA256=$got
}

resolve_config_deb() {
	if [[ -n $DEB_FILE ]]; then
		[[ -f $DEB_FILE ]] || die "--deb: $DEB_FILE não existe"
		local dir name
		dir=$(cd "$(dirname "$DEB_FILE")" && pwd)
		name=$(basename "$DEB_FILE")
		[[ -f $dir/SHA256SUMS ]] || die "--deb: falta $dir/SHA256SUMS"
		verify_sums "$dir" "$name"
		DEB_PATH="$dir/$name"
		CFG_SOURCE="arquivo local $DEB_PATH"
	else
		command -v perl >/dev/null 2>&1 || die "perl necessário"
		perl -MJSON::PP -e1 2>/dev/null || die "módulo perl JSON::PP necessário"
		fetch "$RELEASES_API" "$WORKDIR/releases.json" || die "não consegui listar as releases de $REPO_SLUG"
		local line tag ver deb_url sums_url
		line=$(perl -MJSON::PP -e '
			use strict; use warnings;
			my ($channel) = @ARGV;
			my $data = decode_json(do { local $/; <STDIN> });
			my $best;
			for my $r (@$data) {
				next if $r->{draft};
				my $tag = $r->{tag_name} // "";
				next unless $tag =~ m{^mastermind-apt-config/([0-9][A-Za-z0-9.+~-]*)$};
				my $ver = $1;
				# stable: só releases; testing: pre-releases e releases.
				next if $channel eq "stable" && $r->{prerelease};
				my $name = "mastermind-apt-config_${ver}_all.deb";
				my ($deb) = grep { $_->{name} eq $name } @{ $r->{assets} // [] };
				my ($sums) = grep { $_->{name} eq "SHA256SUMS" } @{ $r->{assets} // [] };
				next unless $deb && $sums;
				if (!$best || system("dpkg", "--compare-versions", $ver, "gt", $best->[1]) == 0) {
					$best = [$tag, $ver, $deb->{browser_download_url}, $sums->{browser_download_url}];
				}
			}
			exit 3 unless $best;
			print join("\t", @$best), "\n";
		' "$CHANNEL" <"$WORKDIR/releases.json") ||
			die "nenhuma release de $CONFIG_PKG no canal $CHANNEL em https://github.com/$REPO_SLUG/releases"
		IFS=$'\t' read -r tag ver deb_url sums_url <<<"$line"
		DEB_NAME="${CONFIG_PKG}_${ver}_all.deb"
		mkdir -p "$WORKDIR/deb"
		fetch "$sums_url" "$WORKDIR/deb/SHA256SUMS" || die "falha ao baixar SHA256SUMS de $tag"
		fetch "$deb_url" "$WORKDIR/deb/$DEB_NAME" || die "falha ao baixar $DEB_NAME"
		verify_sums "$WORKDIR/deb" "$DEB_NAME"
		DEB_PATH="$WORKDIR/deb/$DEB_NAME"
		CFG_SOURCE="release $tag"
	fi
	local pkg
	# shellcheck disable=SC2016 # formato do dpkg-deb, não expansão do shell
	read -r pkg CFG_VERSION < <(dpkg-deb --show --showformat='${Package} ${Version}\n' "$DEB_PATH")
	[[ $pkg == "$CONFIG_PKG" ]] || die "$DEB_PATH não é o $CONFIG_PKG (é $pkg)"
	DEB_NAME=$(basename "$DEB_PATH")
	log "$CONFIG_PKG $CFG_VERSION ($CFG_SOURCE), SHA256 $DEB_SHA256 conferido."
}

# Chave da Proxmox para o gateway: a deste node (do pacote) ou a oficial
# baixada e conferida pelo hash fixado.
prepare_pmx_keyring() {
	local out="$WORKDIR/proxmox-archive-keyring.gpg"
	if [[ -f $PMX_KEYRING ]] && dpkg-query -S "$PMX_KEYRING" >/dev/null 2>&1 &&
		[[ -z $(dpkg --verify proxmox-archive-keyring 2>/dev/null) ]]; then
		cp "$PMX_KEYRING" "$out"
		log "Chave da Proxmox: $PMX_KEYRING deste node (pacote proxmox-archive-keyring)."
	else
		fetch "$PMX_KEYRING_URL" "$out" || die "falha ao baixar $PMX_KEYRING_URL"
		[[ $(sha256sum "$out" | cut -d' ' -f1) == "$PMX_KEYRING_SHA256" ]] ||
			die "hash da chave da Proxmox não confere; confira na documentação do PVE"
		log "Chave da Proxmox: $PMX_KEYRING_URL (SHA256 conferido)."
	fi
}

# --------------------------------------------------------------------------
# Nodes
# --------------------------------------------------------------------------

NODES=()   # online
OFFLINE=() # listados mas offline

discover_nodes() {
	command -v pvesh >/dev/null 2>&1 || die "pvesh não encontrado: rode num node do Proxmox VE (ou use --gateway)"
	local json name online is_local
	json=$(pvesh get /cluster/status --output-format json) || die "pvesh get /cluster/status falhou"
	while IFS=$'\t' read -r name online is_local; do
		[[ $name =~ ^[A-Za-z0-9.-]+$ ]] || die "nome de node inesperado: '$name'"
		if [[ $is_local == 1 ]]; then LOCAL_NODE=$name; fi
		if [[ $online == 1 ]]; then NODES+=("$name"); else OFFLINE+=("$name"); fi
	done < <(perl -MJSON::PP -e '
		my $d = decode_json(do { local $/; <STDIN> });
		for my $e (@$d) {
			next unless ($e->{type} // "") eq "node";
			printf "%s\t%d\t%d\n", $e->{name}, $e->{online} // 0, $e->{local} // 0;
		}' <<<"$json")
	if [[ -z $LOCAL_NODE ]]; then LOCAL_NODE=$(uname -n); fi
	[[ ${#NODES[@]} -gt 0 ]] || die "nenhum node online em /cluster/status"
}

# status HOST -> imprime a linha de REMOTE_STATUS (ou vazio se ssh falhar)
host_status() {
	on_host "$1" "$REMOTE_STATUS" 2>/dev/null || true
}

print_table() {
	local last_col=$1 h line cfg ch tools gw
	shift
	printf '%-24s %-24s %-9s %s\n' "NODE" "$CONFIG_PKG" "CANAL" "$last_col"
	for h in "$@"; do
		line=$(host_status "$h")
		if [[ -z $line ]]; then
			printf '%-24s %s\n' "$h" "(sem acesso via ssh)"
			continue
		fi
		IFS='|' read -r cfg ch tools gw _ <<<"$line"
		if [[ $last_col == mm-gw-restore ]]; then tools=$gw; fi
		printf '%-24s %-24s %-9s %s\n' "$h" "$cfg" "$ch" "$tools"
	done
	for h in "${OFFLINE[@]}"; do
		printf '%-24s %s\n' "$h" "(offline, ignorado)"
	done
}

plan_host() { # plan_host HOST PAPEL: só leitura
	local host=$1 role=$2 line cfg ch tools gw pbs target now
	line=$(host_status "$host")
	if [[ -z $line ]]; then
		log "[$host] sem acesso via ssh root@$host: seria ignorado"
		return 1
	fi
	IFS='|' read -r cfg ch tools gw _ _ pbs <<<"$line"
	if [[ $cfg == - ]] || dpkg --compare-versions "$cfg" lt "$CFG_VERSION"; then
		log "[$host] instalaria $CONFIG_PKG $CFG_VERSION (atual: $cfg)"
	else
		log "[$host] $CONFIG_PKG $cfg já instalado"
	fi
	if [[ $ch == "$CHANNEL" ]]; then log "[$host] canal $CHANNEL (sem mudança)"; else log "[$host] canal: $ch -> $CHANNEL"; fi
	if [[ $role == gateway ]]; then
		[[ $pbs == yes ]] || log "[$host] configuraria o repositório pbs-client da Proxmox"
		target=mm-gw-restore now=$gw
	else
		target=mm-pve-tools now=$tools
	fi
	log "[$host] apt-get update; apt-get install -y $target (atual: $now)"
}

install_host() { # install_host HOST PAPEL
	local host=$1 role=$2 tmp line codename pve
	if [[ $role == gateway ]]; then
		line=$(host_status "$host")
		[[ -n $line ]] || { warn "sem acesso via ssh root@$host"; return 1; }
		IFS='|' read -r _ _ _ _ codename pve _ <<<"$line"
		[[ $codename == trixie ]] || { warn "$host não é Debian 13 (codename '$codename')"; return 1; }
		[[ $pve == no ]] || { warn "$host é um node do Proxmox VE; --gateway é para a VM gateway Debian"; return 1; }
	fi
	tmp=$(on_host "$host" "$REMOTE_MKTEMP") || { warn "sem acesso via ssh root@$host"; return 1; }
	copy_to "$host" "$DEB_PATH" "$tmp/$DEB_NAME" || { warn "falha ao copiar $DEB_NAME para $host"; return 1; }
	if [[ $role == gateway ]]; then
		copy_to "$host" "$WORKDIR/proxmox-archive-keyring.gpg" "$tmp/proxmox-archive-keyring.gpg" ||
			{ warn "falha ao copiar a chave da Proxmox para $host"; return 1; }
	fi
	on_host "$host" "$REMOTE_INSTALL" "$tmp" "$DEB_NAME" "$DEB_SHA256" "$CFG_VERSION" "$CHANNEL" "$role"
}

# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
	case $1 in
	--check) MODE=check; shift ;;
	--dry-run) MODE=dry-run; shift ;;
	--channel) CHANNEL=${2:-}; shift 2 || die "--channel precisa de um valor" ;;
	--gateway) GATEWAY=${2:-}; shift 2 || die "--gateway precisa de um host" ;;
	--deb) DEB_FILE=${2:-}; shift 2 || die "--deb precisa de um arquivo" ;;
	-h | --help) usage; exit 0 ;;
	*) usage >&2; exit 2 ;;
	esac
done

[[ $CHANNEL == stable || $CHANNEL == testing ]] || die "canal inválido: '$CHANNEL' (stable ou testing)"
if [[ -n $GATEWAY && ! $GATEWAY =~ ^[A-Za-z0-9.:-]+$ ]]; then die "host do gateway inválido: '$GATEWAY'"; fi
[[ $EUID -eq 0 ]] || die "rode como root"

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

if [[ -n $GATEWAY ]]; then
	ROLE=gateway
	TARGETS=("$GATEWAY")
	LOCAL_NODE="" # o gateway é sempre remoto
	LAST_COL=mm-gw-restore
else
	ROLE=node
	discover_nodes
	TARGETS=("${NODES[@]}")
	LAST_COL=mm-pve-tools
fi

if [[ $MODE == check ]]; then
	print_table "$LAST_COL" "${TARGETS[@]}"
	exit 0
fi

resolve_config_deb
if [[ $ROLE == gateway ]]; then prepare_pmx_keyring; fi

if [[ $MODE == dry-run ]]; then
	log ""
	log "Plano (--dry-run, canal $CHANNEL; nada será alterado):"
	for h in "${TARGETS[@]}"; do plan_host "$h" "$ROLE" || true; done
	for h in "${OFFLINE[@]}"; do log "[$h] offline: seria ignorado"; done
	exit 0
fi

failed=()
for h in "${TARGETS[@]}"; do
	log ""
	log "== $h ($ROLE, canal $CHANNEL)"
	if ! install_host "$h" "$ROLE"; then
		failed+=("$h")
		warn "$h: falhou (veja as mensagens acima)"
	fi
done

log ""
print_table "$LAST_COL" "${TARGETS[@]}"
for h in "${OFFLINE[@]}"; do warn "$h estava offline: rode o bootstrap de novo quando ele voltar"; done
if [[ ${#failed[@]} -gt 0 ]]; then
	die "falhou em: ${failed[*]}"
fi
log "Pronto. Daqui em diante, atualizações são só 'apt full-upgrade'."
