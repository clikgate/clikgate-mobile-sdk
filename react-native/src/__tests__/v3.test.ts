import { resetClikgateForTesting } from '../Clikgate';
import { Clikgate, ClikgateError } from '../index';
import { fixture, toBridgeMap } from './fixtures';
import { nativeRejection, type MockModule } from './testModule';

jest.mock('../NativeClikgate', () => ({
  __esModule: true,
  default: jest.requireActual('./testModule').createMockModule(),
}));

const mockModule: MockModule = jest.requireMock('../NativeClikgate').default;

beforeEach(() => {
  resetClikgateForTesting();
  jest.clearAllMocks();
});

describe('isFeatureEnabled', () => {
  it('asks native with {key}', async () => {
    mockModule.isFeatureEnabled.mockResolvedValueOnce(false);
    await expect(Clikgate.isFeatureEnabled('leaderboards')).resolves.toBe(
      false
    );
    expect(mockModule.isFeatureEnabled).toHaveBeenCalledWith({
      key: 'leaderboards',
    });
    await expect(Clikgate.isFeatureEnabled('offline_codes')).resolves.toBe(
      true
    );
  });

  it('answers false for an empty key without calling native', async () => {
    await expect(Clikgate.isFeatureEnabled('')).resolves.toBe(false);
    expect(mockModule.isFeatureEnabled).not.toHaveBeenCalled();
  });

  it('treats a null answer as false', async () => {
    mockModule.isFeatureEnabled.mockResolvedValueOnce(
      null as unknown as boolean
    );
    await expect(Clikgate.isFeatureEnabled('some_new_flag')).resolves.toBe(
      false
    );
  });
});

describe('getRequestContext / reportServerError (internal, Engage)', () => {
  it('decodes the context map', async () => {
    await expect(Clikgate.getRequestContext()).resolves.toEqual({
      installationId: 'inst-1',
      sdkKey: 'cg_sdk_test',
      environment: 'production',
      apiBaseUrl: 'https://sdk.clikgate.com',
      identityToken: null,
      customerUserId: null,
      sdkVersion: 'react-native/1.0.0',
      nativeSdkVersion: 'android/1.0.0',
    });
    expect(mockModule.getRequestContext).toHaveBeenCalledWith({});
  });

  it('strips a trailing slash and keeps the identity fields', async () => {
    mockModule.getRequestContext.mockResolvedValueOnce({
      installationId: 'i',
      sdkKey: 'k',
      environment: 'sandbox',
      apiBaseUrl: 'http://10.0.2.2:8000/',
      identityToken: 'sig.1',
      customerUserId: 'user_42',
      sdkVersion: 'react-native/1.0.0',
      nativeSdkVersion: null,
    });
    await expect(Clikgate.getRequestContext()).resolves.toMatchObject({
      environment: 'sandbox',
      apiBaseUrl: 'http://10.0.2.2:8000',
      identityToken: 'sig.1',
      customerUserId: 'user_42',
      nativeSdkVersion: null,
    });
  });

  it('maps native rejections (install_pending, opted_out)', async () => {
    mockModule.getRequestContext.mockRejectedValueOnce(
      nativeRejection('install_pending', 'not yet', null)
    );
    await expect(Clikgate.getRequestContext()).rejects.toMatchObject({
      code: ClikgateError.installPending,
    });
  });

  it('reportServerError sends {code, feature} and never rejects', async () => {
    await Clikgate.reportServerError('feature_disabled', 'leaderboards');
    expect(mockModule.reportServerError).toHaveBeenCalledWith({
      code: 'feature_disabled',
      feature: 'leaderboards',
    });
    mockModule.reportServerError.mockRejectedValueOnce(new Error('x'));
    await expect(
      Clikgate.reportServerError('invalid_sdk_key')
    ).resolves.toBeUndefined();
    expect(mockModule.reportServerError).toHaveBeenLastCalledWith({
      code: 'invalid_sdk_key',
      feature: null,
    });
  });
});

describe('feature_disabled on the core referral calls', () => {
  it('maps a native feature_disabled rejection and names the feature', async () => {
    mockModule.referralsApplyCode.mockRejectedValueOnce(
      nativeRejection('feature_disabled', 'off', { status: null, param: null })
    );
    const e = await Clikgate.referrals
      .applyCode({ programId: 'p', code: 'X' })
      .catch((x) => x);
    expect(e).toBeInstanceOf(ClikgateError);
    expect(e).toMatchObject({ code: 'feature_disabled', feature: 'referrals' });
  });

  it('turns a resolved {accepted: false, reason: feature_disabled} body into the error', async () => {
    mockModule.referralsReferredBy.mockResolvedValueOnce(
      toBridgeMap(fixture('feature_disabled')) as object
    );
    await expect(Clikgate.referrals.referredBy()).rejects.toMatchObject({
      code: 'feature_disabled',
      feature: 'leaderboards', // the body's own feature wins
    });
  });

  it('exposes the error code constants', () => {
    expect(ClikgateError.featureDisabled).toBe('feature_disabled');
    expect(ClikgateError.rateLimited).toBe('rate_limited');
    expect(ClikgateError.codeNotFound).toBe('code_not_found');
    expect(
      new ClikgateError('feature_disabled', 'off', {
        feature: 'referrals',
      }).toString()
    ).toBe('ClikgateError(feature_disabled, feature: referrals): off');
  });
});

describe('ClikgateError.fromNative (v3 details)', () => {
  it('keeps offlineTouchId and the native feature name', () => {
    const error = ClikgateError.fromNative({
      code: 'self_referral',
      message: 'You cannot use your own code.',
      userInfo: { status: 422, param: 'code', offlineTouchId: 'oft_9' },
    });
    expect(error.offlineTouchId).toBe('oft_9');
    expect(error.feature).toBeNull();

    const disabled = ClikgateError.fromNative(
      { code: 'feature_disabled', userInfo: { feature: 'offline_codes' } },
      'leaderboards'
    );
    expect(disabled.feature).toBe('offline_codes');
    expect(disabled.offlineTouchId).toBeNull();
  });
});
