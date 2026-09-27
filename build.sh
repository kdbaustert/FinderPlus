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

# A release is universal: macOS 26 still runs on some Intel Macs. A local build stays native, at
# half the compile time.
ARCH_ARGS=()
if [[ "${RELEASE:-0}" == "1" ]]; then
    ARCH_ARGS=(--arch arm64 --arch x86_64)
fi
echo "==> Compiling"
# ${a[@]+...}: macOS ships bash 3.2, where an empty array under `set -u` is an error.
swift build -c release ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}
BIN="$(swift build -c release ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --show-bin-path)/FinderPlus"

# The Shortcuts/Siri actions in Intents.swift only exist to the system through a
# Metadata.appintents bundle, which Xcode builds produce and `swift build` does not. The metadata
# processor (run after assembly, below) reads `.swiftconstvalues` files the compiler emits when
# asked, for the protocols named in a JSON list.
#
# A *separate* build in its own scratch path, always carrying the emission flags, rather than the
# flags on the main build above: llbuild does not fingerprint `-Xswiftc` flags, so adding them to
# an up-to-date tree rebuilds nothing and emits nothing. Absolute paths throughout — the emission
# path resolves against the compiler's working directory, and a relative one lands nowhere.
# (The same arrangement as Cmd-Tab's, where the pitfalls above were measured.)
INTENTS_DIR="$(pwd)/.build/appintents"
mkdir -p "$INTENTS_DIR"
CONSTVALS="$INTENTS_DIR/FinderPlus.swiftconstvalues"
printf '%s' '["AppIntent","AppEntity","AppEnum","AppShortcutsProvider","TransientAppEntity","EntityQuery","DynamicOptionsProvider","EnumerableEntityQuery","AppIntentsPackage"]' \
    > "$INTENTS_DIR/protocols.json"
echo "==> Extracting App Intents const values"
swift build -c release --scratch-path "$INTENTS_DIR/scratch" \
    -Xswiftc -emit-const-values-path -Xswiftc "$CONSTVALS" \
    -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file \
    -Xswiftc -Xfrontend -Xswiftc "$INTENTS_DIR/protocols.json" >/dev/null
if [[ ! -s "$CONSTVALS" ]]; then
    echo "==> ERROR: $CONSTVALS was not emitted — the Shortcuts actions would be invisible" >&2
    exit 1
fi

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/FinderPlus"
if [[ "${RELEASE:-0}" == "1" ]]; then
    ARCHS="$(lipo -archs "$APP/Contents/MacOS/FinderPlus")"
    if [[ " $ARCHS " != *" arm64 "* || " $ARCHS " != *" x86_64 "* ]]; then
        echo "==> ERROR: the release binary is '$ARCHS', not universal (arm64 and x86_64)" >&2
        exit 1
    fi
fi
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

# ---------------------------------------------------------------- App Intents metadata
#
# Turns the const values emitted above into Contents/Resources/Metadata.appintents — where every
# Xcode-built macOS app carries it, and what Shortcuts, Spotlight and Siri actually index. Before
# signing, because the app's seal covers it. The processor wants the *source* list as well as the
# const values, and a deployment target and triple that match the build.
echo "==> App Intents metadata"
find "$(pwd)/Sources/FinderPlus" -name '*.swift' > "$INTENTS_DIR/sources.txt"
echo "$CONSTVALS" > "$INTENTS_DIR/constvals.txt"
INTENTS_TOOL="$(xcrun --find appintentsmetadataprocessor)"
xcrun appintentsmetadataprocessor \
    --output "$APP/Contents/Resources" \
    --toolchain-dir "${INTENTS_TOOL%/usr/bin/appintentsmetadataprocessor}" \
    --module-name FinderPlus \
    --sdk-root "$(xcrun --show-sdk-path --sdk macosx)" \
    --xcode-version "$(xcodebuild -version | tail -1 | awk '{print $3}')" \
    --platform-family macOS \
    --deployment-target 26.0 \
    --target-triple "$(uname -m)-apple-macos26.0" \
    --source-file-list "$INTENTS_DIR/sources.txt" \
    --swift-const-vals-list "$INTENTS_DIR/constvals.txt" \
    --force --quiet-warnings >/dev/null
if [[ ! -f "$APP/Contents/Resources/Metadata.appintents/extract.actionsdata" ]]; then
    echo "==> ERROR: Metadata.appintents did not materialise — the Shortcuts actions would be invisible" >&2
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
    # Copied beside the old copy first, so a failed copy leaves it installed; only the rename below
    # runs with no app in place. Not named *.app, so nothing registers the half-copied bundle.
    STAGED="/Applications/.FinderPlus-installing"
    rm -rf "$STAGED"
    cp -R "$APP" "$STAGED"
    rm -rf /Applications/FinderPlus.app
    mv "$STAGED" /Applications/FinderPlus.app
    # Services are read from a cache; without a refresh "Search with FinderPlus" can take until the
    # next login to appear in Finder's right-click menu.
    /System/Library/CoreServices/pbs -update
    open /Applications/FinderPlus.app
    echo "==> Launched."
fi
