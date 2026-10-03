#!/usr/bin/env bash
# Exerce la vérification de signature d'install.sh hors ligne, avec une clé
# jetable : manifeste et signature fabriqués au format de la CI du service
# (JSON compact, ECDSA P-256 sur SHA-256, signature IEEE P1363 de 64 octets).
#
#   bash tests/verification.sh
#
# Les fonctions sont extraites d'install.sh entre ses deux marqueurs, telles
# quelles : on teste le code qui part chez les opérateurs, pas une copie.

# « test && ok || ko » : ok ne fait qu'un printf et ne peut pas échouer, donc
# ko ne suit jamais un succès.
# shellcheck disable=SC2015
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

sed -n '/^# --- vérification (début)/,/^# --- vérification (fin)/p' "$here/install.sh" > "$work/fonctions.sh"
grep -q '^verify_manifest()' "$work/fonctions.sh" || { echo "marqueurs introuvables dans install.sh" >&2; exit 1; }
# shellcheck source=/dev/null
. "$work/fonctions.sh"

failures=0
ok() { printf 'ok   %s\n' "$1"; }
ko() { printf 'ÉCHEC %s\n' "$1" >&2; failures=$((failures + 1)); }

# Le point public non compressé d'une clé, comme dans ReleaseKeys.cs.
public_point() {
  openssl pkey -in "$1" -pubout -outform DER 2>/dev/null | tail -c 65 | od -An -v -tx1 | tr -d ' \n'
}

# Signe au format P1363, comme ReleaseManifest.Sign : openssl donne du DER,
# python le découpe en r et s complétés à 32 octets.
sign_p1363() {
  openssl dgst -sha256 -sign "$1" "$2" | python3 -c '
import sys
d = sys.stdin.buffer.read()
assert d[0] == 0x30
i = 2
out = b""
for _ in range(2):
    assert d[i] == 0x02
    n = d[i + 1]
    v = d[i + 2:i + 2 + n].lstrip(b"\0")
    out += v.rjust(32, b"\0")
    i += 2 + n
sys.stdout.buffer.write(out)'
}

openssl ecparam -name prime256v1 -genkey -noout -out "$work/cle.pem" 2>/dev/null
openssl ecparam -name prime256v1 -genkey -noout -out "$work/autre.pem" 2>/dev/null
RELEASE_KEYS="$(public_point "$work/cle.pem")"
[ "${#RELEASE_KEYS}" -eq 130 ] || { echo "point public mal extrait" >&2; exit 1; }

printf 'binaire' > "$work/lprdv"
printf '[Service]\n' > "$work/lprdv.service"
sum() { sha256sum "$1" | cut -d' ' -f1; }
printf '{"version":"1.2.3","signed":1790000000,"urgent":false,"files":{"lprdv":"%s","lprdv.service":"%s"}}' \
  "$(sum "$work/lprdv")" "$(sum "$work/lprdv.service")" > "$work/m.json"

# Plusieurs signatures du même manifeste : r et s tombent tantôt avec le bit
# de poids fort levé (un 00 à ajouter en DER), tantôt non. 64 tirages laissent
# une chance sur 2^64 de manquer l'un des cas.
high=0 low=0
for i in $(seq 64); do
  sign_p1363 "$work/cle.pem" "$work/m.json" > "$work/m.sig"
  [ "$(wc -c < "$work/m.sig")" -eq 64 ] || { ko "signature de 64 octets ($i)"; continue; }
  case "$(od -An -N1 -tx1 "$work/m.sig" | tr -d ' ')" in [89a-f]*) high=$((high + 1)) ;; *) low=$((low + 1)) ;; esac
  verify_manifest "$work/m.json" "$work/m.sig" || ko "signature valide refusée (tirage $i)"
done
[ "$high" -gt 0 ] && [ "$low" -gt 0 ] && ok "64 signatures valides acceptées ($high r à bit fort, $low sans)" || ko "cas de bit fort non couverts"

# Un r ou un s qui commence par un octet nul : rare au tirage, donc fabriqué
# ici directement sur l'encodage, sans clé.
[ "$(der_integer "00$(printf '2b%.0s' $(seq 31))")" = "021f$(printf '2b%.0s' $(seq 31))" ] \
  && ok "zéro de tête retiré" || ko "zéro de tête"
[ "$(der_integer "0080$(printf '11%.0s' $(seq 30))")" = "02200080$(printf '11%.0s' $(seq 30))" ] \
  && ok "zéro de tête gardé devant un bit fort" || ko "zéro de tête devant un bit fort"
[ "$(der_integer "ff$(printf '00%.0s' $(seq 31))")" = "022100ff$(printf '00%.0s' $(seq 31))" ] \
  && ok "00 ajouté devant un bit fort" || ko "00 devant un bit fort"

sign_p1363 "$work/cle.pem" "$work/m.json" > "$work/m.sig"

sed 's/"1\.2\.3"/"1.2.4"/' "$work/m.json" > "$work/altere.json"
if verify_manifest "$work/altere.json" "$work/m.sig"; then ko "manifeste altéré accepté"; else ok "manifeste altéré refusé"; fi

sign_p1363 "$work/autre.pem" "$work/m.json" > "$work/autre.sig"
if verify_manifest "$work/m.json" "$work/autre.sig"; then ko "clé inconnue acceptée"; else ok "signature d'une clé inconnue refusée"; fi

# Une signature DER, celle qu'openssl produit d'office, n'est pas le format
# de la CI : elle doit être refusée et non devinée.
openssl dgst -sha256 -sign "$work/cle.pem" "$work/m.json" > "$work/der.sig"
if verify_manifest "$work/m.json" "$work/der.sig"; then ko "signature DER acceptée"; else ok "signature DER refusée"; fi

head -c 63 "$work/m.sig" > "$work/court.sig"
if verify_manifest "$work/m.json" "$work/court.sig"; then ko "signature tronquée acceptée"; else ok "signature tronquée refusée"; fi
: > "$work/vide.sig"
if verify_manifest "$work/m.json" "$work/vide.sig"; then ko "signature vide acceptée"; else ok "signature vide refusée"; fi

# Plusieurs clés inscrites : la bonne peut être la seconde.
saved=$RELEASE_KEYS
RELEASE_KEYS="$(public_point "$work/autre.pem")
$saved"
verify_manifest "$work/m.json" "$work/m.sig" && ok "clé trouvée parmi plusieurs" || ko "seconde clé ignorée"
RELEASE_KEYS=$saved

[ "$(manifest_sum "$work/m.json" lprdv)" = "$(sum "$work/lprdv")" ] && ok "somme de lprdv lue" || ko "somme de lprdv"
[ "$(manifest_sum "$work/m.json" lprdv.service)" = "$(sum "$work/lprdv.service")" ] && ok "somme de l'unité lue" || ko "somme de l'unité"
if manifest_sum "$work/m.json" lprdv-update.timer > /dev/null; then ko "somme absente inventée"; else ok "fichier absent du manifeste signalé"; fi
printf '{"files":{"lprdv":"%s","lprdv":"%s"}}' "$(sum "$work/lprdv")" "$(sum "$work/lprdv.service")" > "$work/double.json"
if manifest_sum "$work/double.json" lprdv > /dev/null; then ko "nom en double accepté"; else ok "nom en double refusé"; fi

if [ "$failures" -ne 0 ]; then
  echo "$failures échec(s)" >&2
  exit 1
fi
echo "Tout passe."
