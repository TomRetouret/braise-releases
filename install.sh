#!/bin/sh
# Installe ou met à jour Braise sur un Mac ou un PC Linux. (Windows : install.ps1.)
#   curl -fsSL https://raw.githubusercontent.com/TomRetouret/braise-releases/main/install.sh | sh
# Version précise : ... | BRAISE_VERSION=v0.6.0 sh
#
# Ce que fait ce script, et rien d'autre :
#   1. lit la dernière version publiée sur github.com/TomRetouret/braise-releases ;
#   2. télécharge l'app et vérifie son empreinte SHA-256 ;
#   3. Mac : vérifie sa signature (ad hoc, sans compte Apple), l'installe dans ~/Applications ;
#      Linux : installe l'AppImage dans ~/.local/share/braise, avec un raccourci dans le menu
#      des applications et la commande `braise` ;
#   4. l'ouvre. Aucun mot de passe administrateur.
# Désinstaller (Mac) : glisser ~/Applications/Braise.app à la corbeille, et supprimer
# ~/Library/Application Support/fr.quatresh.braise pour effacer la liste des projets.
# Désinstaller (Linux) : ... | BRAISE_UNINSTALL=1 sh

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

OS=$(uname -s)
case "$OS" in
  Darwin)
    major=$(sw_vers -productVersion | cut -d. -f1)
    [ "$major" -ge 12 ] 2>/dev/null || fail "Braise demande macOS 12 ou plus récent (ce Mac : $(sw_vers -productVersion))."
    ;;
  Linux)
    [ "$(uname -m)" = "x86_64" ] || fail "Braise pour Linux existe en x86_64 seulement (cet ordinateur : $(uname -m))."
    ;;
  *) fail "système non pris en charge ($OS). Sur Windows, utilise install.ps1 dans PowerShell." ;;
esac
command -v curl >/dev/null || fail "curl est introuvable."

# Linux : AppImage dans ~/.local/share/braise, lanceur ~/.local/bin/braise, entrée de menu.
LDIR="${XDG_DATA_HOME:-$HOME/.local/share}/braise"
LBIN="$HOME/.local/bin/braise"
LDESK="${XDG_DATA_HOME:-$HOME/.local/share}/applications/braise.desktop"

install_linux() {
  if pgrep -x braise >/dev/null 2>&1; then
    say "  Braise est ouvert : on le ferme pour le remplacer."
    pkill -TERM -x braise 2>/dev/null || true
    i=0
    while pgrep -x braise >/dev/null 2>&1 && [ $i -lt 30 ]; do sleep 1; i=$((i + 1)); done
  fi
  mkdir -p "$LDIR" "$(dirname "$LBIN")" "$(dirname "$LDESK")"
  install -m 755 "$1" "$LDIR/Braise.AppImage" || fail "copie impossible dans $LDIR."
  curl -fsSL -o "$LDIR/braise.png" "https://raw.githubusercontent.com/$OWNER/$REPO/main/assets/braise-icon.png" 2>/dev/null || true
  # Sans libfuse2 (Ubuntu 22.04 et plus récents), l'AppImage se lance en s'extrayant.
  {
    echo '#!/bin/sh'
    if ! (ldconfig -p 2>/dev/null | grep -q 'libfuse\.so\.2'); then echo 'export APPIMAGE_EXTRACT_AND_RUN=1'; fi
    echo "exec \"$LDIR/Braise.AppImage\" \"\$@\""
  } > "$LBIN"
  chmod 755 "$LBIN"
  cat > "$LDESK" <<DESK
[Desktop Entry]
Type=Application
Name=Braise
Comment=Tes projets, allumés.
Exec=$LBIN
Icon=$LDIR/braise.png
Categories=Development;
Terminal=false
StartupWMClass=braise
DESK
  command -v update-desktop-database >/dev/null && update-desktop-database "$(dirname "$LDESK")" >/dev/null 2>&1 || true
  ok "Installé dans $(printf '%s' "$LDIR" | sed "s|^$HOME|~|")"
  say ""
  say "Braise $tag est prêt. Il se mettra à jour tout seul."
  say "Ouvre-le depuis le menu des applications, ou tape : braise"
  case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) say "(Ajoute ~/.local/bin à ton PATH pour la commande braise.)" ;; esac
  (nohup "$LBIN" >/dev/null 2>&1 &) || true
}

if [ -n "${BRAISE_UNINSTALL:-}" ]; then
  [ "$OS" = "Linux" ] || fail "sur Mac, glisse ~/Applications/Braise.app à la corbeille."
  rm -f "$LBIN" "$LDESK" "$LDIR/Braise.AppImage" "$LDIR/braise.png"
  rmdir "$LDIR" 2>/dev/null || true
  say "Braise est désinstallé. Ta liste de projets reste dans ~/.local/share/fr.quatresh.braise (supprime ce dossier pour l'effacer)."
  exit 0
fi

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
if [ "$OS" = "Darwin" ]; then pattern='\.app\.tar\.gz'; else pattern='_amd64\.AppImage'; fi
url=$(printf '%s' "$json" | grep -o "\"browser_download_url\": *\"[^\"]*$pattern\"" | head -n 1 | sed 's/.*"\(http[^"]*\)"$/\1/')
sums=$(printf '%s' "$json" | grep -o '"browser_download_url": *"[^"]*SHA256SUMS\.txt"' | head -n 1 | sed 's/.*"\(http[^"]*\)"$/\1/')
[ -n "$tag" ] && [ -n "$url" ] || fail "aucune version de Braise publiée pour l'instant."
[ -n "$sums" ] || fail "la version $tag n'a pas de fichier d'empreintes, installation refusée."
ok "Version $tag trouvée"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/braise.XXXXXX")
trap 'rm -rf "$tmp"' EXIT INT TERM

file=$(basename "$url")
curl -fL --progress-bar -o "$tmp/$file" "$url" || fail "le téléchargement a échoué."
expected=$(curl -fsSL "$sums" | awk -v f="$file" '$2 == f || $2 == "*"f { print $1; exit }')
if command -v sha256sum >/dev/null; then actual=$(sha256sum "$tmp/$file" | awk '{ print $1 }'); else actual=$(shasum -a 256 "$tmp/$file" | awk '{ print $1 }'); fi
[ -n "$expected" ] && [ "$expected" = "$actual" ] || fail "l'empreinte SHA-256 ne correspond pas : fichier abîmé ou modifié."
ok "Empreinte SHA-256 vérifiée"

if [ "$OS" = "Linux" ]; then
  install_linux "$tmp/$file"
  exit 0
fi
mv "$tmp/$file" "$tmp/braise.app.tar.gz"

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
