import { DeviceEventEmitter } from 'react-native';

import { resetClikgateForTesting } from '../Clikgate';
import { Clikgate, type ClikgateDeepLink } from '../index';
import { fixture } from './fixtures';
import { type MockModule } from './testModule';

jest.mock('../NativeClikgate', () => ({
  __esModule: true,
  default: jest.requireActual('./testModule').createMockModule(),
}));

const mockModule: MockModule = jest.requireMock('../NativeClikgate').default;
const flush = () => new Promise<void>((resolve) => setImmediate(resolve));

beforeEach(() => {
  resetClikgateForTesting();
  jest.clearAllMocks();
});

/**
 * Change 20 (S.1, R.40): the native SDKs send `deeplink_handled` (the handled path, IDs replaced with
 * `:id`) in test mode or while the debug view is open. The JavaScript layer only passes the key and the
 * links through: it never cleans the app's link, never adds a call of its own, and nothing is sent as
 * an event.
 */
describe('deeplink_handled (sent by the native SDKs)', () => {
  it('passes the test key to the native SDK unchanged (test mode is read from its prefix)', async () => {
    await Clikgate.configure({ sdkKey: 'cg_sdk_test_4f1c9a' });
    expect(mockModule.configure).toHaveBeenCalledWith(
      expect.objectContaining({ sdkKey: 'cg_sdk_test_4f1c9a' })
    );
  });

  it('the app still gets the full path and query; only the report is cleaned', async () => {
    await Clikgate.configure({ sdkKey: 'cg_sdk_test_4f1c9a' });
    const received: ClikgateDeepLink[] = [];
    const sub = Clikgate.onDeepLink((l) => received.push(l));
    const path = '/u/ada%40example.com/orders/42?coupon=SAVE10';
    DeviceEventEmitter.emit('ClikgateDeepLink', {
      url: 'https://inv.myapp.com/p/dress',
      path,
      data: { coupon: 'SAVE10' },
      isDeferred: false,
      clickId: 'clk_01JAB3C4D5E6F7G8H9JKMNPQRS',
      matchType: 'app_link',
      link: null,
      referral: null,
    });
    await flush();
    expect(received.map((l) => l.path)).toEqual([path]);
    sub();
  });

  it('adds no native call and tracks nothing for a handled link', async () => {
    await Clikgate.configure({ sdkKey: 'cg_sdk_test_4f1c9a' });
    const sub = Clikgate.onDeepLink(() => {});
    await expect(
      Clikgate.handleUrl('https://inv.myapp.com/products/42?ref=x')
    ).resolves.toBe(true);
    await flush();
    const called = Object.entries(mockModule)
      .filter(([, fn]) => jest.isMockFunction(fn) && fn.mock.calls.length > 0)
      .map(([name]) => name)
      .sort();
    expect(called).toEqual(['addListener', 'configure', 'handleUrl']); // addListener: the deep-link event subscription
    expect(mockModule.goal).not.toHaveBeenCalled();
    sub();
  });

  it('the shared contract: the body is the cleaned path and is_deferred only', () => {
    for (const name of [
      'deeplink_handled_request',
      'deeplink_handled_request_deferred',
    ]) {
      const body = fixture(name);
      expect(Object.keys(body).sort()).toEqual(['is_deferred', 'path']);
      expect(body.path).toBe('/products/:id');
    }
    const cases = fixture('deeplink_path_cases').cases as Array<{
      path: string;
      expected: string;
    }>;
    expect(cases.length).toBeGreaterThan(20);
    for (const c of cases) {
      expect(c.expected).not.toMatch(/[?#@]/);
      expect(c.expected).not.toMatch(/\d{6,}/);
    }
  });

  it('the debug view flag is optional on /resolve and /install answers', () => {
    expect(fixture('resolve_response_matched').debug_view).toBeUndefined();
    expect(fixture('resolve_response_debug_view').debug_view).toBe(true);
    expect(fixture('install_response_debug_view').debug_view).toBe(true);
  });
});
