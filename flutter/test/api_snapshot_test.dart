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

  test('core never depends on clikgate_engage', () {
    expect(File('pubspec.yaml').readAsStringSync(), isNot(contains('clikgate_engage')));
    final importsEngage = RegExp(r'''^\s*(import|export|part)\s+['"]package:clikgate_engage''', multiLine: true);
    final sources = Directory('lib').listSync(recursive: true).whereType<File>();
    for (final f in sources) {
      expect(importsEngage.hasMatch(f.readAsStringSync()), isFalse, reason: f.path);
    }
    // Native sides: no Engage module / product / artifact (the core's `@_spi(ClikgateEngage)`
    // request-context API is core).
    for (final dir in ['android', 'ios']) {
      for (final f in Directory(dir).listSync(recursive: true).whereType<File>()) {
        if (f.path.contains('/build/') || f.path.contains('/.')) continue;
        if (!f.path.endsWith('.kt') && !f.path.endsWith('.swift') && !f.path.endsWith('.gradle') && !f.path.endsWith('.podspec')) continue;
        expect(f.readAsStringSync(), isNot(matches(RegExp(r'import\s+ClikgateEngage\b|"ClikgateEngage"|clikgate-engage|Clikgate/Engage'))), reason: f.path);
      }
    }
  });
}
