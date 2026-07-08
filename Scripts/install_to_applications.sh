#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_APP="${1:-$ROOT/build/termu.app}"
TARGET_APP="/Applications/Termu.app"

if [[ ! -d "$SOURCE_APP" ]]; then
    echo "App bundle not found: $SOURCE_APP" >&2
    echo "Build it first with: Scripts/build_app.sh" >&2
    exit 1
fi

if [[ ! -x "$SOURCE_APP/Contents/MacOS/Termu" && ! -x "$SOURCE_APP/Contents/MacOS/termu" ]]; then
    echo "App executable not found in: $SOURCE_APP" >&2
    exit 1
fi

echo "Installing $SOURCE_APP to $TARGET_APP"
case "$TARGET_APP" in
    /Applications/Termu.app) ;;
    *) echo "Refusing to install outside /Applications/Termu.app: $TARGET_APP" >&2; exit 1 ;;
esac

pkill -x Termu >/dev/null 2>&1 || true
pkill -x termu >/dev/null 2>&1 || true
sudo rm -rf "$TARGET_APP"
sudo ditto "$SOURCE_APP" "$TARGET_APP"
sudo xattr -cr "$TARGET_APP"
codesign --verify --deep --strict --verbose=2 "$TARGET_APP"

echo "Installed Termu to $TARGET_APP"
