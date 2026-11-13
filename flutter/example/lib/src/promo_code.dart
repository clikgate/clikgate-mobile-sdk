import 'package:clikgate_flutter/engage.dart';
import 'package:clikgate_flutter/clikgate_flutter.dart';
import 'package:flutter/material.dart';

import 'screens.dart' show describeError;

/// Promo / offline code redemption (a code from a poster, flyer, agent or
/// USSD menu), with the Engage features (Engage variant only; a backend would
/// call `POST /v1/codes/redeem` server-side instead).
class PromoCodeScreen extends StatefulWidget {
  const PromoCodeScreen({super.key, required this.engage});

  final ClikgateEngage engage;

  @override
  State<PromoCodeScreen> createState() => _PromoCodeScreenState();
}

class _PromoCodeScreenState extends State<PromoCodeScreen> {
  final _code = TextEditingController();
  String? _message;
  bool _busy = false;

  static const _friendly = {
    'code_not_found': 'That code does not exist.',
    'code_expired': 'That code has expired.',
    'code_disabled': 'That code is no longer active.',
    'redemption_limit_reached': 'That code has been used up.',
    'rate_limited': 'Too many attempts. Try again later.',
    'invalid_argument': 'Codes are 3 to 30 characters.',
    'feature_disabled': 'Promo codes are turned off for this app.',
    'already_referred': 'Code recorded (you were already referred).',
    'self_referral': 'You can’t use your own code.',
    'window_expired': 'Code recorded, but it’s too late for a referral.',
  };

  Future<void> _redeem() async {
    setState(() => _busy = true);
    try {
      final r = await widget.engage.codes.redeem(_code.text);
      setState(() => _message = r.referral != null
          ? 'Code ${r.code.code} applied: referred by ${r.referral!.referrerDisplayName ?? 'a friend'}'
          : 'Code ${r.code.code} applied');
    } on ClikgateException catch (e) {
      setState(() => _message = _friendly[e.code] ?? describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Redeem a promo code')),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(children: [
            TextField(
              key: const Key('promo-code-field'),
              controller: _code,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(labelText: 'Promo code', hintText: 'LAGOS50'),
              onSubmitted: (_) => _redeem(),
            ),
            const SizedBox(height: 12),
            FilledButton(key: const Key('promo-code-redeem'), onPressed: _busy ? null : _redeem, child: const Text('Redeem')),
            if (_message != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_message!, key: const Key('promo-code-message'))),
          ]),
        ),
      );
}
