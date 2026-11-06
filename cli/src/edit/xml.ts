import { SaxesParser } from 'saxes';

/**
 * A located XML element: the parser (saxes, a strict XML parser) gives source offsets, so edits
 * splice text into the original string and keep every byte of existing formatting.
 */
export interface XmlElement {
  name: string;
  attrs: Record<string, string>;
  /** Offset of `<`. */
  start: number;
  /** Offset just after the `>` of the opening tag. */
  openEnd: number;
  /** Offset of `</` (equal to openEnd for self-closing tags). */
  closeStart: number;
  /** Offset just after the closing `>`. */
  end: number;
  selfClosing: boolean;
  children: XmlElement[];
  parent?: XmlElement;
}

export class XmlParseError extends Error {}

export function parseXml(text: string): XmlElement {
  const parser = new SaxesParser({ xmlns: false, position: true });
  const stack: XmlElement[] = [];
  let root: XmlElement | undefined;
  let error: Error | undefined;
  parser.on('error', (e) => {
    error ??= e;
  });
  parser.on('opentagstart', (tag) => {
    const start = text.lastIndexOf('<', parser.position - 1);
    const el: XmlElement = {
      name: tag.name,
      attrs: {},
      start,
      openEnd: -1,
      closeStart: -1,
      end: -1,
      selfClosing: false,
      children: [],
      parent: stack[stack.length - 1],
    };
    if (el.parent) el.parent.children.push(el);
    else root = el;
    stack.push(el);
  });
  parser.on('opentag', (tag) => {
    const el = stack[stack.length - 1];
    for (const [k, v] of Object.entries(tag.attributes)) el.attrs[k] = typeof v === 'string' ? v : String((v as { value?: string }).value ?? '');
    el.openEnd = parser.position;
    el.selfClosing = tag.isSelfClosing;
  });
  parser.on('closetag', () => {
    const el = stack.pop()!;
    el.end = parser.position;
    el.closeStart = el.selfClosing ? el.openEnd : text.lastIndexOf('</', el.end - 1);
  });
  parser.write(text).close();
  if (error) throw new XmlParseError(error.message);
  if (!root) throw new XmlParseError('No root element');
  return root;
}

export function children(el: XmlElement, name: string): XmlElement[] {
  return el.children.filter((c) => c.name === name);
}

export function findAll(el: XmlElement, pred: (e: XmlElement) => boolean, out: XmlElement[] = []): XmlElement[] {
  if (pred(el)) out.push(el);
  for (const c of el.children) findAll(c, pred, out);
  return out;
}

/** The whitespace at the start of the line containing `offset`. */
export function lineIndent(text: string, offset: number): string {
  const lineStart = text.lastIndexOf('\n', offset - 1) + 1;
  const m = /^[ \t]*/.exec(text.slice(lineStart));
  return m ? m[0] : '';
}

/** The indentation step used in the file (tab, or the smallest space indent seen), default 4 spaces. */
export function indentUnit(text: string): string {
  if (/\n\t+</.test(text)) return '\t';
  let min = Infinity;
  for (const m of text.matchAll(/\n( +)</g)) min = Math.min(min, m[1].length);
  return Number.isFinite(min) && min > 0 && min <= 8 ? ' '.repeat(min) : '    ';
}

/** Indentation for a new child of `el`: the first existing child's, else el's + one unit. */
export function childIndent(text: string, el: XmlElement): string {
  const first = el.children[0];
  if (first) return lineIndent(text, first.start);
  return lineIndent(text, el.start) + indentUnit(text);
}

export interface Splice {
  at: number;
  /** Characters to delete at `at` (default 0: pure insertion). */
  remove?: number;
  text: string;
}

export function applySplices(text: string, splices: Splice[]): string {
  const sorted = [...splices].sort((a, b) => b.at - a.at);
  let out = text;
  for (const s of sorted) out = out.slice(0, s.at) + s.text + out.slice(s.at + (s.remove ?? 0));
  return out;
}

/**
 * Inserts `block` (already indented lines, no trailing newline) as the last child of `el`.
 * A self-closing element is expanded to an open/close pair.
 */
export function appendChildSplice(text: string, el: XmlElement, block: string): Splice {
  const elIndent = lineIndent(text, el.start);
  if (el.selfClosing) {
    // `<application ... />` -> `<application ...>\n  block\n</application>`
    const slash = text.lastIndexOf('/', el.openEnd - 1);
    const before = text.slice(el.start, slash).replace(/\s+$/, '');
    return {
      at: el.start,
      remove: el.end - el.start,
      text: `${before}>\n${block}\n${elIndent}</${el.name}>`,
    };
  }
  // Insert before the closing tag, on its own line.
  const lineStart = text.lastIndexOf('\n', el.closeStart - 1) + 1;
  const onOwnLine = /^[ \t]*$/.test(text.slice(lineStart, el.closeStart));
  if (onOwnLine) return { at: lineStart, text: `${block}\n` };
  return { at: el.closeStart, text: `\n${block}\n${elIndent}` };
}

/** Adds an attribute to an element's opening tag, matching its multi-line style when it has one. */
export function addAttributeSplice(text: string, el: XmlElement, name: string, value: string): Splice {
  const openTag = text.slice(el.start, el.openEnd);
  const closer = el.selfClosing ? '/>' : '>';
  let insertAt = el.openEnd - closer.length;
  while (insertAt > el.start && /\s/.test(text[insertAt - 1])) insertAt--;
  const attrLines = openTag.split('\n');
  if (attrLines.length > 1) {
    const indent = lineIndent(text, el.start + openTag.indexOf('\n') + 1);
    return { at: insertAt, text: `\n${indent}${name}="${escapeAttr(value)}"` };
  }
  return { at: insertAt, text: ` ${name}="${escapeAttr(value)}"` };
}

export function escapeAttr(v: string): string {
  return v.replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;');
}

export function escapeText(v: string): string {
  return v.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

export function detectEol(text: string): string {
  return text.includes('\r\n') ? '\r\n' : '\n';
}
