#!/usr/bin/env python3
"""Catalogue des quêtes : data/quetes/catalogue.json, outil de développement.

Le catalogue ne contient aucun texte des œuvres : pour chaque entrée, ses métadonnées (titre,
auteur, année, langue, contexte, groupe, nombre de pages, licence), pour chaque page son adresse
dans la Bibliothèque et le SHA-256 des 3200 symboles de la page, et l'adresse et le condensat de
sa notice (titre, auteur, contexte : une page d'un livre de la Bibliothèque). La liste
stolen_books reprend les livres (sans la page) de ces notices. Le texte se lit seulement
en ouvrant le livre à cette adresse, dans le jeu.

Les sources restent hors du dépôt. Elles arrivent par une liste de chemins, une ligne
« clé chemin » par source (lignes vides et lignes en # ignorées) :

    python3 tools/make_catalogue.py --sources tools/.travail/sources.txt

Clés attendues : voir SOURCES. Deux genres de source :
- « page » : une page exacte de 3200 symboles de l'alphabet, reprise telle quelle ;
- « texte » : un texte libre, normalisé par babel.normalize_all puis coupé en pages de
  3200 symboles (la dernière complétée d'espaces). Les marques {NOM} d'un texte reçoivent
  d'abord les noms de touches du jeu (KEY_NAMES, ceux de scripts/hud.gd), dans une copie
  écrite sous tools/.travail/ (hors du dépôt).

L'outil affiche seulement des titres, des longueurs et des condensats ; il n'écrit que le JSON
(et la copie de travail des textes à marques).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "python"))

import babel  # noqa: E402

OUTPUT = os.path.join(ROOT, "data", "quetes", "catalogue.json")
WORK_DIR = os.path.join(ROOT, "tools", ".travail")
VERSION = 1

## Noms des touches du jeu, à l'identique de Hud.QUEST_KEY_NAME et Hud.CLEAR_KEY_NAME.
KEY_NAMES = {"QUETE": "Tab", "EFFACER": "Suppr"}

## Clé de source → genre (« page » ou « texte »).
SOURCES = {
    "borges_babel_page": "page",
    "borges_avis_page": "page",
    "mode_d_emploi": "texte",
    "sur_la_vertu": "texte",
    "sur_l_humour": "texte",
}

BORGES = "Jorge Luis Borges"
BORGES_LICENCE = "œuvre protégée ; la page reprend une citation brève et l'article 5 de la loi argentine 11.723"
BORGES_NOTICE_LICENCE = "œuvre protégée ; la page reprend l'article 5 de la loi argentine 11.723"
CLAUDE_LICENCE = "texte original écrit pour le jeu"

ENTRIES = [
    {
        "id": "borges-biblioteca-de-babel",
        "title": "La biblioteca de Babel",
        "author": BORGES,
        "year": 1941,
        "language": "es",
        "context": "Parue en 1941 dans El jardín de senderos que se bifurcan, reprise dans Ficciones (1944). Borges y décrit un univers de galeries hexagonales dont les livres, de 410 pages de 40 lignes d'environ 80 lettres, épuisent toutes les combinaisons de vingt-cinq symboles. Il reprend une idée de Kurd Lasswitz, « Die Universalbibliothek » (1904), qu'il commente dans son essai « La biblioteca total » (1939).",
        "group": "Borges",
        "licence": BORGES_LICENCE,
        "protected": True,
        "source": "borges_babel_page",
    },
    {
        "id": "borges-el-aleph",
        "title": "El Aleph",
        "author": BORGES,
        "year": 1945,
        "language": "es",
        "context": "Parue en 1945 dans la revue Sur, reprise dans le recueil El Aleph (1949). Dans la cave d'une maison de la rue Garay, à Buenos Aires, le narrateur voit depuis la dix-neuvième marche une petite sphère irisée de deux ou trois centimètres qui contient tous les lieux de la terre, vus de tous les angles. Le nom est celui de la première lettre de l'alphabet hébreu, que Cantor avait choisie pour les nombres transfinis, où le tout n'est pas plus grand que l'une de ses parties.",
        "group": "Borges",
        "licence": BORGES_NOTICE_LICENCE,
        "protected": True,
        "source": "borges_avis_page",
    },
    {
        "id": "borges-el-zahir",
        "title": "El Zahir",
        "author": BORGES,
        "year": 1947,
        "language": "es",
        "context": "Reprise dans le recueil El Aleph (1949). En arabe, zāhir, « l'apparent », est l'un des quatre-vingt-dix-neuf noms de Dieu. Chez Borges, le Zahir est une pièce de vingt centavos reçue en monnaie dans un almacén de Buenos Aires : une fois vue, elle ne peut plus être oubliée et finit par occuper toute la pensée. Le récit énumère d'autres Zahirs à travers l'histoire, dont un tigre au Gujarat et un astrolabe que Nadir Shah fit jeter à la mer.",
        "group": "Borges",
        "licence": BORGES_NOTICE_LICENCE,
        "protected": True,
        "source": "borges_avis_page",
    },
    {
        "id": "borges-tlon-uqbar-orbis-tertius",
        "title": "Tlön, Uqbar, Orbis Tertius",
        "author": BORGES,
        "year": 1940,
        "language": "es",
        "context": "Parue en 1940 dans Sur, reprise dans Ficciones (1944). Tout part d'un article sur l'Uqbar présent dans un seul exemplaire de l'Anglo-American Cyclopaedia (1917). On y découvre Tlön, planète inventée par une société secrète, dont les habitants pensent à la manière de Berkeley : dans ce monde, deux personnes qui cherchent un même crayon perdu finissent par en trouver chacune un, et ces objets nés de la recherche s'appellent hrönir.",
        "group": "Borges",
        "licence": BORGES_NOTICE_LICENCE,
        "protected": True,
        "source": "borges_avis_page",
    },
    {
        "id": "borges-el-golem",
        "title": "El Golem",
        "author": BORGES,
        "year": 1958,
        "language": "es",
        "context": "Poème écrit en 1958, repris dans El otro, el mismo (1964). Il s'ouvre sur le Cratyle de Platon : si le nom est l'archétype de la chose, la rose est dans les lettres de « rose » et tout le Nil dans le mot « Nil ». Borges y raconte comment Juda Loew, rabbin de Prague, anima une figure d'argile par des permutations de lettres, en cherchant le Nom qui est la clé.",
        "group": "Borges",
        "licence": BORGES_NOTICE_LICENCE,
        "protected": True,
        "source": "borges_avis_page",
    },
    {
        "id": "claude-mode-d-emploi",
        "title": "Mode d'emploi de la Bibliothèque",
        "author": "Claude",
        "year": 2026,
        "language": "fr",
        "context": "Instructions à l'usage des bibliothécaires.",
        "group": "Claude",
        "licence": CLAUDE_LICENCE,
        "protected": False,
        "source": "mode_d_emploi",
    },
    {
        "id": "claude-sur-la-vertu",
        "title": "Sur la vertu",
        "author": "Claude",
        "year": 2026,
        "language": "fr",
        "context": "Méditation sur la vertu et le sens d'une existence morale.",
        "group": "Claude",
        "licence": CLAUDE_LICENCE,
        "protected": False,
        "source": "sur_la_vertu",
    },
    {
        "id": "claude-sur-l-humour",
        "title": "Sur l'humour",
        "author": "Claude",
        "year": 2026,
        "language": "fr",
        "context": "Bref essai sur l'humour.",
        "group": "Claude",
        "licence": CLAUDE_LICENCE,
        "protected": False,
        "source": "sur_l_humour",
    },
]


def read_path_list(path: str) -> dict[str, str]:
    paths = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            key, _, value = line.partition(" ")
            paths[key] = value.strip()
    return paths


def fill_key_names(key: str, text: str) -> str:
    """Remplace les marques {NOM} par les noms de touches ; écrit la copie sous WORK_DIR."""
    marks = set(re.findall(r"\{([A-Z_]+)\}", text))
    if not marks:
        return text
    unknown = marks - KEY_NAMES.keys()
    if unknown:
        raise SystemExit(f"{key} : marques inconnues {sorted(unknown)}")
    for name in marks:
        text = text.replace("{%s}" % name, KEY_NAMES[name])
    os.makedirs(WORK_DIR, exist_ok=True)
    with open(os.path.join(WORK_DIR, key + ".txt"), "w", encoding="utf-8") as f:
        f.write(text)
    print(f"  {key} : {len(marks)} marque(s) remplacée(s), copie de travail sous tools/.travail/")
    return text


def page_record(page: str) -> dict:
    """Adresse (livre de texte) et condensat d'une page exacte de 3200 symboles."""
    if len(page) != babel.SYMBOLS or babel.pad(page) != page:
        raise SystemExit("page hors format : 3200 symboles de l'alphabet attendus")
    address, _tries = babel.search_text(page)
    if babel.address_is_image(address) or babel.page_text(address) != page:
        raise SystemExit("la page trouvée ne reproduit pas la source")
    return {"address": address.to_json(), "sha256": hashlib.sha256(page.encode("ascii")).hexdigest()}


def notice_record(entry: dict) -> dict:
    """La notice d'une entrée (titre, auteur et contexte, une ligne chacun) lue comme une page :
    son adresse et son condensat. La notice est une page d'un livre de la Bibliothèque."""
    notice = "\n".join([entry["title"], entry["author"], entry["context"]])
    if len(babel.normalize_all(notice)) > babel.SYMBOLS:
        raise SystemExit(f"{entry['title']} : notice de plus d'une page")
    page = babel.pad(notice)
    address, _tries = babel.search_text(notice)
    if babel.address_is_image(address) or babel.page_text(address) != page:
        raise SystemExit("la notice trouvée ne reproduit pas la source")
    return {"notice_address": address.to_json(), "notice_hash": hashlib.sha256(page.encode("ascii")).hexdigest()}


def source_pages(key: str, kind: str, text: str) -> list[str]:
    if kind == "page":
        return [text]
    symbols = babel.normalize_all(fill_key_names(key, text))
    if not symbols.strip():
        raise SystemExit(f"{key} : texte vide après normalisation")
    return [symbols[i:i + babel.SYMBOLS].ljust(babel.SYMBOLS) for i in range(0, len(symbols), babel.SYMBOLS)]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--sources", required=True, help="liste de chemins : une ligne « clé chemin » par source")
    parser.add_argument("--output", default=OUTPUT)
    args = parser.parse_args(argv)

    paths = read_path_list(args.sources)
    missing = [key for key in SOURCES if key not in paths]
    if missing:
        raise SystemExit(f"sources manquantes : {missing}")

    cache: dict[str, list[dict]] = {}
    entries = []
    for meta in ENTRIES:
        key = meta["source"]
        if key not in cache:
            with open(paths[key], encoding="utf-8") as f:
                text = f.read()
            pages = source_pages(key, SOURCES[key], text)
            cache[key] = [page_record(page) for page in pages]
            print(f"  {key} : {len(text)} caractères, {len(pages)} page(s)")
        entry = {k: v for k, v in meta.items() if k != "source"}
        entry["page_count"] = len(cache[key])
        entry["pages"] = cache[key]
        entry.update(notice_record(entry))
        entries.append(entry)
        hashes = ", ".join(p["sha256"][:16] for p in entry["pages"])
        digits = ", ".join(str(len(p["address"]["hexagon"])) for p in entry["pages"])
        print(f"{entry['title']} — {entry['author']} : {entry['page_count']} page(s), sha256 {hashes}…, hexagone de {digits} chiffres ; notice {entry['notice_hash'][:16]}…")

    # Les livres dont une page est une notice : la Bibliothèque les a perdus.
    stolen = []
    for entry in entries:
        book = {k: v for k, v in entry["notice_address"].items() if k != "page"}
        if book not in stolen:
            stolen.append(book)

    os.makedirs(os.path.dirname(args.output), exist_ok=True)
    with open(args.output, "w", encoding="utf-8") as f:
        json.dump({"version": VERSION, "page_symbols": babel.SYMBOLS, "entries": entries, "stolen_books": stolen}, f, ensure_ascii=False, indent="\t")
        f.write("\n")
    print(f"{len(entries)} entrée(s), {len(stolen)} livre(s) volé(s) écrits dans {os.path.relpath(args.output, ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
