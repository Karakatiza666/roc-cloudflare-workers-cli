#!/usr/bin/env bash
# Check a bundle as a user gets it: roc unbundle restores it (roc checks the hash in the file name), the header has the platform and
# the roc: pin, `roc build --no-cache` of the restored main.roc works, and the built roc-cfw prints its usage.
# Usage: scripts/test_bundle.sh <bundle file>    ROC=<path of roc> (default: scripts/get-roc.sh)
set -eu -o pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
ROC=${ROC:-$("$HERE/get-roc.sh")}
BUNDLE=$(cd "$(dirname "${1:?usage: scripts/test_bundle.sh <bundle file>}")" && pwd)/$(basename "$1")
TAG=$(tr -d '[:space:]' < "$ROOT/.roc-version")
case $(uname -s) in MINGW* | MSYS* | CYGWIN*) EXE=.exe ;; *) EXE= ;; esac
DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT
cd "$DIR"
"$ROC" unbundle "$BUNDLE"
pkg=$DIR/$(basename "$BUNDLE" .tar.zst)
[ -f "$pkg/main.roc" ] && [ -f "$pkg/lib/main.roc" ] || { echo "test_bundle: main.roc or lib/main.roc is not in the bundle" >&2; exit 1; }
grep -q 'platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/' "$pkg/main.roc" || { echo "test_bundle: no basic-cli 0.26.0 platform in the header" >&2; exit 1; }
grep -qE "roc:[[:space:]]*\"$TAG\"" "$pkg/main.roc" || { echo "test_bundle: no roc pin $TAG in the header" >&2; exit 1; }
cd "$pkg"
"$ROC" build --no-cache --output="$DIR/roc-cfw$EXE" main.roc
"$DIR/roc-cfw$EXE" help | grep -q 'roc-cfw shim' || { echo "test_bundle: the built roc-cfw prints no usage" >&2; exit 1; }
echo "test_bundle: ok ($(basename "$BUNDLE"))"
