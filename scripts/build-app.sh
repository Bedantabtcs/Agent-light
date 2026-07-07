#!/bin/bash
set -euo pipefail

CONFIGURATION="${1:-}"
case "$CONFIGURATION" in
  debug|release) ;;
  *) echo "usage: $0 debug|release" >&2; exit 64 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
swift build --package-path "$ROOT" -c "$CONFIGURATION" --product AgentLight
swift build --package-path "$ROOT" -c "$CONFIGURATION" --product AgentLightRelay
BIN_DIR="$(swift build --package-path "$ROOT" -c "$CONFIGURATION" --show-bin-path)"
APP="$ROOT/build/Agent Light.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"

rm -rf "$APP"
mkdir -p "$MACOS"
cp "$BIN_DIR/AgentLight" "$MACOS/AgentLight"
cp "$BIN_DIR/AgentLightRelay" "$MACOS/AgentLightRelay"
cp "$ROOT/Resources/AgentLight-Info.plist" "$CONTENTS/Info.plist"
chmod 0755 "$MACOS/AgentLight" "$MACOS/AgentLightRelay"
codesign --force --deep --sign - "$APP"
echo "$APP"
