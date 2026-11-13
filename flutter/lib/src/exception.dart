import 'package:flutter/services.dart';

/// An error from the Clikgate SDK or API.
///
/// [code] is the backend error code (`code_not_found`, `already_referred`,
/// `window_expired`, `self_referral`, `identity_required`, `not_identified`,
/// `program_paused`, ...) or an SDK
/// code (`not_configured`, `network_error`, `opted_out`, `invalid_argument`,
/// `timeout`, `install_pending`, `unsupported_platform`, `feature_disabled`).
class ClikgateException implements Exception {
  const ClikgateException(this.code, this.message,
      {this.status, this.param, this.feature, this.offlineTouchId});

  /// Maps a [PlatformException] from the native SDK.
  factory ClikgateException.fromPlatformException(PlatformException e) {
    final details = e.details;
    int? status;
    String? param;
    String? feature;
    String? offlineTouchId;
    if (details is Map) {
      status = (details['status'] as num?)?.toInt();
      param = details['param'] as String?;
      feature = details['feature'] as String?;
      offlineTouchId = details['offlineTouchId'] as String?;
    }
    return ClikgateException(e.code, e.message ?? e.code,
        status: status,
        param: param,
        feature: feature,
        offlineTouchId: offlineTouchId);
  }

  final String code;
  final String message;

  /// HTTP status when the error came from the API.
  final int? status;

  /// The request field the error refers to, if any.
  final String? param;

  /// For [featureDisabled]: the switched-off feature (`leaderboards`,
  /// `offline_codes`, `referrals`, ...).
  final String? feature;

  /// Engage `codes.redeem` only: the offline touch that was recorded although the
  /// referral could not be created (`self_referral`, `already_referred`, ...).
  final String? offlineTouchId;

  static const notConfigured = 'not_configured';
  static const networkError = 'network_error';
  static const optedOut = 'opted_out';
  static const invalidArgument = 'invalid_argument';
  static const timeout = 'timeout';
  static const installPending = 'install_pending';
  static const unsupportedPlatform = 'unsupported_platform';

  /// The feature behind the call is switched off for this app (no network
  /// call was made, or the server answered with its no-op body). See
  /// [feature].
  static const featureDisabled = 'feature_disabled';

  @override
  String toString() =>
      'ClikgateException($code${status != null ? ', $status' : ''}'
      '${param != null ? ', param: $param' : ''}'
      '${feature != null ? ', feature: $feature' : ''}): $message';
}
