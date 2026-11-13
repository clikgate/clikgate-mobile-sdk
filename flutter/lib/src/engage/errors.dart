/// Error codes specific to the Engage features. Errors are thrown as
/// `ClikgateException` (from `clikgate_flutter`) with these codes, the
/// backend's codes (`referrer_not_found`, `leaderboard_not_found`,
/// `code_not_found`, `code_expired`, `identity_required`, ...) or the core
/// codes (`feature_disabled`, `not_configured`, `install_pending`,
/// `opted_out`, `network_error`, `timeout`, `invalid_argument`).
abstract final class ClikgateEngageErrors {
  /// The call acts on behalf of a user and `Clikgate.identifyUser` hasn't been
  /// called (no network call was made).
  static const notIdentified = 'not_identified';

  /// Neither WhatsApp nor the system share sheet could be shown.
  static const shareUnavailable = 'share_unavailable';

  /// `leaderboards.hostedPageUrl`: the server returned no `embed_url`
  /// (older server).
  static const hostedPageUnavailable = 'hosted_page_unavailable';
}
