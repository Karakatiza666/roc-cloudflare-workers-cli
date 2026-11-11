# roc-cfw @TAG@

`roc-cfw` is the helper CLI of the Roc platform for Cloudflare Workers (`Karakatiza666/roc-cloudflare-workers`). The main asset is the app bundle `@NAME@`. Talon builds it for your system. The release can also have prebuilt binaries `<hash>-<target>` (`<hash>` is `@NAME@` without `.tar.zst`), `SHA256SUMS`, and a build attestation of the bundle and the binaries (see the README).

## Use with Talon

| Step | Command |
| --- | --- |
| Pin the tool in the project | `tln add --tool Karakatiza666/roc-cloudflare-workers-cli --as roc-cfw` |
| Write the template of the platform | `tln x roc-cfw -- init` |
| Build and sync | `tln run build` |
| Deploy (preflight, versions upload and deploy, smoke checks, rollback) | `deploy = ["@check", "roc-cfw deploy"]` in `[scripts]`, then `tln run deploy` (see `docs/deploy.md`) |

The first command builds `roc-cfw` and writes the `[tools]` entry in `talon.toml`. The entry holds the URL of this bundle, so each project pins its own version.

## Changes in 0.0.3: deploy

| Change | Before (0.0.2) | Now |
| --- | --- | --- |
| Migrations: a "no" | `wrangler d1 migrations apply` asked on a terminal. A "no" applied nothing with exit 0, and the deploy went on. | No `wrangler` command gets a terminal on stdin, so wrangler asks nothing. After the apply, `migrations list` must show no pending migration, else exit 1 before the new version gets traffic. |
| Migrations: order | Before the upload | After the upload (the new version has no traffic yet), before `versions deploy`. A failed upload changes no schema. |
| Migrations: forward-only | A line in the docs | The pending list is printed with "forward-only" before the apply. The report and each stop message name the applied migrations (`schema: migrated (...)`). |
| `--first` | No status read. A failed smoke check left the version with no next step. | The status read must show no live version (else exit 1). A failed smoke check gives exit 4 and the next commands (`wrangler delete`, or a fixed deploy). |
| A gradual deploy in progress | The version with the most traffic was the target; the other version was dropped | Exit 1 before any change, with the `wrangler versions deploy <id>@100%` command of each version |
| Same-body checks | Bytes only | New key `ignore` (JSON pointers) in `[[deploy.smoke]]`: the bodies are compared as JSON with no value at those pointers. A failure names the first pointer that differs. |
| `--env` and `url` | The `url` of `[deploy]` was used for each env | New tables `[deploy.env.<name>]`. With `--env`, smoke checks and only the `url` of `[deploy]`: exit 2 (the checks would read another Worker). |
| HTTP time limit | 30 s, fixed | `--timeout` and `timeout` (default 30) |
| Before reads | One try | 3 tries, `wait` seconds apart |
| Output parsing | The status JSON had to be the whole stdout | The status JSON can have text around it; color codes in the upload output are removed |
| Dry run | One summary line | The plan: one line for each setting and each smoke check |

Config compatibility: each `roc-cfw.toml` of 0.0.2 is valid. One change of behavior: `--env <name>` with smoke checks and a `url` only in `[deploy]` is now exit 2. Move the url to `[deploy.env.<name>]`, or give `--url`.

## Details

| Item | Value |
| --- | --- |
| Bundle URL | `@URL@` |
| Platform of the app | basic-cli 0.26.0 |
| Compiler pin (`roc:` in the header) | `@NIGHTLY@` |
| Platform contract | `js/cfw.json` with `api` 1 |

Read the README for the commands, the exit codes and the contract with the platform bundle.
