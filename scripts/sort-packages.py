#!/usr/bin/env python3
"""Ordena as estrofes de um arquivo Packages (stdin -> stdout) por pacote,
versão (ordem do dpkg) e arquitetura, para o índice sair igual em toda
execução, independente da ordem em que o sistema de arquivos lista o pool."""

import functools
import subprocess
import sys


def field(stanza, name):
    for line in stanza.splitlines():
        if line.startswith(name + ":"):
            return line.split(":", 1)[1].strip()
    return ""


@functools.lru_cache(maxsize=None)
def vercmp(a, b):
    if a == b:
        return 0
    lt = subprocess.run(["dpkg", "--compare-versions", a, "lt", b], check=False).returncode == 0
    return -1 if lt else 1


def cmp(x, y):
    kx = (field(x, "Package"), field(x, "Architecture"))
    ky = (field(y, "Package"), field(y, "Architecture"))
    if kx[0] != ky[0]:
        return -1 if kx[0] < ky[0] else 1
    c = vercmp(field(x, "Version"), field(y, "Version"))
    if c:
        return c
    return (kx[1] > ky[1]) - (kx[1] < ky[1])


stanzas = [s.strip("\n") for s in sys.stdin.read().split("\n\n") if s.strip()]
stanzas.sort(key=functools.cmp_to_key(cmp))
sys.stdout.write("".join(s + "\n\n" for s in stanzas))
