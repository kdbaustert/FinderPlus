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
# uses the commit count). A BUILD not above every build already in the feed is raised to one that
# is: two releases with the same build would share, and garble, one feed entry.
#
# Releases are ad-hoc signed unless the workflow has a signing identity (see build.sh's
# CODESIGN_IDENTITY): there is no Developer ID behind them. Gatekeeper flags the first download
# (right-click → Open, or `xattr -cr` on the app, gets past it once); updates after that arrive
# through Sparkle, which checks each one against the EdDSA key instead.
#
# Environment:
#   SPARKLE_KEY_FILE  sign the feed with a private key file instead of the login keychain (the
#                     workflow's case: read from a runner's keychain, signing stops for a
#                     permission prompt nobody is there to answer)
#   EXISTING_ZIP      a zip already built (and perhaps already published), relative to the
#                     repository root: add it to the feed instead of building. Its own
#                     CFBundleVersion replaces BUILD, since its signature covers those bytes.
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

ARCHIVE="FinderPlus-$VERSION.zip"
ZIP="$RELEASES/$ARCHIVE"
if [[ -n "${EXISTING_ZIP:-}" ]]; then
    if [[ ! -f "$EXISTING_ZIP" ]]; then
        echo "==> ERROR: EXISTING_ZIP '$EXISTING_ZIP' does not exist" >&2
        exit 1
    fi
    ZIP="$EXISTING_ZIP"
    ZIP_PLIST="$(mktemp)"
    unzip -p "$ZIP" FinderPlus.app/Contents/Info.plist > "$ZIP_PLIST"
    ZIP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ZIP_PLIST")"
    BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ZIP_PLIST")"
    rm -f "$ZIP_PLIST"
    if [[ "$ZIP_VERSION" != "$VERSION" ]]; then
        echo "==> ERROR: $ZIP is version $ZIP_VERSION, not $VERSION" >&2
        exit 1
    fi
    echo "==> Using the existing $ZIP (build $BUILD) instead of building"
fi

# ---------------------------------------------------------------- feed so far

# The feed this release extends, read from the gh-pages branch rather than the Pages URL that
# serves it: the URL 404s while Pages is off and caches for ten minutes when it is on, so a second
# release soon after the first would extend a feed missing the first's entry and publish over it.
# `--exit-code` tells "no such branch" (2: the first release) from a failed query, which must stop
# the release rather than read as a first one. Read before building, because BUILD depends on it.
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

# Feed items are matched with local-name() because xmllint cannot bind the sparkle: prefix.
SPARKLE_NS="http://www.andymatuschak.org/xml-namespaces/sparkle"
sparkle() {
    printf '*[local-name()="%s" and namespace-uri()="%s"]' "$1" "$SPARKLE_NS"
}
# The one feed entry for $BUILD, as an XPath; its fields are read with `feed_value`.
ITEM="/rss/channel/item[$(sparkle version) = \"$BUILD\"]"
feed_value() {
    xmllint --xpath "$1" "$STAGING/appcast.xml"
}

ENTRY_EXISTS=0
if [[ -f "$STAGING/appcast.xml" ]]; then
    # The highest build in the feed: the one no other build is greater than.
    LATEST="$(feed_value "string(/rss/channel/item/$(sparkle version)[not(. < /rss/channel/item/$(sparkle version))])")"
    LATEST="${LATEST:-0}"
    if [[ ! "$LATEST" =~ ^[0-9]+$ ]]; then
        echo "==> ERROR: the published feed's highest build is '$LATEST', not a whole number" >&2
        exit 1
    fi
    if [[ -n "${EXISTING_ZIP:-}" ]]; then
        # A re-run after the feed was already published: check that entry rather than write another.
        [[ "$(feed_value "count($ITEM)")" != 0 ]] && ENTRY_EXISTS=1
    elif (( BUILD <= LATEST )); then
        echo "==> NOTE: build $BUILD is not above the feed's highest build ($LATEST); releasing as build $((LATEST + 1))"
        BUILD=$((LATEST + 1))
        ITEM="/rss/channel/item[$(sparkle version) = \"$BUILD\"]"
    fi
fi

# Build and package only when there is no existing zip (left unindented; it closes after package).
if [[ -z "${EXISTING_ZIP:-}" ]]; then

# ---------------------------------------------------------------- build

# The version goes into the tracked Info.plist too, so the tree records what was last shipped.
# A text substitution rather than PlistBuddy, which would re-sort the file and drop its comments.
# Put back on exit unless this is the workflow succeeding — it commits the stamp afterwards — so a
# hand run or a failed build leaves the tracked file as it found it.
PLIST_BACKUP="$(mktemp)"
cp Resources/Info.plist "$PLIST_BACKUP"
restore_plist() {
    local exit_status=$?
    if [[ "$exit_status" != 0 || -z "${GITHUB_ACTIONS:-}" ]]; then
        cp "$PLIST_BACKUP" Resources/Info.plist
    fi
    rm -f "$PLIST_BACKUP"
}
trap restore_plist EXIT
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

mkdir -p "$RELEASES"
echo "==> Packaging $ARCHIVE"
# ditto, not zip: it keeps the framework's version symlinks, without which the signature fails.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

fi

# ---------------------------------------------------------------- appcast

mkdir -p "$RELEASES"
if [[ "$ENTRY_EXISTS" == "1" ]]; then
    echo "==> The feed already has build $BUILD: checking it rather than writing it again"
else
    GENERATE_APPCAST="$(find .build/artifacts -type f -name generate_appcast -perm -u+x -print -quit)"
    if [[ -z "$GENERATE_APPCAST" ]]; then
        echo "==> ERROR: generate_appcast not found — run 'swift package resolve'" >&2
        exit 1
    fi

    # generate_appcast sees this release's zip and the feed so far, nothing else. Shown older zips,
    # it would rewrite their entries to point at this release's download folder, where they don't
    # exist.
    cp "$ZIP" "$STAGING/"
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
    # It exits 0 after a key mismatch (writing an unsigned entry) and after an unreadable key
    # (writing nothing), so its output is checked too. "updated N existing" means it edited an entry
    # already published, which the build number check above exists to prevent.
    status=0
    output="$("$GENERATE_APPCAST" ${APPCAST_ARGS[@]+"${APPCAST_ARGS[@]}"} \
        --download-url-prefix "https://github.com/kdbaustert/FinderPlus/releases/download/v$VERSION/" \
        --full-release-notes-url "https://github.com/kdbaustert/FinderPlus/releases/tag/v$VERSION" \
        --maximum-deltas 0 \
        "$STAGING" 2>&1)" || status=$?
    printf '%s\n' "$output"
    if [[ "$status" != 0 ]]; then
        echo "==> ERROR: generate_appcast failed (exit $status)" >&2
        exit 1
    fi
    if grep -E -- 'Warning:|Error:|updated [1-9][0-9]* existing' <<<"$output" >/dev/null; then
        echo "==> ERROR: generate_appcast reported a problem (above) — the feed cannot be trusted" >&2
        exit 1
    fi
fi
cp "$STAGING/appcast.xml" "$RELEASES/appcast.xml"

# The checks read this release's own entry, not the whole feed, where an older entry would pass.
if [[ ! -f "$STAGING/appcast.xml" || "$(feed_value "count($ITEM)")" != 1 ]]; then
    echo "==> ERROR: the appcast has no single entry for build $BUILD" >&2
    exit 1
fi
TITLE="$(feed_value "string($ITEM/title)")"
if [[ "$TITLE" != "$VERSION" ]]; then
    echo "==> ERROR: build $BUILD's appcast entry is titled '$TITLE', not '$VERSION'" >&2
    exit 1
fi
if [[ -z "$(feed_value "string($ITEM/enclosure/@$(sparkle edSignature))")" ]]; then
    echo "==> ERROR: build $BUILD's appcast entry has no EdDSA signature — every client would refuse the update" >&2
    exit 1
fi
CHANNEL="$(feed_value "string($ITEM/$(sparkle channel))")"
if [[ "$VERSION" == *-* && "$CHANNEL" != "beta" ]]; then
    echo "==> ERROR: the beta's appcast entry has no beta channel — it would go to everyone" >&2
    exit 1
fi
if [[ "$VERSION" != *-* && -n "$CHANNEL" ]]; then
    echo "==> ERROR: the stable release's appcast entry is on channel '$CHANNEL' — most copies would never see it" >&2
    exit 1
fi

# The workflow records the build it shipped, which may be the raised one or the existing zip's.
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "build=$BUILD" >> "$GITHUB_OUTPUT"
fi

echo "==> Ready ($([[ "$BETA" == "1" ]] && echo beta || echo stable)): $ZIP and $RELEASES/appcast.xml"
echo "    To publish, push the tag: git tag v$VERSION && git push origin v$VERSION"
