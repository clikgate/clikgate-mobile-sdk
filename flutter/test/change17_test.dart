import 'dart:convert';
import 'dart:io';

import 'package:clikgate_flutter/clikgate_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Change 17 (R.2): an app opened by a link skips the redirect, so `/resolve`
/// runs the link gates. The native SDKs open a password link's `web_url` in the
/// system browser (nothing reaches Dart) and deliver a blocked link as a deep
/// link with `blockMessage` and no route (shared/PLATFORM_CHANNEL.md "DeepLink").
Map<String, dynamic> fixture(String name) =>
    jsonDecode(File('../shared/fixtures/$name.json').readAsStringSync())
        as Map<String, dynamic>;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methods = MethodChannel('com.clikgate/sdk');
  const events = EventChannel('com.clikgate/deep_links');

  late MockStreamHandlerEventSink sink;

  Future<void> drain() => Future<void>.delayed(const Duration(milliseconds: 1));

  setUp(() async {
    await Clikgate.resetForTesting();
    messenger.setMockMethodCallHandler(methods, (call) async => null);
    messenger.setMockStreamHandler(
        events, MockStreamHandler.inline(onListen: (_, s) => sink = s));
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockStreamHandler(events, null);
  });

  /// The map the native plugins send for a blocked `/resolve` answer.
  Map<String, Object?> blockedEvent() => {
        'url': 'https://inv.myapp.com/offer',
        'path': null,
        'data': <String, Object?>{},
        'isDeferred': false,
        'clickId': null,
        'matchType': null,
        'link': null,
        'referral': null,
        'blockMessage': fixture('resolve_response_blocked')['block_message'],
      };

  test('a blocked link arrives with its message and no route', () async {
    await Clikgate.configure(sdkKey: 'cg_sdk_test');
    final received = <ClikgateDeepLink>[];
    final handoffs = <ClikgateBrowserHandoff>[];
    final a = Clikgate.onDeepLink.listen(received.add);
    final b = Clikgate.onBrowserHandoff.listen(handoffs.add);
    await drain();
    sink.success(blockedEvent());
    await drain();
    final d = received.single;
    expect(d.blockMessage, 'This offer is only for customers in Nigeria.');
    expect(d.url, 'https://inv.myapp.com/offer');
    expect(d.path, isNull);
    expect(d.clickId, isNull);
    expect(d.link, isNull);
    expect(d.referral, isNull);
    expect(d.data, isEmpty);
    expect(d.isDeferred, isFalse);
    expect(d.toString(), contains('blocked'));
    expect(handoffs, isEmpty);
    await a.cancel();
    await b.cancel();
  });

  test('links from older native SDKs (no blockMessage key) are not blocked', () {
    final d = ClikgateDeepLink.fromMap({'path': '/products/42', 'isDeferred': false});
    expect(d.blockMessage, isNull);
    expect(d.path, '/products/42');
  });

  test('an A/B test delivers the variant path the server chose', () async {
    final dl = fixture('resolve_response_ab_variant')['deep_link'] as Map<String, dynamic>;
    await Clikgate.configure(sdkKey: 'cg_sdk_test');
    final received = <ClikgateDeepLink>[];
    final sub = Clikgate.onDeepLink.listen(received.add);
    await drain();
    sink.success({
      'url': dl['url'],
      'path': dl['path'],
      'data': dl['data'],
      'isDeferred': false,
      'clickId': fixture('resolve_response_ab_variant')['click_id'],
      'matchType': 'app_link',
      'link': null,
      'referral': null,
      'blockMessage': null,
    });
    await drain();
    expect(received.single.path, '/menu/b');
    expect(received.single.blockMessage, isNull);
    await sub.cancel();
  });

  test('password_required: nothing reaches the app (the native SDK opens web_url)', () async {
    // The contract the native SDKs act on: a web URL to open, and no click, deep link or link.
    final f = fixture('resolve_response_password_required');
    expect(f['status'], 'password_required');
    expect(f['matched'], isFalse);
    expect(f['web_url'], isNotEmpty);
    for (final k in ['click_id', 'deep_link', 'link', 'referral']) {
      expect(f[k], isNull, reason: k);
    }
    await Clikgate.configure(sdkKey: 'cg_sdk_test');
    final received = <ClikgateDeepLink>[];
    final handoffs = <ClikgateBrowserHandoff>[];
    final a = Clikgate.onDeepLink.listen(received.add);
    final b = Clikgate.onBrowserHandoff.listen(handoffs.add);
    await drain();
    expect(received, isEmpty);
    expect(handoffs, isEmpty);
    await a.cancel();
    await b.cancel();
  });

  test('gated answers never carry a destination (deferred or direct)', () {
    for (final name in ['resolve_response_password_required', 'resolve_response_blocked']) {
      final f = fixture(name);
      expect(f['deep_link'], isNull, reason: name);
      expect(f['click_id'], isNull, reason: name);
      expect(f['link'], isNull, reason: name);
    }
  });
}
