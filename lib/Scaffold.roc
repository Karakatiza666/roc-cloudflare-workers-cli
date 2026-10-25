import header.Header

## The pure part of `roc-cfw init`: how the 4 files of the template (`js/template/` of the platform bundle) join the files that
## `tln init --platform` and `tln add --tool` made. A function gives the new text, or says why it cannot.
##
## | File | Rule |
## | --- | --- |
## | `main.roc` | Keep the header of the file, put the template (a body with no header) after it. Only when the body is still the stub (empty, or with `crash "write the app"`, Talon R-IN8) |
## | `wrangler.toml` | The template, with the name of the project. No file is there before |
## | `talon.toml` | Add the `[scripts]` table of the template at the end. `[tools]` and all other bytes stay. No `[scripts]` table is there before |
## | `.gitignore` | Add each line of the template that the file does not have |
Scaffold :: [].{

	## The text of the stub of Talon R-IN8: a body with it is a body that `init` may replace.
	stub_marker : Str
	stub_marker = "crash \"write the app\""

	## The `main.roc` text: the header of `existing`, a blank line, then `template`. The template has no header (the file of
	## `js/template/` is the body of the app). `NotStub` when the body of `existing` is not the stub.
	app_file : { existing : Str, template : Str } -> Try(Str, [NoHeader, BadHeader, NotStub])
	app_file = |files| {
		old_end = header_end(files.existing)?
		old_body = tail_from(files.existing, old_end)
		if old_body.trim() != "" and !old_body.contains(Scaffold.stub_marker) {
			return Err(NotStub)
		}
		Ok("${head_to(files.existing, old_end)}\n\n${files.template.trim_start()}")
	}

	## A Worker name from the name of a directory: lower case, each run of other characters is one `-`, no `-` at the ends.
	## `roc-app` when nothing is left.
	name_of_dir : Str -> Str
	name_of_dir = |dir| {
		var $out = []
		var $dash = Bool.False
		for byte in dir.to_utf8() {
			low = if byte >= 65 and byte <= 90 byte + 32 else byte
			keep = (low >= 97 and low <= 122) or (low >= 48 and low <= 57)
			if keep {
				if $dash and !$out.is_empty() {
					$out = $out.append(45)
				}
				$dash = Bool.False
				$out = $out.append(low)
			} else {
				$dash = Bool.True
			}
		}
		match Str.from_utf8($out) {
			Ok("") => "roc-app"
			Ok(text) => text
			Err(_) => "roc-app"
		}
	}

	## Whether `name` is a Worker name: `[a-z0-9][a-z0-9-]*`.
	valid_name : Str -> Bool
	valid_name = |name| {
		bytes = name.to_utf8()
		ok_byte = |b| (b >= 97 and b <= 122) or (b >= 48 and b <= 57)
		match bytes {
			[] => Bool.False
			[first, .. as rest] => ok_byte(first) and rest.all(|b| ok_byte(b) or b == 45)
		}
	}

	## `wrangler.toml` of the template with the name of the project. The name that the template has (the first `name = "..."`)
	## is replaced where it stands between quotes and after `wrangler d1 create `.
	wrangler : { template : Str, name : Str } -> Str
	wrangler = |args| match template_name(args.template) {
		Err(_) => args.template
		Ok(old) => args.template
			.replace_each("\"${old}\"", "\"${args.name}\"")
			.replace_each("wrangler d1 create ${old}", "wrangler d1 create ${args.name}")
	}

	## `existing` with the `[scripts]` table of `template` at its end. `HasScripts` when `existing` has the table.
	## `NoScripts` when `template` has none.
	scripts : { existing : Str, template : Str } -> Try(Str, [HasScripts, NoScripts])
	scripts = |files| {
		if has_scripts(files.existing) {
			return Err(HasScripts)
		}
		table = scripts_table(files.template)?
		if files.existing.trim() == "" {
			Ok(table)
		} else {
			kept = if files.existing.ends_with("\n") files.existing else "${files.existing}\n"
			Ok("${kept}\n${table}")
		}
	}

	## `existing` with each line of `template` that it does not have, at its end. A blank line and a comment line are added
	## only when `existing` has no line at all.
	gitignore : { existing : Str, template : Str } -> Str
	gitignore = |files| {
		have = files.existing.split_on("\n").map(|l| l.trim())
		missing = files.template.split_on("\n").map(|l| l.trim()).keep_if(|l| l != "" and !have.contains(l))
		if missing.is_empty() {
			files.existing
		} else {
			kept = if files.existing == "" "" else if files.existing.ends_with("\n") files.existing else "${files.existing}\n"
			"${kept}${Str.join_with(missing, "\n")}\n"
		}
	}
}

## The byte offset of the end of the header of a source text.
header_end : Str -> Try(U64, [NoHeader, BadHeader])
header_end = |text| match Header.parse(text) {
	Ok(h) => Ok(h.span().end)
	Err(NoHeader) => Err(NoHeader)
	Err(BadHeader(_)) => Err(BadHeader)
}

head_to : Str, U64 -> Str
head_to = |text, end| match Str.from_utf8(text.to_utf8().sublist({ start: 0, len: end })) {
	Ok(s) => s
	Err(_) => text
}

tail_from : Str, U64 -> Str
tail_from = |text, start| match Str.from_utf8(text.to_utf8().drop_first(start)) {
	Ok(s) => s
	Err(_) => ""
}

## The value of the first `name = "..."` line of a TOML text.
template_name : Str -> Try(Str, [NoName])
template_name = |text| {
	line = match text.split_on("\n").find_first(|l| l.starts_with("name = \"")) {
		Ok(l) => l
		Err(_) => return Err(NoName)
	}
	parts = line.drop_prefix("name = \"").split_on("\"")
	match parts {
		[value, ..] => Ok(value)
		[] => Err(NoName)
	}
}

has_scripts : Str -> Bool
has_scripts = |text| text.split_on("\n").any(|l| l.trim() == "[scripts]")

## The lines from `[scripts]` to the next table (a line that starts with `[` in the first column), or to the end.
scripts_table : Str -> Try(Str, [NoScripts])
scripts_table = |text| {
	lines = text.split_on("\n")
	var $found = Bool.False
	var $done = Bool.False
	var $taken = []
	for line in lines {
		if !$done {
			if $found {
				if line.starts_with("[") {
					$done = Bool.True
				} else {
					$taken = $taken.append(line)
				}
			} else if line.trim() == "[scripts]" {
				$found = Bool.True
				$taken = $taken.append(line)
			}
		}
	}
	if $found {
		trimmed = Str.join_with($taken, "\n").trim_end()
		Ok("${trimmed}\n")
	} else {
		Err(NoScripts)
	}
}
