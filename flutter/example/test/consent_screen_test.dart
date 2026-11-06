import 'package:clikgate_flutter_example/src/consent.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('consent buttons call the SDK and the screen shows consent and metadata', (tester) async {
    final calls = <MethodCall>[];
    var consent = <String, Object?>{
      'analytics': 'unknown', 'attribution': 'unknown', 'adUserData': 'unknown', 'adPersonalization': 'unknown',
      'region': null, 'required': null,
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('com.clikgate/sdk'), (call) async {
      calls.add(call);
      switch (call.method) {
        case 'getConsent':
          return consent;
        case 'attributionMetadata':
          return {'cg_click_id': 'clk_1', 'cg_link_id': 'lnk_1'};
        case 'setConsent':
          final a = call.arguments as Map;
          consent = {...consent, for (final e in a.entries) e.key as String: e.value};
          return null;
        case 'setConsentRegion':
          consent = {...consent, 'region': (call.arguments as Map)['region'], 'required': true};
          return null;
      }
      return null;
    });
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: ConsentScreen()));
    await tester.pumpAndSettle();
    expect(find.textContaining('cg_click_id: clk_1'), findsOneWidget);
    expect(find.textContaining('required: unknown'), findsOneWidget);

    await tester.tap(find.byKey(const Key('consent-accept')));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.method == 'setConsent').single.arguments,
        {'analytics': 'granted', 'attribution': 'granted', 'adUserData': 'granted', 'adPersonalization': 'granted'});
    expect(find.textContaining('analytics granted, attribution granted'), findsOneWidget);

    await tester.tap(find.byKey(const Key('consent-eea')));
    await tester.pumpAndSettle();
    expect(find.textContaining('region: EEA'), findsOneWidget);
    expect(find.textContaining('required: true'), findsOneWidget);

    await tester.tap(find.byKey(const Key('consent-necessary')));
    await tester.pumpAndSettle();
    expect(find.textContaining('attribution denied'), findsOneWidget);
  });
}
