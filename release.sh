#!/bin/bash
# Builds a FinderPlus release and publishes it to GitHub Releases, where the app's updater finds it.
#
# Usage:
#   VERSION=1.1.0 BUILD=2 ./release.sh                        build, package, write the signed appcast
#   VERSION=1.1.0 BUILD=2 ./release.sh --publish              ... then publish a stable release
#   VERSION=1.2.0-beta.1 BUILD=3 ./release.sh --beta          a beta, prepared but not published
#   VERSION=1.2.0-beta.1 BUILD=3 ./release.sh --beta --publish  ... published as a GitHub pre-release
#
# VERSION is what people see. BUILD is what Sparkle compares to decide whether an update is newer,
# so it must be a whole number that grows with every release — across betas and stable alike.
#
# Stable releases reach everyone. Beta releases are tagged with Sparkle's "beta" channel in the feed,
# so only copies with "Receive beta updates" turned on in Settings are offered them.
#
# The feed is appcast.xml on a GitHub release tagged "appcast", created on the first publish and
# re-uploaded by every one after — the published feed is fetched and this release added to it,
# never replaced, so nobody on an older version is stranded.
#
# Releases are ad-hoc signed: there is no Developer ID behind them. Gatekeeper flags the first
# download (right-click → Open, or `xattr -cr` on the app, gets past it once); updates after that
# arrive through Sparkle, which checks each one against the EdDSA key instead.
#
# Environment:
#   SPARKLE_KEY_FILE  sign the appcast with a private key file instead of the login keychain
#                     (for a machine without the key in its keychain, e.g. CI)
set -euo pipefail

cd "$(dirname "$0")"
REPO="kdbaustert/FinderPlus"
APP="build/FinderPlus.app"
RELEASES="build/releases"
STAGING="build/appcast-staging"
FEED_TAG="appcast"
PUBLISH=0
BETA=0
for argument in "$@"; do
    case "$argument" in
        --publish) PUBLISH=1 ;;
        --beta) BETA=1 ;;
        *)
            echo "==> ERROR: unknown argument '$argument' (expected --beta and/or --publish)" >&2
            exit 1
            ;;
    esac
done

: "${VERSION:?Set VERSION, e.g. VERSION=1.1.0 BUILD=2 ./release.sh}"
: "${BUILD:?Set BUILD, a whole number that grows with every release — Sparkle compares it}"
if [[ ! "$BUILD" =~ ^[0-9]+$ ]]; then
    echo "==> ERROR: BUILD must be a whole number, not '$BUILD'" >&2
    exit 1
fi

if [[ "$PUBLISH" == "1" ]]; then
    # From a Mac, the release's tag is made from what GitHub has, so unpushed commits would be left
    # out of the release that is supposed to contain them. On GitHub Actions the tag being released
    # is already there, and the checkout is that tag rather than a branch with an upstream.
    if [[ "${GITHUB_ACTIONS:-}" != "true" ]]; then
        git fetch --quiet origin
        if [[ -n "$(git status --porcelain)" ]] || [[ "$(git rev-parse HEAD)" != "$(git rev-parse '@{u}')" ]]; then
            echo "==> ERROR: commit and push first — the release is tagged from what GitHub has" >&2
            exit 1
        fi
    fi
    if gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1; then
        echo "==> ERROR: release v$VERSION already exists" >&2
        exit 1
    fi
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

# generate_appcast sees this release's zip and the published feed, nothing else. Shown older zips,
# it would rewrite their entries to point at this release's download folder, where they don't exist.
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp "$RELEASES/$ARCHIVE" "$STAGING/"
FEED="https://github.com/$REPO/releases/download/$FEED_TAG/appcast.xml"
FEED_EXISTS=0
echo "==> Fetching the published appcast"
if curl -fsSL "$FEED" -o "$STAGING/appcast.xml"; then
    FEED_EXISTS=1
else
    rm -f "$STAGING/appcast.xml"
    # Only the very first release has nothing to extend. Any other failure would publish a feed
    # listing this release alone, stranding everyone on older versions.
    if gh release view "$FEED_TAG" --repo "$REPO" >/dev/null 2>&1; then
        echo "==> ERROR: could not fetch $FEED, but the feed release exists — not overwriting it" >&2
        exit 1
    fi
    echo "    No feed yet: starting a new appcast"
fi

echo "==> Signing the update and writing the appcast"
APPCAST_ARGS=()
if [[ -n "${SPARKLE_KEY_FILE:-}" ]]; then
    APPCAST_ARGS=(--ed-key-file "$SPARKLE_KEY_FILE")
fi
# A beta's entry carries the "beta" channel; clients only see it once they have opted in.
if [[ "$BETA" == "1" ]]; then
    APPCAST_ARGS+=(--channel beta)
fi
# ${a[@]+...}: macOS ships bash 3.2, where an empty array under `set -u` is an error.
"$GENERATE_APPCAST" ${APPCAST_ARGS[@]+"${APPCAST_ARGS[@]}"} \
    --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
    --full-release-notes-url "https://github.com/$REPO/releases/tag/v$VERSION" \
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

# ---------------------------------------------------------------- publish

if [[ "$PUBLISH" != "1" ]]; then
    echo
    echo "    To publish, commit the version change in Resources/Info.plist, push, then run:"
    echo "      VERSION=$VERSION BUILD=$BUILD ./release.sh$([[ "$BETA" == "1" ]] && echo " --beta") --publish"
    exit 0
fi

if [[ "$BETA" == "1" ]]; then
    echo "==> Publishing v$VERSION to GitHub as a pre-release"
    gh release create "v$VERSION" "$RELEASES/$ARCHIVE" \
        --repo "$REPO" --title "FinderPlus $VERSION" --generate-notes --prerelease
else
    echo "==> Publishing v$VERSION to GitHub"
    gh release create "v$VERSION" "$RELEASES/$ARCHIVE" \
        --repo "$REPO" --title "FinderPlus $VERSION" --generate-notes --latest
fi

# The feed goes up last, once the zip it points at is downloadable.
if [[ "$FEED_EXISTS" == "1" ]]; then
    echo "==> Updating the feed"
    gh release upload "$FEED_TAG" "$RELEASES/appcast.xml" --repo "$REPO" --clobber
else
    echo "==> Creating the feed release"
    # A pre-release that is never "latest", so it cannot take the place of a real release.
    gh release create "$FEED_TAG" "$RELEASES/appcast.xml" --repo "$REPO" \
        --title "Update feed" --prerelease --latest=false \
        --notes "Holds appcast.xml, which FinderPlus checks for updates. Not a download — see the releases below."
fi
echo "==> Published: https://github.com/$REPO/releases/tag/v$VERSION"
echo "    Installed copies will offer it at their next daily check, or at once from"
echo "    FinderPlus → Check for Updates…"
