#!/bin/sh
# Installe ou met à jour Braise sur ce Mac.
#   curl -fsSL https://raw.githubusercontent.com/TomRetouret/braise-releases/main/install.sh | sh
# Version précise : ... | BRAISE_VERSION=v0.3.0 sh
#
# Ce que fait ce script, et rien d'autre :
#   1. lit la dernière version publiée sur github.com/TomRetouret/braise-releases ;
#   2. télécharge l'app (Apple Silicon et Intel) et vérifie son empreinte SHA-256 ;
#   3. vérifie sa signature (ad hoc, sans compte Apple) avec codesign ;
#   4. l'installe dans ~/Applications (aucun mot de passe administrateur), puis l'ouvre.
# Désinstaller : glisser ~/Applications/Braise.app à la corbeille,
# et supprimer ~/Library/Application Support/fr.quatresh.braise pour effacer la liste des projets.

set -eu

OWNER="${BRAISE_OWNER:-TomRetouret}"
REPO="${BRAISE_REPO:-braise-releases}"
VERSION="${BRAISE_VERSION:-latest}"
APP="Braise.app"
DEST="${BRAISE_DEST:-$HOME/Applications}"
API="${BRAISE_API:-https://api.github.com}"

say() { printf '%s\n' "$*"; }
ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
fail() { printf '\n\033[31mInstallation interrompue :\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "Braise fonctionne sur macOS uniquement."
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 12 ] 2>/dev/null || fail "Braise demande macOS 12 ou plus récent (ce Mac : $(sw_vers -productVersion))."
command -v curl >/dev/null || fail "curl est introuvable."

if [ "$VERSION" = "latest" ]; then
  api="$API/repos/$OWNER/$REPO/releases/latest"
else
  api="$API/repos/$OWNER/$REPO/releases/tags/$VERSION"
fi

say ""
say "Braise · tes projets, allumés."
say ""

json=$(curl -fsSL -H "Accept: application/vnd.github+json" "$api") || fail "impossible de lire les versions sur github.com/$OWNER/$REPO (connexion, VPN ?)."
tag=$(printf '%s' "$json" | grep -o '"tag_name": *"[^"]*"' | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/')
url=$(printf '%s' "$json" | grep -o '"browser_download_url": *"[^"]*\.app\.tar\.gz"' | head -n 1 | sed 's/.*"\(http[^"]*\)"$/\1/')
sums=$(printf '%s' "$json" | grep -o '"browser_download_url": *"[^"]*SHA256SUMS\.txt"' | head -n 1 | sed 's/.*"\(http[^"]*\)"$/\1/')
[ -n "$tag" ] && [ -n "$url" ] || fail "aucune version de Braise publiée pour l'instant."
[ -n "$sums" ] || fail "la version $tag n'a pas de fichier d'empreintes, installation refusée."
ok "Version $tag trouvée"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/braise.XXXXXX")
trap 'rm -rf "$tmp"' EXIT INT TERM

curl -fL --progress-bar -o "$tmp/braise.app.tar.gz" "$url" || fail "le téléchargement a échoué."
expected=$(curl -fsSL "$sums" | awk '/\.app\.tar\.gz/ { print $1; exit }')
actual=$(shasum -a 256 "$tmp/braise.app.tar.gz" | awk '{ print $1 }')
[ -n "$expected" ] && [ "$expected" = "$actual" ] || fail "l'empreinte SHA-256 ne correspond pas : fichier abîmé ou modifié."
ok "Empreinte SHA-256 vérifiée"

tar -xzf "$tmp/braise.app.tar.gz" -C "$tmp" || fail "archive illisible."
[ -d "$tmp/$APP" ] || fail "l'archive ne contient pas $APP."
# Signature ad hoc : codesign en vérifie l'intégrité. On n'appelle pas spctl, qui refuse
# toujours une app non notarisée.
codesign --verify --deep --strict "$tmp/$APP" 2>/dev/null || fail "la signature de l'app est invalide."
ok "Signature vérifiée"

if pgrep -xq Braise; then
  say "  Braise est ouvert : on le ferme pour le remplacer (tes projets allumés sont arrêtés proprement)."
  osascript -e 'tell application "Braise" to quit' >/dev/null 2>&1 || true
  i=0
  while pgrep -xq Braise && [ $i -lt 30 ]; do sleep 1; i=$((i + 1)); done
  pgrep -xq Braise && fail "Braise ne s'est pas fermé. Quitte-le, puis relance la commande."
fi

mkdir -p "$DEST"
rm -rf "$DEST/$APP.old"
[ -d "$DEST/$APP" ] && mv "$DEST/$APP" "$DEST/$APP.old"
if ditto "$tmp/$APP" "$DEST/$APP"; then
  rm -rf "$DEST/$APP.old"
else
  [ -d "$DEST/$APP.old" ] && mv "$DEST/$APP.old" "$DEST/$APP"
  fail "copie impossible dans $DEST."
fi
# curl ne pose pas d'attribut de quarantaine ; on s'en assure quand même.
xattr -dr com.apple.quarantine "$DEST/$APP" 2>/dev/null || true
ok "Installé dans $(printf '%s' "$DEST" | sed "s|^$HOME|~|")"

say ""
say "Braise $tag est prêt. Il se mettra à jour tout seul."
open "$DEST/$APP" 2>/dev/null || say "Ouvre-le depuis $DEST."
