app [main!] { lib: "../lib/main.roc" }

import lib.Deploy

main! = |_args| Ok({})

# Test helpers: the plan of a command line and a roc-cfw.toml text, or the message of the error.
plan_of = |toml, args| {
	s = Deploy.file(toml)?
	f = Deploy.flags(args)?
	Deploy.plan(s, f)
}

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
		Ok(p) => p.wasm == "app.wasm" and !p.wasm_given and p.percent == 100 and p.wait == 5 and p.rollback and p.smoke == [] and p.migrate == [] and !p.first and !p.dry_run
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
		Ok(p) => p.smoke == [{ path: "/", status: 200, same: Bool.False }, { path: "/v1/x.json", status: 404, same: Bool.True }]
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
		Ok(p) => p.url == "https://app.example.workers.dev" and p.migrate == ["DB"] and p.percent == 50 and !p.rollback and p.wait == 2 and p.smoke == [{ path: "/", status: 200, same: Bool.False }, { path: "/v1/index.json", status: 201, same: Bool.True }]
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
	typo = err_text(Deploy.file("[[deploy.smoke]]\npath = \"/\"\nsame_body = true\n"))
	top = err_text(Deploy.file("[deplyo]\nurl = \"https://a\"\n"))
	type = err_text(Deploy.file("[deploy]\npercent = \"50\"\n"))
	path = err_text(Deploy.file("[[deploy.smoke]]\npath = \"x\"\n"))
	bad = err_text(Deploy.file("[deploy\n"))
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

# The live version: the version with the most traffic; split when there are two; extra fields are ignored.
expect {
	one = Deploy.live("{\"id\":\"d1\",\"source\":\"api\",\"versions\":[{\"version_id\":\"v-old\",\"percentage\":100}]}")
	two = Deploy.live("{\"versions\":[{\"version_id\":\"a\",\"percentage\":10},{\"version_id\":\"b\",\"percentage\":90}]}")
	one == Ok({ id: "v-old", percent: 100, split: Bool.False }) and two == Ok({ id: "b", percent: 90, split: Bool.True })
}

# No live version: not JSON, no versions.
expect is_err(Deploy.live("The Worker x has no deployments.")) and is_err(Deploy.live("{\"versions\":[]}"))

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
	plain = { path: "/", status: 200, same: Bool.False }
	same = { path: "/s", status: 200, same: Bool.True }
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
