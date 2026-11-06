jest.mock('../NativeClikgate', () => ({ __esModule: true, default: null }));

import { Clikgate } from '../index';

describe('without the native module (web, Expo Go, not rebuilt)', () => {
  it('rejects calls with unsupported_platform', async () => {
    await expect(
      Clikgate.configure({ sdkKey: 'cg_sdk_x' })
    ).rejects.toMatchObject({
      code: 'unsupported_platform',
    });
    await expect(Clikgate.getAttribution()).rejects.toMatchObject({
      code: 'unsupported_platform',
    });
    await expect(Clikgate.referrals.referredBy()).rejects.toMatchObject({
      code: 'unsupported_platform',
    });
    await expect(
      Clikgate.isFeatureEnabled('leaderboards')
    ).rejects.toMatchObject({ code: 'unsupported_platform' });
    await expect(Clikgate.getRequestContext()).rejects.toMatchObject({
      code: 'unsupported_platform',
    });
    // Best effort: never rejects.
    await expect(
      Clikgate.reportServerError('feature_disabled', 'leaderboards')
    ).resolves.toBeUndefined();
  });

  it('onDeepLink still works (never fires) and isClikgateMessage still works', () => {
    const unsubscribe = Clikgate.onDeepLink(() => {});
    expect(typeof unsubscribe).toBe('function');
    unsubscribe();
    expect(Clikgate.isClikgateMessage({ cg: 'uc' })).toBe(true);
  });
});
