app [main!] { lib: "../lib/main.roc" }

import lib.Cfw
import lib.Platform

main! = |_args| Ok({})

url = "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.2.0/AbCdEf123.tar.zst"

app_with = |platform_value| "app [event!] {\n\tpf: platform \"${platform_value}\",\n\tother: \"https://github.com/roc-lang/unicode/releases/download/4.2.0/4W8SHzvwet9hH9qZewJ1J1CVQoH7YKA6zyijWFTB3y1w.tar.zst\",\n}\n\nimport pf.Worker\n"

# The platform entry of the header: the hash of a release URL, a path, a URL that is not a release, and the faults.
expect {
	release = match Platform.source(app_with(url)) {
		Ok(Url({ hash })) => hash == "AbCdEf123"
		_ => Bool.False
	}
	path = match Platform.source(app_with("../../platform/main.roc")) {
		Ok(Path(value)) => value == "../../platform/main.roc"
		_ => Bool.False
	}
	foreign = match Platform.source(app_with("https://example.com/platform.tar.zst")) {
		Err(ForeignUrl(_)) => Bool.True
		_ => Bool.False
	}
	headerless = match Platform.source("main! = |_| Ok({})\n") {
		Err(NoHeader) => Bool.True
		_ => Bool.False
	}
	no_platform = match Platform.source("app [main!] { json: \"https://github.com/roc-lang/unicode/releases/download/4.2.0/4W8SHzvwet9hH9qZewJ1J1CVQoH7YKA6zyijWFTB3y1w.tar.zst\" }\n") {
		Err(NoPlatform) => Bool.True
		_ => Bool.False
	}
	not_app = match Platform.source("package [Lib] {}\n") {
		Err(NotApp) => Bool.True
		_ => Bool.False
	}
	release and path and foreign and headerless and no_platform and not_app
}

# The cache directory (Talon R-CR1): `$XDG_CACHE_HOME/roc` when set, else `~/.cache/roc`. A path entry is relative to the app directory.
expect {
	xdg = Platform.package_dir({ xdg: "/x/cache", home: "/home/u", hash: "H1" }) == "/x/cache/roc/packages/H1"
	home = Platform.package_dir({ xdg: "", home: "/home/u", hash: "H1" }) == "/home/u/.cache/roc/packages/H1"
	rel = Platform.path_dir({ app_dir: "examples/hello", entry: "../../platform/main.roc" }) == "examples/hello/../../platform"
	same = Platform.path_dir({ app_dir: ".", entry: "main.roc" }) == "."
	abs = Platform.path_dir({ app_dir: "x", entry: "/p/platform/main.roc" }) == "/p/platform"
	dirs = Platform.dir_of_file("a/b/web.roc") == "a/b" and Platform.dir_of_file("web.roc") == "."
	xdg and home and rel and same and abs and dirs
}

# What pins `.roc-cfw/`: only the hash of a release URL, and not when `--js` is given. A copy happens when the stamp differs.
expect {
	hash_want = Platform.want_of(Url({ hash: "H1" }), Auto) == Hash("H1")
	js_want = Platform.want_of(Url({ hash: "H1" }), Dir("../js")) == Always
	path_want = Platform.want_of(Path("../p/main.roc"), Auto) == Always
	same = !Cfw.needs_copy("H1\n", Hash("H1"))
	changed = Cfw.needs_copy("H0\n", Hash("H1"))
	missing = Cfw.needs_copy("", Hash("H1"))
	always = Cfw.needs_copy("dev\n", Always)
	hash_want and js_want and path_want and same and changed and missing and always
}
