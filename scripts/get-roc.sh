#!/usr/bin/env bash
# Print the path of the pinned roc compiler (the tag in .roc-version). Messages go to stderr.
# Order: 1. $ROC. 2. $ROOT/.cache/nightlies/<tag>/roc (an earlier install). 3. roc on PATH, when `roc version` has the tag.
#        4. A download of the release <tag> of roc-lang/nightlies into the dir of step 2: with gh (the sha256 is checked
#        against the digest of the release API), else with curl (no digest).
# Exit 1: unknown system, no asset, a sha256 mismatch, no roc in the archive.
set -eu -o pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
TAG=$(tr -d '[:space:]' < "$ROOT/.roc-version")
REPO=roc-lang/nightlies
fail() { echo "get-roc: $*" >&2; exit 1; }

if [ -n "${ROC:-}" ]; then echo "$ROC"; exit 0; fi

case "$(uname -s)-$(uname -m)" in
Linux-x86_64) target=linux_x86_64 ext=.tar.gz exe=roc ;;
Linux-aarch64 | Linux-arm64) target=linux_arm64 ext=.tar.gz exe=roc ;;
Darwin-arm64) target=macos_apple_silicon ext=.tar.gz exe=roc ;;
Darwin-x86_64) target=macos_x86_64 ext=.tar.gz exe=roc ;;
MINGW*-x86_64 | MSYS*-x86_64 | CYGWIN*-x86_64) target=windows_x86_64 ext=.zip exe=roc.exe ;;
*) fail "no nightly asset for $(uname -s) $(uname -m)" ;;
esac

dest=$ROOT/.cache/nightlies/$TAG
if [ -f "$dest/$exe" ]; then echo "$dest/$exe"; exit 0; fi
if command -v roc > /dev/null 2>&1 && roc version 2> /dev/null | grep -qF "${TAG#nightly-}"; then command -v roc; exit 0; fi

name=roc_nightly-$target-${TAG#nightly-}$ext
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
echo "get-roc: download $name" >&2
if command -v gh > /dev/null 2>&1 && { [ -n "${GH_TOKEN:-}" ] || gh auth status > /dev/null 2>&1; }; then
    want=$(gh api "repos/$REPO/releases/tags/$TAG" --jq ".assets[] | select(.name == \"$name\") | .digest") || fail "no release $TAG in $REPO"
    want=${want#sha256:}
    [ ${#want} -eq 64 ] || fail "asset $name has no sha256 digest"
    gh release download "$TAG" -R "$REPO" -p "$name" -D "$tmp" >&2 || fail "download of $name failed"
    if command -v sha256sum > /dev/null 2>&1; then got=$(sha256sum "$tmp/$name" | cut -d' ' -f1); else got=$(shasum -a 256 "$tmp/$name" | cut -d' ' -f1); fi
    [ "$got" = "$want" ] || fail "sha256 mismatch for $name: got $got, want $want"
else
    curl -fsSL -o "$tmp/$name" "https://github.com/$REPO/releases/download/$TAG/$name" || fail "download of $name failed"
fi

mkdir "$tmp/x"
case $ext in
.tar.gz) tar -xzf "$tmp/$name" -C "$tmp/x" ;;
.zip) if command -v 7z > /dev/null 2>&1; then 7z x -y "-o$tmp/x" "$tmp/$name" > /dev/null; else unzip -q "$tmp/$name" -d "$tmp/x"; fi ;;
esac
bin=$(find "$tmp/x" -type f -name "$exe" | head -n 1)
[ -n "$bin" ] || fail "no $exe in $name"
mkdir -p "$dest"
cp -R "$(dirname "$bin")/." "$dest/"
chmod +x "$dest/$exe"
echo "get-roc: installed $dest/$exe" >&2
echo "$dest/$exe"
