import * as fs from 'node:fs';
import * as path from 'node:path';

export function exists(p: string): boolean {
  try {
    fs.accessSync(p);
    return true;
  } catch {
    return false;
  }
}

export function isDir(p: string): boolean {
  try {
    return fs.statSync(p).isDirectory();
  } catch {
    return false;
  }
}

export function read(p: string): string {
  return fs.readFileSync(p, 'utf8');
}

export function readIfExists(p: string): string | undefined {
  try {
    return fs.readFileSync(p, 'utf8');
  } catch {
    return undefined;
  }
}

export function list(dir: string): string[] {
  try {
    return fs.readdirSync(dir);
  } catch {
    return [];
  }
}

export const SKIP_DIRS = new Set(['node_modules', '.git', 'build', 'Pods', '.dart_tool', '.gradle', 'DerivedData', '.expo', 'dist', '.clikgate-setup-backup', '.idea', '.next']);

/** Breadth-first walk (depth-limited), skipping dependency and build folders. */
export function walk(root: string, maxDepth: number, visit: (dir: string, depth: number) => void): void {
  const queue: [string, number][] = [[root, 0]];
  while (queue.length) {
    const [dir, depth] = queue.shift()!;
    visit(dir, depth);
    if (depth >= maxDepth) continue;
    for (const name of list(dir).sort()) {
      if (SKIP_DIRS.has(name) || name.startsWith('.')) continue;
      const p = path.join(dir, name);
      if (isDir(p) && !name.endsWith('.xcodeproj') && !name.endsWith('.xcworkspace')) queue.push([p, depth + 1]);
    }
  }
}

/** Finds files by name pattern under root (depth-limited). */
export function findFiles(root: string, pattern: RegExp, maxDepth = 6): string[] {
  const out: string[] = [];
  walk(root, maxDepth, (dir) => {
    for (const name of list(dir)) {
      const p = path.join(dir, name);
      if (pattern.test(name) && !isDir(p)) out.push(p);
    }
  });
  return out.sort();
}

export function rel(root: string, p: string): string {
  return path.relative(root, p).split(path.sep).join('/');
}

/** Walks up from `start` until `stop(dir)` or the filesystem root. */
export function findUp(start: string, names: string[], stopAt?: string): string | undefined {
  let dir = path.resolve(start);
  for (;;) {
    for (const n of names) {
      const p = path.join(dir, n);
      if (exists(p)) return p;
    }
    const parent = path.dirname(dir);
    if (parent === dir || (stopAt && dir === path.resolve(stopAt))) return undefined;
    dir = parent;
  }
}
