import { MARKER_END, MARKER_START } from '../constants';
import {
  type XmlElement,
  addAttributeSplice,
  appendChildSplice,
  applySplices,
  children,
  indentUnit,
  lineIndent,
  parseXml,
  type Splice,
} from './xml';

/**
 * Auto Backup and device transfer. The SDK's manifest points `android:fullBackupContent` and
 * `android:dataExtractionRules` at its own rules, which keep Clikgate's installation ID and queue
 * out of backups (a restored or transferred app is a new installation). An app that declares its
 * own rules gets a manifest-merger conflict: the setup command adds Clikgate's excludes to the
 * app's files and resolves the merge with `tools:replace` (the app's files win, now with the
 * excludes in them).
 */

/** What the SDK excludes (android/clikgate/src/main/res/xml/clikgate_*_rules.xml). */
export const CLIKGATE_BACKUP_EXCLUDES: readonly { domain: string; path: string }[] = [
  { domain: 'sharedpref', path: 'clikgate.prefs.xml' },
  { domain: 'database', path: 'clikgate_events.db' },
  { domain: 'database', path: 'clikgate_events.db-journal' },
];

export const FULL_BACKUP_ATTR = 'android:fullBackupContent';
export const DATA_EXTRACTION_ATTR = 'android:dataExtractionRules';
export const BACKUP_ATTRS = [FULL_BACKUP_ATTR, DATA_EXTRACTION_ATTR] as const;
export type BackupAttr = (typeof BACKUP_ATTRS)[number];
/** The sections of a `<data-extraction-rules>` file that need the excludes. */
export const DATA_EXTRACTION_SECTIONS = ['cloud-backup', 'device-transfer'] as const;

const TOOLS_NS = 'http://schemas.android.com/tools';
const COMMENT = 'Clikgate: keep the installation ID out of backups (a restored app is a new installation)';

export interface BackupDeclaration {
  attr: BackupAttr;
  /** The attribute's value as written (`@xml/backup_rules`). */
  value: string;
  /** The xml resource name (`backup_rules`), or undefined when the value isn't an `@xml/` reference. */
  resource?: string;
}

/** The backup attributes the app's own `<application>` declares. */
export function backupDeclarations(manifest: string): BackupDeclaration[] {
  const app = children(parseXml(manifest), 'application')[0];
  if (!app) return [];
  const out: BackupDeclaration[] = [];
  for (const attr of BACKUP_ATTRS) {
    const value = app.attrs[attr];
    if (value === undefined) continue;
    const m = /^@xml\/([A-Za-z0-9_.]+)$/.exec(value.trim());
    out.push({ attr, value, resource: m?.[1] });
  }
  return out;
}

function toolsPrefix(root: XmlElement): string | undefined {
  for (const [k, v] of Object.entries(root.attrs)) if (k.startsWith('xmlns:') && v === TOOLS_NS) return k.slice('xmlns:'.length);
  return undefined;
}

/** The attributes listed in `<application tools:replace>`. */
export function toolsReplaced(manifest: string): string[] {
  const root = parseXml(manifest);
  const prefix = toolsPrefix(root);
  const app = children(root, 'application')[0];
  if (!prefix || !app) return [];
  return (app.attrs[`${prefix}:replace`] ?? '').split(',').map((s) => s.trim()).filter(Boolean);
}

export interface TextEdit {
  text: string;
  changed: boolean;
}

/**
 * Adds `attrs` to `<application tools:replace>` (keeping what is listed already) and declares the
 * tools namespace on `<manifest>` when it's missing.
 */
export function addToolsReplace(manifest: string, attrs: string[]): TextEdit {
  let root = parseXml(manifest);
  let text = manifest;
  let prefix = toolsPrefix(root);
  if (!prefix) {
    prefix = 'tools';
    text = applySplices(text, [addAttributeSplice(text, root, 'xmlns:tools', TOOLS_NS)]);
    root = parseXml(text);
  }
  const app = children(root, 'application')[0];
  if (!app) throw new Error('No <application> element');
  const name = `${prefix}:replace`;
  const current = app.attrs[name];
  const listed = (current ?? '').split(',').map((s) => s.trim()).filter(Boolean);
  const missing = attrs.filter((a) => !listed.includes(a));
  if (missing.length === 0) return { text: manifest, changed: false };
  if (current === undefined) {
    text = applySplices(text, [addAttributeSplice(text, app, name, missing.join(','))]);
  } else {
    // Rewrite the existing attribute's value in place.
    const open = text.slice(app.start, app.openEnd);
    const m = new RegExp(`(${name.replace(':', '\\:')}\\s*=\\s*)(["'])([^"']*)\\2`).exec(open);
    if (!m) throw new Error(`Can't read ${name}`);
    const valueAt = app.start + m.index + m[1].length + 1;
    const joined = [...listed, ...missing].join(',');
    text = applySplices(text, [{ at: valueAt, remove: m[3].length, text: joined }]);
  }
  parseXml(text);
  return { text, changed: true };
}

/** The indentation unit, ignoring commented-out samples (templates indent those oddly). */
function unitOf(text: string): string {
  return indentUnit(text.replace(/<!--[\s\S]*?-->/g, ''));
}

/** Indentation for a new child of `el`: its first element child's, else el's + one unit. */
function childIndent(text: string, el: XmlElement): string {
  const first = el.children[0];
  if (first) return lineIndent(text, first.start);
  return lineIndent(text, el.start) + unitOf(text);
}

function hasExclude(section: XmlElement, e: { domain: string; path: string }): boolean {
  return children(section, 'exclude').some((x) => x.attrs.domain === e.domain && x.attrs.path === e.path);
}

function missingExcludes(section: XmlElement): { domain: string; path: string }[] {
  return CLIKGATE_BACKUP_EXCLUDES.filter((e) => !hasExclude(section, e));
}

function excludeBlock(indent: string, excludes: { domain: string; path: string }[]): string {
  return [
    `${indent}<!-- ${MARKER_START} -->`,
    `${indent}<!-- ${COMMENT} -->`,
    ...excludes.map((e) => `${indent}<exclude domain="${e.domain}" path="${e.path}" />`),
    `${indent}<!-- ${MARKER_END} -->`,
  ].join('\n');
}

/** A new `android:fullBackupContent` file: everything backed up except Clikgate's files. */
export function newFullBackupContent(): string {
  return [
    '<?xml version="1.0" encoding="utf-8"?>',
    '<!-- Android 11 and lower (android:fullBackupContent). -->',
    '<full-backup-content>',
    excludeBlock('    ', [...CLIKGATE_BACKUP_EXCLUDES]),
    '</full-backup-content>',
    '',
  ].join('\n');
}

/** A new `android:dataExtractionRules` file: everything backed up or transferred except Clikgate's files. */
export function newDataExtractionRules(): string {
  const lines = ['<?xml version="1.0" encoding="utf-8"?>', '<!-- Android 12+ (android:dataExtractionRules). -->', '<data-extraction-rules>'];
  for (const s of DATA_EXTRACTION_SECTIONS) lines.push(`    <${s}>`, excludeBlock('        ', [...CLIKGATE_BACKUP_EXCLUDES]), `    </${s}>`);
  lines.push('</data-extraction-rules>', '');
  return lines.join('\n');
}

/**
 * Adds Clikgate's excludes to a `<full-backup-content>` file. Excludes that are already there
 * (marked or not) are kept as they are; nothing is removed.
 */
export function addFullBackupExcludes(text: string): TextEdit {
  const root = parseXml(text);
  if (root.name !== 'full-backup-content') throw new Error(`Expected <full-backup-content>, found <${root.name}>`);
  const missing = missingExcludes(root);
  if (missing.length === 0) return { text, changed: false };
  const out = applySplices(text, [appendChildSplice(text, root, excludeBlock(childIndent(text, root), missing))]);
  parseXml(out);
  return { text: out, changed: true };
}

/**
 * Adds Clikgate's excludes to both sections of a `<data-extraction-rules>` file, adding a section
 * the file doesn't have. A section with only excludes keeps Android's default (everything else is
 * included), so a missing section added here changes nothing but Clikgate's files.
 */
export function addDataExtractionExcludes(text: string): TextEdit {
  const root = parseXml(text);
  if (root.name !== 'data-extraction-rules') throw new Error(`Expected <data-extraction-rules>, found <${root.name}>`);
  // Existing sections first (splices inside them never overlap), then missing sections at the end.
  const inSections: Splice[] = [];
  const absent: string[] = [];
  for (const name of DATA_EXTRACTION_SECTIONS) {
    const section = children(root, name)[0];
    if (!section) absent.push(name);
    else {
      const missing = missingExcludes(section);
      if (missing.length) inSections.push(appendChildSplice(text, section, excludeBlock(childIndent(text, section), missing)));
    }
  }
  if (inSections.length === 0 && absent.length === 0) return { text, changed: false };
  let out = applySplices(text, inSections);
  if (absent.length) {
    const r = parseXml(out);
    const indent = childIndent(out, r);
    const unit = unitOf(out);
    const block = absent.flatMap((name) => [`${indent}<${name}>`, excludeBlock(indent + unit, [...CLIKGATE_BACKUP_EXCLUDES]), `${indent}</${name}>`]).join('\n');
    out = applySplices(out, [appendChildSplice(out, r, block)]);
  }
  parseXml(out);
  return { text: out, changed: true };
}

/** Problems that would break the build or leave Clikgate's files in backups, for doctor. */
export function backupProblems(manifest: string, readXml: (resource: string) => string | null): string[] {
  const decls = backupDeclarations(manifest);
  if (decls.length === 0) return [];
  const problems: string[] = [];
  const replaced = toolsReplaced(manifest);
  const notReplaced = decls.filter((d) => !replaced.includes(d.attr)).map((d) => d.attr);
  if (notReplaced.length) problems.push(`tools:replace on <application> doesn't list ${notReplaced.join(', ')} (the manifest merge fails)`);
  for (const d of decls) {
    if (!d.resource) {
      problems.push(`${d.attr}="${d.value}" isn't an @xml/ resource`);
      continue;
    }
    const text = readXml(d.resource);
    if (text === null) {
      problems.push(`res/xml/${d.resource}.xml not found`);
      continue;
    }
    let root: XmlElement;
    try {
      root = parseXml(text);
    } catch {
      problems.push(`res/xml/${d.resource}.xml doesn't parse`);
      continue;
    }
    const sections = d.attr === FULL_BACKUP_ATTR ? [root] : DATA_EXTRACTION_SECTIONS.map((s) => children(root, s)[0]);
    if (sections.some((s) => !s || missingExcludes(s).length > 0)) problems.push(`res/xml/${d.resource}.xml doesn't exclude Clikgate's files`);
  }
  return problems;
}
