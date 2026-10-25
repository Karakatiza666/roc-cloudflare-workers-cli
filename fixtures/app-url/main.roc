app [event!] {
	pf: platform "https://example.com/roc-cloudflare-workers/releases/download/0.2.0/FIXTUREHASH.tar.zst",
}

import pf.Worker

event! = |e| Worker.answer(e)
