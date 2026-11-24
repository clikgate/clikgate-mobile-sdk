import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clikgate_flutter/clikgate_flutter.dart';
import 'package:clikgate_flutter/engage.dart';
import 'package:clikgate_flutter/src/engage/client.dart' show EngageNoWaitCore;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

String fixture(String name) => File('../shared/fixtures/$name.json').readAsStringSync();

/// A core whose waiting context can be held (an install still on its way).
class NoWaitCore implements EngageCore, EngageNoWaitCore {
  final Map<String, bool> features = {};
  String? userId = 'user_42';
  String? token = 'sig.1760954400';
  final reports = <String>[];
  int contextCalls = 0;
  int noWaitCalls = 0;
  Completer<void>? hold;

  ClikgateRequestContext _ctx() => ClikgateRequestContext(
        installationId: '6a1f0c2e-1111-4222-8333-444455556666',
        sdkKey: 'cg_sdk_test_abc',
        environment: 'production',
        apiBaseUrl: 'https://sdk.example.test',
        identityToken: token,
        customerUserId: userId,
        sdkVersion: 'flutter/1.0.0',
      );

  @override
  Future<bool> isFeatureEnabled(String key) async => features[key] ?? true;

  @override
  Future<ClikgateRequestContext> requestContext() async {
    contextCalls++;
    await hold?.future;
    return _ctx();
  }

  @override
  Future<ClikgateRequestContext> requestContextNoWait() async {
    noWaitCalls++;
    return _ctx();
  }

  @override
  Future<void> reportServerError(String code, {String? feature}) async => reports.add(code);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const engageChannel = MethodChannel('com.clikgate/engage');
  const sdkChannel = MethodChannel('com.clikgate/sdk');

  late NoWaitCore core;
  late List<http.Request> requests;
  late List<http.Response> replies;
  late DateTime now;
  // The native saved links: program -> (owner, link JSON); answered only to the signed-in customer
  late Map<String, (String, String)> saved;

  ClikgateEngage engage() => ClikgateEngage(
        httpClient: MockClient((req) async {
          requests.add(req);
          return replies.length > 1 ? replies.removeAt(0) : replies.single;
        }),
        core: core,
        clock: () => now,
        retryDelay: Duration.zero,
      );

  http.Response ok(String body) => http.Response(body, 200, headers: {'content-type': 'application/json'});
  http.Response err(int status, String code) =>
      http.Response('{"error":{"type":"invalid_request","code":"$code","message":"x"}}', status);
  List<http.Request> me() => requests.where((r) => r.url.path == '/v1/sdk/referrals/me').toList();

  setUp(() {
    core = NoWaitCore();
    requests = [];
    replies = [ok(fixture('referral_stats_response'))];
    now = DateTime.utc(2026, 10, 21, 10);
    saved = {};
    messenger.setMockMethodCallHandler(engageChannel, (call) async {
      final args = (call.arguments as Map).cast<String, Object?>();
      final owner = core.userId;
      final program = args['programId'] as String;
      switch (call.method) {
        case 'savedLink':
          final e = saved[program];
          return {'link': e != null && e.$1 == owner ? e.$2 : null, 'token': owner};
        case 'saveLink':
          if (args['token'] != null && args['token'] == owner) saved[program] = (owner!, args['link'] as String);
          return null;
      }
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(engageChannel, null);
    messenger.setMockMethodCallHandler(sdkChannel, null);
  });

  group('myStats', () {
    test('is sent at once with the customer header while the install is pending', () async {
      core.hold = Completer<void>();
      core.userId = 'usér 42/%(x)!';
      final s = await engage().referrals.myStats(programId: 'rpg_1');
      expect(s.code, 'ADA42X');
      expect(me().single.headers['Clikgate-Customer-User-Id'], 'us%C3%A9r%2042%2F%25%28x%29%21');
      expect(me().single.headers['Clikgate-Identity-Token'], 'sig.1760954400');
      expect(core.contextCalls, 0);
      expect(core.noWaitCalls, 1);
    });

    test('the cache is per customer', () async {
      final e = engage();
      await e.referrals.myStats(programId: 'rpg_1');
      await e.referrals.myStats(programId: 'rpg_1');
      expect(me(), hasLength(1));
      core.userId = 'user_43';
      await e.referrals.myStats(programId: 'rpg_1');
      expect(me(), hasLength(2));
      expect(me()[1].headers['Clikgate-Customer-User-Id'], 'user_43');
    });

    for (final (code, status) in [('installation_unknown', 404), ('not_identified', 403)]) {
      test('falls back once through the waiting path on $code', () async {
        replies = [err(status, code), ok(fixture('referral_stats_response'))];
        core.hold = Completer<void>();
        final f = engage().referrals.myStats(programId: 'rpg_1');
        await pumpEventQueue();
        expect(core.contextCalls, 1);
        expect(me(), hasLength(1));
        core.hold!.complete();
        await f;
        expect(me(), hasLength(2));
        expect(me()[0].headers['Clikgate-Customer-User-Id'], 'user_42');
        expect(me()[1].headers.containsKey('Clikgate-Customer-User-Id'), isFalse);
        expect(core.reports, isEmpty);
      });
    }

    test('falls back only once', () async {
      replies = [err(403, 'not_identified')];
      await expectLater(engage().referrals.myStats(programId: 'rpg_1'),
          throwsA(isA<ClikgateException>().having((e) => e.code, 'code', 'not_identified')));
      expect(me(), hasLength(2));
    });

    test('other errors are returned as they are', () async {
      replies = [err(422, 'identity_invalid')];
      await expectLater(engage().referrals.myStats(programId: 'rpg_1'),
          throwsA(isA<ClikgateException>().having((e) => e.code, 'code', 'identity_invalid')));
      expect(me(), hasLength(1));
      expect(core.contextCalls, 0);
    });

    test('without a token it waits as before', () async {
      core.token = null;
      core.hold = Completer<void>();
      final f = engage().referrals.myStats(programId: 'rpg_1');
      await pumpEventQueue();
      expect(requests, isEmpty);
      core.hold!.complete();
      await f;
      expect(me().single.headers.containsKey('Clikgate-Customer-User-Id'), isFalse);
    });

    test('createLink keeps waiting', () async {
      replies = [ok(fixture('referral_link_response'))];
      await engage().referrals.createLink(programId: 'rpg_1');
      expect(core.noWaitCalls, 0);
      expect(requests.single.headers.containsKey('Clikgate-Customer-User-Id'), isFalse);
    });

    test('the plugin core asks the native side for the context with wait: false', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(sdkChannel, (call) async {
        calls.add(call);
        if (call.method == 'isFeatureEnabled') return true;
        return {
          'installationId': 'i',
          'sdkKey': 'k',
          'apiBaseUrl': 'https://sdk.example.test',
          'identityToken': 't',
          'customerUserId': 'c',
          'sdkVersion': 'flutter/1',
        };
      });
      final e = ClikgateEngage(
          httpClient: MockClient((req) async => ok(fixture('referral_stats_response'))),
          retryDelay: Duration.zero);
      await e.referrals.myStats(programId: 'rpg_1');
      final ctx = calls.where((c) => c.method == 'getRequestContext').single;
      expect(ctx.arguments, {'wait': false});
    });
  });

  group('myLink', () {
    test('the first call fetches without waiting and saves the link fields', () async {
      core.hold = Completer<void>();
      final link = await engage().referrals.myLink(programId: 'rpg_1');
      expect(link.code, 'ADA42X');
      expect(link.url, 'https://inv.myapp.com/r/ADA42X');
      expect(link.shortUrl, 'https://inv.myapp.com/a8K2bq');
      expect(me().single.headers['Clikgate-Customer-User-Id'], 'user_42');
      final stored = jsonDecode(saved['rpg_1']!.$2) as Map<String, dynamic>;
      expect(stored['code'], 'ADA42X');
      expect(stored.containsKey('stats'), isFalse);
    });

    test('the saved link answers with no network, then one refresh per minute', () async {
      saved['rpg_1'] = ('user_42', fixture('referral_link_response'));
      replies = [http.Response('', 503)];
      final e = engage();
      final link = await e.referrals.myLink(programId: 'rpg_1');
      expect(link.code, 'ADA42X');
      await pumpEventQueue();
      expect(me(), hasLength(1));
      await e.referrals.myLink(programId: 'rpg_1');
      await pumpEventQueue();
      expect(me(), hasLength(1));
      now = now.add(const Duration(seconds: 60));
      await e.referrals.myLink(programId: 'rpg_1');
      await pumpEventQueue();
      expect(me(), hasLength(2));
    });

    test('a background refresh updates a changed url', () async {
      saved['rpg_1'] = ('user_42', fixture('referral_link_response'));
      final renamed = jsonDecode(fixture('referral_stats_response')) as Map<String, dynamic>
        ..['url'] = 'https://go.myapp.com/r/ADA42X'
        ..['short_url'] = 'https://go.myapp.com/a8K2bq';
      replies = [ok(jsonEncode(renamed))];
      final e = engage();
      expect((await e.referrals.myLink(programId: 'rpg_1')).url, 'https://inv.myapp.com/r/ADA42X');
      await pumpEventQueue();
      final next = await e.referrals.myLink(programId: 'rpg_1');
      expect(next.url, 'https://go.myapp.com/r/ADA42X');
      expect(next.shortUrl, 'https://go.myapp.com/a8K2bq');
    });

    test('saved links are kept per customer', () async {
      saved['rpg_1'] = ('user_42', fixture('referral_link_response'));
      core.userId = 'user_77';
      replies = [err(404, 'referrer_not_found')];
      await expectLater(engage().referrals.myLink(programId: 'rpg_1'),
          throwsA(isA<ClikgateException>().having((e) => e.code, 'code', 'referrer_not_found')));
      expect(me().single.headers['Clikgate-Customer-User-Id'], 'user_77');
    });

    test('not_identified without a customer, no network and no wait', () async {
      core.userId = null;
      core.token = null;
      core.hold = Completer<void>();
      await expectLater(engage().referrals.myLink(programId: 'rpg_1'),
          throwsA(isA<ClikgateException>().having((e) => e.code, 'code', 'not_identified')));
      expect(requests, isEmpty);
      expect(core.contextCalls, 0);
    });

    test('a switched-off feature fails first', () async {
      saved['rpg_1'] = ('user_42', fixture('referral_link_response'));
      core.features['referrals'] = false;
      await expectLater(engage().referrals.myLink(programId: 'rpg_1'),
          throwsA(isA<ClikgateException>().having((e) => e.code, 'code', 'feature_disabled')));
      expect(requests, isEmpty);
    });

    test('myStats saves the link', () async {
      final e = engage();
      await e.referrals.myStats(programId: 'rpg_1');
      replies = [http.Response('', 503)];
      expect((await e.referrals.myLink(programId: 'rpg_1')).code, 'ADA42X');
    });
  });
}
