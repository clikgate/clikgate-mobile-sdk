import { ClikgateError } from '../errors';

describe('ClikgateError', () => {
  it('is an Error with code, status and param', () => {
    const e = new ClikgateError('self_referral', 'Own code', {
      status: 422,
      param: 'code',
    });
    expect(e).toBeInstanceOf(Error);
    expect(e).toBeInstanceOf(ClikgateError);
    expect(e.name).toBe('ClikgateError');
    expect(e.code).toBe('self_referral');
    expect(e.status).toBe(422);
    expect(e.param).toBe('code');
  });

  it('fromNative keeps an existing ClikgateError', () => {
    const e = new ClikgateError('timeout', 'slow');
    expect(ClikgateError.fromNative(e)).toBe(e);
  });

  it('fromNative handles non-error values', () => {
    expect(ClikgateError.fromNative(undefined)).toMatchObject({
      code: 'unknown',
      message: 'unknown',
    });
    expect(ClikgateError.fromNative('x')).toMatchObject({ code: 'unknown' });
    expect(
      ClikgateError.fromNative({
        code: 'network_error',
        message: '',
        userInfo: { status: 'x' },
      })
    ).toMatchObject({
      code: 'network_error',
      message: 'network_error',
      status: null,
    });
    expect(
      ClikgateError.fromNative({
        code: 'rate_limited',
        message: 'Slow down',
        userInfo: { status: 429.0 },
      })
    ).toMatchObject({ status: 429 });
  });

  it('exposes the SDK error codes', () => {
    expect(ClikgateError.notConfigured).toBe('not_configured');
    expect(ClikgateError.networkError).toBe('network_error');
    expect(ClikgateError.optedOut).toBe('opted_out');
    expect(ClikgateError.invalidArgument).toBe('invalid_argument');
    expect(ClikgateError.timeout).toBe('timeout');
    expect(ClikgateError.installPending).toBe('install_pending');
    expect(ClikgateError.unsupportedPlatform).toBe('unsupported_platform');
  });
});
