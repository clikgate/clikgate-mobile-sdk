import 'package:clikgate_flutter/clikgate_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Change 19 (R.20 S.2): LinkedIn `li_fat_id` and Snap `ScCid` reach the native SDK (and from there Clikgate's
/// /install `launch_url` and /resolve `url`) exactly as the link carried them.
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

  test('handleUrl passes li_fat_id and ScCid unchanged (ScCid keeps its case)',
      () async {
    const url =
        'https://inv.myapp.com/p/dress?cg_click_id=clk_1&li_fat_id=0f1e2d3c-aaaa-bbbb-cccc-1234567890ab&ScCid=snapclick123';
    expect(await Clikgate.handleUrl(url), isTrue);
    expect(calls.single.method, 'handleUrl');
    expect(calls.single.arguments, {'url': url});
  });
}
