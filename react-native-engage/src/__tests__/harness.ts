import { readFileSync } from 'fs';
import { join } from 'path';

import type { ClikgateRequestContext } from '@clikgate/react-native';

import { ClikgateEngage } from '../ClikgateEngage';

const FIXTURES = join(__dirname, '..', '..', '..', 'shared', 'fixtures');

/** `shared/fixtures/<name>.json` as text. */
export function fixtureText(name: string): string {
  return readFileSync(join(FIXTURES, `${name}.json`), 'utf8');
}

export function fixture(name: string): Record<string, unknown> {
  return JSON.parse(fixtureText(name));
}

export const BASE = 'https://sdk.test';

export function context(
  overrides: Partial<ClikgateRequestContext> = {}
): ClikgateRequestContext {
  return {
    installationId: '6a1f0c2e-0000-4000-8000-000000000001',
    sdkKey: 'cg_sdk_test_abc',
    environment: 'production',
    apiBaseUrl: BASE,
    identityToken: 'sig.1760954400',
    customerUserId: 'user_42',
    sdkVersion: 'react-native/1.0.0',
    nativeSdkVersion: 'android/1.0.0',
    ...overrides,
  };
}

type Reply = { status: number; body: string } | Error;

export interface Call {
  url: string;
  method: string;
  headers: Record<string, string>;
  body?: string;
}

/** A test rig: fake core, scripted fetch, manual clock, share/linking spies. */
export function rig(
  options: {
    features?: Record<string, boolean>;
    ctx?: Partial<ClikgateRequestContext>;
    contextError?: Error;
  } = {}
) {
  const routes = new Map<string, Reply[]>();
  const calls: Call[] = [];
  let clock = 1_000_000;
  const core = {
    isFeatureEnabled: jest.fn(
      async (key: string) => options.features?.[key] ?? true
    ),
    getRequestContext: jest.fn(async () => {
      if (options.contextError) throw options.contextError;
      return context(options.ctx);
    }),
    reportServerError: jest.fn(
      async (_code: string, _feature?: string | null) => {}
    ),
  };
  const fetch = jest.fn(
    async (
      url: string,
      init: {
        method: string;
        headers: Record<string, string>;
        body?: string;
        signal?: AbortSignal;
      }
    ) => {
      calls.push({
        url,
        method: init.method,
        headers: init.headers,
        body: init.body,
      });
      const key = `${init.method} ${url.replace(BASE, '').split('?')[0]}`;
      const list = routes.get(key);
      const reply = list && list.length > 1 ? list.shift()! : list?.[0];
      if (reply == null) return { status: 404, text: async () => '' };
      if (reply instanceof Error) throw reply;
      return { status: reply.status, text: async () => reply.body };
    }
  );
  const shareSheet = {
    share: jest.fn(async (_c: { message: string }) => ({})),
  };
  const linking = { openURL: jest.fn(async (_url: string) => true) };
  const engage = new ClikgateEngage({
    core,
    fetch,
    now: () => clock,
    shareSheet,
    linking,
    retryDelayMs: 0,
  });
  return {
    engage,
    core,
    fetch,
    calls,
    shareSheet,
    linking,
    on(route: string, ...replies: Reply[]) {
      routes.set(route, replies);
    },
    ok(body: string) {
      return { status: 200, body };
    },
    advance(ms: number) {
      clock += ms;
    },
  };
}
