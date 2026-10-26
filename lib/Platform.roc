import header.Header
import header.PackageUrl

## Where the `js/` directory of the platform of an app is. Only decisions: the effects (a read, a fetch) are in `main.roc`.
##
## | Platform entry in the header | Platform directory | Pinned by |
## | --- | --- | --- |
## | A release URL | `$XDG_CACHE_HOME/roc/packages/<hash>/`, else `~/.cache/roc/packages/<hash>/` (Talon R-CR1) | The hash of the URL |
## | A path | The directory of the platform file, from the directory of the app file | Nothing |
## | Another URL | None (exit 2, as Talon R-PTH3) | |
##
## `tln path <alias> --file <app file>` (Talon R-PTH1) gives the directory first. The functions of this module give its
## arguments, read its output, and say why the cache rule above was used instead.
Platform :: [].{

	## The platform entry of the header of the app file text.
	source : Str -> Try([Url({ hash : Str }), Path(Str)], [NoHeader, BadHeader, NotApp, NoPlatform, ForeignUrl(Str)])
	source = |text| {
		header = match Header.parse(text) {
			Ok(h) => h
			Err(NoHeader) => return Err(NoHeader)
			Err(BadHeader(_)) => return Err(BadHeader)
		}
		match header.kind() {
			App => {}
			_ => return Err(NotApp)
		}
		entry = match header.entries().find_first(|e| e.is_platform) {
			Ok(e) => e
			Err(_) => return Err(NoPlatform)
		}
		match PackageUrl.parse(entry.value) {
			Ok(url) => Ok(Url({ hash: url.hash() }))
			Err(BadScheme) => Ok(Path(entry.value))
			Err(_) => Err(ForeignUrl(entry.value))
		}
	}

	## The packages directory of roc. `xdg` is `$XDG_CACHE_HOME` and `home` is `$HOME`, each `""` when not set.
	package_dir : { xdg : Str, home : Str, hash : Str } -> Str
	package_dir = |env| {
		root = if env.xdg != "" "${env.xdg}/roc" else "${env.home}/.cache/roc"
		"${root}/packages/${env.hash}"
	}

	## The directory of a platform path entry. `app_dir` is the directory of the app file.
	path_dir : { app_dir : Str, entry : Str } -> Str
	path_dir = |args| {
		parts = args.entry.split_on("/")
		dir = Str.join_with(parts.drop_last(1), "/")
		if args.entry.starts_with("/") dir else if dir == "" args.app_dir else "${args.app_dir}/${dir}"
	}

	## The directory of the app file: `a/b/web.roc` gives `a/b`, `web.roc` gives `.`.
	dir_of_file : Str -> Str
	dir_of_file = |file| {
		dir = Str.join_with(file.split_on("/").drop_last(1), "/")
		if dir == "" (if file.starts_with("/") "/" else ".") else dir
	}

	## What pins the files of `.roc-cfw/`: the hash of a release URL, else nothing.
	want_of : [Url({ hash : Str }), Path(Str)], [Auto, Dir(Str)] -> [Hash(Str), Always]
	want_of = |entry, js| match js {
		Dir(_) => Always
		Auto => match entry {
			Url({ hash }) => Hash(hash)
			Path(_) => Always
		}
	}

	## The alias of the platform entry of the header: the key before `platform "..."` (for example `pf`).
	## The argument of `tln path` (Talon R-PTH1).
	alias : Str -> Try(Str, [NoHeader, BadHeader, NotApp, NoPlatform])
	alias = |text| {
		header = match Header.parse(text) {
			Ok(h) => h
			Err(NoHeader) => return Err(NoHeader)
			Err(BadHeader(_)) => return Err(BadHeader)
		}
		match header.kind() {
			App => {}
			_ => return Err(NotApp)
		}
		match header.entries().find_first(|e| e.is_platform) {
			Ok(e) => Ok(e.name)
			Err(_) => Err(NoPlatform)
		}
	}

	## The arguments of the `tln` command that gives the directory of an entry (Talon R-PTH1).
	tln_args : { alias : Str, file : Str } -> List(Str)
	tln_args = |args| ["path", args.alias, "--file", args.file]

	## The directory from the stdout of `tln path`: one line, an absolute path. `NoDir` for anything else.
	tln_dir : Str -> Try(Str, [NoDir])
	tln_dir = |stdout| {
		line = stdout.trim()
		if line.starts_with("/") and !line.contains("\n") Ok(line) else Err(NoDir)
	}

	## The note line (stderr) that says why the cache rule was used and not `tln path`.
	fallback_note : { alias : Str, why : [NoTln, Failed(I32), BadOutput] } -> Str
	fallback_note = |args| match args.why {
		NoTln => "tln is not on PATH: used the roc cache rule for ${args.alias}"
		Failed(code) => "tln path ${args.alias} exited with ${code.to_str()}: used the roc cache rule"
		BadOutput => "tln path ${args.alias} gave no directory: used the roc cache rule"
	}
}
