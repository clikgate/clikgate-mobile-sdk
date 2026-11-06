import 'package:clikgate_flutter/clikgate_flutter.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'config.dart';

/// Background messages (separate isolate): drop Clikgate's silent uninstall checks.
/// `Clikgate.isClikgateMessage` is pure Dart, so no plugin setup is needed here.
@pragma('vm:entry-point')
Future<void> firebaseBackgroundHandler(RemoteMessage message) async {
  if (Clikgate.isClikgateMessage(message.data)) return;
  // ... the app's own background handling ...
}

FirebaseOptions get _options => const FirebaseOptions(
      apiKey: ExampleConfig.firebaseApiKey,
      appId: ExampleConfig.firebaseAppId,
      messagingSenderId: ExampleConfig.firebaseSenderId,
      projectId: ExampleConfig.firebaseProjectId,
    );

/// Initialises Firebase only when options were passed via --dart-define, then forwards the
/// FCM token (and refreshes) to Clikgate. Returns a status line for the UI.
Future<String> setUpPush() async {
  if (!ExampleConfig.firebaseConfigured) {
    return 'Push disabled (no FIREBASE_* --dart-define values)';
  }
  try {
    await Firebase.initializeApp(options: _options);
    FirebaseMessaging.onBackgroundMessage(firebaseBackgroundHandler);
    FirebaseMessaging.onMessage.listen((message) {
      if (Clikgate.isClikgateMessage(message.data)) return; // never show these
      debugPrint('App message: ${message.data}');
    });

    final messaging = FirebaseMessaging.instance;
    // Silent uninstall-check pushes don't need notification permission; ask only if the
    // app shows its own notifications.
    await Clikgate.setPushToken(await messaging.getToken(), provider: PushProvider.fcm);
    messaging.onTokenRefresh.listen((t) => Clikgate.setPushToken(t, provider: PushProvider.fcm));
    return 'FCM token registered for uninstall tracking';
  } catch (e) {
    return 'Push setup failed: $e';
  }
}
