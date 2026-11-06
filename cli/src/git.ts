import { spawnSync } from 'node:child_process';
import * as fs from 'node:fs';
import * as path from 'node:path';

export interface TreeState {
  isRepo: boolean;
  /** Uncommitted changes (`git status --porcelain` lines). */
  dirty: string[];
}

export function treeState(root: string): TreeState {
  const r = spawnSync('git', ['status', '--porcelain'], { cwd: root, encoding: 'utf8' });
  if (r.error || r.status !== 0) return { isRepo: false, dirty: [] };
  return { isRepo: true, dirty: r.stdout.split('\n').filter((l) => l.trim() !== '') };
}

export function timestamp(d = new Date()): string {
  return d.toISOString().replace(/[:]/g, '').replace(/\.\d+Z$/, 'Z');
}

/** Copies the files about to change into `.clikgate-setup-backup/<timestamp>/` (same relative paths). */
export function backupFiles(root: string, files: string[], stamp = timestamp()): string {
  const dir = path.join(root, '.clikgate-setup-backup', stamp);
  for (const f of files) {
    const src = path.join(root, f);
    if (!fs.existsSync(src)) continue;
    const dst = path.join(dir, f);
    fs.mkdirSync(path.dirname(dst), { recursive: true });
    fs.copyFileSync(src, dst);
  }
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(
    path.join(dir, 'README.txt'),
    [
      'Backup made by the Clikgate setup command before changing these files.',
      'To undo, copy them back over the project files and delete the files listed as new:',
      '',
      ...files.map((f) => `  ${f}${fs.existsSync(src(root, f)) ? '' : '  (new file: delete it)'}`),
      '',
    ].join('\n')
  );
  return dir;
}

function src(root: string, f: string): string {
  return path.join(root, f);
}
