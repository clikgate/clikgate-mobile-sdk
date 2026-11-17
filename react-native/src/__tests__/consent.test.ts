import { resetClikgateForTesting } from '../Clikgate';
import { Clikgate, ClikgateError } from '../index';
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

describe('setConsent', () => {
  it('sends only the given purposes (omitted = unchanged)', async () => {
    await Clikgate.setConsent({ analytics: 'granted', adUserData: 'denied' });
    expect(mockModule.setConsent).toHaveBeenCalledWith({
      analytics: 'granted',
      adUserData: 'denied',
    });
    await Clikgate.setConsent({});
    expect(mockModule.setConsent).toHaveBeenLastCalledWith({});
  });

  it('rejects an unknown state without calling native', async () => {
    const p = Clikgate.setConsent({ attribution: 'yes' as never });
    await expect(p).rejects.toBeInstanceOf(ClikgateError);
    await expect(p).rejects.toMatchObject({
      code: 'invalid_argument',
      param: 'attribution',
    });
    expect(mockModule.setConsent).not.toHaveBeenCalled();
  });

  it('maps native rejections', async () => {
    mockModule.setConsent.mockImplementationOnce(() =>
      Promise.reject(nativeRejection('not_configured', 'configure first', null))
    );
    await expect(
      Clikgate.setConsent({ analytics: 'granted' })
    ).rejects.toMatchObject({
      code: 'not_configured',
    });
  });
});

describe('getConsent', () => {
  it('decodes the consent map', async () => {
    expect(await Clikgate.getConsent()).toEqual({
      analytics: 'granted',
      attribution: 'unknown',
      adUserData: 'denied',
      adPersonalization: 'unknown',
      region: 'EEA',
      required: true,
    });
  });

  it('defaults unknown values', async () => {
    mockModule.getConsent.mockImplementationOnce(() =>
      Promise.resolve<object>({ analytics: 'maybe', required: 'x' })
    );
    expect(await Clikgate.getConsent()).toEqual({
      analytics: 'unknown',
      attribution: 'unknown',
      adUserData: 'unknown',
      adPersonalization: 'unknown',
      region: null,
      required: null,
    });
  });
});

describe('setConsentRegion', () => {
  it('normalises and sends the region', async () => {
    await Clikgate.setConsentRegion(' de ');
    expect(mockModule.setConsentRegion).toHaveBeenCalledWith({ region: 'DE' });
    await Clikgate.setConsentRegion('eea');
    expect(mockModule.setConsentRegion).toHaveBeenLastCalledWith({
      region: 'EEA',
    });
    await Clikgate.setConsentRegion(null);
    expect(mockModule.setConsentRegion).toHaveBeenLastCalledWith({
      region: null,
    });
  });

  it('rejects malformed regions', async () => {
    await expect(Clikgate.setConsentRegion('Europe')).rejects.toMatchObject({
      code: 'invalid_argument',
      param: 'region',
    });
    await expect(Clikgate.setConsentRegion('DEU')).rejects.toMatchObject({
      code: 'invalid_argument',
    });
    expect(mockModule.setConsentRegion).not.toHaveBeenCalled();
  });
});

describe('enableFirebaseForwarding', () => {
  it('sends the defaults', async () => {
    await Clikgate.enableFirebaseForwarding();
    expect(mockModule.enableFirebaseForwarding).toHaveBeenCalledWith({
      logAttributionEvent: true,
      setUserProperties: true,
    });
  });

  it('passes options', async () => {
    await Clikgate.enableFirebaseForwarding({ setUserProperties: false });
    expect(mockModule.enableFirebaseForwarding).toHaveBeenCalledWith({
      logAttributionEvent: true,
      setUserProperties: false,
    });
  });
});

describe('attributionMetadata', () => {
  it('returns the string map', async () => {
    expect(await Clikgate.attributionMetadata()).toEqual({
      cg_click_id: 'clk_1',
      cg_link_id: 'lnk_1',
    });
  });

  it('is empty when native has nothing', async () => {
    mockModule.attributionMetadata.mockImplementationOnce(() =>
      Promise.resolve<object>({ cg_click_id: null })
    );
    expect(await Clikgate.attributionMetadata()).toEqual({});
  });
});

describe('enableGoogleOnDeviceMeasurement', () => {
  it('calls native with an empty map', async () => {
    await Clikgate.enableGoogleOnDeviceMeasurement();
    expect(mockModule.enableGoogleOnDeviceMeasurement).toHaveBeenCalledWith({});
  });
});
