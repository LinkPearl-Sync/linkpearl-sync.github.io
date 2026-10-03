#!/usr/bin/env bash
# Installe ou met à jour un service de rendez-vous Linkpearl (lprdv).
#
#   curl -fsSL https://linkpearl-sync.github.io/install.sh | sudo bash -s -- [options]
#
#   --port N               port TCP et UDP (47900 par défaut)
#   --public-address NOM   nom ou IPv4 sous lequel les autres le joignent ;
#                          sans lui, l'autorité retient l'IPv4 de la candidature
#   --label TEXTE          nom affiché dans les annuaires (64 octets au plus)
#   --no-announce          ne pas se porter candidat au réseau ouvert
#   --no-firewall          ne pas toucher au pare-feu
#   --no-auto-update       ne pas se mettre à jour seul (lprdv-update.timer)
#   --auto-update          la rallumer après un --no-auto-update
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

# Les clés publiques de signature des releases, points P-256 non compressés,
# recopiés de Linkpearl.Rendezvous/ReleaseKeys.cs dans le dépôt du service.
# Une nouvelle clé s'ajoute ici aussi, avant la première release qu'elle
# signe. Jamais lue de l'environnement : qui la choisirait choisirait le binaire.
RELEASE_KEYS="
0415b4c82a4789ad28d050978666ac9784cdf42e0ae7fc216e1648b0d969ad8089fde3a8c360752564a532c1e290f37e13970f5ce57f3c200e11470e938355f941
"

# --- vérification (début) : extrait tel quel par tests/verification.sh ---

# Hexadécimal vers octets par le seul printf de bash : ni xxd (livré avec vim)
# ni python, absents de bien des images minimales.
hex_to_bin() {
  local hex=$1
  while [ -n "$hex" ]; do
    # shellcheck disable=SC2059
    printf "\\x${hex:0:2}"
    hex=${hex:2}
  done
}

bin_to_hex() { od -An -v -tx1 "$1" | tr -d ' \n'; }

# Un entier DER positif à partir de 32 octets bruts : zéros de tête retirés,
# puis un 00 remis si le premier bit est levé, sans quoi il se lirait négatif.
der_integer() {
  local v=$1
  while [ "${#v}" -gt 2 ] && [ "${v:0:2}" = 00 ]; do v=${v:2}; done
  case "${v:0:1}" in [89a-f]) v="00$v" ;; esac
  printf '02%02x%s' $(( ${#v} / 2 )) "$v"
}

# La CI du service signe au format IEEE P1363 (r puis s, 32 octets chacun,
# voir ReleaseManifest.Sign) ; openssl ne lit que le DER.
p1363_to_der() {
  local sig r s
  sig=$(bin_to_hex "$1")
  [ "${#sig}" -eq 128 ] || return 1
  r=$(der_integer "${sig:0:64}")
  s=$(der_integer "${sig:64:64}")
  hex_to_bin "$(printf '30%02x%s%s' $(( (${#r} + ${#s}) / 2 )) "$r" "$s")"
}

# Vrai si l'une des clés de RELEASE_KEYS a signé le manifeste.
verify_manifest() {
  local manifest=$1 signature=$2 dir point
  dir=$(mktemp -d)
  if ! p1363_to_der "$signature" > "$dir/sig.der"; then
    rm -rf "$dir"
    return 1
  fi
  for point in $RELEASE_KEYS; do
    case "$point" in 04*) ;; *) continue ;; esac
    [ "${#point}" -eq 130 ] || continue
    # SubjectPublicKeyInfo d'une clé P-256 : un en-tête fixe, puis le point.
    hex_to_bin "3059301306072a8648ce3d020106082a8648ce3d030107034200$point" > "$dir/key.der"
    if openssl pkey -pubin -inform DER -in "$dir/key.der" -out "$dir/key.pem" 2>/dev/null \
      && openssl dgst -sha256 -verify "$dir/key.pem" -signature "$dir/sig.der" "$manifest" >/dev/null 2>&1; then
      rm -rf "$dir"
      return 0
    fi
  done
  rm -rf "$dir"
  return 1
}

# La somme d'un fichier dans le manifeste signé, JSON compact écrit par
# ReleaseManifest.ToBytes : {"version":…,"files":{"lprdv":"<hex>",…}}. Une
# occurrence exactement, sinon rien : un nom en double serait ambigu.
manifest_sum() {
  local found
  found=$(grep -o "\"$2\":\"[0-9a-f]\{64\}\"" "$1" || true)
  [ -n "$found" ] && [ "$(printf '%s\n' "$found" | wc -l)" -eq 1 ] || return 1
  printf '%s\n' "$found" | cut -d'"' -f4
}

# --- vérification (fin) ---

# Copie de deploy/lprdv-update.service et deploy/lprdv-update.timer du
# service, à reprendre ici quand elles changent là-bas, tant que le manifeste
# signé ne les couvre pas.
builtin_unit() {
  case "$1" in
    lprdv-update.service) cat <<'LPRDV_UNIT'
# Une ronde de mise à jour automatique de lprdv, déclenchée par
# lprdv-update.timer. En root : elle remplace /opt/lprdv/lprdv et l'unité, et
# redémarre le service. Elle ne touche ni /var/lib/lprdv, ni les compléments
# de /etc/systemd/system/lprdv.service.d/.
#
# La couper : systemctl disable --now lprdv-update.timer

[Unit]
Description=Mise à jour automatique du service de rendez-vous Linkpearl
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/lprdv/lprdv update
StateDirectory=lprdv-update
# Durci autant que le travail le permet : il écrit dans /opt et /etc, et
# parle à systemd, donc ni ProtectSystem=strict ni sandbox réseau.
ProtectSystem=yes
ProtectHome=yes
PrivateTmp=yes
NoNewPrivileges=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
LockPersonality=yes
LPRDV_UNIT
    ;;
    lprdv-update.timer) cat <<'LPRDV_UNIT'
# Chaque heure, décalé au hasard jusqu'à une heure : le réseau ne redémarre
# pas à la même seconde quand une version sort de son délai de garde.

[Unit]
Description=Vérifie chaque heure s'il existe une nouvelle version de lprdv

[Timer]
OnBootSec=15min
OnUnitActiveSec=1h
RandomizedDelaySec=1h

[Install]
WantedBy=timers.target
LPRDV_UNIT
    ;;
    *) return 1 ;;
  esac
}

say() { printf '==> %s\n' "$*"; }
die() { printf '!! %s\n' "$*" >&2; exit 1; }

port=47900
public_address=""
label=""
announce=1
firewall=1
auto_update=""
configured=0

while [ $# -gt 0 ]; do
  case "$1" in
    --port) port="${2:-}"; configured=1; shift 2 ;;
    --public-address) public_address="${2:-}"; configured=1; shift 2 ;;
    --label) label="${2:-}"; configured=1; shift 2 ;;
    --no-announce) announce=0; configured=1; shift ;;
    --no-firewall) firewall=0; shift ;;
    # Le minuteur est indépendant des options du service : le couper ne doit
    # pas réécrire le complément avec les valeurs par défaut.
    --no-auto-update) auto_update=0; shift ;;
    --auto-update) auto_update=1; shift ;;
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
  # 64 octets UTF-8, la borne du protocole : au-delà, chaque candidature
  # échouerait en silence. Compté en octets quelle que soit la locale de sudo.
  [ "$(printf '%s' "$label" | LC_ALL=C wc -c)" -le 64 ] || die "libellé trop long : 64 octets au plus (une lettre accentuée en compte deux)"
  case "$label" in
    *[\"\\\$%\`]*|*[[:cntrl:]]*) die "libellé invalide : sans guillemet, barre oblique inverse, \$, % ni accent grave" ;;
  esac
fi

# Une adresse sans port se lit sur 47900 : avec un autre port, le service se
# présenterait sous une adresse où personne ne répond.
case "$public_address" in
  ''|*:*) ;;
  *) if [ "$port" -ne 47900 ]; then public_address="$public_address:$port"; fi ;;
esac

[ "$(id -u)" -eq 0 ] || die "à lancer avec sudo"
[ "$(uname -s)" = Linux ] || die "Linux seulement"
[ "$(uname -m)" = x86_64 ] || die "processeur $(uname -m) : seules les machines x86-64 ont un binaire publié"
command -v systemctl >/dev/null || die "systemd est requis"
command -v curl >/dev/null || die "curl est requis"
command -v sha256sum >/dev/null || die "sha256sum est requis"
command -v openssl >/dev/null || die "openssl est requis (vérification de la signature)"
command -v od >/dev/null || die "od est requis"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

say "Téléchargement de la dernière version"
for file in lprdv lprdv.service lprdv-update.service lprdv-update.timer lprdv.release.json lprdv.release.json.sig; do
  curl -fsSL --retry 3 -o "$work/$file" "$RELEASES/$file"
done
# La signature fait foi, pas lprdv.sha256 : celui-ci vient de la même release
# que le binaire, donc qui peut remplacer l'un remplace l'autre, et ce script
# tourne en root. La clé privée, elle, n'est jamais dans la release.
verify_manifest "$work/lprdv.release.json" "$work/lprdv.release.json.sig" \
  || die "signature du manifeste invalide, rien n'a été installé"
for file in lprdv lprdv.service; do
  expected=$(manifest_sum "$work/lprdv.release.json" "$file") \
    || die "le manifeste signé ne donne pas la somme de $file, rien n'a été installé"
  [ "$(sha256sum "$work/$file" | cut -d' ' -f1)" = "$expected" ] \
    || die "somme de $file différente du manifeste signé, rien n'a été installé"
done
# L'unité de mise à jour tourne en root : la poser sans preuve rendrait la
# signature décorative. Le manifeste ne couvre aujourd'hui que ce que la mise
# à jour automatique remplace (lprdv et lprdv.service). Tant qu'il ne couvre
# pas ces deux-là, on pose la copie intégrée à ce script, dont l'authenticité
# est celle du site, et on ignore celle de la release.
for file in lprdv-update.service lprdv-update.timer; do
  if expected=$(manifest_sum "$work/lprdv.release.json" "$file"); then
    [ "$(sha256sum "$work/$file" | cut -d' ' -f1)" = "$expected" ] \
      || die "somme de $file différente du manifeste signé, rien n'a été installé"
  else
    builtin_unit "$file" > "$work/$file"
  fi
done

say "Installation"
# Relevé avant de poser les unités : un minuteur présent et coupé est un choix
# de l'opérateur ; absent, c'est une installation d'avant la mise à jour
# automatique, qui la reçoit active comme une installation neuve.
had_timer=0
if [ -f /etc/systemd/system/lprdv-update.timer ]; then had_timer=1; fi
id lprdv >/dev/null 2>&1 || useradd --system --home-dir /var/lib/lprdv --shell /usr/sbin/nologin lprdv
install -d -m 0755 /opt/lprdv
# Posé par renommage : le binaire en cours reste intact jusqu'au redémarrage.
install -m 0755 "$work/lprdv" /opt/lprdv/lprdv.new
mv -f /opt/lprdv/lprdv.new /opt/lprdv/lprdv
install -m 0644 "$work/lprdv.service" /etc/systemd/system/lprdv.service
install -m 0644 "$work/lprdv-update.service" /etc/systemd/system/lprdv-update.service
install -m 0644 "$work/lprdv-update.timer" /etc/systemd/system/lprdv-update.timer
# Sans option, on garde le choix déjà fait ; au premier passage, actif.
if [ -z "$auto_update" ]; then
  if [ "$configured" -eq 0 ] && [ "$had_timer" -eq 1 ] && ! systemctl is-enabled --quiet lprdv-update.timer; then
    auto_update=0
  else
    auto_update=1
  fi
fi

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

if [ "$auto_update" -eq 1 ]; then
  systemctl enable --now --quiet lprdv-update.timer
else
  systemctl disable --now --quiet lprdv-update.timer 2>/dev/null || true
fi

for _ in $(seq 30); do
  if curl -fs -o /dev/null "http://127.0.0.1:$ADMIN_PORT/healthz"; then
    # Sans adresse donnée, on n'en devine pas : le nom de la machine est
    # souvent un nom interne de l'hébergeur, que personne ne joindra.
    shown=${public_address:-"<adresse publique de ce serveur>"}
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

Mise à jour automatique : $(if [ "$auto_update" -eq 1 ]; then echo "active, chaque heure"; else echo "coupée"; fi).
EOF
    exit 0
  fi
  sleep 1
done

journalctl -u lprdv -n 30 --no-pager >&2 || true
die "le service ne répond pas sur /healthz"
