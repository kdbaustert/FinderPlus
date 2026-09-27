#!/bin/bash
# Builds FinderPlus.app. Pass --install to copy it into /Applications and launch it.
#
# Environment (release.sh sets these):
#   RELEASE=1          keep the update feed in Info.plist; without it the feed is removed, so a
#                      local build never updates itself out from under its developer
#   VERSION, BUILD     stamp CFBundleShortVersionString / CFBundleVersion into the built bundle
#   CODESIGN_IDENTITY  signing identity; ad-hoc when unset
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

# ---------------------------------------------------------------- Sparkle
#
# SwiftPM links Sparkle.framework but does nothing to put it inside a bundle assembled by hand, so
# without these steps the app launches and dies on its first Sparkle call with dyld's "Library not
# loaded". Copy the macOS slice in, point an rpath at it, and sign it before the app (below).
SPARKLE_XC="$(find .build/artifacts -type d -name 'Sparkle.xcframework' -print -quit)"
if [[ -z "$SPARKLE_XC" ]]; then
    echo "==> ERROR: Sparkle.xcframework not found — run 'swift package resolve' first" >&2
    exit 1
fi
SPARKLE_FW="$(find "$SPARKLE_XC" -maxdepth 2 -type d -name 'Sparkle.framework' -path '*macos*' -print -quit)"
echo "==> Embedding Sparkle"
mkdir -p "$APP/Contents/Frameworks"
# -R keeps the version symlinks a framework is made of; the signature fails without them.
cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/"
# Only when missing: -add_rpath refuses a duplicate. grep without -q reads otool to the end, since
# under pipefail an early exit would fail the pipeline.
if ! otool -l "$APP/Contents/MacOS/FinderPlus" | grep -F -- '@executable_path/../Frameworks' >/dev/null; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/FinderPlus"
fi

if [[ -n "${VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
if [[ -n "${BUILD:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
fi
# The tracked Info.plist carries the release feed. A local build must not follow it: it would see
# the published version as newer than the working tree and replace the build being tested.
if [[ "${RELEASE:-0}" != "1" ]]; then
    /usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$APP/Contents/Info.plist" 2>/dev/null || true
fi

# ---------------------------------------------------------------- signing
#
# Ad-hoc by default: the app needs no entitlements. The one cost is that macOS keys folder-access
# prompts (Desktop, Documents, Downloads) to the code hash, so each rebuild may ask again. A stable
# local identity, as Cmd-Tab uses, would stop that — set CODESIGN_IDENTITY.
#
# Inside out, because an outer signature seals the inner ones: first the bare helper executables in
# Sparkle (Autoupdate), then its bundles deepest first (XPC services, Updater.app, the framework),
# then the app. Signed the other way round, the bundle passes a plain verify and fails --deep.
IDENTITY="${CODESIGN_IDENTITY:--}"
echo "==> Signing (${IDENTITY/#-/ad-hoc})"
while IFS= read -r item; do
    codesign --force --sign "$IDENTITY" "$item"
done < <(find "$APP/Contents/Frameworks" -type f -perm -u+x ! -path '*/Contents/MacOS/*' \
    -exec sh -c 'file -b "$1" | grep -q "Mach-O.*executable"' _ {} \; -print)
while IFS= read -r item; do
    codesign --force --sign "$IDENTITY" "$item"
done < <(find "$APP/Contents/Frameworks" -depth \( -name '*.app' -o -name '*.xpc' -o -name '*.framework' \) ! -type l -print)
codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

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
    # Services are read from a cache; without a refresh "Search with FinderPlus" can take until the
    # next login to appear in Finder's right-click menu.
    /System/Library/CoreServices/pbs -update
    open /Applications/FinderPlus.app
    echo "==> Launched."
fi
