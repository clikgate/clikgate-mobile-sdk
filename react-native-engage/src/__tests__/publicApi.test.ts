/**
 * Public-API snapshot of the Engage add-on (api/public-api.txt) and its package boundary: pure
 * TypeScript (no native code), depends on the core package only as a peer. After an intended API
 * change run `UPDATE_API_SNAPSHOT=1 npx jest publicApi` and commit the file.
 */
import { existsSync, readFileSync, writeFileSync } from 'fs';
import { join } from 'path';

import * as api from '../index';

const ROOT = join(__dirname, '..', '..');
const SNAPSHOT = join(ROOT, 'api', 'public-api.txt');

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
  for (const k of ['version', 'cacheTtlMs']) lines.push(`ClikgateEngage.${k}`);
  const engage = new api.ClikgateEngage({ fetch: jest.fn() });
  const proto = Object.getOwnPropertyNames(api.ClikgateEngage.prototype)
    .filter((n) => n !== 'constructor')
    .sort();
  for (const k of proto) lines.push(`engage.${k}()`);
  for (const group of [
    'referrals',
    'share',
    'leaderboards',
    'codes',
  ] as const) {
    for (const k of Object.keys(engage[group]).sort())
      lines.push(`engage.${group}.${k}`);
  }
  for (const k of Object.keys(api.EngageErrorCodes).sort())
    lines.push(`EngageErrorCodes.${k}`);
  for (const t of exportedTypeNames().sort()) lines.push(`type ${t}`);
  return lines.join('\n') + '\n';
}

describe('public API (Engage)', () => {
  it('matches api/public-api.txt', () => {
    const current = listing();
    if (process.env.UPDATE_API_SNAPSHOT === '1')
      writeFileSync(SNAPSHOT, current);
    expect(current).toBe(readFileSync(SNAPSHOT, 'utf8'));
  });

  it('has the 17A.2 surface', () => {
    const l = listing();
    for (const m of [
      'engage.referrals.createLink',
      'engage.referrals.myStats',
      'engage.share.system',
      'engage.share.whatsApp',
      'engage.share.link',
      'engage.share.referralLink',
      'engage.leaderboards.top',
      'engage.leaderboards.me',
      'engage.leaderboards.aroundMe',
      'engage.leaderboards.setOptOut',
      'engage.leaderboards.hostedPageUrl',
      'engage.codes.redeem',
      'engage.clearCache()',
    ]) {
      expect(l).toContain(m + '\n');
    }
  });

  it('depends on the core only as a peer; native code is only the share bridge (Change 13)', () => {
    const pkg = JSON.parse(readFileSync(join(ROOT, 'package.json'), 'utf8'));
    expect(pkg.peerDependencies['@clikgate/react-native']).toBeDefined();
    expect(Object.keys(pkg.dependencies ?? {})).toEqual([]);
    expect(pkg.codegenConfig.ios.modulesProvider).toEqual({
      ClikgateEngage: 'RNClikgateEngage',
    });
    expect(existsSync(join(ROOT, 'react-native.config.js'))).toBe(false);
    const gradle = readFileSync(join(ROOT, 'android', 'build.gradle'), 'utf8');
    expect(gradle).toContain('com.clikgate:clikgate-engage:');
    expect(gradle).not.toContain('com.clikgate:clikgate-android:');
    const podspec = readFileSync(
      join(ROOT, 'clikgate-react-native-engage.podspec'),
      'utf8'
    );
    expect(podspec).toContain('"Clikgate/Engage"');
  });
});
