// A stub of js/cli.mjs of a platform bundle. It prints its command line and its directory, and exits with the number after `--exit`.
import { dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { existsSync } from 'node:fs';
const args = process.argv.slice(2);
const here = dirname(fileURLToPath(import.meta.url));
console.log(`STUB args=${JSON.stringify(args)} sibling=${existsSync(`${here}/index.js`)}`);
const at = args.indexOf('--exit');
process.exit(at >= 0 ? Number(args[at + 1]) : 0);
