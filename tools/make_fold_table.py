#!/usr/bin/env python3
"""Table de pliage du carnet : scripts/fold_table.gd, outil de développement.

Le carnet (GDScript) normalise comme la recherche (python/babel.py, normalize_all). Sa première
étape, « minuscule, décomposition NFD, marques combinantes ôtées », est babel.fold_char. Cet outil
parcourt TOUS les points de code (0 à 0x10FFFF, sans les demi-codes) et écrit, pour chacun dont le
pliage n'a pas, pour la normalisation, le même effet que le caractère lui-même, son pliage.

« Même effet » : la normalisation ne distingue, entre deux caractères, que (kind) ce qu'il ajoute au
résultat (lettre, espace, virgule, point, ou rien), s'il est un blanc, une ouverture « ‹ » ou un
signe qui efface les blancs précédents. Un caractère qui se plie en un autre caractère sans effet
(grec majuscule → minuscule, jamo d'une syllabe hangul…) n'a donc pas d'entrée ; un caractère qui se
plie en rien (toute marque combinante, quelle que soit sa classe), en lettre, en blanc ou en signe
en a une. Pour un point de code absent de la table, le carnet garde le caractère, sauf les capitales
ASCII, passées en minuscules à la main (Godot n'a plus à en décider). Les clés sont des entiers.

    python3 tools/make_fold_table.py            # récrit scripts/fold_table.gd
    python3 tools/make_fold_table.py --check    # échoue si le fichier n'est pas à jour
    python3 tools/make_fold_table.py --lists    # JSON {combining, fold} pour tests/test_quest.gd
"""

from __future__ import annotations

import json
import os
import sys
import unicodedata

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "python"))

import babel  # noqa: E402

OUTPUT = os.path.join(ROOT, "scripts", "fold_table.gd")


def code_points():
    for code in range(1, 0x110000):
        if not 0xD800 <= code < 0xE000:
            yield code


def kind(char: str) -> tuple:
    """Ce que la normalisation fait d'un caractère déjà plié (voir babel.normalize_all)."""
    mapped = babel._LIGATURES.get(char) or babel._PUNCTUATION.get(char, char)
    if mapped.isspace():
        added = " "
    elif all(c in babel.ALPHABET for c in mapped):
        added = mapped
    else:
        added = ""
    return (added, char.isspace(), char in babel._OPENING, char in babel._SPACE_BEFORE)


INERT = ("", False, False, False)


def effect(text: str) -> list[tuple]:
    """La suite des effets, les caractères sans effet qui se suivent n'en faisant qu'un."""
    out: list[tuple] = []
    for char in text:
        k = kind(char)
        if k == INERT and out and out[-1] == INERT:
            continue
        out.append(k)
    return out


def table() -> dict[int, str]:
    out = {}
    for code in code_points():
        char = chr(code)
        folded = babel.fold_char(char)
        if folded == char:
            continue
        if code < 0x80 and not ("A" <= char <= "Z"):
            raise SystemExit(f"U+{code:04X} : un caractère ASCII autre que A-Z se plie")
        if "A" <= char <= "Z" or effect(folded) != effect(char):
            out[code] = folded
    return out


def escape(text: str) -> str:
    parts = []
    for c in text:
        if "a" <= c <= "z" or c in " ,.":
            parts.append(c)
        elif ord(c) > 0xFFFF:
            parts.append("\\U%06x" % ord(c))
        else:
            parts.append("\\u%04x" % ord(c))
    return "".join(parts)


def render() -> str:
    entries = [f'0x{code:x}: "{escape(folded)}"' for code, folded in sorted(table().items()) if code >= 0x80]
    rows = [", ".join(entries[i:i + 8]) + "," for i in range(0, len(entries), 8)]
    return ("extends RefCounted\n"
            "## Table de pliage du carnet, générée par tools/make_fold_table.py d'après babel.fold_char\n"
            "## (python/babel.py) : ne pas éditer. Point de code → minuscule décomposée (NFD), marques\n"
            "## combinantes ôtées, pour tout point de code que ce pliage rend différent pour la normalisation.\n"
            "## Absent : le caractère reste (les capitales ASCII passent en minuscules dans Carnet.normalize).\n\n"
            "const FOLD := {\n\t" + "\n\t".join(rows) + "\n}\n")


def lists() -> dict:
    """Pour tests/test_quest.gd : toutes les marques combinantes (toute classe), et tous les points de
    code que fold_char change."""
    combining = [c for c in code_points() if unicodedata.combining(chr(c))
                 or unicodedata.category(chr(c)) in ("Mn", "Me", "Mc")]
    folded = [c for c in code_points() if babel.fold_char(chr(c)) != chr(c)]
    return {"combining": combining, "fold": folded}


def main(argv: list[str] | None = None) -> int:
    argv = argv or []
    if "--lists" in argv:
        print(json.dumps(lists()))
        return 0
    text = render()
    if "--check" in argv:
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
