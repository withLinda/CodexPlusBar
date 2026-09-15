#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/build/design-preview/CodexPlusBarDesignPreview.app"
mkdir -p "$APP/Contents/MacOS"
if [[ "${1:-}" == "--build" ]]; then
    shift
    python3 - "$APP" <<'PY'
import pathlib, platform, plistlib, subprocess, sys
app = pathlib.Path(sys.argv[1])
info = {"CFBundleIdentifier": "com.linda.CodexPlusBar.DesignPreview", "CFBundleName": "CodexPlusBarDesignPreview", "CFBundleExecutable": "CodexPlusBarDesignPreview", "CFBundlePackageType": "APPL", "NSHighResolutionCapable": True}
(app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
sources = sorted(str(p) for p in pathlib.Path("Sources").rglob("*.swift") if p.name != "App.swift")
subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", "-D", "DEBUG", "-target", f"{platform.machine()}-apple-macos14.0", *sources, "scripts/DesignPreview.swift", "-o", str(app / "Contents/MacOS/CodexPlusBarDesignPreview")], check=True)
PY
fi
exec "$APP/Contents/MacOS/CodexPlusBarDesignPreview" "$@"
