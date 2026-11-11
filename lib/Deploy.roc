import toml.Toml
import toml.Value

## The pure decisions of `roc-cfw deploy` (docs/deploy.md). `main.roc` runs the commands in the order of the steps.
##
## | Step | Decision here |
## | --- | --- |
## | Command line, `roc-cfw.toml` | `flags`, `file`, `plan` |
## | Preflight | `stale`, `skip_dir`, `sync_args` |
## | Live version, upload | `live`, `version_id` |
## | The wrangler commands | `status_args`, `upload_args`, `deploy_args`, `rollback_args`, `migrations_args`, `dry_run_args` |
## | Smoke checks | `smoke_arg`, `url_of`, `judge`, `after_smoke`, `exit_of` |
Deploy :: [].{

	## The flags of `deploy` after `Args` took `--file` and `--js`. `""` is "not given" for a text.
	flags : List(Str) -> Try(Flags, Str)
	flags = |args| {
		var $f = no_flags
		var $pending = ""
		var $problem = ""
		for arg in args {
			if $pending != "" {
				$f = match set_value($f, $pending, arg) {
					Ok(next) => next
					Err(message) => {
						if $problem == "" {
							$problem = message
						}
						$f
					}
				}
				$pending = ""
			} else if value_flags.contains(arg) {
				$pending = arg
			} else if arg == "--no-rollback" {
				$f = { ..$f, no_rollback: Bool.True }
			} else if arg == "--first" {
				$f = { ..$f, first: Bool.True }
			} else if arg == "--dry-run" {
				$f = { ..$f, dry_run: Bool.True }
			} else if $problem == "" {
				$problem = "unknown argument ${arg}"
			}
		}
		if $pending != "" {
			Err("${$pending} needs a value")
		} else if $problem != "" {
			Err($problem)
		} else {
			Ok($f)
		}
	}

	## A smoke check from a flag value: `<path>` or `<path>=<status>`. `same` is true for `--smoke-same`.
	smoke_arg : Str, Bool -> Try(Smoke, Str)
	smoke_arg = |text, same| {
		(path, status_text) = match text.split_first("=") {
			Ok({ before, after }) => (before, after)
			Err(_) => (text, "200")
		}
		status = match U16.from_str(status_text) {
			Ok(n) if n >= 100 and n <= 599 => n
			_ => return Err("the smoke check ${text}: the status ${status_text} is not an HTTP status (100 to 599)")
		}
		if path.starts_with("/") Ok({ path, status, same }) else Err("the smoke check ${text}: the path must start with /")
	}

	## The `[deploy]` table of the text of `roc-cfw.toml`. `""` (no file) gives no settings.
	## An unknown key or a value of the wrong type is an error: a typo must not make a check weaker with no message.
	file : Str -> Try(FileSettings, Str)
	file = |text| {
		if text.trim() == "" {
			return Ok(no_file)
		}
		doc = match Toml.parse(text) {
			Ok(d) => d
			Err(TomlErr(e)) => return Err("roc-cfw.toml does not parse: line ${e.line.to_str()}, column ${e.column.to_str()}: ${e.message}")
		}
		for key in doc.table().keys() {
			if key != "deploy" {
				return Err("roc-cfw.toml: unknown table or key ${key}")
			}
		}
		table = match doc.get(["deploy"]) {
			Err(NotFound) => return Ok(no_file)
			Ok(Table(d)) => d
			Ok(_) => return Err("roc-cfw.toml: deploy is not a table")
		}
		var $s = no_file
		for (key, value) in table {
			$s = match (key, value) {
				("url", String(u)) => { ..$s, url: u }
				("migrate", Array(items)) => {
					names = items.keep_oks(
						|v| match v {
							String(n) => Ok(n)
							_ => Err({})
						},
					)
					if names.len() != items.len() {
						return Err("roc-cfw.toml: deploy.migrate must be an array of strings")
					}
					{ ..$s, migrate: names }
				}
				("percent", Integer(n)) => { ..$s, percent: Set(int_of(n)?) }
				("rollback", Boolean(b)) => { ..$s, rollback: Set(b) }
				("wait", Integer(n)) => { ..$s, wait: Set(int_of(n)?) }
				("smoke", Array(items)) => {
					var $checks = []
					for item in items {
						$checks = $checks.append(smoke_of(item)?)
					}
					{ ..$s, smoke: $checks }
				}
				("url", _) | ("migrate", _) | ("percent", _) | ("rollback", _) | ("wait", _) | ("smoke", _) => return Err("roc-cfw.toml: deploy.${key} has the wrong type (docs/deploy.md)")
				_ => return Err("roc-cfw.toml: unknown key deploy.${key}")
			}
		}
		Ok($s)
	}

	## The settings of one run: the flags win over `roc-cfw.toml` for one value, and add to it for a list.
	plan : FileSettings, Flags -> Try(Plan, Str)
	plan = |s, f| {
		percent = match f.percent {
			Set(n) => n
			Unset => match s.percent {
				Set(n) => n
				Unset => 100
			}
		}
		wait = match f.wait {
			Set(n) => n
			Unset => match s.wait {
				Set(n) => n
				Unset => 5
			}
		}
		rollback = if f.no_rollback Bool.False else match s.rollback {
			Set(b) => b
			Unset => Bool.True
		}
		url = if f.url != "" f.url else s.url
		smoke = s.smoke.concat(f.smoke)
		migrate = s.migrate.concat(f.migrate)
		if percent < 1 or percent > 100 {
			Err("the percent ${percent.to_str()} is not 1 to 100")
		} else if f.first and percent != 100 {
			Err("--first needs percent 100: there is no old version to split the traffic with")
		} else if !smoke.is_empty() and url == "" {
			Err("the smoke checks need a base URL: --url, or url in [deploy] of roc-cfw.toml")
		} else if url != "" and !(url.starts_with("https://") or url.starts_with("http://")) {
			Err("the URL ${url} does not start with https:// or http://")
		} else if migrate.any(|m| m == "") {
			Err("--migrate needs a D1 binding name")
		} else {
			Ok({
				wasm: if f.wasm == "" "app.wasm" else f.wasm,
				wasm_given: f.wasm != "",
				config: f.config,
				env: f.env,
				message: f.message,
				percent,
				migrate,
				url,
				smoke,
				wait,
				rollback,
				first: f.first,
				dry_run: f.dry_run,
			})
		}
	}

	## The default message of the upload and the deploy: `roc-cfw <version> <commit>`, with `-dirty` for a tree with changes.
	## `commit` is `""` when there is no git.
	message : { version : Str, commit : Str, dirty : Bool } -> Str
	message = |m| {
		if m.commit == "" {
			"roc-cfw ${m.version}"
		} else if m.dirty {
			"roc-cfw ${m.version} ${m.commit}-dirty"
		} else {
			"roc-cfw ${m.version} ${m.commit}"
		}
	}

	## Whether the wasm is older than a source. `Err(path)` names the newest source that is newer than the wasm.
	## The times are nanoseconds since the epoch (`Path.time_modified!`, then `to_nanos_since_epoch`).
	stale : I128, List((Str, I128)) -> Try({}, Str)
	stale = |wasm_time, sources| {
		newer = sources.keep_if(|(_, t)| t > wasm_time).sort_with(|a, b| b.1.order_relative_to(a.1))
		match newer {
			[] => Ok({})
			[(path, _), ..] => Err(path)
		}
	}

	## Whether the age check skips a directory: a name that starts with `.` (`.git`, `.roc-cfw`, `.wrangler`), and `node_modules`.
	skip_dir : Str -> Bool
	skip_dir = |name| name.starts_with(".") or name == "node_modules"

	## The arguments after `node .roc-cfw/cli.mjs sync` for the preflight.
	sync_args : Plan, Str -> List(Str)
	sync_args = |p, app_file| {
		base = ["--file", app_file, "--wasm", p.wasm, "--check"]
		if p.config == "" base else base.concat(["--config", p.config])
	}

	## The live version from the stdout of `wrangler deployments status --json`: the version with the most traffic.
	## `split` is true when the deployment has more than one version (a gradual deploy is in progress).
	live : Str -> Try({ id : Str, percent : U64, split : Bool }, [NoVersion])
	live = |stdout| {
		parsed : Try({ versions : List({ version_id : Str, percentage : Dec }) }, _)
		parsed = Json.parse(stdout.trim())
		versions = match parsed {
			Ok({ versions: v }) => v
			Err(_) => return Err(NoVersion)
		}
		sorted = versions.sort_with(|a, b| b.percentage.order_relative_to(a.percentage))
		match sorted {
			[] => Err(NoVersion)
			[top, ..] => if top.version_id == "" Err(NoVersion) else Ok({ id: top.version_id, percent: top.percentage.to_u64_wrap(), split: versions.len() > 1 })
		}
	}

	## The id of the new version from the stdout of `wrangler versions upload`: the line `Worker Version ID: <id>`.
	version_id : Str -> Try(Str, [NoId])
	version_id = |stdout| {
		found = stdout.split_on("\n").find_first(|line| line.trim().starts_with(version_label))
		match found {
			Ok(line) => {
				id = line.trim().drop_prefix(version_label).trim()
				if id == "" or id.contains(" ") Err(NoId) else Ok(id)
			}
			Err(_) => Err(NoId)
		}
	}

	## `--env <name>` and `--config <file>`, when given. Each wrangler command gets them.
	common : Plan -> List(Str)
	common = |p| {
		env = if p.env == "" [] else ["--env", p.env]
		if p.config == "" env else env.concat(["--config", p.config])
	}

	status_args : Plan -> List(Str)
	status_args = |p| ["deployments", "status", "--json"].concat(Deploy.common(p))

	upload_args : Plan, Str -> List(Str)
	upload_args = |p, msg| ["versions", "upload", "--message", msg].concat(Deploy.common(p))

	## `versions deploy`: the new version gets `percent`; the old version gets the rest when the percent is below 100.
	deploy_args : Plan, { new : Str, old : Str, message : Str } -> List(Str)
	deploy_args = |p, v| {
		specs = if p.percent >= 100 or v.old == "" ["${v.new}@100%"] else ["${v.new}@${p.percent.to_str()}%", "${v.old}@${(100 - p.percent).to_str()}%"]
		["versions", "deploy"].concat(specs).concat(["--message", v.message, "--yes"]).concat(Deploy.common(p))
	}

	rollback_args : Plan, Str, Str -> List(Str)
	rollback_args = |p, old, msg| ["rollback", old, "--message", msg, "--yes"].concat(Deploy.common(p))

	migrations_args : Plan, [List, Apply], Str -> List(Str)
	migrations_args = |p, what, binding| {
		word = match what {
			List => "list"
			Apply => "apply"
		}
		["d1", "migrations", word, binding, "--remote"].concat(Deploy.common(p))
	}

	dry_run_args : Plan -> List(Str)
	dry_run_args = |p| ["deploy", "--dry-run"].concat(Deploy.common(p))

	## The message of an automatic rollback.
	rollback_message : Str
	rollback_message = "roc-cfw: smoke check failed"

	## A command as one line for the user, with single quotes around an argument that needs them.
	shell : Str, List(Str) -> Str
	shell = |program, args| Str.join_with([program].concat(args.map(quote)), " ")

	## The URL of a check: the base with no `/` at the end, then the path.
	url_of : Str, Str -> Str
	url_of = |base, path| {
		trimmed = if base.ends_with("/") base.drop_suffix("/") else base
		"${trimmed}${path}"
	}

	## The result of one try of a smoke check. `before` is the body before the deploy (only for a same-body check).
	judge : { smoke : Smoke, before : [None, Some(List(U8))], got : [Failed(Str), Got({ status : U16, body : List(U8) })] } -> [Pass, Fail(Str)]
	judge = |j| match j.got {
		Failed(why) => Fail("GET ${j.smoke.path}: ${why}")
		Got(r) => {
			if r.status != j.smoke.status {
				Fail("GET ${j.smoke.path}: status ${r.status.to_str()}, expected ${j.smoke.status.to_str()}")
			} else {
				match j.before {
					Some(old) if j.smoke.same and old != r.body => Fail("GET ${j.smoke.path}: the body is not the body before the deploy (${r.body.len().to_str()} bytes, before ${old.len().to_str()} bytes)")
					_ => Pass
				}
			}
		}
	}

	## What to do after the smoke checks. `target` is false when there is no rollback target (`--first`).
	after_smoke : { failed : U64, rollback : Bool, target : Bool } -> [Done, Rollback, Keep]
	after_smoke = |a| {
		if a.failed == 0 {
			Done
		} else if a.rollback and a.target {
			Rollback
		} else {
			Keep
		}
	}

	## The exit code of the end of a deploy (docs/deploy.md, "Exit codes").
	exit_of : [Done, RolledBack, Kept, RollbackFailed] -> I32
	exit_of = |end| match end {
		Done => 0
		RolledBack => 3
		Kept => 4
		RollbackFailed => 4
	}
}

Smoke : { path : Str, status : U16, same : Bool }

Flags : {
	wasm : Str,
	config : Str,
	env : Str,
	message : Str,
	url : Str,
	percent : [Unset, Set(U64)],
	wait : [Unset, Set(U64)],
	migrate : List(Str),
	smoke : List(Smoke),
	no_rollback : Bool,
	first : Bool,
	dry_run : Bool,
}

FileSettings : {
	url : Str,
	migrate : List(Str),
	percent : [Unset, Set(U64)],
	rollback : [Unset, Set(Bool)],
	wait : [Unset, Set(U64)],
	smoke : List(Smoke),
}

Plan : {
	wasm : Str,
	wasm_given : Bool,
	config : Str,
	env : Str,
	message : Str,
	percent : U64,
	migrate : List(Str),
	url : Str,
	smoke : List(Smoke),
	wait : U64,
	rollback : Bool,
	first : Bool,
	dry_run : Bool,
}

version_label : Str
version_label = "Worker Version ID:"

value_flags : List(Str)
value_flags = ["--wasm", "--config", "--env", "--message", "--url", "--percent", "--wait", "--migrate", "--smoke", "--smoke-same"]

no_flags : Flags
no_flags = {
	wasm: "",
	config: "",
	env: "",
	message: "",
	url: "",
	percent: Unset,
	wait: Unset,
	migrate: [],
	smoke: [],
	no_rollback: Bool.False,
	first: Bool.False,
	dry_run: Bool.False,
}

no_file : FileSettings
no_file = { url: "", migrate: [], percent: Unset, rollback: Unset, wait: Unset, smoke: [] }

set_value : Flags, Str, Str -> Try(Flags, Str)
set_value = |f, flag, value| match flag {
	"--wasm" => Ok({ ..f, wasm: value })
	"--config" => Ok({ ..f, config: value })
	"--env" => Ok({ ..f, env: value })
	"--message" => Ok({ ..f, message: value })
	"--url" => Ok({ ..f, url: value })
	"--migrate" => Ok({ ..f, migrate: f.migrate.append(value) })
	"--percent" => match U64.from_str(value) {
		Ok(n) => Ok({ ..f, percent: Set(n) })
		Err(_) => Err("--percent ${value} is not a whole number")
	}
	"--wait" => match U64.from_str(value) {
		Ok(n) => Ok({ ..f, wait: Set(n) })
		Err(_) => Err("--wait ${value} is not a whole number of seconds")
	}
	"--smoke" => Ok({ ..f, smoke: f.smoke.append(Deploy.smoke_arg(value, Bool.False)?) })
	"--smoke-same" => Ok({ ..f, smoke: f.smoke.append(Deploy.smoke_arg(value, Bool.True)?) })
	_ => Err("unknown argument ${flag}")
}

int_of : I64 -> Try(U64, Str)
int_of = |n| if n < 0 Err("roc-cfw.toml: a number in [deploy] is below 0") else Ok(n.to_u64_try() ?? 0)

smoke_of : Value -> Try(Smoke, Str)
smoke_of = |item| {
	table = match item {
		Table(d) => d
		_ => return Err("roc-cfw.toml: each deploy.smoke item must be a table ([[deploy.smoke]])")
	}
	var $path = ""
	var $status = 200
	var $same = Bool.False
	for (key, value) in table {
		match (key, value) {
			("path", String(p)) => {
				$path = p
			}
			("status", Integer(n)) => {
				$status = if n >= 100 and n <= 599 n else return Err("roc-cfw.toml: deploy.smoke status ${n.to_str()} is not an HTTP status")
			}
			("same-body", Boolean(b)) => {
				$same = b
			}
			("path", _) | ("status", _) | ("same-body", _) => return Err("roc-cfw.toml: deploy.smoke ${key} has the wrong type")
			_ => return Err("roc-cfw.toml: unknown key deploy.smoke ${key}")
		}
	}
	if !$path.starts_with("/") {
		return Err("roc-cfw.toml: each deploy.smoke item needs a path that starts with /")
	}
	Ok({ path: $path, status: $status.to_u16_try() ?? 200, same: $same })
}

## Single quotes around an argument with a character that a shell reads. A `'` in it becomes `'\''`.
quote : Str -> Str
quote = |arg| {
	safe = arg != "" and arg.to_utf8().all(|b| (b >= 97 and b <= 122) or (b >= 65 and b <= 90) or (b >= 48 and b <= 57) or [45, 95, 46, 47, 58, 64, 37, 61, 44].contains(b))
	if safe arg else "'${arg.replace_each("'", "'\\''")}'"
}
