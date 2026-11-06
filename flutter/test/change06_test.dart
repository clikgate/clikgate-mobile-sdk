import 'package:clikgate_flutter/clikgate_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Bridge method `goal`: arguments, the result map, providers and enums.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methods = MethodChannel('com.clikgate/sdk');

  late List<MethodCall> calls;
  Object? Function(MethodCall)? handler;

  setUp(() {
    calls = [];
    handler = null;
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      return handler?.call(call);
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(methods, null));

  Map<Object?, Object?> lastArgs() => calls.single.arguments as Map;

  test('sends every option, the value as a decimal string', () async {
    await Clikgate.goal('account_opened',
        value: 2000000, currency: 'NGN', reference: 'APP-55231', isFirst: true, label: 'Ada');
    expect(calls.single.method, 'goal');
    expect(lastArgs(), {
      'key': 'account_opened',
      'value': '2000000',
      'currency': 'NGN',
      'reference': 'APP-55231',
      'provider': null,
      'isFirst': true,
      'label': 'Ada',
    });
  });

  test('numbers and numeric strings become decimal strings, never doubles',
      () async {
    final cases = <Object, String>{
      2000000: '2000000',
      1500.5: '1500.5',
      0.25: '0.25',
      3.0: '3',
      '1500.50': '1500.50', // strings pass unchanged; the native SDK normalises
      ' 42 ': '42',
      BigInt.parse('123456789012345'): '123456789012345',
    };
    for (final entry in cases.entries) {
      calls.clear();
      await Clikgate.goal('order_paid', value: entry.key);
      expect(lastArgs()['value'], entry.value, reason: '${entry.key}');
      expect(lastArgs()['value'], isA<String>());
    }
  });

  test('without options only the key is set', () async {
    await Clikgate.goal('kyc_passed');
    expect(lastArgs(), {
      'key': 'kyc_passed',
      'value': null,
      'currency': null,
      'reference': null,
      'provider': null,
      'isFirst': null,
      'label': null,
    });
  });

  test('NaN, infinity, exponent notation and other types are refused locally',
      () async {
    for (final bad in <Object>[double.nan, double.infinity, 1e21, 1e-7, true]) {
      final r = await Clikgate.goal('order_paid', value: bad);
      expect(r.status, GoalStatus.refused, reason: '$bad');
      expect(r.reason, 'invalid_argument');
      expect(r.goalKind, isNull);
    }
    expect(calls, isEmpty);
  });

  test('native errors resolve as refused with the error code', () async {
    handler = (_) => throw PlatformException(
        code: 'invalid_argument',
        message: 'Goal keys must be snake_case',
        details: {'param': 'goal'});
    final r = await Clikgate.goal('Bad-Key');
    expect(r, const GoalResult(status: GoalStatus.refused, reason: 'invalid_argument'));
  });

  test('a Payment goal sends the provider and reference', () async {
    handler = (_) => {
          'status': 'waiting',
          'reason': 'waiting_for_confirmation',
          'goalKind': 'payment',
          'valueIgnored': false,
        };
    final r = await Clikgate.goal('purchase',
        reference: 'T123456', provider: ClikgateProvider.paystack);
    expect(lastArgs()['provider'], 'paystack');
    expect(lastArgs()['reference'], 'T123456');
    expect(lastArgs().containsKey('kind'), isFalse);
    expect(r.status, GoalStatus.waiting);
    expect(r.reason, 'waiting_for_confirmation');
    expect(r.goalKind, GoalKind.payment);
    expect(r.valueIgnored, isFalse);
  });

  test('decodes counted, ignored values and unknown statuses', () async {
    handler = (_) => {
          'status': 'counted',
          'reason': null,
          'goalKind': 'standard',
          'valueIgnored': false,
        };
    expect(await Clikgate.goal('account_opened'),
        const GoalResult(status: GoalStatus.counted, goalKind: GoalKind.standard));
    handler = (_) => {
          'status': 'waiting',
          'reason': 'waiting_for_confirmation',
          'goalKind': 'payment',
          'valueIgnored': true,
        };
    expect((await Clikgate.goal('purchase', value: 10)).valueIgnored, isTrue);
    handler = (_) => {'status': 'later', 'goalKind': 'other'};
    final r = await Clikgate.goal('purchase');
    expect(r.status, GoalStatus.refused);
    expect(r.goalKind, isNull);
  });

  test('ClikgateProvider constants and fromString', () {
    expect(ClikgateProvider.mtnMomo.value, 'mtn_momo');
    expect(ClikgateProvider.values, contains(ClikgateProvider.stripe));
    expect(ClikgateProvider.values.length, 27);
    expect(ClikgateProvider.fromString(' PayStack '), same(ClikgateProvider.paystack));
    final later = ClikgateProvider.fromString('newpay');
    expect(later?.value, 'newpay');
    expect(later, ClikgateProvider.fromString('newpay'));
    expect(ClikgateProvider.fromString('Bad-Key'), isNull);
    expect(ClikgateProvider.fromString(''), isNull);
  });
}
