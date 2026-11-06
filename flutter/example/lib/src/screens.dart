import 'package:clikgate_flutter/clikgate_flutter.dart';
import 'package:flutter/material.dart';

import 'config.dart';
import 'consent.dart';
import 'leaderboard.dart';
import 'promo_code.dart';
import 'variants/engage_features.dart';
import 'variants/features.dart';

String describeError(Object e) => switch (e) {
      ClikgateException() => '${e.code}: ${e.message}',
      AppError() => '${e.code}: ${e.message}',
      _ => e.toString(),
    };

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.pushStatus});

  final ValueNotifier<String> pushStatus;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  ClikgateAttribution? _attribution;
  ReferredBy? _referredBy;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final attribution = await Clikgate.getAttribution();
      final referredBy = await Clikgate.referrals.referredBy();
      if (!mounted) return;
      setState(() {
        _attribution = attribution;
        _referredBy = referredBy;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    }
  }

  void _open(Widget screen) => Navigator.push(context, MaterialPageRoute(builder: (_) => screen));

  @override
  Widget build(BuildContext context) {
    final features = FeaturesScope.of(context);
    final user = features.user;
    final a = _attribution;
    final referral = _referredBy?.referral;
    return Scaffold(
      appBar: AppBar(title: const Text('Clikgate example')),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_referredBy?.referred == true && referral != null)
              Card(
                key: const Key('referred-by-banner'),
                color: Colors.green.shade50,
                child: ListTile(
                  leading: const Icon(Icons.card_giftcard),
                  title: Text('Invited by ${referral.referrerDisplayName ?? 'a friend'}'),
                  subtitle: Text('Referral status: ${referral.status}'),
                ),
              ),
            Card(
              child: ListTile(
                leading: const Icon(Icons.insights),
                title: Text('Attribution: ${a?.status.name ?? '…'}'),
                subtitle: Text([
                  if (a?.matchType != null) 'via ${a!.matchType}',
                  if (a?.installId != null) 'install ${a!.installId}',
                  if (_error != null) _error!,
                ].join('\n')),
              ),
            ),
            ValueListenableBuilder<String>(
              valueListenable: widget.pushStatus,
              builder: (_, status, __) => Card(
                child: ListTile(leading: const Icon(Icons.notifications_none), title: const Text('Push'), subtitle: Text(status)),
              ),
            ),
            Card(
              key: const Key('variant-card'),
              child: ListTile(
                leading: Icon(features.variant == 'backend' ? Icons.dns : Icons.extension),
                title: Text(user == null
                    ? 'Not signed in'
                    : 'Signed in as ${user.displayName ?? user.userId}${user.verified ? ' (verified)' : ''}'),
                subtitle: Text(features.description),
                trailing: TextButton(
                  key: const Key('open-sign-in'),
                  onPressed: () => _open(const SignInScreen()),
                  child: Text(user == null ? 'Sign in' : 'Switch'),
                ),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              key: const Key('open-invite'),
              icon: const Icon(Icons.person_add),
              label: const Text('Invite friends'),
              onPressed: () => _open(const InviteScreen()),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.confirmation_number),
              label: const Text('I have a referral code'),
              onPressed: () async {
                await Navigator.push(context, MaterialPageRoute(builder: (_) => const ApplyCodeScreen()));
                _refresh();
              },
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const Key('open-leaderboard'),
              icon: const Icon(Icons.leaderboard),
              label: const Text('Weekly leaderboard'),
              onPressed: () => _open(const LeaderboardScreen()),
            ),
            if (features is EngageFeatures) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const Key('open-promo-code'),
                icon: const Icon(Icons.local_offer),
                label: const Text('Redeem a promo code'),
                onPressed: () => _open(PromoCodeScreen(engage: features.engage)),
              ),
            ],
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const Key('record-purchase'),
              icon: const Icon(Icons.shopping_bag),
              label: const Text('Buy something (₦15,000)'),
              onPressed: () async {
                try {
                  final orderId = 'A-${DateTime.now().millisecondsSinceEpoch}';
                  _snack(await features.recordPurchase(orderId: orderId, amountMinor: 1500000, currency: 'NGN'));
                } catch (e) {
                  _snack(describeError(e));
                }
              },
            ),
            const SizedBox(height: 8),
            // Goals: use your own reference only, never customer data.
            OutlinedButton.icon(
              key: const Key('record-goal'),
              icon: const Icon(Icons.flag),
              label: const Text('Goal: account opened (₦2,000,000)'),
              onPressed: () async {
                final r = await Clikgate.goal('account_opened',
                    value: '2000000', currency: 'NGN', reference: 'APP-${DateTime.now().millisecondsSinceEpoch}', isFirst: true);
                _snack('account_opened: ${r.status.name}${r.reason == null ? '' : ' (${r.reason})'}');
              },
            ),
            const SizedBox(height: 8),
            // A Payment goal: pass the provider and the reference your checkout returned.
            // It waits until your payment provider or server confirms it, with the real amount.
            OutlinedButton.icon(
              key: const Key('record-payment-goal'),
              icon: const Icon(Icons.payments_outlined),
              label: const Text('Payment goal: purchase (Paystack)'),
              onPressed: () async {
                final r = await Clikgate.goal('purchase',
                    reference: 'T${DateTime.now().millisecondsSinceEpoch}', provider: ClikgateProvider.paystack);
                _snack('purchase: ${r.status.name}${r.reason == null ? '' : ' (${r.reason})'}');
              },
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const Key('open-consent'),
              icon: const Icon(Icons.privacy_tip_outlined),
              label: const Text('Privacy & sales'),
              onPressed: () => _open(const ConsentScreen()),
            ),
            const SizedBox(height: 24),
            Text('Open https://${ExampleConfig.linkDomain}/… links to test direct deep links.',
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }

  void _snack(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}

/// Sign-in. Backend variant: the demo login of samples/backend returns a session and an
/// identity token, then `Clikgate.identifyUser(customerId: userId, identityToken: ...)`. Engage
/// variant: just `Clikgate.identifyUser(customerId: userId)` (no backend to sign a token).
class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _userId = TextEditingController(text: 'user_42');
  final _name = TextEditingController(text: 'Ada');
  String? _error;
  bool _busy = false;

  Future<void> _signIn() async {
    setState(() => _busy = true);
    try {
      final name = _name.text.trim();
      await FeaturesScope.of(context).signIn(_userId.text.trim(), displayName: name.isEmpty ? null : name);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Sign in')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          TextField(key: const Key('sign-in-user'), controller: _userId, decoration: const InputDecoration(labelText: 'User id')),
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Display name')),
          const SizedBox(height: 12),
          FilledButton(key: const Key('sign-in-submit'), onPressed: _busy ? null : _signIn, child: const Text('Sign in (demo)')),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: Colors.red))),
        ]),
      );
}

/// Referral invite: the user's link, share, stats. Same screen in both variants; the data comes
/// from the sample backend or from clikgate_engage.
class InviteScreen extends StatefulWidget {
  const InviteScreen({super.key});

  @override
  State<InviteScreen> createState() => _InviteScreenState();
}

class _InviteScreenState extends State<InviteScreen> {
  InviteLink? _link;
  InviteStats? _stats;
  String? _status;
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _status = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final features = FeaturesScope.of(context);
    final link = _link;
    final stats = _stats;
    const message = 'Join me on the Clikgate example:';
    return Scaffold(
      appBar: AppBar(title: const Text('Invite friends')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (features.user == null)
            Card(
              child: ListTile(
                title: const Text('Sign in to get your invite link'),
                trailing: TextButton(
                  onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SignInScreen())),
                  child: const Text('Sign in'),
                ),
              ),
            ),
          FilledButton(
            key: const Key('get-invite-link'),
            onPressed: _busy ? null : () => _run(() async {
              final l = await features.inviteLink();
              setState(() {
                _link = l;
                _status = null;
              });
            }),
            child: const Text('Get my invite link'),
          ),
          if (link != null) ...[
            const SizedBox(height: 12),
            SelectableText('Code: ${link.code}\n${link.url}', key: const Key('referral-link')),
            const SizedBox(height: 8),
            FilledButton.icon(
              icon: const Icon(Icons.share),
              label: const Text('Share'),
              onPressed: () => _run(() => features.share(link, message)),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.chat),
              label: const Text('Share on WhatsApp'),
              onPressed: () => _run(() async {
                final opened = await features.shareWhatsApp(link, message);
                setState(() => _status = opened ? null : 'Used the share sheet (pick WhatsApp there)');
              }),
            ),
          ],
          const SizedBox(height: 12),
          OutlinedButton(
            key: const Key('load-stats'),
            onPressed: _busy ? null : () => _run(() async {
              final s = await features.stats();
              setState(() => _stats = s);
            }),
            child: const Text('My referral stats'),
          ),
          if (stats != null)
            DataTable(
              key: const Key('stats-table'),
              columns: const [DataColumn(label: Text('Metric')), DataColumn(label: Text('Count'))],
              rows: [
                for (final e in stats.rows.entries) DataRow(cells: [DataCell(Text(e.key)), DataCell(Text('${e.value}'))]),
              ],
            ),
          if (_status != null)
            Padding(padding: const EdgeInsets.only(top: 12), child: Text(_status!, key: const Key('invite-status'), style: const TextStyle(color: Colors.red))),
        ],
      ),
    );
  }
}

/// Manual referral code entry.
class ApplyCodeScreen extends StatefulWidget {
  const ApplyCodeScreen({super.key});

  @override
  State<ApplyCodeScreen> createState() => _ApplyCodeScreenState();
}

class _ApplyCodeScreenState extends State<ApplyCodeScreen> {
  final _code = TextEditingController();
  String? _message;

  static const _friendly = {
    'code_not_found': 'That code does not exist.',
    'already_referred': 'You were already referred.',
    'window_expired': 'Codes can only be entered shortly after installing.',
    'self_referral': 'You can’t use your own code.',
    'program_paused': 'The referral program is paused.',
    'manual_entry_disabled': 'Codes can’t be entered manually for this program.',
    'referrer_blocked': 'That code can no longer be used.',
  };

  Future<void> _apply() async {
    try {
      final referral = await Clikgate.referrals.applyCode(programId: ExampleConfig.programId, code: _code.text);
      setState(() => _message = 'Referred by ${referral.referrerDisplayName ?? 'a friend'} (${referral.status})');
    } on ClikgateException catch (e) {
      setState(() => _message = _friendly[e.code] ?? describeError(e));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Enter a referral code')),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(children: [
            TextField(
              controller: _code,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(labelText: 'Friend’s code', hintText: 'ADA42X'),
            ),
            const SizedBox(height: 12),
            FilledButton(onPressed: _apply, child: const Text('Apply')),
            if (_message != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_message!)),
          ]),
        ),
      );
}

/// Destination of product links (`/products/{id}`).
class ProductScreen extends StatelessWidget {
  const ProductScreen({super.key, required this.link});

  final ClikgateDeepLink link;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Product')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          Text('Product ${link.data['product_id'] ?? link.path}', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text('path: ${link.path}\ndata: ${link.data}\ndeferred: ${link.isDeferred}\nmatch: ${link.matchType}'),
          if (link.link?.externalReference != null) Text('offer: ${link.link!.externalReference}'),
        ]),
      );
}

/// Shown for referral links (deferred after install, or direct).
class ReferralWelcomeScreen extends StatelessWidget {
  const ReferralWelcomeScreen({super.key, required this.link});

  final ClikgateDeepLink link;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Welcome')),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            '${link.referral?.referrerDisplayName ?? 'A friend'} invited you!\n\n'
            '${link.isDeferred ? 'Deferred deep link after install' : 'Opened from a link'} → ${link.path}\n'
            'data: ${link.data}',
            key: const Key('referral-welcome'),
          ),
        ),
      );
}
