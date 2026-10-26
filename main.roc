app [main!] {
	lib: "lib/main.roc",
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.25.0/CZsY7tYZwR3rj9kYbpaCfxki2yVAaRL8bBwMLvB2xkbA.tar.zst",
}

import pf.Cmd
import pf.Env
import pf.OsStr
import pf.Path
import pf.Random
import pf.Stderr
import pf.Stdout
import lib.Args
import lib.Cfw
import lib.Platform
import lib.Scaffold

## `roc-cfw`: the helper CLI of the Roc platform for Cloudflare Workers (README.md).
## The decisions are in `lib/` (tested with `roc test`). This file holds the effects and the order of the steps.

Opts : { cmd : [Help, Shim, Sync, Init], file : Str, js : [Auto, Dir(Str)], name : [Auto, Named(Str)], rest : List(Str) }

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
	cmd = Cmd.new_str("tln").args_str(Platform.tln_args(args)).stdin(Null).stdout(Capture).stderr(Inherit)
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
			_ = Cmd.new_str("roc").args_str(["check", args.file]).stdin(Null).stdout(Inherit).stderr(Inherit).run!()
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
	cmd = Cmd.new_str("node").args_str([".roc-cfw/cli.mjs", "sync"].concat(args)).stdin(Inherit).stdout(Inherit).stderr(Inherit)
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
