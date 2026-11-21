import 'package:clikgate_flutter/engage.dart';
import 'package:flutter/widgets.dart';

import 'src/app.dart';
import 'src/auth_service.dart';
import 'src/backend/backend_api.dart';
import 'src/clikgate_setup.dart';
import 'src/config.dart';
import 'src/session_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final config = AppConfig.fromEnvironment();
  final session = await SessionStore.open();
  await startClikgate(config, session); // before runApp, so the first deep link isn't missed

  final backend = BackendApi.create(config.backendUrl, session);
  runApp(SampleApp(
    auth: AuthService(backend, session),
    backend: backend,
    engage: ClikgateEngage(),
    referralProgramId: config.referralProgramId,
  ));
}
