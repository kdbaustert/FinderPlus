#!/bin/bash
# Builds FinderPlus.app. Pass --install to copy it into /Applications and launch it.
set -euo pipefail

cd "$(dirname "$0")"
APP="build/FinderPlus.app"

echo "==> Compiling"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/FinderPlus"

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/FinderPlus"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# The icon, compiled the way Xcode does it: Assets.car (read through CFBundleIconName — the Dock
# showed a blank placeholder for a bare .icns) plus AppIcon.icns for anything older.
# Regenerate the artwork with `swift Resources/Icon/make-icon.swift` after changing the design.
echo "==> Compiling icon"
xcrun actool Resources/Assets.xcassets \
    --compile "$APP/Contents/Resources" \
    --platform macosx \
    --minimum-deployment-target 26.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$(mktemp -d)/partial.plist" >/dev/null
if [[ ! -f "$APP/Contents/Resources/Assets.car" ]]; then
    echo "==> ERROR: actool did not produce Assets.car" >&2
    exit 1
fi

# Ad-hoc: the app needs no entitlements and no Accessibility grant. The one cost is that macOS keys
# folder-access prompts (Desktop, Documents, Downloads) to the code hash, so each rebuild may ask
# again. A stable local identity, as Cmd-Tab uses, would stop that — set CODESIGN_IDENTITY.
IDENTITY="${CODESIGN_IDENTITY:--}"
echo "==> Signing (${IDENTITY/#-/ad-hoc})"
codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

echo "==> Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    echo "==> Installing to /Applications"
    osascript -e 'quit app "FinderPlus"' 2>/dev/null || true
    for _ in $(seq 1 30); do
        pgrep -x FinderPlus >/dev/null 2>&1 || break
        sleep 0.1
    done
    pkill -9 -x FinderPlus 2>/dev/null || true
    rm -rf /Applications/FinderPlus.app
    cp -R "$APP" /Applications/FinderPlus.app
    open /Applications/FinderPlus.app
    echo "==> Launched."
fi
