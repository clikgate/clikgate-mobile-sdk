import { DeviceEventEmitter } from 'react-native';

import { resetClikgateForTesting } from '../Clikgate';
import {
  Clikgate,
  type ClikgateBrowserHandoff,
  type ClikgateDeepLink,
} from '../index';
import { type MockModule } from './testModule';

jest.mock('../NativeClikgate', () => ({
  __esModule: true,
  default: jest.requireActual('./testModule').createMockModule(),
}));

const mockModule: MockModule = jest.requireMock('../NativeClikgate').default;

const flush = () => new Promise<void>((resolve) => setImmediate(resolve));

/** The native SDKs tag a handoff on the deep-link event (shared/PLATFORM_CHANNEL.md). */
function emit(payload: Record<string, unknown>) {
  DeviceEventEmitter.emit('ClikgateDeepLink', payload);
}

const handoff = (url: string, host: string) => ({
  event: 'browserHandoff',
  url,
  host,
});

const directLink = {
  url: 'https://clk.ng/mine',
  path: '/products/42',
  data: { product_id: '42' },
  isDeferred: false,
  clickId: 'clk_01JAB3C4D5E6F7G8H9JKMNPQRS',
  matchType: 'app_link',
  link: null,
  referral: null,
};

beforeEach(() => {
  resetClikgateForTesting();
  jest.clearAllMocks();
});

/** Change 06 (1.5.0): shared-domain links of other organisations go to an in-app browser. */
describe('onBrowserHandoff', () => {
  it('configure sends platformDomainBrowserFallback, default true', async () => {
    await Clikgate.configure({ sdkKey: 'cg_sdk_test' });
    expect(mockModule.configure.mock.calls[0]?.[0]).toMatchObject({
      platformDomainBrowserFallback: true,
    });
    resetClikgateForTesting();
    await Clikgate.configure({
      sdkKey: 'cg_sdk_test',
      platformDomainBrowserFallback: false,
    });
    expect(mockModule.configure.mock.calls[1]?.[0]).toMatchObject({
      platformDomainBrowserFallback: false,
    });
  });

  it('delivers a handoff to onBrowserHandoff and never to onDeepLink', async () => {
    const links: ClikgateDeepLink[] = [];
    const handoffs: ClikgateBrowserHandoff[] = [];
    Clikgate.onDeepLink((l) => links.push(l));
    Clikgate.onBrowserHandoff((h) => handoffs.push(h));
    emit(handoff('https://ciz.to/other-org', 'ciz.to'));
    await flush();
    expect(handoffs).toEqual([
      { url: 'https://ciz.to/other-org', host: 'ciz.to' },
    ]);
    expect(links).toEqual([]);
  });

  it('matched links keep arriving on onDeepLink only', async () => {
    const links: ClikgateDeepLink[] = [];
    const handoffs: ClikgateBrowserHandoff[] = [];
    Clikgate.onDeepLink((l) => links.push(l));
    Clikgate.onBrowserHandoff((h) => handoffs.push(h));
    emit(directLink);
    await flush();
    expect(links.map((l) => l.path)).toEqual(['/products/42']);
    expect(handoffs).toEqual([]);
  });

  it('buffers handoffs until the first listener and replays them', async () => {
    await Clikgate.configure({ sdkKey: 'cg_sdk_test' });
    emit(handoff('https://clk.ng/x', 'clk.ng'));
    emit(directLink);
    const handoffs: ClikgateBrowserHandoff[] = [];
    const links: ClikgateDeepLink[] = [];
    const off = Clikgate.onBrowserHandoff((h) => handoffs.push(h));
    Clikgate.onDeepLink((l) => links.push(l));
    await flush();
    expect(handoffs.map((h) => h.host)).toEqual(['clk.ng']);
    expect(links).toHaveLength(1);
    off();
    emit(handoff('https://ciz.to/y', 'ciz.to'));
    await flush();
    expect(handoffs).toHaveLength(1);
  });
});
