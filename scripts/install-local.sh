#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_APP="$ROOT/build/Agent Light.app"
DESTINATION_DIRECTORY="$HOME/Applications"
DESTINATION_APP="$DESTINATION_DIRECTORY/Agent Light.app"
STAGING_ROOT=""
BACKUP_ROOT=""
PRESERVE_BACKUP=0

cleanup() {
    if [[ -n "$STAGING_ROOT" ]]; then
        rm -rf "$STAGING_ROOT"
    fi
    if [[ -n "$BACKUP_ROOT" && "$PRESERVE_BACKUP" -eq 0 ]]; then
        rm -rf "$BACKUP_ROOT"
    fi
}

trap cleanup EXIT

"$ROOT/scripts/build-app.sh" release
mkdir -p "$DESTINATION_DIRECTORY"

if [[ -L "$DESTINATION_APP" ]]; then
    echo "Refusing to replace symlink destination: $DESTINATION_APP" >&2
    exit 1
fi
if [[ -e "$DESTINATION_APP" && ! -d "$DESTINATION_APP" ]]; then
    echo "Refusing to replace non-directory destination: $DESTINATION_APP" >&2
    exit 1
fi

osascript -e 'tell application id "com.bbatchas.agentlight" to quit' >/dev/null 2>&1 || true
for _ in {1..100}; do
    pgrep -x AgentLight >/dev/null || break
    sleep 0.1
done
if pgrep -x AgentLight >/dev/null; then
    echo "Agent Light did not quit cleanly" >&2
    exit 1
fi

STAGING_ROOT="$(mktemp -d "$DESTINATION_DIRECTORY/.agent-light-stage.XXXXXX")"
STAGED_APP="$STAGING_ROOT/Agent Light.app"
ditto "$SOURCE_APP" "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"

if [[ -e "$DESTINATION_APP" ]]; then
    BACKUP_ROOT="$(mktemp -d "$DESTINATION_DIRECTORY/.agent-light-backup.XXXXXX")"
    BACKUP_APP="$BACKUP_ROOT/Agent Light.app"
    mv "$DESTINATION_APP" "$BACKUP_APP"
    PRESERVE_BACKUP=1
fi

if ! mv "$STAGED_APP" "$DESTINATION_APP"; then
    if [[ -n "$BACKUP_ROOT" ]] && mv "$BACKUP_APP" "$DESTINATION_APP"; then
        PRESERVE_BACKUP=0
    elif [[ -n "$BACKUP_ROOT" ]]; then
        echo "Replacement failed; existing app is preserved at: $BACKUP_APP" >&2
    fi
    exit 1
fi

if [[ -n "$BACKUP_ROOT" ]]; then
    PRESERVE_BACKUP=0
    rm -rf "$BACKUP_ROOT"
    BACKUP_ROOT=""
fi

open "$DESTINATION_APP"
