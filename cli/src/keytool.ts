import { spawnSync } from 'node:child_process';
import * as os from 'node:os';
import * as path from 'node:path';
import { exists } from './fsutil';

export const FINGERPRINT = /^([0-9A-F]{2}:){31}[0-9A-F]{2}$/;

/** Normalises a pasted SHA-256 fingerprint (colons optional, any case). */
export function normaliseFingerprint(input: string): string | undefined {
  const hex = input.replace(/^SHA-?256:?\s*/i, '').replace(/[^0-9a-fA-F]/g, '').toUpperCase();
  if (hex.length !== 64) return undefined;
  return hex.match(/.{2}/g)!.join(':');
}

export function defaultDebugKeystore(): string {
  return path.join(os.homedir(), '.android', 'debug.keystore');
}

function keytoolBinary(): string {
  const home = process.env.JAVA_HOME;
  if (home) {
    const p = path.join(home, 'bin', os.platform() === 'win32' ? 'keytool.exe' : 'keytool');
    if (exists(p)) return p;
  }
  return 'keytool';
}

/**
 * SHA-256 of the debug signing certificate via `keytool` (the standard Android debug keystore:
 * alias androiddebugkey, password android). Returns undefined when keytool or the keystore is missing.
 */
export function debugFingerprint(keystore = defaultDebugKeystore()): string | undefined {
  if (!exists(keystore)) return undefined;
  const r = spawnSync(
    keytoolBinary(),
    ['-list', '-v', '-keystore', keystore, '-alias', 'androiddebugkey', '-storepass', 'android', '-keypass', 'android'],
    { encoding: 'utf8', timeout: 20_000, env: { ...process.env, JAVA_TOOL_OPTIONS: '' } }
  );
  if (r.error || r.status !== 0) return undefined;
  const m = /SHA-?256:\s*([0-9A-Fa-f:]{95})/.exec(r.stdout);
  return m ? normaliseFingerprint(m[1]) : undefined;
}
