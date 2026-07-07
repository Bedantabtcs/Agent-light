#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_APP="$ROOT/build/Agent Light.app"
DESTINATION_DIRECTORY="$HOME/Applications"
DESTINATION_APP="$DESTINATION_DIRECTORY/Agent Light.app"

"$ROOT/scripts/build-app.sh" release
mkdir -p "$DESTINATION_DIRECTORY"
rm -rf "$DESTINATION_APP"
ditto "$SOURCE_APP" "$DESTINATION_APP"
open "$DESTINATION_APP"
