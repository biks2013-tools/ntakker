#!/usr/bin/env node
// src/cli.ts — side-effecting shebang launcher. Compiled to `dist/cli.js`
// and pointed at by `package.json` `bin`. Keep this file as small as
// possible so `index.ts` remains testable.
//
// The argument parser itself lives in `args.ts` so it can be exercised
// from unit tests without import side effects.

import { runCli } from './index.js';

void runCli(process.argv.slice(2)).then(
    (code) => process.exit(code),
    (err) => {
        const message = err instanceof Error ? err.message : String(err);
        process.stderr.write(`fatal: ${message}\n`);
        process.exit(1);
    },
);
