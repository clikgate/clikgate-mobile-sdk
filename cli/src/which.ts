import * as path from 'node:path';
import { exists } from './fsutil';

/** Finds an executable on PATH (no shell). Tests set CLIKGATE_SETUP_NO_TOOLS=1 to hide tools. */
export function which(cmd: string): string | undefined {
  if (process.env.CLIKGATE_SETUP_NO_TOOLS === '1') return undefined;
  const exts = process.platform === 'win32' ? (process.env.PATHEXT ?? '.EXE;.CMD;.BAT').split(';') : [''];
  for (const dir of (process.env.PATH ?? '').split(path.delimiter)) {
    if (!dir) continue;
    for (const ext of exts) {
      const p = path.join(dir, cmd + ext);
      if (exists(p)) return p;
    }
  }
  return undefined;
}
