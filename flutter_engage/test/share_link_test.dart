import 'dart:convert';
import 'dart:io';

import 'package:clikgate_engage/clikgate_engage.dart';
import 'package:clikgate_flutter/clikgate_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Change 13 S.1: share.link / share.referralLink go to the native Engage add-on.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.clikgate/engage');
  final calls = <MethodCall>[];
  Object? reply = true;

  setUp(() {
    calls.clear();
    reply = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (reply is PlatformException) throw reply!;
      return reply;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('ShareApp matches the contract', () {
    final apps = (jsonDecode(File('../shared/share_targets.json').readAsStringSync())['share_apps'] as List).cast<String>();
    expect(ShareApp.values.map((a) => a.value).toList(), apps);
    expect(ShareApp.fromString(' WhatsApp '), ShareApp.whatsapp);
    expect(ShareApp.fromString('myspace'), isNull);
  });

  test('link sends the url, message, app and share_urls', () async {
    final engage = ClikgateEngage();
    final opened = await engage.share.link('https://inv.myapp.com/summer',
        message: 'Join me', app: ShareApp.telegram, shareUrls: {ShareApp.whatsapp: 'https://inv.myapp.com/summer-z'});
    expect(opened, isTrue);
    expect(calls.single.method, 'shareLink');
    expect(calls.single.arguments, {
      'url': 'https://inv.myapp.com/summer',
      'message': 'Join me',
      'app': 'telegram',
      'shareUrls': {'whatsapp': 'https://inv.myapp.com/summer-z'},
    });
  });

  test('referralLink keeps the code and short link', () async {
    reply = false;
    final link = ReferralLink.fromJson(jsonDecode(File('../shared/fixtures/referral_link_response.json').readAsStringSync()));
    expect(await ClikgateEngage().share.referralLink(link), isFalse);
    expect(calls.single.arguments, {
      'url': 'https://inv.myapp.com/r/ADA42X',
      'code': 'ADA42X',
      'shortUrl': 'https://inv.myapp.com/a8K2bq',
      'message': null,
      'app': null,
    });
  });

  test('native errors become ClikgateException; an empty url is refused', () async {
    reply = PlatformException(code: 'share_unavailable', message: 'No app can share text on this device');
    final engage = ClikgateEngage();
    await expectLater(engage.share.link('https://inv.myapp.com/summer'),
        throwsA(isA<ClikgateException>().having((e) => e.code, 'code', ClikgateEngageErrors.shareUnavailable)));
    await expectLater(engage.share.link(' '),
        throwsA(isA<ClikgateException>().having((e) => e.code, 'code', ClikgateException.invalidArgument)));
  });

  test('the bridge can be replaced', () async {
    final seen = <Map<String, Object?>>[];
    final engage = ClikgateEngage(shareLink: (args) async {
      seen.add(args);
      return true;
    });
    expect(await engage.share.link('https://inv.myapp.com/summer', app: ShareApp.whatsapp), isTrue);
    expect(seen.single['app'], 'whatsapp');
    expect(calls, isEmpty);
  });
}
