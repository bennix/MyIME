#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
OUTPUT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/MyIME-install.XXXXXX")
trap 'rm -rf "$OUTPUT_DIR"' EXIT

"$SCRIPT_DIR/build_dict.sh"
xcodebuild \
  -project "$ROOT_DIR/MyIME/MyIME.xcodeproj" \
  -scheme MyIME \
  -configuration Release \
  -derivedDataPath "$OUTPUT_DIR/DerivedData" \
  build

SOURCE_APP="$OUTPUT_DIR/DerivedData/Build/Products/Release/MyIME.app"
INSTALL_DIR="$HOME/Library/Input Methods"
DESTINATION_APP="$INSTALL_DIR/MyIME.app"
mkdir -p "$INSTALL_DIR"
pkill -f "$DESTINATION_APP/Contents/MacOS/MyIME" 2>/dev/null || true
ditto "$SOURCE_APP" "$DESTINATION_APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DESTINATION_APP"
xcrun swift "$SCRIPT_DIR/register_input_source.swift" "$DESTINATION_APP"

echo "Installed MyIME.app to $DESTINATION_APP"
echo "Add MyIME in System Settings > Keyboard > Input Sources. Log out and back in if it is not listed yet."
