import toml.Toml
import toml.Value
import JsonBody

## The pure decisions of `roc-cfw deploy` (docs/deploy.md). `main.roc` runs the commands in the order of the steps.
##
## | Step | Decision here |
## | --- | --- |
## | Command line, `roc-cfw.toml` | `flags`, `file`, `plan`, `plan_lines` (the dry-run plan) |
## | Preflight | `stale`, `skip_dir`, `sync_args` |
## | Live version, upload | `live`, `split_message`, `first_check`, `version_id` |
## | Migrations | `pending`, `migration_note`, `schema_note` |
## | The wrangler commands | `status_args`, `upload_args`, `deploy_args`, `rollback_args`, `migrations_args`, `dry_run_args` |
## | Smoke checks | `smoke_arg`, `url_of`, `before_check`, `judge`, `after_smoke`, `first_next`, `exit_of` |
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
		if path.starts_with("/") Ok({ path, status, same, ignore: [] }) else Err("the smoke check ${text}: the path must start with /")
	}

	## The `[deploy]` table of the text of `roc-cfw.toml`. `""` (no file) gives no settings.
	## `env` is the value of `--env` (`""`: none). With an env, the keys of `[deploy.env.<env>]` replace the keys of `[deploy]`.
	## An unknown key or a value of the wrong type is an error: a typo must not make a check weaker with no message.
	## Each env table is checked, also when it is not used.
	file : Str, Str -> Try(FileSettings, Str)
	file = |text, env| {
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
		var $s = settings_of(table, "deploy")?
		for (key, value) in table {
			if key == "env" {
				envs = match value {
					Table(t) => t
					_ => return Err("roc-cfw.toml: deploy.env must be a table of env tables ([deploy.env.<name>])")
				}
				for (name, env_value) in envs {
					prefix = "deploy.env.${name}"
					env_table = match env_value {
						Table(t) => t
						_ => return Err("roc-cfw.toml: ${prefix} must be a table")
					}
					if env_table.keys().contains("env") {
						return Err("roc-cfw.toml: ${prefix}.env: an env table cannot hold env tables")
					}
					over = settings_of(env_table, prefix)?
					if name == env {
						$s = overlay($s, over)
					}
				}
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
		timeout = match f.timeout {
			Set(n) => n
			Unset => match s.timeout {
				Set(n) => n
				Unset => 30
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
		} else if timeout < 1 {
			Err("the timeout ${timeout.to_str()} is not 1 or more seconds")
		} else if !smoke.is_empty() and url == "" {
			Err("the smoke checks need a base URL: --url, or url in [deploy] of roc-cfw.toml")
		} else if url != "" and !(url.starts_with("https://") or url.starts_with("http://")) {
			Err("the URL ${url} does not start with https:// or http://")
		} else if f.env != "" and f.url == "" and !s.url_env and !smoke.is_empty() {
			Err("--env ${f.env}: the url of [deploy] in roc-cfw.toml is the URL of the Worker with no env, so the smoke checks would read another Worker. Set url in [deploy.env.${f.env}], or give --url")
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
				timeout,
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

	## The live version from the stdout of `wrangler deployments status --json`: the id of the one version of the deployment.
	## Text before the first `{` or after the last `}` (a notice of wrangler) is ignored, and so are the other fields.
	## `Split` (a gradual deploy is in progress): the versions with their percent, the most traffic first.
	live : Str -> Try(Str, [NoVersion, Split(List((Str, Str)))])
	live = |stdout| {
		parsed : Try({ versions : List({ version_id : Str, percentage : Dec }) }, _)
		parsed = Json.parse(json_part(stdout))
		versions = match parsed {
			Ok({ versions: v }) => v
			Err(_) => return Err(NoVersion)
		}
		sorted = versions.sort_with(|a, b| b.percentage.order_relative_to(a.percentage))
		match sorted {
			[] => Err(NoVersion)
			[one] => if one.version_id == "" Err(NoVersion) else Ok(one.version_id)
			_ => Err(Split(sorted.map(|v| (v.version_id, Deploy.percent_text(v.percentage)))))
		}
	}

	## A percent with no `.0` for a whole number.
	percent_text : Dec -> Str
	percent_text = |d| {
		text = d.to_str()
		if text.ends_with(".0") text.drop_suffix(".0") else text
	}

	## The message of a live deployment with more than one version. The deploy stops: there is no one version to roll
	## back to, and a new deploy would drop a version of the gradual deploy.
	split_message : Plan, List((Str, Str)) -> Str
	split_message = |p, versions| {
		listed = Str.join_with(versions.map(|(id, pct)| "${id} ${pct}%"), ", ")
		commands = versions.map(|(id, _)| "\n  only ${id}: ${Deploy.shell("wrangler", ["versions", "deploy", "${id}@100%", "--yes"].concat(Deploy.common(p)))}")
		"the live deployment has more than one version (${listed}): a gradual deploy is in progress, so there is no one rollback target. Finish it or undo it first, then deploy again. Nothing changed.${Str.join_with(commands, "")}"
	}

	## `--first`: `Err(<id>)` when the status read shows a live version (the deploy stops: it would lose the rollback target).
	## An exit code that is not 0, or no version in the output, is the first deploy.
	first_check : I32, Str -> Try({}, Str)
	first_check = |code, stdout| {
		if code != 0 {
			return Ok({})
		}
		match Deploy.live(stdout) {
			Ok(id) => Err(id)
			Err(Split(versions)) => Err(versions.first().map_ok(|(id, _)| id) ?? "")
			Err(NoVersion) => Ok({})
		}
	}

	## The id of the new version from the stdout of `wrangler versions upload`: the line `Worker Version ID: <id>`.
	## Color codes are removed first.
	version_id : Str -> Try(Str, [NoId])
	version_id = |stdout| {
		found = strip_ansi(stdout).split_on("\n").find_first(|line| line.trim().starts_with(version_label))
		match found {
			Ok(line) => {
				id = line.trim().drop_prefix(version_label).trim()
				if id == "" or id.contains(" ") Err(NoId) else Ok(id)
			}
			Err(_) => Err(NoId)
		}
	}

	## The pending migrations from the stdout of `wrangler d1 migrations list <binding> --remote`: the rows of the table after
	## `Migrations to be applied:`, or `[]` for `No migrations to apply`. `Unknown` for another output: the deploy cannot
	## verify the migrations, so it stops.
	pending : Str -> Try(List(Str), [Unknown])
	pending = |stdout| {
		lines = strip_ansi(stdout).split_on("\n")
		if lines.any(|l| l.contains("No migrations to apply")) {
			return Ok([])
		}
		start = match lines.find_first_index(|l| l.contains("Migrations to be applied")) {
			Ok(i) => i + 1
			Err(_) => return Err(Unknown)
		}
		names = lines.drop_first(start).keep_oks(
			|l| {
				t = l.trim()
				if t.starts_with("│") or t.starts_with("|") {
					cell = t.replace_each("│", "").replace_each("|", "").trim()
					if cell == "" or cell == "Name" or cell == "name" Err({}) else Ok(cell)
				} else {
					Err({})
				}
			},
		)
		if names.is_empty() Err(Unknown) else Ok(names)
	}

	## The note before an apply: the pending migrations, and that they are forward-only.
	migration_note : Str, List(Str) -> Str
	migration_note = |binding, names| {
		count = if names.len() == 1 "1 pending migration" else "${names.len().to_str()} pending migrations"
		"${binding}: ${count}: ${Str.join_with(names, ", ")}. Migrations are forward-only: a rollback of the Worker does not undo them, so the live version must work with the new schema."
	}

	## The schema line of the end report. `applied` is `<binding> <name>` for each applied migration. `""` when none.
	schema_note : List(Str) -> Str
	schema_note = |applied| {
		if applied.is_empty() "" else "migrated (forward-only, a rollback does not undo it): ${Str.join_with(applied, ", ")}"
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

	## The before read of a same-body check with an ignore list must be JSON (else no try can pass).
	before_check : Smoke, List(U8) -> Try({}, Str)
	before_check = |smoke, body| {
		if smoke.ignore.is_empty() {
			return Ok({})
		}
		match JsonBody.parse(body) {
			Ok(_) => Ok({})
			Err(NotJson) => Err("GET ${smoke.path}: the body is not JSON, and the check has an ignore list (ignore needs a JSON body)")
		}
	}

	## The result of one try of a smoke check. `before` is the body before the deploy (only for a same-body check).
	## With an ignore list, the bodies are compared as JSON with no value at each ignored pointer.
	judge : { smoke : Smoke, before : [None, Some(List(U8))], got : [Failed(Str), Got({ status : U16, body : List(U8) })] } -> [Pass, Fail(Str)]
	judge = |j| match j.got {
		Failed(why) => Fail("GET ${j.smoke.path}: ${why}")
		Got(r) => {
			if r.status != j.smoke.status {
				Fail("GET ${j.smoke.path}: status ${r.status.to_str()}, expected ${j.smoke.status.to_str()}")
			} else {
				match j.before {
					Some(old) if j.smoke.same => same_body(j.smoke, old, r.body)
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

	## The next commands after a failed smoke check of a first deploy (no version to roll back to).
	first_next : Plan -> List(Str)
	first_next = |p| [
		"there is no older version to roll back to. Next, one of:",
		"  take the Worker down: ${Deploy.shell("wrangler", ["delete"].concat(Deploy.common(p)))}",
		"  fix the app, then: roc-cfw deploy (with no --first: the failed version is the rollback target)",
	]

	## The plan of a dry run: one line for each setting and each smoke check.
	plan_lines : Plan, Str -> List(Str)
	plan_lines = |p, msg| {
		traffic = if p.percent >= 100 or p.first "new version 100%" else "new version ${p.percent.to_str()}%, live version ${(100 - p.percent).to_str()}%"
		migrations = if p.migrate.is_empty() "none" else "${Str.join_with(p.migrate, ", ")} (pending list and apply after the upload; forward-only)"
		smoke = if p.smoke.is_empty() {
			["smoke:      none"]
		} else {
			p.smoke.map(
				|c| {
					same = if c.same ", same body" else ""
					ignore = if c.ignore.is_empty() "" else ", ignore ${Str.join_with(c.ignore, " ")}"
					"smoke:      GET ${Deploy.url_of(p.url, c.path)} status ${c.status.to_str()}${same}${ignore}"
				},
			)
		}
		rollback = if p.first "none (--first: no live version)" else if p.rollback "on (to the live version, when a smoke check fails)" else "off"
		[
			"wasm:       ${p.wasm}",
			"message:    ${msg}",
			"env:        ${if p.env == "" "none" else p.env}",
			"config:     ${if p.config == "" "the one that wrangler finds" else p.config}",
			"traffic:    ${traffic}",
			"migrations: ${migrations}",
		]
			.concat(smoke)
			.concat([
				"tries:      3, ${p.wait.to_str()} s apart (the first after ${p.wait.to_str()} s), HTTP time limit ${p.timeout.to_str()} s",
				"rollback:   ${rollback}",
			])
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

Smoke : { path : Str, status : U16, same : Bool, ignore : List(Str) }

Flags : {
	wasm : Str,
	config : Str,
	env : Str,
	message : Str,
	url : Str,
	percent : [Unset, Set(U64)],
	wait : [Unset, Set(U64)],
	timeout : [Unset, Set(U64)],
	migrate : List(Str),
	smoke : List(Smoke),
	no_rollback : Bool,
	first : Bool,
	dry_run : Bool,
}

## `given` names the keys that the table has (an env table replaces only these). `url_env` is true when the url comes from
## the env table of `--env`.
FileSettings : {
	url : Str,
	url_env : Bool,
	migrate : List(Str),
	percent : [Unset, Set(U64)],
	rollback : [Unset, Set(Bool)],
	wait : [Unset, Set(U64)],
	timeout : [Unset, Set(U64)],
	smoke : List(Smoke),
	given : List(Str),
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
	timeout : U64,
	rollback : Bool,
	first : Bool,
	dry_run : Bool,
}

version_label : Str
version_label = "Worker Version ID:"

value_flags : List(Str)
value_flags = ["--wasm", "--config", "--env", "--message", "--url", "--percent", "--wait", "--timeout", "--migrate", "--smoke", "--smoke-same"]

no_flags : Flags
no_flags = {
	wasm: "",
	config: "",
	env: "",
	message: "",
	url: "",
	percent: Unset,
	wait: Unset,
	timeout: Unset,
	migrate: [],
	smoke: [],
	no_rollback: Bool.False,
	first: Bool.False,
	dry_run: Bool.False,
}

no_file : FileSettings
no_file = { url: "", url_env: Bool.False, migrate: [], percent: Unset, rollback: Unset, wait: Unset, timeout: Unset, smoke: [], given: [] }

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
	"--timeout" => match U64.from_str(value) {
		Ok(n) => Ok({ ..f, timeout: Set(n) })
		Err(_) => Err("--timeout ${value} is not a whole number of seconds")
	}
	"--smoke" => Ok({ ..f, smoke: f.smoke.append(Deploy.smoke_arg(value, Bool.False)?) })
	"--smoke-same" => Ok({ ..f, smoke: f.smoke.append(Deploy.smoke_arg(value, Bool.True)?) })
	_ => Err("unknown argument ${flag}")
}

int_of : I64 -> Try(U64, Str)
int_of = |n| if n < 0 Err("roc-cfw.toml: a number in [deploy] is below 0") else Ok(n.to_u64_try() ?? 0)

## The settings of one table: `[deploy]`, or `[deploy.env.<name>]` (`prefix` names it in a message). It skips `env`.
settings_of : _, Str -> Try(FileSettings, Str)
settings_of = |table, prefix| {
	var $s = no_file
	for (key, value) in table {
		$s = match (key, value) {
			("env", _) => $s
			("url", String(u)) => { ..$s, url: u }
			("migrate", Array(items)) => {
				names = items.keep_oks(
					|v| match v {
						String(n) => Ok(n)
						_ => Err({})
					},
				)
				if names.len() != items.len() {
					return Err("roc-cfw.toml: ${prefix}.migrate must be an array of strings")
				}
				{ ..$s, migrate: names }
			}
			("percent", Integer(n)) => { ..$s, percent: Set(int_of(n)?) }
			("rollback", Boolean(b)) => { ..$s, rollback: Set(b) }
			("wait", Integer(n)) => { ..$s, wait: Set(int_of(n)?) }
			("timeout", Integer(n)) => { ..$s, timeout: Set(int_of(n)?) }
			("smoke", Array(items)) => {
				var $checks = []
				for item in items {
					$checks = $checks.append(smoke_of(item, prefix)?)
				}
				{ ..$s, smoke: $checks }
			}
			("url", _) | ("migrate", _) | ("percent", _) | ("rollback", _) | ("wait", _) | ("timeout", _) | ("smoke", _) => return Err("roc-cfw.toml: ${prefix}.${key} has the wrong type (docs/deploy.md)")
			_ => return Err("roc-cfw.toml: unknown key ${prefix}.${key}")
		}
		if key != "env" {
			$s = { ..$s, given: $s.given.append(key) }
		}
	}
	Ok($s)
}

## The settings of `[deploy]` with the keys of an env table put over them.
overlay : FileSettings, FileSettings -> FileSettings
overlay = |base, over| {
	given = |key| over.given.contains(key)
	{
		url: if given("url") over.url else base.url,
		url_env: given("url"),
		migrate: if given("migrate") over.migrate else base.migrate,
		percent: if given("percent") over.percent else base.percent,
		rollback: if given("rollback") over.rollback else base.rollback,
		wait: if given("wait") over.wait else base.wait,
		timeout: if given("timeout") over.timeout else base.timeout,
		smoke: if given("smoke") over.smoke else base.smoke,
		given: base.given.concat(over.given),
	}
}

smoke_of : Value, Str -> Try(Smoke, Str)
smoke_of = |item, prefix| {
	table = match item {
		Table(d) => d
		_ => return Err("roc-cfw.toml: each ${prefix}.smoke item must be a table ([[${prefix}.smoke]])")
	}
	var $path = ""
	var $status = 200
	var $same = Bool.False
	var $ignore = []
	for (key, value) in table {
		match (key, value) {
			("path", String(p)) => {
				$path = p
			}
			("status", Integer(n)) => {
				$status = if n >= 100 and n <= 599 n else return Err("roc-cfw.toml: ${prefix}.smoke status ${n.to_str()} is not an HTTP status")
			}
			("same-body", Boolean(b)) => {
				$same = b
			}
			("ignore", Array(items)) => {
				pointers = items.keep_oks(
					|v| match v {
						String(n) => Ok(n)
						_ => Err({})
					},
				)
				if pointers.len() != items.len() {
					return Err("roc-cfw.toml: ${prefix}.smoke ignore must be an array of strings (JSON pointers)")
				}
				for pointer in pointers {
					match JsonBody.pointer(pointer) {
						Ok(_) => {}
						Err(BadPointer) => return Err("roc-cfw.toml: ${prefix}.smoke ignore: ${pointer} is not a JSON pointer (it starts with /, for example /checked)")
					}
				}
				$ignore = pointers
			}
			("path", _) | ("status", _) | ("same-body", _) | ("ignore", _) => return Err("roc-cfw.toml: ${prefix}.smoke ${key} has the wrong type")
			_ => return Err("roc-cfw.toml: unknown key ${prefix}.smoke ${key}")
		}
	}
	if !$path.starts_with("/") {
		return Err("roc-cfw.toml: each ${prefix}.smoke item needs a path that starts with /")
	}
	if !$ignore.is_empty() and !$same {
		return Err("roc-cfw.toml: ${prefix}.smoke ${$path}: ignore needs same-body = true (a check with no same-body compares no body)")
	}
	Ok({ path: $path, status: $status.to_u16_try() ?? 200, same: $same, ignore: $ignore })
}

## A same-body try. With no ignore list: the bytes must be equal. With one: the JSON values with no value at each pointer.
same_body : Smoke, List(U8), List(U8) -> [Pass, Fail(Str)]
same_body = |smoke, before, body| {
	if smoke.ignore.is_empty() {
		return if before == body Pass else Fail("GET ${smoke.path}: the body is not the body before the deploy (${body.len().to_str()} bytes, before ${before.len().to_str()} bytes)")
	}
	tokens = smoke.ignore.keep_oks(JsonBody.pointer)
	strip = |tree| tokens.fold(tree, |t, ptr| JsonBody.drop(t, ptr))
	match (JsonBody.parse(before), JsonBody.parse(body)) {
		(_, Err(_)) => Fail("GET ${smoke.path}: the body is not JSON, and the check has an ignore list (ignore needs a JSON body)")
		(Err(_), Ok(_)) => Fail("GET ${smoke.path}: the body before the deploy is not JSON (ignore needs a JSON body)")
		(Ok(a), Ok(b)) => match JsonBody.diff(strip(a), strip(b)) {
			Ok(_) => Pass
			Err(at) => Fail("GET ${smoke.path}: the body is not the body before the deploy: it differs at ${at}")
		}
	}
}

## The text from the first `{` to the last `}`, or the whole text when it has none.
json_part : Str -> Str
json_part = |text| {
	bytes = text.to_utf8()
	match (bytes.find_first_index(|b| b == 123), bytes.find_last_index(|b| b == 125)) {
		(Ok(a), Ok(b)) if a < b => Str.from_utf8_lossy(bytes.sublist({ start: a, len: b - a + 1 }))
		_ => text
	}
}

## The text with no ANSI escape sequences (ESC `[` ... a letter).
strip_ansi : Str -> Str
strip_ansi = |text| {
	bytes = text.to_utf8()
	if !bytes.contains(27) {
		return text
	}
	var $out = []
	var $i = 0
	while $i < bytes.len() {
		b = bytes.get($i) ?? 0
		if b == 27 and bytes.get($i + 1) == Ok(91) {
			$i = $i + 2
			while $i < bytes.len() and !is_letter(bytes.get($i) ?? 65) {
				$i = $i + 1
			}
			$i = $i + 1
		} else {
			$out = $out.append(b)
			$i = $i + 1
		}
	}
	Str.from_utf8_lossy($out)
}

is_letter : U8 -> Bool
is_letter = |b| (b >= 65 and b <= 90) or (b >= 97 and b <= 122)

## Single quotes around an argument with a character that a shell reads. A `'` in it becomes `'\''`.
quote : Str -> Str
quote = |arg| {
	safe = arg != "" and arg.to_utf8().all(|b| (b >= 97 and b <= 122) or (b >= 65 and b <= 90) or (b >= 48 and b <= 57) or [45, 95, 46, 47, 58, 64, 37, 61, 44].contains(b))
	if safe arg else "'${arg.replace_each("'", "'\\''")}'"
}
