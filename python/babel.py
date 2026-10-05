#!/usr/bin/env python3
"""Bibliothèque de Babel : bijection exacte entre les livres et leurs adresses, dans les deux sens.

Bibliothèque standard seule, Python ≥ 3.10. Le jeu Godot lance `python babel.py serve` et lui parle
en JSON, une ligne par requête (protocole 3, décrit plus bas) ; la ligne de commande sert hors ligne.

Livre
    410 pages de 3200 symboles (40 lignes de 80), soit M = 1 312 000 symboles pris dans l'alphabet
    de 25 symboles « abcdefghijlmnoprstuvxz ,. ». La page p d'un livre est faite des symboles
    p·3200 … p·3200 + 3199 du livre. Il y a exactement B = 25^M livres possibles et chacun existe
    une fois et une seule dans la Bibliothèque. Une page est un nombre de [0, N), N = 25^3200 :
    le symbole i de la page (ordre de lecture) est le chiffre i du nombre en base 25, poids faible
    en premier, lu dans l'alphabet.

Adresse d'un livre
    (hexagone, niveau, mur 0..3, étagère 0..4, livre 0..31) ; hexagone et niveau sont des entiers
    relatifs. Le numéro de page (0..409) se donne à part.

Rang d'une adresse (calculé en chiffres base 25, sans jamais passer par le binaire)
    1. zigzag des relatifs : z(v) = 2v si v ≥ 0, −2v − 1 sinon (0, −1, 1, −2 … → 0, 1, 2, 3 …) ;
    2. cellule C : le chiffre 2i de C (base 25) est le chiffre i de z(hexagone), le chiffre 2i + 1
       celui de z(niveau) ;
    3. emplacement e = (mur·5 + étagère)·32 + livre, de 0 à 639 ;
    4. rang r = 640·C + e.
    Les adresses dont le rang est < B portent chacune un livre, les autres sont des emplacements
    vides ; rang ↔ adresse est une bijection de [0, B) sur les adresses habitées.

Région habitée (finie, immense)
    B mod 640 = 385, donc les galeries C < ⌊B/640⌋ sont pleines ; la galerie C = ⌊B/640⌋ ne porte que
    ses emplacements e < 385 (jusqu'au mur 2, étagère 2, livre 0) ; toutes les galeries au-delà
    (C > ⌊B/640⌋) ont des étagères vides. Toute galerie dont l'hexagone et le niveau ont au plus
    917 045 chiffres décimaux est pleine. Un rang occupe au plus M chiffres base 25 : hexagone et
    niveau d'une adresse prise au hasard ont chacun environ 917 000 chiffres décimaux.

Mélange : rang r → contenu, bijection
    Les 410 pages « brutes » P_0 … P_409 sont les tranches de 3200 chiffres de r (poids faible en
    premier ; P_i est le chiffre i de r en base N). Le contenu F_0 … F_409 se calcule page après page :
        F_0 = mix((P_0 + T(D)) mod N),  D = SHA-256("BookText|book|" + chiffres de P_1 … P_409),
        F_i = mix((P_i + F_{i−1} + K_i) mod N)  pour i = 1 … 409 (chaîne avant),
    où mix est le mélange d'une page (deux tours affines modulo N séparés d'un retournement des
    3200 chiffres, ci-dessous), T(D) = (A3·(D + 1) + B3) mod N (D lu comme entier, octets poids faible
    en premier) et K_i une constante de page tirée de SHA-256. L'empreinte D (« chaîne arrière »,
    un pas de Feistel) fait dépendre la page 0 de toutes les autres pages brutes, et la chaîne avant
    propage la page 0 à toutes les suivantes : changer un seul symbole n'importe où dans le rang
    change entièrement les 410 pages, et deux adresses voisines donnent deux livres sans rapport.
    Inverse : P_i = (unmix(F_i) − F_{i−1} − K_i) mod N pour i ≥ 1 (pages indépendantes), puis
    P_0 = (unmix(F_0) − T(D)) mod N. Lire la page p coûte p + 1 mélanges (pages calculées à la
    demande et gardées en cache) ; la page 0 d'un livre jamais ouvert ne coûte qu'un mélange.

Mélange d'une page : mix(X)
    Y1 = (A1·X + B1) mod N ; R = Y1 aux 3200 chiffres retournés ; Y = (A2·R + B2) mod N.
    Une multiplication modulo 25^n propage les chiffres vers le haut seulement ; le retournement
    entre les deux tours renvoie vers le bas ce que le premier tour a propagé vers le haut, si bien
    que chaque chiffre de la page dépend de tous les chiffres de X. A1, A2, A3, B1, B2, B3 : constantes
    fixes de 3200 chiffres, tirées de SHA-256 (voir _constant) ; A1, A2 et A3 sont premiers avec 5,
    donc inversibles modulo N = 5^6400 (inverses par pow(A, −1, N)).

Livres d'images (propriété du contenu)
    Un livre est un livre d'images si ses deux premiers symboles autres que l'espace sont tous deux
    des signes (« , » ou « . ») ; l'espace ne compte pas, si bien que des espaces en tête ne créent ni
    ne cachent un livre d'images ; un livre qui a moins de deux symboles autres que l'espace est un
    livre de texte. Proportion exacte : (4/625)·Σ_{t=0}^{M−2} (t + 1)/25^t = 1/144 à 10^−1 834 000 près.
    La règle tient au contenu seul ; la bijection ne dépend pas d'elle. Le drapeau se calcule depuis
    l'adresse sans calculer le livre : la page 0 ne coûte qu'un mélange, dont seuls les 12 premiers
    chiffres sont nécessaires (mix_head) ; les 640 drapeaux d'une galerie partagent la cellule.
    Chaque page d'un livre d'images se lit comme une image de 50 × 64 pixels (portrait, pixels carrés) :
    le pixel (x, y) est le symbole y·50 + x, et le symbole d'indice i dans l'alphabet prend l'encre
    PALETTE[i].

Recherche (exacte, une seule adresse par contenu)
    Texte : normalisé (normalize), tronqué à M symboles (avec un avis) et complété par des espaces
    jusqu'à M symboles ; le livre trouvé est l'unique livre qui contient ce texte suivi seulement
    d'espaces, et le texte en occupe les pages 0, 1 … consécutives. Un texte dont les deux premiers
    symboles autres que l'espace sont des signes tombe, par définition, dans un livre d'images (la
    réponse le dit) ; tout autre texte tombe dans un livre de texte.
    Image : la page 0 est l'image tramée (quantize_samples), dont les deux premiers pixels sont pris
    parmi les deux encres des signes (« , » 23 et « . » 24, la plus proche par Floyd–Steinberg) : la
    marque est écrite, l'aller-retour des pixels reste exact. Les pages 1 … 409 sont de l'encre 0.

Image cherchée (image_grid, fit_samples, quantize_samples)
    Une image W × H se lit seulement en ses points de grille, calculés en arithmétique entière
    (aucun flottant, aucun arrondi de bibliothèque) pour que le jeu et la ligne de commande
    prennent les mêmes pixels source :
    fit_w × fit_h = taille ajustée dans 50 × 64, proportions gardées, arrondi moitié vers le haut
    (si 50·H ≤ 64·W : fit_w = 50, fit_h = ⌊(100·H + W) / 2W⌋, sinon fit_h = 64,
    fit_w = ⌊(128·W + H) / 2H⌋ ; puis bornée à [1, 50] × [1, 64]) ;
    step_x = min(4, ⌈W / fit_w⌉), step_y = min(4, ⌈H / fit_h⌉) ;
    colonne k = ⌊(2k + 1)·W / (2·step_x·fit_w)⌋ pour k < fit_w·step_x, lignes de même.
    Le jeu (BookText.image_grid) refait ce calcul et n'envoie que ces points (au plus 200 × 256,
    soit 200 Ko), quelle que soit la taille de l'image ; la ligne de commande les prend dans le PNG
    décodé (sample_image). Chaque point est posé sur l'encre 0 (transparence), chaque pixel de la
    page moyenne ses step_x × step_y points, l'image ajustée est centrée et bordée de l'encre 0,
    puis tramée aux 25 encres par Floyd–Steinberg.

Normalisation d'un texte cherché (normalize)
    minuscules ; accents retirés (décomposition Unicode NFD, marques combinantes ôtées) ;
    œ → oe, æ → ae, ß → ss ; k → c, q → c, w → v, y → i ; tout blanc (espace, tabulation,
    retour à la ligne) → espace ; les autres caractères (chiffres, apostrophes, ! ? ; : …)
    sont retirés. Au-delà de M = 1 312 000 symboles, la suite est ignorée.
Remplissage (pad) : le texte normalisé est complété par des espaces jusqu'à M symboles.

Coordonnées sur le fil : base 25 signée
    Hexagone et niveau voyagent comme chaînes en base 25 : signe « - » facultatif, puis les chiffres
    « 0123456789abcdefghijklmno », poids fort en premier, sans zéro de tête (« 0 » pour zéro) ;
    c'est la notation de int(texte, 25). La bijection travaille sur les chiffres base 25 : cette
    forme se lit et s'écrit en temps linéaire (un caractère par chiffre, 4,64 bits par caractère),
    alors que le décimal ou l'hexadécimal demanderaient une conversion quadratique des ~917 000
    chiffres (avant Python 3.12, plusieurs dizaines de secondes). Un entier JSON est aussi accepté
    (exact jusqu'à 2^53 seulement côté Godot). Le décimal complet reste disponible en ligne de
    commande (chemin lent : ~1 s par coordonnée de 917 000 chiffres à l'écriture, ~3 s à la lecture,
    par le module decimal) ; l'affichage (display) donne signe, nombre de chiffres décimaux, 4
    premiers (par logarithmes) et 4 derniers chiffres (modulo 10^4 : mod 625 par les deux chiffres
    base 25 de poids faible, mod 16 par la somme des chiffres de rang pair et 9 × celle de rang impair)
    sans conversion complète.

Service JSON, protocole 3 (une requête par ligne, une réponse par ligne)
    adresse   {"hexagon": "<base 25>", "level": "<base 25>", "wall": 0-3, "shelf": 0-4, "book": 0-31}
    livre     "address": adresse, ou "key": clé rendue par une réponse précédente (le service garde
              les 256 dernières clés et le contenu des 4 derniers livres ouverts)
    ping           → {"protocol": 3}
    palette        → {"palette": ["#1a1410", … 25 encres], "width": 50, "height": 64}
    book_info      livre → {"key", "exists": true, "is_image": bool, "address", "short"}
                   ou {"exists": false} pour un emplacement vide
    page           livre, "page": 0-409 (ou "page" dans l'adresse, 0 par défaut), "as_image" facultatif
                   → {"key", "page", "lines": [40 chaînes], "is_image": bool,
                      "indices": base64 des 3200 encres 0-24 (livre d'images, ou as_image)}
    pages          livre, "pages": [numéros, 410 au plus], "as_image" facultatif
                   → {"key", "is_image", "pages": [{"page", "lines", "indices"?}, …]}
    search_text    "text" → {"address", "key", "is_image", "text_pages": pages occupées par le texte,
                   "truncated": bool, "notice": chaîne (si tronqué ou livre d'images)}
    search_image   "width", "height" de l'image d'origine, et soit "samples" (base64 : les points de
                   grille seuls, 4 octets RGBA par point, ligne de grille après ligne de grille), soit
                   "rgba" (base64 : l'image complète) → {"address", "key", "is_image": true}
    is_image_book  "books": [adresses] → {"is_image": [bool ou null (emplacement vide)…]}
                   ou "gallery": {"hexagon", "level"} → {"is_image": [640 valeurs]}, dans l'ordre
                   e = (mur·5 + étagère)·32 + livre
    display        "address" (page facultative) → {"short", "hexagon": résumé, "level": résumé} ;
                   résumé = {"sign": -1|0|1, "digits": chiffres décimaux, "lead": 4 premiers,
                   "tail": 4 derniers, "low": 18 derniers (complétés de zéros)} ; "full": true
                   ajoute "full" (décimal complet, chemin lent)
    Un champ "id" facultatif revient tel quel. Toute erreur répond {"error": "…", "code": …} sur sa
    ligne, code parmi bad_request, unknown_op, unknown_key (clé oubliée : renvoyer l'adresse),
    empty_slot (adresse hors de la région habitée), internal ; le service continue.
"""

from __future__ import annotations

import argparse
import base64
import decimal
import hashlib
import json
import math
import struct
import sys
import unicodedata
import zlib
from collections import OrderedDict
from dataclasses import dataclass
from functools import lru_cache

# Les petites conversions int ↔ texte de plus de 4300 chiffres (pages, constantes) restent permises.
if hasattr(sys, "set_int_max_str_digits"):
    sys.set_int_max_str_digits(0)

PROTOCOL = 3
ALPHABET = "abcdefghijlmnoprstuvxz ,."
PAGES = 410
LINES = 40
CHARS = 80
SYMBOLS = LINES * CHARS                  # 3200 symboles par page
BOOK_SYMBOLS = PAGES * SYMBOLS           # M = 1 312 000 symboles par livre
WALLS = 4
SHELVES = 5
BOOKS = 32
SLOTS = WALLS * SHELVES * BOOKS          # 640 emplacements par galerie
N = 25 ** SYMBOLS
IMAGE_WIDTH = 50
IMAGE_HEIGHT = 64
SPACE = ALPHABET.index(" ")              # 22
SIGNS = (ALPHABET.index(","), ALPHABET.index("."))   # 23, 24 : encres de la marque des livres d'images
IMAGE_FILL = 0                           # encre des pages 1 … 409 d'un livre d'images trouvé
MAX_PAGES_PER_REQUEST = PAGES

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
_FROM_INT_STR = bytes.maketrans(_DIGIT_CHARS, bytes(range(25)))
_TO_ALPHABET = bytes.maketrans(bytes(range(25)), ALPHABET.encode("ascii"))
_FROM_ALPHABET = bytes.maketrans(ALPHABET.encode("ascii"), bytes(range(25)))
_POW25: dict[int, int] = {}


class BabelError(ValueError):
    """Erreur de requête ; `code` est rendu tel quel par le service."""
    code = "bad_request"


class EmptySlot(BabelError):
    code = "empty_slot"


class UnknownKey(BabelError):
    code = "unknown_key"


class UnknownOp(BabelError):
    code = "unknown_op"


def _clip(value: object, limit: int = 60) -> str:
    """repr abrégé : un message d'erreur ne recopie pas une coordonnée de 900 000 chiffres."""
    text = repr(value)
    return text if len(text) <= limit else f"{text[:limit // 2]}…{text[-limit // 4:]} ({len(text)} car.)"


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
    """Le nombre dont les chiffres base 25 sont `digits`, poids faible en premier.
    Quadratique au-delà de quelques milliers de chiffres : voir _digits_to_int."""
    if not digits:
        return 0
    return int(bytes(reversed(digits)).translate(_TO_INT_STR), 25)


def _digits_to_int(digits: bytes) -> int:
    """from_digits en diviser pour régner (multiplications seules, sous-quadratique)."""
    if len(digits) <= 2048:
        return from_digits(digits)
    half = 1 << ((len(digits) - 1).bit_length() - 1)
    return _digits_to_int(digits[half:]) * _pow25(half) + _digits_to_int(digits[:half])


def _int_to_digits(value: int) -> bytes:
    """Chiffres base 25 de value ≥ 0, sans zéro de poids fort (b"" pour 0)."""
    if value == 0:
        return b""
    return _trim(to_digits(value, value.bit_length() // 4 + 1))   # log2(25) > 4


def _trim(digits: bytes) -> bytes:
    return digits.rstrip(b"\x00")


# Arithmétique vectorisée sur des suites de chiffres base 25 (octets, poids faible en premier) :
# chaque chiffre occupe un octet d'un grand entier, et les retenues base 25 se propagent par
# l'addition binaire grâce à un biais de 231 = 256 − 25 par octet (l'astuce du DCB). Tout est
# linéaire et se fait en C (int.from_bytes, +, ^, &, bytes.translate) : un rang de 1 312 000
# chiffres se multiplie par 640 en quelques millisecondes, sans conversion binaire ↔ base 25.

_MOD25 = bytes(v % 25 for v in range(256))
_DIV25 = bytes(v // 25 for v in range(256))
_DIV_BY = {m: bytes(min(v // m, 255) for v in range(256)) for m in (2, 4, 8)}


def _rep(byte: int, count: int) -> int:
    return int.from_bytes(bytes((byte,)) * count, "little")


def _d_add(a: bytes, b: bytes, carry: int = 0) -> bytes:
    """a + b + carry (0 ou 1)."""
    n = max(len(a), len(b)) + 1
    x = int.from_bytes(a, "little") + _rep(231, n)     # octet par octet ≤ 255 : pas de retenue
    y = int.from_bytes(b, "little")
    s = x + y + carry
    ones = _rep(1, n)
    carried = ((s ^ x ^ y) >> 8) & ones                # bit 8k : l'octet k a débordé (chiffre ≥ 25)
    return _trim((s - 231 * (ones ^ carried)).to_bytes(n, "little"))


def _d_sub(a: bytes, b: bytes) -> bytes:
    """a − b, pour a ≥ b : a + (25^n − 1 − b) + 1 − 25^n."""
    n = max(len(a), len(b))
    complement = (_rep(24, n) - int.from_bytes(b, "little")).to_bytes(n, "little")
    total = _d_add(a, complement, 1)
    if len(total) <= n:
        raise ValueError("soustraction négative")
    return _trim(total[:n])


def _d_mul_small(a: bytes, k: int) -> bytes:
    """a·k pour 0 ≤ k ≤ 10 (24·10 ≤ 255 : aucun octet ne déborde avant la normalisation)."""
    n = len(a) + 1
    product = (int.from_bytes(a, "little") * k).to_bytes(n, "little")
    return _d_add(product.translate(_MOD25), b"\x00" + product.translate(_DIV25))


def _d_divmod_pow2(a: bytes, m: int) -> tuple[bytes, int]:
    """divmod(a, m) pour m ∈ {2, 4, 8}. Comme 25 ≡ 1 (mod m), le reste de la division longue au
    chiffre i est la somme des chiffres de rang ≥ i, modulo m : sommes de suffixes en log₂(n)
    passes, puis quotient q_i = (25·reste_{i+1} + a_i) // m par table."""
    n = len(a)
    if n == 0:
        return b"", 0
    d = int.from_bytes(a, "little")
    mask = _rep(m - 1, n)
    suffix = d & mask
    shift = 8
    while shift < 8 * n:
        suffix = (suffix + (suffix >> shift)) & mask
        shift <<= 1
    combined = d + 25 * (suffix >> 8)                  # octet i : a_i + 25·reste_{i+1} ≤ 199
    return _trim(combined.to_bytes(n, "little").translate(_DIV_BY[m])), suffix & (m - 1)


def _d_divmod5(a: bytes) -> tuple[bytes, int]:
    """divmod(a, 5) : a = a_0 + 25·a', a // 5 = 5·a' + a_0 // 5."""
    if not a:
        return b"", 0
    return _d_add(_d_mul_small(a[1:], 5), bytes((a[0] // 5,))), a[0] % 5


def _d_mul640(a: bytes) -> bytes:
    return _d_mul_small(_d_mul_small(_d_mul_small(a, 10), 8), 8)


def _d_divmod640(a: bytes) -> tuple[bytes, int]:
    """divmod(a, 640), 640 = 5·8·8·2."""
    q, r0 = _d_divmod5(a)
    q, r1 = _d_divmod_pow2(q, 8)
    q, r2 = _d_divmod_pow2(q, 8)
    q, r3 = _d_divmod_pow2(q, 2)
    return q, 5 * (64 * r3 + 8 * r2 + r1) + r0


# --- Constantes et mélange d'une page -------------------------------------------------------

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
A3 = _constant("a3", True)
B3 = _constant("b3", False)
A1_INV = pow(A1, -1, N)
A2_INV = pow(A2, -1, N)


def _reverse(x: int) -> int:
    return from_digits(to_digits(x, SYMBOLS)[::-1])


def mix(x: int) -> int:
    """Page brute X ∈ [0, N) → page Y ∈ [0, N), bijection."""
    return (A2 * _reverse((A1 * x + B1) % N) + B2) % N


def unmix(y: int) -> int:
    """Inverse de mix."""
    return (A1_INV * (_reverse((A2_INV * (y - B2)) % N) - B1)) % N


def mix_head(x: int, width: int) -> bytes:
    """Les `width` premiers symboles de mix(x), sans calculer le reste : le second tour, modulo
    25^width, ne lit que les `width` chiffres de poids fort du premier tour."""
    return _head_of_first_round((A1 * x + B1) % N, width)


def _head_of_first_round(y1: int, width: int) -> bytes:
    """mix_head à partir du premier tour Y1 = (A1·x + B1) mod N."""
    top = y1 // _pow25(SYMBOLS - width)
    reversed_low = from_digits(to_digits(top, width)[::-1])
    return to_digits((A2 * reversed_low + B2) % _pow25(width), width)


@lru_cache(maxsize=None)
def _page_constant(index: int) -> int:
    """K_i, constante de la page i dans la chaîne avant."""
    return _constant(f"page{index}", False)


# Les trois briques de la chaîne, séparées pour que les tests mutants puissent en retirer une.

def _high_digest(high: bytes) -> bytes:
    """Empreinte D des pages brutes 1 … 409 (leurs chiffres, zéros de poids fort ôtés)."""
    return hashlib.sha256(b"BookText|book|" + _trim(high)).digest()


def _head_offset(digest: bytes) -> int:
    """T(D) = (A3·(D + 1) + B3) mod N, ajouté à la page brute 0 (chaîne arrière)."""
    return (A3 * (int.from_bytes(digest, "little") + 1) + B3) % N


def _link(previous: int, index: int) -> int:
    """Apport de la page précédente F_{i−1} à la page i (chaîne avant)."""
    return previous + _page_constant(index)


# --- Coordonnées ----------------------------------------------------------------------------

def _parse_b25(text: str) -> tuple[bool, bytes]:
    """« -3k0 » → (négatif, chiffres de la valeur absolue, poids faible en premier, sans zéro de tête)."""
    if not isinstance(text, str):
        raise BabelError(f"coordonnée en base 25 attendue (chaîne) : {_clip(text)}")
    if not text.isascii():    # avant lower() : « K » (U+212A, signe kelvin) deviendrait « k »
        raise BabelError(f"coordonnée en base 25 attendue (chiffres ASCII 0-9, a-o) : {_clip(text)}")
    body = text.lower()
    negative = body.startswith("-")
    if body[:1] in ("-", "+"):
        body = body[1:]
    try:
        raw = body.encode("ascii")
    except UnicodeEncodeError:
        raw = b"\xff"
    # Chaque caractère doit être un chiffre « 0-9a-o » : translate laisserait passer tel quel un
    # octet de contrôle (tabulation, 0x00 …) dont la valeur est déjà < 25.
    if not raw or raw.translate(None, _DIGIT_CHARS):
        raise BabelError(f"coordonnée en base 25 attendue (signe facultatif puis chiffres 0-9, a-o) : {_clip(text)}")
    magnitude = _trim(raw.translate(_FROM_INT_STR)[::-1])
    return negative and bool(magnitude), magnitude


def _format_b25(negative: bool, magnitude: bytes) -> str:
    if not magnitude:
        return "0"
    return ("-" if negative else "") + magnitude[::-1].translate(_TO_INT_STR).decode("ascii")


def int_to_b25(value: int) -> str:
    """Entier relatif → forme base 25 du fil (« -3k0 »)."""
    return _format_b25(value < 0, _int_to_digits(abs(value)))


def b25_to_int(text: str) -> int:
    """Forme base 25 → entier relatif (sous-quadratique ; chemin lent pour 900 000 chiffres)."""
    negative, magnitude = _parse_b25(text)
    value = _digits_to_int(magnitude)
    return -value if negative else value


def _canonical(value: object, name: str) -> str:
    if isinstance(value, bool):
        raise BabelError(f"{name} doit être un entier : {value!r}")
    if isinstance(value, int):
        return int_to_b25(value)
    if isinstance(value, str):
        return _format_b25(*_parse_b25(value))
    raise BabelError(f"{name} doit être une chaîne en base 25 ou un entier : {_clip(value)}")


def zigzag(value: int) -> int:
    return 2 * value if value >= 0 else -2 * value - 1


def unzigzag(code: int) -> int:
    return code // 2 if code % 2 == 0 else -(code + 1) // 2


@lru_cache(maxsize=8)
def _code(coordinate: str) -> bytes:
    """Chiffres base 25 de z(coordonnée), calculés sur les chiffres (2·|v|, moins 1 si v < 0)."""
    negative, magnitude = _parse_b25(coordinate)
    doubled = _d_mul_small(magnitude, 2)
    return _d_sub(doubled, b"\x01") if negative else doubled


def _coordinate_of_code(code: bytes) -> str:
    """Inverse de _code. 25 étant impair, la parité d'un nombre est celle de la somme de ses chiffres."""
    if sum(code) % 2 == 0:
        return _format_b25(False, _d_divmod_pow2(code, 2)[0])
    return _format_b25(True, _d_divmod_pow2(_d_add(code, b"\x01"), 2)[0])


def _decimal_context() -> decimal.Context:
    return decimal.Context(prec=decimal.MAX_PREC, Emax=decimal.MAX_EMAX, Emin=decimal.MIN_EMIN,
                           traps=[decimal.InvalidOperation, decimal.Inexact])


_DEC_POW25: dict[int, decimal.Decimal] = {}
_DEC_LEAF = 512


def _dec_pow25(n: int) -> decimal.Decimal:
    if n not in _DEC_POW25:
        _DEC_POW25[n] = decimal.Decimal(25) ** n
    return _DEC_POW25[n]


def b25_to_decimal(text: str) -> str:
    """Forme base 25 → écriture décimale complète. Chemin lent pour les grandes coordonnées :
    le module decimal (multiplication rapide de libmpdec) assemble les chiffres en diviser pour
    régner, ~1 s pour 917 000 chiffres décimaux, là où str(int) serait quadratique avant 3.12."""
    negative, magnitude = _parse_b25(text)
    sign = "-" if negative else ""
    if len(magnitude) <= 1500:
        return sign + str(from_digits(magnitude))

    def assemble(digits: bytes) -> decimal.Decimal:
        if len(digits) <= _DEC_LEAF:
            return decimal.Decimal(from_digits(digits))
        half = 1 << ((len(digits) - 1).bit_length() - 1)
        return assemble(digits[half:]) * _dec_pow25(half) + assemble(digits[:half])

    with decimal.localcontext(_decimal_context()):
        return sign + str(assemble(magnitude))


def decimal_to_b25(text: str) -> str:
    """Écriture décimale → forme base 25 (chemin lent : ~3 s pour 917 000 chiffres)."""
    body = text.strip()
    negative = body.startswith("-")
    if body[:1] in ("-", "+"):
        body = body[1:]
    if not body or not body.isascii() or not body.isdigit():
        raise BabelError(f"entier décimal attendu : {_clip(text)}")
    body = body.lstrip("0")
    if len(body) <= 3000:
        return _format_b25(negative, _int_to_digits(int(body or "0")))

    def split(value: decimal.Decimal, count: int) -> bytes:
        if count <= _DEC_LEAF:
            return to_digits(int(value), count)
        half = 1 << ((count - 1).bit_length() - 1)
        high, low = divmod(value, _dec_pow25(half))
        return split(low, half) + split(high, count - half)

    count = int(len(body) / math.log10(25)) + 2
    with decimal.localcontext(_decimal_context()):
        magnitude = _trim(split(decimal.Decimal(body), count))
    return _format_b25(negative, magnitude)


LOW_DIGITS = 18
_LOW_MOD5 = 5 ** LOW_DIGITS                     # = 25^9
_LOW_BITS = (1 << LOW_DIGITS) - 1               # reste modulo 2^18
_LOW_PERIOD = 1 << (LOW_DIGITS - 3)             # 25 ≡ 1 (mod 8) : ordre de 25 modulo 2^18 = 2^15
_LOW_INVERSE = pow(_LOW_MOD5, -1, 1 << LOW_DIGITS)


def _low_decimal(magnitude: bytes) -> int:
    """|v| mod 10^18, d'après les chiffres base 25 (poids faible en premier), en temps linéaire :
    modulo 5^18 = 25^9, les 9 derniers chiffres ; modulo 2^18, les chiffres pliés sur la période
    2^15 de 25 (sommes de colonnes en un grand entier à mots de 16 bits, puis Horner sur la
    période) ; puis le théorème chinois."""
    mod5 = from_digits(magnitude[:9])
    total = 0
    for start in range(0, len(magnitude), _LOW_PERIOD):
        row = magnitude[start:start + _LOW_PERIOD]
        wide = bytearray(2 * len(row))
        wide[0::2] = row
        total += int.from_bytes(wide, "little")      # mots de 16 bits : ≤ 24 × 21 lignes
    sums = total.to_bytes(2 * _LOW_PERIOD, "little")
    mod2 = 0
    for i in range(2 * min(len(magnitude), _LOW_PERIOD) - 2, -1, -2):
        mod2 = (mod2 * 25 + sums[i] + 256 * sums[i + 1]) & _LOW_BITS
    return mod5 + _LOW_MOD5 * (((mod2 - mod5) * _LOW_INVERSE) & _LOW_BITS)


def coordinate_summary(text: str) -> dict:
    """{"sign", "digits", "lead", "tail", "low"} d'une coordonnée, sans conversion décimale
    complète : nombre de chiffres et 4 premiers par logarithmes (bornes basse et haute de la valeur
    d'après ses 40 chiffres base 25 de tête, marge d'arrondi comprise ; calcul exact quand elles
    ne s'accordent pas, au ras d'une puissance de dix), 4 derniers (tail) et 18 derniers (low,
    complétés de zéros) par restes modulo 5^18 et 2^18 (théorème chinois)."""
    negative, magnitude = _parse_b25(text)
    sign = -1 if negative else (1 if magnitude else 0)
    if len(magnitude) <= 48:
        exact = str(from_digits(magnitude))
        return {"sign": sign, "digits": len(exact), "lead": exact[:4], "tail": exact[-4:],
                "low": exact[-LOW_DIGITS:].rjust(LOW_DIGITS, "0")}
    keep = 40
    top = from_digits(magnitude[-keep:])
    estimates = []
    with decimal.localcontext() as ctx:
        # La valeur est entre top·25^k et (top + 1)·25^k, à 25^−39 près en relatif (~10^−54) : les
        # logarithmes se calculent sur 80 chiffres significatifs (au moins 72 après la virgule) et
        # chaque borne s'écarte encore de 10^−66, bien au-delà de l'erreur d'arrondi. Deux bornes
        # qui donnent le même nombre de chiffres et les mêmes 4 premiers encadrent donc la valeur.
        ctx.prec = 80
        margin = decimal.Decimal(10) ** -66
        base = (len(magnitude) - keep) * decimal.Decimal(25).log10()
        for bound, nudge in ((top, -margin), (top + 1, margin)):
            logarithm = decimal.Decimal(bound).log10() + base + nudge
            exponent = int(logarithm)
            estimates.append((exponent + 1, str(int(decimal.Decimal(10) ** (logarithm - exponent + 3)))))
    if estimates[0] != estimates[1]:    # valeur au ras d'une puissance de 10 : calcul exact (lent)
        exact = b25_to_decimal(_format_b25(False, magnitude))
        estimates[0] = (len(exact), exact[:4])
    low = f"{_low_decimal(magnitude):0{LOW_DIGITS}d}"
    return {"sign": sign, "digits": estimates[0][0], "lead": estimates[0][1], "tail": low[-4:], "low": low}


def short_coordinate(text: str) -> str:
    """Forme d'écran : décimal complet jusqu'à 12 chiffres, sinon « 1909…0195 (917049 chiffres) »."""
    summary = coordinate_summary(text)
    sign = "-" if summary["sign"] < 0 else ""
    if summary["digits"] <= 12:
        return sign + str(b25_to_int(text) * (-1 if summary["sign"] < 0 else 1))
    return f"{sign}{summary['lead']}…{summary['tail']} ({summary['digits']} chiffres)"


# --- Adresses -------------------------------------------------------------------------------

@dataclass(frozen=True)
class Address:
    """Adresse d'un livre. hexagon et level sont gardés sous forme base 25 canonique (voir l'en-tête) ;
    le constructeur accepte aussi des entiers Python."""
    hexagon: str
    level: str
    wall: int
    shelf: int
    book: int

    def __post_init__(self) -> None:
        for name, value, bound in (("wall", self.wall, WALLS), ("shelf", self.shelf, SHELVES),
                                   ("book", self.book, BOOKS)):
            if not isinstance(value, int) or isinstance(value, bool) or not 0 <= value < bound:
                raise BabelError(f"{name} hors de [0, {bound - 1}] : {value!r}")
        object.__setattr__(self, "hexagon", _canonical(self.hexagon, "hexagon"))
        object.__setattr__(self, "level", _canonical(self.level, "level"))

    @property
    def slot(self) -> int:
        """Emplacement e = (mur·5 + étagère)·32 + livre."""
        return (self.wall * SHELVES + self.shelf) * BOOKS + self.book

    @staticmethod
    def at_slot(hexagon: object, level: object, slot: int) -> Address:
        wall, rest = divmod(slot, SHELVES * BOOKS)
        shelf, book = divmod(rest, BOOKS)
        return Address(hexagon, level, wall, shelf, book)

    def hexagon_int(self) -> int:
        return b25_to_int(self.hexagon)

    def level_int(self) -> int:
        return b25_to_int(self.level)

    def compact(self, page: int | None = None) -> str:
        """« b25:hexagone:niveau:mur:étagère:livre[:page] », hexagone et niveau en base 25 (rapide)."""
        tail = "" if page is None else f":{page}"
        return f"b25:{self.hexagon}:{self.level}:{self.wall}:{self.shelf}:{self.book}{tail}"

    def full(self, page: int | None = None) -> str:
        """« hexagone:niveau:mur:étagère:livre[:page] » en décimal, relue par parse_address.
        Chemin lent pour une adresse trouvée (quelques secondes, 1,8 million de chiffres)."""
        tail = "" if page is None else f":{page}"
        return (f"{b25_to_decimal(self.hexagon)}:{b25_to_decimal(self.level)}"
                f":{self.wall}:{self.shelf}:{self.book}{tail}")

    def short(self, page: int | None = None) -> str:
        """Forme courte pour l'écran : grands nombres abrégés, mur, étagère, livre et page comptés depuis 1."""
        text = (f"hexagone {short_coordinate(self.hexagon)} · niveau {short_coordinate(self.level)}"
                f" · mur {self.wall + 1} · étagère {self.shelf + 1} · livre {self.book + 1}")
        return text if page is None else f"{text} · page {page + 1}"

    def key(self) -> str:
        """Clé courte du livre pour le service (20 chiffres hexadécimaux de SHA-256)."""
        return hashlib.sha256(self.compact().encode("ascii")).hexdigest()[:20]

    def to_json(self) -> dict:
        return {"hexagon": self.hexagon, "level": self.level, "wall": self.wall,
                "shelf": self.shelf, "book": self.book}

    @staticmethod
    def from_json(obj: object) -> Address:
        if not isinstance(obj, dict):
            raise BabelError(f"adresse attendue sous forme d'objet : {_clip(obj)}")
        return Address(_as_coordinate(obj, "hexagon"), _as_coordinate(obj, "level"),
                       _as_int(obj, "wall"), _as_int(obj, "shelf"), _as_int(obj, "book"))


def _as_int(obj: dict, key: str) -> int:
    if key not in obj:
        raise BabelError(f"champ manquant : {key}")
    value = obj[key]
    if isinstance(value, bool):
        raise BabelError(f"{key} doit être un entier : {value!r}")
    if isinstance(value, int):
        return value
    if isinstance(value, float) and value.is_integer():
        return int(value)
    if isinstance(value, str) and value.strip().lstrip("+-").isdigit() and len(value) < 30:
        return int(value.strip())
    raise BabelError(f"{key} doit être un entier : {_clip(value)}")


def _as_coordinate(obj: dict, key: str) -> object:
    if key not in obj:
        raise BabelError(f"champ manquant : {key}")
    value = obj[key]
    if isinstance(value, float) and value.is_integer() and abs(value) <= 2 ** 53:
        return int(value)
    return value


def _check_page(page: object) -> int:
    if not isinstance(page, int) or isinstance(page, bool) or not 0 <= page < PAGES:
        raise BabelError(f"page hors de [0, {PAGES - 1}] : {_clip(page)}")
    return page


def parse_address(text: str) -> tuple[Address, int | None]:
    """Lit « hexagone:niveau:mur:étagère:livre[:page] » (décimal), la même forme précédée de « b25: »
    (hexagone et niveau en base 25), ou un objet JSON d'adresse (page facultative).
    Rend (adresse, page ou None)."""
    text = text.strip()
    if text.startswith("{"):
        obj = json.loads(text)
        page = _check_page(_as_int(obj, "page")) if isinstance(obj, dict) and "page" in obj else None
        return Address.from_json(obj), page
    base25 = text[:4].lower() == "b25:"
    parts = (text[4:] if base25 else text).split(":")
    if len(parts) not in (5, 6):
        raise BabelError("adresse attendue « hexagone:niveau:mur:étagère:livre[:page] »"
                         f" (ou « b25:… ») : {_clip(text)}")
    try:
        numbers = [int(part) for part in parts[2:]]
    except ValueError:
        raise BabelError(f"mur, étagère, livre et page sont des entiers : {_clip(text)}") from None
    hexagon, level = (parts[0], parts[1]) if base25 else (decimal_to_b25(parts[0]), decimal_to_b25(parts[1]))
    address = Address(hexagon, level, *numbers[:3])
    return address, (_check_page(numbers[3]) if len(numbers) == 4 else None)


# --- Région : adresse ↔ rang -----------------------------------------------------------------

def _cell(hexagon: str, level: str) -> bytes:
    """Chiffres base 25 de la cellule C : ceux de z(hexagone) et z(niveau) entrelacés."""
    zh, zl = _code(hexagon), _code(level)
    count = max(len(zh), len(zl))
    out = bytearray(2 * count)
    out[0::2] = zh.ljust(count, b"\x00")
    out[1::2] = zl.ljust(count, b"\x00")
    return _trim(bytes(out))


def book_rank(address: Address) -> bytes | None:
    """Chiffres base 25 du rang r = 640·C + e (poids faible en premier), ou None si r ≥ B
    (emplacement vide, hors de la région habitée)."""
    cell = _cell(address.hexagon, address.level)
    if len(cell) > BOOK_SYMBOLS:
        return None
    rank = _d_add(_d_mul640(cell), _int_to_digits(address.slot))
    return rank if len(rank) <= BOOK_SYMBOLS else None


def address_of_rank(rank: bytes) -> Address:
    """Inverse de book_rank, pour un rang < B."""
    rank = _trim(rank)
    if len(rank) > BOOK_SYMBOLS:
        raise BabelError("rang hors de [0, B)")
    cell, slot = _d_divmod640(rank)
    return Address.at_slot(_coordinate_of_code(_trim(cell[0::2])), _coordinate_of_code(_trim(cell[1::2])), slot)


def is_valid(address: Address) -> bool:
    """Vrai si l'emplacement porte un livre (rang < B)."""
    return book_rank(address) is not None


# --- Livres -----------------------------------------------------------------------------------

def _image_flag(symbols: bytes) -> bool | None:
    """Règle des livres d'images sur un début de livre : None s'il y a moins de deux symboles
    autres que l'espace (il faut lire plus loin)."""
    marks = symbols.replace(bytes((SPACE,)), b"")
    if len(marks) < 2:
        return None
    return marks[0] in SIGNS and marks[1] in SIGNS


def content_is_image(digits: bytes) -> bool:
    """La règle sur un contenu entier (ou un début de contenu suffisant)."""
    return bool(_image_flag(digits))


class Book:
    """Contenu d'un livre, page par page à la demande (chaîne avant), gardé en mémoire.
    `rank` : chiffres base 25 du rang ; `pages` : contenu F_0 … déjà connu (recherche)."""

    def __init__(self, rank: bytes, address: Address | None = None, pages: list[int] | None = None):
        self.rank = _trim(rank)
        if len(self.rank) > BOOK_SYMBOLS:
            raise BabelError("rang hors de [0, B)")
        self.address = address
        self._pages: list[int] = list(pages or [])
        self._image: bool | None = None

    @staticmethod
    def at(address: Address) -> Book:
        rank = book_rank(address)
        if rank is None:
            raise EmptySlot(f"emplacement vide : hors de la région habitée ({address.short()})")
        return Book(rank, address)

    def raw_page(self, index: int) -> int:
        """Page brute P_i : la tranche i de 3200 chiffres du rang."""
        return from_digits(self.rank[index * SYMBOLS:(index + 1) * SYMBOLS])

    def number(self, page: int) -> int:
        """F_page, en calculant au besoin les pages précédentes."""
        _check_page(page)
        while len(self._pages) <= page:
            index = len(self._pages)
            if index == 0:
                x = self.raw_page(0) + _head_offset(_high_digest(self.rank[SYMBOLS:]))
            else:
                x = self.raw_page(index) + _link(self._pages[-1], index)
            self._pages.append(mix(x % N))
        return self._pages[page]

    def digits(self, page: int) -> bytes:
        """Les 3200 symboles de la page, en indices 0..24 de l'alphabet (ordre de lecture)."""
        return to_digits(self.number(page), SYMBOLS)

    def text(self, page: int) -> str:
        return self.digits(page).translate(_TO_ALPHABET).decode("ascii")

    def lines(self, page: int) -> list[str]:
        text = self.text(page)
        return [text[i * CHARS:(i + 1) * CHARS] for i in range(LINES)]

    def content(self) -> bytes:
        """Les 1 312 000 symboles du livre (indices 0..24)."""
        return b"".join(self.digits(p) for p in range(PAGES))

    @property
    def computed_pages(self) -> int:
        return len(self._pages)

    @property
    def is_image(self) -> bool:
        if self._image is None:
            seen = b""
            for page in range(PAGES):
                seen += self.digits(page).replace(bytes((SPACE,)), b"")
                if len(seen) >= 2:
                    break
            self._image = bool(_image_flag(seen))
        return self._image


def _pages_of_content(digits: bytes) -> list[int]:
    """Contenu (M indices) → F_0 … F_409 ; les pages identiques (espaces) ne se convertissent qu'une fois."""
    if len(digits) != BOOK_SYMBOLS:
        raise BabelError(f"contenu de {BOOK_SYMBOLS} symboles attendu : {len(digits)}")
    seen: dict[bytes, int] = {}
    pages = []
    for p in range(PAGES):
        chunk = digits[p * SYMBOLS:(p + 1) * SYMBOLS]
        if chunk not in seen:
            seen[chunk] = from_digits(chunk)
        pages.append(seen[chunk])
    return pages


def rank_of_pages(pages: list[int]) -> bytes:
    """Contenu F_0 … F_409 → rang (inverse du mélange)."""
    unmixed: dict[int, int] = {}
    high = []
    for index in range(1, PAGES):
        f = pages[index]
        if f not in unmixed:
            unmixed[f] = unmix(f)
        high.append(to_digits((unmixed[f] - _link(pages[index - 1], index)) % N, SYMBOLS))
    high_digits = b"".join(high)
    first = (unmix(pages[0]) - _head_offset(_high_digest(high_digits))) % N
    return _trim(to_digits(first, SYMBOLS) + high_digits)


def book_of_content(digits: bytes) -> Book:
    """L'unique livre de ce contenu (M indices 0..24), son adresse et ses pages déjà connues."""
    pages = _pages_of_content(digits)
    rank = rank_of_pages(pages)
    return Book(rank, address_of_rank(rank), pages)


_HEAD = 12


def _flag_from_first_round(y1: int, rank) -> bool:
    """Drapeau d'image depuis le premier tour Y1 de la page 0 ; `rank()` donne le rang pour lire
    le livre entier dans le cas (≈ 25^−10) où les 12 premiers symboles comptent moins de deux
    non-espaces."""
    flag = _image_flag(_head_of_first_round(y1, _HEAD))
    if flag is None:
        flag = Book(rank()).is_image
    return flag


def is_image_book(hexagon: object, level: object, wall: int, shelf: int, book: int) -> bool | None:
    """Vrai pour un livre d'images, faux pour un livre de texte, None pour un emplacement vide.
    Un seul mélange partiel (mix_head) : le livre n'est pas calculé."""
    rank = book_rank(Address(hexagon, level, wall, shelf, book))
    if rank is None:
        return None
    x = (from_digits(rank[:SYMBOLS]) + _head_offset(_high_digest(rank[SYMBOLS:]))) % N
    return _flag_from_first_round((A1 * x + B1) % N, lambda: rank)


def gallery_image_flags(hexagon: object, level: object) -> list[bool | None]:
    """Les 640 drapeaux d'une galerie, dans l'ordre des emplacements e.
    r = 640·C + e = (640·C_haut + retenue)·N + (640·C_bas + e) mod N : la partie haute, et donc
    l'empreinte D, ne change qu'avec la retenue (une ou deux valeurs par galerie) ; d'un
    emplacement au suivant, la page brute 0 croît de 1 et le premier tour Y1 de A1 (mod N)."""
    cell = _cell(_canonical(hexagon, "hexagon"), _canonical(level, "level"))
    if len(cell) > BOOK_SYMBOLS:
        return [None] * SLOTS
    low = 640 * from_digits(cell[:SYMBOLS])
    high_base = _d_mul640(cell[SYMBOLS:])
    by_carry: dict[int, tuple[bytes, int | None]] = {}
    flags: list[bool | None] = []
    previous = None          # (retenue, page brute 0, Y1) de l'emplacement précédent
    for slot in range(SLOTS):
        carry, raw0 = divmod(low + slot, N)
        if carry not in by_carry:
            high = _d_add(high_base, _int_to_digits(carry))
            valid = len(high) <= BOOK_SYMBOLS - SYMBOLS
            by_carry[carry] = (high, _head_offset(_high_digest(high)) if valid else None)
        high, offset = by_carry[carry]
        if offset is None:
            flags.append(None)
            continue
        if previous is not None and previous[0] == carry and previous[1] + 1 == raw0:
            y1 = previous[2] + A1
            if y1 >= N:
                y1 -= N
        else:
            y1 = (A1 * ((raw0 + offset) % N) + B1) % N
        previous = (carry, raw0, y1)
        flags.append(_flag_from_first_round(y1, lambda raw0=raw0, high=high: to_digits(raw0, SYMBOLS) + high))
    return flags


def address_is_image(address: Address) -> bool | None:
    return is_image_book(address.hexagon, address.level, address.wall, address.shelf, address.book)


# Lecture simple depuis Python : un petit cache de livres partagé (le service a le sien).

def _default_library() -> Library:
    global _LIBRARY
    if _LIBRARY is None:
        _LIBRARY = Library()
    return _LIBRARY


_LIBRARY: Library | None = None


def page_digits(address: Address, page: int) -> bytes:
    """Les 3200 symboles de la page `page` du livre, en indices 0..24 de l'alphabet."""
    return _default_library().book(address).digits(page)


def page_text(address: Address, page: int) -> str:
    return page_digits(address, page).translate(_TO_ALPHABET).decode("ascii")


def page_lines(address: Address, page: int) -> list[str]:
    text = page_text(address, page)
    return [text[i * CHARS:(i + 1) * CHARS] for i in range(LINES)]


# --- Texte --------------------------------------------------------------------------------

_LIGATURES = {"œ": "oe", "æ": "ae", "ß": "ss", "k": "c", "q": "c", "w": "v", "y": "i"}


def normalize(text: str) -> str:
    """Ramène un texte à l'alphabet de 25 symboles, M au plus (règles dans l'en-tête du module)."""
    return normalize_all(text)[:BOOK_SYMBOLS]


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
    """Le texte normalisé, complété par des espaces jusqu'à M symboles (le livre entier)."""
    return normalize(text).ljust(BOOK_SYMBOLS)


@dataclass
class Found:
    """Résultat d'une recherche : l'adresse unique, le livre (pages déjà connues) et les avis."""
    address: Address
    book: Book
    text_pages: int = 1
    truncated: bool = False

    @property
    def is_image(self) -> bool:
        return self.book.is_image

    def notice(self) -> str | None:
        notes = []
        if self.truncated:
            notes.append(f"texte tronqué à {BOOK_SYMBOLS} symboles (un livre)")
        if self.text_pages and self.is_image:
            notes.append("le texte commence par deux signes (espaces non comptés) : c'est un livre d'images")
        return " ; ".join(notes) or None


def search_text(text: str) -> Found:
    """L'unique livre qui contient pad(text) : le texte, puis des espaces jusqu'à la fin du livre."""
    normalized = normalize_all(text)
    truncated = len(normalized) > BOOK_SYMBOLS
    normalized = normalized[:BOOK_SYMBOLS]
    digits = normalized.ljust(BOOK_SYMBOLS).encode("ascii").translate(_FROM_ALPHABET)
    book = book_of_content(digits)
    return Found(book.address, book, -(-len(normalized) // SYMBOLS), truncated)

# --- Images -------------------------------------------------------------------------------

def image_grid(width: int, height: int) -> tuple[int, int, list[int], list[int]]:
    """Grille d'échantillonnage d'une image width × height : (fit_w, fit_h, colonnes, lignes).

    Arithmétique entière seule, reproduite à l'identique par BookText.image_grid dans le jeu :
    l'image ajustée occupe fit_w × fit_h pixels de la page (proportions gardées, arrondi au plus
    proche, moitié vers le haut) ; chaque pixel de la page lit step_x × step_y points source,
    step = min(4, ⌈côté source / côté ajusté⌉). Le point k (k = tx·step_x + i) d'un axe est la
    colonne ⌊(2k + 1)·width / (2·step_x·fit_w)⌋ : le centre du k-ième sous-intervalle, arrondi
    vers le bas. Au plus 200 colonnes et 256 lignes, quelle que soit la taille de l'image.
    """
    if width <= 0 or height <= 0:
        raise ValueError(f"image {width} × {height} : dimensions positives attendues")
    if IMAGE_WIDTH * height <= IMAGE_HEIGHT * width:   # la largeur borne
        fit_w = IMAGE_WIDTH
        fit_h = min(IMAGE_HEIGHT, max(1, (2 * height * IMAGE_WIDTH + width) // (2 * width)))
    else:                                              # la hauteur borne
        fit_h = IMAGE_HEIGHT
        fit_w = min(IMAGE_WIDTH, max(1, (2 * width * IMAGE_HEIGHT + height) // (2 * height)))
    step_x = min(4, -(-width // fit_w))
    step_y = min(4, -(-height // fit_h))
    cols = [(2 * k + 1) * width // (2 * step_x * fit_w) for k in range(fit_w * step_x)]
    rows = [(2 * k + 1) * height // (2 * step_y * fit_h) for k in range(fit_h * step_y)]
    return fit_w, fit_h, cols, rows


def sample_image(width: int, height: int, rgba: bytes) -> bytes:
    """Les points de la grille (image_grid) pris dans l'image RGBA complète : 4 octets par point,
    ligne de grille après ligne de grille. C'est ce que le jeu envoie au service (champ samples)."""
    if width <= 0 or height <= 0 or len(rgba) != width * height * 4:
        raise ValueError(f"image {width} × {height} : {len(rgba)} octets reçus, {width * height * 4} attendus")
    _fit_w, _fit_h, cols, rows = image_grid(width, height)
    stride = width * 4
    out = bytearray()
    for sy in rows:
        line = rgba[sy * stride:(sy + 1) * stride]
        out += b"".join(line[sx * 4:sx * 4 + 4] for sx in cols)
    return bytes(out)


def fit_samples(width: int, height: int, samples: bytes) -> list[tuple[float, float, float]]:
    """Ramène l'image à 50 × 64 pixels en gardant ses proportions, bordée de l'encre 0, à partir
    de ses seuls points de grille (sample_image).

    Chaque point est d'abord posé sur l'encre 0 (transparence), puis chaque pixel de la page
    moyenne ses step_x × step_y points (au plus 4 × 4 en réduction, un seul point source, le plus
    proche, en agrandissement).
    """
    fit_w, fit_h, cols, rows = image_grid(width, height)
    if len(samples) != len(cols) * len(rows) * 4:
        raise ValueError(f"image {width} × {height} : {len(samples)} octets d'échantillons reçus,"
                         f" {len(cols) * len(rows) * 4} attendus ({len(cols)} × {len(rows)} points)")
    step_x = len(cols) // fit_w
    step_y = len(rows) // fit_h
    stride = len(cols) * 4
    left = (IMAGE_WIDTH - fit_w) // 2
    top = (IMAGE_HEIGHT - fit_h) // 2
    ink = tuple(float(c) for c in PALETTE[0])
    pixels = [ink] * (IMAGE_WIDTH * IMAGE_HEIGHT)
    n = step_x * step_y
    for ty in range(fit_h):
        for tx in range(fit_w):
            r = g = b = 0.0
            for j in range(step_y):
                o = (ty * step_y + j) * stride + tx * step_x * 4
                for _i in range(step_x):
                    a = samples[o + 3] / 255.0
                    r += ink[0] + (samples[o] - ink[0]) * a
                    g += ink[1] + (samples[o + 1] - ink[1]) * a
                    b += ink[2] + (samples[o + 2] - ink[2]) * a
                    o += 4
            pixels[(top + ty) * IMAGE_WIDTH + left + tx] = (r / n, g / n, b / n)
    return pixels


def fit_image(width: int, height: int, rgba: bytes) -> list[tuple[float, float, float]]:
    """fit_samples sur l'image RGBA complète (ligne de commande, PNG décodé)."""
    return fit_samples(width, height, sample_image(width, height, rgba))


def quantize_samples(width: int, height: int, samples: bytes, reserve: int = 0) -> bytes:
    """Les 3200 indices d'encre de l'image ajustée, tramée par Floyd–Steinberg
    (distance euclidienne en RVB, parcours ligne par ligne de gauche à droite).
    Les `reserve` premiers pixels ne prennent que les encres des signes (SIGNS) : c'est la marque
    des livres d'images, écrite par la recherche d'image (reserve = 2)."""
    work = [list(p) for p in fit_samples(width, height, samples)]
    out = bytearray(IMAGE_WIDTH * IMAGE_HEIGHT)
    palette = PALETTE
    every = tuple(enumerate(palette))
    marks = tuple((k, palette[k]) for k in SIGNS)
    for y in range(IMAGE_HEIGHT):
        for x in range(IMAGE_WIDTH):
            i = y * IMAGE_WIDTH + x
            r, g, b = work[i]
            best = 0
            best_d = float("inf")
            for k, (pr, pg, pb) in (marks if i < reserve else every):
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


def quantize(width: int, height: int, rgba: bytes, reserve: int = 0) -> bytes:
    """quantize_samples sur l'image RGBA complète."""
    return quantize_samples(width, height, sample_image(width, height, rgba), reserve)


MARK_PIXELS = 2


def search_samples(width: int, height: int, samples: bytes) -> Found:
    """L'unique livre dont la page 0 montre quantize_samples(…, reserve=2) (marque des livres
    d'images écrite dans les deux premiers pixels) et dont les pages 1 … 409 sont d'encre 0."""
    page = quantize_samples(width, height, samples, MARK_PIXELS)
    book = book_of_content(page + bytes((IMAGE_FILL,)) * (BOOK_SYMBOLS - SYMBOLS))
    return Found(book.address, book, 0, False)


def search_image(width: int, height: int, rgba: bytes) -> Found:
    """search_samples sur l'image RGBA complète (ligne de commande, PNG décodé)."""
    return search_samples(width, height, sample_image(width, height, rgba))


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

class Library:
    """État du service : contenu des derniers livres ouverts (LRU) et clés courtes des adresses."""

    def __init__(self, books: int = 4, keys: int = 256):
        self.capacity = books
        self.key_capacity = keys
        self._books: OrderedDict[Address, Book] = OrderedDict()
        self._keys: OrderedDict[str, Address] = OrderedDict()

    def remember(self, address: Address) -> str:
        key = address.key()
        self._keys[key] = address
        self._keys.move_to_end(key)
        while len(self._keys) > self.key_capacity:
            self._keys.popitem(last=False)
        return key

    def resolve(self, request: dict, field: str = "address") -> Address:
        """L'adresse d'une requête : champ "key" (clé connue) ou champ `field` (objet d'adresse)."""
        if "key" in request:
            key = request["key"]
            if not isinstance(key, str) or key not in self._keys:
                raise UnknownKey(f"clé inconnue ou oubliée : {_clip(key)} (renvoyer l'adresse)")
            self._keys.move_to_end(key)
            return self._keys[key]
        return Address.from_json(request.get(field))

    def book(self, address: Address) -> Book:
        book = self._books.get(address)
        if book is None:
            book = Book.at(address)
            self.adopt(book)
        else:
            self._books.move_to_end(address)
        return book

    def adopt(self, book: Book) -> None:
        """Garde un livre dont le contenu est (en partie) connu, par exemple trouvé par une recherche."""
        self._books[book.address] = book
        self._books.move_to_end(book.address)
        while len(self._books) > self.capacity:
            self._books.popitem(last=False)


def _page_response(book: Book, page: int, as_image: bool) -> dict:
    digits = book.digits(page)
    response = {"page": page,
                "lines": [digits[i * CHARS:(i + 1) * CHARS].translate(_TO_ALPHABET).decode("ascii")
                          for i in range(LINES)]}
    if as_image or book.is_image:
        response["indices"] = base64.b64encode(digits).decode("ascii")
    return response


def _found_response(found: Found, library: Library) -> dict:
    library.adopt(found.book)
    return {"address": found.address.to_json(), "key": library.remember(found.address),
            "is_image": found.is_image}


def handle(request: object, library: Library | None = None) -> dict:
    """Une requête du service → sa réponse (protocole 3, décrit dans l'en-tête du module)."""
    library = library if library is not None else _default_library()
    if not isinstance(request, dict):
        raise BabelError("requête attendue sous forme d'objet JSON")
    op = request.get("op")
    if op == "ping":
        return {"protocol": PROTOCOL}
    if op == "palette":
        return {"palette": ["#%02x%02x%02x" % c for c in PALETTE], "width": IMAGE_WIDTH, "height": IMAGE_HEIGHT}
    if op == "book_info":
        address = library.resolve(request)
        if not is_valid(address):
            return {"exists": False}
        return {"key": library.remember(address), "exists": True, "is_image": address_is_image(address),
                "address": address.to_json(), "short": address.short()}
    if op == "page":
        address = library.resolve(request)
        if "page" in request:
            page = request["page"]
        else:
            raw = request.get("address")
            page = raw.get("page", 0) if isinstance(raw, dict) else 0
        page = _check_page(page)
        book = library.book(address)
        response = _page_response(book, page, bool(request.get("as_image")))
        response.update(key=library.remember(address), is_image=book.is_image)
        return response
    if op == "pages":
        address = library.resolve(request)
        numbers = request.get("pages")
        if not isinstance(numbers, list) or not numbers or len(numbers) > MAX_PAGES_PER_REQUEST:
            raise BabelError(f"pages attend une liste de 1 à {MAX_PAGES_PER_REQUEST} numéros de page")
        numbers = [_check_page(p) for p in numbers]
        book = library.book(address)
        as_image = bool(request.get("as_image"))
        return {"key": library.remember(address), "is_image": book.is_image,
                "pages": [_page_response(book, p, as_image) for p in numbers]}
    if op == "search_text":
        text = request.get("text")
        if not isinstance(text, str):
            raise BabelError("search_text attend un champ text (chaîne)")
        found = search_text(text)
        response = _found_response(found, library)
        response.update(text_pages=found.text_pages, truncated=found.truncated)
        if found.notice():
            response["notice"] = found.notice()
        return response
    if op == "search_image":
        width, height = _as_int(request, "width"), _as_int(request, "height")
        if ("samples" in request) == ("rgba" in request):
            raise BabelError("search_image attend samples (points de grille) ou rgba (image complète), l'un des deux")
        if "samples" in request:
            found = search_samples(width, height, base64.b64decode(request.get("samples") or "", validate=True))
        else:
            found = search_image(width, height, base64.b64decode(request.get("rgba") or "", validate=True))
        return _found_response(found, library)
    if op == "is_image_book":
        if "gallery" in request:
            gallery = request["gallery"]
            if not isinstance(gallery, dict):
                raise BabelError("gallery attend un objet {hexagon, level}")
            return {"is_image": gallery_image_flags(_as_coordinate(gallery, "hexagon"),
                                                    _as_coordinate(gallery, "level"))}
        books = request.get("books")
        if not isinstance(books, list):
            raise BabelError("is_image_book attend books (liste d'adresses de livres) ou gallery")
        return {"is_image": [address_is_image(Address.from_json(obj)) for obj in books]}
    if op == "display":
        address = library.resolve(request)
        raw = request.get("address")
        page = raw.get("page") if isinstance(raw, dict) and "page" in raw else request.get("page")
        page = None if page is None else _check_page(page)
        response = {"short": address.short(page), "hexagon": coordinate_summary(address.hexagon),
                    "level": coordinate_summary(address.level)}
        if request.get("full"):
            response["full"] = address.full(page)
        return response
    raise UnknownOp(f"opération inconnue : {_clip(op)}")


def serve(source=None, sink=None, library: Library | None = None) -> None:
    """Une requête JSON par ligne sur l'entrée, une réponse JSON par ligne sur la sortie.
    Toute erreur répond {"error": …, "code": …} sur sa ligne ; le service continue."""
    source = source if source is not None else sys.stdin.buffer   # flux binaires, UTF-8
    sink = sink if sink is not None else sys.stdout.buffer
    library = library if library is not None else Library()
    for raw in source:
        line = raw.strip()
        if not line:
            continue
        request = None
        try:
            request = json.loads(line.decode("utf-8"))
            response = handle(request, library)
        except BabelError as error:
            response = {"error": f"{type(error).__name__}: {error}", "code": error.code}
        except (ValueError, TypeError, KeyError) as error:   # JSON illisible, base64 invalide…
            response = {"error": f"{type(error).__name__}: {error}", "code": "bad_request"}
        except Exception as error:  # le service survit à toute requête
            response = {"error": f"{type(error).__name__}: {error}", "code": "internal"}
        if isinstance(request, dict) and "id" in request:
            response["id"] = request["id"]
        payload = json.dumps(response, ensure_ascii=True, separators=(",", ":"))
        sink.write(payload.encode("ascii") + b"\n")
        sink.flush()


# --- Ligne de commande --------------------------------------------------------------------

def _print_found(found: Found, args: argparse.Namespace) -> None:
    if args.json:
        print(json.dumps({"address": found.address.to_json(), "key": found.address.key(),
                          "is_image": found.is_image}))
    elif args.base25:
        print(found.address.compact())
    else:
        print(found.address.full())
    print(found.address.short(), file=sys.stderr)
    if found.notice():
        print(found.notice(), file=sys.stderr)


def _protect_negative_address(argv: list[str]) -> list[str]:
    """`page -12:3:0:0:0:0` : argparse lirait l'adresse (hexagone négatif) comme une option ;
    elle passe en dernier, derrière un `--`, quelle que soit sa place parmi les options
    (`page -12:… --page 5` comme `page --page 5 -12:…`). `page -- -12:…` reste accepté."""
    if not argv or argv[0] != "page" or "--" in argv:
        return argv
    rest = list(argv[1:])
    i = 0
    while i < len(rest):
        token = rest[i]
        if token == "--page":
            i += 2              # la valeur de --page n'est jamais l'adresse
            continue
        if len(token) > 1 and token[0] == "-" and token[1].isdigit():
            address = rest.pop(i)
            return [argv[0], *rest, "--", address]
        i += 1
    return argv


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="babel.py",
        description="Bibliothèque de Babel : page d'un livre, adresse (unique) d'un texte ou d'une image.",
        epilog="Adresse : « hexagone:niveau:mur:étagère:livre[:page] » en décimal (mur 0-3, étagère 0-4,"
               " livre 0-31, page 0-409), la même précédée de « b25: » avec hexagone et niveau en base 25"
               " (rapide), ou objet JSON. Le décimal d'une adresse trouvée compte ~1,8 million de chiffres"
               " (quelques secondes à écrire et à relire). Images : PNG 8 bits seulement ; convertir"
               " d'abord un JPG en PNG (le jeu, lui, accepte PNG, JPG et WebP).")
    commands = parser.add_subparsers(dest="command", required=True)
    page = commands.add_parser("page", help="affiche les 40 lignes d'une page d'un livre")
    page.add_argument("address", help="adresse, ou - pour la lire sur l'entrée standard (une adresse trouvée"
                                      " dépasse la limite de 128 Ko d'un argument sous Linux)")
    page.add_argument("--page", type=int, default=None, help="numéro de page 0-409 (sinon celui de l'adresse, ou 0)")
    for name, helptext, filehelp in (
            ("search-text", "adresse de l'unique livre qui contient ce texte suivi d'espaces",
             "fichier texte UTF-8, ou - pour l'entrée standard"),
            ("search-image", "adresse de l'unique livre d'images dont la page 0 montre cette image (PNG)",
             "fichier PNG (convertir d'abord un JPG en PNG)")):
        command = commands.add_parser(name, help=helptext)
        command.add_argument("file", help=filehelp)
        command.add_argument("--json", action="store_true", help="adresse en JSON (base 25)")
        command.add_argument("--base25", action="store_true", help="adresse « b25:… » (rapide) plutôt qu'en décimal")
    commands.add_parser("serve", help="service JSON ligne à ligne sur l'entrée et la sortie standard")
    args = parser.parse_args(_protect_negative_address(sys.argv[1:] if argv is None else list(argv)))

    try:
        if args.command == "page":
            text = sys.stdin.read() if args.address == "-" else args.address
            address, number = parse_address(text)
            number = _check_page(args.page if args.page is not None else (number or 0))
            for line in Book.at(address).lines(number):
                print(line)
        elif args.command == "search-text":
            if args.file == "-":
                content = sys.stdin.buffer.read().decode("utf-8")
            else:
                with open(args.file, encoding="utf-8") as handle_:
                    content = handle_.read()
            _print_found(search_text(content), args)
        elif args.command == "search-image":
            _print_found(search_image(*read_png(args.file)), args)
        else:
            serve()
    except (ValueError, OSError) as error:
        print(f"babel.py : {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
