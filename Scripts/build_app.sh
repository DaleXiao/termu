#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
APP_DIR="$ROOT/build/termu.app"
STAGE_DIR="$ROOT/build/termu.app.stage"
BINARY="$ROOT/.build/$CONFIGURATION/termu"

cd "$ROOT"
swift package resolve

SWIFTTERM_ROOT="$ROOT/.build/checkouts/SwiftTerm"
SWIFTTERM_MAC_VIEW="$SWIFTTERM_ROOT/Sources/SwiftTerm/Mac/MacTerminalView.swift"
SWIFTTERM_TERMINAL="$SWIFTTERM_ROOT/Sources/SwiftTerm/Terminal.swift"
SWIFTTERM_BUFFER="$SWIFTTERM_ROOT/Sources/SwiftTerm/Buffer.swift"
SWIFTTERM_CLEAR_PATCH="$ROOT/Patches/SwiftTerm-clear-background.patch"
SWIFTTERM_MARGIN_ERASE_PATCH="$ROOT/Patches/SwiftTerm-margin-erase.patch"
SWIFTTERM_MOUSE_WHEEL_PATCH="$ROOT/Patches/SwiftTerm-mouse-wheel-reporting.patch"
SWIFTTERM_MARGIN_WRAP_PATCH="$ROOT/Patches/SwiftTerm-margin-wrap-reflow.patch"
SWIFTTERM_PENDING_WRAP_PATCH="$ROOT/Patches/SwiftTerm-pending-wrap-vertical.patch"
SWIFTTERM_CLEAR_WRAPPED_EL_PATCH="$ROOT/Patches/SwiftTerm-clear-wrapped-el.patch"
SWIFTTERM_CLEAR_WRAPPED_ED_PATCH="$ROOT/Patches/SwiftTerm-clear-wrapped-ed.patch"
SWIFTTERM_DISABLE_REFLOW_PATCH="$ROOT/Patches/SwiftTerm-disable-resize-reflow.patch"

if [[ -f "$SWIFTTERM_MAC_VIEW" ]] && ! grep -q "nativeBackgroundColor.setFill()" "$SWIFTTERM_MAC_VIEW"; then
    chmod u+w "$SWIFTTERM_MAC_VIEW"
    patch -d "$SWIFTTERM_ROOT" -p1 < "$SWIFTTERM_CLEAR_PATCH"
fi

if [[ -f "$SWIFTTERM_TERMINAL" ]] && ! grep -q "let leftBound = marginMode ? buffer.marginLeft : 0" "$SWIFTTERM_TERMINAL"; then
    chmod u+w "$SWIFTTERM_TERMINAL"
    patch -d "$SWIFTTERM_ROOT" -p1 < "$SWIFTTERM_MARGIN_ERASE_PATCH"
fi

if [[ -f "$SWIFTTERM_MAC_VIEW" ]] && ! grep -q "sendWheelEventToApplication" "$SWIFTTERM_MAC_VIEW"; then
    chmod u+w "$SWIFTTERM_MAC_VIEW"
    patch -d "$SWIFTTERM_ROOT" -p1 < "$SWIFTTERM_MOUSE_WHEEL_PATCH"
fi

if [[ -f "$SWIFTTERM_BUFFER" ]] && ! grep -q "let canTrackLineWrap = !marginMode" "$SWIFTTERM_BUFFER"; then
    chmod u+w "$SWIFTTERM_BUFFER"
    patch -d "$SWIFTTERM_ROOT" -p1 < "$SWIFTTERM_MARGIN_WRAP_PATCH"
fi

if [[ -f "$SWIFTTERM_TERMINAL" ]] && ! grep -q "func clampPendingWrapColumn" "$SWIFTTERM_TERMINAL"; then
    chmod u+w "$SWIFTTERM_TERMINAL"
    patch -d "$SWIFTTERM_ROOT" -p1 < "$SWIFTTERM_PENDING_WRAP_PATCH"
fi

if [[ -f "$SWIFTTERM_TERMINAL" ]] && ! grep -q "clearWrap: buffer.x == leftBound" "$SWIFTTERM_TERMINAL"; then
    chmod u+w "$SWIFTTERM_TERMINAL"
    patch -d "$SWIFTTERM_ROOT" -p1 < "$SWIFTTERM_CLEAR_WRAPPED_EL_PATCH"
fi

if [[ -f "$SWIFTTERM_TERMINAL" ]] && ! grep -q "displayLeftBound" "$SWIFTTERM_TERMINAL"; then
    chmod u+w "$SWIFTTERM_TERMINAL"
    patch -d "$SWIFTTERM_ROOT" -p1 < "$SWIFTTERM_CLEAR_WRAPPED_ED_PATCH"
fi

if [[ -f "$SWIFTTERM_BUFFER" ]] && ! grep -q "termu disables resize reflow" "$SWIFTTERM_BUFFER"; then
    chmod u+w "$SWIFTTERM_BUFFER"
    patch -d "$SWIFTTERM_ROOT" -p1 < "$SWIFTTERM_DISABLE_REFLOW_PATCH"
fi

swift build -c "$CONFIGURATION"

case "$STAGE_DIR" in
    "$ROOT"/build/*) ;;
    *) echo "Refusing to package outside build directory: $STAGE_DIR" >&2; exit 1 ;;
esac

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR/Contents/MacOS"
mkdir -p "$STAGE_DIR/Contents/Resources"

cp "$BINARY" "$STAGE_DIR/Contents/MacOS/termu"
cp "$ROOT/Resources/Info.plist" "$STAGE_DIR/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$STAGE_DIR/Contents/Resources/AppIcon.icns"

for bundle in "$ROOT/.build/$CONFIGURATION"/*.bundle; do
    [[ -d "$bundle" ]] || continue
    cp -R "$bundle" "$STAGE_DIR/Contents/Resources/"
done

if [[ -n "${TERMU_CODESIGN_IDENTITY:-}" ]]; then
    codesign --force \
        --deep \
        --sign "$TERMU_CODESIGN_IDENTITY" \
        --entitlements "$ROOT/Resources/Termu.entitlements" \
        "$STAGE_DIR"
else
    codesign --force \
        --deep \
        --sign - \
        "$STAGE_DIR"
fi

rm -rf "$APP_DIR"
mv "$STAGE_DIR" "$APP_DIR"

echo "$APP_DIR"
