// A fake Worker for the smoke checks of the deploy tests. Usage: node server.mjs <state dir>.
// It listens on 127.0.0.1 (a free port, written to <state dir>/port). Each request reads <state dir>/live ("old" or "new",
// set by the fake wrangler) and <state dir>/new.json: { "health": <status of /health for new>, "data": <body of /data for new>,
//   "p": <the value v of /p for new> }.
//   /health  old: 200 "ok"       new: the status of new.json (default 200)
//   /data    old: "data-v1"      new: the body of new.json (default "data-v1")
//   /p       JSON {"v": "1" (new: new.json p), "checked": {"at": <a new time at each request>}}: a body that changes by itself
//   /slow    200 after 3 seconds
//   /flaky   503 for the first request, then 200 "steady"
//   /gone    404 always
import { createServer } from 'node:http';
import { readFileSync, writeFileSync } from 'node:fs';
const dir = process.argv[2];
const read = (f, d) => {
  try {
    return readFileSync(`${dir}/${f}`, 'utf8').trim();
  } catch {
    return d;
  }
};
let flaky = 0;
const server = createServer((req, res) => {
  const live = read('live', 'old');
  const conf = JSON.parse(read('new.json', '{}') || '{}');
  if (req.url === '/health') {
    res.writeHead(live === 'new' ? (conf.health ?? 200) : 200);
    res.end('ok');
  } else if (req.url === '/data') {
    res.writeHead(200);
    res.end(live === 'new' ? (conf.data ?? 'data-v1') : 'data-v1');
  } else if (req.url === '/p') {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ v: live === 'new' ? (conf.p ?? '1') : '1', checked: { at: `${process.hrtime.bigint()}` } }));
  } else if (req.url === '/slow') {
    setTimeout(() => {
      res.writeHead(200);
      res.end('late');
    }, 3000);
  } else if (req.url === '/flaky') {
    flaky += 1;
    res.writeHead(flaky === 1 ? 503 : 200);
    res.end('steady');
  } else {
    res.writeHead(404);
    res.end('not found');
  }
});
server.listen(0, '127.0.0.1', () => writeFileSync(`${dir}/port`, String(server.address().port)));
