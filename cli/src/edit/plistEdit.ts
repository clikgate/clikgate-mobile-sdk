import { parse as parsePlist } from 'plist';
import { XmlElement, appendChildSplice, applySplices, childIndent, children, escapeText, indentUnit, lineIndent, parseXml } from './xml';

export const ASSOCIATED_DOMAINS = 'com.apple.developer.associated-domains';

/** Parses a plist (the `plist` library) and returns its top-level dictionary. */
export function readPlist(text: string): Record<string, unknown> {
  const v = parsePlist(text);
  if (v === null || typeof v !== 'object' || Array.isArray(v)) throw new Error('The plist root is not a dictionary');
  return v as Record<string, unknown>;
}

export function associatedDomains(text: string): string[] {
  const v = readPlist(text)[ASSOCIATED_DOMAINS];
  return Array.isArray(v) ? v.filter((x): x is string => typeof x === 'string') : [];
}

/** `applinks:` hosts (without `?mode=` suffixes). */
export function applinksHosts(text: string): string[] {
  return associatedDomains(text)
    .filter((d) => d.startsWith('applinks:'))
    .map((d) => d.slice('applinks:'.length).replace(/\?.*$/, '').toLowerCase());
}

function rootDict(root: XmlElement): XmlElement {
  const dict = children(root, 'dict')[0];
  if (!dict) throw new Error('The plist root is not a dictionary');
  return dict;
}

/** The value element that follows `<key>name</key>` in a dict. */
function valueFor(text: string, dict: XmlElement, key: string): XmlElement | undefined {
  const kids = dict.children;
  for (let i = 0; i < kids.length - 1; i++) {
    if (kids[i].name === 'key' && text.slice(kids[i].openEnd, kids[i].closeStart).trim() === key) return kids[i + 1];
  }
  return undefined;
}

/** Xcode writes `<dict>` at column 0 under `<plist>` and children one tab in. */
function dictChildIndent(text: string, dict: XmlElement): string {
  if (dict.children.length > 0) return lineIndent(text, dict.children[0].start);
  return lineIndent(text, dict.start) + indentUnit(text);
}

/**
 * Adds `applinks:<host>` entries, keeping every existing entry and the file's formatting.
 * Returns the text unchanged when all are present.
 */
export function addApplinks(text: string, hosts: string[]): string {
  const have = new Set(associatedDomains(text));
  const missing = hosts.map((h) => `applinks:${h}`).filter((e) => !have.has(e));
  if (missing.length === 0) return text;
  const root = parseXml(text);
  const dict = rootDict(root);
  const arr = valueFor(text, dict, ASSOCIATED_DOMAINS);
  let out: string;
  if (arr && arr.name === 'array') {
    const indent = arr.children.length ? lineIndent(text, arr.children[0].start) : childIndent(text, arr);
    out = applySplices(text, [appendChildSplice(text, arr, missing.map((e) => `${indent}<string>${escapeText(e)}</string>`).join('\n'))]);
  } else if (arr) {
    throw new Error(`${ASSOCIATED_DOMAINS} isn't an array`);
  } else {
    const indent = dictChildIndent(text, dict);
    const unit = indentUnit(text);
    const block = [
      `${indent}<key>${ASSOCIATED_DOMAINS}</key>`,
      `${indent}<array>`,
      ...missing.map((e) => `${indent}${unit}<string>${escapeText(e)}</string>`),
      `${indent}</array>`,
    ].join('\n');
    out = applySplices(text, [appendChildSplice(text, dict, block)]);
  }
  readPlist(out); // still a valid plist
  return out;
}

/** Sets a boolean key when the dict doesn't have it (never changes an existing value). */
export function addBoolIfMissing(text: string, key: string, value: boolean): string {
  if (key in readPlist(text)) return text;
  const root = parseXml(text);
  const dict = rootDict(root);
  const indent = dictChildIndent(text, dict);
  const out = applySplices(text, [
    appendChildSplice(text, dict, `${indent}<key>${escapeText(key)}</key>\n${indent}<${value ? 'true' : 'false'}/>`),
  ]);
  readPlist(out);
  return out;
}

export const APS_ENVIRONMENT = 'aps-environment';

/** The `aps-environment` entitlement (Push Notifications capability), or undefined. */
export function apsEnvironment(text: string): string | undefined {
  const v = readPlist(text)[APS_ENVIRONMENT];
  return typeof v === 'string' ? v : undefined;
}

/**
 * Sets a string key. An existing value is kept unless `overwrite` (used for a new Debug copy of the
 * Release file); an existing non-string value is never touched.
 */
export function setString(text: string, key: string, value: string, overwrite = false): string {
  const current = readPlist(text)[key];
  if (current === value) return text;
  if (current !== undefined && (!overwrite || typeof current !== 'string')) return text;
  const root = parseXml(text);
  const dict = rootDict(root);
  let out: string;
  const existing = current !== undefined ? valueFor(text, dict, key) : undefined;
  if (existing) {
    out = text.slice(0, existing.start) + `<string>${escapeText(value)}</string>` + text.slice(existing.end);
  } else {
    const indent = dictChildIndent(text, dict);
    out = applySplices(text, [appendChildSplice(text, dict, `${indent}<key>${escapeText(key)}</key>\n${indent}<string>${escapeText(value)}</string>`)]);
  }
  readPlist(out);
  return out;
}

/** A new entitlements file in Xcode's own format. */
export function newEntitlements(hosts: string[]): string {
  return [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
    '<plist version="1.0">',
    '<dict>',
    `\t<key>${ASSOCIATED_DOMAINS}</key>`,
    '\t<array>',
    ...hosts.map((h) => `\t\t<string>applinks:${h}</string>`),
    '\t</array>',
    '</dict>',
    '</plist>',
    '',
  ].join('\n');
}
