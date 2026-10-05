#!/usr/bin/env python3
"""Catalogue des quêtes : data/quetes/catalogue.bcat (version 2, forme compacte), outil de développement.

Le catalogue ne contient aucun texte des œuvres. Chaque entrée désigne un LIVRE de la
Bibliothèque (bijection exacte livre ↔ adresse de python/babel.py) : ses métadonnées (titre,
auteur, année, langue, contexte, groupe, licence), l'adresse du livre (hexagone et niveau en
base 25, ~656 000 chiffres chacun), le nombre de pages qu'occupe le texte et, pour chacune, son
numéro et le SHA-256 de ses 3200 symboles. Le texte se lit seulement en ouvrant le livre, dans
le jeu.

Forme compacte (catalogue.bcat) : une adresse pèse ~1,3 Mo, et le JSON entier ~22 Mo ; mais les
coordonnées des livres trouvés par la recherche partagent presque toutes leurs chiffres de tête
(~650 000 sur 656 000 : les pages blanches qui suivent le texte font le haut du rang). Le fichier
est donc : b"BCAT", la version de la forme (u32, petit-boutiste), la longueur du JSON (u32), puis
ce JSON en UTF-8 compressé par zlib (deflate, que Godot relit : PackedByteArray.decompress). Le
JSON est {"compact": 1, "strings": [[ref, commun, reste, négatif], …], "data": le catalogue},
chaque hexagone ou niveau de plus de 64 caractères du catalogue étant remplacé par « @i », renvoi
à la chaîne i de "strings" : sa valeur absolue est les `commun` premiers chiffres de la valeur
absolue de la chaîne `ref` (une chaîne précédente ; −1 : aucune) suivis de `reste`, précédée
de « - » si `négatif`. Le jeu (scripts/quest.gd, _read_document) relit la même structure qu'avant
en mémoire ; les épingles du joueur s'enregistrent sous la même forme. Le fichier passe de
~22 Mo à moins de 1 Mo.

Contenu des livres (texte normalisé mot à mot par babel.normalize_all puis composé en lignes de 80
symboles, coulé de page en page, puis des espaces jusqu'à la fin du livre ; c'est l'unique livre
qui contient ce texte, babel.search_text). Composition (typeset) : jamais de mot coupé d'une ligne
à l'autre (seul un mot de plus de 80 symboles est coupé) ; un paragraphe est séparé du suivant par
une ligne blanche (80 espaces), deux lignes blanches de la source restent deux ; la première ligne
du texte (son titre) est centrée ; une ligne seule entre deux lignes blanches, de moins de 40
caractères et sans ponctuation finale, est un intertitre, centré, avec une ligne blanche avant et
après (gardé avec le paragraphe qui suit) ; une page ne commence jamais par une ligne blanche ; un
paragraphe peut se poursuivre à la page suivante :
- cinq livres de Borges : page 1, ligne 1 la citation brève (quotes.txt, « titre | citation |
  source ») ; ligne 2 « ... » centré ; puis la loi argentine 11.723 nommée en toutes lettres et la
  première phrase de son article 5 (ley_11723_art5.txt), « 1 de Enero » écrit « primero de enero »
  puisque les chiffres n'existent pas ; à partir de la page 2, la présentation en français écrite
  pour le jeu (babel_fr.txt, aleph_fr.txt, zahir_fr.txt, tlon_fr.txt, golem_fr.txt) ;
- trois textes de Claude, un livre chacun (« Mode d'emploi de Babel », sur la vertu, sur l'humour).
  Le mode d'emploi nomme les touches en toutes lettres et s'écrit sans les lettres q, k, w, y
  (la normalisation k, q → c, w → v, y → i n'y crée aucune faute) : l'outil l'exige.

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
et des condensats ; il n'écrit que le catalogue. Pour relire la mise en page d'un livre :
tools/preview_book.py (aperçu sous .foreman/scratch/, hors du dépôt).
Chaque livre est relu à son adresse (babel.Book.at) et comparé page à page à la source avant d'être
écrit ; le fichier écrit est relu et comparé au catalogue (aller-retour de la forme compacte).

Sans les sources, `--from catalogue.json` (ou .bcat) récrit un catalogue existant sous la forme
compacte : chaque livre y est relu à son adresse et ses pages comparées aux condensats du
catalogue (notices et carré SATOR compris), puis l'aller-retour vérifié de même :

    python3 tools/make_catalogue.py --from data/quetes/catalogue.json
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import struct
import sys
import time
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "python"))

import babel  # noqa: E402

OUTPUT = os.path.join(ROOT, "data", "quetes", "catalogue.bcat")
VERSION = 2

## Lettres que le mode d'emploi s'interdit : la normalisation les change (k, q → c, w → v, y → i).
FORBIDDEN_LETTERS = "qkwy"

## Sources qui ne doivent contenir aucune de ces lettres.
NO_FORBIDDEN_LETTERS = ("mode_d_emploi",)

## Intertitre : une ligne seule de moins de 40 caractères, sans ponctuation finale.
HEADING_MAX = 40
FINAL_PUNCTUATION = ".,;:!?…»)\"”’'"

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
        "title": "Mode d'emploi de Babel",
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


def check_forbidden_letters(key: str, text: str) -> None:
    """Le mode d'emploi s'écrit sans q, k, w, y : la normalisation n'y crée alors aucune faute."""
    found = sorted({c for c in text.lower() if c in FORBIDDEN_LETTERS})
    if found:
        raise SystemExit(f"{key} : les lettres {found} sont interdites dans cette source")


def normalized(key: str, text: str) -> str:
    """Le texte ramené à l'alphabet (babel.normalize_all), blancs de tête et de queue ôtés."""
    symbols = babel.normalize_all(text).strip(" ")
    if not symbols:
        raise SystemExit(f"{key} : texte vide après normalisation")
    return symbols


def words_of(text: str) -> list[str]:
    """Les mots du texte, un par un (blancs de la source), chacun normalisé : ceux qui ne laissent
    rien (« — », chiffres seuls) disparaissent."""
    out: list[str] = []
    for token in text.split():
        out.extend(babel.normalize_all(token).split())
    return out


def wrap(words: list[str], width: int = babel.CHARS) -> list[str]:
    """Les mots répartis en lignes d'au plus `width` symboles, sans jamais couper un mot (sauf un
    mot plus long que `width`, coupé tous les `width` symboles)."""
    lines: list[str] = []
    current = ""
    for word in words:
        while len(word) > width:
            if current:
                lines.append(current)
                current = ""
            lines.append(word[:width])
            word = word[width:]
        if not word:
            continue
        if not current:
            current = word
        elif len(current) + 1 + len(word) <= width:
            current += " " + word
        else:
            lines.append(current)
            current = word
    if current:
        lines.append(current)
    return lines


def blocks_of(text: str) -> list[dict]:
    """La source en blocs {"words", "blank", "kind"} : blank, lignes blanches avant (au plus 2) ;
    kind « title » (la première ligne, seule), « heading » (intertitre) ou « paragraph »."""
    blocks: list[dict] = []
    group: list[str] = []
    state = {"blank": 0, "pending": 0}

    def flush() -> None:
        nonlocal group
        if group:
            words = words_of(" ".join(group))
            if words:
                plain = group[0].strip()
                kind = "paragraph"
                if len(group) == 1 and not blocks:
                    kind = "title"
                elif len(group) == 1 and len(plain) < HEADING_MAX and plain[-1] not in FINAL_PUNCTUATION:
                    kind = "heading"
                blocks.append({"words": words, "blank": min(state["blank"], 2), "kind": kind})
        group = []

    for line in text.splitlines():
        if line.strip():
            if not group:
                state["blank"], state["pending"] = state["pending"], 0
            group.append(line)
        else:
            flush()
            state["pending"] += 1
    flush()
    return blocks


def typeset(text: str) -> str:
    """Le texte composé en lignes de 80 symboles, en une seule chaîne (sans fin de ligne), espaces
    de queue ôtés. Les règles sont décrites en tête du module."""
    width, per_page = babel.CHARS, babel.LINES
    blank_line = " " * width
    lines: list[str] = []
    blocks = blocks_of(text)

    for number, block in enumerate(blocks):
        centred = block["kind"] in ("title", "heading")
        body = [line.center(width) if centred else line.ljust(width) for line in wrap(block["words"])]
        gap = max(1, block["blank"]) if lines else 0
        if block["kind"] == "heading" and lines and number < len(blocks) - 1:
            # l'intertitre reste avec la suite : lui, une ligne blanche et une ligne du paragraphe
            at = (len(lines) + gap) % per_page
            if at != 0 and per_page - at < 3:
                lines.extend([blank_line] * (per_page - len(lines) % per_page))
                gap = 0
        for _ in range(gap):
            if len(lines) % per_page != 0:        # jamais de ligne blanche en tête de page
                lines.append(blank_line)
        lines.extend(body)
    return "".join(lines).rstrip(" ")


def check_layout(text: str, composed: str) -> None:
    """Contre-épreuve de la composition, sur la liste des mots normalisés de la source : lignes de
    80 symboles dont la lecture ligne à ligne redonne les mots un à un, dans l'ordre, aucun coupé
    en tête ni en queue de ligne (hors mot de plus de 80 symboles) ; aucune page ne commence par
    une ligne blanche."""
    width = babel.CHARS
    padded = composed.ljust(-(-len(composed) // width) * width)
    lines = [padded[i:i + width] for i in range(0, len(padded), width)]
    expected = words_of(text)
    read: list[str] = []
    for number, line in enumerate(lines):
        if number % babel.LINES == 0 and not line.strip():
            raise SystemExit(f"composition : la ligne {number + 1}, en tête de page, est blanche")
        read.extend(line.split())
    if max(len(word) for word in expected) > width:
        if "".join(read) != "".join(expected):
            raise SystemExit("composition : les symboles lus ne sont pas ceux de la source")
    elif read != expected:
        raise SystemExit("composition : les mots lus ne sont pas ceux de la source (un mot est coupé)")


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


# --- Forme compacte -------------------------------------------------------------------------

MAGIC = b"BCAT"
COMPACT_FORMAT = 1
LONG_STRING = 64                 # hexagone ou niveau au-delà : rangé dans la table des chaînes
COORDINATE_KEYS = ("hexagon", "level")


def _common_prefix(a: str, b: str) -> int:
    lo, hi = 0, min(len(a), len(b))
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if a[:mid] == b[:mid]:
            lo = mid
        else:
            hi = mid - 1
    return lo


def encode_compact(document: dict) -> bytes:
    """Le document (JSON) sous la forme compacte décrite en tête du module."""
    strings: list[list] = []
    magnitudes: list[str] = []
    index: dict[str, int] = {}

    def coordinate(value: str) -> str:
        if value not in index:
            negative = value.startswith("-")
            magnitude = value[1:] if negative else value
            ref, shared = -1, 0
            for i, other in enumerate(magnitudes):
                common = _common_prefix(magnitude, other)
                if common > shared:
                    ref, shared = i, common
            index[value] = len(strings)
            strings.append([ref, shared, magnitude[shared:], negative])
            magnitudes.append(magnitude)
        return f"@{index[value]}"

    def walk(node):
        if isinstance(node, dict):
            return {key: (coordinate(value) if key in COORDINATE_KEYS and isinstance(value, str)
                          and len(value) > LONG_STRING else walk(value)) for key, value in node.items()}
        if isinstance(node, list):
            return [walk(item) for item in node]
        return node

    data = walk(document)
    payload = json.dumps({"compact": 1, "strings": strings, "data": data}, ensure_ascii=False,
                         separators=(",", ":")).encode("utf-8")
    return MAGIC + struct.pack("<II", COMPACT_FORMAT, len(payload)) + zlib.compress(payload, 9)


def decode_compact(raw: bytes) -> dict:
    """Inverse de encode_compact (comme scripts/quest.gd, _read_document)."""
    if raw[:4] != MAGIC:
        raise ValueError("pas un catalogue compact (en-tête BCAT attendu)")
    version, size = struct.unpack("<II", raw[4:12])
    if version != COMPACT_FORMAT:
        raise ValueError(f"forme compacte {version} inconnue")
    payload = zlib.decompress(raw[12:])
    if len(payload) != size:
        raise ValueError("longueur du JSON inattendue")
    compact = json.loads(payload.decode("utf-8"))
    magnitudes: list[str] = []
    values: list[str] = []
    for ref, shared, rest, negative in compact["strings"]:
        magnitude = (magnitudes[ref][:shared] if ref >= 0 else "") + rest
        magnitudes.append(magnitude)
        values.append(("-" if negative else "") + magnitude)

    def walk(node):
        if isinstance(node, dict):
            return {key: (values[int(value[1:])] if key in COORDINATE_KEYS and isinstance(value, str)
                          and value.startswith("@") else walk(value)) for key, value in node.items()}
        if isinstance(node, list):
            return [walk(item) for item in node]
        return node

    return walk(compact["data"])


def write_catalogue(document: dict, path: str) -> float:
    """Écrit le catalogue sous la forme compacte, le relit et le compare (aller-retour) ; rend la
    taille en Mo."""
    raw = encode_compact(document)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(raw)
    with open(path, "rb") as f:
        if decode_compact(f.read()) != document:
            raise SystemExit(f"{path} : la forme compacte relue ne redonne pas le catalogue")
    return os.path.getsize(path) / 1e6


def read_catalogue(path: str) -> dict:
    with open(path, "rb") as f:
        raw = f.read()
    return decode_compact(raw) if raw[:4] == MAGIC else json.loads(raw.decode("utf-8"))


def verify_book(label: str, address: dict, pages: list[dict]) -> None:
    """Le livre relu à son adresse : chaque page du catalogue a son condensat, la suivante est blanche."""
    book = babel.Book.at(babel.Address.from_json(address))
    for page in pages:
        if hashlib.sha256(book.text(page["page"]).encode("ascii")).hexdigest() != page["sha256"]:
            raise SystemExit(f"{label} : la page {page['page'] + 1} relue à l'adresse n'a pas le condensat du catalogue")
    after = max(p["page"] for p in pages) + 1
    if after < babel.PAGES and book.text(after) != " " * babel.SYMBOLS:
        raise SystemExit(f"{label} : la page qui suit le texte n'est pas blanche")


def convert(source: str, output: str) -> int:
    """Récrit un catalogue existant sous la forme compacte, livres relus et vérifiés."""
    started = time.time()
    document = read_catalogue(source)
    if document.get("version") != VERSION:
        raise SystemExit(f"{source} : catalogue de version {document.get('version')}, {VERSION} attendue")
    stolen = document["stolen_books"]
    for entry in document["entries"]:
        verify_book(entry["title"], entry["address"], entry["pages"])
        verify_book(f"notice de {entry['title']}", stolen[entry["notice_book"]],
                    [{"page": 0, "sha256": entry["notice_hash"]}])
        print(f"{entry['title']} — {entry['author']} : {entry['page_count']} page(s) relue(s) à l'adresse,"
              f" sha256 {', '.join(p['sha256'][:12] for p in entry['pages'])}…")
    sator = document["destinations"].get("sator")
    if sator:
        verify_book("carré SATOR", sator["address"], [{"page": sator["page"], "sha256": sator["sha256"]}])
        print(f"destination sator : sha256 {sator['sha256'][:12]}… relue")
    size = write_catalogue(document, output)
    print(f"{len(document['entries'])} entrée(s), {len(stolen)} livre(s) volé(s) récrits dans"
          f" {os.path.relpath(output, ROOT)} ({size:.2f} Mo, forme compacte vérifiée) en {time.time() - started:.0f} s")
    return 0


def notice_text(entry: dict) -> str:
    return "\n".join([entry["title"], entry["author"], entry["context"]])


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--sources", help="liste de chemins : une ligne « clé chemin » par source")
    parser.add_argument("--from", dest="source", help="catalogue existant (JSON ou forme compacte) à récrire")
    parser.add_argument("--output", default=OUTPUT)
    args = parser.parse_args(argv)
    if args.source:
        return convert(args.source, args.output)
    if not args.sources:
        parser.error("--sources ou --from attendu")

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
            body = typeset(text)
            check_layout(text, body)
            content = borges_first_page(quotes[meta["title"]], law) + body
        else:
            if key in NO_FORBIDDEN_LETTERS:
                check_forbidden_letters(key, text)
            body = typeset(text)
            check_layout(text, body)
            content = body
        entry = {k: v for k, v in meta.items() if k != "source"}
        content = content.rstrip(" ")
        if not content:
            raise SystemExit(f"{meta['title']} : texte vide après normalisation")
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

    size = write_catalogue({"version": VERSION, "page_symbols": babel.SYMBOLS, "entries": entries,
                            "stolen_books": stolen, "destinations": destinations}, args.output)
    print(f"{len(entries)} entrée(s), {len(stolen)} livre(s) volé(s), {len(destinations)} destination(s) écrits dans"
          f" {os.path.relpath(args.output, ROOT)} ({size:.2f} Mo, forme compacte vérifiée) en {time.time() - started:.0f} s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
