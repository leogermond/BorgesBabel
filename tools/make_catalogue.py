#!/usr/bin/env python3
"""Catalogue des quêtes : data/quetes/catalogue.json (version 2), outil de développement.

Le catalogue ne contient aucun texte des œuvres. Chaque entrée désigne un LIVRE de la
Bibliothèque (bijection exacte livre ↔ adresse de python/babel.py) : ses métadonnées (titre,
auteur, année, langue, contexte, groupe, licence), l'adresse du livre (hexagone et niveau en
base 25, ~656 000 chiffres chacun), le nombre de pages qu'occupe le texte et, pour chacune, son
numéro et le SHA-256 de ses 3200 symboles. Le texte se lit seulement en ouvrant le livre, dans
le jeu. Une adresse pèse ~1,3 Mo : le fichier fait ~22 Mo.

Contenu des livres (texte normalisé par babel.normalize_all, coulé de page en page, puis des
espaces jusqu'à la fin du livre ; c'est l'unique livre qui contient ce texte, babel.search_text) :
- cinq livres de Borges : page 1, ligne 1 la citation brève (quotes.txt, « titre | citation |
  source ») ; ligne 2 « ... » centré ; puis la loi argentine 11.723 nommée en toutes lettres et la
  première phrase de son article 5 (ley_11723_art5.txt), « 1 de Enero » écrit « primero de enero »
  puisque les chiffres n'existent pas ; à partir de la page 2, la présentation en français écrite
  pour le jeu (babel_fr.txt, aleph_fr.txt, zahir_fr.txt, tlon_fr.txt, golem_fr.txt) ;
- trois textes de Claude, un livre chacun (mode d'emploi, sur la vertu, sur l'humour). Les marques
  {NOM} du mode d'emploi reçoivent d'abord les noms de touches du jeu (KEY_NAMES, ceux de
  scripts/hud.gd), dans une copie écrite sous tools/.travail/ (hors du dépôt).

Notices : la notice d'une entrée (titre, auteur et contexte, une ligne chacun) est le contenu
d'un livre, suivi d'espaces : un livre volé à la Bibliothèque. stolen_books liste ces livres
(adresse sans page), une fois chacun ; une entrée y renvoie par notice_book (rang dans la liste)
et garde notice_hash, le SHA-256 de la première page de ce livre (la notice normalisée, complétée
d'espaces jusqu'à 3200 symboles). Le « Registre des livres manquants » du jeu se tire de
stolen_books.

Destinations (lieux que les quêtes savent atteindre, sans entrée ni épingle) :
- « sator » : le livre dont la page 1 est le carré SATOR (sator_page.txt, page exacte), suivi
  d'espaces : {address, page: 0, sha256} ;
- « golem » : vide ({}) pour l'instant ; le commentaire de Rachi viendra plus tard.

Les sources restent hors du dépôt. Elles arrivent par une liste de chemins, une ligne
« clé chemin » par source (lignes vides et lignes en # ignorées) :

    python3 tools/make_catalogue.py --sources tools/.travail/sources.txt

Clés attendues : SOURCES. L'outil n'affiche que des titres, des longueurs, des nombres de pages
et des condensats ; il n'écrit que le JSON (et la copie de travail des textes à marques). Chaque
livre est relu à son adresse (babel.Book.at) et comparé page à page à la source avant d'être écrit.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "python"))

import babel  # noqa: E402

OUTPUT = os.path.join(ROOT, "data", "quetes", "catalogue.json")
WORK_DIR = os.path.join(ROOT, "tools", ".travail")
VERSION = 2

## Noms des touches du jeu, à l'identique de Hud.QUEST_KEY_NAME et Hud.CLEAR_KEY_NAME.
KEY_NAMES = {"QUETE": "Tab", "EFFACER": "Suppr"}

## Clés de source attendues.
SOURCES = (
    "borges_quotes", "borges_ley",
    "borges_babel_fr", "borges_aleph_fr", "borges_zahir_fr", "borges_tlon_fr", "borges_golem_fr",
    "mode_d_emploi", "sur_la_vertu", "sur_l_humour",
    "sator_page",
)

## La loi nommée en toutes lettres, en tête du passage de l'article 5 (page 1 des livres de Borges).
LAW_HEADING = "Ley once mil setecientos veintitrés de propiedad intelectual de la República Argentina, artículo quinto. "

BORGES = "Jorge Luis Borges"
BORGES_LICENCE = ("œuvre protégée ; la page 1 reprend une citation brève et l'article 5 de la loi argentine 11.723 ;"
                  " les pages suivantes, une présentation en français écrite pour le jeu")
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
        "source": "borges_babel_fr",
    },
    {
        "id": "borges-el-aleph",
        "title": "El Aleph",
        "author": BORGES,
        "year": 1945,
        "language": "es",
        "context": "Parue en 1945 dans la revue Sur, reprise dans le recueil El Aleph (1949). Dans la cave d'une maison de la rue Garay, à Buenos Aires, le narrateur voit depuis la dix-neuvième marche une petite sphère irisée de deux ou trois centimètres qui contient tous les lieux de la terre, vus de tous les angles. Le nom est celui de la première lettre de l'alphabet hébreu, que Cantor avait choisie pour les nombres transfinis, où le tout n'est pas plus grand que l'une de ses parties.",
        "group": "Borges",
        "licence": BORGES_LICENCE,
        "protected": True,
        "source": "borges_aleph_fr",
    },
    {
        "id": "borges-el-zahir",
        "title": "El Zahir",
        "author": BORGES,
        "year": 1947,
        "language": "es",
        "context": "Reprise dans le recueil El Aleph (1949). En arabe, zāhir, « l'apparent », est l'un des quatre-vingt-dix-neuf noms de Dieu. Chez Borges, le Zahir est une pièce de vingt centavos reçue en monnaie dans un almacén de Buenos Aires : une fois vue, elle ne peut plus être oubliée et finit par occuper toute la pensée. Le récit énumère d'autres Zahirs à travers l'histoire, dont un tigre au Gujarat et un astrolabe que Nadir Shah fit jeter à la mer.",
        "group": "Borges",
        "licence": BORGES_LICENCE,
        "protected": True,
        "source": "borges_zahir_fr",
    },
    {
        "id": "borges-tlon-uqbar-orbis-tertius",
        "title": "Tlön, Uqbar, Orbis Tertius",
        "author": BORGES,
        "year": 1940,
        "language": "es",
        "context": "Parue en 1940 dans Sur, reprise dans Ficciones (1944). Tout part d'un article sur l'Uqbar présent dans un seul exemplaire de l'Anglo-American Cyclopaedia (1917). On y découvre Tlön, planète inventée par une société secrète, dont les habitants pensent à la manière de Berkeley : dans ce monde, deux personnes qui cherchent un même crayon perdu finissent par en trouver chacune un, et ces objets nés de la recherche s'appellent hrönir.",
        "group": "Borges",
        "licence": BORGES_LICENCE,
        "protected": True,
        "source": "borges_tlon_fr",
    },
    {
        "id": "borges-el-golem",
        "title": "El Golem",
        "author": BORGES,
        "year": 1958,
        "language": "es",
        "context": "Poème écrit en 1958, repris dans El otro, el mismo (1964). Il s'ouvre sur le Cratyle de Platon : si le nom est l'archétype de la chose, la rose est dans les lettres de « rose » et tout le Nil dans le mot « Nil ». Borges y raconte comment Juda Loew, rabbin de Prague, anima une figure d'argile par des permutations de lettres, en cherchant le Nom qui est la clé.",
        "group": "Borges",
        "licence": BORGES_LICENCE,
        "protected": True,
        "source": "borges_golem_fr",
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


def read(paths: dict[str, str], key: str) -> str:
    with open(paths[key], encoding="utf-8") as f:
        return f.read()


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


def normalized(key: str, text: str) -> str:
    """Le texte ramené à l'alphabet (babel.normalize_all), blancs de tête et de queue ôtés."""
    symbols = babel.normalize_all(text).strip(" ")
    if not symbols:
        raise SystemExit(f"{key} : texte vide après normalisation")
    return symbols


def quotations(text: str) -> dict[str, str]:
    """quotes.txt : titre → citation normalisée (une ligne de 80 symboles au plus)."""
    quotes = {}
    for number, line in enumerate(text.splitlines(), 1):
        if not line.strip():
            continue
        parts = [part.strip() for part in line.split("|")]
        if len(parts) != 3:
            raise SystemExit(f"quotes.txt, ligne {number} : « titre | citation | source » attendu")
        quote = normalized(f"citation « {parts[0]} »", parts[1])
        if len(quote) > babel.CHARS:
            raise SystemExit(f"citation « {parts[0]} » : {len(quote)} symboles, plus d'une ligne de {babel.CHARS}")
        quotes[parts[0]] = quote
    return quotes


def law_passage(text: str) -> str:
    """La loi nommée, puis la première phrase de l'article 5, normalisées (« 1 de Enero » écrit
    « primero de enero »). Elle tient sur les lignes 3 à 40 de la page 1."""
    match = re.search(r"ART[IÍ]CULO\s*5\s*°?\s*[—–-]\s*", text, re.IGNORECASE)
    if match is None:
        raise SystemExit("ley_11723_art5.txt : article 5 introuvable")
    body = text[match.end():]
    end = body.find(".")
    if end < 0:
        raise SystemExit("ley_11723_art5.txt : première phrase de l'article 5 sans point final")
    sentence = body[:end + 1].replace("1 de Enero", "primero de enero").replace("1 de enero", "primero de enero")
    if re.search(r"\d", sentence):
        raise SystemExit("ley_11723_art5.txt : un nombre en chiffres reste dans la première phrase de l'article 5")
    passage = babel.normalize_all(LAW_HEADING + sentence)
    if len(passage) > babel.SYMBOLS - 2 * babel.CHARS:
        raise SystemExit("article 5 : passage plus long que la page")
    return passage


def borges_first_page(quote: str, law: str) -> str:
    """Page 1 d'un livre de Borges : citation, « ... » centré, puis la loi, sur 3200 symboles."""
    page = quote.ljust(babel.CHARS) + "...".center(babel.CHARS) + law
    return page.ljust(babel.SYMBOLS)


def book_record(label: str, content: str) -> dict:
    """L'unique livre dont le contenu commence par `content` (symboles de l'alphabet) puis n'a que
    des espaces : son adresse, et pour chaque page occupée son numéro et son condensat. Le livre
    est relu à son adresse et comparé à la source, page à page."""
    if babel.normalize_all(content) != content:
        raise SystemExit(f"{label} : contenu hors de l'alphabet")
    if len(content) > babel.SYMBOLS * babel.PAGES:
        raise SystemExit(f"{label} : plus long qu'un livre")
    found = babel.search_text(content)
    if found.is_image:
        raise SystemExit(f"{label} : le contenu tombe dans un livre d'images")
    count = -(-len(content) // babel.SYMBOLS)
    padded = content.ljust(count * babel.SYMBOLS)
    reread = babel.Book.at(babel.Address.from_json(found.address.to_json()))
    pages = []
    for number in range(count):
        text = padded[number * babel.SYMBOLS:(number + 1) * babel.SYMBOLS]
        if reread.text(number) != text:
            raise SystemExit(f"{label} : la page {number + 1} relue à l'adresse ne reproduit pas la source")
        pages.append({"page": number, "sha256": hashlib.sha256(text.encode("ascii")).hexdigest()})
    if count < babel.PAGES and reread.text(count) != " " * babel.SYMBOLS:
        raise SystemExit(f"{label} : la page qui suit le texte n'est pas blanche")
    return {"address": found.address.to_json(), "page_count": count, "pages": pages}


def notice_text(entry: dict) -> str:
    return "\n".join([entry["title"], entry["author"], entry["context"]])


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--sources", required=True, help="liste de chemins : une ligne « clé chemin » par source")
    parser.add_argument("--output", default=OUTPUT)
    args = parser.parse_args(argv)

    paths = read_path_list(args.sources)
    missing = [key for key in SOURCES if key not in paths]
    if missing:
        raise SystemExit(f"sources manquantes : {missing}")

    started = time.time()
    quotes = quotations(read(paths, "borges_quotes"))
    law = law_passage(read(paths, "borges_ley"))
    print(f"  citations : {len(quotes)} ; article 5 : {len(law)} symboles")

    entries = []
    stolen = []
    for meta in ENTRIES:
        key = meta["source"]
        text = read(paths, key)
        if meta["author"] == BORGES:
            if meta["title"] not in quotes:
                raise SystemExit(f"{meta['title']} : citation absente de quotes.txt")
            content = borges_first_page(quotes[meta["title"]], law) + normalized(key, text)
        else:
            content = normalized(key, fill_key_names(key, text))
        entry = {k: v for k, v in meta.items() if k != "source"}
        entry.update(book_record(entry["title"], content))

        notice = babel.normalize_all(notice_text(entry))
        if len(notice) > babel.SYMBOLS:
            raise SystemExit(f"{entry['title']} : notice de plus d'une page")
        notice_book = book_record(f"notice de {entry['title']}", notice)
        if notice_book["address"] not in stolen:
            stolen.append(notice_book["address"])
        entry["notice_book"] = stolen.index(notice_book["address"])
        entry["notice_hash"] = notice_book["pages"][0]["sha256"]
        entries.append(entry)
        digits = len(entry["address"]["hexagon"].lstrip("-"))
        print(f"{entry['title']} — {entry['author']} : {len(text)} caractères, {entry['page_count']} page(s),"
              f" sha256 {', '.join(p['sha256'][:12] for p in entry['pages'])}… ; hexagone de {digits} chiffres"
              f" base 25 ; notice {entry['notice_hash'][:12]}…")

    sator_page = read(paths, "sator_page")
    if len(sator_page) != babel.SYMBOLS or babel.normalize_all(sator_page) != sator_page:
        raise SystemExit("sator_page : page exacte de 3200 symboles de l'alphabet attendue")
    sator = book_record("carré SATOR", sator_page.rstrip(" "))
    destinations = {
        "sator": {"address": sator["address"], "page": 0,
                  "sha256": hashlib.sha256(sator_page.encode("ascii")).hexdigest()},
        "golem": {},   # le commentaire de Rachi viendra plus tard
    }
    if sator["pages"][0]["sha256"] != destinations["sator"]["sha256"]:
        raise SystemExit("carré SATOR : la page relue ne reproduit pas la source")
    print(f"destination sator : sha256 {destinations['sator']['sha256'][:12]}…")

    os.makedirs(os.path.dirname(args.output), exist_ok=True)
    with open(args.output, "w", encoding="utf-8") as f:
        json.dump({"version": VERSION, "page_symbols": babel.SYMBOLS, "entries": entries, "stolen_books": stolen,
                   "destinations": destinations}, f, ensure_ascii=False, indent="\t")
        f.write("\n")
    size = os.path.getsize(args.output) / 1e6
    print(f"{len(entries)} entrée(s), {len(stolen)} livre(s) volé(s), {len(destinations)} destination(s) écrits dans"
          f" {os.path.relpath(args.output, ROOT)} ({size:.1f} Mo) en {time.time() - started:.0f} s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
