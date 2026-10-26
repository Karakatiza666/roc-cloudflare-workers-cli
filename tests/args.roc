app [main!] { lib: "../lib/main.roc" }

import lib.Args

main! = |_args| Ok({})

# Test helpers. `==` on a `Try` does not compile, so each test takes the `Ok` record out first.
ok_of = |argv| match Args.parse(argv) {
	Ok(parsed) => Ok(parsed)
	Err(message) => Err(message)
}

# The `sync` arguments that are not helper flags go to cli.mjs, in order. `--file` and `--js` with their values never do.
expect {
	match ok_of(["sync", "--wasm", "web.wasm", "--file", "web.roc", "--check", "--js", "../../js", "--entry", "worker.js"]) {
		Ok(p) => p.cmd == Sync and p.file == "web.roc" and p.js == Dir("../../js") and p.rest == ["--wasm", "web.wasm", "--check", "--entry", "worker.js"]
		Err(_) => Bool.False
	}
}

# Defaults: `main.roc`, the platform directory, no name, no sync arguments.
expect {
	match ok_of(["shim"]) {
		Ok(p) => p.cmd == Shim and p.file == "main.roc" and p.js == Auto and p.name == Auto and p.rest == []
		Err(_) => Bool.False
	}
}

# `init` has `--name`. For `sync` the text `--name` is a sync argument, and `shim` refuses an argument it does not know.
expect {
	init = match ok_of(["init", "--name", "my-app"]) {
		Ok(p) => p.cmd == Init and p.name == Named("my-app")
		Err(_) => Bool.False
	}
	sync = match ok_of(["sync", "--name", "x"]) {
		Ok(p) => p.rest == ["--name", "x"] and p.name == Auto
		Err(_) => Bool.False
	}
	shim = match ok_of(["shim", "--wasm"]) {
		Ok(_) => Bool.False
		Err(message) => message == "unknown argument --wasm"
	}
	init and sync and shim
}

# Errors (exit 2): no command, an unknown command, a flag with no value.
expect {
	none = match ok_of([]) {
		Ok(_) => Bool.False
		Err(_) => Bool.True
	}
	unknown = match ok_of(["build"]) {
		Ok(_) => Bool.False
		Err(message) => message.starts_with("unknown command build")
	}
	dangling = match ok_of(["sync", "--file"]) {
		Ok(_) => Bool.False
		Err(message) => message == "--file needs a value"
	}
	none and unknown and dangling
}

# R-SYNC-FILE: `sync_args` puts `--file <file>` first when the file is there, and the other arguments follow in order.
expect {
	Args.sync_args({ file: "web.roc", file_exists: Bool.True, rest: ["--wasm", "web.wasm", "--check"] }) == ["--file", "web.roc", "--wasm", "web.wasm", "--check"]
}

# The default file `main.roc` is passed too, when it is there. No other argument: `--file` alone.
expect {
	match ok_of(["sync"]) {
		Ok(p) => Args.sync_args({ file: p.file, file_exists: Bool.True, rest: p.rest }) == ["--file", "main.roc"]
		Err(_) => Bool.False
	}
}

# The file is not there: nothing is added, the other arguments stay as they are.
expect {
	Args.sync_args({ file: "main.roc", file_exists: Bool.False, rest: ["--check"] }) == ["--check"]
}

# `--file X` of the command line goes on as `--file X` once. `--js` never goes on.
expect {
	match ok_of(["sync", "--js", "../js", "--file", "sub/web.roc", "--check"]) {
		Ok(p) => Args.sync_args({ file: p.file, file_exists: Bool.True, rest: p.rest }) == ["--file", "sub/web.roc", "--check"]
		Err(_) => Bool.False
	}
}
