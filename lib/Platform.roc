import header.Header
import header.PackageUrl

## Where the `js/` directory of the platform of an app is. Only decisions: the effects (a read, a fetch) are in `main.roc`.
##
## | Platform entry in the header | Platform directory | Pinned by |
## | --- | --- | --- |
## | A release URL | `$XDG_CACHE_HOME/roc/packages/<hash>/`, else `~/.cache/roc/packages/<hash>/` (Talon R-CR1) | The hash of the URL |
## | A path | The directory of the platform file, from the directory of the app file | Nothing |
## | Another URL | None (exit 2, as Talon R-PTH3) | |
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
}
