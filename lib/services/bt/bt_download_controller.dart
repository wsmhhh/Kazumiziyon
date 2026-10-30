import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:kazumi/modules/bt/bt_task.dart';
import 'package:kazumi/services/bt/aria2_client.dart';
import 'package:kazumi/services/bt/aria2_engine.dart';
import 'package:kazumi/services/logging/logger.dart';

/// App-wide BitTorrent state. Registered as a singleton in [coreModule].
///
/// The class is a plain [ChangeNotifier] rather than a MobX store because its
/// observable shape is replaced wholesale every second by the aria2 poll.
class BtDownloadController extends ChangeNotifier {
  BtDownloadController._();

  static final BtDownloadController _instance = BtDownloadController._();

  factory BtDownloadController() => _instance;

  final Aria2Engine engine = Aria2Engine();

  /// Torrent files are fetched by Dart rather than aria2: Android builds of
  /// aria2 often have no CA bundle, while Dio uses the system trust store.
  final Dio _torrentDio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 20),
    receiveTimeout: const Duration(seconds: 60),
    headers: const {
      'User-Agent':
          'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Kazumi',
    },
  ));

  Timer? _pollTimer;
  bool _starting = false;
  bool _refreshing = false;
  bool _disposed = false;

  bool get isEngineRunning => engine.isRunning;
  bool get isStarting => _starting;
  String? lastError;

  List<BtTask> downloading = const [];
  List<BtTask> completed = const [];

  /// Last known tasks, including ones from a previous app session.
  List<BtTask> cachedTasks = const [];
  bool _cacheLoaded = false;
  String? _persistedSignature;
  int downloadSpeed = 0;
  int uploadSpeed = 0;
  int freePort = 0;
  String aria2Version = '';

  List<BtTask> get activeTasks =>
      downloading.where((task) => !task.isPaused).toList(growable: false);

  /// All known tasks (live when the engine is running, otherwise the cached
  /// snapshot). Used by the source panel and history restore.
  List<BtTask> get allTasks {
    if (!_cacheLoaded) {
      // The cache is normally loaded during startup; this keeps a very early
      // call from silently seeing an empty library.
      unawaited(loadCache());
    }
    return cachedTasks;
  }

  Future<void> loadCache() async {
    if (_cacheLoaded) return;
    _cacheLoaded = true;
    try {
      final raw = GStorage.btTasks.get('tasks');
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      cachedTasks = [
        for (final item in decoded)
          if (item is Map) BtTask.fromJson(Map<String, dynamic>.from(item)),
      ];
      _notify();
    } catch (e) {
      KazumiLogger().w('BT: failed to read task cache', error: e);
    }
  }

  void _persistTasks(List<BtTask> tasks) {
    final signature = tasks
        .map((task) =>
            '${task.gid}|${task.status}|${task.name}|${task.completedLength ~/ (50 * 1024 * 1024)}|'
            '${task.files.map((file) => '${file.index}:${file.path}:${file.length}').join(',')}')
        .join(';');
    if (signature == _persistedSignature) return;
    _persistedSignature = signature;
    try {
      final payload = jsonEncode(tasks.map((task) => task.toJson()).toList());
      unawaited(
        GStorage.btTasks.put('tasks', payload).catchError((Object _) {}),
      );
    } catch (e) {
      KazumiLogger().w('BT: failed to persist task cache', error: e);
    }
  }

  Future<void> startEngine() async {
    // RSS auto-download can start the process without the BT page being open;
    // opening the page afterwards must still attach the poll loop.
    if (engine.isRunning) {
      if (_pollTimer == null) {
        _startPolling();
        await refreshNow();
      }
      return;
    }
    if (_starting) return;
    _starting = true;
    lastError = null;
    _notify();
    try {
      final client = await engine.ensureStarted();
      aria2Version = await client.getVersion();
      freePort = engine.listenPort ?? 0;
      await client.changeGlobalOption({
        'max-overall-download-limit': '0',
        'max-overall-upload-limit': '0',
      });
      _startPolling();
      await refreshNow();
    } on Aria2EngineException catch (e) {
      lastError = e.message;
      KazumiLogger().e('BT: engine start failed', error: e);
    } catch (e) {
      lastError = 'BT 引擎启动失败：$e';
      KazumiLogger().e('BT: engine start failed', error: e);
    } finally {
      _starting = false;
      _notify();
    }
  }

  Future<void> stopEngine() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    await engine.stop();
    downloading = const [];
    completed = const [];
    downloadSpeed = 0;
    uploadSpeed = 0;
    aria2Version = '';
    _notify();
  }

  Future<void> restartEngine() async {
    await stopEngine();
    await startEngine();
  }

  void _startPolling() {
    // Keep polling even when the BT page is closed: the snapshots feed the
    // anime source panel and history restore. Four loopback RPC calls every
    // two seconds are negligible next to the download itself.
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) => refreshNow());
  }

  void stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> refreshNow() async {
    final client = engine.client;
    if (client == null || _refreshing) return;
    _refreshing = true;
    try {
      final results = await Future.wait<dynamic>([
        client.tellActive(),
        client.tellWaiting(0, 100),
        client.tellStopped(0, 100),
        client.getGlobalStat(),
      ]);
      if (_disposed) return;
      final active = results[0] as List<BtTask>;
      final waiting = results[1] as List<BtTask>;
      final stopped = results[2] as List<BtTask>;
      final stats = results[3] as Map<String, dynamic>;

      final unfinished = <BtTask>[
        ...active,
        ...waiting,
        // Paused tasks live in the stopped list; keep them next to running
        // ones so the user can resume them without a second section.
        ...stopped.where((task) => task.isPaused),
      ];
      unfinished.sort((a, b) => a.isPaused == b.isPaused
          ? a.displayName.compareTo(b.displayName)
          : (a.isPaused ? 1 : -1));

      downloading = unfinished;
      completed = stopped.where((task) => !task.isPaused).toList()
        ..sort((a, b) => b.completedLength.compareTo(a.completedLength));
      downloadSpeed = _asInt(stats['downloadSpeed']);
      uploadSpeed = _asInt(stats['uploadSpeed']);
      cachedTasks = [...unfinished, ...completed];
      _persistTasks(cachedTasks);
      lastError = null;
      _notify();
    } catch (e) {
      // A single transient RPC failure must not tear down the UI.
      if (!engine.isRunning) {
        lastError = 'BT 引擎已停止';
        _notify();
      }
      KazumiLogger().w('BT: poll failed: $e');
    } finally {
      _refreshing = false;
    }
  }

  Future<String?> addUri(String uri) async {
    return _guard(() async {
      final client = await engine.ensureStarted();
      _ensurePolling();
      final gid = await client.addUri([uri], options: _streamingOptions());
      await refreshNow();
      return gid;
    });
  }

  /// Accepts a magnet link or an HTTP(S) `.torrent` URL.
  Future<String?> addDownloadUri(String uri) {
    if (uri.startsWith('magnet:')) {
      return addUri(uri);
    }
    return addTorrentUrl(uri);
  }

  Future<String?> addTorrentUrl(String url) async {
    return _guard(() async {
      final bytes = await _downloadTorrent(url);
      final client = await engine.ensureStarted();
      _ensurePolling();
      final gid = await client.addTorrent(
        base64Encode(bytes),
        options: _streamingOptions(),
      );
      await refreshNow();
      return gid;
    });
  }

  Future<List<int>> _downloadTorrent(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) {
      throw const Aria2Exception('种子地址格式不正确');
    }
    final response = await _torrentDio.get<List<int>>(
      url,
      options: Options(responseType: ResponseType.bytes),
    );
    final bytes = response.data;
    if (bytes == null || bytes.isEmpty) {
      throw const Aria2Exception('种子文件下载失败：内容为空');
    }
    if (bytes.length > 32 * 1024 * 1024) {
      throw const Aria2Exception('链接返回的内容过大，可能不是种子文件');
    }
    // Benign HTML error pages are the most common failure mode for expired
    // links; a real torrent is bencoded and starts with 'd'.
    if (bytes.isNotEmpty && bytes[0] == 0x3C) {
      throw const Aria2Exception('链接返回的是网页而不是种子文件，可能已失效');
    }
    return bytes;
  }

  Future<String?> addTorrentFile(String filePath) async {
    return _guard(() async {
      final file = File(filePath);
      if (!await file.exists()) {
        throw const Aria2Exception('种子文件不存在');
      }
      final raw = await file.readAsBytes();
      final client = await engine.ensureStarted();
      _ensurePolling();
      final gid = await client.addTorrent(
        base64Encode(raw),
        options: _streamingOptions(),
      );
      await refreshNow();
      return gid;
    });
  }

  void _ensurePolling() {
    if (_pollTimer == null) _startPolling();
  }

  Future<void> pause(BtTask task) async {
    await _run((client) => client.forcePause(task.gid));
    await refreshNow();
  }

  Future<void> resume(BtTask task) async {
    await _run((client) => client.unpause(task.gid));
    await refreshNow();
  }

  Future<void> removeTask(BtTask task) async {
    await _run((client) async {
      try {
        await client.remove(task.gid);
      } catch (_) {
        // Completed tasks can only be removed from the result list.
      }
      try {
        await client.removeDownloadResult(task.gid);
      } catch (_) {
        // Already gone.
      }
    });
    await refreshNow();
  }

  /// aria2 has no "open folder" RPC; expose the directory for the UI instead.
  String? directoryOf(BtTask task) =>
      task.directory.isNotEmpty ? task.directory : null;

  Future<String?> _guard(Future<String?> Function() action) async {
    try {
      lastError = null;
      final result = await action();
      _notify();
      return result;
    } on Aria2EngineException catch (e) {
      lastError = e.message;
      _notify();
      return null;
    } on Aria2Exception catch (e) {
      lastError = e.message;
      _notify();
      return null;
    } catch (e) {
      lastError = 'BT 操作失败：$e';
      KazumiLogger().e('BT: action failed', error: e);
      _notify();
      return null;
    }
  }

  Future<void> _run(Future<void> Function(Aria2Client client) action) async {
    final client = engine.client;
    if (client == null) {
      lastError = 'BT 引擎未启动';
      _notify();
      return;
    }
    try {
      await action(client);
      lastError = null;
    } on Aria2Exception catch (e) {
      lastError = e.message;
      KazumiLogger().e('BT: RPC action failed', error: e);
    }
    _notify();
  }

  /// Sequential piece selection plus head-first prioritisation is what makes
  /// "play while downloading" usable: mpv reads the start of the file first.
  Map<String, String> _streamingOptions() => {
        'stream-piece-selector': 'inorder',
        'bt-prioritize-piece': 'head',
        'seed-time': '0',
        'continue': 'true',
      };

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _pollTimer?.cancel();
    super.dispose();
  }

  static int _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}
