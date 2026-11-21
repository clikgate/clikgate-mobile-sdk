import 'package:clikgate_flutter/clikgate_flutter.dart';
import 'package:clikgate_flutter/engage.dart';
import 'package:flutter/material.dart';

import '../auth_service.dart';
import '../backend/backend_api.dart';
import 'referral_screen.dart';

/// The signed-in home: an app goal, a payment, invite friends, and sign-out.
class HomeScreen extends StatelessWidget {
  const HomeScreen({
    super.key,
    required this.auth,
    required this.backend,
    required this.engage,
    required this.referralProgramId,
  });

  final AuthService auth;
  final BackendApi backend;
  final ClikgateEngage engage;
  final String referralProgramId;

  /// A goal that happens in the app. Your own reference makes a resend count once; never put customer data in it.
  Future<void> _completeProfile(BuildContext context) async {
    final result = await Clikgate.goal('profile_completed', reference: 'profile-${auth.user!.id}');
    if (context.mounted) _say(context, 'Goal: ${result.status.name}');
  }

  /// A Payment goal: the app reports the provider and the reference its checkout returned, never an amount.
  /// Then the backend checks the payment with Paystack itself and confirms it to Clikgate with the real amount.
  Future<void> _buy(BuildContext context) async {
    final reference = 'T${DateTime.now().millisecondsSinceEpoch}'; // from your Paystack checkout in a real app
    final result = await Clikgate.goal('order_paid', reference: reference, provider: ClikgateProvider.paystack);
    await backend.confirmPayment(reference);
    if (context.mounted) _say(context, 'Paid. Goal: ${result.status.name}');
  }

  void _say(BuildContext context, String message) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(auth.user?.email ?? '')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            FilledButton(onPressed: () => _completeProfile(context), child: const Text('Complete my profile')),
            FilledButton(onPressed: () => _buy(context), child: const Text('Buy for ₦7,500')),
            FilledButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => ReferralScreen(engage: engage, programId: referralProgramId),
              )),
              child: const Text('Invite friends'),
            ),
            OutlinedButton(onPressed: auth.signOut, child: const Text('Sign out')),
          ],
        ),
      );
}
