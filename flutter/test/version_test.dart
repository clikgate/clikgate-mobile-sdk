import 'dart:io';

import 'package:clikgate_flutter/clikgate_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

/// The plugin version is sent to the native SDK as the wrapper version (the `Clikgate-SDK-Version`
/// header), so it must follow the published package version; the native dependencies must be at
/// least the same minor (1.2.0 brings consent, click ids and Firebase forwarding).
void main() {
  test('pluginVersion matches pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final version = RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(pubspec)!.group(1);
    expect(Clikgate.pluginVersion, version);
  });

  test('native dependencies require the same minor version', () {
    final minor = Clikgate.pluginVersion.split('.').take(2).join('.');
    expect(File('ios/clikgate_flutter.podspec').readAsStringSync(), contains("'Clikgate', '~> $minor."));
    expect(File('android/build.gradle').readAsStringSync(), contains('?: "$minor.'));
  });
}
