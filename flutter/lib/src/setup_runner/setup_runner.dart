// `dart run clikgate_flutter:setup` / `:doctor` (bin/setup.dart, bin/doctor.dart): runs the setup command
// (the same program as `npx @clikgate/setup`, cli/ compiled with Bun by scripts/build_setup_binaries.sh)
// without Node.js. Downloads the gzipped binary for this platform once, checks the SHA-256 of the .gz and,
// after unpacking, of the binary against the hashes this package version carries (setup_binaries.g.dart),
// caches it and runs it with the arguments and the terminal unchanged. The child gets
// CLIKGATE_SETUP_COMMAND=dart run clikgate_flutter, so the commands it prints are ones the person can run.
//
// Pure Dart (dart:io, dart:ffi's Abi, package:crypto): no Flutter imports, `dart run` loads it without the
// Flutter engine. Not exported from the package's public libraries.
//
// Environment:
//   CLIKGATE_SETUP_BINARY=<path>    run this binary (testing, offline machines); no download, no hash check
//   CLIKGATE_SETUP_BASE_URL=<url>   download <url>/<asset>.gz instead of the GitHub release (still verified)
//   CLIKGATE_SETUP_COMMAND=<cmd>    the command the setup command prints (default dart run clikgate_flutter;
//                                   e.g. fvm dart run clikgate_flutter)
//
// Nothing is sent anywhere except the download request (no telemetry); messages go to stderr so
// `doctor --json` keeps stdout for the JSON report.
import 'dart:async';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'setup_binaries.g.dart';

const docsUrl = 'https://clikgate.com/docs/setup-command';
const manualStepsUrl = 'https://clikgate.com/docs/sdks/flutter';
const releaseBaseUrl = 'https://github.com/clikgate/clikgate-mobile-sdk/releases/download';

/// Exit code for "a step failed" (same as the setup command's EXIT.PROBLEMS).
const exitProblems = 1;

/// Arguments for `dart run clikgate_flutter:doctor …`: the setup command's `doctor` subcommand.
List<String> doctorArguments(List<String> args) => ['doctor', ...args];

/// An `<os>-<arch>` pair as used in the release asset names (`darwin-arm64`, `windows-x64`, ...).
class SetupPlatform {
  const SetupPlatform(this.os, this.arch);
  final String os;
  final String arch;
  String get key => '$os-$arch';
  bool get isWindows => os == 'windows';
  @override
  String toString() => key;
}

/// The release platform for a Dart [Abi], or null when there is no binary for it. Windows on Arm runs
/// the x64 binary (Windows 11 emulates x64); macOS under Rosetta reports x64 and gets the x64 binary.
SetupPlatform? platformForAbi(Abi abi) {
  if (abi == Abi.macosArm64) return const SetupPlatform('darwin', 'arm64');
  if (abi == Abi.macosX64) return const SetupPlatform('darwin', 'x64');
  if (abi == Abi.linuxX64) return const SetupPlatform('linux', 'x64');
  if (abi == Abi.linuxArm64) return const SetupPlatform('linux', 'arm64');
  if (abi == Abi.windowsX64 || abi == Abi.windowsArm64) return const SetupPlatform('windows', 'x64');
  return null;
}

/// `clikgate-setup-<version>-<os>-<arch>[.exe]`.
String assetName(String version, SetupPlatform platform) =>
    'clikgate-setup-$version-${platform.key}${platform.isWindows ? '.exe' : ''}';

/// The command the setup command names in its messages and --help (it derives `…:doctor` itself).
const defaultSetupCommand = 'dart run clikgate_flutter';

/// `<base>/<asset>.gz`; base defaults to the GitHub release `setup-v<version>`.
Uri downloadUri(String version, SetupPlatform platform, Map<String, String> env) {
  var base = env['CLIKGATE_SETUP_BASE_URL'] ?? '';
  if (base.isEmpty) base = '$releaseBaseUrl/setup-v$version';
  while (base.endsWith('/')) {
    base = base.substring(0, base.length - 1);
  }
  return Uri.parse('$base/${assetName(version, platform)}.gz');
}

/// `~/.clikgate/setup/<version>` (Windows: `%LOCALAPPDATA%\clikgate\setup\<version>`).
String cacheDirectory(String version, SetupPlatform platform, Map<String, String> env) {
  if (platform.isWindows) {
    final base = env['LOCALAPPDATA'] ?? '${env['USERPROFILE'] ?? '.'}\\AppData\\Local';
    return '$base\\clikgate\\setup\\$version';
  }
  final home = env['HOME'];
  if (home == null || home.isEmpty) throw const SetupRunnerException('HOME is not set, so there is no folder to keep the setup command in.');
  return '$home/.clikgate/setup/$version';
}

class SetupRunnerException implements Exception {
  const SetupRunnerException(this.message, {this.offerNode = true});
  final String message;

  /// Whether `npx @clikgate/setup` is a sensible alternative (false for a checksum mismatch: retrying the
  /// same download is the fix, and a tampered download should be looked at).
  final bool offerNode;
  @override
  String toString() => message;
}

Future<String> sha256OfFile(File file) async => (await sha256.bind(file.openRead()).first).toString();

/// Runs the setup command. Every dependency is injectable for tests.
class SetupRunner {
  SetupRunner({
    String? version,
    Map<String, String>? checksums,
    Map<String, String>? archiveChecksums,
    Map<String, String>? environment,
    SetupPlatform? platform,
    bool detectPlatform = true,
    StringSink? log,
    bool? progressIsTerminal,
    Future<bool> Function()? nodeAvailable,
  })  : version = version ?? setupVersion,
        checksums = checksums ?? setupBinarySha256,
        archiveChecksums = archiveChecksums ?? setupArchiveSha256,
        env = environment ?? Platform.environment,
        platform = platform ?? (detectPlatform ? platformForAbi(Abi.current()) : null),
        log = log ?? stderr,
        _progressIsTerminal = progressIsTerminal ?? stderr.hasTerminal,
        _nodeAvailable = nodeAvailable ?? _isNodeOnPath;

  final String version;
  /// SHA-256 of the binary, by platform.
  final Map<String, String> checksums;

  /// SHA-256 of the downloaded `.gz`, by platform.
  final Map<String, String> archiveChecksums;
  final Map<String, String> env;
  final SetupPlatform? platform;
  final StringSink log;
  final bool _progressIsTerminal;
  final Future<bool> Function() _nodeAvailable;

  /// Resolves the binary (download when needed) and runs it with [args]; returns its exit code. Errors
  /// before the program starts are printed with the alternatives and return [exitProblems].
  Future<int> run(List<String> args) async {
    final String binary;
    try {
      binary = await resolveBinary();
    } on SetupRunnerException catch (e) {
      await _printFailure(e, args);
      return exitProblems;
    }
    return execute(binary, args);
  }

  /// Path of a verified binary for this platform: `CLIKGATE_SETUP_BINARY`, the cache, or a fresh download.
  Future<String> resolveBinary() async {
    final override = env['CLIKGATE_SETUP_BINARY'] ?? '';
    if (override.isNotEmpty) {
      if (!File(override).existsSync()) throw SetupRunnerException('CLIKGATE_SETUP_BINARY points to a file that does not exist: $override');
      return override;
    }
    final p = platform;
    if (p == null) {
      throw SetupRunnerException('There is no setup command binary for this computer (${Abi.current()}).');
    }
    final expected = checksums[p.key];
    final expectedArchive = archiveChecksums[p.key];
    if (expected == null || expectedArchive == null) {
      throw SetupRunnerException('clikgate_flutter $version has no setup command binary for $p.');
    }
    final dir = Directory(cacheDirectory(version, p, env));
    final target = File('${dir.path}${Platform.pathSeparator}${assetName(version, p)}');
    if (target.existsSync()) {
      if (await sha256OfFile(target) == expected) return target.path;
      target.deleteSync(); // stale or damaged: download again
    }
    dir.createSync(recursive: true);
    final archive = File('${target.path}.gz.download-$pid');
    final temp = File('${target.path}.download-$pid');
    try {
      final archiveHash = await _download(downloadUri(version, p, env), archive);
      if (archiveHash != expectedArchive) throw _mismatch(expectedArchive, archiveHash);
      final binaryHash = await _unpack(archive, temp);
      if (binaryHash != expected) throw _mismatch(expected, binaryHash);
      if (!p.isWindows) {
        final r = await Process.run('chmod', ['755', temp.path]);
        if (r.exitCode != 0) throw SetupRunnerException('Could not make ${temp.path} executable: ${r.stderr}');
      }
      temp.renameSync(target.path); // same folder: atomic
      log.writeln('Downloaded and verified the Clikgate setup command $version (${_Progress.mb(archive.lengthSync())}).');
    } finally {
      for (final f in [archive, temp]) {
        if (f.existsSync()) f.deleteSync();
      }
    }
    return target.path;
  }

  SetupRunnerException _mismatch(String expected, String actual) => SetupRunnerException(
        'The downloaded setup command did not match its checksum, so it was not run.\n'
        '  expected sha256 $expected\n  got      sha256 $actual\n'
        'Try again; if it keeps happening, report it at https://github.com/clikgate/clikgate-mobile-sdk/issues',
        offerNode: false,
      );

  /// Unpacks the verified [archive] (gzip) into [into], streaming; returns the SHA-256 of the binary.
  Future<String> _unpack(File archive, File into) async {
    final digest = _DigestSink();
    final hashInput = sha256.startChunkedConversion(digest);
    final out = into.openWrite();
    try {
      await for (final chunk in archive.openRead().transform(gzip.decoder)) {
        out.add(chunk);
        hashInput.add(chunk);
      }
    } on Object catch (e) {
      throw SetupRunnerException('The downloaded setup command could not be unpacked (${_short(e)}), so it was not run.', offerNode: false);
    } finally {
      await out.close();
    }
    hashInput.close();
    return digest.value!.toString();
  }

  /// Streams [uri] into [into] and returns the SHA-256 of what arrived.
  Future<String> _download(Uri uri, File into) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30)
      ..findProxy = HttpClient.findProxyFromEnvironment
      ..userAgent = 'clikgate_flutter-setup/$version';
    final digest = _DigestSink();
    final hashInput = sha256.startChunkedConversion(digest);
    IOSink? out;
    try {
      final HttpClientResponse response;
      try {
        response = await (await client.getUrl(uri)).close(); // follows GitHub's redirect
      } on Object catch (e) {
        throw SetupRunnerException('Could not download the setup command from ${uri.host}: ${_short(e)}');
      }
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>().catchError((_) {});
        throw SetupRunnerException('Could not download the setup command: HTTP ${response.statusCode} from $uri');
      }
      final total = response.contentLength; // -1 when unknown
      final progress = _Progress(log, _progressIsTerminal, version, platform!.key, total);
      progress.start();
      out = into.openWrite();
      var received = 0;
      try {
        await for (final chunk in response.timeout(const Duration(seconds: 60))) {
          out.add(chunk);
          hashInput.add(chunk);
          received += chunk.length;
          progress.update(received);
        }
      } on Object catch (e) {
        progress.fail();
        throw SetupRunnerException('The download of the setup command stopped: ${_short(e)}');
      }
      await out.close();
      out = null;
      hashInput.close();
      progress.done(received);
      return digest.value!.toString();
    } finally {
      await out?.close();
      client.close(force: true);
    }
  }

  /// Runs [binary] in the current folder with the terminal attached; returns its exit code. Ctrl-C reaches
  /// the setup command (same process group), which handles it; this process waits for it to finish.
  Future<int> execute(String binary, List<String> args) async {
    final subs = <StreamSubscription<ProcessSignal>>[];
    try {
      final command = env['CLIKGATE_SETUP_COMMAND'] ?? '';
      final process = await Process.start(binary, args,
          mode: ProcessStartMode.inheritStdio,
          environment: {'CLIKGATE_SETUP_COMMAND': command.isEmpty ? defaultSetupCommand : command});
      subs.add(ProcessSignal.sigint.watch().listen((_) {}));
      if (!Platform.isWindows) {
        subs.add(ProcessSignal.sigterm.watch().listen((_) => process.kill(ProcessSignal.sigterm)));
      }
      return await process.exitCode;
    } on ProcessException catch (e) {
      log.writeln('Could not start the setup command ($binary): ${e.message}');
      return exitProblems;
    } finally {
      for (final s in subs) {
        await s.cancel();
      }
    }
  }

  Future<void> _printFailure(SetupRunnerException e, List<String> args) async {
    log.writeln(e.message);
    if (e.offerNode && await _nodeAvailable()) {
      final rest = args.isEmpty ? '' : ' ${args.map(_shellQuote).join(' ')}';
      log.writeln('Node.js is installed, so you can run the same setup command with it instead:');
      log.writeln('  npx @clikgate/setup@$version$rest');
    } else if (e.offerNode) {
      log.writeln('Set Clikgate up by hand instead: $manualStepsUrl');
    }
    log.writeln('Docs: $docsUrl');
  }
}

String _short(Object e) {
  final s = e is SocketException ? e.message : e.toString();
  final line = s.split('\n').first;
  return line.length > 200 ? '${line.substring(0, 200)}…' : line;
}

String _shellQuote(String a) => RegExp(r'^[A-Za-z0-9_./:=,@+-]+$').hasMatch(a) ? a : "'${a.replaceAll("'", r"'\''")}'";

Future<bool> _isNodeOnPath() async {
  try {
    final r = await Process.run(Platform.isWindows ? 'where' : 'which', ['node'], runInShell: Platform.isWindows);
    return r.exitCode == 0;
  } on Object {
    return false;
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

/// One line on a terminal (`\r` updates, at most every 1%), start and end lines otherwise.
class _Progress {
  _Progress(this.out, this.terminal, this.version, this.platform, this.total);
  final StringSink out;
  final bool terminal;
  final String version;
  final String platform;
  final int total;
  int _lastPercent = -1;

  String get _label => 'Downloading the Clikgate setup command $version ($platform${total > 0 ? ', ${mb(total)}' : ''}, once)';

  void start() {
    if (!terminal) out.writeln('$_label…');
  }

  void update(int received) {
    if (!terminal) return;
    final percent = total > 0 ? received * 100 ~/ total : -1;
    if (total > 0 && percent == _lastPercent) return;
    _lastPercent = percent;
    out.write('\r$_label… ${total > 0 ? '$percent%' : mb(received)}');
  }

  /// Clears the progress line; the runner prints "Downloaded and verified" once both checksums match.
  void done(int received) {
    if (terminal) out.write('\r\x1b[2K');
  }

  void fail() {
    if (terminal) out.writeln();
  }

  static String mb(int bytes) => '${(bytes / 1000000).toStringAsFixed(bytes < 10000000 ? 1 : 0)} MB';
}
