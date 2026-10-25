# roc-cfw

`roc-cfw` is the helper CLI of the Roc platform for Cloudflare Workers (`Karakatiza666/roc-cloudflare-workers`). It is a Roc app on basic-cli. It is step 4 of `talon/cloudflare-workers/research/talon-fit/TRANSITION.md`. This README is the contract. The study is `talon/research/talon-scripts/README.md`, sections 6 and 8.

The version-specific JS (the shim, `cli.mjs sync`, the template) is in `js/` of the platform bundle. `roc-cfw` copies it to `.roc-cfw/` and runs it. The header hash of your app pins the JS, so one `roc-cfw` release serves many platform releases.

## Commands

| Command | Does |
| --- | --- |
| `roc-cfw shim [--file main.roc] [--js <dir>]` | Finds `js/` of the platform of the app. Checks `js/cfw.json`. Copies `js/` to `.roc-cfw/` when the stamp is not the platform hash. Runs no node. |
| `roc-cfw sync [--file main.roc] [--js <dir>] [sync args]` | `shim`, then `node .roc-cfw/cli.mjs sync [sync args]`. The exit code of node is the exit code. The flags `--file` and `--js` are not passed on. |
| `roc-cfw init [--file main.roc] [--js <dir>] [--name <name>]` | Writes the template of the platform (see "init"). |
| `roc-cfw help` | Prints the usage. |

The directory for `.roc-cfw/` is the current directory. The files of `init` are in the directory of the app file.

## Exit codes

| Code | When |
| --- | --- |
| 0 | Good |
| 1 | A failure: a platform that is not in the cache after `roc check`, no or bad `js/cfw.json`, no `template/` file, a file that `init` would write over, a copy that failed |
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
  |       release URL: $XDG_CACHE_HOME/roc/packages/<hash>/  (else ~/.cache/roc/packages/<hash>/)
  |                    missing? run: roc check <app file>, then look again
  |       path entry:  the directory of the platform file
  v
dir/cfw.json: api in the supported list?  --no--> exit 2: "update roc-cfw: tln update roc-cfw"
  |
  v
.roc-cfw/.platform == the platform hash? --no--> copy dir to a temp dir, write .platform, rename to .roc-cfw
  |
  v
sync only: node .roc-cfw/cli.mjs sync [sync args]
```

The stamp pins the files only for a release URL. With `--js`, or with a platform path entry, nothing pins the files: the copy happens at each run and `.platform` holds `dev`.

`platform_dir!` in `main.roc` is the one place that finds the platform directory. It is the fallback of TRANSITION 9 row 1, until `tln path pf` exists (Talon R-PTH1). Then only the body of this function changes.

## The contract with the platform bundle

| Item | Rule |
| --- | --- |
| `js/cfw.json` | `{ "api": N }`. This version supports `api` 1. A new `api` needs a new `roc-cfw` release. |
| `js/cli.mjs` | Run as `node .roc-cfw/cli.mjs sync [args]` in the current directory. |
| `js/template/` | `main.roc`, `wrangler.toml`, `talon.toml`, `.gitignore` (for `init`). |

## init

Run it after `tln init --platform ...` and `tln add --tool ...`. `init` makes all new texts first. When one file cannot be made, it writes nothing.

| File | Rule |
| --- | --- |
| `main.roc` | The header of the file stays. The template (a body with no header) goes after it, with one blank line. Only a stub body is replaced: empty, or with `crash "write the app"` (Talon R-IN8). |
| `wrangler.toml` | The template, with the project name where the template name stands (in quotes, and after `wrangler d1 create`). The name is `--name`, else the name of the directory, lower case. A file that is there gives exit 1. |
| `talon.toml` | The `[scripts]` table of the template is added at the end. `[tools]` and all other bytes stay. A file that has `[scripts]` gives exit 1. |
| `.gitignore` | Each line of the template that the file does not have is added. |

## Tests

`scripts/test.sh [unit|e2e]`.

| Layer | Files | Checks |
| --- | --- | --- |
| unit | `tests/*.roc`, run with `roc check`, `roc fmt --check`, `roc test` | The pure decisions of `lib/`: the command line, the platform entry, the cache path, the api check, the stamp rule, the 4 template merges |
| e2e | `fixtures/`: a fake platform package (`js/cfw.json`, a stub `cli.mjs`, a template), an app with a release URL, a fake `roc` | The built `roc-cfw`: copy, stamp, arguments, exit code, unknown api, fetch fallback, `--file`, `--js`, `init` |

Use the pinned compiler: `ROC=<path>` (default: the nightly in `.roc-version`, found in the Talon repository). Build with `roc build --no-cache --output=roc-cfw main.roc`.

## Files

| Path | Holds |
| --- | --- |
| `main.roc` | The app: the effects (files, `node`, `roc check`) and the order of the steps |
| `lib/` | The pure decisions: `Args`, `Cfw`, `Platform`, `Scaffold`. They use `roc-app-header` 0.1.0 by release URL. |

## Release

An app bundle (`roc bundle`), so that Talon builds it from the locked `url` of `[tools]`. Not done here.
