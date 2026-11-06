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
/// App-defined maps (`data`, `metadata`, `properties`) are passed verbatim.
Object? camel(Object? v) {
  const verbatim = {'data', 'metadata', 'properties'};
  if (v is Map) {
    return v.map((k, value) => MapEntry(
        (k as String).replaceAllMapped(
            RegExp(r'_([a-z])'), (m) => m.group(1)!.toUpperCase()),
        verbatim.contains(k) ? value : camel(value)));
  }
  if (v is List) return v.map(camel).toList();
  return v;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methods = MethodChannel('com.clikgate/sdk');
  const events = EventChannel('com.clikgate/deep_links');

  late List<MethodCall> calls;
  late Map<String, Object? Function(MethodCall)> handlers;

  setUp(() async {
    await Clikgate.resetForTesting();
    calls = [];
    handlers = {};
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      final h = handlers[call.method];
      return h == null ? null : h(call);
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockStreamHandler(events, null);
  });

  group('configure', () {
    test('sends the bridge contract arguments', () async {
      messenger.setMockStreamHandler(
          events, MockStreamHandler.inline(onListen: (_, __) {}));
      await Clikgate.configure(
        sdkKey: 'cg_sdk_test',
        linkDomains: ['inv.myapp.com'],
        apiBaseUrl: 'http://10.0.2.2:8000',
        logLevel: ClikgateLogLevel.debug,
        environment: ClikgateEnvironment.sandbox,
        attestation: ClikgateAttestation.ifAvailable,
        pasteboardMode: ClikgatePasteboardMode.pasteControlOnly,
        waitForATT: true,
        deferredDeepLinkTimeout: const Duration(seconds: 3),
      );
      expect(calls.single.method, 'configure');
      expect(calls.single.arguments, {
        'sdkKey': 'cg_sdk_test',
        'linkDomains': ['inv.myapp.com'],
        'apiBaseUrl': 'http://10.0.2.2:8000',
        'logLevel': 'debug',
        'environment': 'sandbox',
        'attestation': 'ifAvailable',
        'pasteboardMode': 'pasteControlOnly',
        'waitForATT': true,
        'deferredDeepLinkTimeoutMs': 3000,
        'platformDomainBrowserFallback': true,
        'wrapperVersion': Clikgate.pluginVersion,
      });
    });

    test('defaults', () async {
      messenger.setMockStreamHandler(
          events, MockStreamHandler.inline(onListen: (_, __) {}));
      await Clikgate.configure(sdkKey: 'cg_sdk_test');
      final args = calls.single.arguments as Map;
      expect(args['logLevel'], 'warn');
      expect(args['environment'], 'production');
      expect(args['attestation'], 'off');
      expect(args['pasteboardMode'], 'off'); // opt-in since 1.2.0
      expect(args['deferredDeepLinkTimeoutMs'], 5000);
      expect(args['apiBaseUrl'], isNull);
      expect(args['linkDomains'], isEmpty);
    });

    test('forwards every alias link domain unchanged (native merges server link_domains)', () async {
      messenger.setMockStreamHandler(
          events, MockStreamHandler.inline(onListen: (_, __) {}));
      await Clikgate.configure(
          sdkKey: 'cg_sdk_test', linkDomains: ['ybr.ng', 'Go.YourBrand.com']);
      final args = calls.single.arguments as Map;
      expect(args['linkDomains'], ['ybr.ng', 'Go.YourBrand.com']);
    });
  });

  group('events and identity', () {
    test('track with revenue and properties', () async {
      await Clikgate.track('purchase',
          revenue: const ClikgateMoney.ofMinor(1500000, 'NGN'),
          properties: {'order_id': 'A-1001'});
      expect(calls.single.method, 'track');
      expect(calls.single.arguments, {
        'name': 'purchase',
        'revenueMinor': 1500000,
        'currency': 'NGN',
        'properties': {'order_id': 'A-1001'},
      });
    });

    test('track without revenue', () async {
      await Clikgate.track('signup');
      expect(calls.single.arguments,
          {'name': 'signup', 'revenueMinor': null, 'currency': null, 'properties': null});
    });

    test('invalid event is reported as ClikgateException', () async {
      handlers['track'] = (_) => throw PlatformException(
          code: 'invalid_argument',
          message: 'Event name must match',
          details: {'status': null, 'param': 'name'});
      await expectLater(
        Clikgate.track('bad name'),
        throwsA(isA<ClikgateException>()
            .having((e) => e.code, 'code', 'invalid_argument')
            .having((e) => e.param, 'param', 'name')
            .having((e) => e.status, 'status', isNull)),
      );
    });

    test('identifyUser, clear, label only, opt-out', () async {
      await Clikgate.identifyUser(customerId: 'user_42', identityToken: 'sig.1760954400');
      await Clikgate.identifyUser(customerId: null);
      await Clikgate.identifyUser(label: 'Ada (VIP)');
      await Clikgate.setTrackingEnabled(false);
      expect(calls.map((c) => c.method),
          ['identifyUser', 'identifyUser', 'identifyUser', 'setTrackingEnabled']);
      expect(calls[0].arguments,
          {'label': null, 'customerId': 'user_42', 'identityToken': 'sig.1760954400'});
      expect(calls[1].arguments, {'label': null, 'customerId': null, 'identityToken': null});
      expect(calls[2].arguments, {'label': 'Ada (VIP)', 'identityToken': null});
      expect(calls[3].arguments, {'enabled': false});
    });

    test('setPushToken sends provider name and ignores null tokens', () async {
      await Clikgate.setPushToken(null, provider: PushProvider.fcm);
      await Clikgate.setPushToken('', provider: PushProvider.fcm);
      expect(calls, isEmpty);
      await Clikgate.setPushToken('fcm-token-123', provider: PushProvider.fcm);
      await Clikgate.setPushToken('a1b2c3d4', provider: PushProvider.apns);
      expect(calls[0].arguments, {'token': 'fcm-token-123', 'provider': 'fcm'});
      expect(calls[1].arguments, {'token': 'a1b2c3d4', 'provider': 'apns'});
    });

    test('handleUrl and sdkVersion', () async {
      handlers['handleUrl'] = (c) =>
          (c.arguments as Map)['url'].toString().contains('inv.myapp.com');
      handlers['sdkVersion'] = (_) => '1.0.0';
      expect(await Clikgate.handleUrl('https://inv.myapp.com/p/1'), isTrue);
      expect(await Clikgate.handleUrl('https://example.com'), isFalse);
      expect(await Clikgate.nativeSdkVersion(), '1.0.0');
    });

    test('missing plugin maps to unsupported_platform', () async {
      messenger.setMockMethodCallHandler(methods, null);
      await expectLater(
        Clikgate.track('signup'),
        throwsA(isA<ClikgateException>()
            .having((e) => e.code, 'code', 'unsupported_platform')),
      );
    });
  });

  group('attribution', () {
    test('parses an attributed install', () async {
      final response = fixture('install_response_referral');
      handlers['getAttribution'] = (_) => {
            ...(camel(response['attribution']) as Map),
            'installId': response['install_id'],
          };
      final a = await Clikgate.getAttribution();
      expect(a.status, ClikgateAttributionStatus.attributed);
      expect(a.isAttributed, isTrue);
      expect(a.matchType, 'install_referrer');
      expect(a.confidence, 1.0);
      expect(a.clickId, 'clk_01JAB3C4D5E6F7G8H9JKMNPQRS');
      expect(a.clickedAt, DateTime.utc(2026, 10, 20, 9, 59));
      expect(a.installId, 'ins_01JAB3C4D5E6F7G8H9JKMNPQRS');
      expect(a.link!.isReferral, isTrue);
      expect(a.isReinstall, isFalse);
    });

    test('parses pending / organic', () async {
      handlers['getAttribution'] = (_) =>
          camel(fixture('install_response_organic')['attribution']);
      final a = await Clikgate.getAttribution();
      expect(a.status, ClikgateAttributionStatus.organic);
      expect(a.link, isNull);
      handlers['getAttribution'] = (_) => {'status': 'pending', 'isReinstall': false};
      expect((await Clikgate.getAttribution()).status,
          ClikgateAttributionStatus.pending);
    });
  });

  group('referrals', () {
    const program = 'rpg_01JAB3C4D5E6F7G8H9JKMNPQRS';

    test('applyCode success and typed errors', () async {
      handlers['referrals.applyCode'] = (_) => camel(fixture('referral'));
      final r = await Clikgate.referrals.applyCode(programId: program, code: 'ADA42');
      expect(calls.single.arguments, {'programId': program, 'code': 'ADA42'});
      expect(r.source, 'code_entry');
      expect(r.status, 'installed');
      expect(r.referrerDisplayName, 'Ada');
      expect(r.createdAt, DateTime.utc(2026, 10, 20, 10, 0, 1));

      final err = fixture('error_code_not_found')['error'] as Map<String, dynamic>;
      handlers['referrals.applyCode'] = (_) => throw PlatformException(
          code: err['code'] as String,
          message: err['message'] as String,
          details: {'status': 404, 'param': err['param']});
      await expectLater(
        Clikgate.referrals.applyCode(programId: program, code: 'NOPE'),
        throwsA(isA<ClikgateException>()
            .having((e) => e.code, 'code', 'code_not_found')
            .having((e) => e.status, 'status', 404)
            .having((e) => e.param, 'param', 'code')
            .having((e) => e.message, 'message', 'No active referrer has this code.')),
      );
      for (final code in [
        'already_referred',
        'window_expired',
        'self_referral',
        'identity_required',
        'install_pending',
      ]) {
        handlers['referrals.applyCode'] =
            (_) => throw PlatformException(code: code, message: code);
        await expectLater(
            Clikgate.referrals.applyCode(programId: program, code: 'X'),
            throwsA(isA<ClikgateException>().having((e) => e.code, 'code', code)));
      }
    });

    test('referredBy', () async {
      handlers['referrals.referredBy'] = (_) => camel(fixture('referred_by_response'));
      final info = await Clikgate.referrals.referredBy();
      expect(calls.single.method, 'referrals.referredBy');
      expect(info.referred, isTrue);
      expect(info.referral!.status, 'holding');
      handlers['referrals.referredBy'] = (_) => {'referred': false, 'referral': null};
      final none = await Clikgate.referrals.referredBy();
      expect(none.referred, isFalse);
      expect(none.referral, isNull);
    });
  });

  group('isClikgateMessage (pure Dart)', () {
    test('recognises uninstall-check pushes from the shared fixtures', () {
      expect(Clikgate.isClikgateMessage(fixture('push_fcm_uninstall_check')), isTrue);
      expect(Clikgate.isClikgateMessage(fixture('push_apns_uninstall_check')), isTrue);
      expect(Clikgate.isClikgateMessage(fixture('push_app_message')), isFalse);
    });

    test('edge cases', () {
      expect(Clikgate.isClikgateMessage({'cg': '{"t":"uc"}'}), isTrue);
      expect(Clikgate.isClikgateMessage({'cg': '{bad json'}), isFalse);
      expect(Clikgate.isClikgateMessage({'cg': 'other'}), isFalse);
      expect(Clikgate.isClikgateMessage({'cg': {'t': 'x'}}), isFalse);
      expect(Clikgate.isClikgateMessage({}), isFalse);
      expect(Clikgate.isClikgateMessage(null), isFalse);
    });

    test('needs no platform channel', () {
      messenger.setMockMethodCallHandler(methods, null);
      expect(Clikgate.isClikgateMessage({'cg': 'uc'}), isTrue);
      expect(calls, isEmpty);
    });
  });

  group('onDeepLink', () {
    Map<String, Object?> deferredLink() {
      final r = fixture('install_response_referral');
      final dl = camel(r['deep_link']) as Map<String, Object?>;
      final attribution = r['attribution'] as Map<String, dynamic>;
      return {
        ...dl,
        'clickId': attribution['click_id'],
        'matchType': attribution['match_type'],
        'link': camel(attribution['link']),
        'referral': camel(r['referral']),
      };
    }

    Map<String, Object?> directLink() {
      final r = fixture('resolve_response_matched');
      return {
        ...(camel(r['deep_link']) as Map<String, Object?>),
        'clickId': r['click_id'],
        'matchType': 'app_link',
        'link': camel(r['link']),
        'referral': null,
      };
    }

    test('links emitted before anyone listens are replayed to the first subscriber', () async {
      late MockStreamHandlerEventSink sink;
      messenger.setMockStreamHandler(events,
          MockStreamHandler.inline(onListen: (_, s) => sink = s));
      await Clikgate.configure(sdkKey: 'cg_sdk_test');
      await drain();
      sink.success(deferredLink());
      await drain();

      final received = <ClikgateDeepLink>[];
      final sub = Clikgate.onDeepLink.listen(received.add);
      await drain();
      expect(received, hasLength(1));
      final d = received.single;
      expect(d.isDeferred, isTrue);
      expect(d.path, '/welcome');
      expect(d.data, {'ref': 'ADA42', 'screen': 'referral_welcome'});
      expect(d.matchType, 'install_referrer');
      expect(d.referral!.referrerDisplayName, 'Ada');
      expect(d.link!.kind, 'referral');

      sink.success(directLink());
      await drain();
      expect(received, hasLength(2));
      expect(received.last.isDeferred, isFalse);
      expect(received.last.path, '/products/42');
      expect(received.last.link!.metadata, {'creator_id': 'cr_91'});
      expect(received.last.link!.externalReference, 'off_7');
      await sub.cancel();
    });

    test('is a broadcast stream; buffer keeps the latest 10', () async {
      late MockStreamHandlerEventSink sink;
      messenger.setMockStreamHandler(events,
          MockStreamHandler.inline(onListen: (_, s) => sink = s));
      final stream = Clikgate.onDeepLink;
      await drain();
      for (var i = 0; i < 12; i++) {
        sink.success({...directLink(), 'path': '/p/$i'});
      }
      await drain();
      final a = <String?>[];
      final b = <String?>[];
      final s1 = stream.listen((l) => a.add(l.path));
      await drain();
      final s2 = stream.listen((l) => b.add(l.path));
      expect(a, [for (var i = 2; i < 12; i++) '/p/$i']);
      sink.success({...directLink(), 'path': '/live'});
      await drain();
      expect(a.last, '/live');
      expect(b, ['/live']);
      await s1.cancel();
      await s2.cancel();
    });

    test('ignores malformed events and survives stream errors', () async {
      late MockStreamHandlerEventSink sink;
      messenger.setMockStreamHandler(events,
          MockStreamHandler.inline(onListen: (_, s) => sink = s));
      final received = <ClikgateDeepLink>[];
      final sub = Clikgate.onDeepLink.listen(received.add);
      await drain();
      sink.success('not a map');
      sink.error(code: 'x', message: 'boom');
      sink.success(directLink());
      await drain();
      expect(received, hasLength(1));
      await sub.cancel();
    });
  });

  group('models', () {
    test('ClikgateMoney equality', () {
      expect(const ClikgateMoney.ofMinor(100, 'NGN'), const ClikgateMoney.ofMinor(100, 'NGN'));
      expect(const ClikgateMoney.ofMinor(100, 'NGN') == const ClikgateMoney.ofMinor(100, 'USD'), isFalse);
    });

    test('ClikgateMoney.ofMinor is the name; the old constructor stays as an alias (X.E10)', () {
      // ignore: deprecated_member_use_from_same_package
      expect(const ClikgateMoney(100, 'NGN'), const ClikgateMoney.ofMinor(100, 'NGN'));
    });

    test('tolerates missing optional fields', () {
      final d = ClikgateDeepLink.fromMap({'isDeferred': true});
      expect(d.data, isEmpty);
      expect(d.link, isNull);
      expect(ClikgateException.fromPlatformException(PlatformException(code: 'timeout')).message,
          'timeout');
    });
  });
}

Future<void> drain() => Future<void>.delayed(const Duration(milliseconds: 1));
