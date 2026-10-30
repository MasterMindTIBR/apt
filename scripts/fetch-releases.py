#!/usr/bin/env python3
"""Lista as GitHub Releases dos repositórios do sources.yml, baixa os .deb,
confere o SHA256SUMS e decide o que entra em cada canal.

Saídas (em --work):
  incoming/<canal>/<pacote>_<versão>_<arch>.deb   arquivos aceitos
  plan.tsv       <componente>\t<pacote>\t<arquivo>, em ordem crescente de versão
  manifest.json  lista pública e determinística do que foi publicado
  packages.html  tabela para o site

Regras (contrato das releases):
  * só contam tags <componente>/<versão> (e v<semver> onde o sources.yml
    permitir); rascunhos são ignorados;
  * pre-release -> testing, release -> stable;
  * toda release precisa de SHA256SUMS; .deb fora dele é ignorado;
  * checksum divergente é erro fatal (nada é publicado);
  * Package/Version/Architecture vêm de dentro do .deb, nunca do nome;
  * só pacotes listados para aquele repositório são aceitos;
  * por canal, ficam as últimas N versões de cada pacote (N = keep_versions
    do sources.yml).

Uso só da biblioteca padrão + PyYAML (python3-yaml).
"""

import argparse
import functools
import hashlib
import html
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request

import yaml

API = "https://api.github.com"
USER_AGENT = "MasterMindTIBR-apt-publisher"
MAX_ASSET_BYTES = 512 * 1024 * 1024
ARCHES = {"amd64", "all"}

TAG_KINDS = {
    # <componente>/<versão>, ex.: file-restore/4.2.8-1+ntfs3g1
    "component": re.compile(r"^[a-z0-9][a-z0-9-]*/[A-Za-z0-9][A-Za-z0-9.+_-]*$"),
    # v<semver>, ex.: v0.1.0, v1.2.0-rc.1
    "semver": re.compile(
        r"^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?$"
    ),
}
REPO_RE = re.compile(r"^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$")
PKG_RE = re.compile(r"^[a-z0-9][a-z0-9+.-]+$")
VER_RE = re.compile(r"^([0-9]+:)?[0-9][A-Za-z0-9.+~-]*$")
SHA_RE = re.compile(r"^[0-9a-f]{64}$")

IN_ACTIONS = os.environ.get("GITHUB_ACTIONS") == "true"
WARNINGS = []
ERRORS = []


def log(msg):
    print(msg, flush=True)


def warn(msg):
    WARNINGS.append(msg)
    print(("::warning::" if IN_ACTIONS else "AVISO: ") + msg, flush=True)


def error(msg):
    ERRORS.append(msg)
    print(("::error::" if IN_ACTIONS else "ERRO: ") + msg, file=sys.stderr, flush=True)


def die(msg):
    error(msg)
    sys.exit(1)


# --------------------------------------------------------------------------
# HTTP
# --------------------------------------------------------------------------

def _open(req, timeout=60, tries=4):
    delay = 2
    for attempt in range(1, tries + 1):
        try:
            return urllib.request.urlopen(req, timeout=timeout)
        except urllib.error.HTTPError as exc:
            if exc.code == 403 and exc.headers.get("X-RateLimit-Remaining") == "0":
                die(
                    "limite da API do GitHub atingido. Defina GITHUB_TOKEN "
                    "(qualquer token de leitura) e rode de novo."
                )
            if exc.code in (500, 502, 503, 504) and attempt < tries:
                time.sleep(delay)
                delay *= 2
                continue
            raise
        except (urllib.error.URLError, TimeoutError, ConnectionError):
            if attempt < tries:
                time.sleep(delay)
                delay *= 2
                continue
            raise
    raise RuntimeError("unreachable")


def api_get(path):
    """GET na API. O token (opcional) só vai para api.github.com."""
    headers = {
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": USER_AGENT,
    }
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(API + path, headers=headers)
    with _open(req) as resp:
        return json.load(resp)


def list_releases(repo):
    out = []
    for page in range(1, 21):
        try:
            batch = api_get("/repos/%s/releases?per_page=100&page=%d" % (repo, page))
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                die("repositório %s não encontrado (precisa ser público)." % repo)
            raise
        out.extend(batch)
        if len(batch) < 100:
            break
    return out


def download(url, dest, size_hint):
    """Baixa sem cabeçalho de autenticação (assets públicos) e devolve o sha256."""
    if size_hint and size_hint > MAX_ASSET_BYTES:
        raise ValueError("asset grande demais (%d bytes)" % size_hint)
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    tmp = dest + ".part"
    digest = hashlib.sha256()
    total = 0
    with _open(req, timeout=300) as resp, open(tmp, "wb") as fh:
        while True:
            chunk = resp.read(1 << 20)
            if not chunk:
                break
            total += len(chunk)
            if total > MAX_ASSET_BYTES:
                raise ValueError("asset passou de %d bytes" % MAX_ASSET_BYTES)
            digest.update(chunk)
            fh.write(chunk)
    os.replace(tmp, dest)
    return digest.hexdigest()


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


# --------------------------------------------------------------------------
# Debian
# --------------------------------------------------------------------------

def deb_fields(path):
    res = subprocess.run(
        ["dpkg-deb", "--show", "--showformat=${Package}\t${Version}\t${Architecture}", path],
        check=False,
        capture_output=True,
        text=True,
    )
    if res.returncode != 0:
        raise ValueError("dpkg-deb não conseguiu ler: " + res.stderr.strip())
    parts = res.stdout.strip().split("\t")
    if len(parts) != 3:
        raise ValueError("campos de controle inesperados: %r" % res.stdout)
    return parts


@functools.lru_cache(maxsize=None)
def _vercmp(a, b):
    if a == b:
        return 0
    lt = subprocess.run(["dpkg", "--compare-versions", a, "lt", b], check=False).returncode == 0
    return -1 if lt else 1


def version_key():
    return functools.cmp_to_key(lambda x, y: _vercmp(x["version"], y["version"]))




# --------------------------------------------------------------------------
# sources.yml
# --------------------------------------------------------------------------

def load_sources(path):
    with open(path, encoding="utf-8") as fh:
        data = yaml.safe_load(fh)
    if not isinstance(data, dict) or not isinstance(data.get("sources"), list):
        die("%s: falta a lista 'sources'" % path)
    keep = data.get("keep_versions", 5)
    if not isinstance(keep, int) or keep < 1:
        die("%s: keep_versions precisa ser um inteiro >= 1" % path)
    seen_pkgs = {}
    sources = []
    for i, src in enumerate(data["sources"]):
        repo = src.get("repo") if isinstance(src, dict) else None
        if not isinstance(repo, str) or not REPO_RE.match(repo):
            die("%s: sources[%d].repo inválido" % (path, i))
        pkgs = src.get("packages")
        if not isinstance(pkgs, list) or not pkgs:
            die("%s: %s sem 'packages'" % (path, repo))
        for p in pkgs:
            if not isinstance(p, str) or not PKG_RE.match(p):
                die("%s: %s: nome de pacote inválido %r" % (path, repo, p))
            if p in seen_pkgs:
                die("%s: pacote %s listado em %s e %s" % (path, p, seen_pkgs[p], repo))
            seen_pkgs[p] = repo
        kinds = src.get("tags", ["component"])
        if not isinstance(kinds, list) or not kinds or any(k not in TAG_KINDS for k in kinds):
            die("%s: %s: 'tags' aceita só %s" % (path, repo, sorted(TAG_KINDS)))
        sources.append({"repo": repo, "packages": set(pkgs), "tags": kinds})
    return sources, keep


def tag_counts(tag, kinds):
    return any(TAG_KINDS[k].match(tag) for k in kinds)


def parse_sums(text):
    sums = {}
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        m = re.match(r"^([0-9a-fA-F]{64})\s+\*?(.+)$", line)
        if m:
            sums[m.group(2).strip()] = m.group(1).lower()
    return sums


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--sources", default="sources.yml")
    ap.add_argument("--work", default="work")
    args = ap.parse_args()

    sources, keep = load_sources(args.sources)

    cache = os.path.join(args.work, "cache")
    incoming = os.path.join(args.work, "incoming")
    os.makedirs(cache, exist_ok=True)
    shutil.rmtree(incoming, ignore_errors=True)

    entries = {}  # (package, version, arch) -> entry
    summary = []

    for src in sources:
        repo = src["repo"]
        releases = list_releases(repo)
        used = ignored = 0
        log("== %s: %d release(s)" % (repo, len(releases)))
        for rel in releases:
            tag = rel.get("tag_name") or ""
            if rel.get("draft"):
                continue
            if not tag_counts(tag, src["tags"]):
                ignored += 1
                log("   ignorada (tag fora do contrato): %s" % tag)
                continue
            channel = "testing" if rel.get("prerelease") else "stable"
            assets = rel.get("assets") or []
            sums_asset = next((a for a in assets if a.get("name") == "SHA256SUMS"), None)
            debs = [a for a in assets if (a.get("name") or "").endswith(".deb")]
            if not debs:
                ignored += 1
                log("   ignorada (sem .deb): %s" % tag)
                continue
            if sums_asset is None:
                warn("%s %s: release sem SHA256SUMS, ignorada" % (repo, tag))
                ignored += 1
                continue
            sums_path = os.path.join(cache, "sums-%d" % sums_asset["id"])
            try:
                download(sums_asset["browser_download_url"], sums_path, sums_asset.get("size"))
            except (OSError, ValueError) as exc:  # URLError é OSError
                error("%s %s: falha ao baixar SHA256SUMS: %s" % (repo, tag, exc))
                continue
            with open(sums_path, encoding="utf-8", errors="replace") as fh:
                sums = parse_sums(fh.read())
            used += 1
            for asset in debs:
                name = asset["name"]
                expected = sums.get(name)
                if expected is None:
                    warn("%s %s: %s fora do SHA256SUMS, ignorado" % (repo, tag, name))
                    continue
                path = os.path.join(cache, expected + ".deb")
                if os.path.exists(path) and sha256_file(path) == expected:
                    got = expected
                else:
                    try:
                        got = download(asset["browser_download_url"], path, asset.get("size"))
                    except (OSError, ValueError) as exc:
                        error("%s %s: falha ao baixar %s: %s" % (repo, tag, name, exc))
                        continue
                if got != expected:
                    os.unlink(path)
                    error(
                        "%s %s: SHA256 de %s não confere (esperado %s, obtido %s)"
                        % (repo, tag, name, expected, got)
                    )
                    continue
                try:
                    pkg, ver, arch = deb_fields(path)
                except ValueError as exc:
                    error("%s %s: %s: %s" % (repo, tag, name, exc))
                    continue
                if pkg not in src["packages"]:
                    log("   %s: pacote %s não aceito de %s, ignorado" % (tag, pkg, repo))
                    continue
                if not VER_RE.match(ver):
                    error("%s %s: versão inválida %r em %s" % (repo, tag, ver, name))
                    continue
                if arch not in ARCHES:
                    warn("%s %s: arquitetura %s de %s não publicada" % (repo, tag, arch, pkg))
                    continue
                canonical = "%s_%s_%s.deb" % (pkg, ver.split(":", 1)[-1], arch)
                if name != canonical:
                    log("   nota: asset %s contém %s %s (%s)" % (name, pkg, ver, arch))
                key = (pkg, ver, arch)
                entry = {
                    "package": pkg,
                    "version": ver,
                    "architecture": arch,
                    "channel": channel,
                    "sha256": got,
                    "repo": repo,
                    "tag": tag,
                    "release_url": rel.get("html_url", ""),
                    "_path": path,
                    "_file": canonical,
                }
                prev = entries.get(key)
                if prev is None:
                    entries[key] = entry
                elif prev["sha256"] != got:
                    error(
                        "%s %s (%s) aparece com conteúdos diferentes em %s %s e %s %s"
                        % (pkg, ver, arch, prev["repo"], prev["tag"], repo, tag)
                    )
                elif channel == "stable":
                    entries[key] = entry  # mesma build: stable prevalece
        summary.append((repo, len(releases), used, ignored))

    if ERRORS:
        die("%d erro(s) de integridade/contrato; nada foi publicado." % len(ERRORS))

    # Últimas N versões por (canal, pacote, arch).
    groups = {}
    for e in entries.values():
        groups.setdefault((e["channel"], e["package"], e["architecture"]), []).append(e)
    selected = []
    for key in sorted(groups):
        items = sorted(groups[key], key=version_key())
        dropped = items[:-keep]
        for d in dropped:
            log("   fora do limite de %d: %s %s (%s)" % (keep, d["package"], d["version"], key[0]))
        selected.extend(items[-keep:])

    # Arquivos e plano (ordem crescente de versão por pacote).
    plan_lines = []
    for e in selected:
        ddir = os.path.join(incoming, e["channel"])
        os.makedirs(ddir, exist_ok=True)
        dest = os.path.join(ddir, e["_file"])
        shutil.copyfile(e["_path"], dest)
        plan_lines.append("%s\t%s\t%s" % (e["channel"], e["package"], os.path.abspath(dest)))

    with open(os.path.join(args.work, "plan.tsv"), "w", encoding="utf-8") as fh:
        fh.write("".join(line + "\n" for line in plan_lines))

    # Ordem determinística: canal, pacote, arch e versão crescente.
    public = [{k: v for k, v in e.items() if not k.startswith("_")} for e in selected]
    public.sort(key=functools.cmp_to_key(_manifest_cmp))
    with open(os.path.join(args.work, "manifest.json"), "w", encoding="utf-8") as fh:
        json.dump({"repository": "MasterMindTIBR/apt", "packages": public}, fh,
                  indent=2, ensure_ascii=False, sort_keys=True)
        fh.write("\n")

    with open(os.path.join(args.work, "packages.html"), "w", encoding="utf-8") as fh:
        fh.write(render_table(public))

    log("")
    log("Resumo:")
    for repo, total, used, ignored in summary:
        log("  %-40s releases=%d usadas=%d ignoradas=%d" % (repo, total, used, ignored))
    for ch in ("stable", "testing"):
        n = sum(1 for e in public if e["channel"] == ch)
        log("  canal %-8s %d pacote(s)" % (ch, n))
    write_step_summary(summary, public)


def _manifest_cmp(a, b):
    ka = (a["channel"], a["package"], a["architecture"])
    kb = (b["channel"], b["package"], b["architecture"])
    if ka != kb:
        return -1 if ka < kb else 1
    return _vercmp(a["version"], b["version"])


def render_table(entries):
    if not entries:
        return "<p>Nenhum pacote publicado ainda.</p>\n"
    rows = []
    for e in entries:
        rows.append(
            "<tr><td><code>%s</code></td><td><code>%s</code></td><td>%s</td>"
            "<td>%s</td><td><a href=\"%s\">%s</a></td></tr>"
            % tuple(
                html.escape(x)
                for x in (
                    e["package"], e["version"], e["architecture"], e["channel"],
                    e["release_url"], e["tag"],
                )
            )
        )
    return (
        "<table>\n<thead><tr><th>Pacote</th><th>Versão</th><th>Arq.</th>"
        "<th>Canal</th><th>Release</th></tr></thead>\n<tbody>\n"
        + "\n".join(rows)
        + "\n</tbody>\n</table>\n"
    )


def write_step_summary(summary, public):
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not path:
        return
    with open(path, "a", encoding="utf-8") as fh:
        fh.write("### Releases lidas\n\n| Repositório | Releases | Usadas | Ignoradas |\n|---|---|---|---|\n")
        for repo, total, used, ignored in summary:
            fh.write("| %s | %d | %d | %d |\n" % (repo, total, used, ignored))
        fh.write("\n### Pacotes no índice\n\n| Canal | Pacote | Versão | Arq. | Tag |\n|---|---|---|---|---|\n")
        for e in public:
            fh.write("| %s | %s | %s | %s | %s |\n" % (
                e["channel"], e["package"], e["version"], e["architecture"], e["tag"]))
        if WARNINGS:
            fh.write("\n### Avisos\n\n")
            for w in WARNINGS:
                fh.write("- %s\n" % w)


if __name__ == "__main__":
    main()
