// `dart run clikgate_flutter:setup` / `:doctor` (lib/src/setup_runner): platform and asset selection, the
// download → SHA-256 check → cache path against a local HttpServer, env overrides, argument passthrough and
// exit codes with a tiny fake setup command (a shell script). Unix only (the fake command is /bin/sh).
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:clikgate_flutter/src/setup_runner/setup_binaries.g.dart';
import 'package:clikgate_flutter/src/setup_runner/setup_runner.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

const darwinArm = SetupPlatform('darwin', 'arm64');

void main() {
  group('platform and asset selection', () {
    test('maps each supported ABI to its release platform', () {
      expect(platformForAbi(Abi.macosArm64)?.key, 'darwin-arm64');
      expect(platformForAbi(Abi.macosX64)?.key, 'darwin-x64');
      expect(platformForAbi(Abi.linuxX64)?.key, 'linux-x64');
      expect(platformForAbi(Abi.linuxArm64)?.key, 'linux-arm64');
      expect(platformForAbi(Abi.windowsX64)?.key, 'windows-x64');
      expect(platformForAbi(Abi.windowsArm64)?.key, 'windows-x64', reason: 'Windows on Arm emulates x64');
      expect(platformForAbi(Abi.linuxIA32), isNull);
      expect(platformForAbi(Abi.androidArm64), isNull);
    });

    test('asset names, download URL and cache folder', () {
      expect(assetName('2.1.0', darwinArm), 'clikgate-setup-2.1.0-darwin-arm64');
      expect(assetName('2.1.0', const SetupPlatform('windows', 'x64')), 'clikgate-setup-2.1.0-windows-x64.exe');
      expect(downloadUri('2.1.0', darwinArm, {}).toString(),
          'https://github.com/clikgate/clikgate-mobile-sdk/releases/download/setup-v2.1.0/clikgate-setup-2.1.0-darwin-arm64.gz');
      expect(downloadUri('2.1.0', darwinArm, {'CLIKGATE_SETUP_BASE_URL': 'http://127.0.0.1:9/x//'}).toString(),
          'http://127.0.0.1:9/x/clikgate-setup-2.1.0-darwin-arm64.gz');
      expect(cacheDirectory('2.1.0', darwinArm, {'HOME': '/home/a'}), '/home/a/.clikgate/setup/2.1.0');
      expect(cacheDirectory('2.1.0', const SetupPlatform('windows', 'x64'), {'LOCALAPPDATA': r'C:\Users\a\AppData\Local'}),
          r'C:\Users\a\AppData\Local\clikgate\setup\2.1.0');
    });

    test('the generated file carries the CLI version and both sha256 per platform', () {
      expect(setupVersion, matches(RegExp(r'^\d+\.\d+\.\d+')));
      const platforms = ['darwin-arm64', 'darwin-x64', 'linux-x64', 'linux-arm64', 'windows-x64'];
      for (final map in [setupBinarySha256, setupArchiveSha256]) {
        expect(map.keys.toSet(), platforms.toSet());
        for (final hash in map.values) {
          expect(hash, matches(RegExp(r'^[0-9a-f]{64}$')));
        }
      }
    });

    test('doctor runs the doctor subcommand with the rest of the arguments', () {
      expect(doctorArguments(['--json', '--no-wait']), ['doctor', '--json', '--no-wait']);
    });
  });

  group('download, verify, cache and run', () {
    late Directory tmp;
    late HttpServer server;
    late List<int> binary;
    late List<int> served;
    late int requests;
    late int status;
    late File argsFile;
    late StringBuffer log;

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('clikgate_setup_test');
      argsFile = File('${tmp.path}/args.txt');
      // The fake setup command: writes its working folder, CLIKGATE_SETUP_COMMAND and its arguments (one per
      // line), exits 7. The server sends it gzipped, like the release assets.
      binary = utf8.encode(
          '#!/bin/sh\n{ pwd; echo "cmd:\$CLIKGATE_SETUP_COMMAND"; for a in "\$@"; do echo "\$a"; done; } > "${argsFile.path}"\nexit 7\n');
      served = gzip.encode(binary);
      requests = 0;
      status = 200;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        requests++;
        req.response.statusCode = status;
        if (status == 200 && req.uri.path == '/rel/clikgate-setup-9.9.9-darwin-arm64.gz') {
          req.response.contentLength = served.length;
          req.response.add(served);
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      });
      log = StringBuffer();
    });

    tearDown(() async {
      await server.close(force: true);
      tmp.deleteSync(recursive: true);
    });

    SetupRunner runner({Map<String, String>? checksums, Map<String, String>? archiveChecksums, Map<String, String> env = const {}, bool node = false}) =>
        SetupRunner(
          version: '9.9.9',
          checksums: checksums ?? {'darwin-arm64': sha256.convert(binary).toString()},
          archiveChecksums: archiveChecksums ?? {'darwin-arm64': sha256.convert(served).toString()},
          environment: {'HOME': tmp.path, 'CLIKGATE_SETUP_BASE_URL': 'http://127.0.0.1:${server.port}/rel', ...env},
          platform: darwinArm,
          log: log,
          progressIsTerminal: false,
          nodeAvailable: () async => node,
        );
    File cached() => File('${tmp.path}/.clikgate/setup/9.9.9/clikgate-setup-9.9.9-darwin-arm64');

    test('downloads once, verifies, passes every argument through and returns the exit code', () async {
      final code = await runner().run(['doctor', '--json', 'two words', r'$HOME']);
      expect(code, 7);
      expect(requests, 1);
      expect(argsFile.readAsLinesSync(),
          [Directory.current.resolveSymbolicLinksSync(), 'cmd:dart run clikgate_flutter', 'doctor', '--json', 'two words', r'$HOME']);
      expect(cached().existsSync(), isTrue);
      expect(cached().readAsBytesSync(), binary, reason: 'the unpacked binary is cached, not the .gz');
      expect(cached().statSync().modeString(), startsWith('rwx'));
      expect(log.toString(), contains('Downloaded and verified the Clikgate setup command 9.9.9'));
      expect(Directory(cached().parent.path).listSync().map((e) => e.path.split('/').last), ['clikgate-setup-9.9.9-darwin-arm64'],
          reason: 'no temp files left');

      // Second run: the cached binary still matches, no download.
      argsFile.deleteSync();
      expect(await runner().run(['--version']), 7);
      expect(requests, 1);
      expect(argsFile.readAsLinesSync().skip(2), ['--version']);
    });

    test('CLIKGATE_SETUP_COMMAND already set (fvm) is passed on unchanged', () async {
      expect(await runner(env: {'CLIKGATE_SETUP_COMMAND': 'fvm dart run clikgate_flutter'}).run([]), 7);
      expect(argsFile.readAsLinesSync()[1], 'cmd:fvm dart run clikgate_flutter');
    });

    test('a damaged cached binary is downloaded again', () async {
      await runner().run([]);
      cached().writeAsStringSync('#!/bin/sh\nexit 0\n');
      expect(await runner().run([]), 7);
      expect(requests, 2);
    });

    void expectRejected(String message) {
      expect(argsFile.existsSync(), isFalse, reason: 'the download must not run');
      expect(cached().existsSync(), isFalse);
      expect(cached().parent.listSync(), isEmpty, reason: 'temp files removed');
      expect(log.toString(), contains(message));
      expect(log.toString(), isNot(contains('npx')), reason: 'a bad download is not a reason to switch tools');
    }

    test('a .gz that does not match its checksum is rejected before unpacking', () async {
      expect(await runner(archiveChecksums: {'darwin-arm64': 'ab' * 32}, node: true).run(['doctor']), exitProblems);
      expectRejected('did not match its checksum');
      expect(log.toString(), contains('expected sha256 ${'ab' * 32}'));
    });

    test('a good .gz whose unpacked binary does not match is rejected', () async {
      expect(await runner(checksums: {'darwin-arm64': 'cd' * 32}, node: true).run(['doctor']), exitProblems);
      expectRejected('did not match its checksum');
      expect(log.toString(), contains('expected sha256 ${'cd' * 32}'));
    });

    test('a corrupt .gz (checksum matches, but not gzip) is rejected', () async {
      served = utf8.encode('not gzip at all');
      expect(await runner(node: true).run(['doctor']), exitProblems);
      expectRejected('could not be unpacked');
    });

    test('a truncated .gz (checksum matches) is rejected by the binary checksum', () async {
      served = served.sublist(0, served.length ~/ 2);
      expect(await runner(node: true).run([]), exitProblems);
      expectRejected('did not match its checksum');
      expect(log.toString(), isNot(contains('Downloaded and verified')));
    });

    test('CLIKGATE_SETUP_BINARY runs that file without downloading', () async {
      final local = File('${tmp.path}/local-setup')..writeAsBytesSync(binary);
      await Process.run('chmod', ['755', local.path]);
      expect(await runner(env: {'CLIKGATE_SETUP_BINARY': local.path}).run(['a']), 7);
      expect(requests, 0);
      expect(argsFile.readAsLinesSync().skip(2), ['a']);
    });

    test('a missing CLIKGATE_SETUP_BINARY is an error', () async {
      expect(await runner(env: {'CLIKGATE_SETUP_BINARY': '${tmp.path}/nope'}).run([]), exitProblems);
      expect(log.toString(), contains('CLIKGATE_SETUP_BINARY'));
    });

    test('download failure with Node.js installed: prints the npx command (does not run it)', () async {
      status = 404;
      final code = await runner(node: true).run(['doctor', '--json']);
      expect(code, exitProblems);
      expect(log.toString(), contains('HTTP 404'));
      expect(log.toString(), contains('npx @clikgate/setup@9.9.9 doctor --json'));
      expect(argsFile.existsSync(), isFalse);
    });

    test('download failure without Node.js: docs and manual steps links', () async {
      final unreachable = SetupRunner(
        version: '9.9.9',
        checksums: {'darwin-arm64': 'ab' * 32},
        archiveChecksums: {'darwin-arm64': 'ab' * 32},
        environment: {'HOME': tmp.path, 'CLIKGATE_SETUP_BASE_URL': 'http://127.0.0.1:1'},
        platform: darwinArm,
        log: log,
        progressIsTerminal: false,
        nodeAvailable: () async => false,
      );
      expect(await unreachable.run([]), exitProblems);
      expect(log.toString(), contains('Could not download'));
      expect(log.toString(), contains(manualStepsUrl));
      expect(log.toString(), contains(docsUrl));
      expect(log.toString(), isNot(contains('npx')));
    });

    test('unsupported platform, or no checksum for this platform: clear error', () async {
      final none = SetupRunner(version: '9.9.9', checksums: const {}, archiveChecksums: const {}, environment: {'HOME': tmp.path}, detectPlatform: false,
          log: log, nodeAvailable: () async => false);
      expect(await none.run([]), exitProblems);
      expect(log.toString(), contains('no setup command binary for this computer'));
      expect(await runner(checksums: const {}).run([]), exitProblems);
      expect(log.toString(), contains('clikgate_flutter 9.9.9 has no setup command binary for darwin-arm64'));
      expect(requests, 0);
    });
  }, skip: Platform.isWindows ? 'the fake setup command is a shell script' : null);
}
