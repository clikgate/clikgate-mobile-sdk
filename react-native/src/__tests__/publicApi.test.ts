/**
 * Public-API snapshot and core/Engage boundary checks (spec v3 section 20).
 *
 * The listing (runtime exports, the members of `Clikgate` and `referrals`, and the exported type
 * names of src/index.ts) must equal the checked-in api/public-api.txt. After an intended API
 * change run `UPDATE_API_SNAPSHOT=1 npx jest publicApi` and commit the file.
 */
import { readdirSync, readFileSync, statSync, writeFileSync } from 'fs';
import { join } from 'path';

import * as api from '../index';

jest.mock('../NativeClikgate', () => ({ __esModule: true, default: null }));

const ROOT = join(__dirname, '..', '..');
const SNAPSHOT = join(ROOT, 'api', 'public-api.txt');

/** Core must not contain referrer-side / Engage API (spec 0.4). Case-insensitive. */
const FORBIDDEN = [
  'leaderboard',
  'createlink',
  'mystats',
  'referrallink',
  'referralstats',
  'redeem',
  'redemption',
  'share',
  'whatsapp',
  'identitysignal',
  'identity_signal',
  'myrank',
  'hostedpage',
];

function exportedTypeNames(): string[] {
  const src = readFileSync(join(ROOT, 'src', 'index.ts'), 'utf8');
  const names: string[] = [];
  for (const m of src.matchAll(/export\s+(type\s+)?\{([^}]*)\}/g)) {
    const whole = m[1] != null;
    for (const raw of m[2]!.split(',')) {
      const item = raw.trim();
      if (item.length === 0) continue;
      if (whole || item.startsWith('type ')) {
        names.push(
          item
            .replace(/^type\s+/, '')
            .split(/\s+as\s+/)
            .pop()!
        );
      }
    }
  }
  return names;
}

function listing(): string {
  const lines: string[] = [];
  for (const k of Object.keys(api).sort()) lines.push(`export ${k}`);
  for (const k of Object.keys(api.Clikgate).sort()) lines.push(`Clikgate.${k}`);
  for (const k of Object.keys(api.referrals).sort())
    lines.push(`Clikgate.referrals.${k}`);
  for (const k of Object.getOwnPropertyNames(api.ClikgateError)
    .filter((n) => !['length', 'name', 'prototype'].includes(n))
    .sort())
    lines.push(`ClikgateError.${k}`);
  for (const t of exportedTypeNames().sort()) lines.push(`type ${t}`);
  return lines.join('\n') + '\n';
}

function sourceFiles(dir: string): string[] {
  return readdirSync(dir).flatMap((n) => {
    const p = join(dir, n);
    if (statSync(p).isDirectory())
      return n === '__tests__' ? [] : sourceFiles(p);
    return /\.tsx?$/.test(n) ? [p] : [];
  });
}

describe('public API (core)', () => {
  it('matches api/public-api.txt', () => {
    const current = listing();
    if (process.env.UPDATE_API_SNAPSHOT === '1')
      writeFileSync(SNAPSHOT, current);
    expect(current).toBe(readFileSync(SNAPSHOT, 'utf8'));
  });

  it('has no leaderboard, referral-stats, link-creation, code, share or identity-signal API', () => {
    const offending = listing()
      .split('\n')
      .filter((l) => FORBIDDEN.some((t) => l.toLowerCase().includes(t)));
    expect(offending).toEqual([]);
  });

  it('never depends on or imports the Engage add-on', () => {
    const pkg = JSON.parse(readFileSync(join(ROOT, 'package.json'), 'utf8'));
    for (const section of [
      'dependencies',
      'peerDependencies',
      'optionalDependencies',
      'devDependencies',
    ]) {
      expect(Object.keys(pkg[section] ?? {})).not.toContain(
        '@clikgate/react-native-engage'
      );
    }
    const importers = sourceFiles(join(ROOT, 'src')).filter((f) =>
      /(from\s+|require\(\s*|import\(\s*)['"]@clikgate\/react-native-engage/.test(
        readFileSync(f, 'utf8')
      )
    );
    expect(importers).toEqual([]);
  });
});
