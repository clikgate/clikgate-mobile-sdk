import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'api_listing.dart';

/// Public-API snapshot of `package:clikgate_flutter` (CI boundary check, spec 20).
///
/// Update after an intended API change:
/// `UPDATE_API_SNAPSHOT=1 flutter test test/api_snapshot_test.dart`.
void main() {
  final listing = apiListing('lib/clikgate_flutter.dart');
  const snapshotPath = 'test/api_snapshot.txt';

  test('public API matches test/api_snapshot.txt', () {
    final text = '${listing.join('\n')}\n';
    if (Platform.environment['UPDATE_API_SNAPSHOT'] == '1') {
      File(snapshotPath).writeAsStringSync(text);
    }
    expect(text, File(snapshotPath).readAsStringSync(),
        reason: 'Public API changed. If intended: UPDATE_API_SNAPSHOT=1 flutter test test/api_snapshot_test.dart');
  });

  test('core has no Engage API (leaderboards, referral stats, link creation, codes, share, identity signals)', () {
    // Feature-switch keys are allowed: they only name a feature for isFeatureEnabled.
    final allowed = RegExp(r'^  static const (leaderboards|whatsappAttribution)$');
    final forbidden = RegExp(
        r'leaderboard|createLink|myStats|ReferralLink|ReferralStats|redeem|Redemption|RedeemedCode|share|whatsapp|identitySignal|identity_signal|MyRank|hostedPage',
        caseSensitive: false);
    final offending = listing.where((l) => forbidden.hasMatch(l) && !allowed.hasMatch(l)).toList();
    expect(offending, isEmpty);
  });

  // Since 2.1.0 the Engage features ship in this package (lib/engage.dart, lib/src/engage/) and on the
  // native side (the share bridge over the native SDK's Engage features); core code still never uses them.
  test('core code never uses the Engage features', () {
    expect(listing.where((l) => l.contains('engage.dart')), isEmpty, reason: 'clikgate_flutter.dart must not export Engage');
    final importsEngage = RegExp(r"""^\s*(import|export|part)\s+['"](package:clikgate_flutter/engage\.dart|(\.\./)*(src/)?engage/)""", multiLine: true);
    final core = Directory('lib').listSync(recursive: true).whereType<File>()
        .where((f) => !f.path.contains('/engage/') && !f.path.endsWith('/engage.dart'));
    for (final f in core) {
      expect(importsEngage.hasMatch(f.readAsStringSync()), isFalse, reason: f.path);
    }
    // Native sides: only EngageShareBridge (and the plugin registering it) may name the Engage features.
    for (final dir in ['android', 'ios']) {
      for (final f in Directory(dir).listSync(recursive: true).whereType<File>()) {
        if (f.path.contains('/build/') || f.path.contains('/.')) continue;
        if (!f.path.endsWith('.kt') && !f.path.endsWith('.swift')) continue;
        if (f.path.endsWith('EngageShareBridge.kt') || f.path.endsWith('EngageShareBridge.swift')) continue;
        expect(f.readAsStringSync(), isNot(matches(RegExp(r'import\s+ClikgateEngage\b|com\.clikgate\.engage'))), reason: f.path);
      }
    }
  });
}
