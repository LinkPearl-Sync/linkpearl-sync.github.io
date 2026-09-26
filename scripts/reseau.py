#!/usr/bin/env python3
"""Prend l'instantané public du réseau auprès de l'autorité, pour reseau.html.

Usage : reseau.py SORTIE [HÔTE [PORT]]

Le service n'a aucune page HTTP publique : il rend l'état du réseau par la
trame NetworkStatusQuery, sur son port habituel. Le site étant statique, ce
script l'interroge à chaque déploiement horaire et écrit le JSON à côté de la
page.

En cas d'échec, il reprend l'instantané déjà publié : une page qui garde son
dernier état, avec son heure qui vieillit, vaut mieux qu'une page vide pendant
une panne du VPS. Sans l'un ni l'autre, il n'écrit rien et la page le dit.
"""

import json
import socket
import struct
import sys
import urllib.request

HOST = "rdv.linkpearl.eorzea.events"
PORT = 47900
PUBLISHED = "https://linkpearl-sync.github.io/reseau.json"

# RendezvousKind, dans Protocol/Core/Transport/Rendezvous/RendezvousWire.cs.
ERROR = 0x06
NETWORK_STATUS_QUERY = 0x19
NETWORK_STATUS_PAGE = 0x1A

# Les bornes du service : seize pages au plus, 64 Kio par trame.
MAX_PAGES = 16
MAX_FRAME = 64 * 1024
TIMEOUT = 15

STANDINGS = {"listed", "probation", "delisted"}
MAX_TEXT = 256


class Refused(Exception):
    pass


def read_exact(sock, count):
    data = bytearray()
    while len(data) < count:
        chunk = sock.recv(count - len(data))
        if not chunk:
            raise Refused("connexion fermée par le service")
        data += chunk
    return bytes(data)


def read_frame(sock):
    (length,) = struct.unpack(">I", read_exact(sock, 4))
    if length == 0 or length > MAX_FRAME:
        raise Refused(f"trame de {length} octets")
    return read_exact(sock, length)


def fetch(host, port):
    """Demande les pages une à une et recolle le JSON."""
    chunks = []
    with socket.create_connection((host, port), timeout=TIMEOUT) as sock:
        pages = 1
        page = 0
        while page < pages:
            query = struct.pack(">BH", NETWORK_STATUS_QUERY, page)
            sock.sendall(struct.pack(">I", len(query)) + query)

            frame = read_frame(sock)
            if frame[0] == ERROR:
                raise Refused(frame[1:].decode("utf-8", "replace"))
            if frame[0] != NETWORK_STATUS_PAGE or len(frame) < 5:
                raise Refused(f"réponse inattendue 0x{frame[0]:02x}")

            number, total = struct.unpack(">HH", frame[1:5])
            if number != page or not 1 <= total <= MAX_PAGES:
                raise Refused(f"page {number} sur {total}, attendu la page {page}")
            if page == 0:
                pages = total
            elif total != pages:
                raise Refused("le nombre de pages a changé en cours de lecture")

            chunks.append(frame[5:])
            page += 1

    return json.loads(b"".join(chunks).decode("utf-8"))


def text(value):
    return isinstance(value, str) and len(value) <= MAX_TEXT


def when(value):
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def validate(status):
    """La page insère tout par textContent ; on vérifie quand même la forme,
    pour ne jamais publier un document qu'elle afficherait de travers."""
    if not isinstance(status, dict) or status.get("version") != 1:
        raise Refused("version inconnue")
    if not when(status.get("generated")):
        raise Refused("heure de l'instantané absente")

    counts = status.get("counts")
    if not isinstance(counts, dict) or not all(
        when(counts.get(key)) for key in ("listed", "probation", "candidates", "delisted")
    ):
        raise Refused("compteurs malformés")

    services = status.get("services")
    if not isinstance(services, list):
        raise Refused("services absents")
    for service in services:
        if not isinstance(service, dict):
            raise Refused("service malformé")
        if not text(service.get("address")) or not text(service.get("label")):
            raise Refused("adresse ou libellé malformé")
        if service.get("standing") not in STANDINGS:
            raise Refused(f"état inconnu {service.get('standing')!r}")

    authority = status.get("authority")
    if authority is not None and (
        not isinstance(authority, dict)
        or not text(authority.get("publicKey"))
        or not when(authority.get("expires"))
    ):
        raise Refused("autorité malformée")

    return status


def published():
    with urllib.request.urlopen(PUBLISHED, timeout=TIMEOUT) as response:
        return json.load(response)


def main():
    if not 2 <= len(sys.argv) <= 4:
        print(__doc__.splitlines()[2], file=sys.stderr)
        return 2

    output = sys.argv[1]
    host = sys.argv[2] if len(sys.argv) > 2 else HOST
    port = int(sys.argv[3]) if len(sys.argv) > 3 else PORT

    try:
        status = validate(fetch(host, port))
        source = f"{host}:{port}"
    except (OSError, ValueError, Refused) as error:
        print(f"::warning::État du réseau injoignable ({error}), reprise de l'instantané publié", file=sys.stderr)
        try:
            status = validate(published())
            source = PUBLISHED
        except (OSError, ValueError, Refused) as fallback:
            # Pas d'échec du déploiement pour autant : la page dit qu'elle
            # n'a pas d'état, et le reste du site doit partir quand même.
            print(f"::warning::Aucun instantané publié non plus ({fallback}), reseau.json absent", file=sys.stderr)
            return 0

    with open(output, "w", encoding="utf-8") as file:
        json.dump(status, file, ensure_ascii=False, separators=(",", ":"))

    print(f"reseau.json : {len(status['services'])} services, depuis {source}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
