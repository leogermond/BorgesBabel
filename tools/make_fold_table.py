#!/usr/bin/env python3
"""Table de pliage du carnet : scripts/fold_table.gd, outil de développement.

Le carnet (GDScript) normalise comme la recherche (python/babel.py, normalize_all). Sa première
étape, « minuscule, décomposition NFD, marques combinantes ôtées », est babel.fold_char : cet outil
en écrit la table pour chaque caractère de Latin-1 supplément, Latin étendu A et B, Latin étendu
additionnel, des marques combinantes, du point d'interrogation grec (U+037E), des espaces
typographiques U+2000–U+200A et de quelques signes (Ω, K, Å) dont la décomposition change la lettre.
Un caractère absent de la table se replie en minuscule seulement (ASCII).

    python3 tools/make_fold_table.py            # récrit scripts/fold_table.gd
    python3 tools/make_fold_table.py --check    # échoue si le fichier n'est pas à jour
"""

from __future__ import annotations

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "python"))

import babel  # noqa: E402

OUTPUT = os.path.join(ROOT, "scripts", "fold_table.gd")

RANGES = (
    (0x80, 0x250),           # Latin-1 supplément, Latin étendu A et B
    (0x300, 0x370),          # marques combinantes
    (0x37E, 0x37F),          # point d'interrogation grec : « ; »
    (0x1E00, 0x1F00),        # Latin étendu additionnel
    (0x2000, 0x200B),        # espaces typographiques
    (0x2126, 0x2127), (0x212A, 0x212C),   # Ω, K, Å
)


def escape(text: str) -> str:
    return "".join(c if "a" <= c <= "z" or c in " ,." else "\\u%04x" % ord(c) for c in text)


def table() -> dict[str, str]:
    out = {}
    for low, high in RANGES:
        for code in range(low, high):
            char = chr(code)
            folded = babel.fold_char(char)
            if folded != char:
                out[char] = folded
    return out


def render() -> str:
    entries = ['"%s": "%s"' % (escape(k), escape(v)) for k, v in table().items()]
    rows = [", ".join(entries[i:i + 6]) + "," for i in range(0, len(entries), 6)]
    return ("extends RefCounted\n"
            "## Table de pliage du carnet, générée par tools/make_fold_table.py d'après babel.fold_char\n"
            "## (python/babel.py) : ne pas éditer. Caractère → minuscule décomposée (NFD), marques ôtées.\n"
            "## Un caractère absent se replie en minuscule seulement (ASCII).\n\n"
            "const FOLD := {\n\t" + "\n\t".join(rows) + "\n}\n")


def main(argv: list[str] | None = None) -> int:
    text = render()
    if argv and "--check" in argv:
        with open(OUTPUT, encoding="utf-8") as f:
            if f.read() != text:
                raise SystemExit("scripts/fold_table.gd n'est pas à jour : python3 tools/make_fold_table.py")
        return 0
    with open(OUTPUT, "w", encoding="utf-8") as f:
        f.write(text)
    print(f"{len(table())} entrées écrites dans {os.path.relpath(OUTPUT, ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
