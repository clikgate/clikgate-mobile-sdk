/// A fake Clikgate for your app's widget and unit tests.
///
/// ```dart
/// import 'package:clikgate_flutter/testing.dart';
///
/// late ClikgateFake clikgate;
/// setUp(() => clikgate = ClikgateFake.install());
///
/// testWidgets('checkout counts the goal', (tester) async {
///   await tester.pumpWidget(const MyApp());
///   await tester.tap(find.text('Pay'));
///   await tester.pumpAndSettle();
///   expect(clikgate.goals.single.key, 'purchase');
/// });
/// ```
///
/// [ClikgateFake.install] answers every call of `package:clikgate_flutter/clikgate_flutter.dart`
/// and of the Engage features (`package:clikgate_flutter/engage.dart`) without a device or a
/// network: it replaces the plugin's platform channels (`com.clikgate/sdk`,
/// `com.clikgate/engage`, `com.clikgate/deep_links`) and the HTTP client Engage uses to call the
/// Clikgate API from Dart. It records every call and removes itself when the test ends.
///
/// Only import this library from tests. Your app's code never imports it, so it isn't in your
/// app's builds.
library;

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;

import 'src/clikgate.dart' show deliverDeepLinkEventForTesting, resetDeepLinkHubForTesting;
import 'src/models.dart';
import 'src/provider.dart';
import 'src/test_seams.dart';

/// A `Clikgate.goal` call seen by [ClikgateFake], with the result it answered.
class ClikgateFakeGoal {
  ClikgateFakeGoal._(
      {required this.key,
      this.value,
      this.currency,
      this.reference,
      this.provider,
      this.isFirst,
      this.label,
      required this.result});

  final String key;

  /// The value as the SDK sends it: a decimal string such as `'1500.50'`, or null.
  final String? value;
  final String? currency;
  final String? reference;

  /// Set for a Payment goal.
  final ClikgateProvider? provider;
  final bool? isFirst;
  final String? label;

  /// What `Clikgate.goal` returned.
  final GoalResult result;

  bool get isPayment => provider != null;

  @override
  String toString() =>
      'ClikgateFakeGoal($key, value: $value, provider: $provider, reference: $reference, status: ${result.status.name})';
}

/// A `Clikgate.identifyUser` call seen by [ClikgateFake].
class ClikgateFakeIdentify {
  ClikgateFakeIdentify._(
      {this.label,
      required this.customerIdPassed,
      this.customerId,
      this.identityToken});

  final String? label;

  /// False when the call left `customerId` out (the stored one is kept).
  final bool customerIdPassed;

  /// The customer ID passed; null with [customerIdPassed] true is a sign-out.
  final String? customerId;
  final String? identityToken;

  /// `identifyUser(customerId: null)`.
  bool get isSignOut => customerIdPassed && customerId == null;

  @override
  String toString() =>
      'ClikgateFakeIdentify(customerId: ${customerIdPassed ? customerId : '(kept)'}, '
      'identityToken: ${identityToken == null ? null : '(set)'}, label: $label)';
}

/// A `Clikgate.referrals.applyCode` call seen by [ClikgateFake].
class ClikgateFakeAppliedCode {
  ClikgateFakeAppliedCode._(this.programId, this.code);
  final String programId;
  final String code;

  @override
  String toString() => 'ClikgateFakeAppliedCode($programId, $code)';
}

/// An Engage share call seen by [ClikgateFake]: [method] is `shareLink` (`share.link`,
/// `share.referralLink`), `shareText` (`share.system`, or `share.whatsApp` when WhatsApp didn't
/// open) or `openUrl` (`share.whatsApp`).
class ClikgateFakeShare {
  ClikgateFakeShare._(this.method, this.arguments);
  final String method;
  final Map<String, Object?> arguments;

  /// The shared link (`shareLink`) or the opened URL (`openUrl`).
  String? get url => arguments['url'] as String?;

  /// The `message` in front of a shared link.
  String? get message => arguments['message'] as String?;

  /// The text of `share.system`.
  String? get text => arguments['text'] as String?;

  /// The app asked for (`whatsapp`, `instagram`, ...), when any.
  String? get app => arguments['app'] as String?;

  /// The referral code of `share.referralLink`.
  String? get code => arguments['code'] as String?;

  @override
  String toString() => 'ClikgateFakeShare($method, $arguments)';
}

/// A request the Engage features sent to the Clikgate API, seen by [ClikgateFake].
class ClikgateFakeRequest {
  ClikgateFakeRequest._(this.method, this.url, this.headers, this.body);
  final String method;
  final Uri url;
  final Map<String, String> headers;

  /// The decoded JSON body, when any.
  final Map<String, Object?>? body;

  String get path => url.path;

  @override
  String toString() => 'ClikgateFakeRequest($method ${url.path})';
}

/// A fake Clikgate for widget and unit tests: see [ClikgateFake.install].
///
/// Defaults: `configure` succeeds; `getInstallationId` and `getInstallationHeader` return
/// [installationId] and `Clikgate-Installation: <appId>:<installationId>`; `goal` answers
/// [goalStatus] (`counted`), and Payment goals (with a `provider`) [paymentGoalStatus]
/// (`waiting`); `isFeatureEnabled` reads [features]; `referrals.applyCode` succeeds unless
/// [applyCodeError] is set; attribution is [attribution] (organic); Engage
/// `referrals.createLink` returns a link with [referralCode]; share calls open nothing and are
/// recorded in [shares]. Change any of these on the fake at any time.
class ClikgateFake {
  ClikgateFake._({String? customerId, String? identityToken})
      : _customerId = customerId,
        _identityToken = customerId == null ? null : identityToken;

  /// Installs a fake for the current test and returns it. Call it in `setUp` or at the start of
  /// a test; it's removed when the test ends (`addTearDown`).
  ///
  /// [customerId] / [identityToken]: start as if `Clikgate.identifyUser` was already called (a
  /// signed-in user). Without them the installation isn't identified, and Engage calls that act
  /// for a user throw `ClikgateException(not_identified)` until the app calls `identifyUser`,
  /// as they do on a device.
  static ClikgateFake install({String? customerId, String? identityToken}) {
    TestWidgetsFlutterBinding.ensureInitialized();
    final fake = ClikgateFake._(customerId: customerId, identityToken: identityToken);
    fake._install();
    addTearDown(fake.uninstall);
    return fake;
  }

  static const MethodChannel _sdk = MethodChannel('com.clikgate/sdk');
  static const MethodChannel _engage = MethodChannel('com.clikgate/engage');
  static const EventChannel _deepLinks = EventChannel('com.clikgate/deep_links');

  // ------------------------------------------------------------------ configuration

  /// The Clikgate app ID in the installation header: `app_` and a 26-character ULID.
  String appId = 'app_01JD8X6Q2V3W4Y5Z6A7B8C9D0E';

  /// What `Clikgate.getInstallationId()` returns. Null acts like tracking off (the
  /// installation header is null too).
  String? installationId = '3f2b8c1e-9d4a-4b7e-8f00-1a2b3c4d5e6f';

  /// `Clikgate.isFeatureEnabled` answers; unknown keys are off. The defaults are the SDK's
  /// before its first config fetch.
  final Map<String, bool> features = {
    ClikgateFeatures.appAttribution: true,
    ClikgateFeatures.referrals: true,
    ClikgateFeatures.leaderboards: true,
    ClikgateFeatures.offlineCodes: true,
  };

  /// The status `Clikgate.goal` answers for a goal without a `provider`.
  GoalStatus goalStatus = GoalStatus.counted;

  /// The status `Clikgate.goal` answers for a Payment goal (one with a `provider`).
  GoalStatus paymentGoalStatus = GoalStatus.waiting;

  /// Overrides the goal answer: return a [GoalResult] for the goal, or null for the defaults.
  GoalResult? Function(ClikgateFakeGoal goal)? onGoal;

  /// When set, `Clikgate.referrals.applyCode` throws `ClikgateException` with this code
  /// (`code_not_found`, `already_referred`, `self_referral`, `window_expired`, ...;
  /// `existing_user` throws `ExistingUserException`).
  String? applyCodeError;

  /// The referrer's name in the [Referral] that `applyCode` returns.
  String referrerDisplayName = 'Ada';

  /// What `Clikgate.referrals.referredBy()` returns: null means not referred.
  Referral? referredBy;

  /// What `Clikgate.getAttribution()` returns.
  ClikgateAttribution attribution =
      const ClikgateAttribution(status: ClikgateAttributionStatus.organic);

  /// The code of the link Engage `referrals.createLink` returns.
  String referralCode = 'ADA-7Q2ZPX';

  /// The link domain of fake links (`https://<linkDomain>/r/<referralCode>`), and the domain
  /// `Clikgate.handleUrl` treats as a Clikgate link.
  String linkDomain = 'yourapp.dev.ciz.to';

  /// When set, Engage `referrals.createLink` and `myStats` throw `ClikgateException` with this
  /// code (`identity_required`, `program_paused`, ...).
  String? createLinkError;

  /// When set, Engage `codes.redeem` throws `ClikgateException` with this code
  /// (`code_not_found`, `code_expired`, ...).
  String? redeemError;

  /// Whether the app asked for in a share call (`share.whatsApp`, `share.link(app: ...)`)
  /// "opens"; false falls back to the share menu, as on a phone without that app.
  bool shareAppInstalled = true;

  /// Answers an Engage request yourself: return a response, or null for the fake's default.
  /// For example `(r) => r.url.path.endsWith('/referrals/me') ? http.Response('...', 200) : null`.
  http.Response? Function(http.Request request)? onEngageRequest;

  // ------------------------------------------------------------------ recorded calls

  /// Every platform-channel call, in order (`com.clikgate/sdk` and `com.clikgate/engage`).
  final List<MethodCall> calls = [];

  /// `Clikgate.goal` calls.
  final List<ClikgateFakeGoal> goals = [];

  /// `Clikgate.identifyUser` calls.
  final List<ClikgateFakeIdentify> identifyCalls = [];

  /// `Clikgate.referrals.applyCode` calls (failed ones too).
  final List<ClikgateFakeAppliedCode> appliedCodes = [];

  /// Engage share calls.
  final List<ClikgateFakeShare> shares = [];

  /// Requests the Engage features sent to the Clikgate API.
  final List<ClikgateFakeRequest> engageRequests = [];

  /// The arguments of the last `Clikgate.configure` call, or null before it.
  Map<String, Object?>? configureArguments;

  /// The calls of one channel method, such as `setPushToken` or `referrals.referredBy`.
  List<MethodCall> callsTo(String method) =>
      calls.where((c) => c.method == method).toList();

  /// Whether `Clikgate.configure` was called.
  bool get configured => configureArguments != null;

  /// The identified customer, as the native SDK would store it after the `identifyUser` calls.
  String? get customerId => _customerId;

  /// The identity token stored with [customerId].
  String? get identityToken => _identityToken;

  /// False after `Clikgate.setTrackingEnabled(false)`.
  bool get trackingEnabled => _trackingEnabled;

  /// The push token from `Clikgate.setPushToken`, or null.
  String? get pushToken => _pushToken;

  // ------------------------------------------------------------------ deep links

  /// Delivers a deep link on `Clikgate.onDeepLink`, as if the phone opened [url] (or, with
  /// [isDeferred], as the deferred deep link after install). [path] defaults to the URL's
  /// path. Pump the widget tester afterwards so listeners run.
  void pushDeepLink(String url,
      {String? path,
      Map<String, Object?> data = const {},
      bool isDeferred = false,
      String? clickId = 'clk_fake_1',
      String? matchType,
      String linkId = 'lnk_fake_1',
      String linkKind = 'standard',
      Referral? referral}) {
    final uri = Uri.parse(url);
    _emit({
      'url': url,
      'path': path ?? (uri.path.isEmpty ? '/' : uri.path),
      'data': data,
      'isDeferred': isDeferred,
      'clickId': clickId,
      'matchType': matchType ?? (isDeferred ? 'install_referrer' : 'app_link'),
      'link': {'id': linkId, 'kind': linkKind},
      if (referral != null) 'referral': _referralMap(referral),
    });
  }

  /// Delivers a browser handoff on `Clikgate.onBrowserHandoff` (another organisation's link on
  /// a shared Clikgate domain).
  void pushBrowserHandoff(String url) =>
      _emit({'event': 'browserHandoff', 'url': url, 'host': Uri.parse(url).host});

  // ------------------------------------------------------------------ install / uninstall

  String? _customerId;
  String? _identityToken;
  bool _trackingEnabled = true;
  String? _pushToken;
  final Map<String, String> _consent = {};
  String? _consentRegion;
  bool _installed = false;

  TestDefaultBinaryMessenger get _messenger =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void _install() {
    resetDeepLinkHubForTesting();
    _messenger.setMockMethodCallHandler(_sdk, _onSdk);
    _messenger.setMockMethodCallHandler(_engage, _onEngage);
    _messenger.setMockStreamHandler(
        _deepLinks,
        // The SDK listens to the channel; events are delivered straight to it (_emit).
        MockStreamHandler.inline(onListen: (_, __) {}));
    engageHttpClientOverride = () => http_testing.MockClient(_onHttp);
    _installed = true;
  }

  /// Removes the fake (done for you when the test ends).
  void uninstall() {
    if (!_installed) return;
    _installed = false;
    _messenger.setMockMethodCallHandler(_sdk, null);
    _messenger.setMockMethodCallHandler(_engage, null);
    _messenger.setMockStreamHandler(_deepLinks, null);
    engageHttpClientOverride = null;
    resetDeepLinkHubForTesting();
  }

  // Straight to the SDK's deep link hub, not through the event channel: a platform message reaches
  // Dart outside the widget tester's fake async, so `pumpAndSettle` alone wouldn't deliver it. Like
  // the native buffer, the hub keeps events that arrive before anyone listens and replays them.
  void _emit(Map<String, Object?> event) {
    if (_installed) deliverDeepLinkEventForTesting(event);
  }

  // ------------------------------------------------------------------ com.clikgate/sdk

  Map<String, Object?> _args(MethodCall call) => call.arguments is Map
      ? (call.arguments as Map).map((k, v) => MapEntry(k.toString(), v))
      : <String, Object?>{};

  bool get _hasInstallation => _trackingEnabled && installationId != null;

  Future<Object?> _onSdk(MethodCall call) async {
    calls.add(call);
    final a = _args(call);
    switch (call.method) {
      case 'configure':
        configureArguments = a;
        return null;
      case 'getInstallationId':
        return _hasInstallation ? installationId : null;
      case 'getInstallationHeader':
        return _hasInstallation
            ? {'name': ClikgateInstallationHeader.headerName, 'value': '$appId:$installationId'}
            : null;
      case 'identifyUser':
        final passed = a.containsKey('customerId');
        final token = a['identityToken'] as String?;
        identifyCalls.add(ClikgateFakeIdentify._(
            label: a['label'] as String?,
            customerIdPassed: passed,
            customerId: a['customerId'] as String?,
            identityToken: token));
        if (passed || token != null) {
          if (passed) _customerId = a['customerId'] as String?;
          _identityToken = _customerId == null ? null : token;
        }
        return null;
      case 'goal':
        return _goal(a);
      case 'isFeatureEnabled':
        return features[a['key']] ?? false;
      case 'referrals.applyCode':
        final programId = a['programId'] as String? ?? '';
        final code = a['code'] as String? ?? '';
        appliedCodes.add(ClikgateFakeAppliedCode._(programId, code));
        final error = applyCodeError;
        if (error != null) {
          throw PlatformException(
              code: error,
              message: 'Fake applyCode error: $error',
              details: {'status': _statusFor(error)});
        }
        return {
          'referralId': 'ref_fake_1',
          'programId': programId,
          'status': 'installed',
          'source': 'code_entry',
          'referrerId': 'rfr_fake_1',
          'referrerDisplayName': referrerDisplayName,
        };
      case 'referrals.referredBy':
        final r = referredBy;
        return {'referred': r != null, 'referral': r == null ? null : _referralMap(r)};
      case 'getAttribution':
        return _attributionMap(attribution);
      case 'attributionMetadata':
        final a = attribution;
        return {
          if (a.clickId != null) 'cg_click_id': a.clickId,
          if (a.link != null) 'cg_link_id': a.link!.id,
        };
      case 'setTrackingEnabled':
        _trackingEnabled = a['enabled'] == true;
        return null;
      case 'setPushToken':
        _pushToken = a['token'] as String?;
        return null;
      case 'handleUrl':
        final url = a['url'] as String? ?? '';
        final host = Uri.tryParse(url)?.host ?? '';
        final linkDomains = (configureArguments?['linkDomains'] as List?)?.cast<String>() ?? const [];
        final isClikgate = host == linkDomain || linkDomains.contains(host);
        if (isClikgate) pushDeepLink(url, matchType: 'app_link');
        return isClikgate;
      case 'setConsent':
        for (final e in a.entries) {
          if (e.value is String) _consent[e.key] = e.value as String;
        }
        return null;
      case 'getConsent':
        return {..._consent, 'region': _consentRegion, 'required': false};
      case 'setConsentRegion':
        _consentRegion = a['region'] as String?;
        return null;
      case 'getRequestContext':
        if (!_hasInstallation) {
          throw PlatformException(code: 'opted_out', message: 'Tracking is off');
        }
        return {
          'installationId': installationId,
          'sdkKey': configureArguments?['sdkKey'] ?? 'cg_sdk_test_fake',
          'environment': configureArguments?['environment'] ?? 'production',
          'apiBaseUrl': configureArguments?['apiBaseUrl'] ?? 'https://sdk.clikgate.com',
          'identityToken': _identityToken,
          'customerUserId': _customerId,
          'sdkVersion': 'flutter/${configureArguments?['wrapperVersion'] ?? 'fake'}',
          'nativeSdkVersion': 'fake/1.0.0',
        };
      case 'sdkVersion':
        return 'fake/1.0.0';
      default: // enableFirebaseForwarding, enableGoogleOnDeviceMeasurement, reportServerError, ...
        return null;
    }
  }

  Map<String, Object?> _goal(Map<String, Object?> a) {
    final provider = a['provider'] is String
        ? ClikgateProvider.fromString(a['provider'] as String)
        : null;
    final value = a['value'] as String?;
    GoalResult defaults() {
      final status = provider != null ? paymentGoalStatus : goalStatus;
      return GoalResult(
        status: status,
        reason: switch (status) {
          GoalStatus.counted => null,
          GoalStatus.waiting =>
            provider != null ? 'waiting_for_confirmation' : 'unattributed',
          GoalStatus.received => 'not_counted_yet',
          GoalStatus.refused => 'unknown_goal',
        },
        goalKind: provider != null ? GoalKind.payment : GoalKind.standard,
        valueIgnored: provider != null && value != null,
      );
    }

    final probe = ClikgateFakeGoal._(
        key: a['key'] as String? ?? '',
        value: value,
        currency: a['currency'] as String?,
        reference: a['reference'] as String?,
        provider: provider,
        isFirst: a['isFirst'] as bool?,
        label: a['label'] as String?,
        result: defaults());
    final result = onGoal?.call(probe) ?? probe.result;
    goals.add(ClikgateFakeGoal._(
        key: probe.key,
        value: probe.value,
        currency: probe.currency,
        reference: probe.reference,
        provider: probe.provider,
        isFirst: probe.isFirst,
        label: probe.label,
        result: result));
    return {
      'status': result.status.name,
      'reason': result.reason,
      'goalKind': result.goalKind?.name,
      'valueIgnored': result.valueIgnored,
    };
  }

  // ------------------------------------------------------------------ com.clikgate/engage

  Future<Object?> _onEngage(MethodCall call) async {
    calls.add(call);
    final a = _args(call);
    switch (call.method) {
      case 'shareLink':
        shares.add(ClikgateFakeShare._(call.method, a));
        return a['app'] != null && shareAppInstalled;
      case 'shareText':
        shares.add(ClikgateFakeShare._(call.method, a));
        return null;
      case 'openUrl':
        shares.add(ClikgateFakeShare._(call.method, a));
        return shareAppInstalled;
      default: // savedLink (nothing saved), saveLink
        return null;
    }
  }

  // ------------------------------------------------------------------ Engage HTTP

  Future<http.Response> _onHttp(http.Request request) async {
    Map<String, Object?>? body;
    if (request.body.isNotEmpty) {
      final decoded = jsonDecode(request.body);
      if (decoded is Map) body = decoded.map((k, v) => MapEntry(k.toString(), v));
    }
    engageRequests.add(ClikgateFakeRequest._(
        request.method, request.url, Map.unmodifiable(request.headers), body));
    final custom = onEngageRequest?.call(request);
    if (custom != null) return custom;

    final path = request.url.path;
    final q = request.url.queryParameters;
    final programId = body?['program_id'] as String? ?? q['program_id'] ?? 'rpg_fake';
    final link = 'https://$linkDomain/r/$referralCode';

    if (path == '/v1/sdk/referrals/link' || path == '/v1/sdk/referrals/me') {
      final error = createLinkError;
      if (error != null) return _error(error);
      final common = {
        'referrer_id': 'rfr_fake_1',
        'program_id': programId,
        'code': referralCode,
        'url': link,
        'short_url': link,
      };
      if (path.endsWith('/link')) return _json(common);
      return _json({
        ...common,
        'status': 'active',
        'stats': {'clicks': 0, 'installs': 0, 'signups': 0, 'in_progress': 0, 'qualified': 0, 'disqualified': 0, 'rejected': 0},
      });
    }
    if (path == '/v1/sdk/codes/redeem') {
      final error = redeemError;
      if (error != null) return _error(error);
      final code = (body?['code'] as String? ?? '').toUpperCase().replaceAll(RegExp(r'[\s-]'), '');
      return _json({'offline_touch_id': 'oft_fake_1', 'code': {'code': code, 'kind': 'link'}});
    }
    if (path == '/v1/sdk/leaderboards/opt-out') {
      return _json({'program_id': programId, 'opted_out': body?['opt_out'] == true});
    }
    final board = RegExp(r'^/v1/sdk/leaderboards/([^/]+)(/me|/around-me)?$').firstMatch(path);
    if (board != null) {
      final id = Uri.decodeComponent(board.group(1)!);
      final period = {'key': 'current', 'status': 'open'};
      if (board.group(2) == '/me') {
        return _json({
          'leaderboard_id': id,
          'period': period,
          'referrer_id': 'rfr_fake_1',
          'rank': 2,
          'score': 7,
          'gap_to_next': 3,
          if (q['embed'] == '1') 'embed_url': 'https://$linkDomain/leaderboards/$id?token=fake',
        });
      }
      final me = board.group(2) == '/around-me';
      return _json({
        'leaderboard_id': id,
        if (!me) 'name': 'Top referrers',
        if (!me) 'metric': 'qualified',
        'period': period,
        'entries': [
          {'rank': 1, 'referrer_id': 'rfr_fake_0', 'display': 'Tunde', 'score': 10},
          {'rank': 2, 'referrer_id': 'rfr_fake_1', 'display': 'Ada', 'score': 7, 'is_me': true},
          {'rank': 3, 'referrer_id': 'rfr_fake_2', 'display': 'Chidi', 'score': 4},
        ],
      });
    }
    return _error('not_found', status: 404);
  }

  static http.Response _json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body), status,
      headers: {'content-type': 'application/json; charset=utf-8'});

  static http.Response _error(String code, {int? status}) => _json({
        'error': {'code': code, 'message': 'Fake error: $code'}
      }, status ?? _statusFor(code));

  static int _statusFor(String code) => switch (code) {
        'code_not_found' || 'referrer_not_found' || 'leaderboard_not_found' || 'not_found' => 404,
        'identity_required' || 'self_referral' => 403,
        'already_referred' || 'existing_user' => 409,
        'rate_limited' => 429,
        _ => 422,
      };

  static Map<String, Object?> _referralMap(Referral r) => {
        'referralId': r.referralId,
        'programId': r.programId,
        'status': r.status,
        'source': r.source,
        'referrerId': r.referrerId,
        'referrerDisplayName': r.referrerDisplayName,
        'createdAt': r.createdAt?.toIso8601String(),
      };

  static Map<String, Object?> _attributionMap(ClikgateAttribution a) => {
        'status': a.status.name,
        'matchType': a.matchType,
        'confidence': a.confidence,
        'clickId': a.clickId,
        'clickedAt': a.clickedAt?.toIso8601String(),
        'isReinstall': a.isReinstall,
        'installId': a.installId,
        'isExistingUser': a.isExistingUser,
        'link': a.link == null
            ? null
            : {
                'id': a.link!.id,
                'kind': a.link!.kind,
                'externalReference': a.link!.externalReference,
                'campaignId': a.link!.campaignId,
                'metadata': a.link!.metadata,
              },
      };
}
