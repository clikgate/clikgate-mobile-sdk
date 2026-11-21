import 'package:clikgate_flutter/clikgate_flutter.dart';
import 'package:clikgate_flutter/engage.dart';
import 'package:flutter/material.dart';

import 'auth_service.dart';
import 'backend/backend_api.dart';
import 'deep_links.dart';
import 'screens/home_screen.dart';
import 'screens/sign_in_screen.dart';

/// The app: the sign-in screen or the home screen, with deep links routed on top.
class SampleApp extends StatefulWidget {
  const SampleApp({
    super.key,
    required this.auth,
    required this.backend,
    required this.engage,
    required this.referralProgramId,
    this.deepLinks,
  });

  final AuthService auth;
  final BackendApi backend;
  final ClikgateEngage engage;
  final String referralProgramId;

  /// Defaults to `Clikgate.onDeepLink`; the tests pass their own.
  final Stream<ClikgateDeepLink>? deepLinks;

  @override
  State<SampleApp> createState() => _SampleAppState();
}

class _SampleAppState extends State<SampleApp> {
  final _navigator = GlobalKey<NavigatorState>();
  late final DeepLinkRouter _router = DeepLinkRouter(_navigator, links: widget.deepLinks);

  @override
  void initState() {
    super.initState();
    _router.start();
    widget.auth.restore(); // a saved session: refresh it with /me and identify the user again
  }

  @override
  void dispose() {
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Clikgate sample',
        navigatorKey: _navigator,
        home: ListenableBuilder(
          listenable: widget.auth,
          builder: (context, _) => widget.auth.user == null
              ? SignInScreen(auth: widget.auth)
              : HomeScreen(
                  auth: widget.auth,
                  backend: widget.backend,
                  engage: widget.engage,
                  referralProgramId: widget.referralProgramId,
                ),
        ),
      );
}
