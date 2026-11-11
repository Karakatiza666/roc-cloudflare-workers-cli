app [main!] { lib: "../lib/main.roc" }

import lib.Deploy

main! = |_args| Ok({})

# Test helpers: the plan of a command line and a roc-cfw.toml text, or the message of the error.
plan_of = |toml, args| {
	f = Deploy.flags(args)?
	s = Deploy.file(toml, f.env)?
	Deploy.plan(s, f)
}

file_text = |text| Deploy.file(text, "")

is_err = |t| match t {
	Ok(_) => Bool.False
	Err(_) => Bool.True
}

err_text = |t| match t {
	Ok(_) => ""
	Err(message) => message
}

# Defaults: app.wasm (not given), percent 100, wait 5, rollback on, no checks.
expect {
	match plan_of("", []) {
		Ok(p) => p.wasm == "app.wasm" and !p.wasm_given and p.percent == 100 and p.wait == 5 and p.timeout == 30 and p.rollback and p.smoke == [] and p.migrate == [] and !p.first and !p.dry_run
		Err(_) => Bool.False
	}
}

# Flags: each value flag, the switches, --wasm sets wasm_given.
expect {
	args = ["--wasm", "w.wasm", "--config", "w.toml", "--env", "staging", "--message", "m", "--percent", "25", "--wait", "0", "--migrate", "DB", "--migrate", "LOGS", "--url", "https://a.dev", "--no-rollback", "--dry-run"]
	match plan_of("", args) {
		Ok(p) => p.wasm == "w.wasm" and p.wasm_given and p.config == "w.toml" and p.env == "staging" and p.message == "m" and p.percent == 25 and p.wait == 0 and p.migrate == ["DB", "LOGS"] and p.url == "https://a.dev" and !p.rollback and p.dry_run
		Err(_) => Bool.False
	}
}

# Smoke flags: a path alone is status 200; `=<status>` sets it; --smoke-same sets same.
expect {
	match plan_of("", ["--url", "https://a.dev", "--smoke", "/", "--smoke-same", "/v1/x.json=404"]) {
		Ok(p) => p.smoke == [{ path: "/", status: 200, same: Bool.False, ignore: [] }, { path: "/v1/x.json", status: 404, same: Bool.True, ignore: [] }]
		Err(_) => Bool.False
	}
}

# Bad smoke flags: no leading /, a status that is not an HTTP status.
expect {
	is_err(Deploy.smoke_arg("health", Bool.False)) and is_err(Deploy.smoke_arg("/=abc", Bool.False)) and is_err(Deploy.smoke_arg("/=99", Bool.False)) and is_err(Deploy.smoke_arg("/=600", Bool.False))
}

# Bad command lines: an unknown flag, a flag with no value, a percent that is not a number.
expect {
	err_text(Deploy.flags(["--bogus"])) == "unknown argument --bogus" and err_text(Deploy.flags(["--env"])) == "--env needs a value" and is_err(Deploy.flags(["--percent", "half"]))
}

# The plan refuses: percent 0 or 101, --first with a split, checks with no URL, a URL with no scheme.
expect {
	is_err(plan_of("", ["--percent", "0"])) and is_err(plan_of("", ["--percent", "101"])) and is_err(plan_of("", ["--first", "--percent", "50"])) and is_err(plan_of("", ["--smoke", "/"])) and is_err(plan_of("", ["--url", "a.dev"]))
}

# roc-cfw.toml: all keys, and [[deploy.smoke]] items with defaults.
toml_full =
	\\[deploy]
	\\url = "https://app.example.workers.dev"
	\\migrate = ["DB"]
	\\percent = 50
	\\rollback = false
	\\wait = 2
	\\
	\\[[deploy.smoke]]
	\\path = "/"
	\\
	\\[[deploy.smoke]]
	\\path = "/v1/index.json"
	\\status = 201
	\\same-body = true

expect {
	match plan_of(toml_full, []) {
		Ok(p) => p.url == "https://app.example.workers.dev" and p.migrate == ["DB"] and p.percent == 50 and !p.rollback and p.wait == 2 and p.smoke == [{ path: "/", status: 200, same: Bool.False, ignore: [] }, { path: "/v1/index.json", status: 201, same: Bool.True, ignore: [] }]
		Err(_) => Bool.False
	}
}

# Flags win over the file for one value, and add to it for a list (smoke, migrate).
expect {
	match plan_of(toml_full, ["--url", "https://other.dev", "--percent", "100", "--wait", "0", "--smoke", "/x", "--migrate", "LOGS"]) {
		Ok(p) => p.url == "https://other.dev" and p.percent == 100 and p.wait == 0 and p.smoke.len() == 3 and p.migrate == ["DB", "LOGS"]
		Err(_) => Bool.False
	}
}

# A file `rollback = true` and the flag --no-rollback: the flag wins.
expect {
	match plan_of("[deploy]\nrollback = true\n", ["--no-rollback"]) {
		Ok(p) => !p.rollback
		Err(_) => Bool.False
	}
}

# roc-cfw.toml errors: an unknown key (a typo of same-body), an unknown top table, a wrong type, a path with no /, bad TOML.
expect {
	typo = err_text(file_text("[[deploy.smoke]]\npath = \"/\"\nsame_body = true\n"))
	top = err_text(file_text("[deplyo]\nurl = \"https://a\"\n"))
	type = err_text(file_text("[deploy]\npercent = \"50\"\n"))
	path = err_text(file_text("[[deploy.smoke]]\npath = \"x\"\n"))
	bad = err_text(file_text("[deploy\n"))
	typo.contains("unknown key deploy.smoke same_body") and top.contains("unknown table or key deplyo") and type.contains("deploy.percent has the wrong type") and path.contains("starts with /") and bad.contains("does not parse: line 1")
}

# The default message: version and commit, -dirty for changes, no commit with no git.
expect {
	Deploy.message({ version: "0.0.2", commit: "abc1234", dirty: Bool.False }) == "roc-cfw 0.0.2 abc1234"
		and Deploy.message({ version: "0.0.2", commit: "abc1234", dirty: Bool.True }) == "roc-cfw 0.0.2 abc1234-dirty"
			and Deploy.message({ version: "0.0.2", commit: "", dirty: Bool.True }) == "roc-cfw 0.0.2"
}

# The age check: a source newer than the wasm fails and names the newest; equal times pass.
expect {
	fresh = Deploy.stale(100, [("main.roc", 90), ("lib/A.roc", 100)])
	old = Deploy.stale(100, [("main.roc", 90), ("lib/A.roc", 101), ("lib/B.roc", 150)])
	fresh == Ok({}) and old == Err("lib/B.roc")
}

expect Deploy.skip_dir(".git") and Deploy.skip_dir(".roc-cfw") and Deploy.skip_dir("node_modules") and !Deploy.skip_dir("lib")

# The live version: one version with all traffic. Extra fields, nested objects, null and text before the JSON are ignored.
expect {
	one = Deploy.live("{\"id\":\"d1\",\"source\":\"api\",\"versions\":[{\"version_id\":\"v-old\",\"percentage\":100}]}")
	full =
		\\{
		\\  "id": "dep-1",
		\\  "source": "wrangler",
		\\  "strategy": "percentage",
		\\  "author_email": "a@b.c",
		\\  "created_on": "2026-11-01T00:00:00Z",
		\\  "annotations": { "workers/message": "roc-cfw 0.0.2 abc", "workers/triggered_by": "deployment" },
		\\  "tag": null,
		\\  "versions": [ { "version_id": "v-9", "percentage": 100.0 } ]
		\\}
	noisy = "Some notice from wrangler\n${full}\n"
	one == Ok("v-old") and Deploy.live(full) == Ok("v-9") and Deploy.live(noisy) == Ok("v-9")
}

# A gradual deploy in progress (two versions): no single rollback target. Split names each version with its percent.
expect {
	two = Deploy.live("{\"versions\":[{\"version_id\":\"a\",\"percentage\":10},{\"version_id\":\"b\",\"percentage\":90}]}")
	two == Err(Split([("b", "90"), ("a", "10")]))
}

# The message of a split: the versions, and the commands that finish or undo the gradual deploy. --env and --config are in each command.
expect {
	match plan_of("", ["--env", "staging"]) {
		Ok(p) => {
			text = Deploy.split_message(p, [("b", "90"), ("a", "10.5")])
			text.contains("b 90%, a 10.5%") and text.contains("wrangler versions deploy b@100% --yes --env staging") and text.contains("wrangler versions deploy a@100% --yes --env staging") and text.contains("Nothing changed")
		}
		Err(_) => Bool.False
	}
}

# No live version: not JSON, no versions.
expect is_err(Deploy.live("The Worker x has no deployments.")) and is_err(Deploy.live("{\"versions\":[]}"))

# --first: a status read that shows a live version stops the deploy (it would lose the rollback target). Else go on.
expect Deploy.first_check(0, "{\"versions\":[{\"version_id\":\"v-1\",\"percentage\":100}]}") == Err("v-1") and Deploy.first_check(1, "") == Ok({}) and Deploy.first_check(0, "no JSON") == Ok({})

# The new version id from the output of versions upload.
expect {
	out = "Total Upload: 12 KiB\nWorker Startup Time: 3 ms\nUploaded app (1.2 sec)\nWorker Version ID: 1a2b-3c\nVersion Preview URL: https://x\n"
	Deploy.version_id(out) == Ok("1a2b-3c") and is_err(Deploy.version_id("Uploaded app\n")) and is_err(Deploy.version_id("Worker Version ID: \n"))
}

# The wrangler commands: --env and --config go to each one.
expect {
	match plan_of("", ["--env", "staging", "--config", "w.toml"]) {
		Ok(p) => {
			tail = ["--env", "staging", "--config", "w.toml"]
			Deploy.status_args(p) == ["deployments", "status", "--json"].concat(tail)
				and Deploy.upload_args(p, "m") == ["versions", "upload", "--message", "m"].concat(tail)
					and Deploy.deploy_args(p, { new: "N", old: "O", message: "m" }) == ["versions", "deploy", "N@100%", "--message", "m", "--yes"].concat(tail)
						and Deploy.rollback_args(p, "O", "r") == ["rollback", "O", "--message", "r", "--yes"].concat(tail)
							and Deploy.migrations_args(p, List, "DB") == ["d1", "migrations", "list", "DB", "--remote"].concat(tail)
								and Deploy.migrations_args(p, Apply, "DB") == ["d1", "migrations", "apply", "DB", "--remote"].concat(tail)
									and Deploy.dry_run_args(p) == ["deploy", "--dry-run"].concat(tail)
										and Deploy.sync_args(p, "main.roc") == ["--file", "main.roc", "--wasm", "app.wasm", "--check", "--config", "w.toml"]
		}
		Err(_) => Bool.False
	}
}

# A gradual deploy: new@p% old@(100-p)%. With no old version: new@100%.
expect {
	match plan_of("", ["--percent", "10"]) {
		Ok(p) => Deploy.deploy_args(p, { new: "N", old: "O", message: "m" }) == ["versions", "deploy", "N@10%", "O@90%", "--message", "m", "--yes"]
			and Deploy.deploy_args(p, { new: "N", old: "", message: "m" }) == ["versions", "deploy", "N@100%", "--message", "m", "--yes"]
		Err(_) => Bool.False
	}
}

# The printed command: quotes only where a shell needs them.
expect Deploy.shell("wrangler", ["rollback", "v-1", "--message", "roc-cfw: it's bad"]) == "wrangler rollback v-1 --message 'roc-cfw: it'\\''s bad'"

expect Deploy.url_of("https://a.dev/", "/x") == "https://a.dev/x" and Deploy.url_of("https://a.dev", "/") == "https://a.dev/"

# A smoke try: the status, then the body when same.
expect {
	plain = { path: "/", status: 200, same: Bool.False, ignore: [] }
	same = { path: "/s", status: 200, same: Bool.True, ignore: [] }
	ok = Deploy.judge({ smoke: plain, before: None, got: Got({ status: 200, body: [1] }) }) == Pass
	status = Deploy.judge({ smoke: plain, before: None, got: Got({ status: 500, body: [] }) }) == Fail("GET /: status 500, expected 200")
	net = Deploy.judge({ smoke: plain, before: None, got: Failed("no answer") }) == Fail("GET /: no answer")
	equal = Deploy.judge({ smoke: same, before: Some([1, 2]), got: Got({ status: 200, body: [1, 2] }) }) == Pass
	differ = match Deploy.judge({ smoke: same, before: Some([1, 2]), got: Got({ status: 200, body: [1, 3] }) }) {
		Fail(why) => why.contains("not the body before the deploy")
		Pass => Bool.False
	}
	# Not a same check: another body passes.
	other = Deploy.judge({ smoke: plain, before: Some([1]), got: Got({ status: 200, body: [2] }) }) == Pass
	ok and status and net and equal and differ and other
}

# After the checks: done, rollback, or keep (no rollback flag, or no target).
expect {
	Deploy.after_smoke({ failed: 0, rollback: Bool.True, target: Bool.True }) == Done
		and Deploy.after_smoke({ failed: 1, rollback: Bool.True, target: Bool.True }) == Rollback
			and Deploy.after_smoke({ failed: 1, rollback: Bool.False, target: Bool.True }) == Keep
				and Deploy.after_smoke({ failed: 2, rollback: Bool.True, target: Bool.False }) == Keep
}

expect Deploy.exit_of(Done) == 0 and Deploy.exit_of(RolledBack) == 3 and Deploy.exit_of(Kept) == 4 and Deploy.exit_of(RollbackFailed) == 4

# ---- 0.0.3 ----

# The version id line with color codes (a wrangler with FORCE_COLOR).
expect Deploy.version_id("\u(1b)[2mUploaded app\u(1b)[22m\n\u(1b)[1mWorker Version ID:\u(1b)[22m 7f3e-11\n") == Ok("7f3e-11")

# The pending migrations from the output of `wrangler d1 migrations list` (a cli-table3 table, with and with no color codes).
list_two =
	\\
	\\ ⛅️ wrangler 4.151.0
	\\───────────────────
	\\Resource location: remote
	\\Migrations to be applied:
	\\┌────────────────────┐
	\\│ Name               │
	\\├────────────────────┤
	\\│ 0002_add_index.sql │
	\\├────────────────────┤
	\\│ 0003_users.sql     │
	\\└────────────────────┘

expect Deploy.pending(list_two) == Ok(["0002_add_index.sql", "0003_users.sql"])
expect Deploy.pending("Migrations to be applied:\n\u(1b)[90m┌──────┐\u(1b)[39m\n\u(1b)[90m│\u(1b)[39m \u(1b)[34mName\u(1b)[39m \u(1b)[90m│\u(1b)[39m\n\u(1b)[90m│\u(1b)[39m 0001_a.sql \u(1b)[90m│\u(1b)[39m\n") == Ok(["0001_a.sql"])
expect Deploy.pending(" ⛅️ wrangler 4.151.0\n✅ No migrations to apply!\n") == Ok([])
# An output that says neither: Unknown (the deploy cannot verify, so it stops).
expect Deploy.pending("X [ERROR] Couldn't find a D1 DB\n") == Err(Unknown) and Deploy.pending("Migrations to be applied:\n") == Err(Unknown)

# The note before an apply: the names, and that migrations are forward-only.
expect {
	text = Deploy.migration_note("DB", ["0002_a.sql", "0003_b.sql"])
	text.contains("DB: 2 pending migrations: 0002_a.sql, 0003_b.sql") and text.contains("forward-only") and text.contains("does not undo")
}

# The schema line of the end report: the applied migrations stay after a rollback. Empty when none was applied.
expect {
	Deploy.schema_note([]) == "" and Deploy.schema_note(["DB 0002_a.sql", "LOGS 0001_l.sql"]).contains("DB 0002_a.sql, LOGS 0001_l.sql")
		and Deploy.schema_note(["DB 0002_a.sql"]).contains("forward-only")
}

# ignore in [[deploy.smoke]]: JSON pointers of members that the same-body check does not compare.
expect {
	toml = "[deploy]\nurl = \"https://a.dev\"\n\n[[deploy.smoke]]\npath = \"/v1/p.json\"\nsame-body = true\nignore = [\"/checked\", \"/meta/time\"]\n"
	match plan_of(toml, []) {
		Ok(p) => p.smoke == [{ path: "/v1/p.json", status: 200, same: Bool.True, ignore: ["/checked", "/meta/time"] }]
		Err(_) => Bool.False
	}
}

# ignore errors: with no same-body (a status-only check compares no body), a pointer with no leading /, not strings.
expect {
	no_same = err_text(file_text("[[deploy.smoke]]\npath = \"/x\"\nignore = [\"/a\"]\n"))
	no_slash = err_text(file_text("[[deploy.smoke]]\npath = \"/x\"\nsame-body = true\nignore = [\"checked\"]\n"))
	type = err_text(file_text("[[deploy.smoke]]\npath = \"/x\"\nsame-body = true\nignore = [1]\n"))
	no_same.contains("ignore needs same-body = true") and no_slash.contains("checked is not a JSON pointer") and type.contains("ignore must be an array of strings")
}

# A same-body try with an ignore list: a difference only in an ignored member passes; another difference fails with its pointer.
expect {
	check = { path: "/p", status: 200, same: Bool.True, ignore: ["/checked"] }
	before = "{\"v\":[1,2],\"checked\":{\"checked_at\":\"10:00\",\"stale\":false}}".to_utf8()
	later = "{\"v\":[1,2],\"checked\":{\"checked_at\":\"11:00\",\"stale\":true}}".to_utf8()
	changed = "{\"v\":[1,3],\"checked\":{\"checked_at\":\"10:00\",\"stale\":false}}".to_utf8()
	pass = Deploy.judge({ smoke: check, before: Some(before), got: Got({ status: 200, body: later }) }) == Pass
	fail = Deploy.judge({ smoke: check, before: Some(before), got: Got({ status: 200, body: changed }) }) == Fail("GET /p: the body is not the body before the deploy: it differs at /v/1")
	pass and fail
}

# A same-body try with an ignore list and a body that is not JSON: a clear failure.
expect {
	check = { path: "/p", status: 200, same: Bool.True, ignore: ["/checked"] }
	Deploy.judge({ smoke: check, before: Some("{}".to_utf8()), got: Got({ status: 200, body: "<html>".to_utf8() }) }) == Fail("GET /p: the body is not JSON, and the check has an ignore list (ignore needs a JSON body)")
}

# The before read of a check with an ignore list must be JSON: else the deploy stops before a change.
expect {
	check = { path: "/p", status: 200, same: Bool.True, ignore: ["/checked"] }
	plain = { path: "/q", status: 200, same: Bool.True, ignore: [] }
	Deploy.before_check(check, "{\"a\":1}".to_utf8()) == Ok({})
		and err_text(Deploy.before_check(check, "ok".to_utf8())).contains("GET /p: the body is not JSON")
			and Deploy.before_check(plain, "ok".to_utf8()) == Ok({})
}

# The HTTP time limit of one try: --timeout and the timeout key, default 30, 0 is an error.
expect {
	flag = match plan_of("[deploy]\ntimeout = 10\n", ["--timeout", "5"]) {
		Ok(p) => p.timeout == 5
		Err(_) => Bool.False
	}
	file = match plan_of("[deploy]\ntimeout = 10\n", []) {
		Ok(p) => p.timeout == 10
		Err(_) => Bool.False
	}
	flag and file and is_err(plan_of("", ["--timeout", "0"])) and is_err(plan_of("[deploy]\ntimeout = 0\n", []))
}

# [deploy.env.<name>]: with --env <name>, its keys replace the keys of [deploy]. Other env tables are checked but not used.
toml_envs =
	\\[deploy]
	\\url = "https://app.example.workers.dev"
	\\migrate = ["DB"]
	\\
	\\[[deploy.smoke]]
	\\path = "/"
	\\
	\\[deploy.env.staging]
	\\url = "https://app-staging.example.workers.dev"
	\\percent = 50
	\\
	\\[[deploy.env.staging.smoke]]
	\\path = "/health"
	\\
	\\[deploy.env.dev]
	\\url = "https://app-dev.example.workers.dev"

expect {
	staging = match plan_of(toml_envs, ["--env", "staging"]) {
		Ok(p) => p.url == "https://app-staging.example.workers.dev" and p.percent == 50 and p.migrate == ["DB"] and p.smoke == [{ path: "/health", status: 200, same: Bool.False, ignore: [] }]
		Err(_) => Bool.False
	}
	base = match plan_of(toml_envs, []) {
		Ok(p) => p.url == "https://app.example.workers.dev" and p.percent == 100 and p.smoke.len() == 1
		Err(_) => Bool.False
	}
	staging and base
}

# --env with smoke checks and only the url of [deploy]: an error (the checks would read the Worker with no env). --url fixes it.
expect {
	toml = "[deploy]\nurl = \"https://app.example.workers.dev\"\n\n[[deploy.smoke]]\npath = \"/\"\n"
	err_text(plan_of(toml, ["--env", "staging"])).contains("[deploy.env.staging]")
		and !is_err(plan_of(toml, ["--env", "staging", "--url", "https://s.dev"]))
			and !is_err(plan_of("[deploy]\nurl = \"https://a.dev\"\n", ["--env", "staging"]))
}

# Env table errors: an unknown key in it, an env that is not a table, an env table in an env table.
expect {
	unknown = err_text(file_text("[deploy.env.staging]\nurll = \"https://a\"\n"))
	not_table = err_text(file_text("[deploy]\nenv = 1\n"))
	nested = err_text(file_text("[deploy.env.staging.env.x]\nurl = \"https://a\"\n"))
	unknown.contains("unknown key deploy.env.staging.urll") and not_table.contains("deploy.env") and nested.contains("deploy.env.staging.env")
}

# The dry-run plan: one line for each setting and each check, the migrations, and the rollback.
expect {
	toml = "[deploy]\nurl = \"https://a.dev\"\nmigrate = [\"DB\"]\n\n[[deploy.smoke]]\npath = \"/\"\n\n[[deploy.smoke]]\npath = \"/p\"\nsame-body = true\nignore = [\"/checked\"]\n"
	match plan_of(toml, ["--env", "staging", "--url", "https://s.dev", "--percent", "10"]) {
		Ok(p) => {
			lines = Deploy.plan_lines(p, "m1")
			lines.contains("message:    m1")
				and lines.contains("env:        staging")
					and lines.contains("traffic:    new version 10%, live version 90%")
						and lines.contains("migrations: DB (pending list and apply after the upload; forward-only)")
							and lines.contains("smoke:      GET https://s.dev/ status 200")
								and lines.contains("smoke:      GET https://s.dev/p status 200, same body, ignore /checked")
									and lines.contains("rollback:   on (to the live version, when a smoke check fails)")
		}
		Err(_) => Bool.False
	}
}

# The dry-run plan with --first and no checks.
expect {
	match plan_of("", ["--first"]) {
		Ok(p) => {
			lines = Deploy.plan_lines(p, "m")
			lines.contains("rollback:   none (--first: no live version)") and lines.contains("smoke:      none") and lines.contains("migrations: none")
		}
		Err(_) => Bool.False
	}
}

# --first and a failed smoke check: the next commands (delete the Worker, or deploy a fix), with --env and --config.
expect {
	match plan_of("", ["--first", "--env", "staging", "--config", "w.toml"]) {
		Ok(p) => {
			lines = Deploy.first_next(p)
			lines.any(|l| l.contains("wrangler delete --env staging --config w.toml")) and lines.any(|l| l.contains("roc-cfw deploy"))
		}
		Err(_) => Bool.False
	}
}

# The percent text: a whole number with no decimals.
expect Deploy.percent_text(90) == "90" and Deploy.percent_text(10.5) == "10.5" and Deploy.percent_text(100.0) == "100"
