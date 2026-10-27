# roc-cfw

`roc-cfw` is the helper CLI of the Roc platform for Cloudflare Workers (`Karakatiza666/roc-cloudflare-workers`). It is a Roc app on basic-cli 0.26.0. It is step 4 of `talon/cloudflare-workers/research/talon-fit/TRANSITION.md`. This README is the contract. The study is `talon/research/talon-scripts/README.md`, sections 6 and 8.

The version-specific JS (the shim, `cli.mjs sync`, the template) is in `js/` of the platform bundle. `roc-cfw` copies it to `.roc-cfw/` and runs it. The header hash of your app pins the JS, so one `roc-cfw` release serves many platform releases.

## Use with Talon

| Step | Command | Result |
| --- | --- | --- |
| 1 | `tln init --platform Karakatiza666/roc-cloudflare-workers` | A project with the platform in the header of `main.roc` (a stub body) |
| 2 | `tln add --tool Karakatiza666/roc-cloudflare-workers-cli --as roc-cfw` | Talon builds `roc-cfw` from the app bundle of the newest release. It writes the `[tools]` entry (`ref` and `url`) in `talon.toml`. |
| 3 | `tln x roc-cfw -- init` | `init`: the template of the platform (`main.roc`, `wrangler.toml`, `talon.toml`, `.gitignore`) |
| 4 | `tln run build` | The `build` script of `talon.toml`: `roc build`, then `roc-cfw sync` |

The default key of a tool is the name of the repository (`roc-cloudflare-workers-cli`). The flag `--as roc-cfw` sets the key `roc-cfw`, which the template scripts use. The `url` in `[tools]` pins the release of the helper for the project. `tln update roc-cfw` moves it.

## Commands

| Command | Does |
| --- | --- |
| `roc-cfw shim [--file main.roc] [--js <dir>]` | Finds `js/` of the platform of the app. Checks `js/cfw.json`. Copies `js/` to `.roc-cfw/` when the stamp is not the platform hash. Runs no node. |
| `roc-cfw sync [--file main.roc] [--js <dir>] [sync args]` | `shim`, then `node .roc-cfw/cli.mjs sync --file <app file> [sync args]`. The exit code of node is the exit code. The flag `--js` is not passed on. The flag `--file` is passed on (see below). |
| `roc-cfw init [--file main.roc] [--js <dir>] [--name <name>]` | Writes the template of the platform (see "init"). |
| `roc-cfw help` | Prints the usage. |

The directory for `.roc-cfw/` is the current directory. The files of `init` are in the directory of the app file.

## Exit codes

| Code | When |
| --- | --- |
| 0 | Good |
| 1 | A failure: a platform that is not in the cache after `roc check`, no or bad `js/cfw.json`, no `template/` file, a file that `init` would write over, a `talon.toml` that does not parse (the line and column are in the message), a `talon.toml` with a `scripts` key that is not a table, a copy that failed |
| 2 | A bad command line, no app file, no platform entry, a URL that is not a release URL, an `api` that this version does not know, node that does not start |
| n | `sync`: the exit code of `cli.mjs` (0 good, 1 a part is missing or wrong, 2 a bad command line or no app) |

## Flow of shim and sync

```text
read the header of the app file -> the platform entry
  |
  v
--js given? --yes--> dir = <dir>
  | no
  v
dir = platform_dir() + "/js"
  |   1. tln on PATH?  run: tln path <alias> --file <app file>   (alias = the key of the platform entry, for example pf)
  |        exit 0 and one line that is an existing directory --> that directory (Talon fetches a missing package)
  |   2. else (no tln, a non-zero exit, no directory): the cache rule, and one note line on stderr that says why
  |        release URL: $XDG_CACHE_HOME/roc/packages/<hash>/  (else ~/.cache/roc/packages/<hash>/)
  |                     missing? run: roc check <app file>, then look again
  |        path entry:  the directory of the platform file
  v
dir/cfw.json: api in the supported list?  --no--> exit 2: "update roc-cfw: tln update roc-cfw"
  |
  v
.roc-cfw/.platform == the platform hash? --no--> copy dir to a temp dir, write .platform, rename to .roc-cfw
  |
  v
sync only: node .roc-cfw/cli.mjs sync --file <app file> [sync args]
```

The stamp pins the files only for a release URL. With `--js`, or with a platform path entry, nothing pins the files: the copy happens at each run and `.platform` holds `dev`.

`platform_dir!` in `main.roc` is the one place that finds the platform directory. It asks Talon first: `tln path <alias> --file <app file>` (Talon R-PTH1: one line on stdout, the absolute directory, a missing package is fetched). The cache rule is the fallback of TRANSITION 9 row 1.

| Case | Result | Note line on stderr |
| --- | --- | --- |
| `tln` gives exit 0 and a directory | That directory | None |
| `tln` is not on PATH | The cache rule | `tln is not on PATH: used the roc cache rule for <alias>` |
| `tln path` gives a non-zero exit (for example 2 or 15, R-PTH2, R-PTH3) | The cache rule | `tln path <alias> exited with <code>: used the roc cache rule` |
| `tln path` gives exit 0 and no existing directory | The cache rule | `tln path <alias> gave no directory: used the roc cache rule` |

The error text of `tln` goes to the terminal as it is.

## The `--file` argument of sync

`cli.mjs sync` reads the app source with `--file`. It warns of a handler that is defined but not listed in `Worker.new` (exit 0 with a warning, exit 1 with `--check`). `Args.sync_args` decides the arguments.

| Case | Arguments after `sync` |
| --- | --- |
| `--file X` given, X is there | `--file X`, then the sync args in order |
| No `--file`, `main.roc` is there | `--file main.roc`, then the sync args in order |
| The app file is not there | The sync args only (`shim` has failed before this, so this case is a guard) |

The flag `--file` is passed once. The flag `--js` is never passed. The copy of `shim` replaces only `.roc-cfw/`. The file `worker.options.js` is next to the entry file, so `shim` does not touch it, and `roc-cfw` writes no options file.

An explicit `--file` in a `sync` run also sets the app for the platform header. With no `--file`, `cli.mjs` would find `<wasm name>.roc` next to the wasm file. `roc-cfw` passes `main.roc` in this case. Give `--file` for an app with another name.

## The contract with the platform bundle

| Item | Rule |
| --- | --- |
| `js/cfw.json` | `{ "api": N }`. This version supports `api` 1. A new `api` needs a new `roc-cfw` release. |
| `js/cli.mjs` | Run as `node .roc-cfw/cli.mjs sync --file <app file> [args]` in the current directory. |
| `js/template/` | `main.roc`, `wrangler.toml`, `talon.toml`, `.gitignore` (for `init`). |

## init

Run it after `tln init --platform ...` and `tln add --tool ...`. `init` makes all new texts first. When one file cannot be made, it writes nothing.

| File | Rule |
| --- | --- |
| `main.roc` | The header of the file stays. The template (a body with no header) goes after it, with one blank line. Only a stub body is replaced: empty, or with `crash "write the app"` (Talon R-IN8). |
| `wrangler.toml` | The template, with the project name where the template name stands (in quotes, and after `wrangler d1 create`). The name is `--name`, else the name of the directory, lower case. A file that is there gives exit 1. |
| `talon.toml` | Merged with roc-toml. See the table below. |
| `.gitignore` | Each line of the template that the file does not have is added. |

The merge of `talon.toml` takes each key of the `[scripts]` table of the template, in the order of the template text:

| State | Result |
| --- | --- |
| No file | The `[scripts]` table of the template, as it is |
| The file does not parse | Exit 1 with the line and column. No file is written. |
| `scripts` is not a table (`scripts = 1`) | Exit 1. No file is written. |
| The key is missing | `Toml.insert` adds it. A `[scripts]` table is made at the end when there is none. All other bytes stay: `[tools]`, comments, the line end (LF or CRLF). |
| The key has the template value | No change |
| The key has another value | The value of the user stays. One note line on stderr: `talon.toml: [scripts] <key> kept (not the template value)`. Exit 0. |

## Tests

`scripts/test.sh [unit|e2e]`.

| Layer | Files | Checks |
| --- | --- | --- |
| unit | `tests/*.roc`, run with `roc check`, `roc fmt --check`, `roc test` | The pure decisions of `lib/`: the command line, the platform entry and alias, the `tln path` arguments and output, the cache path, the api check, the stamp rule, the 4 template merges |
| e2e | `fixtures/`: a fake platform package (`js/cfw.json`, a stub `cli.mjs`, a template), an app with a release URL, a fake `roc`, a fake `tln` | The built `roc-cfw`: copy, stamp, arguments, exit code, unknown api, `tln path` and the fallbacks, `--file`, `--js`, `init` and the `talon.toml` merge |
| platform | `scripts/test_platform.sh [<platform repo dir>]` | The real JS of the platform repository, with no release and no deploy (see below) |

Use the pinned compiler (the nightly in `.roc-version`). `scripts/get-roc.sh` finds it, in this order:

| Order | Source |
| --- | --- |
| 1 | `ROC=<path>` in the environment |
| 2 | `.cache/nightlies/<tag>/roc` (an earlier install) |
| 3 | `roc` on `PATH`, when `roc version` has the tag |
| 4 | A download from `roc-lang/nightlies` into `.cache/nightlies/<tag>/` (with `gh`, the sha256 is checked; else with `curl`) |

Build with `roc build --no-cache --output=roc-cfw main.roc`. The e2e layer runs `bash` and `node`. The step `scripts/test.sh build` only builds and runs `roc-cfw help`.

### test_platform.sh

`scripts/test_platform.sh [<platform repo dir>]` (default: `$PLATFORM_REPO`, else `../talon/cloudflare-workers`) makes a project in `.work/platform/` and checks the platform JS on disk:

| Step | Check |
| --- | --- |
| 1 | `main.roc` with the stub body `crash "write the app"`, a relative platform path entry to `<repo>/platform/main.roc`, and a `talon.toml` with `[tools]` only |
| 2 | `roc-cfw init --js <repo>/js` writes the 4 files, and `[tools]` stays |
| 3 | `roc build --target=wasm32` with the nightly of `<repo>/compat/last-stack-first-nightly` gives `app.wasm` |
| 4 | `roc-cfw sync --js <repo>/js`, then `sync --check` (exit 0). `worker.js` imports `./.roc-cfw/index.js`. `.roc-cfw/cli.mjs` is there. |
| 5 | When `wrangler` is on PATH: `wrangler dev --local` on a free port, `GET /` gives 200, stop. It never runs `wrangler deploy`. |

## Files

| Path | Holds |
| --- | --- |
| `main.roc` | The app: the effects (files, `node`, `roc check`) and the order of the steps |
| `lib/` | The pure decisions: `Args`, `Cfw`, `Platform`, `Scaffold`. They use `roc-app-header` 0.1.0 and `roc-toml` 0.1.0 by release URL. |
| `scripts/` | `test.sh` (unit, build and e2e), `test_platform.sh` (the real platform JS), `get-roc.sh` (the pinned compiler), `bundle.sh` (the app bundle), `test_bundle.sh` (unbundle, build and run the bundle) |
| `.github/workflows/` | `ci.yml` (tests), `release.yml` (the release on a tag) |
| `.github/release-notes.md` | The text of the notes of a release |

## CI

`.github/workflows/ci.yml` runs on each push and pull request. The compiler is the nightly of `.roc-version`.

| System | Steps |
| --- | --- |
| Linux, macOS | `scripts/test.sh` (unit and e2e), then the bundle check |
| Windows | `scripts/test.sh unit`, `scripts/test.sh build`, then the bundle check. The e2e layer does not run: its fake `roc` and `tln` are bash scripts. |

The bundle check is `scripts/bundle.sh` and `scripts/test_bundle.sh`. Basic-cli 0.26.0 makes the Windows link possible (the Windows C runtime inputs).

## Release

A release is an app bundle (`roc bundle`). Talon builds it from the locked `url` of `[tools]` (Talon R-T10, R-PT6). The header of `main.roc` has the pin `roc: "<nightly>"`, which Talon needs (R-T29). It must equal `.roc-version`: `scripts/bundle.sh` checks this.

| Step | Who | Action |
| --- | --- | --- |
| 1 | You | Make sure that CI is green on `main`. |
| 2 | You | `git tag X.Y.Z && git push origin X.Y.Z` (the tag is `X.Y.Z` with no `v`; `X.Y.Z-pre` makes a prerelease; not `0.0.0`) |
| 3 | `release.yml` | Run `ci.yml` (all tests on 3 systems). |
| 4 | `release.yml` | `scripts/bundle.sh`: `roc bundle main.roc lib/*.roc` gives `<hash>.tar.zst`. `scripts/test_bundle.sh` unbundles it and builds it. |
| 5 | `release.yml` | `gh release create` with that one asset and the notes of `.github/release-notes.md`. |
| 6 | `release.yml` | `test-published`: download the bundle from the release URL, unbundle, build. |

The release has exactly one `<hash>.tar.zst` asset (Talon R-DI4). Do not add another asset by hand.

Check a bundle on your machine:

```text
scripts/bundle.sh dist                 # prints asset: and name:
scripts/test_bundle.sh dist/<hash>.tar.zst
```

A change of the `api` of the platform contract needs a new release (see "The contract with the platform bundle").

## License

UPL-1.0, see `LICENSE`.
