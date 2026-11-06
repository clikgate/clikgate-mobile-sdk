/**
 * Error codes a `ClikgateError` can carry: SDK codes, the backend codes of the referral calls,
 * and any other backend code (the union stays open; `@clikgate/react-native-engage` adds its own).
 */
export type ClikgateErrorCode =
  // SDK
  | 'not_configured'
  | 'network_error'
  | 'opted_out'
  | 'invalid_argument'
  | 'timeout'
  | 'install_pending'
  | 'unsupported_platform'
  | 'unknown'
  // any feature endpoint (v3)
  | 'feature_disabled'
  | 'rate_limited'
  // identity
  | 'not_identified'
  | 'identity_required'
  | 'identity_invalid'
  // referrals
  | 'code_not_found'
  | 'already_referred'
  | 'window_expired'
  | 'self_referral'
  | 'program_paused'
  | (string & {});

/**
 * An error from the Clikgate SDK or API.
 *
 * `code` is the backend error code (`code_not_found`, `already_referred`, `window_expired`,
 * `self_referral`, `identity_required`, `not_identified`, `program_paused`, ...) or an SDK
 * code (`not_configured`, `network_error`, `opted_out`, `invalid_argument`, `timeout`,
 * `install_pending`, `unsupported_platform`).
 *
 * `feature_disabled` means the organisation switched the feature off (`feature` names it, e.g.
 * `referrals`); the SDK answers it from the cached config without a network call.
 */
export class ClikgateError extends Error {
  static readonly notConfigured = 'not_configured';
  static readonly networkError = 'network_error';
  static readonly optedOut = 'opted_out';
  static readonly invalidArgument = 'invalid_argument';
  static readonly timeout = 'timeout';
  static readonly installPending = 'install_pending';
  static readonly unsupportedPlatform = 'unsupported_platform';
  static readonly featureDisabled = 'feature_disabled';
  static readonly rateLimited = 'rate_limited';
  static readonly codeNotFound = 'code_not_found';

  readonly code: ClikgateErrorCode;
  /** HTTP status when the error came from the API. */
  readonly status: number | null;
  /** The request field the error refers to, if any. */
  readonly param: string | null;
  /** For `feature_disabled`: the switched-off feature (`referrals`, ...). */
  readonly feature: string | null;
  /**
   * For a referral error from Engage `codes.redeem`: the redemption was still recorded as this
   * offline touch.
   */
  readonly offlineTouchId: string | null;

  constructor(
    code: ClikgateErrorCode,
    message: string,
    options: {
      status?: number | null;
      param?: string | null;
      feature?: string | null;
      offlineTouchId?: string | null;
    } = {}
  ) {
    super(message);
    this.name = 'ClikgateError';
    this.code = code;
    this.status = options.status ?? null;
    this.param = options.param ?? null;
    this.feature = options.feature ?? null;
    this.offlineTouchId = options.offlineTouchId ?? null;
    // Keep `instanceof` working when compiled to ES5-style classes.
    Object.setPrototypeOf(this, ClikgateError.prototype);
  }

  /**
   * Maps a native promise rejection (`code`, `message`, `userInfo: {status, param, feature}`)
   * to a `ClikgateError`. Other errors become `ClikgateError('unknown')`. `defaultFeature` is
   * used for a `feature_disabled` rejection that doesn't name its feature.
   */
  static fromNative(
    error: unknown,
    defaultFeature: string | null = null
  ): ClikgateError {
    if (error instanceof ClikgateError) return error;
    const e = (error ?? {}) as {
      code?: unknown;
      message?: unknown;
      userInfo?: unknown;
      details?: unknown;
    };
    const code =
      typeof e.code === 'string' && e.code.length > 0 ? e.code : 'unknown';
    const message =
      typeof e.message === 'string' && e.message.length > 0 ? e.message : code;
    const info = (
      isObject(e.userInfo) ? e.userInfo : isObject(e.details) ? e.details : {}
    ) as {
      status?: unknown;
      param?: unknown;
      feature?: unknown;
      offlineTouchId?: unknown;
    };
    const status =
      typeof info.status === 'number' && Number.isFinite(info.status)
        ? Math.trunc(info.status)
        : null;
    const param = typeof info.param === 'string' ? info.param : null;
    const feature =
      typeof info.feature === 'string' && info.feature.length > 0
        ? info.feature
        : code === ClikgateError.featureDisabled
          ? defaultFeature
          : null;
    const offlineTouchId =
      typeof info.offlineTouchId === 'string' ? info.offlineTouchId : null;
    return new ClikgateError(code, message, {
      status,
      param,
      feature,
      offlineTouchId,
    });
  }

  override toString(): string {
    const status = this.status != null ? `, ${this.status}` : '';
    const param = this.param != null ? `, param: ${this.param}` : '';
    const feature = this.feature != null ? `, feature: ${this.feature}` : '';
    return `ClikgateError(${this.code}${status}${param}${feature}): ${this.message}`;
  }
}

function isObject(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null;
}
