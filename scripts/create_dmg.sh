#!/usr/bin/env bash
set -euo pipefail

APP_PATH=""
OUTPUT_PATH=""
VOLUME_NAME=""

usage() {
  cat <<'EOF'
Usage: scripts/create_dmg.sh --app /path/to/App.app --output /path/to/App.dmg [--volume-name NAME]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      [[ $# -ge 2 ]] || { echo "Missing value for --app" >&2; exit 1; }
      APP_PATH="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || { echo "Missing value for --output" >&2; exit 1; }
      OUTPUT_PATH="$2"
      shift 2
      ;;
    --volume-name)
      [[ $# -ge 2 ]] || { echo "Missing value for --volume-name" >&2; exit 1; }
      VOLUME_NAME="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$APP_PATH" || -z "$OUTPUT_PATH" ]]; then
  usage >&2
  exit 1
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found: $APP_PATH" >&2
  exit 1
fi

if [[ ! -f "$APP_PATH/Contents/Info.plist" ]]; then
  echo "App bundle is missing Contents/Info.plist: $APP_PATH" >&2
  exit 1
fi

if [[ -z "$VOLUME_NAME" ]]; then
  VOLUME_NAME="$(basename "$APP_PATH" .app)"
fi

OUTPUT_DIR="$(dirname "$OUTPUT_PATH")"
APP_NAME="$(basename "$APP_PATH")"
TMP_BASE="${TMPDIR:-/tmp}"
STAGING_DIR="$(mktemp -d "$TMP_BASE/dmg-staging.XXXXXX")"

cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

mkdir -p "$OUTPUT_DIR"
rm -f "$OUTPUT_PATH"

echo "Verifying code signature for $APP_NAME"
codesign --verify --deep --strict "$APP_PATH"

echo "Preparing DMG staging folder"
ditto "$APP_PATH" "$STAGING_DIR/$APP_NAME"
ln -s /Applications "$STAGING_DIR/Applications"

echo "Creating DMG at $OUTPUT_PATH"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$OUTPUT_PATH"

echo "DMG created: $OUTPUT_PATH"
