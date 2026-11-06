import { DeviceEventEmitter } from 'react-native';

import { resetClikgateForTesting } from '../Clikgate';
import {
  Clikgate,
  type ClikgateBrowserHandoff,
  type ClikgateDeepLink,
} from '../index';
import { deepLinkFromMap } from '../models';
import { fixture } from './fixtures';

jest.mock('../NativeClikgate', () => ({
  __esModule: true,
  default: jest.requireActual('./testModule').createMockModule(),
}));

const flush = () => new Promise<void>((resolve) => setImmediate(resolve));

function emit(payload: Record<string, unknown>) {
  DeviceEventEmitter.emit('ClikgateDeepLink', payload);
}

/** The map the native modules send for a blocked `/resolve` answer (shared/PLATFORM_CHANNEL.md). */
const blockedEvent = () => ({
  url: 'https://inv.myapp.com/offer',
  path: null,
  data: {},
  isDeferred: false,
  clickId: null,
  matchType: null,
  link: null,
  referral: null,
  blockMessage: fixture('resolve_response_blocked').block_message,
});

beforeEach(() => {
  resetClikgateForTesting();
  jest.clearAllMocks();
});

/**
 * Change 17 (R.2): an app opened by a link skips the redirect, so `/resolve` runs the link gates.
 * The native SDKs open a password link's `web_url` in the system browser (nothing reaches JS) and
 * deliver a blocked link with `blockMessage` and no route.
 */
describe('link gates on app opens', () => {
  it('a blocked link arrives with its message and no route', async () => {
    await Clikgate.configure({ sdkKey: 'cg_sdk_test' });
    const received: ClikgateDeepLink[] = [];
    const handoffs: ClikgateBrowserHandoff[] = [];
    const a = Clikgate.onDeepLink((l) => received.push(l));
    const b = Clikgate.onBrowserHandoff((h) => handoffs.push(h));
    emit(blockedEvent());
    await flush();
    expect(received).toHaveLength(1);
    expect(received[0]).toEqual({
      url: 'https://inv.myapp.com/offer',
      path: null,
      data: {},
      isDeferred: false,
      clickId: null,
      matchType: null,
      link: null,
      referral: null,
      blockMessage: 'This offer is only for customers in Nigeria.',
    });
    expect(handoffs).toEqual([]);
    a();
    b();
  });

  it('links from older native modules (no blockMessage key) are not blocked', () => {
    expect(deepLinkFromMap({ path: '/products/42' }).blockMessage).toBeNull();
  });

  it('an A/B test delivers the variant path the server chose', async () => {
    const body = fixture('resolve_response_ab_variant');
    const dl = body.deep_link as Record<string, unknown>;
    await Clikgate.configure({ sdkKey: 'cg_sdk_test' });
    const received: ClikgateDeepLink[] = [];
    const off = Clikgate.onDeepLink((l) => received.push(l));
    emit({
      url: dl.url,
      path: dl.path,
      data: dl.data,
      isDeferred: false,
      clickId: body.click_id,
      matchType: 'app_link',
      link: null,
      referral: null,
      blockMessage: null,
    });
    await flush();
    expect(received[0]?.path).toBe('/menu/b');
    expect(received[0]?.blockMessage).toBeNull();
    off();
  });

  it('password_required: nothing reaches the app (the native SDK opens web_url)', async () => {
    const f = fixture('resolve_response_password_required');
    expect(f.status).toBe('password_required');
    expect(f.matched).toBe(false);
    expect(typeof f.web_url).toBe('string');
    await Clikgate.configure({ sdkKey: 'cg_sdk_test' });
    const received: ClikgateDeepLink[] = [];
    const handoffs: ClikgateBrowserHandoff[] = [];
    const a = Clikgate.onDeepLink((l) => received.push(l));
    const b = Clikgate.onBrowserHandoff((h) => handoffs.push(h));
    await flush();
    expect(received).toEqual([]);
    expect(handoffs).toEqual([]);
    a();
    b();
  });

  it.each(['resolve_response_password_required', 'resolve_response_blocked'])(
    '%s never carries a destination (deferred or direct)',
    (name) => {
      const f = fixture(name);
      for (const k of [
        'click_id',
        'deep_link',
        'link',
        'referral',
        'match_type',
      ]) {
        expect(f[k]).toBeNull();
      }
    }
  );
});
