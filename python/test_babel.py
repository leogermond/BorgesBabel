"""Vérifie la bijection exacte livre ↔ adresse, la recherche de texte et d'image, le PNG et le service.

uv run --with pytest --with hypothesis pytest python/            # tout, sauf les cas lents
uv run --with pytest --with hypothesis pytest python/ -m slow    # textes de 410 pages, texte trop long
"""

import base64
import io
import itertools
import json
import random
import struct
import subprocess
import sys
import zlib
from fractions import Fraction
from pathlib import Path

import pytest
from hypothesis import given, settings, strategies as st

import babel as b

settings.register_profile("babel", database=None, deadline=None, max_examples=40)
settings.load_profile("babel")

HERE = Path(__file__).resolve().parent
M = b.BOOK_SYMBOLS
BIG = 10 ** 2500
coordinates = st.integers(-BIG, BIG) | st.integers(-1000, 1000)
book_addresses = st.builds(b.Address, coordinates, coordinates, st.integers(0, 3), st.integers(0, 4),
                           st.integers(0, 31))
MAX_RANK = bytes([24]) * M                     # B − 1, le dernier livre


def _int(digits):
    return b._digits_to_int(digits)


def _digits_of(value):
    return b._int_to_digits(value)


def _random_rank(seed):
    return random.Random(seed).randbytes(M).translate(bytes(v % 25 for v in range(256)))


# --- Arithmétique base 25 -----------------------------------------------------------------------

def test_constants_are_invertible():
    assert b.A1 * b.A1_INV % b.N == 1
    assert b.A2 * b.A2_INV % b.N == 1
    assert b.A3 % 5 != 0
    for constant in (b.A1, b.A2, b.A3, b.B1, b.B2, b.B3):
        assert 0 < constant < b.N


@given(st.integers(0, b.N - 1))
def test_mix_is_a_bijection(x):
    assert b.unmix(b.mix(x)) == x
    assert b.mix(b.unmix(x)) == x


@given(st.integers(0, b.N - 1), st.integers(1, 40))
def test_mix_head_is_the_start_of_mix(x, width):
    assert b.mix_head(x, width) == b.to_digits(b.mix(x), b.SYMBOLS)[:width]


@given(st.integers(0, 25 ** 400))
def test_digits_round_trip(x):
    assert b.from_digits(b.to_digits(x, 401)) == x
    assert _int(_digits_of(x)) == x


# Nombres aux longues chaînes de retenues : chiffres 24 (addition), 12 (doublement), 0 (emprunt).
special = st.sampled_from([0, 1, 24, 25 ** 3000 - 1, (25 ** 3000 - 1) // 2, 25 ** 3000, 25 ** 3000 + 1,
                           640 * 25 ** 2000 - 1, 2 * 25 ** 1999])
numbers = st.integers(0, 25 ** 3000) | special


@given(numbers, numbers, st.integers(0, 1))
def test_digit_add_and_sub(x, y, carry):
    assert _int(b._d_add(_digits_of(x), _digits_of(y), carry)) == x + y + carry
    big, small = max(x, y), min(x, y)
    assert _int(b._d_sub(_digits_of(big), _digits_of(small))) == big - small


@given(numbers, st.integers(0, 10))
def test_digit_mul_small(x, k):
    assert _int(b._d_mul_small(_digits_of(x), k)) == x * k


@given(numbers)
def test_digit_divisions(x):
    for m in (2, 4, 8):
        q, r = b._d_divmod_pow2(_digits_of(x), m)
        assert (_int(q), r) == divmod(x, m)
    q, r = b._d_divmod5(_digits_of(x))
    assert (_int(q), r) == divmod(x, 5)
    q, r = b._d_divmod640(_digits_of(x))
    assert (_int(q), r) == divmod(x, 640)
    assert _int(b._d_mul640(_digits_of(x))) == 640 * x


def test_digit_arithmetic_on_a_whole_rank():
    rank = MAX_RANK
    assert b._d_add(rank, b"\x01") == bytes(M) + b"\x01"           # B : retenue sur 1 312 000 chiffres
    q, r = b._d_divmod640(rank)
    assert b._d_add(b._d_mul640(q), b._int_to_digits(r)) == rank
    assert r == (pow(25, M, 640) - 1) % 640


@given(st.integers() | coordinates)
def test_zigzag_round_trip(value):
    assert b.zigzag(value) >= 0
    assert b.unzigzag(b.zigzag(value)) == value
    text = b.int_to_b25(value)
    assert b.b25_to_int(text) == value
    assert _int(b._code(text)) == b.zigzag(value)
    assert b._coordinate_of_code(b._code(text)) == text


def test_zigzag_order():
    assert [b.zigzag(v) for v in (0, -1, 1, -2, 2)] == [0, 1, 2, 3, 4]


def test_b25_wire_form():
    assert b.int_to_b25(0) == "0" and b.int_to_b25(-1) == "-1" and b.int_to_b25(24) == "o"
    assert b.int_to_b25(-625) == "-100"
    assert int(b.int_to_b25(-123456789), 25) == -123456789
    assert b.Address("-0", "+00c", 0, 0, 0) == b.Address(0, 12, 0, 0, 0)
    for bad in ("", "-", "p", "1.5", "１", "0x1"):
        with pytest.raises(b.BabelError):
            b.Address(bad, 0, 0, 0, 0)


@pytest.mark.parametrize("bad", ["1\t2", "1\x002", "\x01", "-\x05", "12\n", " 12", "1 2", "+\x18", "1\x7f"])
def test_b25_rejects_control_and_foreign_characters(bad):
    """Un octet de contrôle vaut déjà moins de 25 : il ne doit pas passer pour un chiffre."""
    with pytest.raises(b.BabelError):
        b.Address(bad, 0, 0, 0, 0)
    with pytest.raises(b.BabelError):
        b.Address(0, bad, 0, 0, 0)
    response, = _serve([json.dumps({"op": "page", "address": {"hexagon": bad, "level": "0", "wall": 0,
                                                               "shelf": 0, "book": 0}})])
    assert response["code"] == "bad_request"
    response, = _serve([json.dumps({"op": "is_image_book", "gallery": {"hexagon": "0", "level": bad}})])
    assert response["code"] == "bad_request"


@pytest.mark.parametrize("size", [5, 1400, 1600, 5000])
def test_decimal_slow_path_round_trip(size):
    rng = random.Random(size)
    value = -rng.randrange(25 ** size)
    text = b.int_to_b25(value)
    assert b.b25_to_decimal(text) == str(value)
    assert b.decimal_to_b25(str(value)) == text


@given(st.integers(-25 ** 300, 25 ** 300) | st.sampled_from(
    [10 ** k + d for k in (60, 61, 100, 333) for d in (-1, 0, 1)] + [-(10 ** 70) + 1, 25 ** 49, 25 ** 48 - 1]))
def test_coordinate_summary_matches_decimal(value):
    exact = str(abs(value))
    summary = b.coordinate_summary(b.int_to_b25(value))
    assert summary == {"sign": (value > 0) - (value < 0), "digits": len(exact), "lead": exact[:4],
                       "tail": exact[-4:]}


def test_coordinate_summary_of_a_huge_coordinate():
    text = "-" + "c" * 655998                                    # −(25^655998 − 1)/2
    summary = b.coordinate_summary(text)
    assert summary["sign"] == -1 and summary["digits"] == 917046
    exact = b.b25_to_decimal(text)
    assert summary["lead"] == exact[1:5] and summary["tail"] == exact[-4:]
    assert b.short_coordinate(text) == f"-{exact[1:5]}…{exact[-4:]} (917046 chiffres)"


@given(book_addresses, st.none() | st.integers(0, 409))
def test_address_forms_round_trip(address, page):
    assert b.parse_address(address.full(page)) == (address, page)
    assert b.parse_address(address.compact(page)) == (address, page)
    assert b.Address.from_json(json.loads(json.dumps(address.to_json()))) == address


# --- Région habitée ---------------------------------------------------------------------------

def _reference_rank(address):
    """640·C + e, calculé en entiers (comme l'ancien pack) ; C entrelace z(h) et z(n) en base 25."""
    zh, zl = b.zigzag(address.hexagon_int()), b.zigzag(address.level_int())
    count = max(zh.bit_length(), zl.bit_length()) // 4 + 1
    cell = bytearray(2 * count)
    cell[0::2] = b.to_digits(zh, count)
    cell[1::2] = b.to_digits(zl, count)
    return 640 * b.from_digits(bytes(cell)) + address.slot


@given(book_addresses)
def test_rank_round_trip(address):
    rank = b.book_rank(address)
    assert _int(rank) == _reference_rank(address)
    assert b.address_of_rank(rank) == address


@given(st.integers(0, 2 ** 64) | st.integers(0, 25 ** 5000))
def test_rank_to_address_is_onto(rank):
    address = b.address_of_rank(_digits_of(rank))
    assert _int(b.book_rank(address)) == rank


def test_region_edges():
    assert pow(25, M, 640) == 385                                # B mod 640
    last = b.address_of_rank(MAX_RANK)                           # rang B − 1
    assert (last.wall, last.shelf, last.book) == (2, 2, 0) and last.slot == 384
    assert b.book_rank(last) == MAX_RANK and b.is_valid(last)
    for slot in (385, 386, 639):
        assert not b.is_valid(b.Address.at_slot(last.hexagon, last.level, slot))
    assert all(b.is_valid(b.Address.at_slot(last.hexagon, last.level, s)) for s in (0, 200, 383))
    flags = b.gallery_image_flags(last.hexagon, last.level)
    assert all(f is not None for f in flags[:385]) and all(f is None for f in flags[385:])
    # La galerie suivante (niveau + 1 sur le dernier chiffre entrelacé) est vide.
    beyond = b.Address("1" + "0" * 700000, 0, 0, 0, 0)
    assert not b.is_valid(beyond) and b.is_image_book(beyond.hexagon, 0, 0, 0, 0) is None
    assert b.gallery_image_flags(beyond.hexagon, beyond.level) == [None] * 640
    with pytest.raises(b.EmptySlot):
        b.Book.at(beyond)


def test_every_gallery_up_to_917045_decimal_digits_is_full():
    extreme = "c" * 655998            # (25^655998 − 1)/2 : 917 046 chiffres, > tout nombre de 917 045 chiffres
    assert b.coordinate_summary(extreme)["digits"] == 917046
    for hexagon, level in ((extreme, extreme), ("-" + extreme, extreme), (extreme, "-" + extreme)):
        corner = b.Address(hexagon, level, 3, 4, 31)
        rank = b.book_rank(corner)
        assert rank is not None and b.address_of_rank(rank) == corner


# --- Livres : pages, mélange, voisins -----------------------------------------------------------

def test_page_shape_and_alphabet():
    book = b.Book.at(b.Address(1, 1, 1, 1, 1))
    for page in (0, 1, 409):
        lines = book.lines(page)
        assert len(lines) == 40 and {len(line) for line in lines} == {80}
        seen = set("".join(lines))
        assert seen <= set(b.ALPHABET) and not seen & set("kqwy")


def test_book_is_deterministic_and_lazy():
    address = b.Address(2 ** 62 - 1, -7, 2, 4, 31)
    first = b.Book.at(address)
    assert first.text(3) == b.Book.at(b.Address(2 ** 62 - 1, -7, 2, 4, 31)).text(3)
    assert first.computed_pages == 4
    assert b.page_lines(address, 3) == first.lines(3)


def _common_prefix(a, c):
    n = 0
    while n < len(a) and a[n] == c[n]:
        n += 1
    return n


def _unrelated(p, q):
    """Deux pages sans rapport : ni début ni fin communs de plus de 4 symboles, accord ≈ 1/25."""
    agree = sum(x == y for x, y in zip(p, q))
    return _common_prefix(p, q) <= 4 and _common_prefix(p[::-1], q[::-1]) <= 4 and 60 <= agree <= 210


def _violations(first, second, pages):
    return [p for p in pages if not _unrelated(first.digits(p), second.digits(p))]


def _neighbour(address, step):
    values = dict(address.to_json())
    if step in ("hexagon", "level"):
        values[step] = b.int_to_b25(b.b25_to_int(values[step]) + 1)
    else:
        bound = {"wall": 3, "shelf": 4, "book": 31}[step]
        values[step] += 1 if values[step] < bound else -1
    return b.Address.from_json(values)


def test_neighbours_are_unrelated_on_first_pages():
    rng = random.Random(3)
    for _ in range(25):
        h = rng.choice([rng.randint(-50, 50), rng.randint(-BIG, BIG)])
        base = b.Address(h, rng.randint(-20, 20), rng.randint(0, 3), rng.randint(0, 4), rng.randint(0, 31))
        step = rng.choice(["hexagon", "level", "wall", "shelf", "book"])
        assert _violations(b.Book.at(base), b.Book.at(_neighbour(base, step)), range(3)) == [], (base, step)


@pytest.mark.parametrize("step", ["book", "shelf", "wall", "hexagon", "level"])
def test_neighbours_are_unrelated_on_every_page(step):
    base = b.Address(-4, 9, 1, 2, 30)
    assert _violations(b.Book.at(base), b.Book.at(_neighbour(base, step)), range(b.PAGES)) == []


def _changed(rank, page, offset=1234):
    position = page * b.SYMBOLS + offset
    return rank[:position] + bytes(((rank[position] + 7) % 25,)) + rank[position + 1:]


@pytest.fixture(scope="module")
def diffusion_books():
    rank = _random_rank(11)
    base = b.Book(rank)
    base.number(409)
    return rank, base


@pytest.mark.parametrize("page", [0, 205, 409])
def test_one_symbol_changes_every_page(diffusion_books, page):
    rank, base = diffusion_books
    assert _violations(base, b.Book(_changed(rank, page)), range(b.PAGES)) == []


def test_mutant_without_backward_chain_fails(monkeypatch):
    """Sans l'empreinte D des pages 1 … 409 dans la page 0, un symbole changé en page 205 laisse
    les pages 0 … 204 intactes : le test de diffusion échoue."""
    monkeypatch.setattr(b, "_head_offset", lambda digest: 0)
    rank = _random_rank(12)
    assert _violations(b.Book(rank), b.Book(_changed(rank, 205)), range(3)) == [0, 1, 2]


def test_mutant_without_forward_chain_fails(monkeypatch):
    """Sans la chaîne avant, un symbole changé en page 0 ne change que la page 0."""
    monkeypatch.setattr(b, "_link", lambda previous, index: b._page_constant(index))
    rank = _random_rank(13)
    assert _violations(b.Book(rank), b.Book(_changed(rank, 0)), range(4)) == [1, 2, 3]


# --- Aller-retour adresse → livre → adresse ------------------------------------------------------

@pytest.mark.parametrize("address", [
    b.Address(0, 0, 0, 0, 0),
    b.Address(-12345, 678, 3, 0, 17),
    b.address_of_rank(_random_rank(5)),        # adresse prise au hasard dans toute la région
    b.address_of_rank(MAX_RANK),               # le dernier livre
], ids=["origine", "petite", "hasard", "dernier"])
def test_address_book_address_round_trip(address):
    book = b.Book.at(address)
    found = b.book_of_content(book.content())
    assert found.address == address and found.rank == book.rank


# --- Recherche de texte -----------------------------------------------------------------------

def _check_text_book(text, pages):
    found = b.search_text(text)
    fresh = b.Book.at(found.address)                       # recalculé depuis l'adresse seule
    padded = b.pad(text)
    for p in pages:
        assert fresh.text(p) == padded[p * 3200:(p + 1) * 3200], p
    return found


def test_empty_text():
    found = _check_text_book("", [0, 1])
    assert found.text_pages == 0 and not found.is_image and found.notice() is None


def test_one_page_text_every_page():
    text = "La bibliothèque de Babel"
    found = b.search_text(text)
    assert found.text_pages == 1 and not found.is_image and not found.truncated
    assert b.Book.at(found.address).content().translate(b._TO_ALPHABET).decode() == b.pad(text)


def test_three_page_text():
    rng = random.Random(7)
    text = "".join(rng.choice(b.ALPHABET) for _ in range(2 * 3200 + 1777))
    if text.replace(" ", "")[:2] in {a + c for a in ",." for c in ",."}:
        text = "x" + text
    found = _check_text_book(text, [0, 1, 2, 3])
    assert found.text_pages == 3 and not found.is_image


@given(st.text(max_size=300))
@settings(max_examples=8)
def test_search_text_round_trip(text):
    found = _check_text_book(text, [0])
    assert found.is_image == b.content_is_image(b.pad(text)[:20].encode().translate(b._FROM_ALPHABET))


@pytest.mark.parametrize("text,image", [
    ("Kafka, Wittgenstein & Yeats : « Qu'œuvrent-ils ? » — Ça, l'été à Ýpres.\nFin.", False),
    (", bonjour", False),           # un seul signe en tête
    ("  bonjour", False),           # les espaces ne comptent pas
    (",.", True),
    ("  . \n ,  suite", True),      # espaces ignorés : « . » puis « , »
    ("..", True),
])
def test_search_text_marker(text, image):
    found = _check_text_book(text, [0])
    assert found.is_image is image
    assert (found.notice() is not None) is image


def test_search_of_a_book_shows_that_book():
    address = b.Address(-99, 3, 0, 1, 2)
    book = b.Book.at(address)
    text = book.content().translate(b._TO_ALPHABET).decode()
    assert b.search_text(text).address == address


@pytest.mark.parametrize("raw,expected", [
    ("Été À L'ÎLE", "ete a lile"),
    ("kiwi quay yoyo", "civi cuai ioio"),
    ("cœur, æther. Straße", "coeur, aether. strasse"),
    ("ligne 1\nligne\t2 !?;:", "ligne  ligne  "),
    ("ñandú çà", "nandu ca"),
])
def test_normalize(raw, expected):
    assert b.normalize(raw) == expected


def test_pad():
    assert b.pad("ab") == "ab" + " " * (M - 2)
    assert len(b.pad("x" * 5000)) == M


@pytest.mark.slow
def test_full_book_text_round_trip():
    rng = random.Random(17)
    text = "a" + "".join(rng.choice(b.ALPHABET) for _ in range(M - 1))
    found = b.search_text(text)
    assert found.text_pages == 410 and not found.truncated
    fresh = b.Book.at(found.address)
    assert fresh.content().translate(b._TO_ALPHABET).decode() == text


@pytest.mark.slow
def test_text_longer_than_a_book_is_truncated():
    text = "Borges " * (M // 7 + 50)
    found = b.search_text(text)
    assert found.truncated and "tronqué" in found.notice() and found.text_pages == 410
    assert b.Book.at(found.address).text(409) == b.normalize(text)[409 * 3200:]


# --- Livres d'images --------------------------------------------------------------------------

def _image_count(length):
    """Nombre exact de contenus de `length` symboles dont les deux premiers non-espaces sont des signes."""
    return 4 * sum((t + 1) * 25 ** (length - 2 - t) for t in range(length - 1))


def test_image_rule_count_by_brute_force():
    count = sum(bool(b._image_flag(bytes(seq))) for seq in itertools.product(range(25), repeat=4))
    assert count == _image_count(4)
    assert abs(Fraction(_image_count(30), 25 ** 30) - Fraction(1, 144)) < Fraction(1, 10 ** 38)


def test_image_book_rate_and_gallery_flags():
    rng = random.Random(11)
    hits = total = 0
    for _ in range(20):
        hexagon, level = rng.randint(-10 ** 6, 10 ** 6), rng.randint(-1000, 1000)
        flags = b.gallery_image_flags(hexagon, level)
        hits += sum(flags)
        total += len(flags)
    assert total == 12800 and 55 <= hits <= 130, hits      # 1/144 : 89 attendus


@pytest.mark.parametrize("hexagon,level", [(17, -3), (-(10 ** 40), 5)])
def test_gallery_flags_match_single_flags_and_content(hexagon, level):
    flags = b.gallery_image_flags(hexagon, level)
    assert flags == [b.is_image_book(hexagon, level, s // 160, s // 32 % 5, s % 32) for s in range(640)]
    for slot in range(0, 640, 37):
        assert b.Book.at(b.Address.at_slot(hexagon, level, slot)).is_image is flags[slot]


def test_far_gallery_flags():
    found = b.search_text("loin")
    flags = b.gallery_image_flags(found.address.hexagon, found.address.level)
    assert flags[found.address.slot] is False and len(flags) == 640
    for slot in (0, 639):
        address = b.Address.at_slot(found.address.hexagon, found.address.level, slot)
        assert b.address_is_image(address) is flags[slot]


def _gradient(width, height):
    data = bytearray()
    for y in range(height):
        for x in range(width):
            data += bytes((x * 255 // max(1, width - 1), y * 255 // max(1, height - 1), 128, 255))
    return bytes(data)


def _checkerboard(width, height, cell):
    data = bytearray()
    for y in range(height):
        for x in range(width):
            data += b"\xff\xff\xff\xff" if (x // cell + y // cell) % 2 else b"\x00\x00\x00\xff"
    return bytes(data)


@pytest.mark.parametrize("width,height,rgba", [
    (200, 120, _gradient(200, 120)),
    (8, 8, _checkerboard(8, 8, 2)),
    (50, 64, _gradient(50, 64)),
    (3, 40, _checkerboard(3, 40, 1)),
])
def test_image_round_trip(width, height, rgba):
    found = b.search_image(width, height, rgba)
    fresh = b.Book.at(found.address)
    expected = b.quantize(width, height, rgba, reserve=2)
    assert fresh.digits(0) == expected and fresh.is_image and found.is_image
    assert set(expected[:2]) <= set(b.SIGNS)
    assert fresh.digits(1) == bytes(3200)
    assert b.address_is_image(found.address) is True


def test_image_book_last_page_is_blank():
    found = b.search_image(8, 8, _checkerboard(8, 8, 2))
    assert b.Book.at(found.address).digits(409) == bytes(3200)


@given(st.integers(1, 12), st.integers(1, 12), st.data())
@settings(max_examples=6)
def test_image_round_trip_random(width, height, data):
    rgba = data.draw(st.binary(min_size=width * height * 4, max_size=width * height * 4))
    found = b.search_image(width, height, rgba)
    assert b.Book.at(found.address).digits(0) == b.quantize(width, height, rgba, reserve=2)
    assert b.address_is_image(found.address) is True


def test_reserve_only_touches_the_mark():
    rgba = _gradient(50, 64)
    plain, marked = b.quantize(50, 64, rgba), b.quantize(50, 64, rgba, reserve=2)
    assert set(marked[:2]) <= set(b.SIGNS) and len(plain) == len(marked) == 3200


def test_letterbox_uses_darkest_ink():
    indices = b.quantize(10, 1, b"\xff\xff\xff\xff" * 10)   # bande horizontale : marges haut et bas
    assert indices[0] == 0 and indices[-1] == 0
    darkest = min(range(25), key=lambda i: sum(b.PALETTE[i]))
    assert darkest == 0


def _reference_grid(width, height):
    """image_grid recalculé en fractions exactes, d'après sa définition."""
    scale = min(Fraction(b.IMAGE_WIDTH, width), Fraction(b.IMAGE_HEIGHT, height))

    def half_up(value):   # value > 0
        return int(value + Fraction(1, 2))

    fit_w = min(b.IMAGE_WIDTH, max(1, half_up(width * scale)))
    fit_h = min(b.IMAGE_HEIGHT, max(1, half_up(height * scale)))
    step_x = min(4, -(-width // fit_w))
    step_y = min(4, -(-height // fit_h))
    cols = [int((tx + Fraction(2 * i + 1, 2 * step_x)) * width / fit_w) for tx in range(fit_w) for i in range(step_x)]
    rows = [int((ty + Fraction(2 * j + 1, 2 * step_y)) * height / fit_h) for ty in range(fit_h) for j in range(step_y)]
    return fit_w, fit_h, cols, rows


@given(st.integers(1, 20000), st.integers(1, 20000))
@settings(max_examples=300)
def test_image_grid_is_exact(width, height):
    fit_w, fit_h, cols, rows = b.image_grid(width, height)
    assert (fit_w, fit_h, cols, rows) == _reference_grid(width, height)
    assert len(cols) <= 200 and len(rows) <= 256
    assert all(0 <= c < width for c in cols) and all(0 <= r < height for r in rows)
    assert cols == sorted(cols) and rows == sorted(rows)


@pytest.mark.parametrize("width,height,fit", [
    (4, 1, (50, 13)),      # 12,5 → 13 : moitié vers le haut (round() de Python donnerait 12)
    (100, 1, (50, 1)),     # 0,5 → 1
    (1, 1, (50, 50)),
    (50, 64, (50, 64)),
    (25, 64, (25, 64)),
    (6000, 4000, (50, 33)),
])
def test_image_grid_rounds_half_up(width, height, fit):
    assert b.image_grid(width, height)[:2] == fit


def _game_samples(width, height, rgba):
    """Ce que fait BookText.search_image : ne lire que les points de grille de l'image."""
    _fit_w, _fit_h, cols, rows = b.image_grid(width, height)
    out = bytearray()
    for y in rows:
        for x in cols:
            o = (y * width + x) * 4
            out += rgba[o:o + 4]
    return bytes(out)


@pytest.mark.parametrize("width,height", [(1, 1), (513, 200), (1024, 1024), (6000, 10), (7, 3000)])
def test_game_request_matches_cli(width, height, tmp_path, capsys):
    """Même image → même adresse, que le jeu envoie ses points de grille ou que la ligne de
    commande lise le PNG complet ; la requête du jeu reste bornée."""
    rng = random.Random(width * 7919 + height)
    rgba = rng.randbytes(width * height * 4)
    samples = _game_samples(width, height, rgba)
    assert len(samples) <= 200 * 256 * 4
    assert b.quantize_samples(width, height, samples, 2) == b.quantize(width, height, rgba, 2)
    game, full = _serve([
        json.dumps({"op": "search_image", "width": width, "height": height,
                    "samples": base64.b64encode(samples).decode()}),
        json.dumps({"op": "search_image", "width": width, "height": height,
                    "rgba": base64.b64encode(rgba).decode()}),
    ])
    assert game == full and game["is_image"] is True
    if width * height <= 300_000:    # le décodeur PNG en Python pur est lent sur les grandes images
        path = tmp_path / "image.png"
        path.write_bytes(_encode_png(width, height, 6, rgba))
        assert b.main(["search-image", str(path), "--json"]) == 0
        assert json.loads(capsys.readouterr().out)["address"] == game["address"]


def test_search_image_request_errors():
    rgba = base64.b64encode(b"\x00" * 16).decode()
    responses = _serve([
        json.dumps({"op": "search_image", "width": 2, "height": 2}),
        json.dumps({"op": "search_image", "width": 2, "height": 2, "rgba": rgba, "samples": rgba}),
        json.dumps({"op": "search_image", "width": 2, "height": 2, "samples": rgba}),   # 50 × 50 points attendus
        json.dumps({"op": "search_image", "width": 0, "height": 2, "samples": ""}),
    ])
    assert all(r.get("code") == "bad_request" for r in responses), responses


# --- PNG ------------------------------------------------------------------------------------

def _paeth(a, c_up, c):
    p = a + c_up - c
    pa, pb, pc = abs(p - a), abs(p - c_up), abs(p - c)
    return a if pa <= pb and pa <= pc else (c_up if pb <= pc else c)


def _encode_png(width, height, color, samples, plte=b"", trns=b""):
    """PNG minimal : chaque ligne prend le filtre (ligne mod 5), pour exercer les cinq filtres."""
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[color]
    stride = width * channels
    raw = bytearray()
    prev = bytes(stride)
    for y in range(height):
        row = samples[y * stride:(y + 1) * stride]
        kind = y % 5
        out = bytearray()
        for i in range(stride):
            a = row[i - channels] if i >= channels else 0
            up = prev[i]
            c = prev[i - channels] if i >= channels else 0
            pred = (0, a, up, (a + up) >> 1, _paeth(a, up, c))[kind]
            out.append((row[i] - pred) & 0xFF)
        raw += bytes([kind]) + out
        prev = row

    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))

    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, color, 0, 0, 0))
    if plte:
        png += chunk(b"PLTE", plte)
    if trns:
        png += chunk(b"tRNS", trns)
    return png + chunk(b"IDAT", zlib.compress(bytes(raw))) + chunk(b"IEND", b"")


def test_png_rgba_rgb_grey():
    rng = random.Random(2)
    w, h = 7, 11
    rgba = bytes(rng.randrange(256) for _ in range(w * h * 4))
    assert b.decode_png(_encode_png(w, h, 6, rgba)) == (w, h, rgba)
    rgb = bytes(v for i, v in enumerate(rgba) if i % 4 != 3)
    expected = bytes(v if i % 4 != 3 else 255 for i, v in enumerate(rgba))
    assert b.decode_png(_encode_png(w, h, 2, rgb)) == (w, h, expected)
    grey = bytes(rng.randrange(256) for _ in range(w * h))
    assert b.decode_png(_encode_png(w, h, 0, grey))[2] == bytes(x for g in grey for x in (g, g, g, 255))
    grey_alpha = bytes(rng.randrange(256) for _ in range(w * h * 2))
    assert b.decode_png(_encode_png(w, h, 4, grey_alpha))[2] == bytes(
        x for i in range(w * h) for x in (grey_alpha[2 * i],) * 3 + (grey_alpha[2 * i + 1],))


def test_png_palette_with_transparency():
    plte = bytes((10, 20, 30, 200, 100, 0, 1, 2, 3))
    indices = bytes([0, 1, 2, 1, 0, 2])
    png = _encode_png(3, 2, 3, indices, plte=plte, trns=bytes([0]))
    expected = b"".join({0: b"\x0a\x14\x1e\x00", 1: b"\xc8\x64\x00\xff", 2: b"\x01\x02\x03\xff"}[i] for i in indices)
    assert b.decode_png(png) == (3, 2, expected)


def test_png_rejects_jpeg_and_16_bit():
    with pytest.raises(ValueError, match="JPG"):
        b.decode_png(b"\xff\xd8\xff\xe0 jpeg")
    png16 = _encode_png(1, 1, 0, b"\x00").replace(
        struct.pack(">IIBBBBB", 1, 1, 8, 0, 0, 0, 0), struct.pack(">IIBBBBB", 1, 1, 16, 0, 0, 0, 0))
    with pytest.raises(ValueError):
        b.decode_png(png16)


def test_search_image_file_through_cli(tmp_path, capsys):
    path = tmp_path / "damier.png"
    rgba = _checkerboard(16, 16, 4)
    path.write_bytes(_encode_png(16, 16, 6, rgba))
    assert b.main(["search-image", str(path), "--json"]) == 0
    out = json.loads(capsys.readouterr().out)
    address = b.Address.from_json(out["address"])
    assert out["is_image"] is True
    assert b.Book.at(address).digits(0) == b.quantize(16, 16, rgba, reserve=2)


# --- Ligne de commande ------------------------------------------------------------------------

def test_cli_search_text_then_page_decimal(tmp_path, capsys, monkeypatch):
    """Forme décimale complète (chemin lent : ~1,8 million de chiffres), relue par `page -`."""
    source = tmp_path / "texte.txt"
    source.write_text("Une phrase de Borges.", encoding="utf-8")
    assert b.main(["search-text", str(source)]) == 0
    captured = capsys.readouterr()
    full = captured.out.strip()
    assert len(full) > 1_000_000 and "hexagone" in captured.err
    monkeypatch.setattr(sys, "stdin", io.StringIO(full))
    assert b.main(["page", "-"]) == 0
    lines = capsys.readouterr().out.splitlines()
    assert lines[0].startswith("une phrase de borges.") and len(lines) == 40


def test_cli_search_text_base25_and_json(tmp_path, capsys):
    source = tmp_path / "texte.txt"
    source.write_text("Une phrase de Borges.", encoding="utf-8")
    assert b.main(["search-text", str(source), "--base25"]) == 0
    compact = capsys.readouterr().out.strip()
    assert compact.startswith("b25:")
    assert b.main(["search-text", str(source), "--json"]) == 0
    out = json.loads(capsys.readouterr().out)
    assert b.Address.from_json(out["address"]).compact() == compact and out["is_image"] is False
    assert b.main(["page", compact, "--page", "1"]) == 0
    assert capsys.readouterr().out.splitlines() == [" " * 80] * 40


def test_cli_page_negative_hexagon(capsys):
    """Une adresse qui commence par « - » reste un argument, avec ou sans « -- »."""
    expected = b.Book.at(b.Address(-12345, -3, 0, 4, 17)).lines(205)
    assert b.main(["page", "-12345:-3:0:4:17:205"]) == 0
    assert capsys.readouterr().out.splitlines() == expected
    assert b.main(["page", "--", "-12345:-3:0:4:17:205"]) == 0
    assert capsys.readouterr().out.splitlines() == expected
    assert b.main(["page", "b25:" + b.int_to_b25(-12345) + ":-3:0:4:17", "--page", "205"]) == 0
    assert capsys.readouterr().out.splitlines() == expected
    assert b.main(["page", "-12345:-3:0:4:17", "--page", "205"]) == 0
    assert capsys.readouterr().out.splitlines() == expected
    assert b.main(["page", "--page", "205", "-12345:-3:0:4:17"]) == 0       # adresse après les options
    assert capsys.readouterr().out.splitlines() == expected
    assert b.main(["page", "--page", "205", "-12345:-3:0:4:17:3"]) == 0     # --page l'emporte
    assert capsys.readouterr().out.splitlines() == expected


def test_cli_errors(capsys):
    assert b.main(["page", "1:2:3"]) == 1
    assert "adresse" in capsys.readouterr().err
    assert b.main(["page", "1:2:3:4:5:410"]) == 1
    assert "page" in capsys.readouterr().err
    assert b.main(["page", "b25:1" + "0" * 700000 + ":0:0:0:0"]) == 1
    assert "vide" in capsys.readouterr().err


def test_cli_subprocess_pipeline(tmp_path):
    """`babel.py search-text f.txt --base25`, puis `babel.py page -` sur l'entrée standard."""
    source = tmp_path / "texte.txt"
    source.write_text("Le jardin aux sentiers qui bifurquent", encoding="utf-8")
    script = [sys.executable, "-X", "utf8", str(HERE / "babel.py")]
    found = subprocess.run(script + ["search-text", str(source), "--base25"], capture_output=True, text=True,
                           encoding="utf-8", timeout=120, check=True).stdout
    page = subprocess.run(script + ["page", "-"], input=found, capture_output=True, text=True,
                          encoding="utf-8", timeout=120)
    assert page.returncode == 0, page.stderr
    assert "".join(page.stdout.splitlines()) == b.pad("Le jardin aux sentiers qui bifurquent")[:3200]


# --- Service, protocole 3 ---------------------------------------------------------------------

def _serve(lines, library=None):
    sink = io.BytesIO()
    b.serve(io.BytesIO("".join(line + "\n" for line in lines).encode("utf-8")), sink, library)
    return [json.loads(line) for line in sink.getvalue().decode("ascii").splitlines()]


def test_serve_protocol():
    address = {"hexagon": b.int_to_b25(-123456789012345678901234567890), "level": "7", "wall": 1, "shelf": 2,
               "book": 3}
    python_address = b.Address.from_json(address)
    book = b.Book.at(python_address)
    rgba = base64.b64encode(_gradient(20, 30)).decode()
    empty = dict(address, hexagon="1" + "0" * 700000)
    library = b.Library()
    responses = _serve([
        json.dumps({"id": 1, "op": "ping"}),
        json.dumps({"id": 2, "op": "page", "address": address, "page": 4}),
        json.dumps({"id": 3, "op": "search_text", "text": "Ô temps, suspends ton vol"}),
        json.dumps({"id": 4, "op": "search_image", "width": 20, "height": 30, "rgba": rgba}),
        json.dumps({"id": 5, "op": "is_image_book", "books": [address, dict(address, page=7), empty]}),
        json.dumps({"id": 6, "op": "display", "address": dict(address, page=4), "full": True}),
        json.dumps({"id": 7, "op": "palette"}),
        json.dumps({"id": 8, "op": "book_info", "address": address}),
        json.dumps({"id": 9, "op": "pages", "address": address, "pages": [0, 409, 4]}),
        json.dumps({"id": 10, "op": "is_image_book", "gallery": {"hexagon": address["hexagon"], "level": "7"}}),
        json.dumps({"id": 11, "op": "book_info", "address": empty}),
        "",
        "pas du json",
        json.dumps({"id": 20, "op": "inconnue"}),
        json.dumps({"id": 21, "op": "page", "address": dict(address, wall=9)}),
        json.dumps({"id": 22, "op": "page"}),
        json.dumps([1, 2]),
        json.dumps({"id": 23, "op": "search_image", "width": 2, "height": 2, "rgba": "AAAA"}),
        json.dumps({"id": 24, "op": "page", "address": empty}),
        json.dumps({"id": 25, "op": "page", "key": "0123456789abcdef0123"}),
        json.dumps({"id": 26, "op": "page", "address": address, "page": 410}),
        json.dumps({"id": 27, "op": "page", "address": dict(address, hexagon="xyz")}),
        json.dumps({"id": 28, "op": "pages", "address": address, "pages": []}),
    ], library)
    assert len(responses) == 22
    by_id = {r.get("id"): r for r in responses}
    assert by_id[1] == {"id": 1, "protocol": 3}
    page = by_id[2]
    assert page["lines"] == book.lines(4) and page["page"] == 4 and page["is_image"] is book.is_image
    assert page["key"] == python_address.key()
    found = by_id[3]
    assert b.Book.at(b.Address.from_json(found["address"])).text(0) == b.pad("Ô temps, suspends ton vol")[:3200]
    assert found["is_image"] is False and found["text_pages"] == 1 and found["truncated"] is False
    assert "notice" not in found
    image_address = b.Address.from_json(by_id[4]["address"])
    assert by_id[4]["is_image"] is True
    assert b.Book.at(image_address).digits(0) == b.quantize(20, 30, _gradient(20, 30), reserve=2)
    assert by_id[5]["is_image"] == [book.is_image, book.is_image, None]
    display = by_id[6]
    assert display["full"] == python_address.full(4) and "hexagone" in display["short"]
    assert display["hexagon"] == {"sign": -1, "digits": 30, "lead": "1234", "tail": "7890"}
    assert len(by_id[7]["palette"]) == 25 and by_id[7]["width"] == 50 and by_id[7]["height"] == 64
    assert by_id[8]["exists"] is True and by_id[8]["is_image"] is book.is_image and by_id[8]["key"] == page["key"]
    assert [p["page"] for p in by_id[9]["pages"]] == [0, 409, 4]
    assert by_id[9]["pages"][1]["lines"] == book.lines(409)
    gallery = by_id[10]["is_image"]
    assert len(gallery) == 640 and gallery[python_address.slot] is book.is_image
    assert by_id[11] == {"id": 11, "exists": False}
    errors = [r for r in responses if "error" in r]
    assert len(errors) == 11
    assert {r.get("id") for r in errors} == {None, 20, 21, 22, 23, 24, 25, 26, 27, 28}
    assert by_id[20]["code"] == "unknown_op" and by_id[24]["code"] == "empty_slot"
    assert by_id[25]["code"] == "unknown_key" and by_id[21]["code"] == "bad_request"
    assert all(len(r["error"]) < 400 for r in errors)          # aucune coordonnée recopiée en entier


def test_serve_keys_and_cache():
    library = b.Library(books=2)
    found, = _serve([json.dumps({"op": "search_text", "text": "clef"})], library)
    key = found["key"]
    first, by_key, info = _serve([
        json.dumps({"op": "page", "key": key, "page": 0}),
        json.dumps({"op": "page", "key": key, "page": 1}),
        json.dumps({"op": "book_info", "key": key}),
    ], library)
    assert first["lines"][0].startswith("clef ") and by_key["lines"] == [" " * 80] * 40
    assert info["address"] == found["address"]


def test_serve_image_page_carries_indices():
    rgba = _checkerboard(8, 8, 2)
    found = b.search_image(8, 8, rgba)
    [response] = _serve([json.dumps({"op": "page", "address": found.address.to_json()})])
    assert response["is_image"] is True
    assert base64.b64decode(response["indices"]) == b.quantize(8, 8, rgba, reserve=2)
    [text_page] = _serve([json.dumps({"op": "page", "address": b.Address(0, 0, 0, 0, 0).to_json(), "page": 2})])
    assert "indices" not in text_page or text_page["is_image"]


def test_serve_subprocess():
    process = subprocess.run([sys.executable, "-X", "utf8", "-u", str(HERE / "babel.py"), "serve"],
                             input='{"id":"a","op":"ping"}\nnimporte quoi\n{"id":"b","op":"search_text","text":"été"}\n',
                             capture_output=True, text=True, encoding="utf-8", timeout=120)
    assert process.returncode == 0, process.stderr
    responses = [json.loads(line) for line in process.stdout.splitlines()]
    assert responses[0] == {"id": "a", "protocol": 3}
    assert responses[1]["code"] == "bad_request"
    assert b.Book.at(b.Address.from_json(responses[2]["address"])).text(0).startswith("ete ")
