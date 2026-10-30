#!/usr/bin/env bash
# Verifica, num Debian 13, se os pacotes de um canal são instaláveis usando
# só este repositório + Debian trixie + os repositórios da Proxmox.
#
# Perfis (sources.yml, seção depcheck):
#   node:    Debian + Proxmox VE pve-no-subscription + pin do mastermind-apt-config
#   gateway: Debian + Proxmox pbs-client
#
# Para cada pacote do perfil presente no canal, confere:
#   1. o apt escolhe a versão da MasterMind como candidata (prova o pin);
#   2. apt-get --simulate install <pacote>=<versão> resolve;
#   3. todos os pacotes do perfil juntos resolvem.
#
# Saída: 0 tudo certo; 1 dependência não satisfeita; 2 falha de infraestrutura
# (rede, chave, apt-get update). Relatório em markdown com --report.
#
# Roda como root dentro de um container debian:13 (o apt fica isolado num
# diretório próprio; nada do sistema é alterado).
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REPO=public
CHANNEL=""
REPORT=""
WORK=work
CODENAME=trixie

# Chave da Proxmox para trixie (mesmo hash publicado na documentação do PVE 9).
PMX_KEYRING_URL=https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg
PMX_KEYRING_SHA256=136673be77aba35dcce385b28737689ad64fd785a797e57897589aed08db6e45

usage() {
	cat <<EOF
Uso: $(basename "$0") --channel stable|testing [--repo DIR] [--report ARQ] [--work DIR]
EOF
}

infra() {
	echo "ERRO (infraestrutura): $*" >&2
	exit 2
}

while [[ $# -gt 0 ]]; do
	case $1 in
	--channel) CHANNEL=${2:?}; shift 2 ;;
	--repo) REPO=${2:?}; shift 2 ;;
	--report) REPORT=${2:?}; shift 2 ;;
	--work) WORK=${2:?}; shift 2 ;;
	-h | --help) usage; exit 0 ;;
	*) usage >&2; exit 2 ;;
	esac
done

case $CHANNEL in
stable) components="stable" ;;
testing) components="stable testing" ;;
*) usage >&2; exit 2 ;;
esac

cd "$ROOT"
[[ $(id -u) == 0 ]] || infra "precisa de root (use 'make depcheck', que roda no container debian:13)"
REPO=$(cd "$REPO" && pwd)
[[ -f $REPO/manifest.json && -f $REPO/debian/dists/$CODENAME/Release ]] ||
	infra "$REPO não tem um repositório montado (rode build-repo.sh)"
[[ -f /usr/share/keyrings/debian-archive-keyring.gpg ]] || infra "debian-archive-keyring ausente"

base="$ROOT/$WORK/depcheck"
mkdir -p "$base"
report_tmp=$(mktemp)
trap 'rm -f "$report_tmp"' EXIT
rep() { printf '%s\n' "$*" >>"$report_tmp"; }
# Trecho útil (linhas de erro do apt) de um log, numa linha só.
excerpt() { awk '/^( |E:)/ && n++ < 15' "$1" | tr '\n' ' '; }

# perfil<TAB>pacote<TAB>versão  (versão mais nova do pacote visível no canal)
mapfile -t targets < <(python3 - "$ROOT/sources.yml" "$REPO/manifest.json" "$CHANNEL" <<'PY'
import functools, json, subprocess, sys, yaml
sources, manifest, channel = sys.argv[1:4]
cfg = yaml.safe_load(open(sources, encoding="utf-8"))
pkgs = json.load(open(manifest, encoding="utf-8"))["packages"]
visible = [p for p in pkgs if channel == "testing" or p["channel"] == "stable"]
def cmp(a, b):
    if a == b:
        return 0
    lt = subprocess.run(["dpkg", "--compare-versions", a, "lt", b]).returncode == 0
    return -1 if lt else 1
newest = {}
for p in visible:
    cur = newest.get(p["package"])
    if cur is None or cmp(cur, p["version"]) < 0:
        newest[p["package"]] = p["version"]
for profile, names in (cfg.get("depcheck") or {}).items():
    for name in names:
        if name in newest:
            print("%s\t%s\t%s" % (profile, name, newest[name]))
PY
)

rep "## Dependências do canal \`$CHANNEL\`"
rep ""
if [[ ${#targets[@]} -eq 0 ]]; then
	rep "Canal vazio: nada a verificar."
	echo "Canal $CHANNEL vazio: nada a verificar."
	[[ -z $REPORT ]] || cp "$report_tmp" "$REPORT"
	exit 0
fi

# Chave da Proxmox (baixada uma vez e conferida pelo hash fixado).
pmx_key="$base/proxmox-archive-keyring.gpg"
if [[ ! -f $pmx_key ]] || ! sha256sum "$pmx_key" | grep -q "^$PMX_KEYRING_SHA256 "; then
	curl -fsSL --retry 3 -o "$pmx_key.tmp" "$PMX_KEYRING_URL" || infra "não baixei $PMX_KEYRING_URL"
	got=$(sha256sum "$pmx_key.tmp" | cut -d' ' -f1)
	[[ $got == "$PMX_KEYRING_SHA256" ]] ||
		infra "hash da chave da Proxmox mudou ($got). Confira na documentação do PVE e atualize PMX_KEYRING_SHA256 aqui e no bootstrap-cluster.sh."
	mv "$pmx_key.tmp" "$pmx_key"
fi

status=0
mapfile -t profiles < <(printf '%s\n' "${targets[@]}" | cut -f1 | awk '!seen[$0]++')

for profile in "${profiles[@]}"; do
	root="$base/$CHANNEL-$profile"
	rm -rf "$root"
	mkdir -p "$root/sources.list.d" "$root/preferences.d" "$root/lists/partial" "$root/cache/archives/partial"
	apt_opts=(
		-o "Dir::Etc::SourceList=/dev/null"
		-o "Dir::Etc::SourceParts=$root/sources.list.d"
		-o "Dir::Etc::Preferences=/dev/null"
		-o "Dir::Etc::PreferencesParts=$root/preferences.d"
		-o "Dir::State::Lists=$root/lists"
		-o "Dir::Cache=$root/cache"
		-o "APT::Sandbox::User=root"
		-o "Acquire::Languages=none"
		-o "Acquire::Retries=3"
	)

	cat >"$root/sources.list.d/mastermind.sources" <<EOF
Types: deb
URIs: file:$REPO/debian
Suites: $CODENAME
Components: $components
Trusted: yes
EOF
	cat >"$root/sources.list.d/debian.sources" <<EOF
Types: deb
URIs: http://deb.debian.org/debian
Suites: $CODENAME $CODENAME-updates
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security
Suites: $CODENAME-security
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
	case $profile in
	node)
		pmx_uri=http://download.proxmox.com/debian/pve
		pmx_comp=pve-no-subscription
		cp mastermind-apt-config/mastermind.pref "$root/preferences.d/mastermind"
		;;
	gateway)
		pmx_uri=http://download.proxmox.com/debian/pbs-client
		pmx_comp=main
		;;
	*) infra "perfil desconhecido no sources.yml: $profile" ;;
	esac
	cat >"$root/sources.list.d/proxmox.sources" <<EOF
Types: deb
URIs: $pmx_uri
Suites: $CODENAME
Components: $pmx_comp
Signed-By: $pmx_key
EOF

	echo "== [$CHANNEL/$profile] apt-get update"
	if ! apt-get "${apt_opts[@]}" -q update >"$root/update.log" 2>&1 ||
		grep -qE '^(E:|W: Failed|Err:)' "$root/update.log"; then
		cat "$root/update.log" >&2
		infra "apt-get update falhou no perfil $profile"
	fi

	rep "### Perfil \`$profile\` (Debian $CODENAME + $pmx_uri $pmx_comp)"
	rep ""
	rep "| Pacote | Versão MasterMind | Candidato do apt | Simulação |"
	rep "|---|---|---|---|"

	specs=()
	failures=()
	for line in "${targets[@]}"; do
		IFS=$'\t' read -r p pkg ver <<<"$line"
		[[ $p == "$profile" ]] || continue
		specs+=("$pkg=$ver")
		cand=$(apt-cache "${apt_opts[@]}" policy "$pkg" | awk '/Candidate:/ && !c { print $2; c = 1 }')
		cand_ok="ok"
		if [[ $cand != "$ver" ]]; then
			cand_ok="NÃO ($cand)"
			status=1
			failures+=("$pkg: o apt escolheria $cand em vez de $ver")
		fi
		log="$root/sim-$pkg.log"
		if apt-get "${apt_opts[@]}" -s -q --no-install-recommends install "$pkg=$ver" >"$log" 2>&1; then
			sim="ok"
		else
			sim="FALHOU"
			status=1
			failures+=("$pkg=$ver: $(excerpt "$log")")
		fi
		rep "| \`$pkg\` | \`$ver\` | $cand_ok | $sim |"
		printf '   %-34s %-28s candidato=%-6s simulação=%s\n' "$pkg" "$ver" "$cand_ok" "$sim"
	done

	all_log="$root/sim-all.log"
	if [[ ${#specs[@]} -gt 1 ]]; then
		if apt-get "${apt_opts[@]}" -s -q --no-install-recommends install "${specs[@]}" >"$all_log" 2>&1; then
			rep "| todos juntos | | | ok |"
			echo "   todos juntos: ok"
		else
			rep "| todos juntos | | | FALHOU |"
			echo "   todos juntos: FALHOU"
			status=1
			failures+=("conjunto ${specs[*]}: $(excerpt "$all_log")")
		fi
	fi
	rep ""
	if [[ ${#failures[@]} -gt 0 ]]; then
		rep "<details><summary>Detalhes</summary>"
		rep ""
		rep '```'
		printf '%s\n' "${failures[@]}" >>"$report_tmp"
		rep '```'
		rep "</details>"
		rep ""
	fi
done

[[ -z $REPORT ]] || cp "$report_tmp" "$REPORT"
if [[ $status -ne 0 ]]; then
	echo "Canal $CHANNEL: dependências NÃO satisfeitas." >&2
else
	echo "Canal $CHANNEL: dependências ok."
fi
exit "$status"
