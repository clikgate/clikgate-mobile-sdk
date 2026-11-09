import { resetClikgateForTesting } from '../Clikgate';
import { Clikgate } from '../index';
import { fixture, toBridgeMap } from './fixtures';
import { type MockModule } from './testModule';

jest.mock('../NativeClikgate', () => ({
  __esModule: true,
  default: jest.requireActual('./testModule').createMockModule(),
}));

const mockModule: MockModule = jest.requireMock('../NativeClikgate').default;

beforeEach(() => {
  resetClikgateForTesting();
  jest.clearAllMocks();
});

/**
 * Change 10 (D.5): deep-link-only mode (Free, Starter, or an app with attribution switched off).
 * The native SDKs warn once ("switched off") and resolve goal, so the JS calls never
 * reject; the install result has organic attribution and, at the deferred deep link cap, no link.
 */
describe('deep-link-only mode', () => {
  const features = fixture('config_response_deep_link_only').features as Record<
    string,
    unknown
  >;

  it('the config fixture has deep linking on and attribution off', async () => {
    mockModule.isFeatureEnabled.mockImplementation(
      async (args: object) => features[(args as { key: string }).key] === true
    );
    await expect(Clikgate.isFeatureEnabled('app_attribution')).resolves.toBe(
      false
    );
    await expect(Clikgate.isFeatureEnabled('deep_linking')).resolves.toBe(true);
  });

  it('goal resolves refused (feature_disabled), without an error', async () => {
    mockModule.goal.mockImplementationOnce(() =>
      Promise.resolve({
        status: 'refused',
        reason: 'feature_disabled',
        goalKind: null,
        valueIgnored: false,
      } as never)
    );
    await expect(
      Clikgate.goal('account_opened', { reference: 'APP-1' })
    ).resolves.toEqual({
      status: 'refused',
      reason: 'feature_disabled',
      goalKind: null,
      valueIgnored: false,
    });
    expect(mockModule.goal).toHaveBeenCalledTimes(1);
  });

  it.each(['install_response_deep_link_only', 'install_response_deferred_cap'])(
    '%s: attribution is organic',
    async (name) => {
      const body = fixture(name);
      mockModule.getAttribution.mockResolvedValueOnce({
        ...(toBridgeMap(body.attribution) as object),
        installId: body.install_id,
      });
      const a = await Clikgate.getAttribution();
      expect(a.status).toBe('organic');
      expect(a.link).toBeNull();
    }
  );

  it.each(['goals_response_feature_disabled'])(
    '%s names app_attribution',
    (name) => {
      expect(fixture(name)).toEqual({
        accepted: false,
        reason: 'feature_disabled',
        feature: 'app_attribution',
      });
    }
  );
});
