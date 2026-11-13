// `dart run clikgate_flutter:doctor [options]`: checks the Clikgate setup of this project and changes
// nothing. The same as `dart run clikgate_flutter:setup doctor` (and `npx @clikgate/setup doctor`).
import 'dart:io';

import 'package:clikgate_flutter/src/setup_runner/setup_runner.dart';

Future<void> main(List<String> args) async {
  final code = await SetupRunner().run(doctorArguments(args));
  await Future.wait([stdout.flush(), stderr.flush()]);
  exit(code);
}
