#!/usr/bin/env python3
"""Localiza el bloque que impide que /bin/sh parsee el instalador.

En macOS /bin/sh es bash 3.2, que tiene un parser mas estricto que el de Linux:
este diagnostico quita un cuerpo heredoc cada vez y vuelve a parsear, de modo que
el bloque culpable se identifica solo. Uso: python3 tests/sh_parse_bisect.py [shell]
"""
from __future__ import annotations

import pathlib
import re
import subprocess
import sys
import tempfile

SHELL = sys.argv[1] if len(sys.argv) > 1 else "/bin/sh"
SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "hermes-mobile-setup.sh"


def parses(source: str) -> subprocess.CompletedProcess:
    with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as handle:
        handle.write(source)
        path = handle.name
    return subprocess.run([SHELL, "-n", path], capture_output=True, text=True)


def main() -> int:
    text = SCRIPT.read_text(encoding="utf-8")
    lines = text.splitlines()
    base = parses(text)
    print(f"shell: {SHELL}")
    print(f"base: rc={base.returncode} {base.stderr.strip().splitlines()[:2]}")

    blocks = []
    index = 0
    while index < len(lines):
        match = re.search(r"<<\s*('?)([A-Za-z_][A-Za-z0-9_]*)\1\s*$", lines[index])
        if match and "<<" in lines[index]:
            marker = match.group(2)
            end = index + 1
            while end < len(lines) and lines[end].strip() != marker:
                end += 1
            blocks.append((index, end, marker))
            index = end
        index += 1
    print(f"bloques heredoc encontrados: {len(blocks)}")

    suspects = []
    for start, end, marker in blocks:
        trimmed = lines[:start + 1] + [f"# cuerpo de {marker} eliminado"] + lines[end:]
        result = parses("\n".join(trimmed) + "\n")
        if result.returncode == 0:
            suspects.append((start + 1, marker, "cuerpo"))
            print(f"SOSPECHOSO: sin el cuerpo del heredoc de la linea {start + 1} ({marker}) el script parsea")

    for start, end, marker in blocks:
        trimmed = lines[:start] + lines[end + 1:]
        result = parses("\n".join(trimmed) + "\n")
        if result.returncode == 0:
            print(f"SOSPECHOSO: sin la linea {start + 1} y su cuerpo ({marker}) el script parsea")

    if base.returncode == 0:
        print("El script parsea tal cual con este shell.")
    if not suspects and base.returncode != 0:
        print("Ningun heredoc aislado lo explica: el desajuste esta en otra construccion.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
