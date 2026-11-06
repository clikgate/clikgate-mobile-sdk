#!/usr/bin/env node
// iOS project-file validation without a Mac (S.8): after `setup`, every edited Info.plist,
// entitlements file and project.pbxproj must parse, each app-target configuration must point
// CODE_SIGN_ENTITLEMENTS at an existing file, Release/Profile must list the live domains and
// never the test domain, and Debug must also list the test domain.
//
// Usage: node scripts/validate-ios.mjs <ios-folder> --live ciz.to,go.example.com [--test dev.ciz.to]
import fs from 'node:fs';
import path from 'node:path';
import xcodeJson from '@bacons/xcode/json';
import { parse as parsePlist } from 'plist';

const parsePbxproj = xcodeJson.parse;

const args = process.argv.slice(2);
const dir = args[0];
const opt = (name, def) => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : def;
};
const live = (opt('--live', '') || '').split(',').filter(Boolean);
const test = opt('--test', 'dev.ciz.to');
if (!dir || live.length === 0) {
  console.error('Usage: validate-ios.mjs <ios-folder> --live <host>[,<host>] [--test dev.ciz.to]');
  process.exit(2);
}

let failures = 0;
const fail = (m) => {
  failures++;
  console.error(`✗ ${m}`);
};
const ok = (m) => console.log(`✓ ${m}`);

const projects = fs.readdirSync(dir).filter((n) => n.endsWith('.xcodeproj') && n !== 'Pods.xcodeproj');
if (projects.length === 0) fail(`no .xcodeproj in ${dir}`);
for (const p of projects) {
  const pbxPath = path.join(dir, p, 'project.pbxproj');
  let project;
  try {
    project = parsePbxproj(fs.readFileSync(pbxPath, 'utf8'));
    ok(`${p}/project.pbxproj parses`);
  } catch (e) {
    fail(`${p}/project.pbxproj doesn't parse: ${e.message}`);
    continue;
  }
  const objects = project.objects;
  const apps = Object.values(objects).filter((o) => o.isa === 'PBXNativeTarget' && String(o.productType).replace(/"/g, '') === 'com.apple.product-type.application');
  for (const t of apps) {
    for (const id of objects[t.buildConfigurationList].buildConfigurations) {
      const c = objects[id];
      const name = String(c.name);
      const debug = /debug/i.test(name);
      const ent = c.buildSettings.CODE_SIGN_ENTITLEMENTS;
      if (!ent) {
        fail(`${t.name} ${name}: CODE_SIGN_ENTITLEMENTS not set`);
        continue;
      }
      const file = path.join(dir, String(ent).replace(/^"|"$/g, ''));
      if (!fs.existsSync(file)) {
        fail(`${t.name} ${name}: ${ent} doesn't exist`);
        continue;
      }
      let plist;
      try {
        plist = parsePlist(fs.readFileSync(file, 'utf8'));
      } catch (e) {
        fail(`${ent} doesn't parse: ${e.message}`);
        continue;
      }
      const domains = (plist['com.apple.developer.associated-domains'] || []).map((d) => String(d).replace(/^applinks:/, '').replace(/\?.*$/, ''));
      for (const h of live) if (!domains.includes(h)) fail(`${t.name} ${name}: ${ent} misses applinks:${h}`);
      if (debug && !domains.includes(test)) fail(`${t.name} ${name}: ${ent} misses applinks:${test}`);
      if (!debug && domains.includes(test)) fail(`${t.name} ${name}: ${ent} has applinks:${test} (release builds must not)`);
      if (!failures) ok(`${t.name} ${name}: ${ent} → ${domains.join(', ')}`);
      const info = c.buildSettings.INFOPLIST_FILE;
      if (info) {
        const infoPath = path.join(dir, String(info).replace(/^"|"$/g, ''));
        try {
          parsePlist(fs.readFileSync(infoPath, 'utf8'));
        } catch (e) {
          fail(`${info} doesn't parse: ${e.message}`);
        }
      }
    }
  }
}
if (failures) {
  console.error(`${failures} problem(s)`);
  process.exit(1);
}
console.log('iOS project files are valid.');
