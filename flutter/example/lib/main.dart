import 'dart:async';

import 'package:clikgate_flutter/clikgate_flutter.dart';
import 'package:flutter/material.dart';

import 'src/config.dart';
import 'src/push.dart';
import 'src/screens.dart';
import 'src/variants/backend_features.dart';
import 'src/variants/engage_features.dart';
import 'src/variants/features.dart';

final navigatorKey = GlobalKey<NavigatorState>();

/// The variant is a compile-time constant (--dart-define=CLIKGATE_VARIANT=backend|engage), so
/// the unused implementation is tree-shaken from release builds.
ReferralFeatures createFeatures() => switch (ExampleConfig.variant) {
      'backend' => BackendFeatures(baseUrl: ExampleConfig.backendUrl),
      'engage' => EngageFeatures(programId: ExampleConfig.programId),
      final other => throw ArgumentError('CLIKGATE_VARIANT must be backend or engage, not "$other"'),
    };

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Clikgate.configure(
    sdkKey: ExampleConfig.sdkKey,
    linkDomains: [ExampleConfig.linkDomain],
    apiBaseUrl: ExampleConfig.apiBaseUrl.isEmpty ? null : ExampleConfig.apiBaseUrl,
    logLevel: ClikgateLogLevel.debug,
  );
  // Clikgate attribution (and tracked events) also go to Firebase Analytics when the app
  // includes it and GA4 forwarding is on for the app in Clikgate. The native SDKs detect Firebase
  // Analytics at runtime; this example ships only firebase_messaging, so add firebase_analytics to
  // see the events. Consent: until the user answers (Privacy & sales screen), apps in consent
  // regions send nothing identifying.
  await Clikgate.enableFirebaseForwarding(mirrorEvents: true);
  runApp(ExampleApp(features: createFeatures()));
}

class ExampleApp extends StatefulWidget {
  const ExampleApp({super.key, required this.features, this.pushSetUp});

  final ReferralFeatures features;

  /// Defaults to [setUpPush] (firebase_messaging; a no-op without FIREBASE_* defines).
  final Future<String> Function()? pushSetUp;

  @override
  State<ExampleApp> createState() => _ExampleAppState();
}

class _ExampleAppState extends State<ExampleApp> {
  StreamSubscription<ClikgateDeepLink>? _links;
  final pushStatus = ValueNotifier<String>('Setting up push…');

  @override
  void initState() {
    super.initState();
    // Deferred (after install) and direct deep links. Links that arrived before this
    // subscription are replayed to it.
    _links = Clikgate.onDeepLink.listen(_route);
    (widget.pushSetUp ?? setUpPush)().then((s) => pushStatus.value = s);
  }

  void _route(ClikgateDeepLink link) {
    final nav = navigatorKey.currentState;
    if (nav == null) return;
    final path = link.path ?? '/';
    if (path.startsWith('/products/')) {
      nav.push(MaterialPageRoute(builder: (_) => ProductScreen(link: link)));
    } else if (link.referral != null || path == '/welcome') {
      nav.push(MaterialPageRoute(builder: (_) => ReferralWelcomeScreen(link: link)));
    } else {
      ScaffoldMessenger.maybeOf(nav.context)
          ?.showSnackBar(SnackBar(content: Text('Deep link: $path ${link.data}')));
    }
  }

  @override
  void dispose() {
    _links?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FeaturesScope(
        features: widget.features,
        child: MaterialApp(
          navigatorKey: navigatorKey,
          title: 'Clikgate example',
          theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
          home: HomeScreen(pushStatus: pushStatus),
        ),
      );
}
