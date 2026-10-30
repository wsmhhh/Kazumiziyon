import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:kazumi/services/bt/aria2_client.dart';
import 'package:kazumi/services/download/download_directory_service.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';

class Aria2EngineException implements Exception {
  const Aria2EngineException(this.message, {this.needsBinary = false});

  final String message;

  /// True when the failure is "aria2c is missing on this device", which the UI
  /// turns into setup guidance instead of a retry button.
  final bool needsBinary;

  @override
  String toString() => message;
}

/// Owns the local aria2c process and its JSON-RPC client.
///
/// The engine is deliberately a process rather than an FFI library: aria2
/// already implements BitTorrent, sequential piece selection (needed for
/// streaming a growing file) and DHT, so the app only supervises it.
class Aria2Engine {
  Aria2Engine();

  static const _androidChannel = MethodChannel('com.predidit.kazumi/bt');
  static const _startupTimeout = Duration(seconds: 20);

  Process? _process;
  Aria2Client? _client;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;
  final StringBuffer _recentLog = StringBuffer();

  int? _rpcPort;
  int? _listenPort;
  String? _binaryPath;
  bool _starting = false;

  bool get isRunning => _client != null && _process != null;
  Aria2Client? get client => _client;
  int? get rpcPort => _rpcPort;
  int? get listenPort => _listenPort;
  String? get binaryPath => _binaryPath;

  /// Starts aria2c if it is not running yet and returns a ready client.
  Future<Aria2Client> ensureStarted() async {
    final existing = _client;
    if (existing != null && _process != null) {
      return existing;
    }
    if (_starting) {
      throw const Aria2EngineException('BT 引擎正在启动，请稍候');
    }
    _starting = true;
    try {
      return await _start();
    } finally {
      _starting = false;
    }
  }

  Future<Aria2Client> _start() async {
    final binary = await _resolveBinary();
    final downloadDir = await DownloadDirectoryService().getDownloadDirectory();
    await Directory(downloadDir).create(recursive: true);

    final rpcPort = await _findFreePort();
    final listenPort = await _findFreePort(excluding: rpcPort);
    final secret = _randomSecret();
    final maxConcurrent = GStorage.getSetting(SettingsKeys.btMaxConcurrent);
    final extraArgs = GStorage.getSetting(SettingsKeys.btAria2Args).trim();

    final args = <String>[
      '--enable-rpc=true',
      '--rpc-listen-all=false',
      '--rpc-listen-port=$rpcPort',
      '--rpc-secret=$secret',
      '--rpc-max-request-size=16M',
      '--dir=$downloadDir',
      '--continue=true',
      '--file-allocation=none',
      '--seed-time=0',
      '--bt-save-metadata=true',
      '--bt-remove-unselected-file=false',
      '--enable-dht=true',
      // Android has no /etc/resolv.conf; c-ares needs explicit DNS servers or
      // tracker hostnames never resolve.
      if (Platform.isAndroid) '--async-dns-server=223.5.5.5,1.1.1.1',
      '--dht-listen-port=$listenPort',
      '--listen-port=$listenPort',
      '--max-concurrent-downloads=$maxConcurrent',
      '--summary-interval=0',
      '--console-log-level=warn',
      if (extraArgs.isNotEmpty) ..._splitArgs(extraArgs),
    ];

    KazumiLogger().i('Aria2: starting $binary ${args.join(' ')}');
    _recentLog.clear();

    final Process process;
    try {
      process = await Process.start(
        binary,
        args,
        workingDirectory: downloadDir,
        runInShell: false,
      );
    } on ProcessException catch (e) {
      throw Aria2EngineException(
        '无法启动 aria2：${e.message}${e.message.contains('Permission') ? '（请确认可执行文件已打包为 libaria2c.so）' : ''}',
        needsBinary: true,
      );
    }

    _process = process;
    _binaryPath = binary;
    _rpcPort = rpcPort;
    _listenPort = listenPort;

    _stdoutSub = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(_recordLog);
    _stderrSub = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(_recordLog);

    final exitCode = process.exitCode.then((code) {
      KazumiLogger().w('Aria2: process exited with code $code');
      _process = null;
      _client = null;
    });
    // Avoid unawaited() noise; exitCode is also observed while waiting.
    unawaited(exitCode);

    final client = Aria2Client(port: rpcPort, secret: secret);
    final ready = await _waitUntilReady(client, process);
    if (!ready) {
      _client = null;
      final detail = _recentLog.toString().trim();
      _killProcess();
      throw Aria2EngineException(
        'aria2 启动超时${detail.isEmpty ? '' : '：$detail'}',
        needsBinary: detail.contains('No such file'),
      );
    }

    _client = client;
    KazumiLogger().i('Aria2: ready on 127.0.0.1:$rpcPort');
    return client;
  }

  Future<bool> _waitUntilReady(Aria2Client client, Process process) async {
    final deadline = DateTime.now().add(_startupTimeout);
    while (DateTime.now().isBefore(deadline)) {
      // The process dying is the usual failure mode for a wrong binary.
      try {
        if (await process.exitCode.timeout(
              const Duration(milliseconds: 1),
              onTimeout: () => -1,
            ) !=
            -1) {
          return false;
        }
      } on TimeoutException {
        // Still running.
      }
      try {
        await client.getVersion();
        return true;
      } on Aria2Exception {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
    return false;
  }

  Future<String> _resolveBinary() async {
    final configured = GStorage.getSetting(SettingsKeys.btAria2Path).trim();
    if (configured.isNotEmpty) {
      final file = File(configured);
      if (await file.exists()) return configured;
      throw Aria2EngineException('设置的 aria2 路径不存在：$configured', needsBinary: true);
    }

    if (Platform.isAndroid) {
      final dir = await _androidNativeLibraryDir();
      if (dir != null) {
        final bundled = '$dir/libaria2c.so';
        if (await File(bundled).exists()) return bundled;
      }
      throw const Aria2EngineException(
        '未找到内置 aria2 引擎。请将 aria2c 以 libaria2c.so 的名称放入 '
        'android/app/src/main/jniLibs/<abi>/ 后重新构建，或在设置中指定可执行文件路径。',
        needsBinary: true,
      );
    }

    for (final candidate in _desktopCandidates()) {
      if (await File(candidate).exists()) return candidate;
    }
    throw const Aria2EngineException(
      '未找到 aria2c。请安装 aria2，或在 BT 设置中指定 aria2c 可执行文件路径。',
      needsBinary: true,
    );
  }

  Iterable<String> _desktopCandidates() sync* {
    final executableDir = File(Platform.resolvedExecutable).parent.path;
    final sep = Platform.pathSeparator;
    if (Platform.isWindows) {
      yield '$executableDir${sep}aria2c.exe';
      yield '${Directory.current.path}${sep}aria2c.exe';
    } else {
      yield '$executableDir${sep}aria2c';
      yield '/usr/bin/aria2c';
      yield '/usr/local/bin/aria2c';
      yield '/opt/homebrew/bin/aria2c';
    }
  }

  Future<String?> _androidNativeLibraryDir() async {
    try {
      return await _androidChannel.invokeMethod<String>('getNativeLibraryDir');
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      KazumiLogger().e('Aria2: failed to read nativeLibraryDir', error: e);
      return null;
    }
  }

  Future<int> _findFreePort({int? excluding}) async {
    for (var attempt = 0; attempt < 10; attempt++) {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      if (port != excluding) return port;
    }
    throw const Aria2EngineException('无法分配本地端口');
  }

  String _randomSecret() {
    final random = Random.secure();
    return List.generate(16, (_) => random.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  void _recordLog(String line) {
    if (line.trim().isEmpty) return;
    _recentLog.writeln(line);
    final lines = _recentLog.toString().split('\n');
    if (lines.length > 40) {
      _recentLog.clear();
      _recentLog.write(lines.sublist(lines.length - 40).join('\n'));
    }
    KazumiLogger().i('Aria2: $line');
  }

  Future<void> stop() async {
    final client = _client;
    if (client != null) {
      try {
        await client.shutdown();
      } catch (_) {
        // Process may already be gone; killing below is the fallback.
      }
    }
    _client = null;
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    _stdoutSub = null;
    _stderrSub = null;

    final process = _process;
    if (process != null) {
      final exited = await process.exitCode
          .timeout(const Duration(seconds: 3), onTimeout: () => -1);
      if (exited == -1) {
        _killProcess();
      }
    }
    _process = null;
    KazumiLogger().i('Aria2: stopped');
  }

  void _killProcess() {
    try {
      _process?.kill(ProcessSignal.sigkill);
    } catch (_) {
      // Best effort.
    }
  }

  /// Splits a user-supplied boolean/string option string, honouring quotes.
  List<String> _splitArgs(String raw) {
    final result = <String>[];
    final buffer = StringBuffer();
    String? quote;
    for (var i = 0; i < raw.length; i++) {
      final char = raw[i];
      if (quote != null) {
        if (char == quote) {
          quote = null;
        } else {
          buffer.write(char);
        }
        continue;
      }
      if (char == '"' || char == "'") {
        quote = char;
      } else if (char == ' ') {
        if (buffer.isNotEmpty) {
          result.add(buffer.toString());
          buffer.clear();
        }
      } else {
        buffer.write(char);
      }
    }
    if (buffer.isNotEmpty) result.add(buffer.toString());
    return result;
  }
}
