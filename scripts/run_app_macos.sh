#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: run_app_macos.sh --app-path /path/to/App.app [--background] [--replace-app-path] [--replace-bundle-id]

Environment:
  TRACE_PRIVATE_API=1    Launch the app executable directly so trace env vars reach the process.
  APP_TRACE_LOG=/path    File to receive stdout/stderr when TRACE_PRIVATE_API=1.
USAGE
}

APP_PATH=""
BACKGROUND=0
REPLACE_APP_PATH=0
REPLACE_BUNDLE_ID=0
TRACE_PRIVATE_API_FLAG="${TRACE_PRIVATE_API:-0}"
APP_TRACE_LOG_PATH="${APP_TRACE_LOG:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-path)
      APP_PATH="$2"
      shift 2
      ;;
    --background)
      BACKGROUND=1
      shift
      ;;
    --replace-app-path)
      REPLACE_APP_PATH=1
      shift
      ;;
    --replace-bundle-id)
      REPLACE_BUNDLE_ID=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
 done

if [[ -z "$APP_PATH" ]]; then
  echo "Missing --app-path" >&2
  usage
  exit 1
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "App not found: $APP_PATH" >&2
  exit 1
fi

INFO_PLIST="$APP_PATH/Contents/Info.plist"
EXECUTABLE_NAME=""
BUNDLE_ID=""
if [[ -f "$INFO_PLIST" ]]; then
  EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$INFO_PLIST" 2>/dev/null || true)"
  BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$INFO_PLIST" 2>/dev/null || true)"
fi

EXECUTABLE_PATH=""
if [[ -n "$EXECUTABLE_NAME" ]]; then
  EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
fi

terminate_bundle_instances() {
  local bundle_id="$1"
  local app_specifier=""

  while IFS= read -r app_specifier; do
    [[ -n "$app_specifier" ]] || continue
    /usr/bin/lsappinfo kill "$app_specifier" >/dev/null 2>&1 || true
  done < <(/usr/bin/lsappinfo find "bundleid=$bundle_id" 2>/dev/null || true)
}

wait_for_bundle_exit() {
  local bundle_id="$1"
  local attempts=0

  while (( attempts < 30 )); do
    if /usr/bin/lsappinfo info "$bundle_id" >/dev/null 2>&1; then
      /bin/sleep 0.1
      attempts=$((attempts + 1))
      continue
    fi

    return 0
  done

  return 1
}

if [[ $REPLACE_BUNDLE_ID -eq 1 && -n "$BUNDLE_ID" ]]; then
  terminate_bundle_instances "$BUNDLE_ID"
  if ! wait_for_bundle_exit "$BUNDLE_ID"; then
    while IFS= read -r app_specifier; do
      [[ -n "$app_specifier" ]] || continue
      /usr/bin/lsappinfo kill -force "$app_specifier" >/dev/null 2>&1 || true
    done < <(/usr/bin/lsappinfo find "bundleid=$BUNDLE_ID" 2>/dev/null || true)
    wait_for_bundle_exit "$BUNDLE_ID" || true
  fi
fi

if [[ $REPLACE_APP_PATH -eq 1 && -n "$EXECUTABLE_PATH" && -x "$EXECUTABLE_PATH" ]]; then
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    /bin/kill "$pid" >/dev/null 2>&1 || true
  done < <(/usr/bin/pgrep -f "$EXECUTABLE_PATH" || true)
fi

if [[ "$TRACE_PRIVATE_API_FLAG" == "1" ]]; then
  if [[ -z "$EXECUTABLE_PATH" || ! -x "$EXECUTABLE_PATH" ]]; then
    echo "App executable not found: $EXECUTABLE_PATH" >&2
    exit 1
  fi

  if [[ -z "$APP_TRACE_LOG_PATH" ]]; then
    echo "Missing APP_TRACE_LOG when TRACE_PRIVATE_API=1" >&2
    exit 1
  fi

  mkdir -p "$(dirname "$APP_TRACE_LOG_PATH")"
  : > "$APP_TRACE_LOG_PATH"
  printf "[run_app_macos] Launching %s with TRACE_PRIVATE_API=1\n" "$EXECUTABLE_PATH" >> "$APP_TRACE_LOG_PATH"
  printf "[run_app_macos] Log started at %s\n" "$(/bin/date -u +"%Y-%m-%dT%H:%M:%SZ")" >> "$APP_TRACE_LOG_PATH"

  /usr/bin/nohup /usr/bin/env \
    TRACE_PRIVATE_API=1 \
    CODEXPLUSBAR_TRACE_PRIVATE_API=1 \
    "$EXECUTABLE_PATH" >> "$APP_TRACE_LOG_PATH" 2>&1 &

  echo "Launched app executable directly for tracing."
  echo "Trace log: $APP_TRACE_LOG_PATH"
  exit 0
fi

if [[ $BACKGROUND -eq 1 ]]; then
  open -gj "$APP_PATH"
else
  open "$APP_PATH"
fi
