import { resetClikgateForTesting } from '../Clikgate';
import {
  CLIKGATE_PROVIDERS,
  Clikgate,
  ClikgateProvider,
  GoalKind,
  GoalStatus,
  providerFromString,
} from '../index';
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

/** Bridge method `goal`: arguments, the result map, providers and enums. */
describe('goal', () => {
  it('sends every option, the value as a decimal string', async () => {
    await Clikgate.goal('account_opened', {
      value: 2000000,
      currency: 'NGN',
      reference: 'APP-55231',
      isFirst: true,
      label: 'Ada',
    });
    expect(mockModule.goal).toHaveBeenCalledWith({
      key: 'account_opened',
      value: '2000000',
      currency: 'NGN',
      reference: 'APP-55231',
      provider: null,
      isFirst: true,
      label: 'Ada',
    });
  });

  it('defaults every option to null', async () => {
    await Clikgate.goal('kyc_passed');
    expect(mockModule.goal).toHaveBeenCalledWith({
      key: 'kyc_passed',
      value: null,
      currency: null,
      reference: null,
      provider: null,
      isFirst: null,
      label: null,
    });
  });

  it('turns numbers and numeric strings into decimal strings, never doubles', async () => {
    const cases: [number | string | bigint, string][] = [
      [2000000, '2000000'],
      [1500.5, '1500.5'],
      [0.25, '0.25'],
      [3.0, '3'],
      ['1500.50', '1500.50'], // strings pass unchanged; the native SDK normalises
      [' 42 ', '42'],
      [BigInt('123456789012345'), '123456789012345'],
    ];
    for (const [input, wire] of cases) {
      mockModule.goal.mockClear();
      await Clikgate.goal('order_paid', { value: input as never });
      expect(mockModule.goal.mock.calls[0]![0]).toMatchObject({ value: wire });
    }
  });

  it('refuses NaN, infinity, exponent notation and other types without calling native', async () => {
    for (const bad of [NaN, Infinity, 1e21, 1e-7, true]) {
      await expect(
        Clikgate.goal('order_paid', { value: bad as never })
      ).resolves.toEqual({
        status: 'refused',
        reason: 'invalid_argument',
        goalKind: null,
        valueIgnored: false,
      });
    }
    expect(mockModule.goal).not.toHaveBeenCalled();
  });

  it('resolves native errors as refused with the error code', async () => {
    mockModule.goal.mockImplementationOnce(() =>
      Promise.reject(
        nativeRejection('invalid_argument', 'Goal keys must be snake_case', {
          param: 'goal',
        })
      )
    );
    await expect(Clikgate.goal('Bad-Key')).resolves.toMatchObject({
      status: GoalStatus.Refused,
      reason: 'invalid_argument',
    });
  });

  it('sends the provider of a Payment goal and decodes waiting', async () => {
    mockModule.goal.mockImplementationOnce(() =>
      Promise.resolve({
        status: 'waiting',
        reason: 'waiting_for_confirmation',
        goalKind: 'payment',
        valueIgnored: true,
      } as never)
    );
    const r = await Clikgate.goal('purchase', {
      reference: 'T123456',
      provider: ClikgateProvider.Paystack,
      value: 10,
    });
    const args = mockModule.goal.mock.calls[0]![0] as Record<string, unknown>;
    expect(args.provider).toBe('paystack');
    expect(args).not.toHaveProperty('kind');
    expect(r).toEqual({
      status: GoalStatus.Waiting,
      reason: 'waiting_for_confirmation',
      goalKind: GoalKind.Payment,
      valueIgnored: true,
    });
  });

  it('decodes counted and maps unknown statuses to refused', async () => {
    mockModule.goal.mockImplementationOnce(() =>
      Promise.resolve({
        status: 'counted',
        reason: null,
        goalKind: 'standard',
        valueIgnored: false,
      } as never)
    );
    await expect(Clikgate.goal('account_opened')).resolves.toEqual({
      status: 'counted',
      reason: null,
      goalKind: 'standard',
      valueIgnored: false,
    });
    mockModule.goal.mockImplementationOnce(() =>
      Promise.resolve({ status: 'later', goalKind: 'other' } as never)
    );
    await expect(Clikgate.goal('account_opened')).resolves.toMatchObject({
      status: 'refused',
      goalKind: null,
    });
  });
});

describe('ClikgateProvider', () => {
  it('has the generated constants and parses newer providers', () => {
    expect(ClikgateProvider.MtnMomo).toBe('mtn_momo');
    expect(CLIKGATE_PROVIDERS).toHaveLength(27);
    expect(CLIKGATE_PROVIDERS).toContain('custom');
    expect(providerFromString(' PayStack ')).toBe(ClikgateProvider.Paystack);
    expect(providerFromString('newpay')).toBe('newpay');
    expect(providerFromString('Bad-Key')).toBeNull();
    expect(providerFromString('')).toBeNull();
  });
});
