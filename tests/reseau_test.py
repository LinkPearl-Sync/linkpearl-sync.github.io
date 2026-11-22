#!/usr/bin/env python3
"""Vérifie que reseau.py n'accepte que l'état du réseau signé par l'autorité.

    python3 tests/reseau_test.py

Le vecteur de tests/fixtures/reseau-signe.json a été signé par
NetworkStatus.Sign du dépôt du service, avec une clé jetable dont voici le
point public : une dérive de format entre le service et ce script le ferait
refuser, sans qu'aucun service réel soit interrogé.
"""

import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
KEY = "04fdd10a9ca1fc150916d3ea8e52c424a0759be76bb9350f8511dab3545524cc4c38671850ac40edc026e62fa089526c30b18aae5b99c32adf07c7d706541451a7"

spec = importlib.util.spec_from_file_location("reseau", os.path.join(HERE, "..", "scripts", "reseau.py"))
reseau = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reseau)

with open(os.path.join(HERE, "fixtures", "reseau-signe.json"), "rb") as file:
    SIGNED = file.read()

failures = 0


def check(name, condition):
    global failures
    print(("ok   " if condition else "ÉCHEC ") + name, file=sys.stdout if condition else sys.stderr)
    failures += 0 if condition else 1


def refused(raw, keys):
    try:
        reseau.authenticated(raw, keys)
        return False
    except reseau.Refused:
        return True


document = reseau.authenticated(SIGNED, [KEY])
check("document signé par le service accepté", document.endswith(b'"services":[]}') and b"signature" not in document)
check("document retouché refusé", refused(SIGNED.replace(b'"listed":0', b'"listed":9'), [KEY]))
check("autre clé refusée", refused(SIGNED, reseau.AUTHORITY_KEYS))
check("document sans signature refusé", refused(document, [KEY]))
check("signature suivie d'un autre champ refusée", refused(SIGNED[:-1] + b',"x":1}', [KEY]))
check("signature tronquée refusée", refused(SIGNED.replace(b'","', b'",', 1)[:-3] + b'"}', [KEY]))

check("ligne ::warning:: sans saut de ligne", "\n" not in reseau.clean("a\n::add-mask::b\r"))
check("adresse de 261 caractères acceptée", reseau.text("a" * 255 + ":65535"))
check("date hors de portée de Date refusée", not reseau.when(10**13))

if failures:
    print(f"{failures} échec(s)", file=sys.stderr)
    sys.exit(1)
print("Tout passe.")
