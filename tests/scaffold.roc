app [main!] { lib: "../lib/main.roc" }

import lib.Scaffold

main! = |_args| Ok({})

# The header that `tln init --platform` wrote, and its stub body (Talon R-IN8).
stub_app = "# my app\napp [event!] {\n\tpf: platform \"https://github.com/o/p/releases/download/1.0.0/H1.tar.zst\",\n}\n\nimport pf.Worker\n\nevent! = |_| crash \"write the app\"\n"

# The template of js/template/main.roc: no header, the body only.
template_app = "## The example.\nimport pf.Worker\n\nevent! = |e| Worker.answer(e)\n"

# main.roc: the header (with its comment before it and its own platform line) stays, the template replaces the stub body.
expect {
	want = "# my app\napp [event!] {\n\tpf: platform \"https://github.com/o/p/releases/download/1.0.0/H1.tar.zst\",\n}\n\n## The example.\nimport pf.Worker\n\nevent! = |e| Worker.answer(e)\n"
	match Scaffold.app_file({ existing: stub_app, template: template_app }) {
		Ok(text) => text == want
		Err(_) => Bool.False
	}
}

# main.roc: a body that is not the stub is never replaced. An empty body is replaced. A file with no header is an error.
expect {
	written = "app [event!] { pf: platform \"https://github.com/o/p/releases/download/1.0.0/H1.tar.zst\" }\n\nevent! = |e| Worker.answer(e)\n"
	empty = "app [event!] { pf: platform \"https://github.com/o/p/releases/download/1.0.0/H1.tar.zst\" }\n"
	refused = match Scaffold.app_file({ existing: written, template: template_app }) {
		Err(NotStub) => Bool.True
		_ => Bool.False
	}
	filled = match Scaffold.app_file({ existing: empty, template: template_app }) {
		Ok(text) => text.contains("Worker.answer") and text.starts_with("app [event!] { pf: platform \"https://github.com/o/p/")
		Err(_) => Bool.False
	}
	headerless = match Scaffold.app_file({ existing: "x = 1\n", template: template_app }) {
		Err(NoHeader) => Bool.True
		_ => Bool.False
	}
	refused and filled and headerless
}

# talon.toml, merged with roc-toml. The template keys, in the order of the template text (not the order of a Dict).
template_toml = "# the template\n[workspace]\nmembers = []\n\n[scripts]\nbuild = [\"a\", \"b\"]\ncheck = [\"c\"]\ndev = [\"@build\"]\ndeploy = [\"@check\", \"d\"]\n\n[other]\nx = 1\n"

table = "[scripts]\nbuild = [\"a\", \"b\"]\ncheck = [\"c\"]\ndev = [\"@build\"]\ndeploy = [\"@check\", \"d\"]\n"

# talon.toml: a file with `[tools]` only. The exact text: every byte of `[tools]` stays (also a comment, a trailing comment and the lines
# after the last entry), then a blank line and the `[scripts]` table with the keys in template order. Nothing is kept back.
expect {
	tools = "# project\n[tools]\n# the cli\nroc-cfw = { ref = \"o/cli@^1\", url = \"https://x/1.0.3/H.tar.zst\" } # pinned\n\n# end\n"
	match Scaffold.scripts({ existing: tools, template: template_toml }) {
		Ok(merged) => merged.text == "${tools}\n${table}" and merged.kept == []
		Err(_) => Bool.False
	}
}

# talon.toml: the last line has no line end. A line end is added before the new table.
expect {
	match Scaffold.scripts({ existing: "[tools]\na = 1", template: template_toml }) {
		Ok(merged) => merged.text == "[tools]\na = 1\n\n${table}"
		Err(_) => Bool.False
	}
}

# talon.toml: a file with `[scripts]` that has 1 equal key (build), 1 key with another value (dev), and 2 missing keys (check, deploy).
# The user value stays with its comment, the missing keys come after the last entry in template order, `[other]` after it stays.
# Only the other value is in `kept`.
expect {
	existing = "[tools]\na = 1\n\n[scripts]\nbuild = [\"a\", \"b\"]\ndev = [\"@mine\"] # mine\n\n[other]\nx = 1\n"
	want = "[tools]\na = 1\n\n[scripts]\nbuild = [\"a\", \"b\"]\ndev = [\"@mine\"] # mine\ncheck = [\"c\"]\ndeploy = [\"@check\", \"d\"]\n\n[other]\nx = 1\n"
	match Scaffold.scripts({ existing, template: template_toml }) {
		Ok(merged) => merged.text == want and merged.kept == ["dev"]
		Err(_) => Bool.False
	}
}

# talon.toml: all keys are there with the template values: the text is the same, nothing is kept. The second merge changes nothing.
expect {
	once = Scaffold.scripts({ existing: "[tools]\na = 1", template: template_toml })
	match once {
		Err(_) => Bool.False
		Ok(first) => match Scaffold.scripts({ existing: first.text, template: template_toml }) {
			Ok(second) => second.text == first.text and second.kept == []
			Err(_) => Bool.False
		}
	}
}

# talon.toml: a CRLF file. The inserted lines use CRLF too, and the old bytes stay.
expect {
	existing = "[tools]\r\na = 1\r\n"
	want = "[tools]\r\na = 1\r\n\r\n[scripts]\r\nbuild = [\"a\", \"b\"]\r\ncheck = [\"c\"]\r\ndev = [\"@build\"]\r\ndeploy = [\"@check\", \"d\"]\r\n"
	match Scaffold.scripts({ existing, template: template_toml }) {
		Ok(merged) => merged.text == want
		Err(_) => Bool.False
	}
}

# talon.toml: a file that does not parse gives the line and the column. `scripts = 1` and `[[scripts]]` give ScriptsNotTable.
expect {
	bad = match Scaffold.scripts({ existing: "[tools]\na = 1\nb = \n", template: template_toml }) {
		Err(BadToml(e)) => e.line == 3 and e.column >= 1
		_ => Bool.False
	}
	number = match Scaffold.scripts({ existing: "scripts = 1\n", template: template_toml }) {
		Err(ScriptsNotTable) => Bool.True
		_ => Bool.False
	}
	array = match Scaffold.scripts({ existing: "[tools]\na = 1\n\n[[scripts]]\nx = 1\n", template: template_toml }) {
		Err(ScriptsNotTable) => Bool.True
		_ => Bool.False
	}
	bad and number and array
}

# talon.toml: no file (the empty text) gets the `[scripts]` table of the template, with no other table of the template.
# A template with no `[scripts]` table, or one that does not parse, is an error.
expect {
	fresh = match Scaffold.scripts({ existing: "", template: template_toml }) {
		Ok(merged) => merged.text == table and merged.kept == []
		Err(_) => Bool.False
	}
	none = match Scaffold.scripts({ existing: "[tools]\na = 1\n", template: "[other]\nx = 1\n" }) {
		Err(NoScripts) => Bool.True
		_ => Bool.False
	}
	broken = match Scaffold.scripts({ existing: "[tools]\na = 1\n", template: "[scripts\n" }) {
		Err(BadTemplate) => Bool.True
		_ => Bool.False
	}
	fresh and none and broken
}

# The note line for a kept key (README, init).
expect Scaffold.kept_note("dev") == "talon.toml: [scripts] dev kept (not the template value)"

# .gitignore: each template line that is not there is added (compared after trim), the old lines stay, the result is the same when added twice.
expect {
	template = "app.wasm\n.roc-cfw/\n.wrangler/\n"
	once = Scaffold.gitignore({ existing: "node_modules\n.roc-cfw/", template })
	twice = Scaffold.gitignore({ existing: once, template })
	fresh = Scaffold.gitignore({ existing: "", template })
	once == "node_modules\n.roc-cfw/\napp.wasm\n.wrangler/\n" and twice == once and fresh == template
}

# wrangler.toml: the name of the template is replaced between quotes and after `wrangler d1 create`, and only there.
# The name of a project from a directory name, and the check of a given name.
expect {
	template = "name = \"roc-hello\"\nmain = \"worker.js\"\n# wrangler d1 create roc-hello, and a roc-hello-x word\n[[d1_databases]]\ndatabase_name = \"roc-hello\"\n"
	got = Scaffold.wrangler({ template, name: "shop" })
	want = "name = \"shop\"\nmain = \"worker.js\"\n# wrangler d1 create shop, and a roc-hello-x word\n[[d1_databases]]\ndatabase_name = \"shop\"\n"
	names = Scaffold.name_of_dir("My Shop_2!") == "my-shop-2" and Scaffold.name_of_dir("--x--") == "x" and Scaffold.name_of_dir("!!!") == "roc-app"
	valid = Scaffold.valid_name("a-1") and !Scaffold.valid_name("-a") and !Scaffold.valid_name("A") and !Scaffold.valid_name("")
	got == want and names and valid
}
