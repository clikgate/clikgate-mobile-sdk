import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'channel.dart';
import 'deep_link_hub.dart';
import 'exception.dart';
import 'models.dart';
import 'provider.dart';
import 'referrals.dart';


/// identifyUser()'s "customerId not passed" default (never a real customer ID).
const String _keepCustomerId = '\u0000';
/// Clikgate core: deep links, install attribution, goals, identifyUser,
/// referee-side referral calls, uninstall tracking and feature switches. A
/// thin bridge over the native Android and iOS SDKs.
///
/// Referral links and stats, leaderboards, promo codes and share helpers are
/// in the Engage features, `package:clikgate_flutter/engage.dart` (for apps without a backend).
class Clikgate {
  Clikgate._();

  /// Version of this Flutter plugin (reported as `Clikgate-SDK-Version: flutter/<version>`).
  static const String pluginVersion = '2.1.0';

  static DeepLinkHub _hub = DeepLinkHub();

  /// Referee-side referral calls (`applyCode`, `referredBy`).
  static const ClikgateReferrals referrals = ClikgateReferrals();

  /// Whether an organisation feature (see `ClikgateFeatures`) is switched on
  /// for this app, from the native SDK's cached config. Before the first
  /// config fetch: `referrals`, `leaderboards`, `offline_codes`,
  /// `app_attribution` on, the rest off; unknown keys off. Calls of a
  /// switched-off feature throw `ClikgateException(feature_disabled)` without
  /// a network call, so this is only needed to hide UI.
  static Future<bool> isFeatureEnabled(String key) async =>
      await ClikgateChannels.invoke<bool>('isFeatureEnabled', {'key': key}) ??
      false;

  /// Starts the SDK. Call once, early (before `runApp` is fine; it needs
  /// `WidgetsFlutterBinding.ensureInitialized()`).
  ///
  /// [pasteboardMode] (iOS only): the opt-in clipboard deferred deep link.
  /// Off by default since 1.2.0; `automatic` reads the pasteboard on the first
  /// launch (iOS 16+ shows the system paste prompt) when the app's Clikgate
  /// setting enables it.
  ///
  /// [linkDomains]: every link domain of your Clikgate domain group (aliases
  /// such as `ybr.ng` and `go.yourbrand.com` are the same links). Add each one
  /// to the iOS Associated Domains (`applinks:<domain>`) and to an Android
  /// `autoVerify` intent filter. The native SDK adds the server's
  /// `link_domains` (case-insensitive, cached) to these and logs a warning for
  /// any server domain missing here.
  ///
  /// [platformDomainBrowserFallback] (default true): a link on a shared Clikgate
  /// domain (`ciz.to`, `clk.ng`, `clkg.to`, `dev.ciz.to`) that belongs to
  /// another organisation opens in an in-app browser (Custom Tabs /
  /// SFSafariViewController) and is reported on [onBrowserHandoff], never on
  /// [onDeepLink]. False drops it, as before 1.4.0.
  ///
  /// [automaticPushToken] (default true): when uninstall tracking is on for
  /// the app (and tracking and consent allow it), the SDK gets a push token by
  /// itself, without asking for notification permission. iOS: it registers for
  /// remote notifications and this plugin passes the APNs token on (no
  /// AppDelegate code). Android: it fetches the FCM token when Firebase
  /// Messaging is in the app. A token passed to [setPushToken] always wins.
  /// False leaves push registration to the app: call [setPushToken] yourself.
  static Future<void> configure({
    required String sdkKey,
    List<String> linkDomains = const [],
    String? apiBaseUrl,
    ClikgateLogLevel logLevel = ClikgateLogLevel.warn,
    ClikgateEnvironment environment = ClikgateEnvironment.production,
    ClikgateAttestation attestation = ClikgateAttestation.off,
    ClikgatePasteboardMode pasteboardMode = ClikgatePasteboardMode.off,
    bool waitForATT = false,
    Duration deferredDeepLinkTimeout = const Duration(seconds: 5),
    bool platformDomainBrowserFallback = true,
    bool automaticPushToken = true,
  }) async {
    // Listen before configuring so no deep link is missed.
    _hub.start();
    await ClikgateChannels.invoke<void>('configure', {
      'sdkKey': sdkKey,
      'linkDomains': linkDomains,
      'apiBaseUrl': apiBaseUrl,
      'logLevel': logLevel.name,
      'environment': environment.name,
      'attestation': attestation.name,
      'pasteboardMode': pasteboardMode.name,
      'waitForATT': waitForATT,
      'deferredDeepLinkTimeoutMs': deferredDeepLinkTimeout.inMilliseconds,
      'platformDomainBrowserFallback': platformDomainBrowserFallback,
      'automaticPushToken': automaticPushToken,
      'wrapperVersion': pluginVersion,
    });
  }

  /// Every deep link: the deferred one after install and direct opens.
  /// Links received before the first listener attaches are replayed to it.
  static Stream<ClikgateDeepLink> get onDeepLink => _hub.stream;

  /// Shared-domain links of other organisations that the native SDK opened
  /// in an in-app browser instead of the app (no deep link is delivered for
  /// them). Buffered like [onDeepLink].
  static Stream<ClikgateBrowserHandoff> get onBrowserHandoff =>
      _hub.handoffs;

  /// Install attribution. On first launch waits for the server up to
  /// `deferredDeepLinkTimeout`, then returns status `pending`.
  static Future<ClikgateAttribution> getAttribution() async =>
      ClikgateAttribution.fromMap(
          await ClikgateChannels.invokeMap('getAttribution'));

  /// Records a goal: an outcome your business chose, such as
  /// `account_opened`, `loan_disbursed` or `purchase`, attributed to the click
  /// or install that brought this user. `goal()` is the only method for what
  /// happens in your app; it works on every plan:
  /// `Clikgate.goal('account_opened', value: 2000000, currency: 'NGN', reference: 'APP-55231', isFirst: true)`.
  ///
  /// For a **Payment goal** (set in the dashboard), pass the payment provider
  /// and the reference your checkout returned:
  /// `Clikgate.goal('purchase', reference: 'T123456', provider: ClikgateProvider.paystack)`.
  /// It waits until your payment provider or server confirms it, with the
  /// real amount (any [value] sent from the app is ignored).
  ///
  /// [value] is in normal units (never kobo or cents): an `int`, a `double` or
  /// a numeric `String` such as `'1500.50'` (pass a string for exact amounts:
  /// it reaches the native SDK as a decimal string, never as a double). At
  /// most 15 significant digits, zero or more. [reference] is your own unique
  /// id (1-128 characters; a UUID is generated when omitted). Queued, retried
  /// and consent-buffered, idempotent by key and reference, and sent in
  /// private mode too. A name counts once it's ticked in the dashboard ("Count
  /// this as a goal"). Never put customer data in a goal.
  ///
  /// Completes with a [GoalResult] once Clikgate has answered:
  /// [GoalStatus.counted], [GoalStatus.waiting] (a Payment goal waiting for
  /// its confirmation), [GoalStatus.received] (stored, not counted: the name
  /// isn't ticked yet; not retried) or [GoalStatus.refused] with a [GoalResult.reason]
  /// (`invalid_argument` for a bad key, value, currency or reference). While
  /// the device is offline the goal stays queued and the future completes when
  /// it is sent, so don't block your UI on it.
  static Future<GoalResult> goal(String key,
      {Object? value,
      String? currency,
      String? reference,
      ClikgateProvider? provider,
      bool? isFirst,
      String? label}) async {
    final String? wire;
    try {
      wire = _goalValueString(value);
    } on ClikgateException catch (e) {
      return GoalResult(status: GoalStatus.refused, reason: e.code);
    }
    try {
      final map = await ClikgateChannels.invokeMap('goal', {
        'key': key,
        'value': wire,
        'currency': currency,
        'reference': reference,
        'provider': provider?.value,
        'isFirst': isFirst,
        'label': label,
      });
      return GoalResult.fromMap(map);
    } on ClikgateException catch (e) {
      return GoalResult(status: GoalStatus.refused, reason: e.code);
    }
  }

  /// The decimal string sent for a goal value (`2000000` → `'2000000'`,
  /// `'1500.50'` stays a string). Throws `ClikgateException(invalid_argument)`
  /// for NaN, infinity, a number Dart prints with an exponent, or another type.
  static String? _goalValueString(Object? value) {
    if (value == null) return null;
    String? s;
    if (value is String) {
      s = value.trim();
    } else if (value is int || value is BigInt) {
      s = value.toString();
    } else if (value is double && value.isFinite) {
      s = value.toString();
      if (s.endsWith('.0')) s = s.substring(0, s.length - 2);
      if (s.contains('e')) s = null;
    }
    if (s == null) {
      throw const ClikgateException(ClikgateException.invalidArgument,
          'Goal value must be a number or a numeric string (pass very large or small amounts as a string)',
          param: 'value');
    }
    return s;
  }

  /// Tells Clikgate who this user is: an optional [label] your team sees
  /// instead of the click ID (1-80 characters, `''` clears it; Growth and up),
  /// your [customerId] (`null` clears it on logout; leave it out to keep the
  /// stored one) and an [identityToken] from your backend (for referral
  /// programs with `require_identity_token`). With nothing to send it does
  /// nothing. In private mode the customer ID and token are dropped on the
  /// device, and the label too unless your organisation allows labels there.
  /// Don't put information in labels that your customers wouldn't expect you
  /// to keep.
  ///
  /// Identity Path A (the default): your server makes the token with the
  /// server SDK's `createIdentityToken` (it reads `CLIKGATE_IDENTITY_SECRET`;
  /// the secret never goes in the app) and returns it in the sign-in and
  /// "current user" responses; pass the newest one here. Call after sign-in or
  /// sign-up and at app open when already signed in; on sign-out call
  /// `identifyUser(customerId: null)`. Path B needs no token: see
  /// [getInstallationId]. Guide: https://clikgate.com/docs/identify-users
  static Future<void> identifyUser(
      {String? label, String? customerId = _keepCustomerId, String? identityToken}) {
    return ClikgateChannels.invoke<void>('identifyUser', {
      'label': label,
      if (customerId != _keepCustomerId) 'customerId': customerId,
      'identityToken': identityToken,
    });
  }

  /// This installation's ID: the random UUID the native SDK created at first
  /// launch and sends to Clikgate with every call (not personal data; allowed
  /// in private mode). For identity Path B, include it in the sign-in request
  /// to your own server (and at every signed-in app open); your server calls
  /// the server SDK's `identifyUser({appId, installationId, customerId, label?})`.
  /// No identity secret or token is needed.
  ///
  /// `final id = await Clikgate.getInstallationId();` Right after [configure]
  /// it waits for the first launch's config answer (a few seconds at most;
  /// offline it answers at once). A reinstall gets a new ID. Null when tracking
  /// is off ([setTrackingEnabled] `false`, consent denied or not given yet
  /// where it's required, or deep-link-only mode), so your server simply skips
  /// `identifyUser`. Guide: https://clikgate.com/docs/identify-users
  static Future<String?> getInstallationId() =>
      ClikgateChannels.invoke<String>('getInstallationId');

  /// Opt-out switch: `false` stops all processing for this installation.
  static Future<void> setTrackingEnabled(bool enabled) =>
      ClikgateChannels.invoke<void>('setTrackingEnabled', {'enabled': enabled});

  /// Registers the push token used for uninstall checks. A null or empty
  /// token is ignored (e.g. `FirebaseMessaging.instance.getToken()` failed).
  /// For [PushProvider.apns] pass the hex device token. Not needed with
  /// `automaticPushToken` (the default); a token passed here always wins, and
  /// on iOS the plugin then stops passing on the APNs token itself.
  static Future<void> setPushToken(String? token,
      {required PushProvider provider}) async {
    if (token == null || token.isEmpty) return;
    await ClikgateChannels.invoke<void>(
        'setPushToken', {'token': token, 'provider': provider.name});
  }

  /// True for Clikgate's silent uninstall-check pushes (FCM `data["cg"] == "uc"`,
  /// APNs `cg.t == "uc"`). Pure Dart, so it works in background isolates.
  /// Return early without showing a notification when it is true.
  static bool isClikgateMessage(Map<String, dynamic>? data) {
    final cg = data?['cg'];
    if (cg == 'uc') return true;
    if (cg is Map) return cg['t'] == 'uc';
    if (cg is String && cg.startsWith('{')) {
      try {
        final decoded = jsonDecode(cg);
        return decoded is Map && decoded['t'] == 'uc';
      } on FormatException {
        return false;
      }
    }
    return false;
  }

  /// Hands a URL to the SDK (e.g. from a QR scanner). Returns true for
  /// Clikgate links; the result arrives on [onDeepLink]. App Links /
  /// Universal Links that open the app are forwarded automatically.
  static Future<bool> handleUrl(String url) async =>
      await ClikgateChannels.invoke<bool>('handleUrl', {'url': url}) ?? false;

  // ---------------------------------------------------------------- consent, Firebase, sales metadata

  static final RegExp _region = RegExp(r'^(EEA|UK|[A-Z]{2})$');

  /// Sets the user's consent per purpose. Omitted purposes keep their current
  /// value (all are `unknown` until set). Where consent is required (EEA, UK,
  /// CH by default) and `attribution` is unknown, the native SDK buffers
  /// events (up to 7 days / 1,000 events) and sends nothing identifying; on
  /// grant it sends the buffer, on deny it drops it.
  static Future<void> setConsent({
    ConsentState? analytics,
    ConsentState? attribution,
    ConsentState? adUserData,
    ConsentState? adPersonalization,
  }) {
    final args = <String, Object?>{
      if (analytics != null) 'analytics': analytics.name,
      if (attribution != null) 'attribution': attribution.name,
      if (adUserData != null) 'adUserData': adUserData.name,
      if (adPersonalization != null) 'adPersonalization': adPersonalization.name,
    };
    return ClikgateChannels.invoke<void>('setConsent', args);
  }

  /// The consent set with [setConsent], the region hint and whether consent
  /// is required for this device.
  static Future<ClikgateConsent> getConsent() async =>
      ClikgateConsent.fromMap(await ClikgateChannels.invokeMap('getConsent'));

  /// Region hint for consent: `EEA`, `UK` or an ISO 3166-1 alpha-2 country
  /// (case-insensitive); null clears it. Throws
  /// `ClikgateException(invalid_argument)` for anything else.
  static Future<void> setConsentRegion(String? region) async {
    final normalized = region?.trim().toUpperCase();
    if (normalized != null && !_region.hasMatch(normalized)) {
      throw ClikgateException(ClikgateException.invalidArgument,
          'region must be EEA, UK or an ISO 3166-1 alpha-2 country code',
          param: 'region');
    }
    await ClikgateChannels.invoke<void>(
        'setConsentRegion', {'region': normalized});
  }

  /// Forwards Clikgate attribution to Firebase Analytics when the app
  /// includes it (e.g. via `firebase_analytics`; detected natively at
  /// runtime): `clikgate_attribution` once per install and the
  /// `cg_first_source` / `cg_first_campaign` user properties. Needs
  /// `analytics` consent and GA4 forwarding enabled for the app in Clikgate.
  /// Call on every launch.
  static Future<void> enableFirebaseForwarding({
    bool logAttributionEvent = true,
    bool setUserProperties = true,
  }) =>
      ClikgateChannels.invoke<void>('enableFirebaseForwarding', {
        'logAttributionEvent': logAttributionEvent,
        'setUserProperties': setUserProperties,
      });

  /// `{cg_click_id, cg_link_id}` of the click that brought this user, for
  /// Paystack `metadata` / Flutterwave `meta` so Clikgate can match the sale.
  /// Empty when there is none or consent doesn't allow attribution.
  static Future<Map<String, String>> attributionMetadata() async {
    final m = await ClikgateChannels.invokeMap('attributionMetadata');
    return {
      for (final e in m.entries)
        if (e.value is String) e.key: e.value as String,
    };
  }

  /// iOS only (no-op on Android): passes Google's on-device conversion
  /// measurement info to Clikgate with the first install when the app
  /// includes Google's `GoogleAdsOnDeviceConversion` SDK. Call before
  /// [configure] on the first launch.
  static Future<void> enableGoogleOnDeviceMeasurement() =>
      ClikgateChannels.invoke<void>('enableGoogleOnDeviceMeasurement');

  /// Version of the native SDK underneath.
  static Future<String> nativeSdkVersion() async =>
      await ClikgateChannels.invoke<String>('sdkVersion') ?? 'unknown';

  /// **Internal** (used by the Engage features, `engage.dart`; not part of the app-facing
  /// API): the request context for a `/v1/sdk/*` call on behalf of this
  /// installation, once the first install was recorded and a pending
  /// `identify` was sent. Throws `ClikgateException` (`not_configured`,
  /// `opted_out`, `install_pending`, `invalid_sdk_key`, `sdk_disabled`).
  static Future<ClikgateRequestContext> getRequestContext() async =>
      ClikgateRequestContext.fromMap(
          await ClikgateChannels.invokeMap('getRequestContext'));

  /// **Internal** (used by the Engage features, `engage.dart`): reports an error code a
  /// `/v1/sdk/*` call made with [getRequestContext] got, so the native SDK
  /// applies its rules (`feature_disabled` switches [feature] off until the
  /// next config fetch; `invalid_sdk_key`, `sdk_disabled`,
  /// `installation_unknown` apply the global error rules).
  static Future<void> reportServerError(String code, {String? feature}) =>
      ClikgateChannels.invoke<void>(
          'reportServerError', {'code': code, 'feature': feature});

  @visibleForTesting
  static Future<void> resetForTesting() async {
    await _hub.dispose();
    _hub = DeepLinkHub();
  }
}
