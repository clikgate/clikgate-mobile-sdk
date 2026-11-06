import { readFileSync } from 'fs';
import { join } from 'path';

/** Directory of the shared SDK <-> API fixtures (snake_case API bodies). */
const FIXTURES = join(__dirname, '..', '..', '..', 'shared', 'fixtures');

/** Reads `shared/fixtures/<name>.json`. */
export function fixture(name: string): Record<string, unknown> {
  return JSON.parse(readFileSync(join(FIXTURES, `${name}.json`), 'utf8'));
}

function camel(key: string): string {
  return key.replace(/_([a-z0-9])/g, (_m, c: string) => c.toUpperCase());
}

/**
 * The bridge map the native SDKs build from an API body: the same structure with camelCase
 * keys (shared/PLATFORM_CHANNEL.md), recursively.
 */
export function toBridgeMap(v: unknown): unknown {
  if (Array.isArray(v)) return v.map(toBridgeMap);
  if (typeof v === 'object' && v !== null) {
    return Object.fromEntries(
      Object.entries(v).map(([k, x]) => [camel(k), toBridgeMap(x)])
    );
  }
  return v;
}
