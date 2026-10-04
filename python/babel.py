#!/usr/bin/env python3
"""Bibliothèque de Babel : bijection entre adresses et pages, dans les deux sens.

Bibliothèque standard seule, Python ≥ 3.10. Le jeu Godot lance `python babel.py serve`
et lui parle en JSON, une ligne par requête ; la ligne de commande sert aussi hors ligne.

Page
    3200 symboles (40 lignes de 80) pris dans l'alphabet de 25 symboles
    « abcdefghijlmnoprstuvxz ,. ». Une page est un nombre Y de [0, N), N = 25^3200 :
    le symbole i de la page (ordre de lecture) est le chiffre i de Y en base 25,
    poids faible en premier, lu dans l'alphabet.

Adresse
    (hexagone, niveau, mur 0..3, étagère 0..4, livre 0..31, page 0..409), hexagone et
    niveau entiers relatifs sans borne.

Empaquetage adresse → X'
    1. Codage zigzag des relatifs : z(v) = 2v si v ≥ 0, −2v − 1 sinon (0, −1, 1, −2 … → 0, 1, 2, 3 …).
    2. Entrelacement base 25 : le chiffre 2i de « rest » est le chiffre i de z(hexagone),
       le chiffre 2i + 1 celui de z(niveau).
    3. local = ((mur·5 + étagère)·32 + livre)·410 + page, de 0 à 262 399.
    4. X' = rest·262 400 + local, entier naturel sans borne.

Contenu X = X' mod N, puis mélange Y = mix(X) :
    Y1 = (A1·X + B1) mod N ; R = Y1 aux 3200 chiffres retournés ; Y = (A2·R + B2) mod N.
    Une multiplication modulo 25^n propage les chiffres vers le haut seulement ; le retournement
    entre les deux tours renvoie vers le bas ce que le premier tour a propagé vers le haut,
    si bien que chaque chiffre de la page dépend de tous les chiffres de l'adresse :
    deux adresses voisines donnent des pages sans début ni fin communs.
    A1, A2, B1, B2 : constantes fixes de 3200 chiffres, tirées de SHA-256 (voir _constant).
    A1 et A2 sont premiers avec 5, donc inversibles modulo N = 5^6400 ; l'inverse vient de
    pow(A, −1, N). N étant impair, être premier avec 5 suffit.

Recherche
    Une page Y donne X = unmix(Y), puis les adresses X' = X + k·N (k = 0, 1, 2 …) montrent
    toutes la même page. La recherche de texte prend le premier k qui tombe dans un livre de
    texte, la recherche d'image le premier k qui tombe dans un livre d'images.

Livres d'images
    is_image_book : SHA-256 de (z(hexagone), z(niveau), mur, étagère, livre), vrai pour un
    livre sur 50 environ. Chaque page d'un tel livre se lit comme une image de 50 × 64 pixels
    (portrait, pixels carrés) : le pixel (x, y) est le symbole y·50 + x, et le symbole d'indice i
    dans l'alphabet prend l'encre PALETTE[i].

Normalisation d'un texte cherché (normalize)
    minuscules ; accents retirés (décomposition Unicode NFD, marques combinantes ôtées) ;
    œ → oe, æ → ae, ß → ss ; k → c, q → c, w → v, y → i ; tout blanc (espace, tabulation,
    retour à la ligne) → espace ; les autres caractères (chiffres, apostrophes, ! ? ; : …)
    sont retirés. Au-delà de 3200 symboles, la suite est ignorée.
Remplissage (pad) : le texte normalisé est complété par des espaces jusqu'à 3200 symboles.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import struct
import sys
import unicodedata
import zlib
from dataclasses import dataclass

# Les hexagones trouvés par la recherche comptent quelques milliers de chiffres décimaux.
if hasattr(sys, "set_int_max_str_digits"):
    sys.set_int_max_str_digits(0)

PROTOCOL = 1
ALPHABET = "abcdefghijlmnoprstuvxz ,."
PAGES = 410
LINES = 40
CHARS = 80
SYMBOLS = LINES * CHARS          # 3200
WALLS = 4
SHELVES = 5
BOOKS = 32
LOCAL_COUNT = WALLS * SHELVES * BOOKS * PAGES   # 262 400
N = 25 ** SYMBOLS
IMAGE_BOOK_ONE_IN = 50
IMAGE_WIDTH = 50
IMAGE_HEIGHT = 64

## 25 encres chaudes, une par symbole, dans l'ordre de l'alphabet. L'encre 0 est la plus sombre :
## elle borde les images dont les proportions diffèrent de la page.
PALETTE: tuple[tuple[int, int, int], ...] = (
    (0x1A, 0x14, 0x10),  # a  noir de fumée
    (0x2E, 0x22, 0x19),  # b  bistre sombre
    (0x4A, 0x35, 0x27),  # c  terre d'ombre brûlée
    (0x6B, 0x4E, 0x36),  # d  sépia
    (0x8C, 0x6A, 0x4A),  # e  terre d'ombre naturelle
    (0xAD, 0x8A, 0x64),  # f  cuir
    (0xC9, 0xA9, 0x7F),  # g  chamois
    (0xE0, 0xC9, 0xA0),  # h  vélin
    (0xF1, 0xE3, 0xC4),  # i  parchemin
    (0xFB, 0xF4, 0xE2),  # j  ivoire
    (0x5C, 0x1A, 0x14),  # l  sang-de-bœuf
    (0x8E, 0x2A, 0x1C),  # m  ocre rouge
    (0xB8, 0x44, 0x2A),  # n  vermillon
    (0xD9, 0x78, 0x4A),  # o  orangé brûlé
    (0x7A, 0x4A, 0x1C),  # p  terre de Sienne
    (0xB0, 0x7A, 0x2A),  # r  ocre jaune
    (0xD9, 0xA6, 0x3C),  # s  or
    (0x3E, 0x4A, 0x2A),  # t  olive sombre
    (0x6B, 0x7A, 0x3E),  # u  olive
    (0x4F, 0x7A, 0x6A),  # v  vert-de-gris
    (0x8F, 0xAE, 0x96),  # x  céladon
    (0x1F, 0x2E, 0x40),  # z  indigo
    (0x3D, 0x54, 0x70),  # ' ' encre ferro-gallique
    (0x7A, 0x8E, 0xA8),  # ,  bleu passé
    (0x6A, 0x4A, 0x5E),  # .  garance violette
)

_DIGIT_CHARS = b"0123456789abcdefghijklmno"
_TO_INT_STR = bytes.maketrans(bytes(range(25)), _DIGIT_CHARS)
_TO_ALPHABET = bytes.maketrans(bytes(range(25)), ALPHABET.encode("ascii"))
_FROM_ALPHABET = bytes.maketrans(ALPHABET.encode("ascii"), bytes(range(25)))
_POW25: dict[int, int] = {}


# --- Chiffres en base 25 ------------------------------------------------------------------

def _pow25(n: int) -> int:
    if n not in _POW25:
        _POW25[n] = 25 ** n
    return _POW25[n]


def to_digits(x: int, count: int) -> bytes:
    """Les `count` chiffres base 25 de poids faible de x ≥ 0, poids faible en premier."""
    if count <= 24:
        out = bytearray(count)
        for i in range(count):
            x, out[i] = divmod(x, 25)
        return bytes(out)
    half = count // 2
    high, low = divmod(x, _pow25(half))
    return to_digits(low, half) + to_digits(high, count - half)


def from_digits(digits: bytes) -> int:
    """Le nombre dont les chiffres base 25 sont `digits`, poids faible en premier."""
    if not digits:
        return 0
    return int(bytes(reversed(digits)).translate(_TO_INT_STR), 25)


def _constant(label: str, multiplier: bool) -> int:
    """3200 chiffres base 25 tirés de SHA-256("BookText|<label>|<bloc>"), bloc = 0, 1, 2 …

    Les octets ≥ 250 sont écartés (tirage uniforme), les autres donnent octet mod 25.
    Pour un multiplicateur, le chiffre de poids faible passe au suivant s'il est multiple de 5 :
    le nombre devient premier avec 5, donc inversible modulo N.
    """
    digits = bytearray()
    block = 0
    while len(digits) < SYMBOLS:
        for byte in hashlib.sha256(f"BookText|{label}|{block}".encode("ascii")).digest():
            if byte < 250 and len(digits) < SYMBOLS:
                digits.append(byte % 25)
        block += 1
    if multiplier and digits[0] % 5 == 0:
        digits[0] += 1
    return from_digits(bytes(digits))


A1 = _constant("a1", True)
B1 = _constant("b1", False)
A2 = _constant("a2", True)
B2 = _constant("b2", False)
A1_INV = pow(A1, -1, N)
A2_INV = pow(A2, -1, N)


def _reverse(x: int) -> int:
    return from_digits(to_digits(x, SYMBOLS)[::-1])


def mix(x: int) -> int:
    """Contenu X ∈ [0, N) → page Y ∈ [0, N), bijection."""
    return (A2 * _reverse((A1 * x + B1) % N) + B2) % N


def unmix(y: int) -> int:
    """Inverse de mix."""
    return (A1_INV * (_reverse((A2_INV * (y - B2)) % N) - B1)) % N


# --- Adresses -----------------------------------------------------------------------------

@dataclass(frozen=True)
class Address:
    hexagon: int
    level: int
    wall: int
    shelf: int
    book: int
    page: int

    def __post_init__(self) -> None:
        for name, value, bound in (("wall", self.wall, WALLS), ("shelf", self.shelf, SHELVES),
                                   ("book", self.book, BOOKS), ("page", self.page, PAGES)):
            if not isinstance(value, int) or not 0 <= value < bound:
                raise ValueError(f"{name} hors de [0, {bound - 1}] : {value!r}")
        for name, value in (("hexagon", self.hexagon), ("level", self.level)):
            if not isinstance(value, int) or isinstance(value, bool):
                raise ValueError(f"{name} doit être un entier : {value!r}")

    def full(self) -> str:
        """Forme complète « hexagone:niveau:mur:étagère:livre:page », en décimal, relue par parse_address."""
        return f"{self.hexagon}:{self.level}:{self.wall}:{self.shelf}:{self.book}:{self.page}"

    def short(self) -> str:
        """Forme courte pour l'écran : grands nombres abrégés, mur, étagère, livre et page comptés depuis 1."""
        return (f"hexagone {_short_number(self.hexagon)} · niveau {_short_number(self.level)}"
                f" · mur {self.wall + 1} · étagère {self.shelf + 1} · livre {self.book + 1}"
                f" · page {self.page + 1}")

    def to_json(self) -> dict:
        return {"hexagon": str(self.hexagon), "level": str(self.level), "wall": self.wall,
                "shelf": self.shelf, "book": self.book, "page": self.page}

    @staticmethod
    def from_json(obj: dict, page_required: bool = True) -> Address:
        if not isinstance(obj, dict):
            raise ValueError(f"adresse attendue sous forme d'objet : {obj!r}")
        return Address(_as_int(obj, "hexagon"), _as_int(obj, "level"), _as_int(obj, "wall"),
                       _as_int(obj, "shelf"), _as_int(obj, "book"),
                       _as_int(obj, "page") if page_required or "page" in obj else 0)


def _as_int(obj: dict, key: str) -> int:
    if key not in obj:
        raise ValueError(f"champ manquant : {key}")
    value = obj[key]
    if isinstance(value, bool):
        raise ValueError(f"{key} doit être un entier : {value!r}")
    if isinstance(value, int):
        return value
    if isinstance(value, float) and value.is_integer():
        return int(value)
    if isinstance(value, str):
        return int(value.strip())
    raise ValueError(f"{key} doit être un entier : {value!r}")


def _short_number(value: int) -> str:
    sign = "-" if value < 0 else ""
    text = str(abs(value))
    if len(text) <= 12:
        return sign + text
    return f"{sign}{text[:4]}…{text[-4:]} ({len(text)} chiffres)"


def parse_address(text: str) -> Address:
    """Lit la forme complète « h:n:m:é:l:p » ou un objet JSON d'adresse."""
    text = text.strip()
    if text.startswith("{"):
        return Address.from_json(json.loads(text))
    parts = text.split(":")
    if len(parts) != 6:
        raise ValueError(f"adresse attendue « hexagone:niveau:mur:étagère:livre:page » : {text!r}")
    return Address(*(int(part) for part in parts))


def zigzag(value: int) -> int:
    return 2 * value if value >= 0 else -2 * value - 1


def unzigzag(code: int) -> int:
    return code // 2 if code % 2 == 0 else -(code + 1) // 2


def _local(wall: int, shelf: int, book: int, page: int) -> int:
    return ((wall * SHELVES + shelf) * BOOKS + book) * PAGES + page


def pack(address: Address) -> int:
    """Adresse → X' (sans borne) ; le contenu de la page est X' mod N."""
    zh, zl = zigzag(address.hexagon), zigzag(address.level)
    count = max(zh.bit_length(), zl.bit_length()) // 4 + 1   # log2(25) > 4 : majorant du nombre de chiffres
    rest = bytearray(2 * count)
    rest[0::2] = to_digits(zh, count)
    rest[1::2] = to_digits(zl, count)
    return from_digits(bytes(rest)) * LOCAL_COUNT + _local(address.wall, address.shelf,
                                                           address.book, address.page)


def unpack(packed: int) -> Address:
    """X' → adresse ; pack(unpack(X')) == X'."""
    rest, local = divmod(packed, LOCAL_COUNT)
    local, page = divmod(local, PAGES)
    local, book = divmod(local, BOOKS)
    wall, shelf = divmod(local, SHELVES)
    digits = to_digits(rest, 2 * (rest.bit_length() // 8 + 1))
    return Address(unzigzag(from_digits(digits[0::2])), unzigzag(from_digits(digits[1::2])),
                   wall, shelf, book, page)


def is_image_book(hexagon: int, level: int, wall: int, shelf: int, book: int) -> bool:
    """Vrai pour un livre sur 50 environ : SHA-256 des coordonnées du livre (sans la page)."""
    zh, zl = zigzag(hexagon), zigzag(level)
    bh = zh.to_bytes((zh.bit_length() + 7) // 8, "little")
    bl = zl.to_bytes((zl.bit_length() + 7) // 8, "little")
    digest = hashlib.sha256(b"BookText|image|" + struct.pack("<II", len(bh), len(bl)) + bh + bl
                            + bytes((wall, shelf, book))).digest()
    return int.from_bytes(digest[:8], "little") % IMAGE_BOOK_ONE_IN == 0


def address_is_image(address: Address) -> bool:
    return is_image_book(address.hexagon, address.level, address.wall, address.shelf, address.book)


# --- Pages --------------------------------------------------------------------------------

def page_digits(address: Address) -> bytes:
    """Les 3200 symboles de la page, en indices 0..24 de l'alphabet (ordre de lecture)."""
    return to_digits(mix(pack(address) % N), SYMBOLS)


def page_text(address: Address) -> str:
    return page_digits(address).translate(_TO_ALPHABET).decode("ascii")


def page_lines(address: Address) -> list[str]:
    text = page_text(address)
    return [text[i * CHARS:(i + 1) * CHARS] for i in range(LINES)]


def locate(content: int, image: bool) -> tuple[Address, int]:
    """Première adresse X' = content + k·N du genre demandé, et le nombre d'essais (k + 1)."""
    packed = content
    tries = 1
    while True:
        address = unpack(packed)
        if address_is_image(address) == image:
            return address, tries
        packed += N
        tries += 1


# --- Texte --------------------------------------------------------------------------------

_LIGATURES = {"œ": "oe", "æ": "ae", "ß": "ss", "k": "c", "q": "c", "w": "v", "y": "i"}


def normalize(text: str) -> str:
    """Ramène un texte à l'alphabet de 25 symboles, 3200 au plus (règles dans l'en-tête du module)."""
    return normalize_all(text)[:SYMBOLS]


def normalize_all(text: str) -> str:
    """Comme normalize, sans limite de longueur."""
    out = []
    for char in unicodedata.normalize("NFD", text.lower()):
        if unicodedata.combining(char):
            continue
        char = _LIGATURES.get(char, char)
        if char.isspace():
            out.append(" ")
        elif all(c in ALPHABET for c in char):
            out.append(char)
    return "".join(out)


def pad(text: str) -> str:
    """Le texte normalisé, complété par des espaces jusqu'à 3200 symboles."""
    return normalize(text).ljust(SYMBOLS)


def search_text(text: str) -> tuple[Address, int]:
    """Adresse d'un livre de texte dont la page montre pad(text), et le nombre d'essais."""
    digits = pad(text).encode("ascii").translate(_FROM_ALPHABET)
    return locate(unmix(from_digits(digits)), image=False)


# --- Images -------------------------------------------------------------------------------

def fit_image(width: int, height: int, rgba: bytes) -> list[tuple[float, float, float]]:
    """Ramène l'image à 50 × 64 pixels en gardant ses proportions, bordée de l'encre 0.

    L'image est d'abord posée sur l'encre 0 (transparence), puis chaque pixel de la page
    moyenne une grille d'au plus 4 × 4 points de sa zone source (réduction) ou reprend le
    point source le plus proche (agrandissement).
    """
    if width <= 0 or height <= 0 or len(rgba) != width * height * 4:
        raise ValueError(f"image {width} × {height} : {len(rgba)} octets reçus, {width * height * 4} attendus")
    scale = min(IMAGE_WIDTH / width, IMAGE_HEIGHT / height)
    fit_w = min(IMAGE_WIDTH, max(1, round(width * scale)))
    fit_h = min(IMAGE_HEIGHT, max(1, round(height * scale)))
    left = (IMAGE_WIDTH - fit_w) // 2
    top = (IMAGE_HEIGHT - fit_h) // 2
    ink = tuple(float(c) for c in PALETTE[0])
    pixels = [ink] * (IMAGE_WIDTH * IMAGE_HEIGHT)
    step_x = min(4, -(-width // fit_w))
    step_y = min(4, -(-height // fit_h))
    for ty in range(fit_h):
        rows = [min(height - 1, int((ty + (j + 0.5) / step_y) * height / fit_h)) for j in range(step_y)]
        for tx in range(fit_w):
            cols = [min(width - 1, int((tx + (i + 0.5) / step_x) * width / fit_w)) for i in range(step_x)]
            r = g = b = 0.0
            for sy in rows:
                row = sy * width
                for sx in cols:
                    o = (row + sx) * 4
                    a = rgba[o + 3] / 255.0
                    r += ink[0] + (rgba[o] - ink[0]) * a
                    g += ink[1] + (rgba[o + 1] - ink[1]) * a
                    b += ink[2] + (rgba[o + 2] - ink[2]) * a
            n = step_x * step_y
            pixels[(top + ty) * IMAGE_WIDTH + left + tx] = (r / n, g / n, b / n)
    return pixels


def quantize(width: int, height: int, rgba: bytes) -> bytes:
    """Les 3200 indices d'encre de l'image ajustée, tramée par Floyd–Steinberg
    (distance euclidienne en RVB, parcours ligne par ligne de gauche à droite)."""
    work = [list(p) for p in fit_image(width, height, rgba)]
    out = bytearray(IMAGE_WIDTH * IMAGE_HEIGHT)
    palette = PALETTE
    for y in range(IMAGE_HEIGHT):
        for x in range(IMAGE_WIDTH):
            i = y * IMAGE_WIDTH + x
            r, g, b = work[i]
            best = 0
            best_d = float("inf")
            for k, (pr, pg, pb) in enumerate(palette):
                d = (r - pr) ** 2 + (g - pg) ** 2 + (b - pb) ** 2
                if d < best_d:
                    best, best_d = k, d
            out[i] = best
            pr, pg, pb = palette[best]
            er, eg, eb = r - pr, g - pg, b - pb
            for dx, dy, w in ((1, 0, 7 / 16), (-1, 1, 3 / 16), (0, 1, 5 / 16), (1, 1, 1 / 16)):
                nx, ny = x + dx, y + dy
                if 0 <= nx < IMAGE_WIDTH and ny < IMAGE_HEIGHT:
                    cell = work[ny * IMAGE_WIDTH + nx]
                    cell[0] += er * w
                    cell[1] += eg * w
                    cell[2] += eb * w
    return bytes(out)


def indices_to_rgb(indices: bytes) -> bytes:
    """Indices d'encre → octets RVB, pixel après pixel."""
    table = [bytes(c) for c in PALETTE]
    return b"".join(table[i] for i in indices)


def search_image(width: int, height: int, rgba: bytes) -> tuple[Address, int]:
    """Adresse d'un livre d'images dont la page montre quantize(image), et le nombre d'essais."""
    return locate(unmix(from_digits(quantize(width, height, rgba))), image=True)


# --- PNG ----------------------------------------------------------------------------------

_PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def decode_png(data: bytes) -> tuple[int, int, bytes]:
    """(largeur, hauteur, RGBA) d'un PNG 8 bits par canal, non entrelacé : niveaux de gris,
    gris + alpha, RVB, RVBA ou palette (avec transparence tRNS). Le JPG se convertit d'abord en PNG."""
    if not data.startswith(_PNG_SIGNATURE):
        raise ValueError("signature PNG absente (le JPG se convertit d'abord en PNG)")
    pos = len(_PNG_SIGNATURE)
    header = None
    plte = b""
    trns = b""
    idat = []
    while pos + 8 <= len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        crc = data[pos + 8 + length:pos + 12 + length]
        if len(body) != length or len(crc) != 4 or zlib.crc32(kind + body) != struct.unpack(">I", crc)[0]:
            raise ValueError(f"bloc PNG {kind!r} tronqué ou corrompu")
        pos += 12 + length
        if kind == b"IHDR":
            header = struct.unpack(">IIBBBBB", body)
        elif kind == b"PLTE":
            plte = body
        elif kind == b"tRNS":
            trns = body
        elif kind == b"IDAT":
            idat.append(body)
        elif kind == b"IEND":
            break
    if header is None:
        raise ValueError("bloc IHDR absent")
    width, height, depth, color, _compression, _filter, interlace = header
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}.get(color)
    if depth != 8 or channels is None or interlace != 0:
        raise ValueError(f"PNG non pris en charge : profondeur {depth}, couleur {color}, entrelacement {interlace}"
                         " (8 bits non entrelacé seulement)")
    raw = zlib.decompress(b"".join(idat))
    stride = width * channels
    if len(raw) != height * (stride + 1):
        raise ValueError("données PNG de taille inattendue")
    pixels = bytearray(height * stride)
    prev = bytearray(stride)
    bpp = channels
    for y in range(height):
        kind = raw[y * (stride + 1)]
        row = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        if kind == 1:
            for i in range(bpp, stride):
                row[i] = (row[i] + row[i - bpp]) & 0xFF
        elif kind == 2:
            row = bytearray((a + b) & 0xFF for a, b in zip(row, prev))
        elif kind == 3:
            for i in range(stride):
                left = row[i - bpp] if i >= bpp else 0
                row[i] = (row[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif kind == 4:
            for i in range(stride):
                a = row[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                row[i] = (row[i] + pred) & 0xFF
        elif kind != 0:
            raise ValueError(f"filtre PNG inconnu : {kind}")
        pixels[y * stride:(y + 1) * stride] = row
        prev = row
    return width, height, _to_rgba(pixels, width * height, color, plte, trns)


def _to_rgba(pixels: bytearray, count: int, color: int, plte: bytes, trns: bytes) -> bytes:
    out = bytearray(count * 4)
    if color == 6:
        return bytes(pixels)
    if color == 2:
        out[0::4], out[1::4], out[2::4] = pixels[0::3], pixels[1::3], pixels[2::3]
        out[3::4] = b"\xff" * count
        if len(trns) == 6:
            key = bytes((trns[1], trns[3], trns[5]))
            for i in range(count):
                if pixels[i * 3:i * 3 + 3] == key:
                    out[i * 4 + 3] = 0
    elif color == 0:
        out[0::4] = out[1::4] = out[2::4] = pixels
        out[3::4] = b"\xff" * count
        if len(trns) == 2:
            for i in range(count):
                if pixels[i] == trns[1]:
                    out[i * 4 + 3] = 0
    elif color == 4:
        out[0::4] = out[1::4] = out[2::4] = pixels[0::2]
        out[3::4] = pixels[1::2]
    else:  # palette
        entries = len(plte) // 3
        alpha = bytes(trns[:entries]).ljust(entries, b"\xff")
        table = [plte[i * 3:i * 3 + 3] + alpha[i:i + 1] for i in range(entries)]
        if any(p >= entries for p in pixels):
            raise ValueError("indice de palette PNG hors de la palette")
        out = bytearray(b"".join(table[p] for p in pixels))
    return bytes(out)


def read_png(path: str) -> tuple[int, int, bytes]:
    with open(path, "rb") as handle:
        return decode_png(handle.read())


# --- Service JSON -------------------------------------------------------------------------

def handle(request: dict) -> dict:
    """Une requête du service → sa réponse (protocole décrit dans le README, section « Recherche inverse »)."""
    if not isinstance(request, dict):
        raise ValueError("requête attendue sous forme d'objet JSON")
    op = request.get("op")
    if op == "ping":
        return {"protocol": PROTOCOL}
    if op == "palette":
        return {"palette": ["#%02x%02x%02x" % c for c in PALETTE], "width": IMAGE_WIDTH, "height": IMAGE_HEIGHT}
    if op == "page":
        address = Address.from_json(request.get("address"))
        digits = page_digits(address)
        image = address_is_image(address)
        response = {"lines": [digits[i * CHARS:(i + 1) * CHARS].translate(_TO_ALPHABET).decode("ascii")
                              for i in range(LINES)],
                    "is_image": image}
        if image or request.get("as_image"):
            response["indices"] = base64.b64encode(digits).decode("ascii")
        return response
    if op == "search_text":
        text = request.get("text")
        if not isinstance(text, str):
            raise ValueError("search_text attend un champ text (chaîne)")
        address, tries = search_text(text)
        return {"address": address.to_json(), "tries": tries}
    if op == "search_image":
        width, height = _as_int(request, "width"), _as_int(request, "height")
        rgba = base64.b64decode(request.get("rgba") or "", validate=True)
        address, tries = search_image(width, height, rgba)
        return {"address": address.to_json(), "tries": tries}
    if op == "is_image_book":
        books = request.get("books")
        if not isinstance(books, list):
            raise ValueError("is_image_book attend un champ books (liste d'adresses de livres)")
        flags = []
        for obj in books:
            a = Address.from_json(obj, page_required=False)
            flags.append(is_image_book(a.hexagon, a.level, a.wall, a.shelf, a.book))
        return {"is_image": flags}
    if op == "display":
        address = Address.from_json(request.get("address"))
        return {"short": address.short(), "full": address.full()}
    raise ValueError(f"opération inconnue : {op!r}")


def serve(source=None, sink=None) -> None:
    """Une requête JSON par ligne sur l'entrée, une réponse JSON par ligne sur la sortie.
    Toute erreur répond {"error": …} sur sa ligne ; le service continue."""
    source = source if source is not None else sys.stdin.buffer   # flux binaires, UTF-8
    sink = sink if sink is not None else sys.stdout.buffer
    for raw in source:
        line = raw.strip()
        if not line:
            continue
        request = None
        try:
            request = json.loads(line.decode("utf-8"))
            response = handle(request)
        except Exception as error:  # le service survit à toute requête
            response = {"error": f"{type(error).__name__}: {error}"}
        if isinstance(request, dict) and "id" in request:
            response["id"] = request["id"]
        payload = json.dumps(response, ensure_ascii=True, separators=(",", ":"))
        sink.write(payload.encode("ascii") + b"\n")
        sink.flush()


# --- Ligne de commande --------------------------------------------------------------------

def _print_address(address: Address, tries: int, as_json: bool) -> None:
    if as_json:
        print(json.dumps({"address": address.to_json(), "tries": tries}))
    else:
        print(address.full())
        print(address.short(), file=sys.stderr)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="babel.py",
        description="Bibliothèque de Babel : page d'une adresse, adresse d'un texte ou d'une image.",
        epilog="Adresse : « hexagone:niveau:mur:étagère:livre:page » (mur 0-3, étagère 0-4, livre 0-31,"
               " page 0-409) ou objet JSON. Images : PNG 8 bits seulement ; convertir d'abord un JPG en PNG"
               " (le jeu, lui, accepte PNG, JPG et WebP).")
    commands = parser.add_subparsers(dest="command", required=True)
    page = commands.add_parser("page", help="affiche les 40 lignes de la page")
    page.add_argument("address")
    text = commands.add_parser("search-text", help="adresse d'un livre de texte montrant ce texte")
    text.add_argument("file", help="fichier texte UTF-8, ou - pour l'entrée standard")
    text.add_argument("--json", action="store_true", help="adresse en JSON")
    image = commands.add_parser("search-image", help="adresse d'un livre d'images montrant cette image (PNG)")
    image.add_argument("file", help="fichier PNG (convertir d'abord un JPG en PNG)")
    image.add_argument("--json", action="store_true", help="adresse en JSON")
    commands.add_parser("serve", help="service JSON ligne à ligne sur l'entrée et la sortie standard")
    args = parser.parse_args(argv)

    try:
        if args.command == "page":
            for line in page_lines(parse_address(args.address)):
                print(line)
        elif args.command == "search-text":
            if args.file == "-":
                content = sys.stdin.buffer.read().decode("utf-8")
            else:
                with open(args.file, encoding="utf-8") as handle:
                    content = handle.read()
            if len(normalize_all(content)) > SYMBOLS:
                print(f"texte tronqué à {SYMBOLS} symboles", file=sys.stderr)
            _print_address(*search_text(content), args.json)
        elif args.command == "search-image":
            _print_address(*search_image(*read_png(args.file)), args.json)
        else:
            serve()
    except (ValueError, OSError) as error:
        print(f"babel.py : {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
