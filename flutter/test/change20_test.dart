import 'dart:convert';
import 'dart:io';

import 'package:clikgate_flutter/clikgate_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Change 20 (S.1, R.40): the native SDKs send `deeplink_handled` (the handled
/// path, IDs replaced with `:id`) in test mode or while the debug view is open.
/// The Dart layer only passes the key and the links through: it never cleans
/// the app's link, never adds a call of its own, and nothing is tracked as an
/// event.
dynamic fixture(String name) =>
    jsonDecode(File('../shared/fixtures/$name.json').readAsStringSync());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methods = MethodChannel('com.clikgate/sdk');
  const events = EventChannel('com.clikgate/deep_links');

  late List<MethodCall> calls;
  late MockStreamHandlerEventSink sink;

  Future<void> drain() => Future<void>.delayed(const Duration(milliseconds: 1));

  setUp(() async {
    await Clikgate.resetForTesting();
    calls = [];
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      return call.method == 'handleUrl' ? true : null;
    });
    messenger.setMockStreamHandler(
        events, MockStreamHandler.inline(onListen: (_, s) => sink = s));
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockStreamHandler(events, null);
  });

  test('the test key reaches the native SDK unchanged (test mode is its prefix)',
      () async {
    await Clikgate.configure(sdkKey: 'cg_sdk_test_4f1c9a');
    final configure = calls.singleWhere((c) => c.method == 'configure');
    expect((configure.arguments as Map)['sdkKey'], 'cg_sdk_test_4f1c9a');
  });

  test('the app still gets the full path and query; only the report is cleaned',
      () async {
    await Clikgate.configure(sdkKey: 'cg_sdk_test_4f1c9a');
    final received = <ClikgateDeepLink>[];
    final sub = Clikgate.onDeepLink.listen(received.add);
    await drain();
    const path = '/u/ada%40example.com/orders/42?coupon=SAVE10';
    sink.success({
      'url': 'https://inv.myapp.com/p/dress',
      'path': path,
      'data': {'coupon': 'SAVE10'},
      'isDeferred': false,
      'clickId': 'clk_01JAB3C4D5E6F7G8H9JKMNPQRS',
      'matchType': 'app_link',
      'link': null,
      'referral': null,
    });
    await drain();
    expect(received.map((l) => l.path), [path]);
    await sub.cancel();
  });

  test('adds no channel call and tracks nothing for a handled link', () async {
    await Clikgate.configure(sdkKey: 'cg_sdk_test_4f1c9a');
    expect(await Clikgate.handleUrl('https://inv.myapp.com/products/42?ref=x'),
        isTrue);
    await drain();
    expect(calls.map((c) => c.method), ['configure', 'handleUrl']);
  });

  test('the shared contract: the body is the cleaned path and is_deferred only',
      () {
    for (final name in [
      'deeplink_handled_request',
      'deeplink_handled_request_deferred'
    ]) {
      final body = fixture(name) as Map<String, dynamic>;
      expect(body.keys.toSet(), {'path', 'is_deferred'});
      expect(body['path'], '/products/:id');
    }
    final cases = (fixture('deeplink_path_cases') as Map)['cases'] as List;
    expect(cases.length, greaterThan(20));
    for (final c in cases.cast<Map>()) {
      expect(c['expected'] as String, isNot(matches(RegExp(r'[?#@]'))));
      expect(c['expected'] as String, isNot(matches(RegExp(r'\d{6,}'))));
    }
  });

  test('the debug view flag is optional on /resolve and /install answers', () {
    expect((fixture('resolve_response_matched') as Map)['debug_view'], isNull);
    expect((fixture('resolve_response_debug_view') as Map)['debug_view'], isTrue);
    expect((fixture('install_response_debug_view') as Map)['debug_view'], isTrue);
  });
}
