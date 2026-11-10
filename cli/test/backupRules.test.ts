import * as fs from 'node:fs';
import * as path from 'node:path';
import { describe, expect, it, vi } from 'vitest';
import type { DoctorReport } from '../src/doctor';
import {
  CLIKGATE_BACKUP_EXCLUDES,
  addDataExtractionExcludes,
  addFullBackupExcludes,
  addToolsReplace,
  backupDeclarations,
  backupProblems,
  newDataExtractionRules,
  newFullBackupContent,
  toolsReplaced,
} from '../src/edit/backupRules';
import { parseXml } from '../src/edit/xml';
import { main } from '../src/index';
import { OFFLINE, ScriptedUI, copyFixture, snapshotTree } from './helpers';

const MANIFEST = `<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">

    <application
        android:allowBackup="true"
        android:dataExtractionRules="@xml/data_extraction_rules"
        android:fullBackupContent="@xml/backup_rules"
        android:label="@string/app_name">
        <activity android:name=".MainActivity" android:exported="true" />
    </application>

</manifest>
`;

function excludes(xml: string): string[] {
  return [...xml.matchAll(/<exclude domain="([^"]+)" path="([^"]+)"/g)].map((m) => `${m[1]}:${m[2]}`);
}
const ALL = CLIKGATE_BACKUP_EXCLUDES.map((e) => `${e.domain}:${e.path}`);

describe('backup rules: manifest', () => {
  it('reads the backup attributes the app declares', () => {
    expect(backupDeclarations(MANIFEST)).toEqual([
      { attr: 'android:fullBackupContent', value: '@xml/backup_rules', resource: 'backup_rules' },
      { attr: 'android:dataExtractionRules', value: '@xml/data_extraction_rules', resource: 'data_extraction_rules' },
    ]);
    expect(backupDeclarations('<manifest><application android:allowBackup="false"/></manifest>')).toEqual([]);
    expect(backupDeclarations('<manifest><application android:fullBackupContent="false"/></manifest>')[0].resource).toBeUndefined();
  });

  it('declares the tools namespace and adds tools:replace, once', () => {
    const attrs = ['android:fullBackupContent', 'android:dataExtractionRules'];
    const first = addToolsReplace(MANIFEST, attrs);
    expect(first.changed).toBe(true);
    expect(first.text).toContain('xmlns:tools="http://schemas.android.com/tools"');
    expect(toolsReplaced(first.text)).toEqual(attrs);
    expect(first.text).toContain('        android:label="@string/app_name"\n        tools:replace="android:fullBackupContent,android:dataExtractionRules">');
    // Everything else byte for byte.
    expect(first.text.replace(/\s*xmlns:tools="[^"]*"/, '').replace(/\s*tools:replace="[^"]*"/, '')).toBe(MANIFEST);
    expect(addToolsReplace(first.text, attrs)).toEqual({ text: first.text, changed: false });
  });

  it('keeps what tools:replace already lists and uses the declared prefix', () => {
    const m = MANIFEST.replace('<manifest ', '<manifest xmlns:t="http://schemas.android.com/tools" ').replace(
      'android:label="@string/app_name"',
      'android:label="@string/app_name"\n        t:replace="android:label"'
    );
    const out = addToolsReplace(m, ['android:fullBackupContent']);
    expect(out.text).toContain('t:replace="android:label,android:fullBackupContent"');
    expect(out.text).not.toContain('xmlns:tools');
    expect(addToolsReplace(out.text, ['android:fullBackupContent']).changed).toBe(false);
  });
});

describe('backup rules: rules files', () => {
  it('adds the excludes to <full-backup-content>, once, keeping the app\'s rules', () => {
    const app = '<?xml version="1.0" encoding="utf-8"?>\n<full-backup-content>\n    <include domain="sharedpref" path="." />\n    <exclude domain="sharedpref" path="device.xml" />\n</full-backup-content>\n';
    const out = addFullBackupExcludes(app);
    expect(out.changed).toBe(true);
    expect(excludes(out.text)).toEqual(['sharedpref:device.xml', ...ALL]);
    expect(out.text).toContain('    <include domain="sharedpref" path="." />');
    expect(addFullBackupExcludes(out.text)).toEqual({ text: out.text, changed: false });
  });

  it('adds only the excludes that are missing', () => {
    const app = '<full-backup-content>\n  <exclude domain="sharedpref" path="clikgate.prefs.xml"/>\n</full-backup-content>\n';
    const out = addFullBackupExcludes(app);
    expect(excludes(out.text)).toEqual(['sharedpref:clikgate.prefs.xml', 'database:clikgate_events.db', 'database:clikgate_events.db-journal']);
    expect(out.text).toContain('\n  <exclude domain="database" path="clikgate_events.db" />');
  });

  it('expands a self-closing <full-backup-content/>', () => {
    const out = addFullBackupExcludes('<?xml version="1.0" encoding="utf-8"?>\n<full-backup-content />\n');
    expect(excludes(out.text)).toEqual(ALL);
    parseXml(out.text);
  });

  it('adds the excludes to both data extraction sections, adding a missing section', () => {
    const app = [
      '<?xml version="1.0" encoding="utf-8"?>',
      '<data-extraction-rules>',
      '    <cloud-backup disableIfNoEncryptionCapabilities="true">',
      '        <include domain="file" path="." />',
      '    </cloud-backup>',
      '</data-extraction-rules>',
      '',
    ].join('\n');
    const out = addDataExtractionExcludes(app);
    expect(out.changed).toBe(true);
    const root = parseXml(out.text);
    const cloud = root.children.find((c) => c.name === 'cloud-backup')!;
    const transfer = root.children.find((c) => c.name === 'device-transfer')!;
    expect(cloud.attrs.disableIfNoEncryptionCapabilities).toBe('true');
    expect(excludes(out.text.slice(cloud.start, cloud.end))).toEqual(ALL);
    expect(excludes(out.text.slice(transfer.start, transfer.end))).toEqual(ALL);
    expect(out.text).toContain('        <include domain="file" path="." />');
    expect(addDataExtractionExcludes(out.text)).toEqual({ text: out.text, changed: false });
  });

  it('adds both sections to an empty <data-extraction-rules>', () => {
    const out = addDataExtractionExcludes('<data-extraction-rules>\n</data-extraction-rules>\n');
    expect(out.text.match(/<cloud-backup>/g)).toHaveLength(1);
    expect(out.text.match(/<device-transfer>/g)).toHaveLength(1);
    expect(excludes(out.text)).toEqual([...ALL, ...ALL]);
  });

  it('refuses a file of the wrong kind', () => {
    expect(() => addFullBackupExcludes('<data-extraction-rules/>')).toThrow(/full-backup-content/);
    expect(() => addDataExtractionExcludes('<full-backup-content/>')).toThrow(/data-extraction-rules/);
  });

  it('writes new files that need nothing more', () => {
    expect(addFullBackupExcludes(newFullBackupContent()).changed).toBe(false);
    expect(addDataExtractionExcludes(newDataExtractionRules()).changed).toBe(false);
  });
});

describe('backup rules: doctor problems', () => {
  const files: Record<string, string> = { backup_rules: newFullBackupContent(), data_extraction_rules: newDataExtractionRules() };
  const read = (r: string) => files[r] ?? null;
  const fixed = addToolsReplace(MANIFEST, ['android:fullBackupContent', 'android:dataExtractionRules']).text;

  it('none when the app declares no rules or everything is in place', () => {
    expect(backupProblems('<manifest><application/></manifest>', () => null)).toEqual([]);
    expect(backupProblems(fixed, read)).toEqual([]);
  });

  it('names a missing tools:replace, a missing file and missing excludes', () => {
    expect(backupProblems(MANIFEST, read)).toEqual([
      "tools:replace on <application> doesn't list android:fullBackupContent, android:dataExtractionRules (the manifest merge fails)",
    ]);
    expect(backupProblems(fixed, (r) => (r === 'backup_rules' ? null : files[r]))).toEqual(['res/xml/backup_rules.xml not found']);
    const halfDone = newDataExtractionRules().replace(/<device-transfer>[\s\S]*<\/device-transfer>/, '');
    expect(backupProblems(fixed, (r) => (r === 'data_extraction_rules' ? halfDone : files[r]))).toEqual([
      "res/xml/data_extraction_rules.xml doesn't exclude Clikgate's files",
    ]);
  });
});

async function doctorJson(dir: string): Promise<DoctorReport> {
  let out = '';
  const spy = vi.spyOn(process.stdout, 'write').mockImplementation((chunk: string | Uint8Array) => {
    out += chunk.toString();
    return true;
  });
  try {
    await main(['doctor', '--json', '--cwd', dir, '--domain', 'acme.ciz.to,go.acme.com'], { ui: new ScriptedUI([], false) });
    return JSON.parse(out) as DoctorReport;
  } finally {
    spy.mockRestore();
  }
}

describe('backup rules: setup and doctor on a project', () => {
  it('creates rules files the app references but lacks, and a second run changes nothing', async () => {
    const dir = copyFixture('android-views');
    const xml = path.join(dir, 'app/src/main/res/xml');
    fs.rmSync(xml, { recursive: true });
    expect(await main(['--cwd', dir, ...OFFLINE], { ui: new ScriptedUI() })).toBe(0);
    expect(excludes(fs.readFileSync(path.join(xml, 'backup_rules.xml'), 'utf8'))).toEqual(ALL);
    expect(excludes(fs.readFileSync(path.join(xml, 'data_extraction_rules.xml'), 'utf8'))).toEqual([...ALL, ...ALL]);
    const after = snapshotTree(dir);
    const ui = new ScriptedUI();
    expect(await main(['--cwd', dir, ...OFFLINE], { ui })).toBe(0);
    expect(snapshotTree(dir)).toEqual(after);
    expect(ui.text).toContain("Android: backup rules exclude Clikgate's installation ID");
  });

  it('doctor fails before setup and passes after it', async () => {
    const dir = copyFixture('android-compose');
    const before = await doctorJson(dir);
    expect(before.checks.find((c) => c.id === 'android.backup_rules')).toMatchObject({ status: 'fail' });
    expect(await main(['--cwd', dir, ...OFFLINE], { ui: new ScriptedUI() })).toBe(0);
    const after = await doctorJson(dir);
    expect(after.checks.find((c) => c.id === 'android.backup_rules')).toMatchObject({ status: 'pass' });
  });

  it('leaves apps without their own backup rules alone', async () => {
    const dir = copyFixture('react-native');
    expect(await main(['--cwd', dir, ...OFFLINE], { ui: new ScriptedUI() })).toBe(0);
    const report = await doctorJson(dir);
    expect(report.checks.find((c) => c.id === 'android.backup_rules')).toBeUndefined();
  });
});
