import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'api_listing.dart';

/// Public-API snapshot of `package:clikgate_engage`.
///
/// Update after an intended API change:
/// `UPDATE_API_SNAPSHOT=1 flutter test test/api_snapshot_test.dart`.
void main() {
  const snapshotPath = 'test/api_snapshot.txt';

  test('public API matches test/api_snapshot.txt', () {
    final text = '${apiListing('lib/clikgate_engage.dart').join('\n')}\n';
    if (Platform.environment['UPDATE_API_SNAPSHOT'] == '1') {
      File(snapshotPath).writeAsStringSync(text);
    }
    expect(text, File(snapshotPath).readAsStringSync(),
        reason: 'Public API changed. If intended: UPDATE_API_SNAPSHOT=1 flutter test test/api_snapshot_test.dart');
  });

  test('native code: only the share bridge, over the native Engage add-on (Change 13)', () {
    for (final dir in ['macos', 'windows', 'linux']) {
      expect(Directory(dir).existsSync(), isFalse, reason: dir);
    }
    final kotlin = Directory('android/src/main').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.kt'));
    final swift = Directory('ios').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.swift') && !f.path.endsWith('Package.swift'));
    expect(kotlin.map((f) => f.uri.pathSegments.last), ['ClikgateEngagePlugin.kt']);
    expect(swift.map((f) => f.uri.pathSegments.last), ['ClikgateEngagePlugin.swift']);
    expect(File('android/build.gradle').readAsStringSync(), contains('com.clikgate:clikgate-engage:'));
    expect(File('ios/clikgate_engage.podspec').readAsStringSync(), contains("'Clikgate/Engage'"));
  });

  test('both copies of the API listing helper are identical', () {
    expect(File('test/api_listing.dart').readAsStringSync(),
        File('../flutter/test/api_listing.dart').readAsStringSync());
  });
}
