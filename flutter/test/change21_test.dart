import 'package:clikgate_flutter/clikgate_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Change 21 (S.1, S.2, R.2, R.25): the Flutter plugin hands every opened URL to the native SDK exactly as it
/// arrived, so the native `/resolve` (direct App Link / Universal Link opens) and `/install` `launch_url` carry the
/// redirect's `cg_click_id` (the server attaches to that click and never records a second one) and X's `twclid`
/// (like `li_fat_id`, change 19 S.2). The installation id is added natively on every call.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methods = MethodChannel('com.clikgate/sdk');
  late List<MethodCall> calls;

  setUp(() {
    calls = [];
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      return true;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(methods, null));

  test('a direct open passes the URL with nothing added', () async {
    const url = 'https://inv.myapp.com/p/dress';
    expect(await Clikgate.handleUrl(url), isTrue);
    expect(calls.single.method, 'handleUrl');
    expect(calls.single.arguments, {'url': url});
  });

  test('a redirect open passes the click reference unchanged, in one call',
      () async {
    const url =
        'https://inv.myapp.com/p/dress?cg_click_id=clk_01JAB3C4D5E6F7G8H9JKMNPQRS&cg_link=lnk_01JAB3C4D5E6F7G8H9JKMNPQRS';
    expect(await Clikgate.handleUrl(url), isTrue);
    expect(calls.single.method, 'handleUrl');
    expect(calls.single.arguments, {'url': url});
  });

  test('handleUrl passes twclid unchanged', () async {
    const url =
        'https://inv.myapp.com/p/dress?cg_click_id=clk_1&twclid=2-abcDEF123xyz&li_fat_id=LIFAT1';
    expect(await Clikgate.handleUrl(url), isTrue);
    expect(calls.single.arguments, {'url': url});
  });
}
