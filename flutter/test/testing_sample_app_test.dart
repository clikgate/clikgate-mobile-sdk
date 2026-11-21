// A typical app flow tested with the fake (package:clikgate_flutter/testing.dart): sign-in with
// identifyUser and the installation header, a goal, a Payment goal, a referral screen built on
// Engage, a typed referral code, and a deep link that opens a screen. The small app below stands
// in for yours.
import 'package:clikgate_flutter/clikgate_flutter.dart';
import 'package:clikgate_flutter/engage.dart';
import 'package:clikgate_flutter/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late ClikgateFake clikgate;
  setUp(() => clikgate = ClikgateFake.install());

  testWidgets('sign-in identifies the user and sends the installation header', (tester) async {
    final backend = FakeBackend();
    await tester.pumpWidget(MaterialApp(home: HomeScreen(backend: backend)));

    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    expect(backend.headers['Clikgate-Installation'], '${clikgate.appId}:${clikgate.installationId}');
    expect(clikgate.identifyCalls.single.customerId, 'user_42');
    expect(clikgate.identifyCalls.single.identityToken, 'cgid_v2.from-server');
    expect(find.text('Signed in as user_42'), findsOneWidget);

    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    expect(clikgate.identifyCalls.last.isSignOut, isTrue);
  });

  testWidgets('a goal counts; a Payment goal waits for its confirmation', (tester) async {
    await tester.pumpWidget(MaterialApp(home: HomeScreen(backend: FakeBackend())));

    await tester.tap(find.text('Complete profile'));
    await tester.pumpAndSettle();
    expect(find.text('profile_completed: counted'), findsOneWidget);

    await tester.tap(find.text('Pay'));
    await tester.pumpAndSettle();
    expect(find.text('purchase: waiting'), findsOneWidget);
    final pay = clikgate.goals.last;
    expect(pay.provider, ClikgateProvider.paystack);
    expect(pay.reference, 'T123456');
    expect(pay.value, isNull); // the amount comes from the payment confirmation, never the app
  });

  testWidgets('referral screen shows the link and applies a typed code', (tester) async {
    await Clikgate.identifyUser(customerId: 'user_42');
    await tester.pumpWidget(MaterialApp(home: ReferralScreen(engage: ClikgateEngage())));
    await tester.pumpAndSettle();

    expect(find.text(clikgate.referralCode), findsOneWidget);
    expect(find.text('https://yourapp.dev.ciz.to/r/${clikgate.referralCode}'), findsOneWidget);

    await tester.tap(find.text('Share on WhatsApp'));
    await tester.pumpAndSettle();
    expect(clikgate.shares.single.app, 'whatsapp');
    expect(clikgate.shares.single.code, clikgate.referralCode);

    await tester.enterText(find.byType(TextField), '  ADA42 ');
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(find.text('Code applied'), findsOneWidget);
    expect(clikgate.appliedCodes.single.code, 'ADA42');

    clikgate.applyCodeError = 'code_not_found';
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(find.text('code_not_found'), findsOneWidget);
  });

  testWidgets('a deep link opens the product screen', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: DeepLinkRouter()));
    clikgate.pushDeepLink('https://yourapp.dev.ciz.to/products/42');
    await tester.pumpAndSettle();
    expect(find.text('Product 42'), findsOneWidget);
  });
}

// ---------------------------------------------------------------------------------- the "app"

/// Your own backend client. Here it records the headers a real one would send.
class FakeBackend {
  final headers = <String, String>{};

  Future<({String userId, String identityToken})> signIn() async {
    final h = await Clikgate.getInstallationHeader();
    if (h != null) headers[h.name] = h.value;
    return (userId: 'user_42', identityToken: 'cgid_v2.from-server');
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.backend});
  final FakeBackend backend;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String status = '';

  Future<void> _signIn() async {
    final me = await widget.backend.signIn();
    await Clikgate.identifyUser(customerId: me.userId, identityToken: me.identityToken);
    setState(() => status = 'Signed in as ${me.userId}');
  }

  Future<void> _signOut() async {
    await Clikgate.identifyUser(customerId: null);
    setState(() => status = 'Signed out');
  }

  Future<void> _goal(String key, {ClikgateProvider? provider, String? reference}) async {
    final r = await Clikgate.goal(key, provider: provider, reference: reference);
    setState(() => status = '$key: ${r.status.name}');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Column(children: [
          TextButton(onPressed: _signIn, child: const Text('Sign in')),
          TextButton(onPressed: _signOut, child: const Text('Sign out')),
          TextButton(onPressed: () => _goal('profile_completed'), child: const Text('Complete profile')),
          TextButton(
              onPressed: () => _goal('purchase', provider: ClikgateProvider.paystack, reference: 'T123456'),
              child: const Text('Pay')),
          Text(status),
        ]),
      );
}

class ReferralScreen extends StatefulWidget {
  const ReferralScreen({super.key, required this.engage});
  final ClikgateEngage engage;

  @override
  State<ReferralScreen> createState() => _ReferralScreenState();
}

class _ReferralScreenState extends State<ReferralScreen> {
  static const programId = 'rpg_replace_me';
  final code = TextEditingController();
  ReferralLink? link;
  String result = '';

  @override
  void initState() {
    super.initState();
    widget.engage.referrals.createLink(programId: programId).then((l) => setState(() => link = l));
  }

  Future<void> _apply() async {
    try {
      await Clikgate.referrals.applyCode(programId: programId, code: code.text.trim());
      setState(() => result = 'Code applied');
    } on ClikgateException catch (e) {
      setState(() => result = e.code);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Column(children: [
          if (link != null) ...[
            Text(link!.code),
            Text(link!.url),
            TextButton(
                onPressed: () => widget.engage.share.referralLink(link!, app: ShareApp.whatsapp),
                child: const Text('Share on WhatsApp')),
          ],
          TextField(controller: code),
          TextButton(onPressed: _apply, child: const Text('Apply')),
          Text(result),
        ]),
      );
}

class DeepLinkRouter extends StatefulWidget {
  const DeepLinkRouter({super.key});

  @override
  State<DeepLinkRouter> createState() => _DeepLinkRouterState();
}

class _DeepLinkRouterState extends State<DeepLinkRouter> {
  final navigator = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    Clikgate.onDeepLink.listen((link) {
      final id = RegExp(r'^/products/(\w+)$').firstMatch(link.path ?? '')?.group(1);
      if (id != null) {
        navigator.currentState!.push(MaterialPageRoute<void>(builder: (_) => Scaffold(body: Text('Product $id'))));
      }
    });
  }

  @override
  Widget build(BuildContext context) => Navigator(
        key: navigator,
        onGenerateRoute: (_) => MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('Home'))),
      );
}
