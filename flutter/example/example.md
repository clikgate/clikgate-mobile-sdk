# clikgate_flutter example

```dart
import 'package:clikgate_flutter/clikgate_flutter.dart';

Future<void> main() async {
  await Clikgate.configure(sdkKey: 'cg_sdk_live_...', linkDomains: ['go.yourbrand.com']);

  Clikgate.onDeepLink.listen((link) {
    // Route to link.path with link.data.
  });

  // A goal: an outcome your business chose, with your own reference.
  final opened = await Clikgate.goal('account_opened',
      value: 2000000, currency: 'NGN', reference: 'APP-55231', isFirst: true);
  // opened.status: GoalStatus.counted

  // A Payment goal: the provider and the reference your checkout returned. It
  // waits until your payment provider or server confirms it, with the real amount.
  final paid = await Clikgate.goal('purchase',
      reference: 'T123456', provider: ClikgateProvider.paystack);
  // paid.status: GoalStatus.waiting (paid.reason: 'waiting_for_confirmation')
}
```

The full example app (deep links, referrals, consent, push and Engage screens) is in the
[clikgate-mobile-sdk repository](https://github.com/clikgate/clikgate-mobile-sdk/tree/main/flutter/example).
