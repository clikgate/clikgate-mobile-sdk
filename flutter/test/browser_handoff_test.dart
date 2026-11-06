import 'package:clikgate_flutter/clikgate_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Change 06 (1.4.0): shared-domain links of other organisations are opened in an in-app browser
/// by the native SDKs and reported as tagged events on the deep-link channel
/// (shared/PLATFORM_CHANNEL.md "Browser handoff").
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
      return null;
    });
    messenger.setMockStreamHandler(
        events, MockStreamHandler.inline(onListen: (_, s) => sink = s));
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockStreamHandler(events, null);
  });

  Map<String, Object?> handoff(String url, String host) =>
      {'event': 'browserHandoff', 'url': url, 'host': host};

  Map<String, Object?> directLink() => {
        'url': 'https://clk.ng/mine',
        'path': '/products/42',
        'data': {'product_id': '42'},
        'isDeferred': false,
        'clickId': 'clk_01JAB3C4D5E6F7G8H9JKMNPQRS',
        'matchType': 'app_link',
        'link': null,
        'referral': null,
      };

  test('configure sends platformDomainBrowserFallback (default true)', () async {
    await Clikgate.configure(sdkKey: 'cg_sdk_test');
    expect((calls.single.arguments as Map)['platformDomainBrowserFallback'], isTrue);
    await Clikgate.resetForTesting();
    calls.clear();
    await Clikgate.configure(sdkKey: 'cg_sdk_test', platformDomainBrowserFallback: false);
    expect((calls.single.arguments as Map)['platformDomainBrowserFallback'], isFalse);
  });

  test('a shared-domain handoff goes to onBrowserHandoff, never onDeepLink', () async {
    await Clikgate.configure(sdkKey: 'cg_sdk_test');
    final links = <ClikgateDeepLink>[];
    final handoffs = <ClikgateBrowserHandoff>[];
    final a = Clikgate.onDeepLink.listen(links.add);
    final b = Clikgate.onBrowserHandoff.listen(handoffs.add);
    await drain();
    sink.success(handoff('https://ciz.to/other-org', 'ciz.to'));
    await drain();
    expect(handoffs, hasLength(1));
    expect(handoffs.single.url, 'https://ciz.to/other-org');
    expect(handoffs.single.host, 'ciz.to');
    expect(links, isEmpty);
    await a.cancel();
    await b.cancel();
  });

  test('matched links (shared or custom domain) still arrive on onDeepLink only', () async {
    await Clikgate.configure(sdkKey: 'cg_sdk_test');
    final links = <ClikgateDeepLink>[];
    final handoffs = <ClikgateBrowserHandoff>[];
    final a = Clikgate.onDeepLink.listen(links.add);
    final b = Clikgate.onBrowserHandoff.listen(handoffs.add);
    await drain();
    sink.success(directLink());
    await drain();
    expect(links.single.path, '/products/42');
    expect(handoffs, isEmpty);
    await a.cancel();
    await b.cancel();
  });

  test('handoffs before anyone listens are replayed to the first subscriber', () async {
    await Clikgate.configure(sdkKey: 'cg_sdk_test');
    await drain();
    sink.success(handoff('https://clk.ng/x', 'clk.ng'));
    sink.success(directLink());
    await drain();
    final handoffs = <ClikgateBrowserHandoff>[];
    final links = <ClikgateDeepLink>[];
    final a = Clikgate.onBrowserHandoff.listen(handoffs.add);
    final b = Clikgate.onDeepLink.listen(links.add);
    await drain();
    expect(handoffs.single.host, 'clk.ng');
    expect(links, hasLength(1));
    await a.cancel();
    await b.cancel();
  });
}
