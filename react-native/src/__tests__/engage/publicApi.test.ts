/**
 * Public-API snapshot of the Engage features (api/engage-public-api.txt; part of
 * `@clikgate/react-native` since 2.1.0, re-exported by src/index.ts). After an intended API change run
 * `UPDATE_API_SNAPSHOT=1 npx jest publicApi` and commit the file.
 */
import { readFileSync, writeFileSync } from 'fs';
import { join } from 'path';

import * as api from '../../engage/index';

const ROOT = join(__dirname, '..', '..', '..');
const SNAPSHOT = join(ROOT, 'api', 'engage-public-api.txt');

function exportedTypeNames(): string[] {
  const src = readFileSync(join(ROOT, 'src', 'engage', 'index.ts'), 'utf8');
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
  it('matches api/engage-public-api.txt', () => {
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

  it('ships in the core package: main entry, one TurboModule spec library, native SDK carries Engage', () => {
    const main = require('../../index');
    for (const k of Object.keys(api))
      expect(main[k]).toBe((api as Record<string, unknown>)[k]);
    const pkg = JSON.parse(readFileSync(join(ROOT, 'package.json'), 'utf8'));
    expect(pkg.codegenConfig.ios.modulesProvider).toEqual({
      Clikgate: 'RNClikgate',
      ClikgateEngage: 'RNClikgateEngage',
    });
    const gradle = readFileSync(join(ROOT, 'android', 'build.gradle'), 'utf8');
    expect(gradle).toContain('com.clikgate:clikgate-android:');
    expect(gradle).not.toContain('clikgate-engage');
    const podspec = readFileSync(
      join(ROOT, 'clikgate-react-native.podspec'),
      'utf8'
    );
    expect(podspec).not.toContain('Clikgate/Engage');
  });
});
