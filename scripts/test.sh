#!/usr/bin/env bash
# The tests of roc-cfw. Step 1: roc check, roc fmt --check, roc test (the pure decisions in lib/).
# Step 2: build roc-cfw and run it on the fixtures in fixtures/ (a fake platform package, a stub cli.mjs, a template).
# The step 2 runs need node. A fake `roc` on PATH stands for the fetch of `roc check`. A fake `tln` on PATH stands for `tln path`
# (Talon R-PTH1), so the tests do not depend on the Talon cache. Its answer is set by TLN_OUT and TLN_CODE, its calls go to TLN_LOG.
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
