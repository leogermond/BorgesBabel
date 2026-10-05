"""Mise en page des textes du catalogue (tools/make_catalogue.py, typeset) : textes de démonstration."""

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tools"))

import babel as b  # noqa: E402
import make_catalogue as m  # noqa: E402


def lines_of(text: str) -> list[str]:
    composed = m.typeset(text)
    padded = composed.ljust(-(-len(composed) // b.CHARS) * b.CHARS)
    return [padded[i:i + b.CHARS] for i in range(0, len(padded), b.CHARS)]


DEMO = "Le titre\n\n" + "\n\n".join(" ".join(["lorem", "ipsum", "dolor", "amet"] * 40) for _ in range(3))


def test_words_never_cut_and_lines_of_80():
    lines = lines_of(DEMO)
    assert all(len(line) == b.CHARS for line in lines)
    read = [w for line in lines for w in line.split()]
    assert read == m.words_of(DEMO)
    m.check_layout(DEMO, m.typeset(DEMO))


def test_title_centred_and_paragraphs_separated():
    lines = lines_of(DEMO)
    assert lines[0].strip() == "le titre" and abs((len(lines[0]) - len(lines[0].lstrip())) - (len(lines[0]) - len(lines[0].rstrip()))) <= 1
    assert lines[1] == " " * b.CHARS and lines[2].strip()
    blanks = [i for i, line in enumerate(lines) if not line.strip()]
    assert len(blanks) >= 3


def test_heading_centred_with_blanks_and_double_blank_kept():
    text = "Titre\n\nun premier paragraphe.\n\n\nIntertitre\n\nle suivant.\n"
    lines = lines_of(text)
    assert [line.strip() for line in lines[:8]] == ["titre", "", "un premier paragraphe.", "", "", "intertitre", "", "le suivant."]
    assert lines[5].strip() == "intertitre" and lines[5].startswith(" ") and lines[5] == lines[5].center(b.CHARS)


def test_heading_needs_no_final_punctuation_and_fewer_than_40_characters():
    text = "T\n\nPremier.\n\nIntertitre sans point\n\nSuite.\n\nUne ligne seule avec un point final.\n\nSuite."
    kinds = [block["kind"] for block in m.blocks_of(text)]
    assert kinds == ["title", "paragraph", "heading", "paragraph", "paragraph", "paragraph"]
    long_line = "x" * 40 + " fin"
    kinds = [block["kind"] for block in m.blocks_of("T\n\n" + long_line + "\n\nSuite.")]
    assert kinds == ["title", "paragraph", "paragraph"]


def test_page_never_starts_with_a_blank_line():
    paragraph = " ".join(["mot"] * 25)          # 99 symboles : 2 lignes
    text = "Titre\n\n" + "\n\n".join([paragraph] * 40)
    lines = lines_of(text)
    for page in range(0, len(lines), b.LINES):
        assert lines[page].strip()


def test_heading_kept_with_next_paragraph():
    paragraph = "mot " * 19                     # 3 lignes en tout avec le suivant
    body = "\n\n".join(["un paragraphe de " + paragraph] * 12)
    for n in range(1, 14):
        filler = " ".join(["x"] * 1)
        text = "Titre\n\n" + "\n\n".join(["bla " * 30] * n) + "\n\nIntertitre\n\n" + body
        lines = lines_of(text)
        at = next(i for i, line in enumerate(lines) if line.strip() == "intertitre")
        assert at % b.LINES <= b.LINES - 3 or at % b.LINES == 0
        assert lines[at + 1] == " " * b.CHARS and lines[at + 2].strip()


def test_word_longer_than_a_line_is_the_only_cut():
    text = "Titre\n\n" + "a" * 100 + " fin"
    lines = lines_of(text)
    assert lines[2] == "a" * 80 and lines[3].startswith("a" * 20 + " fin")


def test_forbidden_letters_assertion():
    m.check_forbidden_letters("mode_d_emploi", "touche entree pour avancer")
    for letter in "qkwyQKWY":
        with pytest.raises(SystemExit):
            m.check_forbidden_letters("mode_d_emploi", "un " + letter + " de trop")


def test_forbidden_letters_found_through_accents():
    for text in ("un ý isole", "UN Ÿ ISOLE", "un ẃ isole", "un ḱ isole", "un Ý isole"):
        with pytest.raises(SystemExit):
            m.check_forbidden_letters("mode_d_emploi", text)
    m.check_forbidden_letters("mode_d_emploi", "un été à l'île")


def test_elisions_and_short_hyphen_parts_are_unbreakable_units():
    assert m.units_of("l'espace d'or, lui-même, peut-être, qu'il vis-à-vis") == [
        "l espace", "d or,", "lui meme,", "peut", "etre,", "cu il", "vis a vis"]
    assert m.units_of("a : b « mot » ;") == ["a,", "b", "mot,"]


def test_no_dangling_elision_at_a_line_end():
    for shift in range(0, 12):
        text = "Titre\n\n" + "x" * shift + " " + " ".join(["mot l'autre lui-même d'or"] * 30)
        lines = lines_of(text)
        for line, following in zip(lines, lines[1:]):
            last = line.split()[-1] if line.strip() else ""
            if last in ("l", "d", "lui") and following.strip():
                assert False, (last, shift)
        m.check_layout(text, m.typeset(text))


def test_fold_table_is_up_to_date():
    import make_fold_table
    make_fold_table.main(["--check"])
