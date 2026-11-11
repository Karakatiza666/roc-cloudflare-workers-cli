app [main!] {
	http: "https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
	lib: "lib/main.roc",
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	roc: "nightly-2026-10-14-38a3029",
}

import pf.Cmd
import pf.Env
import pf.Http
import pf.OsStr
import pf.Path
import pf.Random
import pf.Sleep
import pf.Stderr
import pf.Stdout
import http.Request
import lib.Args
import lib.Cfw
import lib.Deploy
import lib.Platform
import lib.Scaffold

## `roc-cfw`: the helper CLI of the Roc platform for Cloudflare Workers (README.md).
## The decisions are in `lib/` (tested with `roc test`). This file holds the effects and the order of the steps.

Opts : { cmd : [Help, Shim, Sync, Init, Deploy], file : Str, js : [Auto, Dir(Str)], name : [Auto, Named(Str)], rest : List(Str) }

Want : [Hash(Str), Always]

Entry : [Url({ hash : Str }), Path(Str)]

main! : List(OsStr) => Try({}, _)
main! = |os_args| {
	argv = os_args.map(|a| OsStr.display(a))
	opts = match Args.parse(argv) {
		Ok(parsed) => parsed
		Err(message) => return die!(2, message)
	}
	match opts.cmd {
		Help => {
			_ = Stdout.write!(Args.usage)
			Ok({})
		}
		Shim => {
			_ = prepare!(opts)?
			Ok({})
		}
		Sync => {
			prepared = prepare!(opts)?
			run_node!(Args.sync_args({ file: opts.file, file_exists: exists!(opts.file), rest: opts.rest }), prepared.js)
		}
		Init => init!(opts)
		Deploy => deploy!(opts)
	}
}

# ---- The effects ----

note! : Str => {}
note! = |message| {
	_ = Stderr.write!("roc-cfw: ${message}\n")
	{}
}

die! : I32, Str => Try(a, [Exit(I32)])
die! = |code, message| {
	note!(message)
	Err(Exit(code))
}

read! : Str => Try(Str, [Missing])
read! = |path| match Path.read_utf8!(Path.utf8(path)) {
	Ok(text) => Ok(text)
	Err(_) => Err(Missing)
}

is_dir! : Str => Bool
is_dir! = |path| match Path.is_dir!(Path.utf8(path)) {
	Ok(found) => found
	Err(_) => Bool.False
}

exists! : Str => Bool
exists! = |path| match Path.exists!(Path.utf8(path)) {
	Ok(found) => found
	Err(_) => Bool.False
}

## A command of basic-cli from the program and the arguments, as text.
command : Str, List(Str) -> Cmd.Command
command = |program, args| Cmd.new(OsStr.from_str(program)).args(args.map(OsStr.from_str))

env_or_empty! : Str => Str
env_or_empty! = |name| match Env.var_str!(OsStr.from_str(name)) {
	Ok(value) => value
	Err(_) => ""
}

# ---- The directory of the platform ----

## The one place that finds the directory of the platform of an app (`pf`).
## First `tln path <alias> --file <app file>` (Talon R-PTH1): its one stdout line is the directory. Talon fetches a missing package.
## When `tln` is not on PATH, or exits non-zero, or gives no directory: the cache rule, with one note line on stderr.
## The rule: compute `$XDG_CACHE_HOME/roc/packages/<hash>/`, and run `roc check <app>` when it is missing.
platform_dir! : { entry : Entry, alias : Str, file : Str, app_dir : Str } => Try(Str, [Exit(I32)])
platform_dir! = |args| match tln_path!({ alias: args.alias, file: args.file }) {
	Ok(dir) => Ok(dir)
	Err(why) => {
		note!(Platform.fallback_note({ alias: args.alias, why }))
		cache_dir!(args)
	}
}

## The directory from `tln path`, or the reason why there is none.
tln_path! : { alias : Str, file : Str } => Try(Str, [NoTln, Failed(I32), BadOutput])
tln_path! = |args| {
	cmd = command("tln", Platform.tln_args(args)).stdin(Null).stdout(Capture).stderr(Inherit)
	out = match cmd.run!() {
		Ok(o) => o
		Err(_) => return Err(NoTln)
	}
	match out.status {
		Exited(0) => {}
		Exited(code) => return Err(Failed(code))
		Signaled(signal) => return Err(Failed(128 + signal))
	}
	text = match Str.from_utf8(out.stdout_bytes) {
		Ok(t) => t
		Err(_) => return Err(BadOutput)
	}
	match Platform.tln_dir(text) {
		Ok(dir) if is_dir!(dir) => Ok(dir)
		_ => Err(BadOutput)
	}
}

## The cache rule of TRANSITION 9 row 1.
cache_dir! : { entry : Entry, alias : Str, file : Str, app_dir : Str } => Try(Str, [Exit(I32)])
cache_dir! = |args| match args.entry {
	Path(_) => Ok(Platform.path_dir({ app_dir: args.app_dir, entry: path_value(args.entry) }))
	Url({ hash }) => {
		dir = Platform.package_dir({ xdg: env_or_empty!("XDG_CACHE_HOME"), home: env_or_empty!("HOME"), hash })
		if is_dir!(dir) {
			Ok(dir)
		} else {
			note!("the platform is not in the cache: roc check ${args.file}")
			_ = command("roc", ["check", args.file]).stdin(Null).stdout(Inherit).stderr(Inherit).run!()
			if is_dir!(dir) Ok(dir) else die!(1, "the platform ${hash} is not in ${dir}, also after roc check ${args.file}")
		}
	}
}

path_value : Entry -> Str
path_value = |entry| match entry {
	Path(value) => value
	Url(_) => ""
}

# ---- shim ----

## The steps that `shim` and `sync` share (TRANSITION 5): header, directory, api, copy.
prepare! : Opts => Try({ js : Str, app_dir : Str, entry : Entry }, [Exit(I32)])
prepare! = |opts| {
	found = locate!(opts)?
	install!({ js: found.js, want: Platform.want_of(found.entry, opts.js) })?
	Ok(found)
}

## The header, the directory of `js/`, and the api check. It writes nothing.
locate! : Opts => Try({ js : Str, app_dir : Str, entry : Entry }, [Exit(I32)])
locate! = |opts| {
	text = match read!(opts.file) {
		Ok(t) => t
		Err(_) => return die!(2, "cannot read ${opts.file}: run in the project directory, or use --file")
	}
	entry = match Platform.source(text) {
		Ok(e) => e
		Err(NoHeader) => return die!(2, "${opts.file} has no header")
		Err(BadHeader) => return die!(2, "${opts.file}: the header cannot be read")
		Err(NotApp) => return die!(2, "${opts.file} is not an app")
		Err(NoPlatform) => return die!(2, "${opts.file} has no platform entry in its header")
		Err(ForeignUrl(url)) => return die!(2, "the platform URL ${url} is not a roc release URL")
	}
	app_dir = Platform.dir_of_file(opts.file)
	js = match opts.js {
		Dir(dir) => dir
		Auto => {
			alias = Platform.alias(text) ?? "pf"
			dir = platform_dir!({ entry, alias, file: opts.file, app_dir })?
			"${dir}/js"
		}
	}
	cfw = match read!("${js}/cfw.json") {
		Ok(t) => t
		Err(_) => return die!(1, "no cfw.json in ${js}: this platform release has no contract with roc-cfw")
	}
	match Cfw.check(cfw) {
		Ok(_) => Ok({ js, app_dir, entry })
		Err(BadCfw) => die!(1, "${js}/cfw.json has no api number")
		Err(UnknownApi(api)) => {
			known = Str.join_with(Cfw.supported.map(|n| n.to_str()), ", ")
			die!(2, "${Cfw.update_message} (the platform has api ${api.to_str()}, this version knows: ${known})")
		}
	}
}

## Copies `js/` to `.roc-cfw/` through a temp directory and a rename, when the stamp is not the hash of the platform.
install! : { js : Str, want : Want } => Try({}, [Exit(I32)])
install! = |args| {
	stamp = match read!(".roc-cfw/.platform") {
		Ok(t) => t
		Err(_) => ""
	}
	if !Cfw.needs_copy(stamp, args.want) {
		note!(".roc-cfw is up to date")
		return Ok({})
	}
	n = match Random.seed_u64!() {
		Ok(seed) => seed
		Err(_) => 0
	}
	tmp = ".roc-cfw.tmp-${n.to_str()}"
	fail! = |message| {
		_ = Path.delete_all!(Path.utf8(tmp))
		die!(1, message)
	}
	match Path.copy_dir_with!(Path.utf8(args.js), Path.utf8(tmp), { symlinks: Follow, destination: RequireNew }) {
		Ok(_) => {}
		Err(CopyErr(e)) => return fail!("cannot copy ${args.js}: ${Str.inspect(e.error)}")
	}
	match Path.write_utf8!(Path.utf8("${tmp}/.platform"), Cfw.stamp_text(args.want)) {
		Ok(_) => {}
		Err(_) => return fail!("cannot write ${tmp}/.platform")
	}
	_ = Path.delete_all!(Path.utf8(".roc-cfw"))
	match Path.rename!(Path.utf8(tmp), Path.utf8(".roc-cfw")) {
		Ok(_) => {
			note!("copied ${args.js} to .roc-cfw")
			Ok({})
		}
		Err(_) => fail!("cannot rename ${tmp} to .roc-cfw")
	}
}

# ---- sync ----

## `node .roc-cfw/cli.mjs sync [args]` (`Args.sync_args`) with the terminal of the process. The exit code of node is the exit code of the helper.
run_node! : List(Str), Str => Try({}, [Exit(I32)])
run_node! = |args, _js| {
	cmd = command("node", [".roc-cfw/cli.mjs", "sync"].concat(args)).stdin(Inherit).stdout(Inherit).stderr(Inherit)
	match cmd.run!() {
		Ok(out) => match out.status {
			Exited(0) => Ok({})
			Exited(code) => Err(Exit(code))
			Signaled(signal) => Err(Exit(128 + signal))
		}
		Err(_) => die!(2, "cannot start node: is it on PATH?")
	}
}

# ---- init ----

## `init` (TRANSITION 5, study 6.1). All texts are made first: when one file cannot be made, nothing is written.
init! : Opts => Try({}, [Exit(I32)])
init! = |opts| {
	found = locate!(opts)?
	tdir = "${found.js}/template"
	template! = |name| match read!("${tdir}/${name}") {
		Ok(t) => Ok(t)
		Err(_) => Err(name)
	}
	t_app = match template!("main.roc") {
		Ok(t) => t
		Err(name) => return die!(1, "no ${name} in ${tdir}")
	}
	t_wrangler = match template!("wrangler.toml") {
		Ok(t) => t
		Err(name) => return die!(1, "no ${name} in ${tdir}")
	}
	t_talon = match template!("talon.toml") {
		Ok(t) => t
		Err(name) => return die!(1, "no ${name} in ${tdir}")
	}
	t_ignore = match template!(".gitignore") {
		Ok(t) => t
		Err(name) => return die!(1, "no ${name} in ${tdir}")
	}
	dir = found.app_dir
	wrangler_path = "${dir}/wrangler.toml"
	talon_path = "${dir}/talon.toml"
	ignore_path = "${dir}/.gitignore"
	if exists!(wrangler_path) {
		return die!(1, "${wrangler_path} is there already: init writes no file over another")
	}
	name = match opts.name {
		Named(given) => if Scaffold.valid_name(given) given else return die!(2, "the name ${given} is not a Worker name (a-z, 0-9, -)")
		Auto => Scaffold.name_of_dir(dir_name!(dir))
	}
	app_text = match read!(opts.file) {
		Ok(t) => t
		Err(_) => return die!(2, "cannot read ${opts.file}")
	}
	new_app = match Scaffold.app_file({ existing: app_text, template: t_app }) {
		Ok(t) => t
		Err(NotStub) => return die!(1, "${opts.file} has an app body already: init replaces only the stub body (crash \"write the app\")")
		Err(_) => return die!(1, "the header of ${opts.file} or of the template cannot be read")
	}
	merged = match Scaffold.scripts({ existing: read_or_empty!(talon_path), template: t_talon }) {
		Ok(m) => m
		Err(BadToml(e)) => return die!(1, "${talon_path} does not parse: line ${e.line.to_str()}, column ${e.column.to_str()}: ${e.message}")
		Err(ScriptsNotTable) => return die!(1, "${talon_path} has a scripts key that is not a table")
		Err(NoScripts) => return die!(1, "the template talon.toml has no [scripts] table")
		Err(BadTemplate) => return die!(1, "the template talon.toml does not parse")
	}
	new_talon = merged.text
	new_ignore = Scaffold.gitignore({ existing: read_or_empty!(ignore_path), template: t_ignore })
	files = [
		(wrangler_path, Scaffold.wrangler({ template: t_wrangler, name })),
		(talon_path, new_talon),
		(ignore_path, new_ignore),
		(opts.file, new_app),
	]
	for (path, content) in files {
		match Path.write_utf8!(Path.utf8(path), content) {
			Ok(_) => {}
			Err(_) => return die!(1, "cannot write ${path}")
		}
	}
	for key in merged.kept {
		_ = Stderr.write!("${Scaffold.kept_note(key)}\n")
	}
	note!("wrote ${opts.file}, ${wrangler_path} (name ${name}), ${talon_path}, ${ignore_path}")
	note!("next: tln run build")
	Ok({})
}

read_or_empty! : Str => Str
read_or_empty! = |path| match read!(path) {
	Ok(text) => text
	Err(_) => ""
}

## The name of a directory (its last part, with the links and `.` resolved).
dir_name! : Str => Str
dir_name! = |dir| {
	full = match Path.canonicalize!(Path.utf8(dir)) {
		Ok(p) => p.display()
		Err(_) => dir
	}
	match full.split_on("/").last() {
		Ok(last) => last
		Err(_) => ""
	}
}

# ---- deploy ----

## `deploy` (docs/deploy.md). The decisions are in `lib/Deploy.roc`. A failure before step 5 changes nothing remote.
deploy! : Opts => Try({}, [Exit(I32)])
deploy! = |opts| {
	settings = match Deploy.file(read_or_empty!("roc-cfw.toml")) {
		Ok(s) => s
		Err(message) => return die!(2, message)
	}
	given = match Deploy.flags(opts.rest) {
		Ok(f) => f
		Err(message) => return die!(2, message)
	}
	p = match Deploy.plan(settings, given) {
		Ok(x) => x
		Err(message) => return die!(2, message)
	}

	# 1. Preflight: local only.
	if !exists!(p.wasm) {
		return die!(1, "${p.wasm} is not there: build the app first (tln run check). Nothing changed.")
	}
	if p.wasm_given {
		note!("preflight: ${p.wasm} was given with --wasm, so its age is not checked")
	} else {
		wasm_time = match Path.time_modified!(Path.utf8(p.wasm)) {
			Ok(t) => t.to_nanos_since_epoch()
			Err(_) => return die!(1, "cannot read the time of ${p.wasm}")
		}
		match Deploy.stale(wasm_time, roc_files!(Platform.dir_of_file(opts.file))) {
			Ok(_) => {}
			Err(source) => return die!(1, "${p.wasm} is older than ${source}: build it again (tln run check). Nothing changed.")
		}
	}
	prepared = prepare!(opts)?
	note!("preflight: node .roc-cfw/cli.mjs sync ${Str.join_with(Deploy.sync_args(p, opts.file), " ")}")
	match run_node!(Deploy.sync_args(p, opts.file), prepared.js) {
		Ok(_) => {}
		Err(Exit(code)) => {
			note!("preflight failed (sync --check exit ${code.to_str()}). Nothing changed.")
			return Err(Exit(code))
		}
	}
	message = if p.message != "" p.message else default_message!({})

	if p.dry_run {
		note!("dry run: message \"${message}\", percent ${p.percent.to_str()}, migrations: ${list_text(p.migrate)}, smoke checks: ${p.smoke.len().to_str()}")
		r = wrangler!(Deploy.dry_run_args(p), Inherit)?
		if r.code != 0 {
			return die!(1, "wrangler deploy --dry-run exited with ${r.code.to_str()}")
		}
		_ = Stdout.line!("deploy: dry run passed. Nothing changed.")
		return Ok({})
	}

	# 2. The live version: the rollback target.
	old = if p.first {
		note!("--first: no live version is read, so there is no rollback target")
		""
	} else {
		r = wrangler!(Deploy.status_args(p), Capture)?
		if r.code != 0 {
			return die!(1, "wrangler deployments status exited with ${r.code.to_str()}: cannot read the live version. Nothing changed. For the first deploy of a Worker, use --first.")
		}
		match Deploy.live(r.out) {
			Ok(v) => {
				if v.split {
					note!("the live deployment has more than one version: the target is ${v.id} (${v.percent.to_str()}%)")
				}
				v.id
			}
			Err(_) => return die!(1, "no version in the output of wrangler deployments status --json. Nothing changed. For the first deploy of a Worker, use --first.")
		}
	}
	rollback_line = if old == "" "none (no live version)" else Deploy.shell("wrangler", Deploy.rollback_args(p, old, "roc-cfw rollback"))
	if old != "" {
		note!("live version: ${old} (the rollback target)")
		note!("rollback command: ${rollback_line}")
	}

	# 3. The before reads of the same-body checks.
	var $befores = []
	for check in p.smoke {
		before = if check.same and old != "" {
			url = Deploy.url_of(p.url, check.path)
			match get!(url) {
				Got(r) if r.status == check.status => Some(r.body)
				Got(r) => return die!(1, "before the deploy, GET ${check.path} gave status ${r.status.to_str()}, not ${check.status.to_str()}: the same-body check needs a good answer to compare. Nothing changed.")
				Failed(why) => return die!(1, "before the deploy, GET ${check.path}: ${why}. Nothing changed.")
			}
		} else {
			if check.same {
				note!("--first: the same-body check of ${check.path} checks only the status")
			}
			None
		}
		$befores = $befores.append(before)
	}

	# 4. The D1 migrations: the pending list first, then apply.
	for binding in p.migrate {
		listed = wrangler!(Deploy.migrations_args(p, List, binding), Inherit)?
		if listed.code != 0 {
			return die!(1, "wrangler d1 migrations list ${binding} exited with ${listed.code.to_str()}. Nothing was uploaded.")
		}
		applied = wrangler!(Deploy.migrations_args(p, Apply, binding), Inherit)?
		if applied.code != 0 {
			return die!(1, "wrangler d1 migrations apply ${binding} exited with ${applied.code.to_str()}. Nothing was uploaded. The migrations that were applied stay.")
		}
	}

	# 5. Upload.
	up = wrangler!(Deploy.upload_args(p, message), Tee)?
	if up.code != 0 {
		return die!(1, "wrangler versions upload exited with ${up.code.to_str()}. The live version did not change.")
	}
	new = match Deploy.version_id(up.out) {
		Ok(id) => id
		Err(_) => return die!(1, "no \"Worker Version ID:\" line in the output of wrangler versions upload. The live version did not change.")
	}
	note!("new version: ${new}")

	# 6. Deploy.
	dep = wrangler!(Deploy.deploy_args(p, { new, old, message }), Inherit)?
	if dep.code != 0 {
		note!("rollback command: ${rollback_line}")
		return die!(1, "wrangler versions deploy exited with ${dep.code.to_str()}. Check the live version with wrangler deployments status.")
	}

	# 7. Smoke checks.
	if p.smoke.is_empty() {
		note!("no smoke checks (--smoke, or [[deploy.smoke]] in roc-cfw.toml)")
	} else if p.percent < 100 {
		note!("percent ${p.percent.to_str()}: a smoke check can reach the old or the new version")
	}
	var $failed = []
	if !p.smoke.is_empty() {
		_ = Sleep.millis!(p.wait * 1000)
	}
	for (check, before) in p.smoke.map2($befores, |c, b| (c, b)) {
		match smoke_one!({ url: p.url, wait: p.wait }, check, before) {
			Pass => {
				_ = Stdout.line!("smoke ok   GET ${check.path}")
			}
			Fail(why) => {
				_ = Stdout.line!("smoke FAIL ${why}")
				$failed = $failed.append(why)
			}
		}
	}

	# 8. The end: done, rollback, or keep.
	report! = |state| {
		_ = Stdout.line!("deploy: ${state}")
		_ = Stdout.line!("  new version: ${new} (${p.percent.to_str()}%)")
		_ = Stdout.line!("  old version: ${if old == "" "none" else old}")
		_ = Stdout.line!("  rollback:    ${rollback_line}")
		{}
	}
	match Deploy.after_smoke({ failed: $failed.len(), rollback: p.rollback, target: old != "" }) {
		Done => {
			report!("done")
			Ok({})
		}
		Rollback => {
			note!("${$failed.len().to_str()} smoke check(s) failed: rollback to ${old}")
			back = wrangler!(Deploy.rollback_args(p, old, Deploy.rollback_message), Inherit)?
			if back.code == 0 {
				report!("smoke check failed, rolled back to ${old}")
				Err(Exit(Deploy.exit_of(RolledBack)))
			} else {
				report!("smoke check failed, the rollback failed (exit ${back.code.to_str()}): run the rollback command")
				Err(Exit(Deploy.exit_of(RollbackFailed)))
			}
		}
		Keep => {
			why = if old == "" "there is no rollback target" else "the rollback is off"
			report!("smoke check failed, ${why}: the new version stays")
			Err(Exit(Deploy.exit_of(Kept)))
		}
	}
}

list_text : List(Str) -> Str
list_text = |items| if items.is_empty() "none" else Str.join_with(items, ", ")

## One smoke check: up to 3 tries, `wait` seconds apart. The first pass wins.
smoke_one! : { url : Str, wait : U64 }, { path : Str, status : U16, same : Bool }, [None, Some(List(U8))] => [Pass, Fail(Str)]
smoke_one! = |p, check, before| {
	var $result = Fail("no try")
	var $tries = 0
	while $tries < 3 {
		if $tries > 0 {
			_ = Sleep.millis!(p.wait * 1000)
		}
		$result = Deploy.judge({ smoke: check, before, got: get!(Deploy.url_of(p.url, check.path)) })
		$tries = if $result == Pass 3 else $tries + 1
	}
	$result
}

## A GET with a time limit of 30 seconds.
get! : Str => [Failed(Str), Got({ status : U16, body : List(U8) })]
get! = |url| {
	request = Request.from_method(GET).with_uri(url).with_timeout(TimeoutMilliseconds(30000))
	match Http.send!(request, {}) {
		Ok(response) => Got({ status: response.status(), body: response.body() })
		Err(InvalidUrl(_)) => Failed("the URL ${url} is not valid")
		Err(HttpErr(e)) => Failed("no answer (${Str.inspect(e)})")
		Err(Interrupted) => Failed("interrupted")
	}
}

## Runs `wrangler <args>`. The command line goes to stderr first. `Capture` keeps stdout, `Tee` keeps it and shows it.
## A wrangler that does not start is exit 2.
wrangler! : List(Str), [Inherit, Capture, Tee] => Try({ code : I32, out : Str }, [Exit(I32)])
wrangler! = |args, mode| {
	note!("run: ${Deploy.shell("wrangler", args)}")
	out_mode = match mode {
		Inherit => Inherit
		Capture => Capture
		Tee => Tee
	}
	cmd = command("wrangler", args).stdin(Inherit).stdout(out_mode).stderr(Inherit)
	match cmd.run!() {
		Ok(out) => {
			text = Str.from_utf8_lossy(out.stdout_bytes)
			code = match out.status {
				Exited(c) => c
				Signaled(signal) => 128 + signal
			}
			Ok({ code, out: text })
		}
		Err(_) => die!(2, "cannot start wrangler: is it on PATH?")
	}
}

## The default message: `roc-cfw <version> <commit>` from git (`-dirty` with changes).
default_message! : {} => Str
default_message! = |{}| {
	commit = match capture!("git", ["rev-parse", "--short", "HEAD"]) {
		Ok(t) => t.trim()
		Err(_) => ""
	}
	dirty = match capture!("git", ["status", "--porcelain"]) {
		Ok(t) => t.trim() != ""
		Err(_) => Bool.False
	}
	Deploy.message({ version: Args.version, commit, dirty })
}

## The stdout of a command that exited with 0.
capture! : Str, List(Str) => Try(Str, [Failed])
capture! = |program, args| match command(program, args).stdin(Null).stdout(Capture).stderr(Null).run!() {
	Ok(out) if out.status == Exited(0) => Ok(Str.from_utf8_lossy(out.stdout_bytes))
	_ => Err(Failed)
}

## The `.roc` files under a directory with their times, for the age check of the wasm. `Deploy.skip_dir` names the
## directories that it does not enter.
roc_files! : Str => List((Str, I128))
roc_files! = |dir| {
	entries = match Path.list!(Path.utf8(dir)) {
		Ok(list) => list
		Err(_) => []
	}
	var $found = []
	for entry in entries {
		full = entry.display()
		name = match full.split_on("/").last() {
			Ok(last) => last
			Err(_) => full
		}
		if is_dir!(full) {
			if !Deploy.skip_dir(name) {
				$found = $found.concat(roc_files!(full))
			}
		} else if name.ends_with(".roc") {
			match Path.time_modified!(entry) {
				Ok(t) => {
					$found = $found.append((full, t.to_nanos_since_epoch()))
				}
				Err(_) => {}
			}
		}
	}
	$found
}
