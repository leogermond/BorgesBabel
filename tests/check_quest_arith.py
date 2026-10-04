#!/usr/bin/env python3
"""Contre-épreuve de l'arithmétique décimale de Quest par les entiers de Python.

Lit un fichier JSON [[a, b], …] (entiers relatifs décimaux en chaînes) et écrit sur la sortie
une ligne JSON : pour chaque paire, {sum, diff, cmp, sign, digits} (somme, a − b, comparaison,
signe de a, chiffres de |a|), entiers en chaînes canoniques. Appelé par tests/test_quest.gd.
"""

import json
import sys

if hasattr(sys, "set_int_max_str_digits"):
    sys.set_int_max_str_digits(0)

with open(sys.argv[1], encoding="utf-8") as f:
    pairs = json.load(f)
results = []
for a_text, b_text in pairs:
    a, b = int(a_text), int(b_text)
    results.append({
        "sum": str(a + b),
        "diff": str(a - b),
        "cmp": (a > b) - (a < b),
        "sign": (a > 0) - (a < 0),
        "digits": len(str(abs(a))),
    })
print(json.dumps(results))
