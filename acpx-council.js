#!/usr/bin/env node
'use strict';
const {execFileSync} = require('child_process');
const path = require('path');
const script = path.join(__dirname, 'acpx', 'bin', 'acpx-council');
try {
  execFileSync('bash', [script, ...process.argv.slice(2)], {stdio: 'inherit'});
} catch (e) {
  process.exit(e.status || 1);
}
