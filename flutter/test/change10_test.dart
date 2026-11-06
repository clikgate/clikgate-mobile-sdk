import 'dart:convert';
import 'dart:io';

import 'package:clikgate_flutter/clikgate_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Change 10 (D.5): deep-link-only mode (Free, Starter, or an app with
/// attribution switched off). The native SDKs warn once ("needs Growth") and
/// answer goal / track with success, so the Dart calls complete without an
/// error; the install result has organic attribution and, at the deferred deep
/// link cap, no deep link.
Map<String, dynamic> fixture(String name) =>
    jsonDecode(File('../shared/fixtures/$name.json').readAsStringSync())
        as Map<String, dynamic>;

Object? camel(Object? v) {
  const verbatim = {'data', 'metadata', 'properties'};
  if (v is Map) {
    return v.map((k, value) => MapEntry(
        (k as String).replaceAllMapped(
            RegExp(r'_([a-z])'), (m) => m.group(1)!.toUpperCase()),
        verbatim.contains(k) ? value : camel(value)));
  }
  return v;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methods = MethodChannel('com.clikgate/sdk');

  late List<MethodCall> calls;
  late Map<String, Object? Function(MethodCall)> handlers;

  setUp(() async {
    await Clikgate.resetForTesting();
    calls = [];
    handlers = {};
    final features = (fixture('config_response_deep_link_only')['features']
        as Map<String, dynamic>);
    handlers['isFeatureEnabled'] =
        (call) => features[(call.arguments as Map)['key']] == true;
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      final h = handlers[call.method];
      return h == null ? null : h(call);
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(methods, null));

  test('the config fixture has deep linking on and attribution off', () async {
    expect(await Clikgate.isFeatureEnabled(ClikgateFeatures.appAttribution),
        isFalse);
    expect(await Clikgate.isFeatureEnabled('deep_linking'), isTrue);
  });

  test('goal and track complete without an error', () async {
    await expectLater(
        Clikgate.goal('account_opened', reference: 'APP-1'), completes);
    await expectLater(
        Clikgate.track('purchase', revenue: ClikgateMoney.ofMinor(1500, 'NGN')),
        completes);
    expect(calls.map((c) => c.method), containsAll(['goal', 'track']));
  });

  test('install attribution is organic, with or without a deferred link',
      () async {
    for (final name in [
      'install_response_deep_link_only',
      'install_response_deferred_cap'
    ]) {
      final response = fixture(name);
      handlers['getAttribution'] = (_) => {
            ...(camel(response['attribution']) as Map),
            'installId': response['install_id'],
          };
      final a = await Clikgate.getAttribution();
      expect(a.status, ClikgateAttributionStatus.organic, reason: name);
      expect(a.isAttributed, isFalse);
      expect(a.link, isNull);
    }
  });

  test('the feature_disabled bodies of /events and /goals name app_attribution',
      () {
    for (final name in [
      'events_response_feature_disabled',
      'goals_response_feature_disabled'
    ]) {
      expect(fixture(name), {
        'accepted': false,
        'reason': 'feature_disabled',
        'feature': 'app_attribution'
      });
    }
  });
}
