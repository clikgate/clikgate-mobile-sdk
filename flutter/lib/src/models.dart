import 'package:flutter/foundation.dart';

/// Push provider of a token passed to `Clikgate.setPushToken`.
enum PushProvider {
  /// Firebase Cloud Messaging registration token.
  fcm,

  /// APNs device token (hex string).
  apns,
}

/// SDK log level (logs never contain keys or tokens).
enum ClikgateLogLevel { verbose, debug, info, warn, error, none }

/// The environment of the app's SDK key.
enum ClikgateEnvironment { production, sandbox }

/// Device attestation on install (Play Integrity / App Attest).
enum ClikgateAttestation { off, ifAvailable }

/// iOS pasteboard matching mode (ignored on Android).
enum ClikgatePasteboardMode { off, automatic, pasteControlOnly }

/// Install attribution status.
enum ClikgateAttributionStatus {
  pending,
  attributed,
  organic;

  static ClikgateAttributionStatus parse(Object? value) => switch (value) {
        'attributed' => attributed,
        'organic' => organic,
        _ => pending,
      };
}

/// The outcome of a goal call ([GoalResult.status]).
enum GoalStatus {
  /// The goal counted.
  counted,

  /// Not counted yet: a Payment goal waiting for its confirmation from your
  /// payment provider or server, or a goal waiting for its click.
  waiting,

  /// Stored, not counted: the name isn't ticked as a goal in the dashboard yet
  /// (`not_counted_yet`) or the goal is archived (`goal_archived`). A success:
  /// it isn't retried. It counts once the name is ticked.
  received,

  /// Not counted; [GoalResult.reason] says why. Final: never retried. When
  /// the organisation accepts only goals it has set up, a name with no goal
  /// behind it is refused with `unknown_goal` (an archived goal with
  /// `goal_archived`); debug builds log "Goal `name` isn't set up in Clikgate".
  refused;

  /// The status for a wire value (`counted`, `waiting`, `received`,
  /// `refused`); unknown values are [refused].
  static GoalStatus parse(Object? value) => switch (value) {
        'counted' => counted,
        'waiting' => waiting,
        'received' => received,
        _ => refused,
      };
}

/// The kind of a goal, set in the goal's settings (never in the call).
enum GoalKind {
  /// Counts when it's sent.
  standard,

  /// Counts when your payment provider or server confirms it, with the real
  /// amount.
  payment;

  /// The kind for a wire value; null when unknown or absent.
  static GoalKind? parse(Object? value) => switch (value) {
        'standard' => standard,
        'payment' => payment,
        _ => null,
      };
}

/// The result of `Clikgate.goal`.
@immutable
class GoalResult {
  const GoalResult(
      {required this.status,
      this.reason,
      this.goalKind,
      this.valueIgnored = false});

  /// Decodes the platform channel's goal result map.
  factory GoalResult.fromMap(Map<String, dynamic> m) => GoalResult(
        status: GoalStatus.parse(m['status']),
        reason: m['reason'] as String?,
        goalKind: GoalKind.parse(m['goalKind']),
        valueIgnored: m['valueIgnored'] == true,
      );

  final GoalStatus status;

  /// Null when counted; else a reason code such as `waiting_for_confirmation`,
  /// `not_counted_yet`, `goal_archived`, `unknown_goal`, `unattributed`,
  /// `payment_goal_needs_confirmation` or `invalid_argument`.
  final String? reason;

  /// The goal's kind, when Clikgate said (null for goals refused on the
  /// device).
  final GoalKind? goalKind;

  /// True when a value was sent for a Payment goal: it was ignored (the amount
  /// comes from the confirmation).
  final bool valueIgnored;

  @override
  bool operator ==(Object other) =>
      other is GoalResult &&
      other.status == status &&
      other.reason == reason &&
      other.goalKind == goalKind &&
      other.valueIgnored == valueIgnored;

  @override
  int get hashCode => Object.hash(status, reason, goalKind, valueIgnored);

  @override
  String toString() =>
      'GoalResult(status: ${status.name}, reason: $reason, goalKind: ${goalKind?.name}, valueIgnored: $valueIgnored)';
}

/// The Clikgate link behind a deep link or attribution.
@immutable
class ClikgateLink {
  const ClikgateLink({
    required this.id,
    required this.kind,
    this.externalReference,
    this.campaignId,
    this.metadata = const {},
  });

  factory ClikgateLink.fromMap(Map<String, dynamic> m) => ClikgateLink(
        id: m['id'] as String? ?? '',
        kind: m['kind'] as String? ?? 'standard',
        externalReference: m['externalReference'] as String?,
        campaignId: m['campaignId'] as String?,
        metadata: asStringMap(m['metadata']),
      );

  final String id;

  /// `standard` or `referral`.
  final String kind;
  final String? externalReference;
  final String? campaignId;
  final Map<String, dynamic> metadata;

  bool get isReferral => kind == 'referral';
}

/// A referral of this installation (as referee).
@immutable
class Referral {
  const Referral({
    required this.referralId,
    required this.programId,
    required this.status,
    required this.referrerId,
    this.source,
    this.referrerDisplayName,
    this.createdAt,
  });

  factory Referral.fromMap(Map<String, dynamic> m) => Referral(
        referralId: m['referralId'] as String? ?? '',
        programId: m['programId'] as String? ?? '',
        status: m['status'] as String? ?? 'installed',
        source: m['source'] as String?,
        referrerId: m['referrerId'] as String? ?? '',
        referrerDisplayName: m['referrerDisplayName'] as String?,
        createdAt: _date(m['createdAt']),
      );

  final String referralId;
  final String programId;

  /// `installed`, `signed_up`, `in_progress`, `holding`, `qualified`,
  /// `disqualified` or `rejected`.
  final String status;

  /// `link`, `code_entry`, `byo_code` or `offline_code`.
  final String? source;
  final String referrerId;
  final String? referrerDisplayName;
  final DateTime? createdAt;
}

/// A deep link: deferred (first launch after install) or direct (App Link,
/// Universal Link, custom scheme).
@immutable
class ClikgateDeepLink {
  const ClikgateDeepLink({
    this.url,
    this.path,
    this.data = const {},
    this.isDeferred = false,
    this.clickId,
    this.matchType,
    this.link,
    this.referral,
    this.blockMessage,
  });

  factory ClikgateDeepLink.fromMap(Map<String, dynamic> m) => ClikgateDeepLink(
        url: m['url'] as String?,
        path: m['path'] as String?,
        data: asStringMap(m['data']),
        isDeferred: m['isDeferred'] as bool? ?? false,
        clickId: m['clickId'] as String?,
        matchType: m['matchType'] as String?,
        link: _optional(m['link'], ClikgateLink.fromMap),
        referral: _optional(m['referral'], Referral.fromMap),
        blockMessage: m['blockMessage'] as String?,
      );

  final String? url;
  final String? path;
  final Map<String, dynamic> data;
  final bool isDeferred;
  final String? clickId;

  /// `app_link`, `install_referrer`, `pasteboard`, `code_entry`, ...
  final String? matchType;
  final ClikgateLink? link;
  final Referral? referral;

  /// Set when the link is blocked here (allowed countries or a block rule):
  /// show this text and don't route. [path], [clickId] and [link] are null.
  final String? blockMessage;

  @override
  String toString() =>
      'ClikgateDeepLink(path: $path, data: $data, isDeferred: $isDeferred, '
      'matchType: $matchType, referral: ${referral?.referralId}'
      '${blockMessage != null ? ', blocked' : ''})';
}

/// A link on a shared Clikgate domain (`ciz.to`, `clk.ng`, `clkg.to`,
/// `dev.ciz.to`) that isn't this app's: the native SDK opened [url] in an
/// in-app browser (Custom Tabs / SFSafariViewController) instead of
/// delivering a deep link.
class ClikgateBrowserHandoff {
  const ClikgateBrowserHandoff({required this.url, required this.host});

  factory ClikgateBrowserHandoff.fromMap(Map<String, dynamic> m) =>
      ClikgateBrowserHandoff(
          url: m['url'] as String? ?? '', host: m['host'] as String? ?? '');

  final String url;
  final String host;

  @override
  String toString() => 'ClikgateBrowserHandoff(host: $host)';
}

/// Install attribution of this installation.
@immutable
class ClikgateAttribution {
  const ClikgateAttribution({
    required this.status,
    this.matchType,
    this.confidence,
    this.clickId,
    this.clickedAt,
    this.isReinstall = false,
    this.installId,
    this.link,
  });

  factory ClikgateAttribution.fromMap(Map<String, dynamic> m) =>
      ClikgateAttribution(
        status: ClikgateAttributionStatus.parse(m['status']),
        matchType: m['matchType'] as String?,
        confidence: (m['confidence'] as num?)?.toDouble(),
        clickId: m['clickId'] as String?,
        clickedAt: _date(m['clickedAt']),
        isReinstall: m['isReinstall'] as bool? ?? false,
        installId: m['installId'] as String?,
        link: _optional(m['link'], ClikgateLink.fromMap),
      );

  final ClikgateAttributionStatus status;
  final String? matchType;
  final double? confidence;
  final String? clickId;
  final DateTime? clickedAt;
  final bool isReinstall;

  /// Clikgate install id (`ins_...`), null until the install was recorded.
  final String? installId;
  final ClikgateLink? link;

  bool get isAttributed => status == ClikgateAttributionStatus.attributed;
}

/// Whether this installation was referred.
@immutable
class ReferredBy {
  const ReferredBy({required this.referred, this.referral});

  factory ReferredBy.fromMap(Map<String, dynamic> m) => ReferredBy(
        referred: m['referred'] as bool? ?? false,
        referral: _optional(m['referral'], Referral.fromMap),
      );

  final bool referred;
  final Referral? referral;
}

/// Feature keys for `Clikgate.isFeatureEnabled`.
abstract final class ClikgateFeatures {
  static const appAttribution = 'app_attribution';
  static const referrals = 'referrals';
  static const leaderboards = 'leaderboards';
  static const identityChecks = 'identity_checks';
  static const whatsappAttribution = 'whatsapp_attribution';
  static const offlineCodes = 'offline_codes';
  static const skanPostbacks = 'skan_postbacks';
  static const uninstallTracking = 'uninstall_tracking';
  static const probabilisticMatching = 'probabilistic_matching';
  static const appleSearchAds = 'apple_search_ads';
}

/// **Internal** (used by the Engage features, `engage.dart`; not part of the app-facing API):
/// what a `/v1/sdk/*` call needs to act for this installation, from the
/// native core SDK (`Clikgate.getRequestContext`). A snapshot: get a fresh
/// one per call (the identity token changes with `Clikgate.identifyUser`).
@immutable
class ClikgateRequestContext {
  const ClikgateRequestContext({
    required this.installationId,
    required this.sdkKey,
    required this.environment,
    required this.apiBaseUrl,
    required this.sdkVersion,
    this.identityToken,
    this.customerUserId,
    this.nativeSdkVersion,
  });

  factory ClikgateRequestContext.fromMap(Map<String, dynamic> m) =>
      ClikgateRequestContext(
        installationId: m['installationId'] as String? ?? '',
        sdkKey: m['sdkKey'] as String? ?? '',
        environment: m['environment'] as String? ?? 'production',
        apiBaseUrl: m['apiBaseUrl'] as String? ?? 'https://sdk.clikgate.com',
        identityToken: m['identityToken'] as String?,
        customerUserId: m['customerUserId'] as String?,
        sdkVersion: m['sdkVersion'] as String? ?? 'flutter/unknown',
        nativeSdkVersion: m['nativeSdkVersion'] as String?,
      );

  /// `Clikgate-Installation-Id`.
  final String installationId;

  /// `Clikgate-SDK-Key`.
  final String sdkKey;

  /// `production` or `sandbox`.
  final String environment;

  /// The SDK API base URL (e.g. `https://sdk.clikgate.com`).
  final String apiBaseUrl;

  /// The identity token from the last `Clikgate.identifyUser`, if any.
  final String? identityToken;

  /// The identified user; null when the installation isn't identified.
  final String? customerUserId;

  /// Exact `Clikgate-SDK-Version` header value (`flutter/1.0.0`).
  final String sdkVersion;

  /// `Clikgate-SDK-Native-Version` header value (`android/1.0.0`, `ios/1.0.0`).
  final String? nativeSdkVersion;

  /// The contract's request headers (SDK key, versions, installation id,
  /// identity token).
  Map<String, String> get headers => {
        'Clikgate-SDK-Key': sdkKey,
        'Clikgate-SDK-Version': sdkVersion,
        if (nativeSdkVersion != null)
          'Clikgate-SDK-Native-Version': nativeSdkVersion!,
        'Clikgate-Installation-Id': installationId,
        if (identityToken != null) 'Clikgate-Identity-Token': identityToken!,
      };

  @override
  String toString() =>
      'ClikgateRequestContext(installationId: $installationId, environment: '
      '$environment, apiBaseUrl: $apiBaseUrl, identified: ${customerUserId != null})';
}

/// Converts a platform-channel map (`Map<Object?, Object?>`) recursively.
Map<String, dynamic> asStringMap(Object? value) {
  if (value is! Map) return <String, dynamic>{};
  return value.map((k, v) => MapEntry(k.toString(), _deep(v)));
}

Object? _deep(Object? v) {
  if (v is Map) return asStringMap(v);
  if (v is List) return v.map(_deep).toList();
  return v;
}

T? _optional<T>(Object? v, T Function(Map<String, dynamic>) f) =>
    v is Map ? f(asStringMap(v)) : null;

DateTime? _date(Object? v) => v is String ? DateTime.tryParse(v) : null;

/// State of one consent purpose.
enum ConsentState {
  granted,
  denied,
  unknown;

  static ConsentState parse(Object? value) => switch (value) {
        'granted' => granted,
        'denied' => denied,
        _ => unknown,
      };
}

/// The consent set with `Clikgate.setConsent`, the region hint from
/// `Clikgate.setConsentRegion`, and whether consent is required for this
/// device ([required] is null until the SDK knows).
@immutable
class ClikgateConsent {
  const ClikgateConsent({
    this.analytics = ConsentState.unknown,
    this.attribution = ConsentState.unknown,
    this.adUserData = ConsentState.unknown,
    this.adPersonalization = ConsentState.unknown,
    this.region,
    this.required,
  });

  factory ClikgateConsent.fromMap(Map<String, dynamic> m) => ClikgateConsent(
        analytics: ConsentState.parse(m['analytics']),
        attribution: ConsentState.parse(m['attribution']),
        adUserData: ConsentState.parse(m['adUserData']),
        adPersonalization: ConsentState.parse(m['adPersonalization']),
        region: m['region'] as String?,
        required: m['required'] as bool?,
      );

  final ConsentState analytics;
  final ConsentState attribution;
  final ConsentState adUserData;
  final ConsentState adPersonalization;

  /// Region hint (`EEA`, `UK` or an ISO 3166-1 alpha-2 country), or null.
  final String? region;

  /// Whether consent is required for this device; null while unknown.
  final bool? required;

  @override
  bool operator ==(Object other) =>
      other is ClikgateConsent &&
      other.analytics == analytics &&
      other.attribution == attribution &&
      other.adUserData == adUserData &&
      other.adPersonalization == adPersonalization &&
      other.region == region &&
      other.required == required;

  @override
  int get hashCode => Object.hash(
      analytics, attribution, adUserData, adPersonalization, region, required);

  @override
  String toString() =>
      'ClikgateConsent(analytics: ${analytics.name}, attribution: ${attribution.name}, '
      'adUserData: ${adUserData.name}, adPersonalization: ${adPersonalization.name}, '
      'region: $region, required: $required)';
}
