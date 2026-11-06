#!/usr/bin/env node
/**
 * Development without a second `npm install`: links ./node_modules to the core package's
 * ../react-native/node_modules (same toolchain: Jest, Babel, TypeScript, ESLint, bob, RN).
 * Run `cd ../react-native && npm ci` first. A real `npm install` here works too.
 */
const fs = require('fs');
const path = require('path');

const here = path.join(__dirname, '..', 'node_modules');
const core = path.join(__dirname, '..', '..', 'react-native', 'node_modules');
if (!fs.existsSync(core)) {
  console.error('Missing ../react-native/node_modules: run `npm ci` in ../react-native first.');
  process.exit(1);
}
try {
  const stat = fs.lstatSync(here);
  if (stat.isSymbolicLink()) {
    console.log('node_modules already linked');
    process.exit(0);
  }
  console.log('node_modules exists (installed); leaving it alone');
  process.exit(0);
} catch {
  fs.symlinkSync(path.relative(path.dirname(here), core), here, 'dir');
  console.log('linked node_modules -> ../react-native/node_modules');
}
