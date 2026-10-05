#!/usr/bin/env python3
"""Aperçu de la mise en page d'un livre du catalogue, outil de développement.

    python3 tools/preview_book.py "Mode d'emploi de Babel"      # un titre (ou une partie du titre)
    python3 tools/preview_book.py --all

Chaque livre est relu à son adresse (babel.Book.at, comme le fait le jeu), page par page, et écrit
sous .foreman/scratch/preview_<id>.txt (hors du dépôt) : lignes de 80 symboles encadrées de « | »,
numérotées, une ligne d'en-tête par page. L'outil n'affiche que les chemins écrits.
"""

from __future__ import annotations

import argparse
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "python"))
sys.path.insert(0, os.path.join(ROOT, "tools"))

import babel  # noqa: E402
import make_catalogue  # noqa: E402

SCRATCH = os.path.join(ROOT, ".foreman", "scratch")


def render(entry: dict) -> str:
    book = babel.Book.at(babel.Address.from_json(entry["address"]))
    out = []
    for number in range(entry["page_count"]):
        text = book.text(number)
        out.append(f"=== page {number + 1} / {entry['page_count']} " + "=" * 50)
        for row in range(babel.LINES):
            line = text[row * babel.CHARS:(row + 1) * babel.CHARS]
            out.append(f"{row + 1:2d} |{line}|")
    return "\n".join(out) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("title", nargs="?", help="titre (ou fragment) de l'entrée")
    parser.add_argument("--all", action="store_true")
    parser.add_argument("--catalogue", default=make_catalogue.OUTPUT)
    args = parser.parse_args(argv)
    entries = make_catalogue.read_catalogue(args.catalogue)["entries"]
    if not args.all:
        if not args.title:
            parser.error("un titre ou --all attendu")
        entries = [e for e in entries if args.title.lower() in e["title"].lower()]
        if not entries:
            raise SystemExit("aucune entrée à ce titre")
    os.makedirs(SCRATCH, exist_ok=True)
    for entry in entries:
        path = os.path.join(SCRATCH, "preview_" + entry["id"] + ".txt")
        with open(path, "w", encoding="utf-8") as f:
            f.write(render(entry))
        print(os.path.relpath(path, ROOT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
