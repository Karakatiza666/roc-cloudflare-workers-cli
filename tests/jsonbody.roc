app [main!] { lib: "../lib/main.roc" }

import lib.JsonBody

main! = |_args| Ok({})

tree = |text| JsonBody.parse(text.to_utf8())

is_json = |text| match tree(text) {
	Ok(_) => Bool.True
	Err(NotJson) => Bool.False
}

## The first difference of two bodies after the drop of the pointers, or "" when they are equal.
## "not json" when one body is not JSON.
compare = |a, b, pointers| {
	tokens = pointers.keep_oks(JsonBody.pointer)
	match (tree(a), tree(b)) {
		(Ok(x), Ok(y)) => {
			dx = tokens.fold(x, |t, p| JsonBody.drop(t, p))
			dy = tokens.fold(y, |t, p| JsonBody.drop(t, p))
			match JsonBody.diff(dx, dy) {
				Ok(_) => ""
				Err(at) => at
			}
		}
		_ => "not json"
	}
}

registry_a =
	\\{"name":"roc-semver","versions":["0.1.0","0.2.0"],
	\\ "checked":{"name":"roc-semver","checked_at":"2026-11-10T10:00:00Z","stale":false}}

registry_b =
	\\{ "name" : "roc-semver", "versions" : [ "0.1.0", "0.2.0" ],
	\\  "checked" : { "name" : "roc-semver", "checked_at" : "2026-11-11T09:30:00Z", "stale" : true } }

# A body that differs only in an ignored member is equal. White space and the order of members do not count.
expect compare(registry_a, registry_b, ["/checked"]) == ""

# The same bodies with no ignore list: the first difference is in checked.
expect compare(registry_a, registry_b, []) == "/checked/checked_at"

# A difference outside the ignored member is found, with its pointer.
expect {
	other = registry_b.replace_each("0.2.0", "0.3.0")
	compare(registry_a, other, ["/checked"]) == "/versions/1"
}

# A member that only one body has: the pointer of that member.
expect compare("{\"a\":1}", "{\"a\":1,\"b\":2}", []) == "/b" and compare("{\"a\":1,\"b\":2}", "{\"a\":1}", []) == "/b"

# The order of the members of an object does not count; the order of the items of an array does.
expect compare("{\"a\":1,\"b\":2}", "{\"b\":2,\"a\":1}", []) == "" and compare("[1,2]", "[2,1]", []) == "/0"

# A pointer into an array and a nested pointer. A pointer that is not there changes nothing.
expect compare("{\"l\":[{\"t\":1,\"k\":5},{\"t\":2,\"k\":6}]}", "{\"l\":[{\"t\":9,\"k\":5},{\"t\":2,\"k\":6}]}", ["/l/0/t", "/nothing/here"]) == ""

# A whole-body difference names "/". Numbers and strings compare as text.
expect compare("1", "2", []) == "/" and compare("1.0", "1", []) != "" and compare("\"a\"", "\"a\"", []) == ""

# The pointer escapes ~0 and ~1 (RFC 6901).
expect JsonBody.pointer("/a~1b/c~0d") == Ok(["a/b", "c~d"]) and JsonBody.pointer("checked") == Err(BadPointer)
expect compare("{\"a/b\":1,\"c\":2}", "{\"a/b\":3,\"c\":2}", ["/a~1b"]) == ""

# Not JSON: text, HTML, a value with more after it, a cut body, a bad word.
expect {
	bad = ["ok", "<html></html>", "{} {}", "{\"a\":", "[1,]", "{\"a\" 1}", "tru", ""]
	bad.all(|b| !is_json(b))
}

# JSON: all value kinds, escapes in strings, white space at the ends.
expect {
	good = [" {\"s\":\"a\\\"b\\\\\",\"n\":-1.5e3,\"t\":true,\"f\":false,\"z\":null,\"l\":[],\"o\":{}}\n", "[]", "0", "\"x\""]
	good.all(is_json)
}
