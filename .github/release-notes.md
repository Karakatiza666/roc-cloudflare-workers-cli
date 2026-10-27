# roc-cfw @TAG@

`roc-cfw` is the helper CLI of the Roc platform for Cloudflare Workers (`Karakatiza666/roc-cloudflare-workers`). This release has one asset: the app bundle `@NAME@`. Talon builds it for your system.

## Use with Talon

| Step | Command |
| --- | --- |
| Pin the tool in the project | `tln add --tool Karakatiza666/roc-cloudflare-workers-cli --as roc-cfw` |
| Write the template of the platform | `tln x roc-cfw -- init` |
| Build and sync | `tln run build` |

The first command builds `roc-cfw` and writes the `[tools]` entry in `talon.toml`. The entry holds the URL of this bundle, so each project pins its own version.

## Details

| Item | Value |
| --- | --- |
| Bundle URL | `@URL@` |
| Platform of the app | basic-cli 0.26.0 |
| Compiler pin (`roc:` in the header) | `@NIGHTLY@` |
| Platform contract | `js/cfw.json` with `api` 1 |

Read the README for the commands, the exit codes and the contract with the platform bundle.
