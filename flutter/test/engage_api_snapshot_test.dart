import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'api_listing.dart';

/// Public-API snapshot of the Engage features, `package:clikgate_flutter/engage.dart` (was `clikgate_engage`).
///
/// Update after an intended API change:
/// `UPDATE_API_SNAPSHOT=1 flutter test test/engage_api_snapshot_test.dart`.
void main() {
  const snapshotPath = 'test/engage_api_snapshot.txt';

  test('Engage public API matches test/engage_api_snapshot.txt', () {
    final text = '${apiListing('lib/engage.dart').join('\n')}\n';
    if (Platform.environment['UPDATE_API_SNAPSHOT'] == '1') {
      File(snapshotPath).writeAsStringSync(text);
    }
    expect(text, File(snapshotPath).readAsStringSync(),
        reason: 'Public API changed. If intended: UPDATE_API_SNAPSHOT=1 flutter test test/engage_api_snapshot_test.dart');
  });

  test('native code: the share bridge over the native SDK\'s Engage features (Change 13)', () {
    expect(File('android/src/main/kotlin/com/clikgate/clikgate_flutter/EngageShareBridge.kt').readAsStringSync(),
        contains('com.clikgate.engage.ClikgateEngage'));
    expect(File('ios/clikgate_flutter/Sources/clikgate_flutter/EngageShareBridge.swift').readAsStringSync(),
        contains('ClikgateEngage.share'));
    // One native dependency: the core SDK carries the Engage features.
    expect(File('android/build.gradle').readAsStringSync(), isNot(contains('clikgate-engage')));
    expect(File('ios/clikgate_flutter.podspec').readAsStringSync(), isNot(contains("'Clikgate/Engage'")));
  });
}
