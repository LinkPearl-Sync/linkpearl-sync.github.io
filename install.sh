#!/usr/bin/env bash
# Installe ou met à jour un service de rendez-vous Linkpearl (lprdv).
#
#   curl -fsSL https://linkpearl-sync.github.io/install.sh | sudo bash -s -- [options]
#
#   --port N               port TCP et UDP (47900 par défaut)
#   --public-address NOM   nom ou IPv4 sous lequel les autres le joignent ;
#                          sans lui, l'autorité retient l'IPv4 de la candidature
#   --label TEXTE          nom affiché dans les annuaires
#   --no-announce          ne pas se porter candidat au cercle ouvert
#   --no-firewall          ne pas toucher au pare-feu
#
# Rejouable : relancé sans option de configuration, il met à jour le binaire
# et l'unité et garde les options déjà posées. Il ne touche jamais à
# /var/lib/lprdv, où vivent le jeton, les réglages et la liste de
# bannissement avec son sel.
#
# Page de génération : https://linkpearl-sync.github.io/heberger.html
set -euo pipefail

RELEASES="${LPRDV_RELEASES:-https://github.com/LinkPearl-Sync/linkpearl-sync-rendezvous/releases/latest/download}"
DROPIN_DIR=/etc/systemd/system/lprdv.service.d
DROPIN="$DROPIN_DIR/options.conf"
ADMIN_PORT=47901

say() { printf '==> %s\n' "$*"; }
die() { printf '!! %s\n' "$*" >&2; exit 1; }

port=47900
public_address=""
label=""
announce=1
firewall=1
configured=0

while [ $# -gt 0 ]; do
  case "$1" in
    --port) port="${2:-}"; configured=1; shift 2 ;;
    --public-address) public_address="${2:-}"; configured=1; shift 2 ;;
    --label) label="${2:-}"; configured=1; shift 2 ;;
    --no-announce) announce=0; configured=1; shift ;;
    --no-firewall) firewall=0; shift ;;
    *) die "option inconnue : $1 (voir https://linkpearl-sync.github.io/heberger.html)" ;;
  esac
done

# Les valeurs finissent dans une ligne ExecStart : on les borne ici plutôt
# que de compter sur l'échappement de systemd.
case "$port" in
  ''|*[!0-9]*) die "port invalide : $port" ;;
esac
{ [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; } || die "port hors bornes : $port"
[ "$port" -ne "$ADMIN_PORT" ] || die "le port $ADMIN_PORT est celui de la console"
if [ -n "$public_address" ] && ! printf '%s' "$public_address" | grep -Eq '^[A-Za-z0-9._-]{1,253}(:[0-9]{1,5})?$'; then
  die "adresse publique invalide : un nom ou une IPv4, éventuellement suivi de :port"
fi
# Le libellé passe entre guillemets dans ExecStart : on y refuse ce que systemd
# interprète là (" \ $ % et l'accent grave) et les caractères de contrôle.
# Les lettres accentuées passent, quelle que soit la locale de sudo.
if [ -n "$label" ]; then
  [ "${#label}" -le 64 ] || die "libellé trop long : 64 caractères au plus"
  case "$label" in
    *[\"\\\$%\`]*|*[[:cntrl:]]*) die "libellé invalide : sans guillemet, barre oblique inverse, \$, % ni accent grave" ;;
  esac
fi

[ "$(id -u)" -eq 0 ] || die "à lancer avec sudo"
[ "$(uname -s)" = Linux ] || die "Linux seulement"
[ "$(uname -m)" = x86_64 ] || die "processeur $(uname -m) : seules les machines x86-64 ont un binaire publié"
command -v systemctl >/dev/null || die "systemd est requis"
command -v curl >/dev/null || die "curl est requis"
command -v sha256sum >/dev/null || die "sha256sum est requis"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

say "Téléchargement de la dernière version"
for file in lprdv lprdv.service lprdv.sha256; do
  curl -fsSL --retry 3 -o "$work/$file" "$RELEASES/$file"
done
# La somme couvre le binaire et l'unité : rien n'est posé sans elle.
(cd "$work" && sha256sum --quiet -c lprdv.sha256) || die "somme de contrôle incorrecte, rien n'a été installé"

say "Installation"
id lprdv >/dev/null 2>&1 || useradd --system --home-dir /var/lib/lprdv --shell /usr/sbin/nologin lprdv
install -d -m 0755 /opt/lprdv
# Posé par renommage : le binaire en cours reste intact jusqu'au redémarrage.
install -m 0755 "$work/lprdv" /opt/lprdv/lprdv.new
mv -f /opt/lprdv/lprdv.new /opt/lprdv/lprdv
install -m 0644 "$work/lprdv.service" /etc/systemd/system/lprdv.service

if [ "$configured" -eq 1 ] || [ ! -f "$DROPIN" ]; then
  args="--port $port"
  if [ -n "$public_address" ]; then args="$args --public-address $public_address"; fi
  if [ -n "$label" ]; then args="$args --label \"$label\""; fi
  if [ "$announce" -eq 0 ]; then args="$args --no-announce"; fi
  install -d -m 0755 "$DROPIN_DIR"
  cat > "$DROPIN" <<EOF
# Écrit par install.sh ; le relancer avec d'autres options le réécrit.
[Service]
ExecStart=
ExecStart=/opt/lprdv/lprdv $args
EOF
  chmod 0644 "$DROPIN"
else
  say "Options inchangées ($DROPIN)"
  kept=$(grep -Eo -- '--port [0-9]+' "$DROPIN" | awk '{print $2}' | head -n 1 || true)
  port=${kept:-47900}
fi

if [ "$firewall" -eq 1 ]; then
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
    say "Ouverture du port $port (ufw)"
    ufw allow "$port" >/dev/null
  elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    say "Ouverture du port $port (firewalld)"
    firewall-cmd --quiet --permanent --add-port="$port/tcp" --add-port="$port/udp"
    firewall-cmd --quiet --reload
  fi
fi

say "Démarrage"
systemctl daemon-reload
systemctl enable --quiet lprdv
systemctl restart lprdv

for _ in $(seq 30); do
  if curl -fs -o /dev/null "http://127.0.0.1:$ADMIN_PORT/healthz"; then
    shown=${public_address:-$(hostname -f 2>/dev/null || hostname)}
    case "$shown" in
      *:*) ;;
      *) if [ "$port" -ne 47900 ]; then shown="$shown:$port"; fi ;;
    esac
    cat <<EOF
==> En ligne.

Dans le plugin : Réglages › Réseau › Services de rendez-vous, ajouter
    $shown

Ouvrir aussi le port $port en TCP et en UDP dans le pare-feu de l'hébergeur,
s'il en a un.

Console, depuis votre machine :
    ssh -L $ADMIN_PORT:127.0.0.1:$ADMIN_PORT <vous>@<ce serveur>
puis http://localhost:$ADMIN_PORT, avec ce jeton comme mot de passe :
    sudo cat /var/lib/lprdv/admin.token

Sauvegarder /var/lib/lprdv : la liste de bannissement et son sel ne se
reconstruisent pas.
EOF
    exit 0
  fi
  sleep 1
done

journalctl -u lprdv -n 30 --no-pager >&2 || true
die "le service ne répond pas sur /healthz"
