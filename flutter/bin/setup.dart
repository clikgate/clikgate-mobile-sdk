// `dart run clikgate_flutter:setup [options]` (short form: `dart run clikgate_flutter`): the Clikgate
// setup command (the same program as `npx @clikgate/setup`) without Node.js. Add the package first
// (`flutter pub add clikgate_flutter`), then run it in your Flutter project's folder. See
// https://clikgate.com/docs/setup-command
import 'dart:io';

import 'package:clikgate_flutter/src/setup_runner/setup_runner.dart';

Future<void> main(List<String> args) async {
  final code = await SetupRunner().run(args);
  await Future.wait([stdout.flush(), stderr.flush()]);
  exit(code);
}
