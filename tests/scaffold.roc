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

# talon.toml: `[tools]` and the bytes before it stay, `[scripts]` of the template comes last. Only the table is taken from the template.
# A file that has `[scripts]` is not changed. A missing file (the empty text) gets the table only.
expect {
	tools = "# project\n[tools]\nroc-cfw = { ref = \"o/cli@^1\", url = \"https://x/1.0.3/H.tar.zst\" }\n"
	template = "# the template\n[workspace]\nmembers = []\n\n[scripts]\nbuild = [\n  \"roc build main.roc\",\n  \"roc-cfw sync\",\n]\ndev = [\"@build\"]\n\n[other]\nx = 1\n"
	table = "[scripts]\nbuild = [\n  \"roc build main.roc\",\n  \"roc-cfw sync\",\n]\ndev = [\"@build\"]\n"
	added = match Scaffold.scripts({ existing: tools, template }) {
		Ok(text) => text == "${tools}\n${table}"
		Err(_) => Bool.False
	}
	no_newline = match Scaffold.scripts({ existing: "[tools]\na = 1", template }) {
		Ok(text) => text == "[tools]\na = 1\n\n${table}"
		Err(_) => Bool.False
	}
	found = match Scaffold.scripts({ existing: "[scripts]\nx = [\"y\"]\n", template }) {
		Err(HasScripts) => Bool.True
		_ => Bool.False
	}
	fresh = match Scaffold.scripts({ existing: "", template }) {
		Ok(text) => text == table
		Err(_) => Bool.False
	}
	none = match Scaffold.scripts({ existing: tools, template: "[other]\nx = 1\n" }) {
		Err(NoScripts) => Bool.True
		_ => Bool.False
	}
	added and no_newline and found and fresh and none
}

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
