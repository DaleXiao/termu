#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_PROCESS_NAME="termu"
BUNDLE_ID="com.dingxiao.termu"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/build/termu.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/termu"

stop_running_app() {
  pkill -x "$APP_PROCESS_NAME" >/dev/null 2>&1 || true
}

build_app() {
  "$ROOT_DIR/Scripts/build_app.sh"
}

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

stop_running_app
build_app

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_PROCESS_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_PROCESS_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
