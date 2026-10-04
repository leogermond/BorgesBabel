"""Vérifie la bijection de la Bibliothèque, la recherche de texte et d'image, le PNG et le service.

uv run --with pytest --with hypothesis pytest python/
"""

import base64
import io
import json
import random
import struct
import subprocess
import sys
import zlib
from pathlib import Path

import pytest
from hypothesis import given, settings, strategies as st

import babel as b

settings.register_profile("babel", database=None, deadline=None, max_examples=60)
settings.load_profile("babel")

HERE = Path(__file__).resolve().parent
BIG = 10 ** 2500
coordinates = st.integers(-BIG, BIG) | st.integers(-1000, 1000)
addresses = st.builds(b.Address, coordinates, coordinates, st.integers(0, 3), st.integers(0, 4),
                      st.integers(0, 31), st.integers(0, 409))


# --- Mathématique -------------------------------------------------------------------------

def test_constants_are_invertible():
    assert b.A1 * b.A1_INV % b.N == 1
    assert b.A2 * b.A2_INV % b.N == 1
    for constant in (b.A1, b.A2, b.B1, b.B2):
        assert 0 < constant < b.N
        assert len(b.to_digits(constant, b.SYMBOLS)) == b.SYMBOLS


@given(st.integers(0, b.N - 1))
def test_mix_is_a_bijection(x):
    assert b.unmix(b.mix(x)) == x
    assert b.mix(b.unmix(x)) == x


@given(st.integers(0, 25 ** 400))
def test_digits_round_trip(x):
    assert b.from_digits(b.to_digits(x, 401)) == x


@given(st.integers(0, 10 * b.N))
def test_pack_unpack_round_trip(packed):
    assert b.pack(b.unpack(packed)) == packed


@given(st.integers() | coordinates)
def test_zigzag_round_trip(value):
    assert b.zigzag(value) >= 0
    assert b.unzigzag(b.zigzag(value)) == value


def test_zigzag_order():
    assert [b.zigzag(v) for v in (0, -1, 1, -2, 2)] == [0, 1, 2, 3, 4]


@given(addresses)
def test_address_forms_round_trip(address):
    assert b.parse_address(address.full()) == address
    assert b.Address.from_json(json.loads(json.dumps(address.to_json()))) == address


# --- Pages et recherche de texte ------------------------------------------------------------

def test_page_shape_and_alphabet():
    lines = b.page_lines(b.Address(1, 1, 1, 1, 1, 1))
    assert len(lines) == 40 and {len(line) for line in lines} == {80}
    seen = set("".join(lines))
    assert seen <= set(b.ALPHABET) and not seen & set("kqwy")


def test_page_is_deterministic():
    address = b.Address(2 ** 62 - 1, -7, 2, 4, 31, 409)
    assert b.page_text(address) == b.page_text(b.Address(2 ** 62 - 1, -7, 2, 4, 31, 409))


@given(st.text(max_size=4000))
@settings(max_examples=80)
def test_search_text_round_trip(text):
    address, _tries = b.search_text(text)
    assert b.page_text(address) == b.pad(text)
    assert not b.address_is_image(address)


@pytest.mark.parametrize("text", [
    "",
    "la bibliotheque de babel",
    "".join(random.Random(7).choice(b.ALPHABET) for _ in range(3200)),
    "Kafka, Wittgenstein & Yeats : « Qu'œuvrent-ils ? » — Ça, l'été à Ýpres.\nFin.",
])
def test_search_text_named_cases(text):
    address, _tries = b.search_text(text)
    assert b.page_text(address) == b.pad(text)
    assert not b.address_is_image(address)


@given(addresses)
def test_search_of_a_page_shows_that_page(address):
    page = b.page_text(address)
    found, _tries = b.search_text(page)
    assert b.page_text(found) == page


@pytest.mark.parametrize("hexagon,level", [(-1, -1), (-12345, 678), (-(10 ** 40), -(10 ** 40) - 3), (5, -(2 ** 70))])
def test_negative_coordinates_round_trip(hexagon, level):
    address = b.Address(hexagon, level, 3, 0, 17, 300)
    assert b.unpack(b.pack(address)) == address
    found, _ = b.search_text(b.page_text(address))
    assert b.page_text(found) == b.page_text(address)


def test_text_tries_average():
    rng = random.Random(1)
    tries = [b.search_text("".join(rng.choice(b.ALPHABET) for _ in range(50)))[1] for _ in range(300)]
    assert sum(tries) / len(tries) < 1.2


def _common_prefix(a, c):
    n = 0
    while n < len(a) and a[n] == c[n]:
        n += 1
    return n


def test_neighbours_share_no_prefix_nor_suffix():
    rng = random.Random(3)
    pairs = []
    for _ in range(50):
        h = rng.choice([rng.randint(-50, 50), rng.randint(-BIG, BIG)])
        level = rng.randint(-20, 20)
        base = b.Address(h, level, rng.randint(0, 3), rng.randint(0, 4), rng.randint(0, 30), rng.randint(0, 408))
        step = rng.choice(["hexagon", "level", "wall", "shelf", "book", "page"])
        values = base.__dict__.copy()
        bound = {"wall": 3, "shelf": 4, "book": 31, "page": 409}.get(step)
        values[step] = values[step] + 1 if bound is None or values[step] < bound else values[step] - 1
        pairs.append((base, b.Address(**values)))
    for first, second in pairs:
        p, q = b.page_text(first), b.page_text(second)
        assert _common_prefix(p, q) <= 4, (first, second)
        assert _common_prefix(p[::-1], q[::-1]) <= 4, (first, second)


def test_mixing_spreads_high_and_low_digits():
    """Deux contenus qui diffèrent par un seul chiffre, bas ou haut : pages sans début ni fin communs.
    Une seule multiplication garderait communs tous les chiffres sous le chiffre modifié."""
    rng = random.Random(9)
    for k in (0, 1, 7, 100, 1600, 3000, 3199):
        x = rng.randrange(b.N)
        x2 = (x + rng.randint(1, 24) * 25 ** k) % b.N
        p = b.to_digits(b.mix(x), b.SYMBOLS)
        q = b.to_digits(b.mix(x2), b.SYMBOLS)
        assert _common_prefix(p, q) <= 4, k
        assert _common_prefix(p[::-1], q[::-1]) <= 4, k


@pytest.mark.parametrize("raw,expected", [
    ("Été À L'ÎLE", "ete a lile"),
    ("kiwi quay yoyo", "civi cuai ioio"),
    ("cœur, æther. Straße", "coeur, aether. strasse"),
    ("ligne 1\nligne\t2 !?;:", "ligne  ligne  "),
    ("ñandú çà", "nandu ca"),
])
def test_normalize(raw, expected):
    assert b.normalize(raw) == expected


def test_pad_and_truncation():
    assert b.pad("ab") == "ab" + " " * 3198
    assert b.pad("a" * 5000) == "a" * 3200


# --- Livres d'images ------------------------------------------------------------------------

def test_image_book_rate():
    rng = random.Random(11)
    hits = sum(b.is_image_book(rng.randint(-10 ** 6, 10 ** 6), rng.randint(-1000, 1000),
                               rng.randint(0, 3), rng.randint(0, 4), rng.randint(0, 31))
               for _ in range(10_000))
    assert 150 <= hits <= 250, hits


def test_image_book_ignores_page():
    address = b.Address(4, -9, 1, 2, 3, 0)
    assert all(b.address_is_image(b.Address(4, -9, 1, 2, 3, p)) == b.address_is_image(address) for p in range(410))


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
    address, _tries = b.search_image(width, height, rgba)
    assert b.address_is_image(address)
    assert b.page_digits(address) == b.quantize(width, height, rgba)


@given(st.integers(1, 12), st.integers(1, 12), st.data())
@settings(max_examples=25)
def test_image_round_trip_random(width, height, data):
    rgba = data.draw(st.binary(min_size=width * height * 4, max_size=width * height * 4))
    address, _ = b.search_image(width, height, rgba)
    assert b.address_is_image(address)
    assert b.page_digits(address) == b.quantize(width, height, rgba)


def test_letterbox_uses_darkest_ink():
    indices = b.quantize(10, 1, b"\xff\xff\xff\xff" * 10)   # bande horizontale : marges haut et bas
    assert indices[0] == 0 and indices[-1] == 0
    darkest = min(range(25), key=lambda i: sum(b.PALETTE[i]))
    assert darkest == 0


def test_image_tries_average():
    rng = random.Random(5)
    tries = [b.locate(rng.randrange(b.N), image=True)[1] for _ in range(200)]
    assert 25 <= sum(tries) / len(tries) <= 80


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
    address = b.Address.from_json(json.loads(capsys.readouterr().out)["address"])
    assert b.page_digits(address) == b.quantize(16, 16, rgba)


# --- Ligne de commande et service -------------------------------------------------------------

def test_cli_page_and_search_text(tmp_path, capsys):
    source = tmp_path / "texte.txt"
    source.write_text("Une phrase de Borges.", encoding="utf-8")
    assert b.main(["search-text", str(source)]) == 0
    full = capsys.readouterr().out.strip()
    assert b.main(["page", full]) == 0
    lines = capsys.readouterr().out.splitlines()
    assert lines[0].startswith("une phrase de borges.") and len(lines) == 40


def test_cli_bad_address(capsys):
    assert b.main(["page", "1:2:3"]) == 1
    assert "adresse" in capsys.readouterr().err


def _serve(lines):
    sink = io.BytesIO()
    b.serve(io.BytesIO("".join(line + "\n" for line in lines).encode("utf-8")), sink)
    return [json.loads(line) for line in sink.getvalue().decode("ascii").splitlines()]


def test_serve_protocol():
    address = {"hexagon": "-123456789012345678901234567890", "level": "7", "wall": 1, "shelf": 2, "book": 3, "page": 4}
    rgba = base64.b64encode(_gradient(20, 30)).decode()
    responses = _serve([
        json.dumps({"id": 1, "op": "ping"}),
        json.dumps({"id": 2, "op": "page", "address": address}),
        json.dumps({"id": 3, "op": "search_text", "text": "Ô temps, suspends ton vol"}),
        json.dumps({"id": 4, "op": "search_image", "width": 20, "height": 30, "rgba": rgba}),
        json.dumps({"id": 5, "op": "is_image_book", "books": [address, {k: v for k, v in address.items() if k != "page"}]}),
        json.dumps({"id": 6, "op": "display", "address": address}),
        json.dumps({"id": 7, "op": "palette"}),
        "",
        "pas du json",
        json.dumps({"id": 8, "op": "inconnue"}),
        json.dumps({"id": 9, "op": "page", "address": dict(address, wall=9)}),
        json.dumps({"id": 10, "op": "page"}),
        json.dumps([1, 2]),
        json.dumps({"id": 11, "op": "search_image", "width": 2, "height": 2, "rgba": "AAAA"}),
        json.dumps({"id": 12, "op": "page", "address": dict(address, wall=1.0)}),
    ])
    assert len(responses) == 14
    by_id = {r.get("id"): r for r in responses}
    assert by_id[1] == {"id": 1, "protocol": b.PROTOCOL}
    page = by_id[2]
    expected = b.page_lines(b.Address(-123456789012345678901234567890, 7, 1, 2, 3, 4))
    assert page["lines"] == expected and page["is_image"] is b.address_is_image(b.Address.from_json(address))
    found = b.Address.from_json(by_id[3]["address"])
    assert b.page_text(found) == b.pad("Ô temps, suspends ton vol")
    image_address = b.Address.from_json(by_id[4]["address"])
    assert b.address_is_image(image_address)
    assert b.page_digits(image_address) == b.quantize(20, 30, _gradient(20, 30))
    assert by_id[5]["is_image"] == [b.address_is_image(b.Address.from_json(address))] * 2
    assert by_id[6]["full"] == b.Address.from_json(address).full() and "hexagone" in by_id[6]["short"]
    assert len(by_id[7]["palette"]) == 25 and by_id[7]["width"] == 50 and by_id[7]["height"] == 64
    errors = [r for r in responses if "error" in r]
    assert len(errors) == 6
    assert {r.get("id") for r in errors} == {None, 8, 9, 10, 11}
    assert by_id[12]["lines"] == expected


def test_serve_image_page_carries_indices():
    rgba = _checkerboard(8, 8, 2)
    address, _ = b.search_image(8, 8, rgba)
    [response] = _serve([json.dumps({"op": "page", "address": address.to_json()})])
    assert response["is_image"] is True
    assert base64.b64decode(response["indices"]) == b.quantize(8, 8, rgba)
    [text_page] = _serve([json.dumps({"op": "page", "address": b.search_text("x")[0].to_json()})])
    assert text_page["is_image"] is False and "indices" not in text_page


def test_serve_subprocess():
    process = subprocess.run([sys.executable, "-X", "utf8", "-u", str(HERE / "babel.py"), "serve"],
                             input='{"id":"a","op":"ping"}\nnimporte quoi\n{"id":"b","op":"search_text","text":"été"}\n',
                             capture_output=True, text=True, encoding="utf-8", timeout=60)
    assert process.returncode == 0, process.stderr
    responses = [json.loads(line) for line in process.stdout.splitlines()]
    assert responses[0] == {"id": "a", "protocol": b.PROTOCOL}
    assert "error" in responses[1]
    assert b.page_text(b.Address.from_json(responses[2]["address"])).startswith("ete ")
