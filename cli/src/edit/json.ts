import { applyEdits, modify, parse, printParseErrorCode, type FormattingOptions, type ParseError } from 'jsonc-parser';
import { SDK, TEST_LINK_DOMAIN } from '../constants';

/**
 * package.json and app.json: jsonc-parser (VS Code's JSON-with-comments parser). `modify` makes
 * minimal text edits, so key order, comments and formatting of everything else stay unchanged.
 */

export function parseJsonc<T = unknown>(text: string): T {
  const errors: ParseError[] = [];
  const v = parse(text, errors, { allowTrailingComma: true, disallowComments: false });
  if (errors.length) throw new Error(`Invalid JSON: ${printParseErrorCode(errors[0].error)} at offset ${errors[0].offset}`);
  return v as T;
}

export function formatting(text: string): FormattingOptions {
  const m = /\n([ \t]+)"/.exec(text);
  const indent = m ? m[1] : '  ';
  return {
    insertSpaces: !indent.startsWith('\t'),
    tabSize: indent.startsWith('\t') ? 1 : indent.length,
    eol: text.includes('\r\n') ? '\r\n' : '\n',
    insertFinalNewline: text.endsWith('\n'),
  };
}

/** Adds `name: range` to `dependencies`, in alphabetical position (npm's own order). */
export function addPackageDependency(text: string, name: string, range: string): string {
  const pkg = parseJsonc<Record<string, Record<string, string> | undefined>>(text);
  if (pkg.dependencies?.[name]) return text;
  const edits = modify(text, ['dependencies', name], range, {
    formattingOptions: formatting(text),
    getInsertionIndex: (props) => {
      const i = props.findIndex((p) => p.localeCompare(name, 'en') > 0);
      return i < 0 ? props.length : i;
    },
  });
  const out = applyEdits(text, edits);
  parseJsonc(out);
  return out;
}

export interface ExpoPluginProps {
  linkDomains: string[];
  testLinkDomain?: string;
}

type PluginEntry = string | [string, Record<string, unknown>?];

export function findClikgatePlugin(appJson: unknown): { index: number; props?: Record<string, unknown> } | undefined {
  const plugins = expoRoot(appJson)?.plugins as PluginEntry[] | undefined;
  if (!Array.isArray(plugins)) return undefined;
  const index = plugins.findIndex((p) => (Array.isArray(p) ? p[0] : p) === SDK.reactNative.package);
  if (index < 0) return undefined;
  const entry = plugins[index];
  return { index, props: Array.isArray(entry) ? (entry[1] as Record<string, unknown> | undefined) : undefined };
}

/** app.json may hold `{expo: {...}}` or the config directly. */
export function expoRoot(appJson: unknown): Record<string, unknown> | undefined {
  if (!appJson || typeof appJson !== 'object') return undefined;
  const o = appJson as Record<string, unknown>;
  if (o.expo && typeof o.expo === 'object') return o.expo as Record<string, unknown>;
  return o;
}

function rootPath(appJson: unknown): (string | number)[] {
  return appJson && typeof appJson === 'object' && 'expo' in (appJson as object) ? ['expo'] : [];
}

/**
 * Adds (or completes) the `@clikgate/react-native` config plugin entry. Existing props are kept;
 * missing link domains are appended.
 */
export function addExpoPlugin(text: string, props: ExpoPluginProps): string {
  const json = parseJsonc(text);
  const base = rootPath(json);
  const fmt = { formattingOptions: formatting(text) };
  const found = findClikgatePlugin(json);
  let out = text;
  if (!found) {
    const plugins = expoRoot(json)?.plugins;
    const entry: PluginEntry = [SDK.reactNative.package, { linkDomains: props.linkDomains, ...(props.testLinkDomain ? { testLinkDomain: props.testLinkDomain } : {}) }];
    if (Array.isArray(plugins)) {
      out = applyEdits(out, modify(out, [...base, 'plugins', -1], entry, { ...fmt, isArrayInsertion: true }));
    } else {
      out = applyEdits(out, modify(out, [...base, 'plugins'], [entry], fmt));
    }
  } else {
    const current = found.props ?? {};
    if (!found.props) {
      out = applyEdits(out, modify(out, [...base, 'plugins', found.index], [SDK.reactNative.package, {}], fmt));
    }
    const have = Array.isArray(current.linkDomains) ? (current.linkDomains as string[]) : [];
    const missing = props.linkDomains.filter((d) => !have.includes(d));
    if (missing.length || !Array.isArray(current.linkDomains)) {
      out = applyEdits(out, modify(out, [...base, 'plugins', found.index, 1, 'linkDomains'], [...have, ...missing], fmt));
    }
    if (props.testLinkDomain && current.testLinkDomain !== props.testLinkDomain) {
      out = applyEdits(out, modify(out, [...base, 'plugins', found.index, 1, 'testLinkDomain'], props.testLinkDomain, fmt));
    }
  }
  parseJsonc(out);
  return out;
}

/** Sets a string at a path inside the expo config only when it's missing. */
export function setExpoValueIfMissing(text: string, path: string[], value: string): string {
  const json = parseJsonc(text);
  let cur: unknown = expoRoot(json);
  for (const k of path) cur = cur && typeof cur === 'object' ? (cur as Record<string, unknown>)[k] : undefined;
  if (cur !== undefined) return text;
  const out = applyEdits(text, modify(text, [...rootPath(json), ...path], value, { formattingOptions: formatting(text) }));
  parseJsonc(out);
  return out;
}

export { TEST_LINK_DOMAIN };
