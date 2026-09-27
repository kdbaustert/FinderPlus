#!/bin/bash
# Builds a FinderPlus release: the app, its zip, and the update feed with this release added.
#
# Releases are published by GitHub Actions when a version tag is pushed — see
# .github/workflows/release.yml — the same way as Cmd-Tab's. This script is the build half that
# workflow runs, and it can be run by hand to check a release before tagging it:
#
#   VERSION=1.2.0 BUILD=40 ./release.sh               a stable release
#   VERSION=1.3.0-beta BUILD=41 ./release.sh --beta   a beta, offered only to copies that opt in
#
# VERSION is what people see. BUILD is what Sparkle compares to decide whether an update is newer,
# so it must be a whole number that grows with every release, betas and stable alike (the workflow
# uses the commit count).
#
# Releases are ad-hoc signed: there is no Developer ID behind them. Gatekeeper flags the first
# download (right-click → Open, or `xattr -cr` on the app, gets past it once); updates after that
# arrive through Sparkle, which checks each one against the EdDSA key instead.
#
# Environment:
#   SPARKLE_KEY_FILE  sign the feed with a private key file instead of the login keychain (the
#                     workflow's case: read from a runner's keychain, signing stops for a
#                     permission prompt nobody is there to answer)
set -euo pipefail

cd "$(dirname "$0")"
APP="build/FinderPlus.app"
RELEASES="build/releases"
STAGING="build/appcast-staging"
BETA=0
for argument in "$@"; do
    case "$argument" in
        --beta) BETA=1 ;;
        *)
            echo "==> ERROR: unknown argument '$argument' (expected --beta or nothing)" >&2
            exit 1
            ;;
    esac
done

: "${VERSION:?Set VERSION, e.g. VERSION=1.2.0 BUILD=40 ./release.sh}"
: "${BUILD:?Set BUILD, a whole number that grows with every release — Sparkle compares it}"
if [[ ! "$BUILD" =~ ^[0-9]+$ ]]; then
    echo "==> ERROR: BUILD must be a whole number, not '$BUILD'" >&2
    exit 1
fi

# ---------------------------------------------------------------- build

# The version goes into the tracked Info.plist too, so the tree records what was last shipped.
# A text substitution rather than PlistBuddy, which would re-sort the file and drop its comments.
stamp() {
    KEY="$1" VALUE="$2" perl -0pi -e \
        's{(<key>\Q$ENV{KEY}\E</key>\s*<string>)[^<]*(</string>)}{$1$ENV{VALUE}$2}' Resources/Info.plist
    if [[ "$(/usr/libexec/PlistBuddy -c "Print :$1" Resources/Info.plist)" != "$2" ]]; then
        echo "==> ERROR: could not stamp $1=$2 into Resources/Info.plist" >&2
        exit 1
    fi
}
stamp CFBundleShortVersionString "$VERSION"
stamp CFBundleVersion "$BUILD"

RELEASE=1 VERSION="$VERSION" BUILD="$BUILD" ./build.sh
if [[ -z "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$APP/Contents/Info.plist" 2>/dev/null)" ]]; then
    echo "==> ERROR: the built app has no SUFeedURL — it would never find an update" >&2
    exit 1
fi

# ---------------------------------------------------------------- package

ARCHIVE="FinderPlus-$VERSION.zip"
mkdir -p "$RELEASES"
echo "==> Packaging $ARCHIVE"
# ditto, not zip: it keeps the framework's version symlinks, without which the signature fails.
rm -f "$RELEASES/$ARCHIVE"
ditto -c -k --keepParent "$APP" "$RELEASES/$ARCHIVE"

# ---------------------------------------------------------------- appcast

GENERATE_APPCAST="$(find .build/artifacts -type f -name generate_appcast -perm -u+x -print -quit)"
if [[ -z "$GENERATE_APPCAST" ]]; then
    echo "==> ERROR: generate_appcast not found — run 'swift package resolve'" >&2
    exit 1
fi

# The feed this release extends, read from the gh-pages branch rather than the Pages URL that
# serves it: the URL 404s while Pages is off and caches for ten minutes when it is on, so a second
# release soon after the first would extend a feed missing the first's entry and publish over it.
# `--exit-code` tells "no such branch" (2: the first release) from a failed query, which must stop
# the release rather than read as a first one.
rm -rf "$STAGING"
mkdir -p "$STAGING"
status=0
git ls-remote --exit-code --heads origin gh-pages >/dev/null || status=$?
if [[ "$status" == 2 ]]; then
    echo "==> No gh-pages branch yet: this release starts the feed"
elif [[ "$status" != 0 ]]; then
    echo "==> ERROR: could not ask origin about gh-pages (git ls-remote exit $status)" >&2
    exit 1
else
    git fetch --quiet origin gh-pages
    if git cat-file -e origin/gh-pages:appcast.xml 2>/dev/null; then
        git show origin/gh-pages:appcast.xml > "$STAGING/appcast.xml"
        echo "==> Extending the published appcast"
    else
        echo "==> gh-pages has no appcast.xml yet: this release starts the feed"
    fi
fi

# generate_appcast sees this release's zip and the feed so far, nothing else. Shown older zips, it
# would rewrite their entries to point at this release's download folder, where they don't exist.
cp "$RELEASES/$ARCHIVE" "$STAGING/"
APPCAST_ARGS=()
if [[ -n "${SPARKLE_KEY_FILE:-}" ]]; then
    APPCAST_ARGS=(--ed-key-file "$SPARKLE_KEY_FILE")
fi
# A beta's entry carries the "beta" channel; clients only see it once they have opted in.
if [[ "$BETA" == "1" ]]; then
    APPCAST_ARGS+=(--channel beta)
fi
echo "==> Signing the update and writing the appcast"
# ${a[@]+...}: macOS ships bash 3.2, where an empty array under `set -u` is an error.
"$GENERATE_APPCAST" ${APPCAST_ARGS[@]+"${APPCAST_ARGS[@]}"} \
    --download-url-prefix "https://github.com/kdbaustert/FinderPlus/releases/download/v$VERSION/" \
    --full-release-notes-url "https://github.com/kdbaustert/FinderPlus/releases/tag/v$VERSION" \
    --maximum-deltas 0 \
    "$STAGING"
cp "$STAGING/appcast.xml" "$RELEASES/appcast.xml"

if ! grep -F -- "sparkle:edSignature" "$RELEASES/appcast.xml" >/dev/null; then
    echo "==> ERROR: the appcast has no EdDSA signature — every client would refuse the update" >&2
    exit 1
fi
if [[ "$BETA" == "1" ]] && ! grep -F -- "<sparkle:channel>beta</sparkle:channel>" "$RELEASES/appcast.xml" >/dev/null; then
    echo "==> ERROR: the beta's appcast entry has no beta channel — it would go to everyone" >&2
    exit 1
fi

echo "==> Ready ($([[ "$BETA" == "1" ]] && echo beta || echo stable)): $RELEASES/$ARCHIVE and $RELEASES/appcast.xml"
echo "    To publish, push the tag: git tag v$VERSION && git push origin v$VERSION"
