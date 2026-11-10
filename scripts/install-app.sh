#!/bin/bash
# Install a verified app transactionally. All moved bundles are retained.
set -euo pipefail
umask 077
BUILT_APP="${1:?Pass the built Voice.app}"
INSTALL_DIR="${2:?Pass the Applications directory}"
BACKUP_ROOT="${3:?Pass the backup directory}"
if [[ ! -d "$BUILT_APP" || -L "$BUILT_APP" ]]; then echo 'The built Voice app is unavailable.'; exit 1; fi
mkdir -p "$INSTALL_DIR" "$BACKUP_ROOT"
for name in Voice.app LocalVoice.app; do
  if [[ -L "$INSTALL_DIR/$name" || ( -e "$INSTALL_DIR/$name" && ! -d "$INSTALL_DIR/$name" ) ]]; then
    echo "Leave $INSTALL_DIR/$name untouched: it is not an ordinary app bundle."; exit 1
  fi
  if [[ -d "$INSTALL_DIR/$name" ]]; then
    existing_id="$(plutil -extract CFBundleIdentifier raw -o - "$INSTALL_DIR/$name/Contents/Info.plist" 2>/dev/null)" || existing_id=""
    if [[ "$existing_id" != com.sunday.localvoice ]]; then
      echo "Leave $INSTALL_DIR/$name untouched: it belongs to another app or its identity could not be verified."
      echo 'Move that app to a different location yourself before installing Voice here.'
      exit 1
    fi
  fi
done
STAGE="$(mktemp -d "$INSTALL_DIR/.Voice-stage.XXXXXX")"
BACKUP=""
VOICE_MOVED=0
LEGACY_MOVED=0
COMMITTED=0
finish() {
  local status=$?
  trap - EXIT
  if [[ "$COMMITTED" == 0 ]]; then
    # A same-volume bundle rename is atomic. Keep any unexpected destination
    # instead of deleting it before restoring previous bundles.
    if [[ "$VOICE_MOVED" == 1 || "$LEGACY_MOVED" == 1 ]]; then
      if [[ -e "$INSTALL_DIR/Voice.app" ]]; then
        if ! mv "$INSTALL_DIR/Voice.app" "$BACKUP/Incomplete-Voice.app"; then
          echo "Could not move the incomplete app aside. Previous bundles remain at $BACKUP."
          status=1
        fi
      fi
      if [[ "$VOICE_MOVED" == 1 ]]; then
        if [[ -e "$INSTALL_DIR/Voice.app" || -L "$INSTALL_DIR/Voice.app" ]]; then
          echo "Voice.app could not be restored over an occupied destination. Previous bundle remains at $BACKUP/Voice.app."
          status=1
        elif ! mv "$BACKUP/Voice.app" "$INSTALL_DIR/Voice.app"; then
          echo "Restore Voice.app manually from $BACKUP."
          status=1
        fi
      fi
      if [[ "$LEGACY_MOVED" == 1 ]]; then
        if [[ -e "$INSTALL_DIR/LocalVoice.app" || -L "$INSTALL_DIR/LocalVoice.app" ]]; then
          echo "LocalVoice.app could not be restored over an occupied destination. Previous bundle remains at $BACKUP/LocalVoice.app."
          status=1
        elif ! mv "$BACKUP/LocalVoice.app" "$INSTALL_DIR/LocalVoice.app"; then
          echo "Restore LocalVoice.app manually from $BACKUP."
          status=1
        fi
      fi
      echo 'Installation did not finish; previous app bundles were restored where possible.'
    fi
  fi
  rm -rf "$STAGE"
  exit "$status"
}
trap finish EXIT
ditto "$BUILT_APP" "$STAGE/Voice.app"
codesign --verify --deep --strict "$STAGE/Voice.app"
if [[ -e "$INSTALL_DIR/Voice.app" || -e "$INSTALL_DIR/LocalVoice.app" ]]; then
  BACKUP="$(mktemp -d "$BACKUP_ROOT/Previous.XXXXXX")"
fi
if [[ -e "$INSTALL_DIR/Voice.app" ]]; then
  mv "$INSTALL_DIR/Voice.app" "$BACKUP/Voice.app"
  VOICE_MOVED=1
fi
if [[ -e "$INSTALL_DIR/LocalVoice.app" ]]; then
  mv "$INSTALL_DIR/LocalVoice.app" "$BACKUP/LocalVoice.app"
  LEGACY_MOVED=1
fi
mv "$STAGE/Voice.app" "$INSTALL_DIR/Voice.app"
COMMITTED=1
if [[ -n "$BACKUP" ]]; then echo "Previous app bundles retained at $BACKUP"; fi
