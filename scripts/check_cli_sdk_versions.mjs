#!/usr/bin/env node
// The setup command (cli/) writes the SDK coordinates and versions from cli/src/constants.ts into
// app projects, and doctor uses the same versions as minimums. This check fails when they drift
// from the SDKs in this repository:
//
//   cli SDK.android   GROUP / POM_ARTIFACT_ID / VERSION_NAME     android/gradle.properties
//   cli SDK.ios       s.name / s.version (podConstraint ~> x.y)  ios/Clikgate.podspec
//   cli SDK.flutter   name / version (constraint ^x.y.z)         flutter/pubspec.yaml
//   cli SDK.reactNative name / version (constraint ^x.y.z)       react-native/package.json
//   cli CLI_VERSION                                              cli/package.json version
//
// Usage: node scripts/check_cli_sdk_versions.mjs   (Node 18+, no dependencies)
// When an SDK version changes, update cli/src/constants.ts (and the CLI's snapshots, docs and
// CHANGELOG) in the same change. The AI guides in clikgate_sdks check their versions.json against
// the same constants.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const read = (rel) => fs.readFileSync(path.join(root, rel), 'utf8');
const errors = [];
const expect = (what, cli, sdk, where) => {
  if (cli !== sdk) errors.push(`${what}: cli/src/constants.ts has ${JSON.stringify(cli)}, ${where} has ${JSON.stringify(sdk)}`);
};
const match = (src, re, where) => {
  const m = re.exec(src);
  if (!m) throw new Error(`couldn't read ${re} from ${where}`);
  return m[1];
};

// cli/src/constants.ts: `export const SDK = { name: { key: 'value', ... }, ... } as const;`
const constants = read('cli/src/constants.ts');
const block = match(constants, /export const SDK = \{([\s\S]*?)\n\} as const;/, 'cli/src/constants.ts');
const sdk = {};
for (const line of block.split('\n')) {
  const m = /^\s*(\w+): \{(.*)\},?\s*$/.exec(line);
  if (!m) continue;
  sdk[m[1]] = Object.fromEntries([...m[2].matchAll(/(\w+): '([^']*)'/g)].map((x) => [x[1], x[2]]));
}
for (const k of ['android', 'ios', 'flutter', 'reactNative']) {
  if (!sdk[k]) errors.push(`cli/src/constants.ts: SDK.${k} not found (has the format changed? update this script)`);
}
const cliVersion = match(constants, /export const CLI_VERSION = '([^']+)'/, 'cli/src/constants.ts');

if (sdk.android) {
  const where = 'android/gradle.properties';
  const props = read(where);
  const prop = (k) => match(props, new RegExp(`^${k}=(.+)$`, 'm'), where).trim();
  expect('Android group', sdk.android.group, prop('GROUP'), `${where} GROUP`);
  expect('Android artifact', sdk.android.artifact, prop('POM_ARTIFACT_ID'), `${where} POM_ARTIFACT_ID`);
  expect('Android version', sdk.android.version, prop('VERSION_NAME'), `${where} VERSION_NAME`);
}
if (sdk.ios) {
  const where = 'ios/Clikgate.podspec';
  const spec = read(where);
  const name = match(spec, /^\s*s\.name\s*=\s*'([^']+)'/m, where);
  const version = match(spec, /^\s*s\.version\s*=\s*'([^']+)'/m, where);
  expect('iOS pod', sdk.ios.pod, name, `${where} s.name`);
  expect('iOS version', sdk.ios.version, version, `${where} s.version`);
  expect('iOS pod constraint', sdk.ios.podConstraint, `~> ${version.split('.').slice(0, 2).join('.')}`, `${where} s.version (as ~> major.minor)`);
}
if (sdk.flutter) {
  const where = 'flutter/pubspec.yaml';
  const pubspec = read(where);
  const name = match(pubspec, /^name:\s*(\S+)/m, where);
  const version = match(pubspec, /^version:\s*(\S+)/m, where);
  expect('Flutter package', sdk.flutter.package, name, `${where} name`);
  expect('Flutter minimum', sdk.flutter.minimum, version, `${where} version`);
  expect('Flutter constraint', sdk.flutter.constraint, `^${version}`, `${where} version (as ^x.y.z)`);
}
if (sdk.reactNative) {
  const where = 'react-native/package.json';
  const pkg = JSON.parse(read(where));
  expect('React Native package', sdk.reactNative.package, pkg.name, `${where} name`);
  expect('React Native minimum', sdk.reactNative.minimum, pkg.version, `${where} version`);
  expect('React Native constraint', sdk.reactNative.constraint, `^${pkg.version}`, `${where} version (as ^x.y.z)`);
}
expect('CLI version', cliVersion, JSON.parse(read('cli/package.json')).version, 'cli/package.json version');

if (errors.length) {
  console.error('The setup command and the SDKs have drifted apart:');
  for (const e of errors) console.error(`  - ${e}`);
  console.error('Update cli/src/constants.ts (then `cd cli && npm run test:update` and review the snapshots), or fix the SDK version.');
  process.exit(1);
}
console.log(
  `cli/src/constants.ts matches the SDKs: android ${sdk.android.version}, ios ${sdk.ios.version}, flutter ${sdk.flutter.minimum}, react-native ${sdk.reactNative.minimum} (cli ${cliVersion}).`,
);
