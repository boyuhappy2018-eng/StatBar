#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h}"
APP_SOURCE="$PROJECT_DIR/build/StatBar.app"
DESTINATION="$HOME/Applications/StatBar.app"

if [[ ! -d "$APP_SOURCE" ]]; then
  "$PROJECT_DIR/build.sh"
fi

mkdir -p "$HOME/Applications"
osascript -e 'tell application id "com.statbar.app" to quit' 2>/dev/null || true
sleep 1
if [[ -e "$DESTINATION" ]]; then
  BACKUP="$HOME/Applications/StatBar.backup-$(date +%Y%m%d-%H%M%S).app"
  mv "$DESTINATION" "$BACKUP"
  echo "Previous copy moved to: $BACKUP"
fi

# File Provider folders can attach FinderInfo after a bundle is signed. Copy the
# app without extended attributes, then sign it at its final local location.
ditto --noextattr "$APP_SOURCE" "$DESTINATION"
xattr -cr "$DESTINATION"
codesign --force --sign - "$DESTINATION/Contents/Helpers/StatBarSMCHelper"
if [[ -d "$DESTINATION/Contents/PlugIns/StatBarControls.appex" ]]; then
  codesign --force --sign - "$DESTINATION/Contents/PlugIns/StatBarControls.appex"
fi
codesign --force --sign - --identifier com.statbar.app "$DESTINATION"
codesign --verify --deep --strict "$DESTINATION"
if [[ -d "$DESTINATION/Contents/PlugIns/StatBarControls.appex" ]]; then
  pluginkit -a "$DESTINATION/Contents/PlugIns/StatBarControls.appex"
fi
open "$DESTINATION"
echo "Installed and opened: $DESTINATION"
