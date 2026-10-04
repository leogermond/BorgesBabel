#!/usr/bin/env python3
"""Compose et rend la musique d'ambiance : audio/ambiance.ogg (≈ 14 min, boucle sans couture).

Bibliothèque standard uniquement pour la composition et la synthèse (déterministe, graine fixe).
ffmpeg ne sert qu'à encoder le WAV en OGG Vorbis (outil de développement, absent du jeu).

    python3 tools/make_ambiance.py          rend le WAV dans .foreman/scratch/, encode audio/ambiance.ogg
    python3 tools/make_ambiance.py --map    imprime la carte des sections (tempo, mètre, mode) sans rendre
    python3 tools/make_ambiance.py --check  mesure le WAV rendu : niveaux, couture, non-répétition

Composition. Le bourdon de ré (ré 2, ré 3, la 2) sonne du début à la fin avec des cycles entiers sur la durée
totale : sa phase et son niveau sont identiques au premier et au dernier échantillon, donc la fin de la boucle
s'écoule dans l'ouverture. Neuf sections contrastées se succèdent, sans aucune répétition littérale :
  prélude (cloches lentes) · premier rayon (mélodie à l'archet, ré dorien) · galerie des miroirs (3/4, la éolien,
  motifs renversés) · silence · escalier en spirale (6/8, sol dorien, arpèges animés) · hexagone central
  (5/4 et 4/4 alternés, si♭ lydien, sommet) · passage des étagères (mi phrygien, rétrogrades) · mémoire (le motif
  initial en valeurs longues, aux cloches) · coda (retour au bourdon).
Chaque section enchaîne des périodes de phrases antécédent / conséquent de 4 bars (demi-cadence puis cadence
modale), harmonisées à nouveau à chaque fois, et reprend trois motifs (A soupir, B chute, C ascension) transformés
(inversion, augmentation, diminution, rétrograde). Le tempo glisse dans chaque section et ralentit à chaque fin de
phrase (rubato). Voix : nappe additive désaccordée, basse sinusoïdale, archet soufflé avec vibrato, pizzicato de
harpe doux, cloche inharmonique, tout en attaques arrondies (aucune percussion, aucun transitoire sec).
Le rendu passe par une réverbération de Schroeder circulaire (la queue de la fin retombe sur le début).
"""
import array
import bisect
import math
import random
import subprocess
import sys
import wave
from operator import add, mul
from pathlib import Path

SR = 22050
SEED = 1941
PRE = 14.0                      # bourdon seul avant la première mesure
TAIL = 14.0                     # bourdon seul après la dernière mesure
TARGET_RMS_DB = -20.0
PEAK_LIMIT_DB = -3.5
REVERB_TAIL_S = 10.0

ROOT = Path(__file__).resolve().parent.parent
WAV_PATH = ROOT / ".foreman" / "scratch" / "ambiance.wav"
OGG_PATH = ROOT / "audio" / "ambiance.ogg"

TWO_PI = 2.0 * math.pi
sin, exp = math.sin, math.exp

DORIAN = [0, 2, 3, 5, 7, 9, 10]
AEOLIAN = [0, 2, 3, 5, 7, 8, 10]
LYDIAN = [0, 2, 4, 6, 7, 9, 11]
PHRYGIAN = [0, 1, 3, 5, 7, 8, 10]

M44 = (4, (2, 2))
M34 = (3, (3,))
M68 = (3, (1.5, 1.5))           # 6/8 : trois temps de croche pointée comptés en noires, deux groupes
M54 = (5, (3, 2))
METRE_NAMES = {M44: "4/4", M34: "3/4", M68: "6/8", M54: "5/4"}

# Motifs : (degré relatif au premier, durée en temps)
MOTIFS = {
    "A": [(0, 1.5), (2, 0.5), (1, 1.0), (-1, 1.0)],     # soupir : tierce montante, chute
    "B": [(0, 1.0), (-1, 1.0), (-2, 2.0)],              # chute par degrés conjoints
    "C": [(0, 1.0), (1, 1.0), (2, 1.0), (4, 1.0)],      # ascension et saut
}

# Progressions (degrés de la fondamentale) évitant les accords diminués du mode.
PROGS = {
    "dorian": dict(ant=[[0, 3, 2, 4], [0, 2, 3, 4], [0, 3, 6, 4], [0, 6, 3, 1]],
                   con=[[0, 3, 6, 0], [2, 3, 6, 0], [0, 1, 6, 0], [3, 1, 6, 0]]),
    "aeolian": dict(ant=[[0, 5, 3, 4], [0, 2, 5, 4], [0, 6, 5, 4], [0, 3, 6, 4]],
                    con=[[0, 5, 6, 0], [2, 3, 6, 0], [5, 3, 6, 0], [0, 3, 6, 0]]),
    "lydian": dict(ant=[[0, 1, 4, 2], [0, 5, 2, 4], [0, 2, 5, 1]],
                   con=[[0, 5, 1, 0], [2, 5, 1, 0], [0, 4, 1, 0]]),
    "phrygian": dict(ant=[[0, 1, 0, 6], [0, 3, 5, 6], [0, 2, 1, 6]],
                     con=[[0, 3, 1, 0], [2, 6, 1, 0], [5, 6, 1, 0]]),
}

SECTIONS = [
    dict(name="Prélude : le bourdon", feel="cloches rares sur le bourdon, quasi immobile",
         mode=DORIAN, fam="dorian", modename="ré dorien", tonic=50, bpm=(40, 44), n=2, bars=[[M44] * 4],
         lead=["bell"], lead_center=12, amp=2, activity=0.05, acc=["none"], pad_center=58,
         motifs=[("A", ["aug"]), ("A", ["aug", "inv"])], shifts=[0, 2],
         mix=dict(pad=0.55, bass=0.5, lead=0.9, acc=0.5, bell=0.9), arc=[(0, 0.22), (1, 0.42)], bell_cad=0.9),
    dict(name="Premier rayon", feel="mélodie lente à l'archet, arpèges qui s'installent",
         mode=DORIAN, fam="dorian", modename="ré dorien", tonic=50, bpm=(58, 62), n=8, bars=[[M44] * 4],
         lead=["bow"], lead_center=9, amp=3, activity=0.30,
         acc=["none", "none", "sparse", "sparse", "arp_slow", "arp_slow", "arp_slow", "sparse"], pad_center=58,
         motifs=[("A", []), ("A", []), ("B", []), ("A", ["inv"]), ("C", []), ("A", ["dim"]), ("B", ["inv"]), ("A", ["retro"])],
         shifts=[0, 0, -2, 1, 3, 0, -1, 2],
         mix=dict(pad=0.8, bass=0.8, lead=1.0, acc=0.8, bell=0.7), arc=[(0, 0.40), (0.5, 0.72), (1, 0.85)], bell_cad=0.6),
    dict(name="Galerie des miroirs", feel="valse de harpe, motifs renversés comme dans un miroir",
         mode=AEOLIAN, fam="aeolian", modename="la éolien", tonic=57, bpm=(72, 78), n=12, bars=[[M34] * 4],
         lead=["pluck", "pluck", "bow", "pluck"], lead_center=7, amp=3, activity=0.40,
         acc=["waltz"], pad_center=60,
         motifs=[("B", ["inv"]), ("A", ["inv"]), ("C", ["inv"]), ("A", ["inv", "dim"]), ("B", ["inv", "dim"]), ("C", ["inv", "aug"])],
         shifts=[0, 1, -1, 2, 0, 3, -2, 1, 0, 2, -1, 0],
         mix=dict(pad=0.7, bass=0.7, lead=0.95, acc=0.85, bell=0.6), arc=[(0, 0.50), (0.5, 0.80), (1, 0.55)], bell_cad=0.6),
    dict(name="Silence", feel="presque rien : le bourdon et sept cloches lointaines",
         mode=AEOLIAN, fam="aeolian", modename="la éolien", tonic=57, bpm=(44, 44), n=2, bars=[[M44] * 4],
         lead=[None], lead_center=7, amp=2, activity=0.1, acc=["none"], pad_center=58, motifs=[("A", [])], shifts=[0],
         mix=dict(pad=0.35, bass=0.25, lead=0.0, acc=0.0, bell=0.0), arc=[(0, 0.16), (1, 0.16)], bell_cad=0.0, scatter=7),
    dict(name="Escalier en spirale", feel="arpèges fluides, mélodie plus vive, crescendo",
         mode=DORIAN, fam="dorian", modename="sol dorien", tonic=55, bpm=(80, 92), n=14, bars=[[M68] * 4],
         lead=["bow", "pluck", "bow"], lead_center=8, amp=4, activity=0.65,
         acc=["arp_flow"], pad_center=60,
         motifs=[("C", []), ("B", ["dim"]), ("A", ["dim"]), ("C", ["inv"]), ("B", ["inv", "dim"]), ("A", ["dim", "retro"]), ("C", ["dim"])],
         shifts=[0, 2, -1, 3, 1, -2, 0, 4, 1, -1, 2, 0, 3, -1],
         mix=dict(pad=0.75, bass=0.7, lead=1.0, acc=0.9, bell=0.6), arc=[(0, 0.45), (0.6, 0.90), (1, 0.70)], bell_cad=0.5),
    dict(name="L'hexagone central", feel="sommet : 5/4 et 4/4 alternés, lydien lumineux, archet haut",
         mode=LYDIAN, fam="lydian", modename="si♭ lydien", tonic=46, bpm=(60, 68), n=6,
         bars=[[M54, M54, M44, M54], [M54, M44, M54, M44]],
         lead=["bow"], lead_center=12, amp=4, activity=0.45,
         acc=["arp_slow", "arp_flow"], pad_center=62,
         motifs=[("A", []), ("C", ["inv"]), ("B", ["aug"]), ("A", ["inv", "dim"]), ("C", ["retro"]), ("A", ["aug"])],
         shifts=[0, 3, 1, 4, 2, 0],
         mix=dict(pad=1.0, bass=0.9, lead=1.1, acc=0.85, bell=0.8), arc=[(0, 0.50), (0.7, 1.00), (1, 0.60)], bell_cad=0.9),
    dict(name="Passage des étagères", feel="mi phrygien sombre, rétrogrades, pizzicati épars",
         mode=PHRYGIAN, fam="phrygian", modename="mi phrygien", tonic=52, bpm=(56, 52), n=6,
         bars=[[M44, M44, M34, M44], [M34, M34, M44, M44]],
         lead=["pluck", "bow"], lead_center=9, amp=3, activity=0.30,
         acc=["sparse", "arp_slow"], pad_center=58,
         motifs=[("A", ["retro"]), ("B", ["retro", "dim"]), ("C", ["aug"]), ("A", ["retro", "inv"]), ("B", ["inv", "aug"]), ("C", ["retro"])],
         shifts=[0, -2, 2, 1, -1, 3],
         mix=dict(pad=0.8, bass=0.8, lead=0.95, acc=0.7, bell=0.7), arc=[(0, 0.52), (1, 0.32)], bell_cad=0.7),
    dict(name="Mémoire", feel="le motif initial en valeurs longues, aux cloches, ralenti",
         mode=DORIAN, fam="dorian", modename="ré dorien", tonic=50, bpm=(54, 42), n=5, bars=[[M44] * 4],
         lead=["bell"], lead_center=11, amp=3, activity=0.10,
         acc=["none"], pad_center=56,
         motifs=[("A", ["aug"]), ("A", ["aug", "inv"]), ("B", ["aug"]), ("A", ["aug", "retro"]), ("C", ["aug"])],
         shifts=[0, 1, -1, 2, 0],
         mix=dict(pad=0.85, bass=0.8, lead=1.0, acc=0.0, bell=1.0), arc=[(0, 0.50), (1, 0.24)], bell_cad=0.9),
    dict(name="Coda : retour au bourdon", feel="les cloches s'espacent, tout se résorbe dans le bourdon",
         mode=DORIAN, fam="dorian", modename="ré dorien", tonic=50, bpm=(40, 36), n=2, bars=[[M34] * 4],
         lead=["bell"], lead_center=10, amp=2, activity=0.05, acc=["none"], pad_center=56,
         motifs=[("A", ["aug", "dim"]), ("B", ["aug"])], shifts=[0, -1],
         mix=dict(pad=0.50, bass=0.4, lead=0.8, acc=0.0, bell=0.8), arc=[(0, 0.24), (0.6, 0.12), (1, 0.0)], bell_cad=0.8,
         scatter=3),
]


# --------------------------------------------------------------------------- composition

def pitch(tonic: int, mode: list, deg: int) -> int:
    return tonic + 12 * (deg // 7) + mode[deg % 7]


def hz(midi: float) -> float:
    return 440.0 * 2.0 ** ((midi - 69.0) / 12.0)


def transform(motif: list, ops: list) -> list:
    m = list(motif)
    for op in ops:
        if op == "inv":
            m = [(-d, b) for d, b in m]
        elif op == "aug":
            m = [(d, b * 2.0) for d, b in m]
        elif op == "dim":
            m = [(d, max(0.5, math.floor(b + 0.5) / 2.0)) for d, b in m]
        elif op == "retro":
            r = m[::-1]
            base = r[0][0]
            m = [(d - base, b) for d, b in r]
    return m


class Tempo:
    """Correspondance temps musical (en temps) → secondes : glissando de tempo et ralenti en fin de phrase."""
    STEP = 32

    def __init__(self, total: float, bpm0: float, bpm1: float, ends: list) -> None:
        self.cum = [0.0]
        n = int(math.ceil(total * self.STEP)) + 1
        for i in range(n):
            b = (i + 0.5) / self.STEP
            bpm = bpm0 + (bpm1 - bpm0) * min(1.0, b / total)
            k = bisect.bisect_left(ends, b)
            if k < len(ends):
                d = ends[k] - b
                bpm *= 1.0 - 0.14 * max(0.0, 1.0 - d / 2.5) ** 2
            self.cum.append(self.cum[-1] + 60.0 / bpm / self.STEP)

    def time(self, beat: float) -> float:
        x = max(0.0, beat) * self.STEP
        i = min(int(x), len(self.cum) - 2)
        return self.cum[i] + (self.cum[i + 1] - self.cum[i]) * (x - i)


def expand(tpl: list, bars: int, rng: random.Random, pool: list) -> list:
    if bars == 4:
        return list(tpl)
    if bars == 6:
        return [tpl[0], tpl[1], tpl[2], tpl[1], tpl[2], tpl[3]]
    if bars == 5:
        return [tpl[0], tpl[1], tpl[2], tpl[2], tpl[3]]
    return list(tpl) + list(rng.choice(pool))


def chord_degrees(root: int, ext: str) -> list:
    d = [root, root + 2, root + 4]
    if ext == "7":
        d.append(root + 6)
    elif ext == "9":
        d.append(root + 8)
    return d


def voicing(sec: dict, root: int, ext: str) -> list:
    """Accord ouvert autour de pad_center : chaque degré prend la hauteur la plus proche de sa cible."""
    out = []
    for k, d in enumerate(chord_degrees(root, ext)):
        pc = pitch(sec["tonic"], sec["mode"], d) % 12
        target = sec["pad_center"] + (-7, -2, 3, 8)[k]
        m = target + (pc - target + 6) % 12 - 6          # hauteur de même classe la plus proche de la cible
        out.append(m if m >= 45 else m + 12)
    return sorted(out)


def bass_midi(sec: dict, root: int) -> int:
    m = pitch(sec["tonic"], sec["mode"], root)
    while m > 46:
        m -= 12
    while m < 34:
        m += 12
    return m


def pick_duration(rng: random.Random, rem: float, activity: float) -> float:
    target = 3.0 * (1.0 - activity) + 0.5
    opts = [d for d in (0.5, 1.0, 1.5, 2.0, 3.0, 4.0) if d <= rem + 1e-6]
    if not opts:
        return rem
    weights = [exp(-((d - target) ** 2) / 1.2) + 0.02 for d in opts]
    x = rng.random() * sum(weights)
    for d, w in zip(opts, weights):
        x -= w
        if x <= 0:
            return d
    return opts[-1]


def make_melody(rng: random.Random, sec: dict, kind: str, bars: list, roots: list, exts: list, motif: list, start_target: int) -> list:
    """Notes (degré absolu, début en temps, durée) d'une phrase de 4 à 8 bars avec cadence."""
    length = sum(b[0] for b in bars)
    starts = [0.0]
    for b in bars:
        starts.append(starts[-1] + b[0])
    final_len = min(float(bars[-1][0]), 3.0)
    fstart = length - final_len
    center, amp = sec["lead_center"], sec["amp"]
    lo, hi = center - 6, center + 6

    def bar_at(t: float) -> int:
        return max(i for i in range(len(bars)) if starts[i] <= t + 1e-9)

    def chordset(t: float) -> set:
        i = bar_at(t)
        return {d % 7 for d in chord_degrees(roots[i], exts[i])}

    def strong(t: float, dur: float) -> bool:
        i = bar_at(t)
        off = t - starts[i]
        edge = 0.0
        for g in [0.0] + list(bars[i][1]):
            if abs(off - edge) < 1e-6:
                return True
            edge += g
        return dur >= 2.0

    def shape(p: float) -> float:
        return sin(math.pi * (p ** 0.85 if kind == "ant" else p ** 1.4))

    first_set = chordset(0.0)
    start = min((d for d in range(center - 10, center + 11) if d % 7 in first_set), key=lambda d: abs(d - start_target))
    notes = []
    t = 0.0
    for rel, beats in motif:
        if t + beats > fstart - 1.0:
            break
        notes.append([start + rel, t, beats])
        t += beats
    cur = notes[-1][0] if notes else start
    if not notes:
        notes.append([start, 0.0, 1.0])
        t, cur = 1.0, start
    last_set = {d % 7 for d in chord_degrees(roots[-1], exts[-1])}
    if kind == "con":
        cad = min((d for d in range(center - 12, center + 13) if d % 7 == 0), key=lambda d: abs(d - cur))
    else:
        cands = [d for d in range(center - 8, center + 9) if d % 7 in last_set and d % 7 != 0 and d != cur]
        cad = min(cands, key=lambda d: abs(d - cur) + 0.2 * abs(d - center))
    while t < fstart - 1e-6:
        rem = min(starts[bar_at(t) + 1] - t, fstart - t)
        dur = pick_duration(rng, rem, sec["activity"])
        left = fstart - (t + dur)
        if 1e-6 < left < 0.45:
            dur = fstart - t
        if abs(t + dur - fstart) < 1e-6:
            d = min((cad + 1, cad - 1), key=lambda x: abs(x - cur))
        else:
            target = center + amp * shape(t / length)
            best, best_s = cur, 1e9
            cs = chordset(t)
            for step in (-3, -2, -1, 0, 1, 2, 3):
                if step == 0 and rng.random() < 0.85:
                    continue
                d0 = cur + step
                s = abs(d0 - target) * 0.55 + abs(step) * 0.25 + rng.random() * 0.9
                if strong(t, dur):
                    s += 0.0 if d0 % 7 in cs else 1.6
                if d0 < lo or d0 > hi:
                    s += 3.0
                if s < best_s:
                    best, best_s = d0, s
            d = best
        notes.append([d, t, dur])
        cur = d
        t += dur
    notes.append([cad, fstart, final_len + 1.0])      # la note finale résonne un temps de plus
    return notes


def arc_level(arc: list, x: float) -> float:
    for (x0, v0), (x1, v1) in zip(arc, arc[1:]):
        if x <= x1:
            u = 0.0 if x1 == x0 else (x - x0) / (x1 - x0)
            return v0 + (v1 - v0) * u
    return arc[-1][1]


def accompaniment(kind: str, bar_len: float, groups: tuple, vc: list) -> list:
    """(décalage en temps, hauteur MIDI, vélocité relative) pour un bar."""
    out = []
    m = len(vc)
    if kind == "sparse":
        out.append((0.0, vc[-1], 0.6))
        if bar_len >= 4:
            out.append((groups[0], vc[2 % m], 0.4))
    elif kind == "arp_slow":
        seq = [0, 1, 2, 3, 2, 1]
        for k in range(int(bar_len)):
            i = seq[k % len(seq)] % m
            out.append((float(k), vc[i] + 12 * (k % 5 == 4), 0.55 if k else 0.7))
    elif kind == "arp_flow":
        cyc = list(range(m)) + list(range(m - 2, 0, -1))
        edges = []
        e = 0.0
        for g in groups:
            edges.append(e)
            e += g
        for j in range(int(bar_len * 2)):
            off = j * 0.5
            out.append((off, vc[cyc[j % len(cyc)]] + 12, 0.85 if off in edges else 0.5))
    elif kind == "waltz":
        out.append((0.0, vc[0], 0.7))
        out.append((1.0, vc[2 % m], 0.45))
        out.append((2.0, vc[1 % m] + 12, 0.45))
    return out


def compose() -> dict:
    rng = random.Random(SEED)
    events = []      # (voix, début s, durée s, midi, vélocité)
    infos = []
    sigs = []
    t = PRE
    for si, sec in enumerate(SECTIONS):
        fam, mode, tonic = sec["fam"], sec["mode"], sec["tonic"]
        phrases = []
        beat = 0.0
        for pi in range(sec["n"]):
            bars = sec["bars"][pi % len(sec["bars"])]
            kind = "ant" if pi % 2 == 0 else "con"
            pool = PROGS[fam][kind]
            roots = expand(rng.choice(pool), len(bars), rng, pool)
            exts = []
            for k in range(len(bars)):
                final = (kind == "con" and k == len(bars) - 1)
                major9 = pitch(tonic, mode, roots[k] + 8) - pitch(tonic, mode, roots[k]) == 14
                options = ["", "9"] if final else ["7", "7", "9", ""]
                exts.append(rng.choice([o for o in options if o != "9" or major9]))
            ph = dict(kind=kind, bars=bars, roots=roots, exts=exts, beat0=beat, len=float(sum(b[0] for b in bars)))
            phrases.append(ph)
            beat += ph["len"]
        total = beat
        tm = Tempo(total, sec["bpm"][0], sec["bpm"][1], [p["beat0"] + p["len"] for p in phrases])
        t0 = t
        mix = sec["mix"]

        def T(b: float) -> float:
            return t0 + tm.time(b)

        for pi, ph in enumerate(phrases):
            b0 = ph["beat0"]
            # nappe et basse, un accord par bar
            bar_b = b0
            pad_prev = None
            for k, (blen, groups) in enumerate(ph["bars"]):
                root, ext = ph["roots"][k], ph["exts"][k]
                vc = voicing(sec, root, ext)
                lvl = arc_level(sec["arc"], bar_b / total)
                ts, te = T(bar_b), T(bar_b + blen)
                if mix["pad"] > 0:
                    for m in vc:
                        events.append(("pad", ts, te - ts, m, lvl * mix["pad"]))
                    events.append(("bass", ts, te - ts, bass_midi(sec, root), lvl * mix["bass"]))
                acc = sec["acc"][pi % len(sec["acc"])]
                if mix["acc"] > 0:
                    for off, m, v in accompaniment(acc, blen, groups, vc):
                        events.append(("pluck", T(bar_b + off), 0.0, m, lvl * mix["acc"] * v))
                bar_b += blen
            lead = sec["lead"][pi % len(sec["lead"])]
            mname, ops = sec["motifs"][pi % len(sec["motifs"])]
            motif = transform(MOTIFS[mname], ops)
            target = sec["lead_center"] + sec["shifts"][pi % len(sec["shifts"])]
            notes = make_melody(rng, sec, ph["kind"], ph["bars"], ph["roots"], ph["exts"], motif, target)
            sigs.append((si, pi, tuple((d, round(b, 2), round(u, 2)) for d, b, u in notes), tuple(ph["roots"])))
            if lead:
                for d, b, u in notes:
                    x = b / ph["len"]
                    hair = 0.78 + 0.22 * sin(math.pi * min(1.0, x))
                    lvl = arc_level(sec["arc"], (b0 + b) / total)
                    ts, te = T(b0 + b), T(b0 + b + u)
                    events.append((lead, ts, te - ts, pitch(tonic, mode, d), lvl * mix["lead"] * hair))
            # cloche de cadence : la tonique (conséquent) ou la quinte de l'accord (antécédent)
            if rng.random() < sec["bell_cad"] * (1.0 if ph["kind"] == "con" else 0.5) and mix["bell"] > 0:
                d, b, u = notes[-1]
                lvl = arc_level(sec["arc"], (b0 + b) / total)
                base = pitch(tonic, mode, d) + (12 if ph["kind"] == "con" else 0)
                events.append(("bell", T(b0 + b), 0.0, base + 12, 0.7 * lvl * mix["bell"]))
        t_end = T(total)
        if sec.get("scatter"):
            pent = [0, 1, 2, 4, 5]
            n = sec["scatter"]
            times = sorted(rng.uniform(t0 + 3.0, t_end - 7.0) for _ in range(n))
            for ts in times:
                d = rng.choice(pent) + 7 * rng.choice([2, 3])
                lvl = arc_level(sec["arc"], (ts - t0) / (t_end - t0))
                events.append(("bell", ts, 0.0, pitch(tonic, mode, d), rng.uniform(0.55, 0.9) * max(0.4, lvl * 2.2)))
        infos.append(dict(name=sec["name"], feel=sec["feel"], start=t0, end=t_end, bpm=sec["bpm"],
                          metres=sorted({METRE_NAMES[b] for p in phrases for b in p["bars"]}),
                          mode=sec["modename"], bars=sum(len(p["bars"]) for p in phrases), phrases=len(phrases)))
        t = t_end
    total_s = t + TAIL
    drone_pts = [(0.0, 1.0), (PRE, 1.0)]
    for sec, info in zip(SECTIONS, infos):
        drone_pts.append(((info["start"] + info["end"]) * 0.5, 0.55 if sec["name"].startswith("Silence") else 0.8 if sec["name"].startswith(("Prélude", "Coda")) else 0.45))
    drone_pts += [(total_s - TAIL, 1.0), (total_s, 1.0)]
    return dict(events=events, sections=infos, signatures=sigs, total=total_s, drone=drone_pts)


def fmt_time(s: float) -> str:
    return "%d:%02d" % (int(s) // 60, int(s) % 60)


def print_map(score: dict) -> None:
    print("durée totale %s (%.1f s, boucle comprise), %d événements" % (fmt_time(score["total"]), score["total"], len(score["events"])))
    print("%-27s %-11s %-7s %-14s %-12s %s" % ("section", "temps", "bpm", "mètre", "mode", "caractère"))
    for i in score["sections"]:
        bpm = "%d→%d" % i["bpm"] if i["bpm"][0] != i["bpm"][1] else "%d" % i["bpm"][0]
        print("%-27s %-11s %-7s %-14s %-12s %s" % (i["name"], fmt_time(i["start"]) + "–" + fmt_time(i["end"]), bpm,
                                                    "+".join(i["metres"]), i["mode"], i["feel"]))


# --------------------------------------------------------------------------- synthèse

CH = 1 << 18
_RAMPS = {}
_CACHE = {}


def zeros(n: int) -> array.array:
    return array.array("f", bytes(4 * n))


def ramp_up(n: int) -> list:
    r = _RAMPS.get(n)
    if r is None:
        r = [sin(0.5 * math.pi * i / n) ** 2 for i in range(n)]
        _RAMPS[n] = r
    return r


def make_env(total: int, a: int, r: int) -> list:
    q = 441
    a = max(q, min(total // 2, a) // q * q)
    r = max(q, min(total - a, r) // q * q)
    return ramp_up(a) + [1.0] * (total - a - r) + ramp_up(r)[::-1]


def mix_into(dst: array.array, start: int, wave_: list, gain: float) -> None:
    if start >= len(dst) or gain <= 0.0:
        return
    end = min(len(dst), start + len(wave_))
    seg = dst[start:end]
    dst[start:end] = array.array("f", [m + gain * w for m, w in zip(seg, wave_)])


def pad_note(f: float, dur: float) -> list:
    rel = min(3.2, 0.9 * dur + 0.5)
    n = int((dur + rel) * SR)
    env = make_env(n, int(min(2.4, 0.45 * dur + 0.3) * SR), int(rel * SR))
    w1 = TWO_PI * f * 0.9991 / SR
    w2 = TWO_PI * f * 1.0009 / SR
    return [e * (sin(w1 * i) + sin(w2 * i) + 0.25 * (sin(2 * w1 * i + 0.8) + sin(2 * w2 * i + 1.7)))
            for i, e in enumerate(env)]


def bass_note(f: float, dur: float) -> list:
    rel = min(2.5, 0.8 * dur + 0.4)
    n = int((dur + rel) * SR)
    env = make_env(n, int(min(1.2, 0.35 * dur + 0.2) * SR), int(rel * SR))
    w = TWO_PI * f / SR
    return [e * (sin(w * i) + 0.30 * sin(2 * w * i + 0.5)) for i, e in enumerate(env)]


_BREATH = None


def breath_table() -> list:
    global _BREATH
    if _BREATH is None:
        rr = random.Random(SEED + 7)
        s, out = 0.0, []
        for _ in range(3 * SR):
            s += 0.30 * (rr.uniform(-1.0, 1.0) - s)
            out.append(s)
        _BREATH = out
    return _BREATH


def bow_note(f: float, dur: float, rr: random.Random) -> list:
    rel = 0.45
    n = int((dur + rel) * SR)
    env = make_env(n, int(min(0.30, 0.4 * dur) * SR), int(rel * SR))
    w = TWO_PI * f / SR
    vr_hz = rr.uniform(4.6, 5.3)
    vr = TWO_PI * vr_hz / SR
    vi = f * 0.0035 / vr_hz
    d0, d1 = int(0.35 * SR), int(0.60 * SR)
    vib = [0.0] * min(n, d0) + [(i / d1) for i in range(d1)]
    vib = (vib + [1.0] * n)[:n]
    br = breath_table()
    off = rr.randrange(len(br))
    noise = ((br * (n // len(br) + 2))[off:off + n])
    return [e * (0.045 * z + sin(p) + 0.38 * sin(2 * p) + 0.14 * sin(3 * p) + 0.05 * sin(4 * p))
            for i, (e, v, z) in enumerate(zip(env, vib, noise))
            for p in (w * i + vi * v * sin(vr * i),)]


def bell_wave(midi: int) -> list:
    key = ("bell", midi)
    if key not in _CACHE:
        f = hz(midi)
        n = 9 * SR
        env = make_env(n, int(0.012 * SR), 3 * SR)
        parts = [(1.0, 1.00, 3.4), (2.0, 0.22, 2.6), (2.76, 0.30, 2.2), (4.07, 0.10, 1.4), (5.40, 0.06, 0.9)]
        ps = [(TWO_PI * f * r / SR, a, 1.0 / (d * SR)) for r, a, d in parts]
        (w1, a1, k1), (w2, a2, k2), (w3, a3, k3), (w4, a4, k4), (w5, a5, k5) = ps
        _CACHE[key] = [e * (a1 * exp(-i * k1) * sin(w1 * i) + a2 * exp(-i * k2) * sin(w2 * i)
                            + a3 * exp(-i * k3) * sin(w3 * i) + a4 * exp(-i * k4) * sin(w4 * i)
                            + a5 * exp(-i * k5) * sin(w5 * i)) * 0.6 for i, e in enumerate(env)]
    return _CACHE[key]


def pluck_wave(midi: int) -> list:
    key = ("pluck", midi)
    if key not in _CACHE:
        f = hz(midi)
        n = int(3.6 * SR)
        env = make_env(n, int(0.008 * SR), int(1.0 * SR))
        parts = [(1.0, 1.0, 1.3), (2.0, 0.5, 0.8), (3.0, 0.22, 0.45), (4.0, 0.10, 0.28)]
        (w1, a1, k1), (w2, a2, k2), (w3, a3, k3), (w4, a4, k4) = [
            (TWO_PI * f * r / SR, a, 1.0 / (d * SR)) for r, a, d in parts]
        _CACHE[key] = [e * (a1 * exp(-i * k1) * sin(w1 * i) + a2 * exp(-i * k2) * sin(w2 * i)
                            + a3 * exp(-i * k3) * sin(w3 * i) + a4 * exp(-i * k4) * sin(w4 * i)) * 0.7
                       for i, e in enumerate(env)]
    return _CACHE[key]


DRONE_GAIN = 0.045
GAIN = dict(pad=0.050, bass=0.105, bow=0.150, pluck=0.150, bell=0.140)


def drone_level(pts: list, t: float, total: float) -> float:
    """Niveau du bourdon : interpolation en cosinus entre points de contrôle, souffle lent périodique sur la boucle."""
    xs = [p[0] for p in pts]
    k = max(1, min(len(pts) - 1, bisect.bisect_right(xs, t)))
    (t0, v0), (t1, v1) = pts[k - 1], pts[k]
    u = 0.0 if t1 == t0 else min(1.0, max(0.0, (t - t0) / (t1 - t0)))
    base = v0 + (v1 - v0) * (0.5 - 0.5 * math.cos(math.pi * u))
    m = round(total / 17.0)
    return base * (1.0 + 0.14 * sin(TWO_PI * m * t / total))


def render_drone(dry: array.array, pts: list, n_total: int) -> None:
    total = n_total / SR
    f1 = round(hz(38) * total)              # cycles entiers : phase identique aux deux extrémités
    f2 = round(hz(45) * total)
    w1, w2 = TWO_PI * f1 / n_total, TWO_PI * f2 / n_total
    blk = SR // 10
    s = 0
    while s < n_total:
        L = min(blk, n_total - s)
        l0 = drone_level(pts, s / SR, total)
        l1 = drone_level(pts, min(total, (s + L) / SR), total)
        seg = dry[s:s + L]
        dry[s:s + L] = array.array("f", [
            m + (l0 + (l1 - l0) * j / L) * DRONE_GAIN * (sin(w1 * (s + j)) + 0.40 * sin(2 * w1 * (s + j) + 1.1)
                                                    + 0.55 * sin(w2 * (s + j)))
            for j, m in enumerate(seg)])
        s += L


def comb_block(x: array.array, delay: int, g: float, a: float) -> array.array:
    """Filtre en peigne bouclé (amortissement : moyenne de deux échantillons retardés), calcul par blocs."""
    n = len(x)
    y = zeros(n)
    b = 1.0 - a
    for s in range(0, n, delay):
        L = min(delay, n - s)
        xb = x[s:s + L]
        if s >= delay + 1:
            p0 = y[s - delay:s - delay + L]
            p1 = y[s - delay - 1:s - delay - 1 + L]
            y[s:s + L] = array.array("f", [xv + g * (a * u + b * v) for xv, u, v in zip(xb, p0, p1)])
        else:
            y[s:s + L] = xb
    return y


def allpass_block(x: array.array, delay: int, g: float) -> array.array:
    n = len(x)
    y = zeros(n)
    for s in range(0, n, delay):
        L = min(delay, n - s)
        xb = x[s:s + L]
        if s >= delay:
            xd = x[s - delay:s - delay + L]
            yd = y[s - delay:s - delay + L]
            y[s:s + L] = array.array("f", [-g * xv + a + g * c for xv, a, c in zip(xb, xd, yd)])
        else:
            y[s:s + L] = array.array("f", [-g * xv for xv in xb])
    return y


def reverb(x: array.array) -> array.array:
    acc = zeros(len(x))
    for delay, g in ((2111, 0.86), (2333, 0.855), (2557, 0.85), (2791, 0.845)):
        c = comb_block(x, delay, g, 0.6)
        for s in range(0, len(acc), CH):
            acc[s:s + CH] = array.array("f", map(add, acc[s:s + CH], c[s:s + CH]))
    for delay, g in ((347, 0.6), (113, 0.6)):
        acc = allpass_block(acc, delay, g)
    return acc


def rms_of(x: array.array, step: int = 1) -> float:
    s = x[::step]
    return math.sqrt(sum(map(mul, s, s)) / max(1, len(s)))


def render(score: dict) -> array.array:
    n_total = int(score["total"] * SR)
    dry = zeros(n_total)
    rr = random.Random(SEED + 1)
    events = sorted(score["events"], key=lambda e: (e[0], e[1]))
    cnt = {}
    for voice, ts, dur, midi, vel in events:
        cnt[voice] = cnt.get(voice, 0) + 1
        start = int(ts * SR)
        if voice == "pad":
            wave_ = pad_note(hz(midi), dur)
        elif voice == "bass":
            wave_ = bass_note(hz(midi), dur)
        elif voice == "bow":
            wave_ = bow_note(hz(midi), dur, rr)
        elif voice == "bell":
            wave_ = bell_wave(midi)
        else:
            wave_ = pluck_wave(midi)
        mix_into(dry, start, wave_, GAIN[voice] * vel)
    print("notes rendues :", cnt, flush=True)
    render_drone(dry, score["drone"], n_total)
    print("synthèse terminée, réverbération…", flush=True)
    ext = dry + zeros(int(REVERB_TAIL_S * SR))
    wet = reverb(ext)
    tail = int(REVERB_TAIL_S * SR)
    for s in range(0, tail, CH):                                   # la queue passe de la fin au début
        e = min(tail, s + CH)
        wet[s:e] = array.array("f", map(add, wet[s:e], wet[n_total + s:n_total + e]))
    wet = wet[:n_total]
    scale = 0.9 * rms_of(dry, 7) / max(1e-9, rms_of(wet, 7))
    mixed = zeros(n_total)
    for s in range(0, n_total, CH):
        mixed[s:s + CH] = array.array("f", [0.72 * d + 0.62 * scale * w for d, w in zip(dry[s:s + CH], wet[s:s + CH])])
    del dry, wet, ext
    # adoucit les aigus (passe-bas à un pôle, circulaire : l'état initial vient de la fin du signal)
    c = 0.6
    st = 0.0
    for v in mixed[-4410:]:
        st += c * (v - st)
    out = zeros(n_total)
    for i, v in enumerate(mixed):
        st += c * (v - st)
        out[i] = st
    del mixed
    # Niveau moyen visé, puis limiteur doux : seules les rares crêtes au-dessus du seuil sont comprimées vers le plafond.
    ceiling = 10.0 ** (PEAK_LIMIT_DB / 20.0)
    knee = 0.68 * ceiling
    gain = 10.0 ** (TARGET_RMS_DB / 20.0) / rms_of(out)

    def limited(v: float) -> float:
        a = abs(v)
        if a <= knee:
            return v
        y = knee + (ceiling - knee) * math.tanh((a - knee) / (ceiling - knee))
        return y if v > 0 else -y

    for _ in range(3):                                   # le limiteur retire un peu d'énergie : on regagne le niveau visé
        probe = array.array("f", [limited(v * gain) for v in out[::5]])
        gain *= 10.0 ** (TARGET_RMS_DB / 20.0) / rms_of(probe)
    for s in range(0, n_total, CH):
        out[s:s + CH] = array.array("f", [limited(v * gain) for v in out[s:s + CH]])
    peak = max(max(out), -min(out))
    print("ajustement : gain %.2f, crête %.2f dBFS" % (gain, db(peak)))
    return out


def write_wav(x: array.array, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        for s in range(0, len(x), CH):
            pcm = array.array("h", [max(-32768, min(32767, int(round(v * 32767.0)))) for v in x[s:s + CH]])
            if sys.byteorder == "big":
                pcm.byteswap()
            w.writeframes(pcm.tobytes())


def encode_ogg(wav_path: Path, ogg_path: Path) -> bool:
    try:
        ogg_path.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(wav_path), "-ac", "1", "-ar", str(SR),
                        "-c:a", "libvorbis", "-q:a", "3", str(ogg_path)], check=True)
    except FileNotFoundError:
        print("ffmpeg est absent : le WAV est prêt dans %s ; encodez-le à la main :\n"
              "  ffmpeg -i %s -ac 1 -ar %d -c:a libvorbis -q:a 3 %s" % (wav_path, wav_path, SR, ogg_path))
        return False
    except subprocess.CalledProcessError as e:
        print("ffmpeg a échoué :", e)
        return False
    print("%s : %.2f Mo (OGG Vorbis mono %d Hz, -q:a 3)" % (ogg_path, ogg_path.stat().st_size / 1e6, SR))
    return True


# --------------------------------------------------------------------------- vérifications

def read_wav(path: Path) -> array.array:
    with wave.open(str(path), "rb") as w:
        assert w.getnchannels() == 1 and w.getsampwidth() == 2 and w.getframerate() == SR
        x = array.array("h")
        x.frombytes(w.readframes(w.getnframes()))
    return x


def db(v: float) -> float:
    return 20.0 * math.log10(max(v, 1e-12))


def seam_report(x: array.array, label: str) -> bool:
    """Saut entre dernier et premier échantillon comparé à la plus grande différence entre voisins sur la boucle."""
    jump = abs(x[-1] - x[0])
    steps = [abs(x[i + 1] - x[i]) for i in range(0, len(x) - 1, 1)]
    top = max(steps)
    seam_vs_end = [abs(x[i + 1] - x[i]) for i in range(len(x) - 2205, len(x) - 1)]
    ok = jump <= max(top, 1)
    print("%s : |dernier − premier| = %d LSB ; plus grande différence entre voisins = %d LSB ; moyenne = %.1f ; %s"
          % (label, jump, top, sum(steps) / len(steps), "couture lisse" if ok else "COUTURE SUSPECTE"))
    return ok


def goertzel(x: list, coeff: float) -> float:
    s1 = s2 = 0.0
    for v in x:
        s0 = v + coeff * s1 - s2
        s2 = s1
        s1 = s0
    return s1 * s1 + s2 * s2 - coeff * s1 * s2


def band_features(x: array.array) -> list:
    """Énergie log en 14 bandes (55 Hz → 1,5 kHz) par trames d'une seconde, sur le signal décimé par 6."""
    sl = [x[k::6] for k in range(6)]
    n = min(len(s) for s in sl)
    dec = [sum(t) for t in zip(*[s[:n] for s in sl])]
    sr = SR / 6.0
    freqs = [55.0 * 1.27 ** k for k in range(14)]
    coeffs = [2.0 * math.cos(TWO_PI * f / sr) for f in freqs]
    frame = int(sr)
    feats = []
    for k in range(len(dec) // frame):
        seg = dec[k * frame:(k + 1) * frame]
        feats.append([math.log(1e-3 + goertzel(seg, c) / frame ** 2) for c in coeffs])
    return feats


def pearson(a: list, b: list) -> float:
    ma, mb = sum(a) / len(a), sum(b) / len(b)
    da, db_ = [v - ma for v in a], [v - mb for v in b]
    na, nb = math.sqrt(sum(v * v for v in da)), math.sqrt(sum(v * v for v in db_))
    return 0.0 if na < 1e-9 or nb < 1e-9 else sum(p * q for p, q in zip(da, db_)) / (na * nb)


def repetition_report(x: array.array, threshold: float = 0.90) -> bool:
    """Fenêtres de 10 s (pas de 5 s) : deux fenêtres disjointes ne doivent pas avoir des enveloppes spectrales quasi identiques."""
    feats = band_features(x)
    nb = len(feats[0])
    mean = [sum(f[b] for f in feats) / len(feats) for b in range(nb)]
    sd = [math.sqrt(sum((f[b] - mean[b]) ** 2 for f in feats) / len(feats)) + 1e-6 for b in range(nb)]
    z = [[(f[b] - mean[b]) / sd[b] for b in range(nb)] for f in feats]
    win, hop = 10, 5
    vecs = []
    for s in range(0, len(z) - win + 1, hop):
        vecs.append((s, [v for fr in z[s:s + win] for v in fr]))
    seam_zone = 20                                   # secondes de bourdon seul aux extrémités : identiques par construction
    worst, pair = -2.0, None
    for i in range(len(vecs)):
        for j in range(i + 2, len(vecs)):
            si, sj = vecs[i][0], vecs[j][0]
            if si < seam_zone and sj + win > len(z) - seam_zone:
                continue
            r = pearson(vecs[i][1], vecs[j][1])
            if r > worst:
                worst, pair = r, (si, sj)
    print("non-répétition : %d fenêtres de 10 s, corrélation spectrale maximale entre deux fenêtres disjointes = %.3f "
          "(fenêtres à %s et %s ; seuil %.2f ; extrémités de boucle exclues)" % (len(vecs), worst, fmt_time(pair[0]), fmt_time(pair[1]), threshold))
    return worst < threshold


def loudness_arc(x: array.array, score: dict) -> None:
    print("niveau RMS par section (dBFS) :")
    for i in score["sections"]:
        a, b = int(i["start"] * SR), int(i["end"] * SR)
        print("  %-27s %.1f" % (i["name"], db(rms_of(x[a:b]) / 32768.0)))


def check() -> int:
    score = compose()
    print_map(score)
    sigs = score["signatures"]
    uniq = len({(s[2], s[3]) for s in sigs})
    print("phrases : %d, toutes différentes : %s" % (len(sigs), "oui" if uniq == len(sigs) else "NON"))
    ok = uniq == len(sigs)
    if not WAV_PATH.exists():
        print("WAV absent : lancez d'abord python3 tools/make_ambiance.py")
        return 1
    x = read_wav(WAV_PATH)
    peak, rms = db(max(max(x), -min(x)) / 32768.0), db(rms_of(x) / 32768.0)
    print("WAV : %.1f s, crête %.2f dBFS, RMS %.2f dBFS" % (len(x) / SR, peak, rms))
    ok &= peak <= -3.0 and -23.0 <= rms <= -17.0 and len(x) / SR >= 600.0
    ok &= seam_report(x, "couture du WAV")
    loudness_arc(x, score)
    ok &= repetition_report(x)
    if OGG_PATH.exists():
        dec = WAV_PATH.with_name("decoded.wav")
        try:
            subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(OGG_PATH), "-ac", "1", "-ar", str(SR), str(dec)], check=True)
            y = read_wav(dec)
            peak2, rms2 = db(max(max(y), -min(y)) / 32768.0), db(rms_of(y) / 32768.0)
            print("OGG décodé : %.1f s, crête %.2f dBFS, RMS %.2f dBFS" % (len(y) / SR, peak2, rms2))
            ok &= peak2 <= -3.0
            ok &= seam_report(y, "couture de l'OGG décodé")
        except (FileNotFoundError, subprocess.CalledProcessError):
            print("ffmpeg absent : OGG non redécodé")
    print("VERDICT :", "OK" if ok else "ECHEC")
    return 0 if ok else 1


def main() -> int:
    if "--map" in sys.argv:
        print_map(compose())
        return 0
    if "--check" in sys.argv:
        return check()
    score = compose()
    print_map(score)
    x = render(score)
    write_wav(x, WAV_PATH)
    print("WAV : %s (%.1f s)" % (WAV_PATH, len(x) / SR))
    encode_ogg(WAV_PATH, OGG_PATH)
    return 0


if __name__ == "__main__":
    sys.exit(main())
