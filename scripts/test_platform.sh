#!/usr/bin/env bash
# A local end-to-end check of roc-cfw against the real platform JS (no release, no deploy).
# In a project under .work/platform/: init, build the wasm with the nightly of the platform, sync, sync --check, then (when wrangler
# is on PATH) `wrangler dev --local` and GET /. It never runs `wrangler deploy`.
# Usage: scripts/test_platform.sh [<platform repo dir>]    (default: /home/george/dev/Karakatiza666/talon/cloudflare-workers)
#        ROC=<roc for building roc-cfw>   (default: the pinned nightly of .roc-version, as scripts/test.sh)
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
REPO=$(cd "${1:-/home/george/dev/Karakatiza666/talon/cloudflare-workers}" && pwd) || exit 1
PINNED=/home/george/dev/Karakatiza666/talon/cloudflare-workers/.cache/nightlies/$(cat "$ROOT/.roc-version")/roc
if [ -z "${ROC:-}" ]; then
  if [ -x "$PINNED" ]; then ROC=$PINNED; else ROC=$(command -v roc); fi
fi
WORK=$ROOT/.work
PROJ=$WORK/platform
FAILS=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; FAILS=$((FAILS + 1)); }
has() { grep -q -- "$2" "$1"; }
finish() { echo; if [ $FAILS = 0 ]; then echo "all passed"; exit 0; else echo "$FAILS failed"; exit 1; fi; }

command -v node >/dev/null || { echo "node is needed"; exit 1; }
[ -f "$REPO/platform/main.roc" ] && [ -f "$REPO/js/cfw.json" ] || { echo "no platform/main.roc or js/cfw.json in $REPO"; exit 1; }
NIGHTLY=$(tr -d '[:space:]' < "$REPO/compat/last-stack-first-nightly")
PROC=$REPO/.cache/nightlies/$NIGHTLY/roc
[ -x "$PROC" ] || { echo "no roc at $PROC (compat/last-stack-first-nightly)"; exit 1; }
echo "platform repo: $REPO"
echo "roc for the wasm: $NIGHTLY"

# roc-cfw itself.
mkdir -p "$WORK"
(cd "$ROOT" && "$ROC" build --no-cache --output="$WORK/roc-cfw" main.roc >"$WORK/build.log" 2>&1) || { bad "roc build of roc-cfw"; tail -20 "$WORK/build.log"; finish; }
ok "roc build of roc-cfw"
CFW=$WORK/roc-cfw

# The project: a stub body (Talon R-IN8), a path entry to the platform, a talon.toml with [tools] only.
rm -rf "$PROJ"; mkdir -p "$PROJ"; cd "$PROJ" || exit 1
# roc takes no absolute path for a platform, so the entry is relative to the project directory.
PF=$(realpath --relative-to="$PROJ" "$REPO/platform/main.roc")
printf 'app [event!] { pf: platform "%s" }\n\nevent! = |_| crash "write the app"\n' "$PF" > main.roc
printf '# the project\n[tools]\nroc-cfw = { ref = "Karakatiza666/roc-cloudflare-workers-cli@^1", url = "https://example.com/cli/releases/download/1.0.0/H.tar.zst" } # pinned\n' > talon.toml
cp talon.toml talon.toml.before

"$CFW" init --js "$REPO/js" >out 2>err; code=$?
if [ $code = 0 ] && [ -f main.roc ] && [ -f wrangler.toml ] && [ -f talon.toml ] && [ -f .gitignore ]; then ok "init: 4 files"; else bad "init (code $code)"; cat err; finish; fi
has main.roc "^app \[event!\] { pf: platform \"$PF\" }" && ! has main.roc 'write the app' && has main.roc 'Worker.new' && ok "init: header kept, stub body replaced" || bad "init: main.roc"
has wrangler.toml 'name = "platform"' && ok "init: wrangler.toml with the directory name" || bad "init: wrangler.toml name"
head -3 talon.toml | diff -q - <(head -3 talon.toml.before) >/dev/null && has talon.toml '^\[scripts\]' && has talon.toml '^build = ' && has talon.toml '^deploy = ' && ok "init: talon.toml, [tools] bytes kept, [scripts] added" || { bad "init: talon.toml"; cat talon.toml; }
has .gitignore '^app.wasm$' && has .gitignore '^.roc-cfw/$' && ok "init: .gitignore" || bad "init: .gitignore"

# The wasm, built with the nightly of the platform.
if "$PROC" build --target=wasm32 --no-cache --output=app.wasm main.roc >build.log 2>&1 && [ -s app.wasm ]; then ok "roc build --target=wasm32 ($NIGHTLY)"; else bad "roc build --target=wasm32"; tail -30 build.log; finish; fi

"$CFW" sync --js "$REPO/js" >out 2>err; code=$?
[ $code = 0 ] && ok "sync" || { bad "sync (code $code)"; cat out err; }
"$CFW" sync --js "$REPO/js" --check >out 2>err; code=$?
[ $code = 0 ] && ok "sync --check: exit 0" || { bad "sync --check (code $code)"; cat out err; }
has worker.js "from './.roc-cfw/index.js'" && ok "worker.js imports ./.roc-cfw/index.js" || { bad "worker.js import"; head -5 worker.js; }
[ -f .roc-cfw/cli.mjs ] && ok ".roc-cfw/cli.mjs is there" || bad ".roc-cfw/cli.mjs"

# wrangler dev --local, GET /. Never wrangler deploy.
if command -v wrangler >/dev/null; then
  PORT=$(node -e 'const s=require("net").createServer().listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')
  export WRANGLER_SEND_METRICS=false CI=1
  setsid wrangler dev --local --port "$PORT" --inspector-port 0 >dev.log 2>&1 &
  WPID=$!
  status=000
  for _ in $(seq 1 90); do
    status=$(curl -s -o body.txt -w '%{http_code}' --max-time 5 "http://127.0.0.1:$PORT/" 2>/dev/null || true)
    [ "$status" != 000 ] && break
    kill -0 "$WPID" 2>/dev/null || break
    sleep 1
  done
  kill -- -"$WPID" 2>/dev/null || kill "$WPID" 2>/dev/null
  wait "$WPID" 2>/dev/null
  if [ "$status" = 200 ]; then ok "wrangler dev --local: GET / gives 200 ($(head -c 60 body.txt))"; else bad "wrangler dev --local: GET / gave $status"; tail -20 dev.log; fi
else
  echo "skip wrangler dev: wrangler is not on PATH"
fi
finish
