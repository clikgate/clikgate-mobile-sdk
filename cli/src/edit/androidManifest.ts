import { MARKER_END, MARKER_START } from '../constants';
import {
  XmlElement,
  addAttributeSplice,
  appendChildSplice,
  applySplices,
  childIndent,
  children,
  findAll,
  indentUnit,
  lineIndent,
  parseXml,
  type Splice,
} from './xml';

const VIEW = 'android.intent.action.VIEW';
const MAIN = 'android.intent.action.MAIN';
const LAUNCHER = 'android.intent.category.LAUNCHER';

function actions(f: XmlElement): string[] {
  return children(f, 'action').map((a) => a.attrs['android:name']).filter(Boolean);
}
function categories(f: XmlElement): string[] {
  return children(f, 'category').map((a) => a.attrs['android:name']).filter(Boolean);
}
function dataAttr(f: XmlElement, attr: string): string[] {
  return children(f, 'data').map((d) => d.attrs[attr]).filter((v): v is string => typeof v === 'string');
}

export function activities(root: XmlElement): XmlElement[] {
  const app = children(root, 'application')[0];
  if (!app) return [];
  return [...children(app, 'activity'), ...children(app, 'activity-alias')];
}

/** The activity with the MAIN/LAUNCHER intent filter (the one Clikgate links open). */
export function launcherActivity(root: XmlElement): XmlElement | undefined {
  return activities(root).find((a) =>
    children(a, 'intent-filter').some((f) => actions(f).includes(MAIN) && categories(f).includes(LAUNCHER))
  );
}

export interface AppLinkFilter {
  activity: string;
  hosts: string[];
  autoVerify: boolean;
}

/** Every https VIEW intent filter in the manifest, with its hosts. */
export function appLinkFilters(text: string): AppLinkFilter[] {
  const root = parseXml(text);
  const out: AppLinkFilter[] = [];
  for (const a of activities(root)) {
    for (const f of children(a, 'intent-filter')) {
      if (!actions(f).includes(VIEW)) continue;
      const schemes = dataAttr(f, 'android:scheme');
      if (!schemes.includes('https')) continue;
      out.push({
        activity: a.attrs['android:name'] ?? '',
        hosts: dataAttr(f, 'android:host').map((h) => h.toLowerCase()),
        autoVerify: f.attrs['android:autoVerify'] === 'true',
      });
    }
  }
  return out;
}

/** Hosts with a verified (`autoVerify="true"`) https filter. */
export function verifiedHosts(text: string): Set<string> {
  return new Set(appLinkFilters(text).filter((f) => f.autoVerify).flatMap((f) => f.hosts));
}

export function allLinkHosts(text: string): Set<string> {
  return new Set(appLinkFilters(text).flatMap((f) => f.hosts));
}

function filterBlock(indent: string, unit: string, hosts: string[], comment: string, metaData: string | null): string {
  const i1 = indent + unit;
  const lines = [
    `${indent}<!-- ${MARKER_START} -->`,
    `${indent}<!-- ${comment} -->`,
  ];
  if (metaData) lines.push(`${indent}${metaData}`);
  if (hosts.length > 0) {
    lines.push(
      `${indent}<intent-filter android:autoVerify="true">`,
      `${i1}<action android:name="${VIEW}" />`,
      `${i1}<category android:name="android.intent.category.DEFAULT" />`,
      `${i1}<category android:name="android.intent.category.BROWSABLE" />`,
      `${i1}<data android:scheme="https" />`,
      ...hosts.map((h) => `${i1}<data android:host="${h}" />`),
      `${indent}</intent-filter>`
    );
  }
  lines.push(`${indent}<!-- ${MARKER_END} -->`);
  return lines.join('\n');
}

/** A Clikgate-marked verified filter inside the activity, to extend instead of adding another. */
function markedFilter(text: string, activity: XmlElement): XmlElement | undefined {
  return children(activity, 'intent-filter').find((f) => {
    if (f.attrs['android:autoVerify'] !== 'true' || !actions(f).includes(VIEW)) return false;
    const before = text.slice(Math.max(activity.openEnd, f.start - 400), f.start);
    const lastStart = before.lastIndexOf(MARKER_START);
    return lastStart >= 0 && before.lastIndexOf(MARKER_END) < lastStart;
  });
}

export interface ManifestEdit {
  text: string;
  added: string[];
  changed: boolean;
}

export interface AddLinksOptions {
  /** android:name of the activity that receives links (as written in the main manifest). */
  activityName: string;
  hosts: string[];
  comment: string;
  /** Flutter: add `flutter_deeplinking_enabled=false` so Flutter's own router doesn't also handle links. */
  flutterDeepLinkingOff?: boolean;
}

/**
 * Adds a verified https intent filter for each missing host to the activity. Existing intent
 * filters, attributes and comments are kept byte for byte; only new lines are inserted.
 */
export function addAppLinks(text: string, opts: AddLinksOptions): ManifestEdit {
  const root = parseXml(text);
  const have = verifiedHosts(text);
  const missing = opts.hosts.filter((h) => !have.has(h));
  const activity = activities(root).find((a) => a.attrs['android:name'] === opts.activityName);
  if (!activity) throw new Error(`Activity ${opts.activityName} not found`);
  const wantMeta =
    opts.flutterDeepLinkingOff === true &&
    findAll(root, (e) => e.name === 'meta-data' && e.attrs['android:name'] === 'flutter_deeplinking_enabled').length === 0;
  if (missing.length === 0 && !wantMeta) return { text, added: [], changed: false };

  const unit = indentUnit(text);
  const marked = markedFilter(text, activity);
  const splices: Splice[] = [];
  if (marked && missing.length > 0 && !wantMeta) {
    const dataIndent = childIndent(text, marked);
    splices.push(appendChildSplice(text, marked, missing.map((h) => `${dataIndent}<data android:host="${h}" />`).join('\n')));
  } else {
    const indent = childIndent(text, activity);
    const meta = wantMeta ? '<meta-data android:name="flutter_deeplinking_enabled" android:value="false" />' : null;
    splices.push(appendChildSplice(text, activity, filterBlock(indent, unit, missing, opts.comment, meta)));
  }
  const out = applySplices(text, splices);
  parseXml(out); // must still be well-formed
  return { text: out, added: missing, changed: true };
}

/** A new debug-only manifest that adds the test domain to the launcher activity. */
export function newDebugManifest(activityName: string, hosts: string[]): string {
  const unit = '    ';
  return [
    '<?xml version="1.0" encoding="utf-8"?>',
    '<!-- Debug builds only: merged into the main manifest by the Android build. -->',
    '<manifest xmlns:android="http://schemas.android.com/apk/res/android">',
    `${unit}<application>`,
    `${unit}${unit}<activity android:name="${activityName}">`,
    filterBlock(unit.repeat(3), unit, hosts, 'Clikgate test links (debug builds only)', null),
    `${unit}${unit}</activity>`,
    `${unit}</application>`,
    '</manifest>',
    '',
  ].join('\n');
}

/**
 * Debug manifest: adds the activity element (merged with the main one) if needed, then the
 * filter. Creates `<application>` when the manifest has none (Flutter's debug manifest).
 */
export function addDebugAppLinks(text: string, activityName: string, hosts: string[]): ManifestEdit {
  const root = parseXml(text);
  const have = verifiedHosts(text);
  const missing = hosts.filter((h) => !have.has(h));
  if (missing.length === 0) return { text, added: [], changed: false };
  const existing = activities(root).find((a) => a.attrs['android:name'] === activityName);
  if (existing) return addAppLinks(text, { activityName, hosts: missing, comment: 'Clikgate test links (debug builds only)' });

  const unit = indentUnit(text);
  const app = children(root, 'application')[0];
  let out: string;
  if (app) {
    const indent = childIndent(text, app);
    const block = [
      `${indent}<activity android:name="${activityName}">`,
      filterBlock(indent + unit, unit, missing, 'Clikgate test links (debug builds only)', null),
      `${indent}</activity>`,
    ].join('\n');
    out = applySplices(text, [appendChildSplice(text, app, block)]);
  } else {
    const indent = childIndent(text, root);
    const block = [
      `${indent}<application>`,
      `${indent}${unit}<activity android:name="${activityName}">`,
      filterBlock(indent + unit + unit, unit, missing, 'Clikgate test links (debug builds only)', null),
      `${indent}${unit}</activity>`,
      `${indent}</application>`,
    ].join('\n');
    out = applySplices(text, [appendChildSplice(text, root, block)]);
  }
  parseXml(out);
  return { text: out, added: missing, changed: true };
}

/** `<application android:name>` or undefined. */
export function applicationName(text: string): string | undefined {
  const app = children(parseXml(text), 'application')[0];
  return app?.attrs['android:name'];
}

/** Registers an Application class on `<application>` (only when it has no android:name). */
export function setApplicationName(text: string, name: string): string {
  const root = parseXml(text);
  const app = children(root, 'application')[0];
  if (!app) throw new Error('No <application> element');
  if (app.attrs['android:name']) return text;
  return applySplices(text, [addAttributeSplice(text, app, 'android:name', name)]);
}

export { lineIndent };
