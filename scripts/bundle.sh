#!/usr/bin/env bash
# Make the app bundle of roc-cfw: main.roc first, then every .roc file of lib/. Talon builds a project tool from this bundle (Talon R-T10, R-PT6).
# Usage: scripts/bundle.sh [<output dir>]    (default: dist)    ROC=<path of roc> (default: scripts/get-roc.sh)
# Output on stdout: `asset: <path>` and `name: <hash>.tar.zst`. Exit 1: no roc:-pin in main.roc, not exactly one bundle, or a bad name.
set -eu -o pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
ROC=${ROC:-$("$HERE/get-roc.sh")}
OUT=${1:-$ROOT/dist}
TAG=$(tr -d '[:space:]' < "$ROOT/.roc-version")

# Talon stops for an app header with no roc: pin (R-T29), and the pin must be the nightly that the tests use.
grep -qE "^[[:space:]]*roc:[[:space:]]*\"$TAG\"" "$ROOT/main.roc" || { echo "bundle: main.roc has no roc: \"$TAG\" entry in its header" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
cd "$ROOT"
files=(main.roc)
while IFS= read -r file; do files+=("$file"); done < <(find lib -type f -name '*.roc' | LC_ALL=C sort)
"$ROC" bundle "${files[@]}" --output-dir "$OUT" >&2

shopt -s nullglob
assets=("$OUT"/*.tar.zst)
[ ${#assets[@]} -eq 1 ] || { echo "bundle: expected one .tar.zst in $OUT, found ${#assets[@]}" >&2; exit 1; }
name=$(basename "${assets[0]}")
[[ "$name" =~ ^[1-9A-HJ-NP-Za-km-z]{43,44}\.tar\.zst$ ]] || { echo "bundle: the name is not <base58>.tar.zst: $name" >&2; exit 1; }
echo "asset: ${assets[0]}"
echo "name: $name"
