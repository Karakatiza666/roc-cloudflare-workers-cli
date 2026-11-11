## A JSON body as a tree, for a same-body smoke check with an `ignore` list (docs/deploy.md, "Same-body checks").
##
## | Function | Does |
## | --- | --- |
## | `parse` | The tree of a body. `NotJson` for a body that is not one JSON value. |
## | `pointer` | The tokens of a JSON pointer (RFC 6901): `/checked` gives `["checked"]`, `/a~1b/0` gives `["a/b", "0"]` |
## | `drop` | The tree with no value at a pointer. A pointer that is not in the tree changes nothing. |
## | `diff` | `Ok({})` when two trees are equal, else `Err(<pointer>)` of the first difference |
##
## A string and a number stay as their JSON text: `"A"` is not equal to `"A"`, and `1.0` is not equal to `1`.
## The order of the members of an object is not part of the value. The order of the items of an array is.
JsonBody := [Obj(List((Str, JsonBody))), Arr(List(JsonBody)), Atom(Str)].{

	parse : List(U8) -> Try(JsonBody, [NotJson])
	parse = |bytes| {
		(value, next) = value_at(bytes, skip_ws(bytes, 0), 0)?
		if skip_ws(bytes, next) == bytes.len() Ok(value) else Err(NotJson)
	}

	pointer : Str -> Try(List(Str), [BadPointer])
	pointer = |text| {
		if !text.starts_with("/") {
			return Err(BadPointer)
		}
		tokens = text.drop_prefix("/").split_on("/")
		Ok(tokens.map(|t| t.replace_each("~1", "/").replace_each("~0", "~")))
	}

	drop : JsonBody, List(Str) -> JsonBody
	drop = |tree, tokens| match tokens {
		[] => tree
		[token, .. as rest] => match tree {
			Obj(members) => {
				if rest.is_empty() {
					Obj(members.keep_if(|(k, _)| k != token))
				} else {
					Obj(members.map(|(k, v)| if k == token (k, JsonBody.drop(v, rest)) else (k, v)))
				}
			}
			Arr(items) => match U64.from_str(token) {
				Ok(n) if n < items.len() => {
					if rest.is_empty() {
						Arr(items.drop_at(n))
					} else {
						Arr(items.map_with_index(|v, i| if i == n JsonBody.drop(v, rest) else v))
					}
				}
				_ => tree
			}
			Atom(_) => tree
		}
	}

	diff : JsonBody, JsonBody -> Try({}, Str)
	diff = |a, b| diff_at(a, b, "")
}

diff_at : JsonBody, JsonBody, Str -> Try({}, Str)
diff_at = |a, b, path| match (a, b) {
	(Atom(x), Atom(y)) => if x == y Ok({}) else Err(here(path))
	(Arr(xs), Arr(ys)) => {
		if xs.len() != ys.len() {
			return Err(here(path))
		}
		var $i = 0.U64
		for (x, y) in xs.map2(ys, |x, y| (x, y)) {
			diff_at(x, y, "${path}/${$i.to_str()}")?
			$i = $i + 1
		}
		Ok({})
	}
	(Obj(xs), Obj(ys)) => {
		for (k, x) in xs {
			match ys.find_first(|(key, _)| key == k) {
				Ok((_, y)) => diff_at(x, y, "${path}/${escape(k)}")?
				Err(_) => return Err("${path}/${escape(k)}")
			}
		}
		for (k, _) in ys {
			if !xs.any(|(key, _)| key == k) {
				return Err("${path}/${escape(k)}")
			}
		}
		Ok({})
	}
	_ => Err(here(path))
}

## The pointer of the whole body is `""`. A message names it `/`.
here : Str -> Str
here = |path| if path == "" "/" else path

escape : Str -> Str
escape = |token| token.replace_each("~", "~0").replace_each("/", "~1")

## The deepest nesting that `parse` reads. A deeper body is `NotJson`.
max_depth : U64
max_depth = 200

is_ws : U8 -> Bool
is_ws = |b| b == 32 or b == 9 or b == 10 or b == 13

skip_ws : List(U8), U64 -> U64
skip_ws = |bytes, start| {
	var $i = start
	while $i < bytes.len() and is_ws(bytes.get($i) ?? 0) {
		$i = $i + 1
	}
	$i
}

## The value that starts at `i` (no white space before it), and the index after it.
value_at : List(U8), U64, U64 -> Try((JsonBody, U64), [NotJson])
value_at = |bytes, i, depth| {
	if depth > max_depth {
		return Err(NotJson)
	}
	match bytes.get(i) {
		Ok(123) => object_at(bytes, i + 1, depth + 1)
		Ok(91) => array_at(bytes, i + 1, depth + 1)
		Ok(34) => {
			end = string_end(bytes, i + 1)?
			Ok((Atom(text_of(bytes, i, end)), end))
		}
		Ok(_) => {
			end = atom_end(bytes, i)
			word = text_of(bytes, i, end)
			if word == "true" or word == "false" or word == "null" or is_number(word) Ok((Atom(word), end)) else Err(NotJson)
		}
		Err(_) => Err(NotJson)
	}
}

## After `{`: the members, then the index after `}`.
object_at : List(U8), U64, U64 -> Try((JsonBody, U64), [NotJson])
object_at = |bytes, start, depth| {
	var $i = skip_ws(bytes, start)
	var $members = []
	if bytes.get($i) == Ok(125) {
		return Ok((Obj([]), $i + 1))
	}
	while Bool.True {
		if bytes.get($i) != Ok(34) {
			return Err(NotJson)
		}
		key_end = string_end(bytes, $i + 1)?
		key = text_of(bytes, $i + 1, key_end - 1)
		$i = skip_ws(bytes, key_end)
		if bytes.get($i) != Ok(58) {
			return Err(NotJson)
		}
		(value, after) = value_at(bytes, skip_ws(bytes, $i + 1), depth)?
		$members = $members.append((key, value))
		$i = skip_ws(bytes, after)
		match bytes.get($i) {
			Ok(44) => {
				$i = skip_ws(bytes, $i + 1)
			}
			Ok(125) => return Ok((Obj($members), $i + 1))
			_ => return Err(NotJson)
		}
	}
	Err(NotJson)
}

## After `[`: the items, then the index after `]`.
array_at : List(U8), U64, U64 -> Try((JsonBody, U64), [NotJson])
array_at = |bytes, start, depth| {
	var $i = skip_ws(bytes, start)
	var $items = []
	if bytes.get($i) == Ok(93) {
		return Ok((Arr([]), $i + 1))
	}
	while Bool.True {
		(value, after) = value_at(bytes, $i, depth)?
		$items = $items.append(value)
		$i = skip_ws(bytes, after)
		match bytes.get($i) {
			Ok(44) => {
				$i = skip_ws(bytes, $i + 1)
			}
			Ok(93) => return Ok((Arr($items), $i + 1))
			_ => return Err(NotJson)
		}
	}
	Err(NotJson)
}

## After the `"` that opens a string: the index after the `"` that closes it. A `\` escapes the next byte.
string_end : List(U8), U64 -> Try(U64, [NotJson])
string_end = |bytes, start| {
	var $i = start
	while $i < bytes.len() {
		match bytes.get($i) {
			Ok(34) => return Ok($i + 1)
			Ok(92) => {
				$i = $i + 2
			}
			Ok(b) if b < 32 => return Err(NotJson)
			_ => {
				$i = $i + 1
			}
		}
	}
	Err(NotJson)
}

## The end of a word (`true`, `false`, `null`, a number): the first white space, `,`, `]` or `}`.
atom_end : List(U8), U64 -> U64
atom_end = |bytes, start| {
	var $i = start
	while $i < bytes.len() and !(is_ws(bytes.get($i) ?? 32) or [44, 93, 125].contains(bytes.get($i) ?? 44)) {
		$i = $i + 1
	}
	$i
}

## A JSON number: `-`, digits, `.`, `e`, `E`, `+`. The form is checked loosely: the text is compared, not the value.
is_number : Str -> Bool
is_number = |word| {
	bytes = word.to_utf8()
	first_ok = match bytes.first() {
		Ok(b) => b == 45 or (b >= 48 and b <= 57)
		Err(_) => Bool.False
	}
	first_ok and bytes.all(|b| (b >= 48 and b <= 57) or [45, 43, 46, 101, 69].contains(b))
}

text_of : List(U8), U64, U64 -> Str
text_of = |bytes, start, end| Str.from_utf8_lossy(bytes.sublist({ start, len: end - start }))
