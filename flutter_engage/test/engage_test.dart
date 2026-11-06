import 'dart:convert';
import 'dart:io';

import 'package:clikgate_engage/clikgate_engage.dart';
import 'package:clikgate_flutter/clikgate_flutter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Shared contract fixture (../shared/fixtures, relative to flutter_engage/).
String fixture(String name) => File('../shared/fixtures/$name.json').readAsStringSync();

class FakeCore implements EngageCore {
  final Map<String, bool> features = {};
  String? userId = 'user_42';
  String? token = 'sig.1760954400';
  Object? contextError;
  final reports = <List<String?>>[];
  int contextCalls = 0;

  @override
  Future<bool> isFeatureEnabled(String key) async => features[key] ?? true;

  @override
  Future<ClikgateRequestContext> requestContext() async {
    contextCalls++;
    if (contextError != null) throw contextError!;
    return ClikgateRequestContext(
      installationId: '6a1f0c2e-1111-4222-8333-444455556666',
      sdkKey: 'cg_sdk_test_abc',
      environment: 'production',
      apiBaseUrl: 'https://sdk.example.test/',
      identityToken: token,
      customerUserId: userId,
      sdkVersion: 'flutter/1.0.0',
      nativeSdkVersion: 'android/1.0.0',
    );
  }

  @override
  Future<void> reportServerError(String code, {String? feature}) async =>
      reports.add([code, feature]);
}

void main() {
  late FakeCore core;
  late List<http.Request> requests;
  late Map<String, List<Object> Function()> routes; // "METHOD /path" -> responses
  late Map<String, int> served;
  late DateTime now;
  late List<Uri> opened;
  late List<String> shared;
  bool whatsAppInstalled = true;

  ClikgateEngage engage() {
    final client = MockClient((req) async {
      requests.add(req);
      final key = '${req.method} ${req.url.path}';
      final list = routes[key]?.call();
      if (list == null) return http.Response('{"error":{"code":"not_found","message":"x"}}', 404);
      final i = served.update(key, (v) => v + 1, ifAbsent: () => 0);
      final r = list[i < list.length ? i : list.length - 1];
      if (r is Exception) throw r;
      return r as http.Response;
    });
    return ClikgateEngage(
      httpClient: client,
      core: core,
      clock: () => now,
      retryDelay: Duration.zero,
      openUrl: (uri) async {
        opened.add(uri);
        return whatsAppInstalled;
      },
      shareText: (text, {subject}) async => shared.add(text),
    );
  }

  http.Response ok(String body) =>
      http.Response(body, 200, headers: {'content-type': 'application/json'});

  setUp(() {
    core = FakeCore();
    requests = [];
    routes = {};
    served = {};
    now = DateTime.utc(2026, 10, 21, 10);
    opened = [];
    shared = [];
    whatsAppInstalled = true;
  });

  TypeMatcher<ClikgateException> clikgateError(String code, {String? feature, int? status}) => isA<ClikgateException>()
      .having((e) => e.code, 'code', code)
      .having((e) => e.feature, 'feature', feature)
      .having((e) => e.status, 'status', status);

  group('referrals', () {
    test('createLink sends the contract request with context headers', () async {
      routes['POST /v1/sdk/referrals/link'] = () => [ok(fixture('referral_link_response'))];
      final link = await engage().referrals.createLink(programId: 'rpg_1', displayName: 'Ada');
      expect(link.code, 'ADA42X');
      expect(link.shortUrl, 'https://inv.myapp.com/a8K2bq');
      final r = requests.single;
      expect(r.url.toString(), 'https://sdk.example.test/v1/sdk/referrals/link');
      expect(jsonDecode(r.body), {'program_id': 'rpg_1', 'display_name': 'Ada'});
      expect(r.headers['Clikgate-SDK-Key'], 'cg_sdk_test_abc');
      expect(r.headers['Clikgate-SDK-Version'], 'flutter/1.0.0');
      expect(r.headers['Clikgate-SDK-Native-Version'], 'android/1.0.0');
      expect(r.headers['Clikgate-Installation-Id'], '6a1f0c2e-1111-4222-8333-444455556666');
      expect(r.headers['Clikgate-Identity-Token'], 'sig.1760954400');
      expect(r.headers['Content-Type'], startsWith('application/json'));
    });

    test('myStats parses the fixture and is cached for 60 s', () async {
      routes['GET /v1/sdk/referrals/me'] = () => [ok(fixture('referral_stats_response'))];
      final e = engage();
      final s = await e.referrals.myStats(programId: 'rpg_1');
      expect([s.clicks, s.installs, s.signups, s.inProgress, s.qualified, s.disqualified, s.rejected],
          [12, 4, 3, 1, 2, 0, 1]);
      expect(requests.single.url.queryParameters, {'program_id': 'rpg_1'});
      now = now.add(const Duration(seconds: 59));
      await e.referrals.myStats(programId: 'rpg_1');
      expect(requests, hasLength(1));
      now = now.add(const Duration(seconds: 2));
      await e.referrals.myStats(programId: 'rpg_1');
      expect(requests, hasLength(2));
    });

    test('cache is keyed by user and cleared by writes and clearCache', () async {
      routes['GET /v1/sdk/referrals/me'] = () => [ok(fixture('referral_stats_response'))];
      routes['POST /v1/sdk/referrals/link'] = () => [ok(fixture('referral_link_response'))];
      final e = engage();
      await e.referrals.myStats(programId: 'rpg_1');
      core.userId = 'user_43';
      await e.referrals.myStats(programId: 'rpg_1');
      expect(requests, hasLength(2));
      await e.referrals.createLink(programId: 'rpg_1');
      await e.referrals.myStats(programId: 'rpg_1');
      expect(requests, hasLength(4));
      e.clearCache();
      await e.referrals.myStats(programId: 'rpg_1');
      expect(requests, hasLength(5));
    });

    test('not_identified without a network call', () async {
      core.userId = null;
      final e = engage();
      await expectLater(e.referrals.createLink(programId: 'rpg_1'),
          throwsA(clikgateError(ClikgateEngageErrors.notIdentified)));
      await expectLater(e.leaderboards.me('lb_1'), throwsA(clikgateError('not_identified')));
      await expectLater(e.leaderboards.aroundMe('lb_1'), throwsA(clikgateError('not_identified')));
      await expectLater(e.leaderboards.setOptOut(programId: 'rpg_1', optOut: true),
          throwsA(clikgateError('not_identified')));
      await expectLater(e.leaderboards.hostedPageUrl('lb_1'), throwsA(clikgateError('not_identified')));
      expect(requests, isEmpty);
    });

    test('identity_required from the server is typed', () async {
      routes['POST /v1/sdk/referrals/link'] = () => [
            http.Response('{"error":{"code":"identity_required","message":"token needed"}}', 403)
          ];
      await expectLater(engage().referrals.createLink(programId: 'rpg_1'),
          throwsA(clikgateError('identity_required', status: 403)));
    });
  });

  group('feature switches', () {
    test('feature_disabled without network for every call', () async {
      core.features.addAll({'referrals': false, 'leaderboards': false, 'offline_codes': false});
      final e = engage();
      final calls = <(Future<Object?> Function(), String)>[
        (() => e.referrals.createLink(programId: 'p'), 'referrals'),
        (() => e.referrals.myStats(programId: 'p'), 'referrals'),
        (() => e.leaderboards.top('lb'), 'leaderboards'),
        (() => e.leaderboards.me('lb'), 'leaderboards'),
        (() => e.leaderboards.aroundMe('lb'), 'leaderboards'),
        (() => e.leaderboards.setOptOut(programId: 'p', optOut: true), 'leaderboards'),
        (() => e.leaderboards.hostedPageUrl('lb'), 'leaderboards'),
        (() => e.codes.redeem('LAGOS50'), 'offline_codes'),
      ];
      for (final (call, feature) in calls) {
        await expectLater(call(), throwsA(clikgateError('feature_disabled', feature: feature)));
      }
      expect(requests, isEmpty);
      expect(core.contextCalls, 0);
    });

    test('server no-op body maps to feature_disabled and is reported to core', () async {
      routes['GET /v1/sdk/leaderboards/lb_1'] = () => [ok(fixture('feature_disabled'))];
      await expectLater(engage().leaderboards.top('lb_1'),
          throwsA(clikgateError('feature_disabled', feature: 'leaderboards')));
      expect(core.reports, [
        ['feature_disabled', 'leaderboards']
      ]);
    });

    test('global errors are reported to core', () async {
      routes['GET /v1/sdk/leaderboards/lb_1'] =
          () => [http.Response('{"error":{"code":"sdk_disabled","message":"off"}}', 403)];
      await expectLater(engage().leaderboards.top('lb_1'), throwsA(clikgateError('sdk_disabled', status: 403)));
      expect(core.reports, [
        ['sdk_disabled', null]
      ]);
    });

    test('context errors propagate', () async {
      core.contextError = const ClikgateException('install_pending', 'later');
      await expectLater(engage().leaderboards.top('lb_1'), throwsA(clikgateError('install_pending')));
      expect(requests, isEmpty);
    });
  });

  group('retries', () {
    test('one retry for a network error', () async {
      routes['GET /v1/sdk/leaderboards/lb_1'] =
          () => [http.ClientException('connection reset'), ok(fixture('leaderboard_page'))];
      final page = await engage().leaderboards.top('lb_1');
      expect(page.entries, hasLength(2));
      expect(requests, hasLength(2));
    });

    test('no second retry', () async {
      routes['GET /v1/sdk/leaderboards/lb_1'] =
          () => [http.ClientException('a'), http.ClientException('b'), ok(fixture('leaderboard_page'))];
      await expectLater(engage().leaderboards.top('lb_1'), throwsA(clikgateError('network_error')));
      expect(requests, hasLength(2));
    });

    test('no retry for HTTP errors', () async {
      routes['GET /v1/sdk/leaderboards/lb_1'] = () => [http.Response('', 503), ok(fixture('leaderboard_page'))];
      await expectLater(engage().leaderboards.top('lb_1'), throwsA(clikgateError('server_error', status: 503)));
      routes['POST /v1/sdk/codes/redeem'] = () => [
            http.Response('{"error":{"code":"rate_limited","message":"slow"}}', 429, headers: {'retry-after': '1'})
          ];
      await expectLater(engage().codes.redeem('LAGOS50'), throwsA(clikgateError('rate_limited', status: 429)));
      expect(requests, hasLength(2));
    });
  });

  group('leaderboards', () {
    test('top sends query values (clamped) and parses the fixture', () async {
      routes['GET /v1/sdk/leaderboards/lb_1'] = () => [ok(fixture('leaderboard_page'))];
      final page = await engage().leaderboards
          .top('lb_1', period: LeaderboardPeriod.previous, segment: 'lagos', limit: 500);
      expect(requests.single.url.queryParameters, {'period': 'previous', 'segment': 'lagos', 'limit': '100'});
      expect(page.name, 'Weekly top inviters');
      expect(page.period.key, '2026-W43');
      expect(page.period.endsAt, DateTime.utc(2026, 10, 26, 23));
      expect(page.myEntry!.display, 'B**42X');
      expect(page.entries.first.pending, 3);
    });

    test('top works without an identified user', () async {
      core.userId = null;
      routes['GET /v1/sdk/leaderboards/lb_1'] = () => [ok(fixture('leaderboard_page'))];
      expect((await engage().leaderboards.top('lb_1')).entries, hasLength(2));
    });

    test('me and aroundMe', () async {
      routes['GET /v1/sdk/leaderboards/lb_1/me'] = () => [ok(fixture('my_rank'))];
      routes['GET /v1/sdk/leaderboards/lb_1/around-me'] = () => [
            ok(jsonEncode({
              'leaderboard_id': 'lb_1',
              'period': {'key': '2026-W43', 'status': 'open'},
              'entries': (jsonDecode(fixture('leaderboard_page')) as Map)['entries'],
            }))
          ];
      final e = engage();
      final me = await e.leaderboards.me('lb_1');
      expect([me.rank, me.score, me.gapToNext, me.bestRank], [2, 9, 3, 2]);
      final around = await e.leaderboards.aroundMe('lb_1', radius: 99);
      expect(around.name, isNull);
      expect(around.entries, hasLength(2));
      expect(requests.last.url.queryParameters, {'radius': '25', 'period': 'current'});
    });

    test('setOptOut posts and clears the cache', () async {
      routes['GET /v1/sdk/leaderboards/lb_1/me'] = () => [ok(fixture('my_rank'))];
      routes['POST /v1/sdk/leaderboards/opt-out'] = () => [ok('{"program_id":"rpg_1","opt_out":true}')];
      final e = engage();
      await e.leaderboards.me('lb_1');
      await e.leaderboards.setOptOut(programId: 'rpg_1', optOut: true);
      expect(jsonDecode(requests.last.body), {'program_id': 'rpg_1', 'opt_out': true});
      await e.leaderboards.me('lb_1');
      expect(requests, hasLength(3));
    });

    test('hostedPageUrl uses embed_url and is never cached', () async {
      final body = jsonDecode(fixture('my_rank')) as Map<String, dynamic>;
      body['embed_token'] = 'emb_x';
      body['embed_url'] = 'https://inv.myapp.com/leaderboard/lb_1?me=emb_x';
      routes['GET /v1/sdk/leaderboards/lb_1/me'] = () => [ok(jsonEncode(body))];
      final e = engage();
      final url = await e.leaderboards.hostedPageUrl('lb_1');
      expect(url.toString(), 'https://inv.myapp.com/leaderboard/lb_1?me=emb_x');
      expect(requests.single.url.queryParameters, {'period': 'current', 'embed': '1'});
      await e.leaderboards.hostedPageUrl('lb_1');
      expect(requests, hasLength(2));
    });

    test('hostedPageUrl without embed_url', () async {
      routes['GET /v1/sdk/leaderboards/lb_1/me'] = () => [ok(fixture('my_rank'))];
      await expectLater(engage().leaderboards.hostedPageUrl('lb_1'),
          throwsA(clikgateError(ClikgateEngageErrors.hostedPageUnavailable)));
    });

    test('invalid ids are rejected locally', () async {
      final e = engage();
      await expectLater(e.leaderboards.top(' '), throwsA(clikgateError('invalid_argument')));
      await expectLater(e.leaderboards.me('a/b'), throwsA(clikgateError('invalid_argument')));
      await expectLater(e.referrals.myStats(programId: ''), throwsA(clikgateError('invalid_argument')));
      expect(requests, isEmpty);
    });
  });

  group('codes', () {
    test('redeem trims and parses the fixture', () async {
      routes['POST /v1/sdk/codes/redeem'] = () => [ok(fixture('code_redemption_response'))];
      final r = await engage().codes.redeem('  LAGOS50 ');
      expect(jsonDecode(requests.single.body), {'code': 'LAGOS50'});
      expect(r.offlineTouchId, 'oft_01JAB3C4D5E6F7G8H9JKMNPQRS');
      expect(r.code.kind, 'link');
      expect(r.referral, isNull);
    });

    test('referral code returns the core Referral', () async {
      final body = jsonDecode(fixture('code_redemption_response')) as Map<String, dynamic>;
      body['code']['kind'] = 'referral';
      body['referral'] = (jsonDecode(fixture('referral')) as Map)..['source'] = 'offline_code';
      routes['POST /v1/sdk/codes/redeem'] = () => [ok(jsonEncode(body))];
      final r = await engage().codes.redeem('ADA42X');
      expect(r.code.isReferral, isTrue);
      expect(r.referral!.source, 'offline_code');
      expect(r.referral!.referrerDisplayName, 'Ada');
    });

    test('errors with offline_touch_id', () async {
      routes['POST /v1/sdk/codes/redeem'] = () => [http.Response(fixture('error_code_expired'), 409)];
      await expectLater(
          engage().codes.redeem('OLD'),
          throwsA(clikgateError('code_expired', status: 409)
              .having((e) => e.param, 'param', 'code')
              .having((e) => e.message, 'message', 'This code has expired.')));
      routes['POST /v1/sdk/codes/redeem'] = () => [
            http.Response(
                '{"error":{"code":"self_referral","message":"own code","offline_touch_id":"oft_9"}}', 422)
          ];
      await expectLater(engage().codes.redeem('MINE'),
          throwsA(isA<ClikgateException>().having((e) => e.offlineTouchId, 'offlineTouchId', 'oft_9')));
    });

    test('length is validated locally', () async {
      await expectLater(engage().codes.redeem(' ab '), throwsA(clikgateError('invalid_argument')));
      await expectLater(engage().codes.redeem('x' * 31), throwsA(clikgateError('invalid_argument')));
      expect(requests, isEmpty);
    });
  });

  group('share', () {
    test('whatsApp opens whatsapp://send with RFC 3986 encoding', () async {
      expect(await engage().share.whatsApp(text: 'Join me: https://x.io/r/A?b=1&c=2 #win+ é'), isTrue);
      expect(opened.single.toString(),
          'whatsapp://send?text=Join%20me%3A%20https%3A%2F%2Fx.io%2Fr%2FA%3Fb%3D1%26c%3D2%20%23win%2B%20%C3%A9');
      expect(shared, isEmpty);
    });

    test('whatsApp falls back to the share sheet', () async {
      whatsAppInstalled = false;
      expect(await engage().share.whatsApp(text: 'hi'), isFalse);
      expect(shared, ['hi']);
    });

    test('system share and share_unavailable', () async {
      await engage().share.system(text: 'hello');
      expect(shared, ['hello']);
      final failing = ClikgateEngage(core: core, shareText: (t, {subject}) async => throw StateError('no ui'));
      await expectLater(failing.share.system(text: 'x'), throwsA(clikgateError('share_unavailable')));
    });
  });
}
