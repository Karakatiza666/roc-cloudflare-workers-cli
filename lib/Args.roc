## The command line of `roc-cfw`.
##
## | Command | Flags that the helper reads | Other arguments |
## | --- | --- | --- |
## | `shim` | `--file <app.roc>`, `--js <dir>` | An error (exit 2) |
## | `sync` | `--file <app.roc>`, `--js <dir>` | In order, to `node .roc-cfw/cli.mjs sync` (see `sync_args`) |
## | `init` | `--file <app.roc>`, `--js <dir>`, `--name <name>` | An error (exit 2) |
## | `help` (also `--help`, `-h`) | none | none |
##
## A flag has its value in the next argument. The flag `--js` is never passed to `cli.mjs`. The flag `--file` is passed by `sync_args`.
Args :: [].{

	## The arguments after `node .roc-cfw/cli.mjs sync`. `file` is the app file of `roc-cfw` (`--file`, else `main.roc`).
	## `cli.mjs sync` reads the app source with `--file` to warn of a handler that `Worker.new` does not list.
	## `--file <file>` goes first, when `file_exists` is true. When the file is not there, nothing is added.
	sync_args : { file : Str, file_exists : Bool, rest : List(Str) } -> List(Str)
	sync_args = |args| if args.file_exists ["--file", args.file].concat(args.rest) else args.rest

	## `Err` has the text of the message for the user. The caller exits with code 2.
	parse : List(Str) -> Try({ cmd : [Help, Shim, Sync, Init], file : Str, js : [Auto, Dir(Str)], name : [Auto, Named(Str)], rest : List(Str) }, Str)
	parse = |argv| match argv {
		[] => Err("no command: use shim, sync or init")
		[first, .. as tail] => match first {
			"help" | "--help" | "-h" => Ok({ cmd: Help, file: "main.roc", js: Auto, name: Auto, rest: [] })
			"shim" => flags(Shim, tail)
			"sync" => flags(Sync, tail)
			"init" => flags(Init, tail)
			other => Err("unknown command ${other}: use shim, sync or init")
		}
	}

	## The text of `roc-cfw help`.
	usage : Str
	usage =
		\\usage:
		\\  roc-cfw shim [--file main.roc] [--js <dir>]
		\\      Copies js/ of the platform of the app to .roc-cfw/ (when the platform hash changed).
		\\  roc-cfw sync [--file main.roc] [--js <dir>] [sync arguments]
		\\      shim, then: node .roc-cfw/cli.mjs sync --file <app file> [sync arguments]. The exit code of node is the exit code.
		\\      --file is passed on when the app file is there (cli.mjs warns of a handler that Worker.new does not list).
		\\  roc-cfw init [--file main.roc] [--js <dir>] [--name <name>]
		\\      Writes the template of the platform: the app body in main.roc, wrangler.toml, [scripts] in talon.toml, .gitignore.
		\\  --js <dir>: use this directory in place of js/ of the platform (for the repository of the platform).
		\\Exit: 0 good, 1 a failure, 2 a bad command line or an api of the platform that this version does not know.
}

flags : [Shim, Sync, Init], List(Str) -> Try({ cmd : [Help, Shim, Sync, Init], file : Str, js : [Auto, Dir(Str)], name : [Auto, Named(Str)], rest : List(Str) }, Str)
flags = |cmd, tail| {
	var $file = "main.roc"
	var $js = Auto
	var $name = Auto
	var $rest = []
	var $pending = ""
	var $problem = ""
	for arg in tail {
		if $pending != "" {
			if $pending == "--file" {
				$file = arg
			} else if $pending == "--js" {
				$js = Dir(arg)
			} else {
				$name = Named(arg)
			}
			$pending = ""
		} else if arg == "--file" or arg == "--js" {
			$pending = arg
		} else if arg == "--name" and cmd == Init {
			$pending = arg
		} else if cmd == Sync {
			$rest = $rest.append(arg)
		} else if $problem == "" {
			$problem = "unknown argument ${arg}"
		}
	}
	if $pending != "" {
		Err("${$pending} needs a value")
	} else if $problem != "" {
		Err($problem)
	} else {
		Ok({ cmd: cmd_of(cmd), file: $file, js: $js, name: $name, rest: $rest })
	}
}

cmd_of : [Shim, Sync, Init] -> [Help, Shim, Sync, Init]
cmd_of = |cmd| match cmd {
	Shim => Shim
	Sync => Sync
	Init => Init
}
