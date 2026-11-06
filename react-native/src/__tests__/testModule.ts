/** A mocked `NativeClikgate` TurboModule (every method is a jest.fn returning a promise). */
export function createMockModule() {
  return {
    configure: jest.fn((_args: object) => Promise.resolve(null)),
    getAttribution: jest.fn((_args: object) =>
      Promise.resolve<object>({ status: 'pending', isReinstall: false })
    ),
    track: jest.fn((_args: object) => Promise.resolve(null)),
    identifyUser: jest.fn((_args: object) => Promise.resolve(null)),
    setTrackingEnabled: jest.fn((_args: object) => Promise.resolve(null)),
    setPushToken: jest.fn((_args: object) => Promise.resolve(null)),
    handleUrl: jest.fn((_args: object) => Promise.resolve(true)),
    referralsApplyCode: jest.fn((_args: object) => Promise.resolve<object>({})),
    referralsReferredBy: jest.fn((_args: object) =>
      Promise.resolve<object>({ referred: false, referral: null })
    ),
    sdkVersion: jest.fn(() => Promise.resolve('1.0.0')),
    isFeatureEnabled: jest.fn((_args: object) => Promise.resolve(true)),
    getRequestContext: jest.fn((_args: object) =>
      Promise.resolve<object>({
        installationId: 'inst-1',
        sdkKey: 'cg_sdk_test',
        environment: 'production',
        apiBaseUrl: 'https://sdk.clikgate.com',
        identityToken: null,
        customerUserId: null,
        sdkVersion: 'react-native/1.0.0',
        nativeSdkVersion: 'android/1.0.0',
      })
    ),
    reportServerError: jest.fn((_args: object) => Promise.resolve(null)),
    setConsent: jest.fn((_args: object) => Promise.resolve(null)),
    goal: jest.fn((_args: object) => Promise.resolve(null)),
    getConsent: jest.fn((_args: object) =>
      Promise.resolve<object>({
        analytics: 'granted',
        attribution: 'unknown',
        adUserData: 'denied',
        adPersonalization: 'unknown',
        region: 'EEA',
        required: true,
      })
    ),
    setConsentRegion: jest.fn((_args: object) => Promise.resolve(null)),
    enableFirebaseForwarding: jest.fn((_args: object) => Promise.resolve(null)),
    attributionMetadata: jest.fn((_args: object) =>
      Promise.resolve<object>({ cg_click_id: 'clk_1', cg_link_id: 'lnk_1' })
    ),
    enableGoogleOnDeviceMeasurement: jest.fn((_args: object) =>
      Promise.resolve(null)
    ),
    addListener: jest.fn((_eventName: string) => {}),
    removeListeners: jest.fn((_count: number) => {}),
  };
}

export type MockModule = ReturnType<typeof createMockModule>;

/** A native promise rejection as React Native delivers it to JS. */
export function nativeRejection(
  code: string,
  message: string,
  userInfo: Record<string, unknown> | null
): Error {
  const e = new Error(message) as Error & {
    code: string;
    userInfo: Record<string, unknown> | null;
  };
  e.code = code;
  e.userInfo = userInfo;
  return e;
}
