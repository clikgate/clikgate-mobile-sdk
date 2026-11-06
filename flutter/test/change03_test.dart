import 'package:clikgate_flutter/clikgate_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Change 03 bridge methods (shared/PLATFORM_CHANNEL.md "Change 03 methods").
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

  group('setConsent', () {
    test('sends only the given purposes', () async {
      await Clikgate.setConsent(
          attribution: ConsentState.granted, adUserData: ConsentState.denied);
      expect(calls.single.method, 'setConsent');
      expect(calls.single.arguments,
          {'attribution': 'granted', 'adUserData': 'denied'});
    });

    test('all four purposes', () async {
      await Clikgate.setConsent(
          analytics: ConsentState.unknown,
          attribution: ConsentState.denied,
          adUserData: ConsentState.denied,
          adPersonalization: ConsentState.granted);
      expect(calls.single.arguments, {
        'analytics': 'unknown',
        'attribution': 'denied',
        'adUserData': 'denied',
        'adPersonalization': 'granted',
      });
    });

    test('maps a native invalid_argument error', () async {
      handlers['setConsent'] = (_) => throw PlatformException(
          code: 'invalid_argument',
          message: 'bad',
          details: {'status': null, 'param': 'analytics'});
      await expectLater(
          Clikgate.setConsent(analytics: ConsentState.granted),
          throwsA(isA<ClikgateException>()
              .having((e) => e.code, 'code', 'invalid_argument')
              .having((e) => e.param, 'param', 'analytics')));
    });
  });

  test('getConsent decodes the consent map', () async {
    handlers['getConsent'] = (_) => {
          'analytics': 'granted',
          'attribution': 'denied',
          'adUserData': 'unknown',
          'adPersonalization': 'something-new',
          'region': 'EEA',
          'required': true,
        };
    final c = await Clikgate.getConsent();
    expect(
        c,
        const ClikgateConsent(
            analytics: ConsentState.granted,
            attribution: ConsentState.denied,
            region: 'EEA',
            required: true));
    expect(c.adPersonalization, ConsentState.unknown);
  });

  test('getConsent before the SDK knows: required is null', () async {
    handlers['getConsent'] = (_) => {
          'analytics': 'unknown',
          'attribution': 'unknown',
          'adUserData': 'unknown',
          'adPersonalization': 'unknown',
          'region': null,
          'required': null,
        };
    expect((await Clikgate.getConsent()).required, isNull);
  });

  group('setConsentRegion', () {
    test('normalises and sends', () async {
      await Clikgate.setConsentRegion(' de ');
      await Clikgate.setConsentRegion('eea');
      await Clikgate.setConsentRegion(null);
      expect(calls.map((c) => c.arguments).toList(), [
        {'region': 'DE'},
        {'region': 'EEA'},
        {'region': null},
      ]);
    });

    test('rejects invalid regions without a channel call', () async {
      for (final bad in ['Europe', 'DEU', '', '1A']) {
        await expectLater(
            Clikgate.setConsentRegion(bad),
            throwsA(isA<ClikgateException>()
                .having((e) => e.code, 'code', ClikgateException.invalidArgument)
                .having((e) => e.param, 'param', 'region')));
      }
      expect(calls, isEmpty);
    });
  });

  group('enableFirebaseForwarding', () {
    test('defaults', () async {
      await Clikgate.enableFirebaseForwarding();
      expect(calls.single.method, 'enableFirebaseForwarding');
      expect(calls.single.arguments, {
        'logAttributionEvent': true,
        'setUserProperties': true,
        'mirrorEvents': false,
        'eventNameMap': <String, String>{},
      });
    });

    test('options', () async {
      await Clikgate.enableFirebaseForwarding(
          mirrorEvents: true,
          setUserProperties: false,
          eventNameMap: {'signup': 'sign_up'});
      expect(calls.single.arguments, {
        'logAttributionEvent': true,
        'setUserProperties': false,
        'mirrorEvents': true,
        'eventNameMap': {'signup': 'sign_up'},
      });
    });
  });

  group('attributionMetadata', () {
    test('returns the native map', () async {
      handlers['attributionMetadata'] = (_) => {
            'cg_click_id': 'clk_01JAB3C4D5E6F7G8H9JKMNPQRS',
            'cg_link_id': 'lnk_01JAB3C4D5E6F7G8H9JKMNPQRS',
          };
      expect(await Clikgate.attributionMetadata(), {
        'cg_click_id': 'clk_01JAB3C4D5E6F7G8H9JKMNPQRS',
        'cg_link_id': 'lnk_01JAB3C4D5E6F7G8H9JKMNPQRS',
      });
    });

    test('empty when there is none', () async {
      handlers['attributionMetadata'] = (_) => <String, Object?>{};
      expect(await Clikgate.attributionMetadata(), isEmpty);
    });
  });

  test('enableGoogleOnDeviceMeasurement calls through', () async {
    await Clikgate.enableGoogleOnDeviceMeasurement();
    expect(calls.single.method, 'enableGoogleOnDeviceMeasurement');
  });

  test('configure defaults pasteboardMode to off', () async {
    messenger.setMockStreamHandler(const EventChannel('com.clikgate/deep_links'),
        MockStreamHandler.inline(onListen: (_, __) {}));
    await Clikgate.resetForTesting();
    await Clikgate.configure(sdkKey: 'cg_sdk_test');
    final args = calls.firstWhere((c) => c.method == 'configure').arguments as Map;
    expect(args['pasteboardMode'], 'off');
    expect(args['wrapperVersion'], Clikgate.pluginVersion);
    messenger.setMockStreamHandler(const EventChannel('com.clikgate/deep_links'), null);
  });
}
