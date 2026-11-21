import 'package:clikgate_flutter/clikgate_flutter.dart';

import 'config.dart';
import 'session_store.dart';

/// Starts Clikgate once, before `runApp`, so no deep link is missed.
Future<void> startClikgate(AppConfig config, SessionStore session) {
  return Clikgate.configure(
    sdkKey: config.sdkKey,
    // Every link domain of your domain group. Add each one to the iOS Associated Domains and to an Android
    // autoVerify intent filter too (`dart run clikgate_flutter` does both).
    linkDomains: config.linkDomains,
    // Your own storage says this person used the app before (a saved session). Clikgate reads the phone's install
    // date first and uses this hint only when it can't, so an app update is never counted as a new install.
    existingUser: session.hasUsedAppBefore,
  );
}
