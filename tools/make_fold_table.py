#!/usr/bin/env python3
"""Table de pliage de la normalisation, ÉPINGLÉE : python/fold_data.py et scripts/fold_table.gd.

La normalisation d'un texte (python/babel.py, normalize_all ; scripts/carnet.gd) commence par plier
chaque caractère : minuscule, décomposition NFD, marques combinantes ôtées. Pour que chaque joueur
obtienne le même résultat, quelle que soit la version de Python (donc d'Unicode) installée chez lui,
ce pliage ne s'appuie plus sur unicodedata à l'exécution : il lit une table écrite une fois pour
toutes dans python/fold_data.py (source unique, versionnée avec UNICODE_VERSION), dont
scripts/fold_table.gd est la copie pour GDScript. Seul cet outil lit unicodedata.

La table a une entrée pour tout point de code (0x80 à 0x10FFFF, sans les demi-codes) dont le pliage
change l'effet du caractère sur la normalisation : ce qu'il ajoute au résultat (lettre, espace,
virgule, point, ou rien), son état de blanc, d'ouverture « ‹ » ou de signe qui efface les blancs
précédents. Toute marque combinante, quelle que soit sa classe, se plie en rien. Un point de code
absent reste tel quel, sauf les capitales ASCII, passées en minuscules.

    python3 tools/make_fold_table.py               # récrit scripts/fold_table.gd d'après python/fold_data.py
    python3 tools/make_fold_table.py --check       # échoue si scripts/fold_table.gd n'est pas à jour (toute version de Python)
    python3 tools/make_fold_table.py --pin         # récrit python/fold_data.py d'après l'unicodedata de CET interpréteur
                                                   # (à n'utiliser que pour changer de version d'Unicode) puis scripts/fold_table.gd
    python3 tools/make_fold_table.py --check-data  # échoue si python/fold_data.py n'est pas ce que donne unicodedata
                                                   # (échoue d'emblée si la version d'Unicode n'est pas l'épinglée)
    python3 tools/make_fold_table.py --lists       # JSON {combining, fold}, d'après la table, pour tests/test_quest.gd
"""

from __future__ import annotations

import json
import os
import sys
import unicodedata

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "python"))

import babel  # noqa: E402
import fold_data  # noqa: E402

DATA = os.path.join(ROOT, "python", "fold_data.py")
OUTPUT = os.path.join(ROOT, "scripts", "fold_table.gd")


def code_points():
    for code in range(1, 0x110000):
        if not 0xD800 <= code < 0xE000:
            yield code


# --- Ce que lit unicodedata (seule étape qui en dépend) ---------------------------------------------

def unicode_fold(char: str) -> str:
    """Minuscule, décomposition NFD, marques combinantes ôtées, selon l'unicodedata de cet interpréteur."""
    return "".join(c for c in unicodedata.normalize("NFD", char.lower()) if not unicodedata.combining(c))


def kind(char: str) -> tuple:
    """Ce que la normalisation fait d'un caractère déjà plié (voir babel.normalize_all)."""
    mapped = babel._LIGATURES.get(char) or babel._PUNCTUATION.get(char, char)
    if mapped in babel._BLANKS:
        added = " "
    elif all(c in babel.ALPHABET for c in mapped):
        added = mapped
    else:
        added = ""
    return (added, char in babel._BLANKS, char in babel._OPENING, char in babel._SPACE_BEFORE)


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


def computed_table() -> dict[str, str]:
    """La table que donne unicodedata (caractère → pliage), pour les points de code 0x80 et au-delà."""
    out = {}
    for code in code_points():
        if code < 0x80:
            if unicode_fold(chr(code)) != (chr(code + 32) if 0x41 <= code <= 0x5A else chr(code)):
                raise SystemExit(f"U+{code:04X} : l'ASCII se plie autrement que A-Z → a-z")
            continue
        char = chr(code)
        folded = unicode_fold(char)
        if folded != char and effect(folded) != effect(char):
            out[char] = folded
    return out


def blanks_of_python() -> frozenset[str]:
    return frozenset(chr(c) for c in code_points() if chr(c).isspace())


# --- Rendu ------------------------------------------------------------------------------------------

WIDE_PYTHON = "\\U%08x"      # \U00001d165
WIDE_GODOT = "\\U%06x"       # \U01d165


def escape(text: str, wide: str) -> str:
    parts = []
    for c in text:
        if "a" <= c <= "z" or c in " ,.":
            parts.append(c)
        elif ord(c) > 0xFFFF:
            parts.append(wide % ord(c))
        else:
            parts.append("\\u%04x" % ord(c))
    return "".join(parts)


def rows(entries: list[str], per_line: int) -> list[str]:
    return [", ".join(entries[i:i + per_line]) + "," for i in range(0, len(entries), per_line)]


def render_data(table: dict[str, str], version: str) -> str:
    entries = ['"%s": "%s"' % (escape(k, WIDE_PYTHON), escape(v, WIDE_PYTHON)) for k, v in sorted(table.items())]
    return ('"""Table de pliage ÉPINGLÉE de la normalisation (générée par tools/make_fold_table.py --pin ; ne pas éditer).\n\n'
            "Source unique, pour Python (babel.normalize_all) et, par tools/make_fold_table.py, pour le carnet\n"
            "(scripts/fold_table.gd) : la normalisation ne dépend ainsi d'aucune version d'Unicode installée.\n"
            "FOLD : caractère → minuscule décomposée (NFD), marques combinantes ôtées (« » pour une marque), pour tout\n"
            "caractère de U+0080 et au-delà que ce pliage rend différent pour la normalisation. Absent : inchangé\n"
            'sauf les capitales ASCII (→ minuscules).\n"""\n\n'
            f'UNICODE_VERSION = "{version}"     # unicodedata.unidata_version des données ci-dessous\n\n'
            "FOLD = {\n    " + "\n    ".join(rows(entries, 4)) + "\n}\n")


def render_gd(table: dict[str, str]) -> str:
    entries = ['0x%x: "%s"' % (ord(k), escape(v, WIDE_GODOT)) for k, v in sorted(table.items())]
    blanks = ", ".join('"%s"' % escape(c, WIDE_GODOT) for c in sorted(babel._BLANKS))
    return ("extends RefCounted\n"
            "## Table de pliage du carnet, générée par tools/make_fold_table.py d'après python/fold_data.py (la table\n"
            "## épinglée que lit aussi python/babel.py) : ne pas éditer. Point de code → minuscule décomposée (NFD),\n"
            "## marques combinantes ôtées, pour tout point de code que ce pliage rend différent pour la normalisation.\n"
            "## Absent : le caractère reste (les capitales ASCII passent en minuscules dans Carnet.normalize).\n\n"
            "const FOLD := {\n\t" + "\n\t".join(rows(entries, 8)) + "\n}\n\n"
            "## Les blancs de la normalisation (babel._BLANKS) : tous deviennent une espace.\n"
            "const BLANKS := [" + blanks + "]\n")


def lists() -> dict:
    """Pour tests/test_quest.gd : les marques combinantes (la table les plie en rien ; sous la version
    d'Unicode épinglée, on y joint toutes les marques de unicodedata : catégories Mn, Mc, Me) et tous les
    points de code que la table plie."""
    table = fold_data.FOLD
    marks = {ord(k) for k, v in table.items() if v == ""}
    if unicodedata.unidata_version == fold_data.UNICODE_VERSION:
        marks |= {c for c in code_points() if unicodedata.category(chr(c)) in ("Mn", "Me", "Mc")}
    return {"combining": sorted(marks), "fold": sorted(ord(k) for k in table)}


def main(argv: list[str] | None = None) -> int:
    argv = argv or []
    if "--lists" in argv:
        print(json.dumps(lists()))
        return 0
    if "--check-data" in argv:
        if unicodedata.unidata_version != fold_data.UNICODE_VERSION:
            raise SystemExit(f"unicodedata {unicodedata.unidata_version} : la table est épinglée sur Unicode {fold_data.UNICODE_VERSION}")
        if computed_table() != fold_data.FOLD:
            raise SystemExit("python/fold_data.py n'est pas ce que donne unicodedata : python3 tools/make_fold_table.py --pin")
        if blanks_of_python() != babel._BLANKS:
            raise SystemExit("babel._BLANKS n'est pas l'ensemble des blancs de str.isspace")
        return 0
    if "--pin" in argv:
        with open(DATA, "w", encoding="utf-8") as f:
            f.write(render_data(computed_table(), unicodedata.unidata_version))
        print(f"{len(computed_table())} entrées épinglées (Unicode {unicodedata.unidata_version}) dans {os.path.relpath(DATA, ROOT)}")
        table = computed_table()
    else:
        table = fold_data.FOLD
    text = render_gd(table)
    if "--check" in argv:
        with open(OUTPUT, encoding="utf-8") as f:
            if f.read() != text:
                raise SystemExit("scripts/fold_table.gd n'est pas à jour : python3 tools/make_fold_table.py")
        return 0
    with open(OUTPUT, "w", encoding="utf-8") as f:
        f.write(text)
    print(f"{len(table)} entrées écrites dans {os.path.relpath(OUTPUT, ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
