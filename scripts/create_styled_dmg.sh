#!/usr/bin/env zsh
set -euo pipefail

APP_PATH="${1:-./dist/NativeCurlRunner.app}"
OUT_DMG="${2:-./dist/NativeCurlRunner.dmg}"
VOL_NAME="${3:-NativeCurlRunner}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App not found: $APP_PATH" >&2
  exit 1
fi

WORK_ROOT="$(mktemp -d /tmp/nativecurlrunner-dmg.XXXXXX)"
STAGE_DIR="$WORK_ROOT/stage"
RW_DMG="$WORK_ROOT/temp-rw.dmg"
MOUNT_DIR="/Volumes/$VOL_NAME"
MOUNTED="0"

cleanup() {
  if [[ "$MOUNTED" == "1" ]] && mount | rg -q "$MOUNT_DIR"; then
    hdiutil detach "$MOUNT_DIR" -quiet || hdiutil detach "$MOUNT_DIR" -force -quiet || true
  fi
  rm -rf "$WORK_ROOT"
}
trap cleanup EXIT

mkdir -p "$STAGE_DIR"
cp -R "$APP_PATH" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

APP_NAME="$(basename "$APP_PATH")"

create_basic_dmg() {
  hdiutil create -srcfolder "$STAGE_DIR" -volname "$VOL_NAME" -format UDZO -ov "$OUT_DMG"
}

attempt_styled_layout() {
  hdiutil create -srcfolder "$STAGE_DIR" -volname "$VOL_NAME" -fs HFS+ -format UDRW "$RW_DMG"
  hdiutil attach "$RW_DMG" -mountpoint "$MOUNT_DIR" -noverify -noautoopen
  MOUNTED="1"

  osascript <<EOF
tell application "Finder"
  tell disk "$VOL_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {100, 100, 720, 430}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 100
    set position of item "$APP_NAME" to {160, 160}
    set position of item "Applications" to {460, 160}
    close
    open
    update without registering applications
    delay 1
  end tell
end tell
EOF

  if mount | rg -q "$MOUNT_DIR"; then
    hdiutil detach "$MOUNT_DIR" -quiet || hdiutil detach "$MOUNT_DIR" -force -quiet || true
  fi
  MOUNTED="0"

  hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$OUT_DMG" -ov
}

if attempt_styled_layout; then
  echo "Created styled DMG: $OUT_DMG"
else
  echo "Warning: styled Finder layout failed; producing default drag-to-Applications DMG." >&2
  create_basic_dmg
  echo "Created DMG: $OUT_DMG"
fi
