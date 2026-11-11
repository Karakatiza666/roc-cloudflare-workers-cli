# roc-cfw deploy

`roc-cfw deploy` deploys a Worker that is made with the platform. It is general: it knows no app. It runs the checks before the deploy, records the live version (the rollback target), uploads a new version, applies the D1 migrations that you name, deploys the new version with `wrangler`, reads the smoke checks, and rolls back when a check fails.

## Command

```text
roc-cfw deploy [--file main.roc] [--js <dir>] [--wasm <file>] [--config <wrangler config>] [--env <name>]
               [--message <text>] [--percent <1-100>] [--migrate <D1 binding>]...
               [--url <base URL>] [--smoke <path>[=<status>]]... [--smoke-same <path>[=<status>]]...
               [--wait <seconds>] [--timeout <seconds>] [--no-rollback] [--first] [--dry-run]
```

| Flag | Default | Does |
| --- | --- | --- |
| `--file <app.roc>` | `main.roc` | The app file (as `sync`) |
| `--js <dir>` | the platform `js/` | As `sync` |
| `--wasm <file>` | `app.wasm` | The built app. With `--wasm`, the age check is not done (you gave the file). |
| `--config <file>` | wrangler finds it | Passed to `sync --check` and to each `wrangler` command |
| `--env <name>` | none | Passed to each `wrangler` command as `--env <name>`. Selects `[deploy.env.<name>]` of `roc-cfw.toml`. |
| `--message <text>` | `roc-cfw <version> <commit>` (`-dirty` when the tree has changes; no commit when there is no git) | The message of the upload and of the deploy |
| `--percent <n>` | 100 | The traffic of the new version. Below 100: `new@n% old@(100-n)%` (a gradual deploy) |
| `--migrate <binding>` | none | Apply the pending D1 migrations of this binding after the upload and before the deploy. You can give it more than once. Migrations are forward-only (see "Migrations"). |
| `--url <base>` | none | The base URL of the smoke checks (`https://...`) |
| `--smoke <path>[=<status>]` | status 200 | A `GET <base><path>` after the deploy must give the status. The body is not compared. |
| `--smoke-same <path>[=<status>]` | status 200 | As `--smoke`, and the body must be equal to the body before the deploy |
| `--wait <seconds>` | 5 | The time before the first smoke try, and between tries (3 tries) |
| `--timeout <seconds>` | 30 | The time limit of one HTTP request of a check (1 or more) |
| `--no-rollback` | rollback on | Do not roll back when a smoke check fails |
| `--first` | off | The first deploy of the Worker: there is no live version, so there is no rollback target |
| `--dry-run` | off | Preflight, the plan, and `wrangler deploy --dry-run` only. No remote read and no remote change. |

## Config file: roc-cfw.toml

The smoke checks are a list, so a file is easier than flags. The file is `roc-cfw.toml` in the current directory (the directory of `.roc-cfw/`). It is optional.

```toml
[deploy]
url = "https://my-app.my-account.workers.dev"
migrate = ["DB"]
percent = 100
rollback = true
wait = 5
timeout = 30

[[deploy.smoke]]
path = "/"
status = 200

[[deploy.smoke]]
path = "/v1/index.json"
same-body = true

[[deploy.smoke]]
path = "/v1/packages/roc-semver.json"
same-body = true
ignore = ["/checked"]

[deploy.env.staging]
url = "https://my-app-staging.my-account.workers.dev"
```

| Key | Type | Flag |
| --- | --- | --- |
| `url` | string | `--url` replaces it |
| `migrate` | array of strings | `--migrate` adds to it |
| `percent` | integer 1 to 100 | `--percent` replaces it |
| `rollback` | boolean | `--no-rollback` sets false |
| `wait` | integer, seconds | `--wait` replaces it |
| `timeout` | integer, seconds, 1 or more | `--timeout` replaces it |
| `smoke` | array of tables: `path` (string, starts with `/`), `status` (integer, default 200), `same-body` (boolean, default false), `ignore` (array of JSON pointers, only with `same-body = true`) | `--smoke` and `--smoke-same` add to it. `ignore` has no flag. |
| `env` | tables `[deploy.env.<name>]` with the keys above (not `env`) | `--env <name>` selects one |

An unknown key, or a value of the wrong type, stops the command with exit 2. A typo (for example `same_body`) must not make a check weaker with no message. Each env table is checked, also when `--env` does not select it.

### Env tables

With `--env <name>`, each key of `[deploy.env.<name>]` replaces the same key of `[deploy]`. A key that the env table does not have comes from `[deploy]`. A list key (`migrate`, `smoke`) is replaced as one value: the items are not added.

| `--env` | `--url` | `url` of `[deploy.env.<name>]` | Smoke checks | Result |
| --- | --- | --- | --- | --- |
| none | any | any | any | As in 0.0.2: `--url`, else `url` of `[deploy]` |
| given | given | any | any | `--url` |
| given | none | given | any | The env `url` |
| given | none | none | some | Exit 2: the `url` of `[deploy]` is the URL of the Worker with no env, so the checks would read another Worker |
| given | none | none | none | Go on (no check reads a URL) |

### Same-body checks

A same-body check reads the path before the deploy (step 3) and compares the body after the deploy with it.

| `ignore` | Compare | A body that is not JSON |
| --- | --- | --- |
| none | The bytes must be equal | Compared as bytes |
| `["/checked", ...]` | The two bodies as JSON values, with no value at each pointer. The order of the members of an object does not count. The order of the items of an array does. A string or a number is compared as its JSON text. | Before the deploy: exit 1, nothing changed. After the deploy: the try fails. |

A pointer is a JSON pointer (RFC 6901): `/checked` is the member `checked` of the top object, `/meta/time` is a nested member, `/items/0/at` goes into an array, `~1` is `/` and `~0` is `~` in a name. A pointer that is not in a body changes nothing. A failure names the first pointer that differs, for example `it differs at /versions/1`.

Use `ignore` for a member that changes by itself: a time that a cron writes, or a value that depends on the time of the request. For a route whose whole body changes by itself, use a check with no `same-body`: it checks only the status.

Why this file, and not another place:

| Place | Why not |
| --- | --- |
| Wrangler `vars` | They go to the Worker as environment values. A deploy setting is not an app value. |
| A `[deploy]` table in `talon.toml` | Talon gives a warning for each unknown table at each run (Talon R-TF4). Also, a project can use `roc-cfw` with no Talon. |
| Flags in the `deploy` script of `talon.toml` | This works too for all keys but `ignore` and `env`. Use flags for 1 or 2 checks, and the file for more. |

## Steps

```text
1 preflight (local only)
    app.wasm is there; it is not older than a .roc file under the app directory (not with --wasm)
    shim, then: node .roc-cfw/cli.mjs sync --check --file <app> --wasm <wasm> [--config <c>]
      (shim hash, manifest against the wrangler config, bindings, crons, nightly range)
    a failure: stop. No wrangler command ran.
--dry-run: print the plan, run `wrangler deploy --dry-run [--env] [--config]`, stop.
2 live version: wrangler deployments status --json
    one version: it is the rollback target. Print it and the rollback command.
    two or more versions (a gradual deploy in progress): stop, exit 1, with the commands that finish it.
    --first: there must be no live version (else stop, exit 1). No target.
3 before reads: GET of each same-body check (3 tries). It must give the status (and JSON, with ignore), else stop.
4 upload: wrangler versions upload --message <m>  -> "Worker Version ID: <id>". The new version has no traffic.
5 migrations: for each binding:
    wrangler d1 migrations list <b> --remote   -> the pending list; none: next binding
    print the pending list and "forward-only"
    wrangler d1 migrations apply <b> --remote  (no terminal on stdin: wrangler asks no question)
    wrangler d1 migrations list <b> --remote   -> the pending list must be empty, else stop, exit 1
6 deploy: wrangler versions deploy <new>@<p>% [<old>@<100-p>%] --message <m> --yes
7 smoke: wait, then each check (3 tries, <wait> seconds apart, <timeout> seconds for each request)
8 a check fails: wrangler rollback <old> --message "roc-cfw: smoke check failed" --yes (not with --no-rollback or --first)
```

Each `wrangler` command gets `--env <name>` and `--config <file>` when you give them. The stdout and stderr of wrangler go to the terminal, but its stdin is empty: no `wrangler` command asks a question, so the result does not depend on a person at the terminal. The rollback command is printed after step 2 and in the last report.

| A stop before step | Remote state |
| --- | --- |
| 4 (upload) | No change |
| 5 (migrations) | A new version with no traffic. The live version did not change. |
| 6 (deploy) | The applied migrations stay. The live version did not change. |

## Migrations

D1 migrations are forward-only. `wrangler rollback` changes only the code: a rollback after a migration puts the old code on the new schema. Write migrations that the live version can use (for example: add a table or a column; do not drop or rename one that the live version reads).

| Rule | Why |
| --- | --- |
| Opt-in for each binding (`--migrate`, `migrate`) | A deploy changes a schema only when you name its binding |
| After the preflight, the live-version read, the before reads and the upload | A failure in these steps stops the deploy before a schema change |
| The pending list is printed with "forward-only" before the apply | You see what changes and that a rollback does not undo it |
| No question: stdin of wrangler is empty | `wrangler d1 migrations apply` asks for a yes on a terminal. A "no" gives exit 0 and applies nothing, so a deploy could go on with no migration. With an empty stdin wrangler uses its non-interactive answer (yes). |
| The pending list must be empty after the apply | The exit code of `apply` does not show a "no" or a cancelled migration. A pending migration after the apply stops the deploy (exit 1) before the new version gets traffic. |
| The report names the applied migrations | After a stop or a rollback, the line `schema: migrated (...)` names each applied migration. They stay. |

## Gradual deploys

`--percent <n>` below 100 deploys `new@n% old@(100-n)%`. A smoke check can then reach the old or the new version. A failed check rolls back to the old version at 100%.

`roc-cfw deploy` has no command to finish a gradual deploy. When the live deployment has two versions, the next `roc-cfw deploy` stops with exit 1 and prints, for each version, the command that gives it 100%:

```text
wrangler versions deploy <id>@100% --yes [--env <name>] [--config <file>]
```

Why: a new deploy would split the traffic with only one of the two versions, and a rollback could restore only one of them.

## The first deploy

With `--first`, `deploy` reads the live version too. When there is one, it stops with exit 1: with `--first` the deploy would have no rollback target.

Cloudflare has no rollback to "no Worker". When a smoke check of a first deploy fails, the new version stays (exit 4), and the report gives the next commands:

| Next | Command |
| --- | --- |
| Take the Worker down | `wrangler delete [--env <name>] [--config <file>]` |
| Deploy a fix | `roc-cfw deploy` with no `--first`. The failed version is then the rollback target. |

## Exit codes

The codes 0, 1 and 2 have the meaning that they have for `sync`.

| Code | When | State of the Worker |
| --- | --- | --- |
| 0 | All steps passed (or the dry run passed) | The new version is live |
| 1 | A failure before the new version got traffic: preflight, the live version read (also: a gradual deploy in progress, `--first` with a live version), a before read, the upload, a migration that did not apply, the deploy command | The old version is live. The applied migrations stay (the message names them). After a failed `versions deploy`, check it with the printed rollback command. |
| 2 | A bad command line or `roc-cfw.toml`, a tool (`node`, `wrangler`) that does not start, an api of the platform that this version does not know | No change |
| 3 | A smoke check failed, and the rollback passed | The old version is live. The applied migrations stay (line `schema:`). |
| 4 | A smoke check failed, and there was no rollback (`--no-rollback`, `--first`, or the rollback failed) | The new version is live |
| n | The exit code of `sync --check` (1 or 2), as `sync` | No change |

## What deploy does not do

| Item | Why |
| --- | --- |
| Log tail, dead-letter queue checks, app tests | They are specific to an app. Put them in the `deploy` script of `talon.toml`, before or after `roc-cfw deploy`. |
| An `--after <cmd>` hook | A script step after `roc-cfw deploy` does the same. A hook that can roll back would need a contract for the exit code of the hook. |
| A rollback of migrations | D1 has no down migrations. Write migrations that the live version can use. |
| A command that finishes a gradual deploy | Use `wrangler versions deploy <id>@100% --yes` |
| `--json` | `sync`, `shim` and `init` have no JSON output. |
| Methods other than `GET` in a smoke check | A smoke check must not change data. |

## The template script

```toml
deploy = ["@check", "roc-cfw deploy"]
```

`@check` builds `app.wasm`. `roc-cfw deploy` checks it again (this is fast) and deploys it.
