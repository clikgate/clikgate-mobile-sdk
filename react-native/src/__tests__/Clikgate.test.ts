import { DeviceEventEmitter } from 'react-native';

import { resetClikgateForTesting } from '../Clikgate';
import {
  Clikgate,
  ClikgateError,
  VERSION,
  type ClikgateDeepLink,
} from '../index';
import * as api from '../index';
import { nativeRejection, type MockModule } from './testModule';

jest.mock('../NativeClikgate', () => ({
  __esModule: true,
  default: jest.requireActual('./testModule').createMockModule(),
}));

const mockModule: MockModule = jest.requireMock('../NativeClikgate').default;

const flush = () => new Promise<void>((resolve) => setImmediate(resolve));

function emitDeepLink(payload: Record<string, unknown>) {
  DeviceEventEmitter.emit('ClikgateDeepLink', payload);
}

beforeEach(() => {
  resetClikgateForTesting();
  jest.clearAllMocks();
});

describe('configure', () => {
  it('sends the contract argument map with defaults and the wrapper version', async () => {
    await Clikgate.configure({
      sdkKey: 'cg_sdk_test',
      linkDomains: ['inv.myapp.com'],
    });
    expect(mockModule.configure).toHaveBeenCalledTimes(1);
    expect(mockModule.configure).toHaveBeenCalledWith({
      sdkKey: 'cg_sdk_test',
      linkDomains: ['inv.myapp.com'],
      apiBaseUrl: null,
      logLevel: 'warn',
      environment: 'production',
      attestation: 'off',
      pasteboardMode: 'off',
      waitForATT: false,
      deferredDeepLinkTimeoutMs: 5000,
      platformDomainBrowserFallback: true,
      wrapperVersion: VERSION,
    });
  });

  it('forwards every alias link domain unchanged (native merges server link_domains)', async () => {
    await Clikgate.configure({
      sdkKey: 'cg_sdk_test',
      linkDomains: ['ybr.ng', 'Go.YourBrand.com'],
    });
    expect(mockModule.configure.mock.calls[0]?.[0]).toMatchObject({
      linkDomains: ['ybr.ng', 'Go.YourBrand.com'],
    });
  });

  it('passes every option through', async () => {
    await Clikgate.configure({
      sdkKey: 'cg_sdk_test',
      linkDomains: ['a.example.com', 'b.example.com'],
      apiBaseUrl: 'http://10.0.2.2:8000',
      logLevel: 'debug',
      environment: 'sandbox',
      attestation: 'ifAvailable',
      pasteboardMode: 'pasteControlOnly',
      waitForATT: true,
      deferredDeepLinkTimeoutMs: 2500,
      platformDomainBrowserFallback: false,
    });
    expect(mockModule.configure.mock.calls[0]?.[0]).toMatchObject({
      apiBaseUrl: 'http://10.0.2.2:8000',
      logLevel: 'debug',
      environment: 'sandbox',
      attestation: 'ifAvailable',
      pasteboardMode: 'pasteControlOnly',
      waitForATT: true,
      deferredDeepLinkTimeoutMs: 2500,
      platformDomainBrowserFallback: false,
    });
  });

  it('subscribes to native deep links before calling configure', async () => {
    const order: string[] = [];
    mockModule.addListener.mockImplementationOnce(() => {
      order.push('addListener');
    });
    mockModule.configure.mockImplementationOnce(() => {
      order.push('configure');
      return Promise.resolve(null);
    });
    await Clikgate.configure({ sdkKey: 'cg_sdk_test' });
    expect(order).toEqual(['addListener', 'configure']);
    expect(mockModule.addListener).toHaveBeenCalledWith('ClikgateDeepLink');
  });

  it('rejects a missing sdkKey without calling native', async () => {
    await expect(Clikgate.configure({} as never)).rejects.toMatchObject({
      code: 'invalid_argument',
      param: 'sdkKey',
    });
    expect(mockModule.configure).not.toHaveBeenCalled();
  });
});

describe('method and argument mapping', () => {
  it('there is no track method or ClikgateMoney (goal() is the only method)', () => {
    expect((Clikgate as Record<string, unknown>).track).toBeUndefined();
    expect('ClikgateMoney' in api).toBe(false);
  });

  it('getInstallationId unwraps the native map', async () => {
    mockModule.getInstallationId.mockResolvedValueOnce({
      installationId: '6a1f0c2e-4b7d-4c1a-9e2f-0d3b5a7c9e11',
    });
    await expect(Clikgate.getInstallationId()).resolves.toBe(
      '6a1f0c2e-4b7d-4c1a-9e2f-0d3b5a7c9e11'
    );
    expect(mockModule.getInstallationId).toHaveBeenCalledWith({});
    // Tracking off natively: null.
    await expect(Clikgate.getInstallationId()).resolves.toBeNull();
  });

  it('identifyUser: customer ID, logout, label only', async () => {
    await Clikgate.identifyUser({
      customerId: 'user_42',
      identityToken: 'tok',
    });
    await Clikgate.identifyUser({ customerId: null });
    await Clikgate.identifyUser({ label: 'Ada (VIP)' });
    expect(mockModule.identifyUser.mock.calls).toEqual([
      [{ label: null, customerId: 'user_42', identityToken: 'tok' }],
      [{ label: null, customerId: null, identityToken: null }],
      [{ label: 'Ada (VIP)', identityToken: null }],
    ]);
  });

  it('setTrackingEnabled', async () => {
    await Clikgate.setTrackingEnabled(false);
    expect(mockModule.setTrackingEnabled).toHaveBeenCalledWith({
      enabled: false,
    });
  });

  it('setPushToken forwards token and provider, ignores empty tokens', async () => {
    await Clikgate.setPushToken('fcm-token', { provider: 'fcm' });
    await Clikgate.setPushToken('a1b2', { provider: 'apns' });
    await Clikgate.setPushToken(null, { provider: 'fcm' });
    await Clikgate.setPushToken('', { provider: 'fcm' });
    expect(mockModule.setPushToken.mock.calls).toEqual([
      [{ token: 'fcm-token', provider: 'fcm' }],
      [{ token: 'a1b2', provider: 'apns' }],
    ]);
  });

  it('handleUrl', async () => {
    mockModule.handleUrl.mockResolvedValueOnce(false);
    await expect(Clikgate.handleUrl('https://inv.myapp.com/x')).resolves.toBe(
      false
    );
    expect(mockModule.handleUrl).toHaveBeenCalledWith({
      url: 'https://inv.myapp.com/x',
    });
    await expect(Clikgate.handleUrl('https://inv.myapp.com/y')).resolves.toBe(
      true
    );
  });

  it('nativeSdkVersion', async () => {
    await expect(Clikgate.nativeSdkVersion()).resolves.toBe('1.0.0');
    expect(mockModule.sdkVersion).toHaveBeenCalledWith();
  });

  it('getAttribution decodes the result map', async () => {
    mockModule.getAttribution.mockResolvedValueOnce({
      status: 'attributed',
      matchType: 'install_referrer',
      confidence: 1,
      clickId: 'clk_1',
      clickedAt: '2026-10-20T10:00:00.000Z',
      isReinstall: false,
      installId: 'ins_1',
      link: {
        id: 'lnk_1',
        kind: 'referral',
        externalReference: null,
        campaignId: 'cmp_1',
        metadata: { snake_case_key: 1 },
      },
    });
    const a = await Clikgate.getAttribution();
    expect(mockModule.getAttribution).toHaveBeenCalledWith({});
    expect(a.status).toBe('attributed');
    expect(a.isAttributed).toBe(true);
    expect(a.matchType).toBe('install_referrer');
    expect(a.clickedAt?.toISOString()).toBe('2026-10-20T10:00:00.000Z');
    expect(a.installId).toBe('ins_1');
    expect(a.link).toEqual({
      id: 'lnk_1',
      kind: 'referral',
      externalReference: null,
      campaignId: 'cmp_1',
      metadata: { snake_case_key: 1 },
      isReferral: true,
    });
  });

  it('getAttribution tolerates missing fields', async () => {
    mockModule.getAttribution.mockResolvedValueOnce({
      status: 'something-new',
    });
    const a = await Clikgate.getAttribution();
    expect(a).toEqual({
      status: 'pending',
      matchType: null,
      confidence: null,
      clickId: null,
      clickedAt: null,
      isReinstall: false,
      installId: null,
      link: null,
      isAttributed: false,
    });
  });
});

describe('referrals', () => {
  const referralMap = {
    referralId: 'ref_1',
    programId: 'rpg_1',
    status: 'installed',
    source: 'code_entry',
    referrerId: 'rfr_1',
    referrerDisplayName: 'Ada',
    createdAt: '2026-10-20T10:00:00Z',
  };

  it('applyCode', async () => {
    mockModule.referralsApplyCode.mockResolvedValueOnce(referralMap);
    const r = await Clikgate.referrals.applyCode({
      programId: 'rpg_1',
      code: 'ADA42',
    });
    expect(mockModule.referralsApplyCode).toHaveBeenCalledWith({
      programId: 'rpg_1',
      code: 'ADA42',
    });
    expect(r.referralId).toBe('ref_1');
    expect(r.source).toBe('code_entry');
    expect(r.referrerDisplayName).toBe('Ada');
    expect(r.createdAt?.toISOString()).toBe('2026-10-20T10:00:00.000Z');
  });

  it('referredBy', async () => {
    mockModule.referralsReferredBy.mockResolvedValueOnce({
      referred: true,
      referral: referralMap,
    });
    const info = await Clikgate.referrals.referredBy();
    expect(mockModule.referralsReferredBy).toHaveBeenCalledWith({});
    expect(info.referred).toBe(true);
    expect(info.referral?.referrerId).toBe('rfr_1');
  });
});

describe('error mapping', () => {
  it('maps a rejection with userInfo {status, param} to ClikgateError', async () => {
    mockModule.referralsApplyCode.mockRejectedValueOnce(
      nativeRejection('code_not_found', 'No such code', {
        status: 404,
        param: 'code',
      })
    );
    const error = await Clikgate.referrals
      .applyCode({ programId: 'rpg_1', code: 'NOPE' })
      .catch((e: unknown) => e);
    expect(error).toBeInstanceOf(ClikgateError);
    expect(error).toMatchObject({
      code: 'code_not_found',
      message: 'No such code',
      status: 404,
      param: 'code',
    });
    expect(String(error)).toBe(
      'ClikgateError(code_not_found, 404, param: code): No such code'
    );
  });

  it('maps SDK errors without status (null userInfo values)', async () => {
    mockModule.getInstallationId.mockRejectedValueOnce(
      nativeRejection('invalid_argument', 'Bad name', {
        status: null,
        param: null,
      })
    );
    await expect(Clikgate.getInstallationId()).rejects.toMatchObject({
      code: 'invalid_argument',
      status: null,
      param: null,
    });
  });

  it('accepts `details` instead of `userInfo`', async () => {
    const e = Object.assign(new Error('Too late'), {
      code: 'window_expired',
      details: { status: 409, param: null },
    });
    mockModule.referralsApplyCode.mockRejectedValueOnce(e);
    await expect(
      Clikgate.referrals.applyCode({ programId: 'p', code: 'c' })
    ).rejects.toMatchObject({ code: 'window_expired', status: 409 });
  });

  it('maps unknown errors to code "unknown"', async () => {
    mockModule.getAttribution.mockRejectedValueOnce(new Error('boom'));
    await expect(Clikgate.getAttribution()).rejects.toMatchObject({
      code: 'unknown',
      message: 'boom',
      status: null,
    });
  });

  it('referral SDK codes such as install_pending pass through', async () => {
    mockModule.referralsReferredBy.mockRejectedValueOnce(
      nativeRejection('install_pending', 'Install not finished', null)
    );
    await expect(Clikgate.referrals.referredBy()).rejects.toMatchObject({
      code: 'install_pending',
    });
  });
});

describe('deep links', () => {
  const link = (path: string) => ({
    url: `https://inv.myapp.com${path}`,
    path,
    data: { product_id: 'p1', camelCase: true, snake_case: 1 },
    isDeferred: false,
    clickId: 'clk_1',
    matchType: 'app_link',
    link: null,
    referral: null,
  });

  it('delivers native events to listeners and decodes them', async () => {
    await Clikgate.configure({ sdkKey: 'cg_sdk_test' });
    const received: ClikgateDeepLink[] = [];
    const unsubscribe = Clikgate.onDeepLink((l) => received.push(l));
    emitDeepLink(link('/products/1'));
    expect(received).toHaveLength(1);
    expect(received[0]).toMatchObject({
      path: '/products/1',
      data: { product_id: 'p1', camelCase: true, snake_case: 1 },
      isDeferred: false,
      matchType: 'app_link',
      link: null,
      referral: null,
    });
    unsubscribe();
    emitDeepLink(link('/products/2'));
    expect(received).toHaveLength(1);
  });

  it('buffers links received before the first listener and replays them to it', async () => {
    await Clikgate.configure({ sdkKey: 'cg_sdk_test' });
    emitDeepLink({
      ...link('/welcome'),
      isDeferred: true,
      matchType: 'install_referrer',
    });
    emitDeepLink(link('/products/1'));

    const first: string[] = [];
    Clikgate.onDeepLink((l) => first.push(l.path ?? ''));
    expect(first).toEqual([]); // replayed asynchronously, after onDeepLink returns
    await flush();
    expect(first).toEqual(['/welcome', '/products/1']);

    // A second listener doesn't get the replay again, but gets new links.
    const second: string[] = [];
    Clikgate.onDeepLink((l) => second.push(l.path ?? ''));
    await flush();
    expect(second).toEqual([]);
    emitDeepLink(link('/products/3'));
    expect(first).toEqual(['/welcome', '/products/1', '/products/3']);
    expect(second).toEqual(['/products/3']);
  });

  it('keeps the latest 10 buffered links', async () => {
    await Clikgate.configure({ sdkKey: 'cg_sdk_test' });
    for (let i = 0; i < 15; i++) emitDeepLink(link(`/p/${i}`));
    const paths: string[] = [];
    Clikgate.onDeepLink((l) => paths.push(l.path ?? ''));
    await flush();
    expect(paths).toEqual(Array.from({ length: 10 }, (_, i) => `/p/${i + 5}`));
  });

  it('keeps buffered links when the first listener unsubscribes before the replay', async () => {
    await Clikgate.configure({ sdkKey: 'cg_sdk_test' });
    emitDeepLink(link('/welcome'));
    const early: string[] = [];
    const unsubscribe = Clikgate.onDeepLink((l) => early.push(l.path ?? ''));
    unsubscribe();
    await flush();
    expect(early).toEqual([]);
    const late: string[] = [];
    Clikgate.onDeepLink((l) => late.push(l.path ?? ''));
    await flush();
    expect(late).toEqual(['/welcome']);
  });

  it('buffers again after every listener unsubscribed', async () => {
    await Clikgate.configure({ sdkKey: 'cg_sdk_test' });
    const a: string[] = [];
    const unsubscribe = Clikgate.onDeepLink((l) => a.push(l.path ?? ''));
    unsubscribe();
    unsubscribe(); // idempotent
    emitDeepLink(link('/later'));
    const b: string[] = [];
    Clikgate.onDeepLink((l) => b.push(l.path ?? ''));
    await flush();
    expect(a).toEqual([]);
    expect(b).toEqual(['/later']);
  });

  it('onDeepLink before configure starts listening too', () => {
    const paths: string[] = [];
    Clikgate.onDeepLink((l) => paths.push(l.path ?? ''));
    expect(mockModule.addListener).toHaveBeenCalledWith('ClikgateDeepLink');
    emitDeepLink(link('/x'));
    expect(paths).toEqual(['/x']);
  });

  it('subscribes to the native emitter only once', async () => {
    await Clikgate.configure({ sdkKey: 'cg_sdk_test' });
    await Clikgate.configure({ sdkKey: 'cg_sdk_test' });
    Clikgate.onDeepLink(() => {});
    Clikgate.onDeepLink(() => {});
    expect(mockModule.addListener).toHaveBeenCalledTimes(1);
  });

  it('a throwing listener does not prevent delivery to the others', async () => {
    const spy = jest.spyOn(console, 'error').mockImplementation(() => {});
    await Clikgate.configure({ sdkKey: 'cg_sdk_test' });
    const paths: string[] = [];
    Clikgate.onDeepLink(() => {
      throw new Error('listener bug');
    });
    Clikgate.onDeepLink((l) => paths.push(l.path ?? ''));
    emitDeepLink(link('/ok'));
    expect(paths).toEqual(['/ok']);
    expect(spy).toHaveBeenCalled();
    spy.mockRestore();
  });

  it('decodes referral and link of a deferred referral deep link', async () => {
    await Clikgate.configure({ sdkKey: 'cg_sdk_test' });
    const received: ClikgateDeepLink[] = [];
    Clikgate.onDeepLink((l) => received.push(l));
    emitDeepLink({
      url: null,
      path: '/welcome',
      data: {},
      isDeferred: true,
      clickId: 'clk_9',
      matchType: 'install_referrer',
      link: {
        id: 'lnk_9',
        kind: 'referral',
        externalReference: 'ext',
        campaignId: null,
        metadata: {},
      },
      referral: {
        referralId: 'ref_9',
        programId: 'rpg_1',
        status: 'installed',
        source: 'link',
        referrerId: 'rfr_1',
        referrerDisplayName: null,
        createdAt: null,
      },
    });
    expect(received[0]?.isDeferred).toBe(true);
    expect(received[0]?.link?.isReferral).toBe(true);
    expect(received[0]?.link?.externalReference).toBe('ext');
    expect(received[0]?.referral).toEqual({
      referralId: 'ref_9',
      programId: 'rpg_1',
      status: 'installed',
      source: 'link',
      referrerId: 'rfr_1',
      referrerDisplayName: null,
      createdAt: null,
    });
  });
});

describe('isClikgateMessage on Clikgate', () => {
  it('is the pure helper', () => {
    expect(Clikgate.isClikgateMessage({ cg: 'uc' })).toBe(true);
    expect(mockModule.configure).not.toHaveBeenCalled();
  });
});
