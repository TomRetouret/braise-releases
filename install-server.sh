#!/bin/sh
# Installe ou met à jour Braise Server sur un serveur Linux, en une commande :
#   curl -fsSL https://raw.githubusercontent.com/TomRetouret/braise-releases/main/install-server.sh | sh
#
# Ce que fait ce script, et rien d'autre :
#   1. télécharge braise-server (dernière version publiée) et vérifie son empreinte SHA-256 ;
#      depuis le dépôt de Braise, `./scripts/install-server.sh --source` le construit à la place ;
#   2. l'installe dans ~/.local/bin, sans droits administrateur ;
#   3. demande le mot de passe de connexion à la première installation ;
#   4. crée le service systemd de l'utilisateur et le démarre (et le redémarre lors d'une mise à jour) ;
#   5. propose de le garder allumé au démarrage du serveur (une commande sudo) et l'accès HTTPS
#      par Tailscale s'il est installé.
#
# Variables :
#   BRAISE_VERSION=v0.21.0        une version précise (défaut : la dernière)
#   BRAISE_LISTEN=127.0.0.1:7420  adresse d'écoute (défaut 0.0.0.0:7420 : réseau local et Tailscale)
#   BRAISE_PASSWORD=…             mot de passe sans question (installation automatisée)
#   BRAISE_UNINSTALL=1            désinstalle (les projets et réglages sont gardés)
#   BRAISE_PURGE=1                avec BRAISE_UNINSTALL : efface aussi les données

set -eu

OWNER="${BRAISE_OWNER:-TomRetouret}"
REPO="${BRAISE_REPO:-braise-releases}"
VERSION="${BRAISE_VERSION:-latest}"
API="${BRAISE_API:-https://api.github.com}"
LISTEN="${BRAISE_LISTEN:-0.0.0.0:7420}"
PORT="${LISTEN##*:}"
BIN="$HOME/.local/bin/braise-server"
DATA="${BRAISE_SERVER_DATA:-${XDG_DATA_HOME:-$HOME/.local/share}/braise-server}"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT="$UNIT_DIR/braise-server.service"

say() { printf '%s\n' "$*"; }
ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
fail() { printf '\n\033[31mInstallation interrompue :\033[0m %s\n' "$*" >&2; exit 1; }
short() { printf '%s' "$1" | sed "s|^$HOME|~|"; }

# Questions : lues sur le terminal, même quand le script arrive par « curl | sh ».
has_tty() { [ -r /dev/tty ] && (: < /dev/tty) 2>/dev/null; }
ask_yes() {
  has_tty || return 1
  printf '%s [o/N] ' "$1" > /dev/tty
  read -r a < /dev/tty || return 1
  case "$a" in o|O|oui|Oui|y|Y|yes) return 0 ;; *) return 1 ;; esac
}

SOURCE=""
for a in "$@"; do
  case "$a" in
    --source) SOURCE=1 ;;
    --help|-h) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) fail "option inconnue : $a (seule --source existe)." ;;
  esac
done
[ -n "${BRAISE_SOURCE:-}" ] && SOURCE=1

[ "$(uname -s)" = "Linux" ] || fail "Braise Server s'installe sur Linux. Sur Mac ou Windows, installe l'app Braise."
if [ "$(id -u)" = "0" ] && [ -z "${BRAISE_ALLOW_ROOT:-}" ]; then
  fail "lance ce script avec l'utilisateur qui possède les projets, pas root : Braise lance les commandes des projets avec ses droits. (BRAISE_ALLOW_ROOT=1 pour forcer.)"
fi
command -v curl >/dev/null || fail "curl est introuvable (sudo apt install curl)."
command -v tar >/dev/null || fail "tar est introuvable."

HAS_SYSTEMD=""
command -v systemctl >/dev/null && systemctl --user show-environment >/dev/null 2>&1 && HAS_SYSTEMD=1

# ------------------------------------------------------------------ désinstallation
if [ -n "${BRAISE_UNINSTALL:-}" ]; then
  if [ -n "$HAS_SYSTEMD" ]; then
    systemctl --user disable --now braise-server >/dev/null 2>&1 || true
    rm -f "$UNIT"
    systemctl --user daemon-reload >/dev/null 2>&1 || true
  fi
  rm -f "$BIN"
  if [ -n "${BRAISE_PURGE:-}" ]; then
    rm -rf "$DATA"
    say "Braise Server est désinstallé, données comprises."
  else
    say "Braise Server est désinstallé. Projets, réglages et mot de passe restent dans $(short "$DATA") (BRAISE_PURGE=1 pour les effacer)."
  fi
  exit 0
fi

say ""
say "Braise Server · tes projets, allumés, depuis n'importe quel appareil."
say ""

tmp=$(mktemp -d "${TMPDIR:-/tmp}/braise-server.XXXXXX")
trap 'rm -rf "$tmp"' EXIT INT TERM

# ------------------------------------------------------------------ 1. le programme
if [ -n "$SOURCE" ]; then
  root=$(cd "$(dirname "$0")/.." && pwd)
  [ -f "$root/crates/braise-server/Cargo.toml" ] || fail "--source se lance depuis le dépôt de Braise (scripts/install-server.sh)."
  command -v cargo >/dev/null || fail "Rust est introuvable : https://rustup.rs"
  command -v npm >/dev/null || fail "Node et npm sont introuvables (Node 22 recommandé)."
  say "  Construction depuis $(short "$root")…"
  (cd "$root" && npm ci --no-audit --no-fund --loglevel=error && npm run build >/dev/null) || fail "la construction de l'interface a échoué."
  (cd "$root" && cargo build --release -p braise-server) || fail "la construction a échoué. Sur Debian ou Ubuntu : sudo apt install build-essential pkg-config libdbus-1-dev"
  cp "$root/target/release/braise-server" "$tmp/braise-server"
  ok "Construit depuis le dépôt"
else
  case "$(uname -m)" in
    x86_64|amd64) arch=x86_64 ;;
    aarch64|arm64) arch=aarch64 ;;
    *) fail "pas de version publiée pour $(uname -m). Depuis le dépôt : ./scripts/install-server.sh --source" ;;
  esac
  if [ "$VERSION" = "latest" ]; then api="$API/repos/$OWNER/$REPO/releases/latest"; else api="$API/repos/$OWNER/$REPO/releases/tags/$VERSION"; fi
  json=$(curl -fsSL -H "Accept: application/vnd.github+json" "$api") || fail "impossible de lire les versions sur github.com/$OWNER/$REPO (connexion, proxy ?)."
  tag=$(printf '%s' "$json" | grep -o '"tag_name": *"[^"]*"' | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/')
  file="braise-server-linux-$arch.tar.gz"
  url=$(printf '%s' "$json" | grep -o "\"browser_download_url\": *\"[^\"]*/$file\"" | head -n 1 | sed 's/.*"\(http[^"]*\)"$/\1/')
  sums=$(printf '%s' "$json" | grep -o '"browser_download_url": *"[^"]*SHA256SUMS\.txt"' | head -n 1 | sed 's/.*"\(http[^"]*\)"$/\1/')
  [ -n "$tag" ] || fail "aucune version de Braise publiée pour l'instant."
  [ -n "$url" ] || fail "la version $tag n'a pas Braise Server pour $arch. Depuis le dépôt : ./scripts/install-server.sh --source"
  [ -n "$sums" ] || fail "la version $tag n'a pas de fichier d'empreintes, installation refusée."
  ok "Version $tag trouvée ($arch)"
  curl -fL --progress-bar -o "$tmp/$file" "$url" || fail "le téléchargement a échoué."
  expected=$(curl -fsSL "$sums" | awk -v f="$file" '$2 == f || $2 == "*"f { print $1; exit }')
  actual=$(sha256sum "$tmp/$file" | awk '{ print $1 }')
  [ -n "$expected" ] && [ "$expected" = "$actual" ] || fail "l'empreinte SHA-256 ne correspond pas : fichier abîmé ou modifié."
  ok "Empreinte SHA-256 vérifiée"
  tar -xzf "$tmp/$file" -C "$tmp" || fail "archive illisible."
  [ -f "$tmp/braise-server" ] || fail "l'archive ne contient pas braise-server."
fi
chmod 755 "$tmp/braise-server"
"$tmp/braise-server" --version >/dev/null 2>&1 || fail "braise-server ne démarre pas sur ce système (bibliothèque manquante ? sudo apt install libdbus-1-3)."

# ------------------------------------------------------------------ 2. installation
was_active=""
[ -n "$HAS_SYSTEMD" ] && systemctl --user is-active --quiet braise-server 2>/dev/null && was_active=1
if [ -n "$was_active" ]; then
  warn "Mise à jour : les projets allumés vont être arrêtés proprement, puis Braise Server redémarre."
  systemctl --user stop braise-server
fi
mkdir -p "$(dirname "$BIN")"
install -m 755 "$tmp/braise-server" "$BIN" || fail "copie impossible dans $(short "$BIN")."
ok "Installé : $(short "$BIN") ($("$BIN" --version | awk '{ print $2 }'))"

# ------------------------------------------------------------------ 3. mot de passe
if [ -f "$DATA/auth.json" ]; then
  ok "Mot de passe déjà défini (pour le changer : braise-server set-password)"
elif [ -n "${BRAISE_PASSWORD:-}" ]; then
  printf '%s\n' "$BRAISE_PASSWORD" | "$BIN" set-password >/dev/null || fail "mot de passe refusé."
  ok "Mot de passe enregistré"
elif has_tty; then
  say ""
  say "  Choisis le mot de passe pour te connecter depuis le navigateur (10 caractères au moins)."
  until "$BIN" set-password < /dev/tty > /dev/tty; do say "  On recommence."; done
else
  fail "pas de terminal pour choisir le mot de passe. Lance « braise-server set-password », puis relance ce script (ou passe BRAISE_PASSWORD)."
fi

# ------------------------------------------------------------------ 4. service
lan_ip=$(hostname -I 2>/dev/null | awk '{ print $1 }')
case "$LISTEN" in 127.*|localhost:*) shown="http://127.0.0.1:$PORT" ;; *) shown="http://${lan_ip:-<adresse du serveur>}:$PORT" ;; esac

if [ -z "$HAS_SYSTEMD" ]; then
  warn "systemd (session utilisateur) n'est pas disponible : Braise Server ne démarrera pas tout seul."
  say ""
  say "Pour le lancer : $(short "$BIN") --listen $LISTEN"
  say "Puis ouvre $shown"
  exit 0
fi

mkdir -p "$UNIT_DIR"
cat > "$UNIT" <<UNIT
# Créé par install-server.sh. Relancer le script pour mettre à jour Braise Server.
[Unit]
Description=Braise Server : projets de dev pilotés depuis le navigateur
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN --listen $LISTEN
# Braise arrête lui-même les projets (conteneurs compris) quand le service s'arrête.
KillMode=mixed
TimeoutStopSec=45
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
UNIT
systemctl --user daemon-reload
systemctl --user enable braise-server >/dev/null 2>&1
systemctl --user restart braise-server
i=0
until curl -fsS -o /dev/null "http://127.0.0.1:$PORT/login" 2>/dev/null; do
  i=$((i + 1))
  if [ $i -ge 20 ]; then
    say ""
    journalctl --user -u braise-server -n 15 --no-pager 2>/dev/null || true
    fail "Braise Server ne répond pas sur le port $PORT (port déjà pris ?). Journal : journalctl --user -u braise-server"
  fi
  sleep 0.5
done
ok "Service démarré (systemctl --user status braise-server)"

# ------------------------------------------------------------------ 5. démarrage au boot, HTTPS
if [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || true)" = "yes" ]; then
  ok "Démarre avec le serveur, même sans session ouverte"
elif loginctl enable-linger "$USER" >/dev/null 2>&1; then
  ok "Démarre avec le serveur, même sans session ouverte"
elif command -v sudo >/dev/null && ask_yes "  Garder Braise Server allumé au démarrage du serveur, sans session ouverte ? (demande sudo)"; then
  if sudo loginctl enable-linger "$USER" < /dev/tty; then ok "Démarre avec le serveur, même sans session ouverte"; else warn "Non activé. Plus tard : sudo loginctl enable-linger $USER"; fi
else
  warn "Braise Server s'arrêtera à la fermeture de ta session. Pour l'éviter : sudo loginctl enable-linger $USER"
fi

ts_url=""
if command -v tailscale >/dev/null 2>&1; then
  ts_name=$(tailscale status --json 2>/dev/null | grep -o '"DNSName": *"[^"]*"' | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/; s/\.$//')
  if tailscale serve status 2>/dev/null | grep -q ":$PORT"; then
    [ -n "$ts_name" ] && ts_url="https://$ts_name"
    ok "Accès HTTPS par Tailscale déjà en place"
  elif ask_yes "  Tailscale est installé. Activer l'accès HTTPS depuis tes appareils Tailscale ?"; then
    if tailscale serve --bg "$PORT" >/dev/null 2>&1 || sudo tailscale serve --bg "$PORT" < /dev/tty >/dev/null 2>&1; then
      [ -n "$ts_name" ] && ts_url="https://$ts_name"
      ok "Accès HTTPS par Tailscale activé"
    else
      warn "Non activé. Plus tard : tailscale serve --bg $PORT"
    fi
  fi
fi

say ""
say "Braise Server est prêt. Ouvre depuis un autre appareil :"
say "  $shown"
[ -n "$ts_url" ] && say "  $ts_url   (Tailscale, HTTPS)"
case "$LISTEN" in 127.*|localhost:*) ;; *) [ -z "$ts_url" ] && say "  (En HTTP, à réserver à ton réseau local. Pour l'extérieur : Tailscale.)" ;; esac
say ""
say "Mettre à jour : relance cette commande. Désinstaller : BRAISE_UNINSTALL=1 avec la même commande."
