import 'package:clikgate_flutter/clikgate_flutter.dart';
import 'package:flutter/material.dart';

/// consent controls (what your own consent banner would call) and the sales metadata
/// helper (`Clikgate.attributionMetadata()` → Paystack `metadata` / Flutterwave `meta`).
class ConsentScreen extends StatefulWidget {
  const ConsentScreen({super.key});

  @override
  State<ConsentScreen> createState() => _ConsentScreenState();
}

class _ConsentScreenState extends State<ConsentScreen> {
  ClikgateConsent? _consent;
  Map<String, String>? _metadata;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final consent = await Clikgate.getConsent();
      final metadata = await Clikgate.attributionMetadata();
      if (!mounted) return;
      setState(() {
        _consent = consent;
        _metadata = metadata;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final c = _consent;
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy & sales')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              key: const Key('consent-state'),
              leading: const Icon(Icons.privacy_tip_outlined),
              title: Text(c == null
                  ? 'Consent: …'
                  : 'analytics ${c.analytics.name}, attribution ${c.attribution.name}, '
                      'ad data ${c.adUserData.name}, ad personalisation ${c.adPersonalization.name}'),
              subtitle: Text([
                'region: ${c?.region ?? 'none'}',
                'required: ${c?.required ?? 'unknown'}',
                if (_error != null) _error!,
              ].join('\n')),
            ),
          ),
          FilledButton(
            key: const Key('consent-accept'),
            onPressed: () => _run(() => Clikgate.setConsent(
                  analytics: ConsentState.granted,
                  attribution: ConsentState.granted,
                  adUserData: ConsentState.granted,
                  adPersonalization: ConsentState.granted,
                )),
            child: const Text('Accept all'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            key: const Key('consent-necessary'),
            onPressed: () => _run(() => Clikgate.setConsent(
                  analytics: ConsentState.denied,
                  attribution: ConsentState.denied,
                  adUserData: ConsentState.denied,
                  adPersonalization: ConsentState.denied,
                )),
            child: const Text('Necessary only'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            key: const Key('consent-eea'),
            onPressed: () => _run(() => Clikgate.setConsentRegion('EEA')),
            child: const Text('Pretend the user is in the EEA'),
          ),
          const SizedBox(height: 16),
          Card(
            child: ListTile(
              key: const Key('attribution-metadata'),
              leading: const Icon(Icons.receipt_long),
              title: const Text('attributionMetadata()'),
              subtitle: Text(_metadata == null
                  ? '…'
                  : _metadata!.isEmpty
                      ? 'none (not attributed, or no attribution consent)'
                      : _metadata!.entries.map((e) => '${e.key}: ${e.value}').join('\n')),
            ),
          ),
        ],
      ),
    );
  }
}
