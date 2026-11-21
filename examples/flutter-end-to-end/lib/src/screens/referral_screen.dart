import 'package:clikgate_flutter/clikgate_flutter.dart';
import 'package:clikgate_flutter/engage.dart';
import 'package:flutter/material.dart';

/// "Invite friends": the user's own referral link and code, a Share button, and "Have a code?".
///
/// This screen uses the Engage features, which work without a backend. With a backend, you can get the code from
/// your server instead (`GET /me/referral` in the sample backends): it is the same code either way.
class ReferralScreen extends StatefulWidget {
  const ReferralScreen({super.key, required this.engage, required this.programId});

  final ClikgateEngage engage;
  final String programId;

  @override
  State<ReferralScreen> createState() => _ReferralScreenState();
}

class _ReferralScreenState extends State<ReferralScreen> {
  late final Future<ReferralLink> _link = widget.engage.referrals.createLink(programId: widget.programId);
  final _code = TextEditingController();
  String? _codeMessage;

  /// A friend's code typed by hand (when they didn't install from the friend's link).
  Future<void> _applyCode() async {
    try {
      await Clikgate.referrals.applyCode(programId: widget.programId, code: _code.text.trim());
      setState(() => _codeMessage = 'Code applied. Thanks!');
    } on ClikgateException catch (e) {
      // e.code is code_not_found, already_referred, self_referral, window_expired, ...
      setState(() => _codeMessage = 'That code didn\'t work (${e.code}).');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Invite friends')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            FutureBuilder<ReferralLink>(
              future: _link,
              builder: (context, snapshot) {
                final link = snapshot.data;
                if (snapshot.hasError) return const Text('Your link isn\'t available right now.');
                if (link == null) return const Center(child: CircularProgressIndicator());
                return Column(children: [
                  Text('Your code: ${link.code}'),
                  Text(link.shortUrl),
                  // Each app gets its own version of the link, and the referral code is kept in every one.
                  FilledButton(
                    onPressed: () => widget.engage.share.referralLink(link, message: 'Join me on the app'),
                    child: const Text('Share'),
                  ),
                ]);
              },
            ),
            const Divider(height: 32),
            TextField(controller: _code, decoration: const InputDecoration(labelText: 'Have a code?')),
            TextButton(onPressed: _applyCode, child: const Text('Apply code')),
            if (_codeMessage != null) Text(_codeMessage!),
          ],
        ),
      );

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }
}
