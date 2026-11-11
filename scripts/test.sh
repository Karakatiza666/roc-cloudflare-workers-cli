#!/usr/bin/env bash
# The tests of roc-cfw. Step 1: roc check, roc fmt --check, roc test (the pure decisions in lib/).
# Step 2: build roc-cfw and run it on the fixtures in fixtures/ (a fake platform package, a stub cli.mjs, a template).
# The step 2 runs need node. A fake `roc` on PATH stands for the fetch of `roc check`. A fake `tln` on PATH stands for `tln path`
# (Talon R-PTH1), so the tests do not depend on the Talon cache. Its answer is set by TLN_OUT and TLN_CODE, its calls go to TLN_LOG.
# deploy: a fake wrangler (fixtures/deploy/wrangler) and a fake Worker (fixtures/deploy/server.mjs on 127.0.0.1). No call reaches Cloudflare.
# Usage: scripts/test.sh [unit|build|e2e]   (build: only roc build and `roc-cfw help`, for a system where the fake programs of e2e cannot run)
#           ROC=<path of roc> (default: scripts/get-roc.sh, the nightly of .roc-version)
#        PLATFORM_REPO=<dir> (default: ../talon/cloudflare-workers; the real js/ runs are skipped when it is not there)
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
ROC=${ROC:-$("$HERE/get-roc.sh")} || exit 1
STEP=${1:-all}
WORK=$ROOT/.work
FAILS=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; FAILS=$((FAILS + 1)); }
# expect <name> <command that must succeed>
expect() { local n=$1; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }
has() { grep -q -- "$2" "$1"; }

if [ "$STEP" = all ] || [ "$STEP" = unit ]; then
  cd "$ROOT" || exit 1
  expect "roc check main.roc" "$ROC" check main.roc
  expect "roc fmt --check" "$ROC" fmt --check main.roc lib tests
  for t in tests/*.roc; do
    if out=$("$ROC" test --no-cache "$t" 2>&1); then ok "roc test $t: $(echo "$out" | tail -1)"; else bad "roc test $t"; echo "$out" | tail -30; fi
  done
fi

# The built file of roc-cfw has the suffix .exe on Windows.
case $(uname -s) in MINGW* | MSYS* | CYGWIN*) EXE=.exe ;; *) EXE= ;; esac

if [ "$STEP" = build ]; then
  mkdir -p "$WORK"; cd "$ROOT" || exit 1
  "$ROC" build --no-cache --output="$WORK/roc-cfw$EXE" main.roc >"$WORK/build.log" 2>&1 || { bad "roc build"; tail -20 "$WORK/build.log"; exit 1; }
  ok "roc build"
  if "$WORK/roc-cfw$EXE" help >"$WORK/help.txt" 2>&1 && has "$WORK/help.txt" 'roc-cfw'; then ok "roc-cfw help"; else bad "roc-cfw help"; cat "$WORK/help.txt"; fi
fi

if [ "$STEP" = all ] || [ "$STEP" = e2e ]; then
  command -v node >/dev/null || { echo "node is needed for the e2e step"; exit 1; }
  rm -rf "$WORK"; mkdir -p "$WORK"
  cd "$ROOT" || exit 1
  "$ROC" build --no-cache --output="$WORK/roc-cfw$EXE" main.roc >"$WORK/build.log" 2>&1 || { bad "roc build"; tail -20 "$WORK/build.log"; exit 1; }
  ok "roc build"
  CFW=$WORK/roc-cfw
  # A cache with the fixture platform under the hash of the fixture app, and one with an api that is not known.
  cache() { # <dir> : $1/roc/packages/FIXTUREHASH = platform, $1/roc/packages/NEWAPI = platform-api9
    mkdir -p "$1/roc/packages"; cp -r "$ROOT/fixtures/platform" "$1/roc/packages/FIXTUREHASH"; cp -r "$ROOT/fixtures/platform-api9" "$1/roc/packages/NEWAPI"
  }
  project() { # <name> : a project dir with the url app
    rm -rf "$WORK/$1"; mkdir -p "$WORK/$1"; cp "$ROOT"/fixtures/app-url/main.roc "$ROOT"/fixtures/app-url/talon.toml "$WORK/$1/"
  }
  cache "$WORK/cache"
  export XDG_CACHE_HOME=$WORK/cache
  # The fake tln. By default it fails (exit 1), so the runs below use the cache rule. Single tests change TLN_OUT and TLN_CODE.
  mkdir -p "$WORK/tlnbin"
  cat > "$WORK/tlnbin/tln" <<'FAKE'
#!/usr/bin/env bash
echo "$@" >> "${TLN_LOG:-/dev/null}"
[ -n "${TLN_OUT:-}" ] && echo "$TLN_OUT"
exit "${TLN_CODE:-0}"
FAKE
  chmod +x "$WORK/tlnbin/tln"
  export PATH="$WORK/tlnbin:$PATH" TLN_CODE=1 TLN_LOG="$WORK/tln.log"

  # sync: the copy, the stamp, node runs the stub from .roc-cfw/ with the other arguments in order, in the project directory.
  project p1; cd "$WORK/p1" || exit 1
  "$CFW" sync --wasm app.wasm --check >out 2>err; code=$?
  [ $code = 0 ] && has out 'STUB args=\["sync","--file","main.roc","--wasm","app.wasm","--check"\] sibling=true' && ok "sync: copy, stamp and arguments" || { bad "sync: copy, stamp and arguments (code $code)"; cat out err; }
  [ "$(cat .roc-cfw/.platform)" = FIXTUREHASH ] && [ -f .roc-cfw/index.js ] && [ ! -e .roc-cfw.tmp-* ] && ok "sync: .platform holds the hash, no temp dir left" || bad "sync: .platform holds the hash, no temp dir left"
  # The exit code of node passes through.
  "$CFW" sync --exit 7 >/dev/null 2>&1; code=$?
  [ $code = 7 ] && ok "sync: exit code of node passes through" || bad "sync: exit code of node (got $code)"
  # The stamp is equal: no copy (a marker file stays). The stamp differs: a copy (the marker goes).
  touch .roc-cfw/marker
  "$CFW" shim >out 2>err
  [ -f .roc-cfw/marker ] && has err 'up to date' && ! has out STUB && ok "shim: equal stamp, no copy, no node" || bad "shim: equal stamp, no copy, no node"
  echo OTHERHASH > .roc-cfw/.platform
  "$CFW" shim >/dev/null 2>&1
  [ ! -e .roc-cfw/marker ] && [ "$(cat .roc-cfw/.platform)" = FIXTUREHASH ] && ok "shim: another stamp, copied again" || bad "shim: another stamp, copied again"

  # tln path (Talon R-PTH1): the fake tln gives the directory. The cache is empty and the fake roc is not on PATH, so only tln can find it.
  project p7; cd "$WORK/p7" || exit 1
  rm -f "$TLN_LOG"
  TLN_CODE=0 TLN_OUT="$WORK/cache/roc/packages/FIXTUREHASH" XDG_CACHE_HOME="$WORK/empty-cache" "$CFW" sync >out 2>err; code=$?
  [ $code = 0 ] && [ "$(cat "$TLN_LOG")" = "path pf --file main.roc" ] && [ -f .roc-cfw/cli.mjs ] && ! has err 'tln' && ok "tln path: directory from tln, alias and --file as arguments, no note" || { bad "tln path: directory from tln (code $code)"; cat err; }
  # tln exits non-zero: the cache rule, one note line with the exit code.
  project p8; cd "$WORK/p8" || exit 1
  TLN_CODE=15 "$CFW" sync >out 2>err; code=$?
  [ $code = 0 ] && has err 'tln path pf exited with 15: used the roc cache rule' && [ "$(grep -c 'used the roc cache rule' err)" = 1 ] && [ -f .roc-cfw/cli.mjs ] && ok "tln path: exit 15, cache rule, one note" || { bad "tln path: exit 15 (code $code)"; cat err; }
  # tln gives a line that is not a directory: the cache rule.
  project p9; cd "$WORK/p9" || exit 1
  TLN_CODE=0 TLN_OUT="/no/such/dir" "$CFW" sync >out 2>err; code=$?
  [ $code = 0 ] && has err 'gave no directory' && ok "tln path: not a directory, cache rule" || { bad "tln path: not a directory (code $code)"; cat err; }
  # tln is not on PATH: the cache rule, the note says so.
  project p10; cd "$WORK/p10" || exit 1
  mkdir -p "$WORK/nodebin"; ln -sf "$(command -v node)" "$WORK/nodebin/node"
  PATH="$WORK/nodebin" "$CFW" sync >out 2>err; code=$?
  [ $code = 0 ] && has err 'tln is not on PATH: used the roc cache rule for pf' && ok "tln path: no tln on PATH, cache rule, note" || { bad "tln path: no tln (code $code)"; cat err; }
  # --file and a path entry: tln gets the file, its directory is used.
  rm -rf "$WORK/p11"; mkdir -p "$WORK/p11/sub"; cd "$WORK/p11" || exit 1
  printf 'app [event!] { web: platform "../../platform/main.roc" }\n\nevent! = |_| crash "x"\n' > sub/web.roc
  rm -f "$TLN_LOG"
  TLN_CODE=0 TLN_OUT="$ROOT/fixtures/platform" "$CFW" sync --file sub/web.roc >out 2>err; code=$?
  [ $code = 0 ] && [ "$(cat "$TLN_LOG")" = "path web --file sub/web.roc" ] && has out 'STUB args=\["sync","--file","sub/web.roc"\]' && ok "tln path: --file and the alias of a path entry" || { bad "tln path: --file (code $code)"; cat out err; }
  # --js: tln is not called.
  rm -f "$TLN_LOG"
  "$CFW" shim --file sub/web.roc --js "$ROOT/fixtures/platform/js" >/dev/null 2>&1; code=$?
  [ $code = 0 ] && [ ! -e "$TLN_LOG" ] && ok "tln path: not called with --js" || bad "tln path: not called with --js (code $code)"
  cd "$WORK" || exit 1

  # An api that this version does not know: exit 2, the message, nothing copied.
  project p2; cd "$WORK/p2" || exit 1
  sed 's/FIXTUREHASH/NEWAPI/' main.roc > main.roc.new && mv main.roc.new main.roc
  "$CFW" sync >out 2>err; code=$?
  [ $code = 2 ] && has err 'update roc-cfw: tln update roc-cfw' && [ ! -e .roc-cfw ] && ok "sync: unknown api, exit 2, no copy" || { bad "sync: unknown api (code $code)"; cat err; }

  # The platform is not in the cache: the fake roc stands for `roc check`, which fetches it (TRANSITION 9 row 1).
  project p3; cd "$WORK/p3" || exit 1
  mkdir -p "$WORK/fakebin" "$WORK/cache3"
  cat > "$WORK/fakebin/roc" <<FAKE
#!/usr/bin/env bash
echo "\$@" >> "$WORK/fakeroc.log"
mkdir -p "$WORK/cache3/roc/packages"
cp -r "$ROOT/fixtures/platform" "$WORK/cache3/roc/packages/FIXTUREHASH"
FAKE
  chmod +x "$WORK/fakebin/roc"
  PATH="$WORK/fakebin:$PATH" XDG_CACHE_HOME="$WORK/cache3" "$CFW" sync >out 2>err; code=$?
  [ $code = 0 ] && [ "$(cat "$WORK/fakeroc.log")" = "check main.roc" ] && [ -f .roc-cfw/cli.mjs ] && ok "sync: platform not in cache, roc check fetches it" || { bad "sync: fetch fallback (code $code)"; cat err; }
  # roc check does not fetch: exit 1 with a message.
  project p4; cd "$WORK/p4" || exit 1
  printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/fakebin/roc"
  PATH="$WORK/fakebin:$PATH" XDG_CACHE_HOME="$WORK/cache4" "$CFW" shim >out 2>err; code=$?
  [ $code = 1 ] && has err 'also after roc check main.roc' && ok "shim: fetch fails, exit 1" || { bad "shim: fetch fails (code $code)"; cat err; }

  # --file and --js: a path platform and a js directory. The copy happens at each run (nothing pins it).
  rm -rf "$WORK/p5"; mkdir -p "$WORK/p5/sub"; cd "$WORK/p5" || exit 1
  printf 'app [event!] { pf: platform "../../platform/main.roc" }\n\nevent! = |_| crash "x"\n' > sub/web.roc
  "$CFW" sync --file sub/web.roc --js "$ROOT/fixtures/platform/js" --exit 0 >out 2>err; code=$?
  [ $code = 0 ] && [ "$(cat .roc-cfw/.platform)" = dev ] && has out 'STUB args=\["sync","--file","sub/web.roc","--exit","0"\]' && ok "sync: --file is passed on once, --js is not" || { bad "sync: --file and --js (code $code)"; cat out err; }
  # A path platform with no --js: the js/ of the platform directory (sub/../../platform/js is not there: exit 1 with a message).
  rm -rf .roc-cfw; "$CFW" shim --file sub/web.roc >out 2>err; code=$?
  [ $code = 1 ] && has err 'no cfw.json in' && ok "shim: path platform with no js/, exit 1" || { bad "shim: path platform (code $code)"; cat err; }

  # init: the stub body of main.roc is replaced, the header stays, wrangler.toml gets the name, [tools] stays, .gitignore is made.
  rm -rf "$WORK/shop"; mkdir -p "$WORK/shop"; cd "$WORK/shop" || exit 1
  cp "$ROOT/fixtures/app-url/talon.toml" .
  printf 'app [event!] {\n\tpf: platform "https://example.com/roc-cloudflare-workers/releases/download/0.2.0/FIXTUREHASH.tar.zst",\n}\n\nimport pf.Worker\n\nevent! = |_| crash "write the app"\n' > main.roc
  "$CFW" init >out 2>err; code=$?
  [ $code = 0 ] && has main.roc 'FIXTUREHASH' && has main.roc 'Worker.answer' && ! has main.roc 'write the app' && ok "init: main.roc body replaced, header kept" || { bad "init: main.roc (code $code)"; cat err main.roc; }
  has wrangler.toml 'name = "shop"' && has wrangler.toml 'database_name = "shop"' && has wrangler.toml 'wrangler d1 create shop' && ok "init: wrangler.toml with the project name" || bad "init: wrangler.toml"
  has talon.toml '^\[tools\]' && has talon.toml '^roc-cfw = ' && has talon.toml '^\[scripts\]' && has talon.toml '^dev = ' && ok "init: [scripts] added, [tools] kept" || { bad "init: talon.toml"; cat talon.toml; }
  [ "$(cat .gitignore)" = "$(printf 'app.wasm\n.roc-cfw/\n.wrangler/')" ] && ok "init: .gitignore" || bad "init: .gitignore"
  # A second init changes nothing and exits 1 (wrangler.toml is there). With wrangler.toml removed: the body is not the stub, exit 1, nothing written.
  cp -r . "$WORK/shop.before"
  "$CFW" init >out 2>err; code=$?
  [ $code = 1 ] && diff -r -x out -x err . "$WORK/shop.before" >/dev/null && ok "init: second run exit 1, no file changed" || bad "init: second run (code $code)"
  rm wrangler.toml
  "$CFW" init >out 2>err; code=$?
  [ $code = 1 ] && has err 'app body already' && [ ! -e wrangler.toml ] && ok "init: body is not the stub, exit 1, nothing written" || { bad "init: not the stub (code $code)"; cat err; }
  # --name that is not a Worker name: exit 2.
  rm -rf "$WORK/p6"; mkdir "$WORK/p6"; cd "$WORK/p6" || exit 1
  printf 'app [event!] {\n\tpf: platform "https://example.com/roc-cloudflare-workers/releases/download/0.2.0/FIXTUREHASH.tar.zst",\n}\n\nevent! = |_| crash "write the app"\n' > main.roc
  "$CFW" init --name 'Bad Name' >out 2>err; code=$?
  [ $code = 2 ] && ok "init: bad --name, exit 2" || bad "init: bad --name (code $code)"
  # init merges talon.toml with roc-toml: [scripts] with a user key, and 2 missing keys. Exit 0, one note line, the user value stays.
  rm -rf "$WORK/p12"; mkdir "$WORK/p12"; cd "$WORK/p12" || exit 1
  printf 'app [event!] {\n\tpf: platform "https://example.com/roc-cloudflare-workers/releases/download/0.2.0/FIXTUREHASH.tar.zst",\n}\n\nevent! = |_| crash "write the app"\n' > main.roc
  printf '[tools]\na = 1\n\n[scripts]\ndev = ["mine"]\n' > talon.toml
  "$CFW" init >out 2>err; code=$?
  [ $code = 0 ] && has talon.toml '^dev = \["mine"\]$' && has talon.toml '^build = ' && has talon.toml '^a = 1$' && has err 'talon.toml: \[scripts\] dev kept (not the template value)' && [ "$(grep -c 'kept (not the template' err)" = 1 ] && ok "init: [scripts] merged, user key kept with a note" || { bad "init: merge (code $code)"; cat err talon.toml; }
  # A talon.toml that does not parse: exit 1, line and column, nothing written.
  rm -rf "$WORK/p13"; mkdir "$WORK/p13"; cd "$WORK/p13" || exit 1
  printf 'app [event!] {\n\tpf: platform "https://example.com/roc-cloudflare-workers/releases/download/0.2.0/FIXTUREHASH.tar.zst",\n}\n\nevent! = |_| crash "write the app"\n' > main.roc
  printf '[tools]\na = \n' > talon.toml
  cp -r . "$WORK/p13.before"
  "$CFW" init >out 2>err; code=$?
  [ $code = 1 ] && has err 'does not parse: line 2, column' && [ ! -e wrangler.toml ] && diff -r -x out -x err . "$WORK/p13.before" >/dev/null && ok "init: talon.toml does not parse, exit 1, nothing written" || { bad "init: bad talon.toml (code $code)"; cat err; }
  # scripts = 1: exit 1, nothing written.
  printf 'scripts = 1\n' > talon.toml; cp talon.toml "$WORK/p13.before/talon.toml"
  "$CFW" init >out 2>err; code=$?
  [ $code = 1 ] && has err 'not a table' && [ ! -e wrangler.toml ] && diff -r -x out -x err . "$WORK/p13.before" >/dev/null && ok "init: scripts is not a table, exit 1, nothing written" || { bad "init: scripts = 1 (code $code)"; cat err; }
  "$CFW" bogus >out 2>err; code=$?
  [ $code = 2 ] && ok "bad command, exit 2" || bad "bad command (code $code)"

  # deploy (docs/deploy.md): a fake wrangler on PATH (fixtures/deploy/wrangler, it never reaches Cloudflare) and a fake Worker
  # (fixtures/deploy/server.mjs on 127.0.0.1) for the smoke checks. The fake wrangler logs each call to WR_LOG.
  mkdir -p "$WORK/wrbin" "$WORK/wrstate"; cp "$ROOT/fixtures/deploy/wrangler" "$WORK/wrbin/wrangler"
  export WR_STATE=$WORK/wrstate WR_LOG=$WORK/wrangler.log
  node "$ROOT/fixtures/deploy/server.mjs" "$WR_STATE" & SERVER=$!
  trap 'kill $SERVER 2>/dev/null' EXIT
  for _ in $(seq 50); do [ -s "$WR_STATE/port" ] && break; sleep 0.1; done
  BASE="http://127.0.0.1:$(cat "$WR_STATE/port")"
  # dproject <name>: a project with a built app.wasm (newer than main.roc), the live version "old", a clean log.
  dproject() {
    project "$1"; cd "$WORK/$1" || exit 1
    touch -d 2026-01-01T00:00:00 main.roc; printf '\0asm' > app.wasm
    echo old > "$WR_STATE/live"; echo '{}' > "$WR_STATE/new.json"; rm -f "$WR_LOG"; touch "$WR_LOG"
    printf '0002_add_index.sql\n' > "$WR_STATE/pending"
  }
  DPATH="$WORK/wrbin:$PATH"
  # The number of lines of a file (macOS wc pads it with spaces).
  lines() { wc -l < "$1" | tr -d ' '; }

  # Success: preflight (sync --check with --file, --wasm), status, upload with the default message, deploy at 100%, smoke ok.
  dproject d1
  PATH=$DPATH "$CFW" deploy --url "$BASE" --smoke /health --smoke-same /data --wait 0 >out 2>err; code=$?
  [ $code = 0 ] && has out 'STUB args=\["sync","--file","main.roc","--wasm","app.wasm","--check"\]' \
    && [ "$(sed -n 1p "$WR_LOG")" = "deployments status --json" ] \
    && sed -n 2p "$WR_LOG" | grep -q '^versions upload --message roc-cfw 0\.0\.3' \
    && sed -n 3p "$WR_LOG" | grep -q '^versions deploy v-new@100% --message roc-cfw 0\.0\.3 .* --yes$' \
    && [ "$(lines "$WR_LOG")" = 3 ] && has out '^smoke ok   GET /health' && has out '^smoke ok   GET /data' && has out '^deploy: done' \
    && has err "rollback command: wrangler rollback v-old --message 'roc-cfw rollback' --yes" && [ "$(cat "$WR_STATE/live")" = new ] \
    && ok "deploy: success, 3 wrangler calls, smoke ok, rollback command printed" || { bad "deploy: success (code $code)"; cat out err "$WR_LOG"; }

  # Preflight failures: no wrangler call. sync --check fails (its exit code passes through), a stale wasm, no wasm.
  dproject d2
  STUB_EXIT=1 PATH=$DPATH "$CFW" deploy >out 2>err; code=$?
  [ $code = 1 ] && [ ! -s "$WR_LOG" ] && has err 'preflight failed (sync --check exit 1). Nothing changed.' && ok "deploy: sync --check fails, exit 1, no wrangler call" || { bad "deploy: sync --check fails (code $code)"; cat err "$WR_LOG"; }
  STUB_EXIT=2 PATH=$DPATH "$CFW" deploy >out 2>err; code=$?
  [ $code = 2 ] && [ ! -s "$WR_LOG" ] && ok "deploy: sync --check exit 2 passes through" || bad "deploy: sync --check exit 2 (code $code)"
  mkdir -p lib; touch lib/Extra.roc
  PATH=$DPATH "$CFW" deploy >out 2>err; code=$?
  [ $code = 1 ] && [ ! -s "$WR_LOG" ] && has err 'app.wasm is older than ./lib/Extra.roc' && ! has out STUB && ok "deploy: stale wasm, exit 1, no sync, no wrangler call" || { bad "deploy: stale wasm (code $code)"; cat err; }
  PATH=$DPATH "$CFW" deploy --wasm app.wasm --dry-run >out 2>err; code=$?
  [ $code = 0 ] && has err 'was given with --wasm' && ok "deploy: --wasm skips the age check" || { bad "deploy: --wasm (code $code)"; cat err; }
  rm -f app.wasm "$WR_LOG"; touch "$WR_LOG"
  PATH=$DPATH "$CFW" deploy >out 2>err; code=$?
  [ $code = 1 ] && [ ! -s "$WR_LOG" ] && has err 'app.wasm is not there' && ok "deploy: no wasm, exit 1, no wrangler call" || { bad "deploy: no wasm (code $code)"; cat err; }

  # Migrations from roc-cfw.toml: after the upload, the pending list, apply, the pending list again (it must be empty), then the deploy.
  # A "n" on stdin does not reach wrangler (stdin is not passed on), so the answer is not a person's: the apply is done.
  dproject d3
  printf '[deploy]\nurl = "%s"\nmigrate = ["DB"]\nwait = 0\n\n[[deploy.smoke]]\npath = "/health"\n' "$BASE" > roc-cfw.toml
  echo n | PATH=$DPATH "$CFW" deploy --message m3 >out 2>err; code=$?
  [ $code = 0 ] && [ "$(cat "$WR_LOG")" = "$(printf 'deployments status --json\nversions upload --message m3\nd1 migrations list DB --remote\nd1 migrations apply DB --remote\nd1 migrations list DB --remote\nversions deploy v-new@100%% --message m3 --yes')" ] \
    && has out '0002_add_index.sql' && has err 'DB: 1 pending migration: 0002_add_index.sql. Migrations are forward-only' && has out '^smoke ok   GET /health' \
    && has out '^  schema:      migrated (forward-only, a rollback does not undo it): DB 0002_add_index.sql' && [ ! -s "$WR_STATE/pending" ] \
    && ok "deploy: upload, then migrations listed, applied with no prompt and verified, then deploy" || { bad "deploy: migrations (code $code)"; cat out err "$WR_LOG"; }

  # The apply applies nothing and exits 0 (as wrangler after a "no"): the check after the apply finds the pending list. Exit 1, no deploy.
  dproject d3b
  WR_APPLY=no PATH=$DPATH "$CFW" deploy --migrate DB --message m3b >out 2>err; code=$?
  [ $code = 1 ] && ! grep -q '^versions deploy' "$WR_LOG" && [ "$(tail -1 "$WR_LOG")" = "d1 migrations list DB --remote" ] \
    && has err 'the migrations of DB were not all applied (wrangler d1 migrations apply exit 0; still pending: 0002_add_index.sql)' \
    && has err 'The live version did not change (v-new is uploaded, not deployed)' && [ "$(cat "$WR_STATE/live")" = old ] \
    && ok "deploy: migrations not applied (exit 0 of apply), exit 1, no deploy" || { bad "deploy: migrations not applied (code $code)"; cat out err "$WR_LOG"; }

  # Two pending, the second fails: exit 1, no deploy, the report names the migration that stays applied.
  dproject d3c
  printf '0002_add_index.sql\n0003_users.sql\n' > "$WR_STATE/pending"
  WR_APPLY=fail PATH=$DPATH "$CFW" deploy --migrate DB >out 2>err; code=$?
  [ $code = 1 ] && ! grep -q '^versions deploy' "$WR_LOG" && has err 'still pending: 0003_users.sql' && has err 'The schema is migrated (forward-only, a rollback does not undo it): DB 0002_add_index.sql' \
    && ok "deploy: a migration fails, exit 1, the applied one is named" || { bad "deploy: migration fails (code $code)"; cat out err "$WR_LOG"; }

  # No pending migration: no apply call.
  dproject d3d
  : > "$WR_STATE/pending"
  PATH=$DPATH "$CFW" deploy --migrate DB --message m >out 2>err; code=$?
  [ $code = 0 ] && ! grep -q 'migrations apply' "$WR_LOG" && has err 'DB: no pending migrations' && ! has out 'schema:' \
    && ok "deploy: no pending migration, no apply" || { bad "deploy: no pending (code $code)"; cat out err "$WR_LOG"; }

  # A smoke check fails after a migration: rollback (exit 3), and the report says that the schema stays migrated.
  dproject d3e
  echo '{"health": 500}' > "$WR_STATE/new.json"
  PATH=$DPATH "$CFW" deploy --migrate DB --url "$BASE" --smoke /health --wait 0 >out 2>err; code=$?
  [ $code = 3 ] && has out 'rolled back to v-old' && has out '^  schema:      migrated (forward-only, a rollback does not undo it): DB 0002_add_index.sql' \
    && ok "deploy: smoke fails after a migration, rollback, the schema line" || { bad "deploy: schema line (code $code)"; cat out err "$WR_LOG"; }

  # A smoke check fails: automatic rollback to the recorded version, exit 3.
  dproject d4
  echo '{"health": 500}' > "$WR_STATE/new.json"
  PATH=$DPATH "$CFW" deploy --url "$BASE" --smoke /health --wait 0 --message m4 >out 2>err; code=$?
  [ $code = 3 ] && [ "$(tail -1 "$WR_LOG")" = "rollback v-old --message roc-cfw: smoke check failed --yes" ] && [ "$(lines "$WR_LOG")" = 4 ] \
    && has out 'smoke FAIL GET /health: status 500, expected 200' && has out 'rolled back to v-old' && [ "$(cat "$WR_STATE/live")" = old ] \
    && ok "deploy: smoke fails, rollback to the old version, exit 3" || { bad "deploy: smoke fails, rollback (code $code)"; cat out err "$WR_LOG"; }

  # The same, with --no-rollback: no rollback call, exit 4, the rollback command in the report.
  dproject d5
  echo '{"health": 503}' > "$WR_STATE/new.json"
  PATH=$DPATH "$CFW" deploy --url "$BASE" --smoke /health --wait 0 --no-rollback >out 2>err; code=$?
  [ $code = 4 ] && ! grep -q '^rollback' "$WR_LOG" && [ "$(lines "$WR_LOG")" = 3 ] && has out 'the rollback is off: the new version stays' \
    && has out "rollback:    wrangler rollback v-old --message 'roc-cfw rollback' --yes" && [ "$(cat "$WR_STATE/live")" = new ] \
    && ok "deploy: smoke fails with --no-rollback, no rollback, exit 4" || { bad "deploy: --no-rollback (code $code)"; cat out err "$WR_LOG"; }

  # The rollback fails: exit 4.
  dproject d5b
  echo '{"health": 500}' > "$WR_STATE/new.json"
  WR_ROLLBACK_CODE=1 PATH=$DPATH "$CFW" deploy --url "$BASE" --smoke /health --wait 0 >out 2>err; code=$?
  [ $code = 4 ] && grep -q '^rollback v-old' "$WR_LOG" && has out 'the rollback failed' && ok "deploy: the rollback fails, exit 4" || { bad "deploy: rollback fails (code $code)"; cat out err; }

  # Dry run: preflight and `wrangler deploy --dry-run` only, with --env and --config passed on.
  dproject d6
  PATH=$DPATH "$CFW" deploy --dry-run --env staging --config wrangler.toml --migrate DB >out 2>err; code=$?
  [ $code = 0 ] && [ "$(cat "$WR_LOG")" = "deploy --dry-run --env staging --config wrangler.toml" ] && has out 'STUB args=\["sync","--file","main.roc","--wasm","app.wasm","--check","--config","wrangler.toml"\]' \
    && has out '^  migrations: DB (pending list and apply after the upload; forward-only)$' && has out '^  env:        staging$' \
    && has out 'dry run passed. Nothing changed.' && ok "deploy: dry run, one wrangler call, no remote change" || { bad "deploy: dry run (code $code)"; cat out err "$WR_LOG"; }

  # Same-body check: the body after the deploy differs from the body before. Rollback, exit 3.
  dproject d7
  echo '{"data": "data-v2"}' > "$WR_STATE/new.json"
  PATH=$DPATH "$CFW" deploy --url "$BASE" --smoke-same /data --wait 0 >out 2>err; code=$?
  [ $code = 3 ] && has out 'smoke FAIL GET /data: the body is not the body before the deploy' && grep -q '^rollback v-old' "$WR_LOG" \
    && ok "deploy: same-body mismatch, rollback, exit 3" || { bad "deploy: same-body mismatch (code $code)"; cat out err "$WR_LOG"; }
  # A same-body check whose before read fails: exit 1 before any change (only the status read).
  dproject d7b
  PATH=$DPATH "$CFW" deploy --url "$BASE" --smoke-same /gone --wait 0 >out 2>err; code=$?
  [ $code = 1 ] && [ "$(cat "$WR_LOG")" = "deployments status --json" ] && has err 'before the deploy, GET /gone gave status 404' && ok "deploy: before read fails, exit 1, nothing changed" || { bad "deploy: before read (code $code)"; cat err "$WR_LOG"; }

  # --env and --config go to each wrangler call. A gradual deploy splits the traffic with the old version.
  dproject d8
  PATH=$DPATH "$CFW" deploy --env staging --config wrangler.toml --percent 10 --migrate DB --message m8 >out 2>err; code=$?
  [ $code = 0 ] && [ "$(grep -vc -- '--env staging --config wrangler.toml$' "$WR_LOG")" = 0 ] && [ "$(lines "$WR_LOG")" = 6 ] \
    && grep -q '^versions deploy v-new@10% v-old@90% --message m8 --yes' "$WR_LOG" && ok "deploy: --env and --config on each call, percent 10" || { bad "deploy: --env/--config/percent (code $code)"; cat err "$WR_LOG"; }

  # No live version: exit 1 after the status call. --first: the status call finds no version, a failed check keeps the new version (exit 4)
  # and the report gives the next commands.
  dproject d9
  WR_LIVE= PATH=$DPATH "$CFW" deploy >out 2>err; code=$?
  [ $code = 1 ] && [ "$(cat "$WR_LOG")" = "deployments status --json" ] && has err 'use --first' && ok "deploy: no live version, exit 1, nothing changed" || { bad "deploy: no live version (code $code)"; cat err; }
  rm -f "$WR_LOG"; touch "$WR_LOG"; echo '{"health": 500}' > "$WR_STATE/new.json"
  WR_LIVE= PATH=$DPATH "$CFW" deploy --first --url "$BASE" --smoke /health --wait 0 --message m9 >out 2>err; code=$?
  [ $code = 4 ] && [ "$(sed -n 2p "$WR_LOG")" = "versions upload --message m9" ] && ! grep -q '^rollback' "$WR_LOG" && has out 'there is no rollback target' \
    && has out 'take the Worker down: wrangler delete$' && ok "deploy: --first, failed check keeps the new version, exit 4, next commands" || { bad "deploy: --first (code $code)"; cat out err "$WR_LOG"; }
  # --first on a Worker with a live version: exit 1 after the status call (the deploy would lose the rollback target).
  rm -f "$WR_LOG"; touch "$WR_LOG"
  PATH=$DPATH "$CFW" deploy --first >out 2>err; code=$?
  [ $code = 1 ] && [ "$(cat "$WR_LOG")" = "deployments status --json" ] && has err '\-\-first, but the Worker has a live version (v-old)' \
    && ok "deploy: --first with a live version, exit 1, nothing changed" || { bad "deploy: --first with a live version (code $code)"; cat err "$WR_LOG"; }

  # A gradual deploy in progress (two live versions): exit 1 after the status call, with the commands that finish it.
  dproject d9b
  WR_SPLIT=1 PATH=$DPATH "$CFW" deploy >out 2>err; code=$?
  [ $code = 1 ] && [ "$(cat "$WR_LOG")" = "deployments status --json" ] && has err 'more than one version (v-old 90%, v-a 10%)' && has err 'only v-a: wrangler versions deploy v-a@100% --yes' \
    && ok "deploy: split live deployment, exit 1, nothing changed" || { bad "deploy: split (code $code)"; cat err "$WR_LOG"; }

  # A same-body check with ignore: /p changes checked.at at each request. Equal when checked is ignored; v differs: rollback.
  dproject d9c
  printf '[deploy]\nurl = "%s"\nwait = 0\n\n[[deploy.smoke]]\npath = "/p"\nsame-body = true\nignore = ["/checked"]\n' "$BASE" > roc-cfw.toml
  PATH=$DPATH "$CFW" deploy --message m >out 2>err; code=$?
  [ $code = 0 ] && has out '^smoke ok   GET /p' && ok "deploy: same-body with ignore, a body that changes by itself passes" || { bad "deploy: ignore passes (code $code)"; cat out err; }
  echo old > "$WR_STATE/live"; echo '{"p": "2"}' > "$WR_STATE/new.json"
  PATH=$DPATH "$CFW" deploy --message m >out 2>err; code=$?
  [ $code = 3 ] && has out 'smoke FAIL GET /p: the body is not the body before the deploy: it differs at /v' && ok "deploy: same-body with ignore, another difference fails" || { bad "deploy: ignore fails (code $code)"; cat out err; }
  # An ignore list on a body that is not JSON: exit 1 before any change.
  printf '[deploy]\nurl = "%s"\n\n[[deploy.smoke]]\npath = "/data"\nsame-body = true\nignore = ["/x"]\n' "$BASE" > roc-cfw.toml
  echo old > "$WR_STATE/live"; rm -f "$WR_LOG"; touch "$WR_LOG"
  PATH=$DPATH "$CFW" deploy >out 2>err; code=$?
  [ $code = 1 ] && [ "$(cat "$WR_LOG")" = "deployments status --json" ] && has err 'GET /data: the body is not JSON, and the check has an ignore list' \
    && ok "deploy: ignore on a body that is not JSON, exit 1, nothing changed" || { bad "deploy: ignore not JSON (code $code)"; cat err "$WR_LOG"; }
  # --env with a url of [deploy] only: exit 2, nothing runs.
  printf '[deploy]\nurl = "%s"\n\n[[deploy.smoke]]\npath = "/health"\n' "$BASE" > roc-cfw.toml
  rm -f "$WR_LOG"; touch "$WR_LOG"
  PATH=$DPATH "$CFW" deploy --env staging >out 2>err; code=$?
  [ $code = 2 ] && [ ! -s "$WR_LOG" ] && has err 'Set url in \[deploy.env.staging\]' && ok "deploy: --env and only the url of [deploy], exit 2" || { bad "deploy: --env url (code $code)"; cat err; }
  # [deploy.env.staging] gives the url: the checks use it.
  printf '[deploy]\nurl = "https://wrong.invalid"\nwait = 0\n\n[[deploy.smoke]]\npath = "/health"\n\n[deploy.env.staging]\nurl = "%s"\n' "$BASE" > roc-cfw.toml
  PATH=$DPATH "$CFW" deploy --env staging --message m >out 2>err; code=$?
  [ $code = 0 ] && has out '^smoke ok   GET /health' && ok "deploy: [deploy.env.staging] url" || { bad "deploy: env url (code $code)"; cat out err; }
  rm roc-cfw.toml

  # The HTTP time limit: /slow answers after 3 s; --timeout 1 fails each try (rollback, exit 3).
  dproject d9d
  PATH=$DPATH "$CFW" deploy --url "$BASE" --smoke /slow --wait 0 --timeout 1 >out 2>err; code=$?
  [ $code = 3 ] && has out 'smoke FAIL GET /slow: no answer' && ok "deploy: --timeout 1 on a slow answer fails" || { bad "deploy: --timeout (code $code)"; cat out err; }
  # A before read tries 3 times: /flaky gives 503 once, then 200.
  dproject d9e
  PATH=$DPATH "$CFW" deploy --url "$BASE" --smoke-same /flaky --wait 0 --message m >out 2>err; code=$?
  [ $code = 0 ] && has out '^smoke ok   GET /flaky' && ok "deploy: the before read tries again after a 503" || { bad "deploy: before read retry (code $code)"; cat out err; }

  # Upload with no version id: exit 1, no deploy call.
  dproject d10
  WR_NEW=none PATH=$DPATH "$CFW" deploy >out 2>err; code=$?
  [ $code = 1 ] && [ "$(lines "$WR_LOG")" = 2 ] && has err 'no "Worker Version ID:" line' && ok "deploy: no version id from the upload, exit 1, no deploy call" || { bad "deploy: no version id (code $code)"; cat err "$WR_LOG"; }

  # Bad settings: exit 2, nothing runs. A typo in roc-cfw.toml, an unknown flag, checks with no URL.
  dproject d11
  printf '[[deploy.smoke]]\npath = "/"\nsame_body = true\n' > roc-cfw.toml
  PATH=$DPATH "$CFW" deploy >out 2>err; code=$?
  [ $code = 2 ] && [ ! -s "$WR_LOG" ] && ! has out STUB && has err 'unknown key deploy.smoke same_body' && ok "deploy: typo in roc-cfw.toml, exit 2, nothing runs" || { bad "deploy: bad roc-cfw.toml (code $code)"; cat err; }
  rm roc-cfw.toml
  PATH=$DPATH "$CFW" deploy --smoke / >out 2>err; code=$?
  [ $code = 2 ] && has err 'need a base URL' && ok "deploy: checks with no URL, exit 2" || bad "deploy: no URL (code $code)"
  PATH=$DPATH "$CFW" deploy --bogus >out 2>err; code=$?
  [ $code = 2 ] && [ ! -s "$WR_LOG" ] && ok "deploy: unknown flag, exit 2" || bad "deploy: unknown flag (code $code)"
  # No wrangler on PATH: exit 2 at the first wrangler call (still before any change).
  PATH="$WORK/nodebin:$WORK/tlnbin" "$CFW" deploy >out 2>err; code=$?
  [ $code = 2 ] && has err 'cannot start wrangler' && ok "deploy: no wrangler, exit 2" || { bad "deploy: no wrangler (code $code)"; cat err; }
  cd "$WORK" || exit 1

  # The real js/ of the platform repository (read only): the copy, then `cli.mjs sync` on a built example. Skipped when the repository is not there.
  # The wasm is the prebuilt hello.wasm of the platform repository (its test-bundle cache), since the build of the platform needs its zig chain.
  # The path platform of examples/hello is not used: --js gives the directory.
  REAL=${PLATFORM_REPO:-$ROOT/../talon/cloudflare-workers}
  if [ -f "$REAL/js/cfw.json" ] && [ -f "$REAL/examples/hello/main.roc" ]; then
    rm -rf "$WORK/real"; mkdir -p "$WORK/real"; cd "$WORK/real" || exit 1
    cp "$REAL/examples/hello/main.roc" "$REAL/examples/hello/wrangler.toml" .
    if [ -f "$REAL/.cache/test-bundle/hello.wasm" ]; then
      cp "$REAL/.cache/test-bundle/hello.wasm" app.wasm
      "$CFW" sync --js "$REAL/js" >out 2>err; code=$?
      [ $code = 0 ] && has worker.js "from './.roc-cfw/index.js'" && [ -f .roc-cfw/cli.mjs ] && [ -f .roc-cfw/package.json ] && ok "real js/: sync writes worker.js with the .roc-cfw import" || { bad "real js/: sync (code $code)"; cat out err; }
      "$CFW" sync --js "$REAL/js" --check >out 2>err; code=$?
      [ $code = 0 ] && has out 'up to date' && ok "real js/: sync --check passes after sync" || { bad "real js/: sync --check (code $code)"; cat out err; }
      echo '// edited' >> worker.js
      "$CFW" sync --js "$REAL/js" --check >out 2>err; code=$?
      [ $code = 1 ] && ok "real js/: sync --check exit 1 for a changed worker.js" || bad "real js/: sync --check on a change (code $code)"
    else
      echo "skip real js/ sync: no $REAL/.cache/test-bundle/hello.wasm"
    fi
    # A missing wasm: exit 2 of cli.mjs passes through (this part needs no wasm).
    rm -rf .roc-cfw app.wasm
    "$CFW" sync --js "$REAL/js" >out 2>err; code=$?
    [ $code = 2 ] && ok "real js/: no wasm, exit 2 of cli.mjs passes through" || bad "real js/: no wasm (code $code)"
    # init with the real template: the stub body of a main.roc is replaced.
    rm -rf "$WORK/real-init"; mkdir -p "$WORK/real-init/my-worker"; cd "$WORK/real-init/my-worker" || exit 1
    printf '[tools]\nroc-cfw = { ref = "o/cli@^1", url = "https://x/1.0.3/H.tar.zst" }\n' > talon.toml
    printf 'app [event!] {\n\tpf: platform "https://example.com/roc-cloudflare-workers/releases/download/0.2.0/FIXTUREHASH.tar.zst",\n}\n\nimport pf.Worker\n\nevent! = |_| crash "write the app"\n' > main.roc
    "$CFW" init --js "$REAL/js" >out 2>err; code=$?
    [ $code = 0 ] && has main.roc 'FIXTUREHASH' && has main.roc 'worker = Worker.new' && ! has main.roc 'write the app' && ! has main.roc '^app \[event!\].*roc-hello' && ok "real template: init, main.roc" || { bad "real template: init main.roc (code $code)"; cat err; }
    [ "$(grep -c 'my-worker' wrangler.toml)" = 3 ] && ! has wrangler.toml roc-hello && has talon.toml '^\[tools\]' && has talon.toml '^deploy = ' && ! has talon.toml 'The \[scripts\] table that' && ok "real template: init, wrangler.toml name on 3 lines, talon.toml" || { bad "real template: init wrangler/talon"; cat wrangler.toml talon.toml; }
  else
    echo "skip real js/ runs: no platform repository at $REAL"
  fi
fi

echo
if [ $FAILS = 0 ]; then echo "all passed"; else echo "$FAILS failed"; exit 1; fi
