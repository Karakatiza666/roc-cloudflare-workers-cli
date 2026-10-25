## The contract between `roc-cfw` and the `js/` directory of a platform bundle.
##
## `js/cfw.json` is `{ "api": N }`. This version supports the numbers in `supported`. A new `api` needs a new `roc-cfw`
## release. A platform release with the same `api` needs none.
Cfw :: [].{

	## The `api` numbers that this version knows.
	supported : List(U64)
	supported = [1]

	## The text that tells the user to update the helper (exit code 2).
	update_message : Str
	update_message = "update roc-cfw: tln update roc-cfw"

	## The `api` of the text of `js/cfw.json`. `BadCfw` when it is not JSON, or has no `api` number.
	api_of : Str -> Try(U64, [BadCfw])
	api_of = |text| match Json.parse(text) {
		Ok({ api }) => Ok(api)
		Err(_) => Err(BadCfw)
	}

	## `Ok` when the text of `js/cfw.json` holds an `api` that this version supports.
	check : Str -> Try({}, [BadCfw, UnknownApi(U64)])
	check = |text| {
		api = Cfw.api_of(text)?
		if Cfw.supported.contains(api) Ok({}) else Err(UnknownApi(api))
	}

	## Whether `.roc-cfw/` must be copied again. `stamp` is the text of `.roc-cfw/.platform`, or `""` when there is none.
	## `want` is `Hash(h)` when the files come from the platform release of the app header (the hash pins the files),
	## and `Always` for a directory that the hash does not pin (the flag `--js`, a platform path entry).
	needs_copy : Str, [Hash(Str), Always] -> Bool
	needs_copy = |stamp, want| match want {
		Always => Bool.True
		Hash(hash) => stamp.trim() != hash
	}

	## The text of `.roc-cfw/.platform` for a copy.
	stamp_text : [Hash(Str), Always] -> Str
	stamp_text = |want| match want {
		Always => "dev\n"
		Hash(hash) => "${hash}\n"
	}
}
