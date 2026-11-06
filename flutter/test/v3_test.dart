import 'dart:convert';
import 'dart:io';

import 'package:clikgate_flutter/clikgate_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Loads a shared contract fixture (../shared/fixtures, relative to flutter/).
Map<String, dynamic> fixture(String name) =>
    jsonDecode(File('../shared/fixtures/$name.json').readAsStringSync())
        as Map<String, dynamic>;

/// snake_case API JSON -> camelCase bridge map (what the native plugins send).
Object? camel(Object? v) {
  if (v is Map) {
    return v.map((k, value) => MapEntry(
        (k as String).replaceAllMapped(
            RegExp(r'_([a-z])'), (m) => m.group(1)!.toUpperCase()),
        camel(value)));
  }
  if (v is List) return v.map(camel).toList();
  return v;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methods = MethodChannel('com.clikgate/sdk');

  late List<MethodCall> calls;
  late Map<String, Object? Function(MethodCall)> handlers;

  setUp(() {
    calls = [];
    handlers = {};
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      final h = handlers[call.method];
      return h == null ? null : h(call);
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(methods, null));

  Never featureDisabled(String feature) => throw PlatformException(
      code: 'feature_disabled',
      message: "The '$feature' feature is switched off for this app",
      details: {'status': null, 'param': null, 'feature': feature});

  group('isFeatureEnabled', () {
    test('asks the native SDK', () async {
      handlers['isFeatureEnabled'] =
          (c) => (c.arguments as Map)['key'] == ClikgateFeatures.leaderboards;
      expect(await Clikgate.isFeatureEnabled('leaderboards'), isTrue);
      expect(await Clikgate.isFeatureEnabled(ClikgateFeatures.identityChecks),
          isFalse);
      expect(calls.map((c) => c.arguments), [
        {'key': 'leaderboards'},
        {'key': 'identity_checks'},
      ]);
    });

    test('null from the platform reads as off', () async {
      expect(await Clikgate.isFeatureEnabled('x'), isFalse);
    });
  });

  test('feature_disabled from applyCode maps to ClikgateException', () async {
    handlers['referrals.applyCode'] = (_) => featureDisabled('referrals');
    await expectLater(
      Clikgate.referrals.applyCode(programId: 'rpg_1', code: 'ADA42'),
      throwsA(isA<ClikgateException>()
          .having((e) => e.code, 'code', ClikgateException.featureDisabled)
          .having((e) => e.feature, 'feature', 'referrals')),
    );
  });

  group('Engage support (internal)', () {
    test('getRequestContext parses the bridge map', () async {
      handlers['getRequestContext'] = (_) => {
            'installationId': '6a1f0c2e-1111-4222-8333-444455556666',
            'sdkKey': 'cg_sdk_test_abc',
            'environment': 'sandbox',
            'apiBaseUrl': 'http://10.0.2.2:8000',
            'identityToken': 'sig.1760954400',
            'customerUserId': 'user_42',
            'sdkVersion': 'flutter/1.0.0',
            'nativeSdkVersion': 'android/1.0.0',
          };
      final c = await Clikgate.getRequestContext();
      expect(calls.single.method, 'getRequestContext');
      expect(c.installationId, '6a1f0c2e-1111-4222-8333-444455556666');
      expect(c.environment, 'sandbox');
      expect(c.apiBaseUrl, 'http://10.0.2.2:8000');
      expect(c.customerUserId, 'user_42');
      expect(c.headers, {
        'Clikgate-SDK-Key': 'cg_sdk_test_abc',
        'Clikgate-SDK-Version': 'flutter/1.0.0',
        'Clikgate-SDK-Native-Version': 'android/1.0.0',
        'Clikgate-Installation-Id': '6a1f0c2e-1111-4222-8333-444455556666',
        'Clikgate-Identity-Token': 'sig.1760954400',
      });
    });

    test('getRequestContext without identity has no token header', () async {
      handlers['getRequestContext'] = (_) => {
            'installationId': 'i',
            'sdkKey': 'k',
            'environment': 'production',
            'apiBaseUrl': 'https://sdk.clikgate.com',
            'identityToken': null,
            'customerUserId': null,
            'sdkVersion': 'flutter/1.0.0',
            'nativeSdkVersion': null,
          };
      final c = await Clikgate.getRequestContext();
      expect(c.customerUserId, isNull);
      expect(c.headers.keys, ['Clikgate-SDK-Key', 'Clikgate-SDK-Version', 'Clikgate-Installation-Id']);
    });

    test('getRequestContext errors are typed', () async {
      handlers['getRequestContext'] = (_) =>
          throw PlatformException(code: 'install_pending', message: 'later');
      await expectLater(
          Clikgate.getRequestContext(),
          throwsA(isA<ClikgateException>()
              .having((e) => e.code, 'code', ClikgateException.installPending)));
    });

    test('reportServerError sends code and feature', () async {
      await Clikgate.reportServerError('feature_disabled', feature: 'leaderboards');
      await Clikgate.reportServerError('sdk_disabled');
      expect(calls.map((c) => [c.method, c.arguments]), [
        ['reportServerError', {'code': 'feature_disabled', 'feature': 'leaderboards'}],
        ['reportServerError', {'code': 'sdk_disabled', 'feature': null}],
      ]);
    });
  });

  test('ClikgateException.toString includes the feature', () {
    expect(
        const ClikgateException('feature_disabled', 'off',
                feature: 'leaderboards')
            .toString(),
        contains('feature: leaderboards'));
  });
}
