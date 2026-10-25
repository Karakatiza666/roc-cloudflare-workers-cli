app [main!] { lib: "../lib/main.roc" }

import lib.Cfw

main! = |_args| Ok({})

# The api check: a known number passes, an unknown number is `UnknownApi`, a file with no number is `BadCfw`.
expect {
	known = match Cfw.check("{ \"api\": 1 }") {
		Ok(_) => Bool.True
		Err(_) => Bool.False
	}
	extra = match Cfw.check("{\"api\":1,\"note\":\"x\"}") {
		Ok(_) => Bool.True
		Err(_) => Bool.False
	}
	unknown = match Cfw.check("{\"api\":2}") {
		Err(UnknownApi(n)) => n == 2
		_ => Bool.False
	}
	bad_json = match Cfw.check("api = 1") {
		Err(BadCfw) => Bool.True
		_ => Bool.False
	}
	no_api = match Cfw.check("{}") {
		Err(BadCfw) => Bool.True
		_ => Bool.False
	}
	known and extra and unknown and bad_json and no_api and Cfw.update_message == "update roc-cfw: tln update roc-cfw"
}
