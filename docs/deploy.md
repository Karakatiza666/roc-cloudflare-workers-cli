# roc-cfw deploy

`roc-cfw deploy` deploys a Worker that is made with the platform. It is general: it knows no app. It runs the checks before the deploy, records the live version (the rollback target), uploads and deploys a new version with `wrangler`, reads the smoke checks, and rolls back when a check fails.

## Command

```text
roc-cfw deploy [--file main.roc] [--js <dir>] [--wasm <file>] [--config <wrangler config>] [--env <name>]
               [--message <text>] [--percent <1-100>] [--migrate <D1 binding>]...
               [--url <base URL>] [--smoke <path>[=<status>]]... [--smoke-same <path>[=<status>]]...
               [--wait <seconds>] [--no-rollback] [--first] [--dry-run]
```

| Flag | Default | Does |
| --- | --- | --- |
| `--file <app.roc>` | `main.roc` | The app file (as `sync`) |
| `--js <dir>` | the platform `js/` | As `sync` |
| `--wasm <file>` | `app.wasm` | The built app. With `--wasm`, the age check is not done (you gave the file). |
| `--config <file>` | wrangler finds it | Passed to `sync --check` and to each `wrangler` command |
| `--env <name>` | none | Passed to each `wrangler` command as `--env <name>` |
| `--message <text>` | `roc-cfw <version> <commit>` (`-dirty` when the tree has changes; no commit when there is no git) | The message of the upload and of the deploy |
| `--percent <n>` | 100 | The traffic of the new version. Below 100: `new@n% old@(100-n)%` (a gradual deploy) |
| `--migrate <binding>` | none | Apply the D1 migrations of this binding before the upload. You can give it more than once. |
| `--url <base>` | none | The base URL of the smoke checks (`https://...`) |
| `--smoke <path>[=<status>]` | status 200 | A `GET <base><path>` after the deploy must give the status |
| `--smoke-same <path>[=<status>]` | status 200 | As `--smoke`, and the body must be equal to the body before the deploy |
| `--wait <seconds>` | 5 | The time before the first smoke try, and between tries (3 tries) |
| `--no-rollback` | rollback on | Do not roll back when a smoke check fails |
| `--first` | off | The first deploy of the Worker: there is no live version, so there is no rollback target |
| `--dry-run` | off | Preflight and `wrangler deploy --dry-run` only. No remote read and no remote change. |

## Config file: roc-cfw.toml

The smoke checks are a list, so a file is easier than flags. The file is `roc-cfw.toml` in the current directory (the directory of `.roc-cfw/`). It is optional.

```toml
[deploy]
url = "https://my-app.my-account.workers.dev"
migrate = ["DB"]
percent = 100
rollback = true
wait = 5

[[deploy.smoke]]
path = "/"
status = 200

[[deploy.smoke]]
path = "/v1/index.json"
same-body = true
```

| Key | Type | Flag |
| --- | --- | --- |
| `url` | string | `--url` replaces it |
| `migrate` | array of strings | `--migrate` adds to it |
| `percent` | integer 1 to 100 | `--percent` replaces it |
| `rollback` | boolean | `--no-rollback` sets false |
| `wait` | integer, seconds | `--wait` replaces it |
| `smoke` | array of tables: `path` (string, starts with `/`), `status` (integer, default 200), `same-body` (boolean, default false) | `--smoke` and `--smoke-same` add to it |

An unknown key, or a value of the wrong type, stops the command with exit 2. A typo (for example `same_body`) must not make a check weaker with no message.

Why this file, and not another place:

| Place | Why not |
| --- | --- |
| Wrangler `vars` | They go to the Worker as environment values. A deploy setting is not an app value. |
| A `[deploy]` table in `talon.toml` | Talon gives a warning for each unknown table at each run (Talon R-TF4). Also, a project can use `roc-cfw` with no Talon. |
| Flags in the `deploy` script of `talon.toml` | This works too: all keys have a flag. Use flags for 1 or 2 checks, and the file for more. |

## Steps

```text
1 preflight (local only)
    app.wasm is there; it is not older than a .roc file under the app directory (not with --wasm)
    shim, then: node .roc-cfw/cli.mjs sync --check --file <app> --wasm <wasm> [--config <c>]
      (shim hash, manifest against the wrangler config, bindings, crons, nightly range)
    a failure: stop. No wrangler command ran.
--dry-run: print the plan, run `wrangler deploy --dry-run [--env] [--config]`, stop.
2 live version: wrangler deployments status --json -> the version with the most traffic. Print it and the rollback command.
    (--first: no read, no target)
3 before reads: GET of each --smoke-same path. It must give the status, else stop (nothing changed).
4 migrations: for each binding: wrangler d1 migrations list <b> --remote (the pending list), then apply <b> --remote
5 upload: wrangler versions upload --message <m>  -> "Worker Version ID: <id>"
6 deploy: wrangler versions deploy <new>@<p>% [<old>@<100-p>%] --message <m> --yes
7 smoke: wait, then each check (3 tries, <wait> seconds apart)
8 a check fails: wrangler rollback <old> --message "roc-cfw: smoke check failed" --yes (not with --no-rollback or --first)
```

Each `wrangler` command gets `--env <name>` and `--config <file>` when you give them. The output of wrangler goes to the terminal. The rollback command is printed after step 2 and in the last report.

The migrations do not roll back. A rollback after a migration puts the old code on the new schema. Write migrations that the old code can use.

`wrangler d1 migrations apply` asks for a yes on a terminal. In CI (no terminal) wrangler uses yes.

## Exit codes

The codes 0, 1 and 2 have the meaning that they have for `sync`.

| Code | When | State of the Worker |
| --- | --- | --- |
| 0 | All steps passed (or the dry run passed) | The new version is live |
| 1 | A failure before the new version got traffic: preflight, the live version read, a before read, a migration, the upload, the deploy command | The old version is live (applied migrations stay). After a failed `versions deploy`, check it with the printed rollback command. |
| 2 | A bad command line or `roc-cfw.toml`, a tool (`node`, `wrangler`) that does not start, an api of the platform that this version does not know | No change |
| 3 | A smoke check failed, and the rollback passed | The old version is live |
| 4 | A smoke check failed, and there was no rollback (`--no-rollback`, `--first`, or the rollback failed) | The new version is live |
| n | The exit code of `sync --check` (1 or 2), as `sync` | No change |

## What deploy does not do

| Item | Why |
| --- | --- |
| Log tail, dead-letter queue checks, app tests | They are specific to an app. Put them in the `deploy` script of `talon.toml`, before or after `roc-cfw deploy`. |
| An `--after <cmd>` hook | A script step after `roc-cfw deploy` does the same. A hook that can roll back would need a contract for the exit code of the hook. |
| `--json` | `sync`, `shim` and `init` have no JSON output. |
| Methods other than `GET` in a smoke check | A smoke check must not change data. |

## The template script

```toml
deploy = ["@check", "roc-cfw deploy"]
```

`@check` builds `app.wasm`. `roc-cfw deploy` checks it again (this is fast) and deploys it.
