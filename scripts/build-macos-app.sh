#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="${1:-$REPO_ROOT/.build}"
APP_BUNDLE="$BUILD_ROOT/CodexSkin.app"
CONTENTS="$APP_BUNDLE/Contents"
RESOURCES="$CONTENTS/Resources"
RUNTIME="$RESOURCES/AutoSkinRuntime"

case "$APP_BUNDLE" in
  */.build/CodexSkin.app|*/CodexSkin.app) ;;
  *) echo "Refusing unexpected app output: $APP_BUNDLE" >&2; exit 1 ;;
esac

rm -rf "$APP_BUNDLE"
mkdir -p "$CONTENTS/MacOS" "$RUNTIME" "$CONTENTS/Resources"

cp "$REPO_ROOT/app/macos/Info.plist" "$CONTENTS/Info.plist"
cp "$REPO_ROOT/app/macos/assets/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
cp "$REPO_ROOT/app/macos/autoskin-app-command.sh" "$RESOURCES/autoskin-app-command.sh"
chmod 755 "$RESOURCES/autoskin-app-command.sh"

for entry in scripts assets styles themes examples; do
  /usr/bin/ditto "$REPO_ROOT/skill/$entry" "$RUNTIME/$entry"
done

xcrun swiftc \
  -framework AppKit \
  -framework ServiceManagement \
  -target "$(uname -m)-apple-macos13.0" \
  "$REPO_ROOT/app/macos/AutoSkinApp.swift" \
  -o "$CONTENTS/MacOS/CodexSkin"

/usr/bin/codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null
/usr/bin/plutil -lint "$CONTENTS/Info.plist" >/dev/null
AUTOSKIN_RESOURCE_ROOT="$RESOURCES" bash "$RESOURCES/autoskin-app-command.sh" self-test
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"

echo "$APP_BUNDLE"
