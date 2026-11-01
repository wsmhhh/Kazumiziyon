import 'dart:async';
import 'dart:convert';

import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';

class _LocalVideoProgress {
  const _LocalVideoProgress({
    required this.positionSeconds,
    required this.durationSeconds,
    required this.updatedAtMs,
  });

  final int positionSeconds;
  final int durationSeconds;
  final int updatedAtMs;
}

/// 按文件路径记录本地视频的播放位置，用于断点续播。
///
/// 记录保存在设置项 [SettingsKeys.localVideoProgress] 中，不写入番剧观看历史，
/// 因此不会污染历史列表。播放器每秒调用 [save]，但最多每 5 秒落盘一次。
class LocalVideoProgressStore {
  LocalVideoProgressStore._();

  static final LocalVideoProgressStore instance = LocalVideoProgressStore._();

  static const Duration _writeInterval = Duration(seconds: 5);
  static const Duration _flushDelay = Duration(seconds: 2);
  static const Duration _nearEndWindow = Duration(seconds: 10);
  static const int _maxEntries = 300;

  final Map<String, _LocalVideoProgress> _entries = {};
  final Map<String, DateTime> _lastWriteAt = {};
  bool _loaded = false;
  bool _dirty = false;
  Timer? _flushTimer;

  /// 读取某个文件的续播位置；没有记录或已接近结尾时返回 0。
  Duration positionFor(String path) {
    if (path.isEmpty) {
      return Duration.zero;
    }
    _ensureLoaded();
    final entry = _entries[path];
    if (entry == null) {
      return Duration.zero;
    }
    final position = Duration(seconds: entry.positionSeconds);
    final duration = Duration(seconds: entry.durationSeconds);
    if (duration > Duration.zero && position >= duration - _nearEndWindow) {
      return Duration.zero;
    }
    return position;
  }

  /// 保存播放位置。[force] 为 true 时立即落盘（切换剧集、退出播放页）。
  void save(
    String path,
    Duration position, {
    required Duration duration,
    bool force = false,
  }) {
    if (path.isEmpty || position <= Duration.zero) {
      return;
    }
    _ensureLoaded();
    if (duration > Duration.zero && position >= duration - _nearEndWindow) {
      // 已接近结尾，下次从头播放。
      if (_entries.remove(path) != null) {
        _dirty = true;
      }
    } else {
      _entries[path] = _LocalVideoProgress(
        positionSeconds: position.inSeconds,
        durationSeconds: duration.inSeconds,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      _dirty = true;
    }

    final now = DateTime.now();
    final lastWriteAt = _lastWriteAt[path];
    if (!force &&
        lastWriteAt != null &&
        now.difference(lastWriteAt) < _writeInterval) {
      return;
    }
    _lastWriteAt[path] = now;
    if (force) {
      unawaited(flush());
    } else {
      _scheduleFlush();
    }
  }

  /// 删除某个文件的记录（文件被移动或删除时使用）。
  void remove(String path) {
    _ensureLoaded();
    if (_entries.remove(path) != null) {
      _dirty = true;
      _scheduleFlush();
    }
  }

  Future<void> flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (!_loaded || !_dirty) {
      return;
    }
    _dirty = false;
    _prune();
    _lastWriteAt.removeWhere((key, _) => !_entries.containsKey(key));
    final payload = <String, Map<String, int>>{
      for (final entry in _entries.entries)
        entry.key: {
          'p': entry.value.positionSeconds,
          'd': entry.value.durationSeconds,
          't': entry.value.updatedAtMs,
        },
    };
    try {
      await GStorage.putSetting(
        SettingsKeys.localVideoProgress,
        jsonEncode(payload),
      );
    } catch (error) {
      _dirty = true;
      KazumiLogger().w(
        'LocalVideoProgressStore: failed to persist progress',
        error: error,
      );
    }
  }

  void _scheduleFlush() {
    _flushTimer?.cancel();
    _flushTimer = Timer(_flushDelay, () {
      _flushTimer = null;
      unawaited(flush());
    });
  }

  void _ensureLoaded() {
    if (_loaded) {
      return;
    }
    _loaded = true;
    try {
      final raw = GStorage.getSetting(SettingsKeys.localVideoProgress);
      if (raw.isEmpty) {
        return;
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return;
      }
      decoded.forEach((key, value) {
        if (key is! String || value is! Map) {
          return;
        }
        final position = value['p'];
        final duration = value['d'];
        final updatedAt = value['t'];
        if (position is! int || duration is! int) {
          return;
        }
        _entries[key] = _LocalVideoProgress(
          positionSeconds: position,
          durationSeconds: duration,
          updatedAtMs: updatedAt is int ? updatedAt : 0,
        );
      });
    } catch (error) {
      KazumiLogger().w(
        'LocalVideoProgressStore: failed to read progress',
        error: error,
      );
    }
  }

  void _prune() {
    if (_entries.length <= _maxEntries) {
      return;
    }
    final ordered = _entries.entries.toList()
      ..sort((a, b) => a.value.updatedAtMs.compareTo(b.value.updatedAtMs));
    final removeCount = _entries.length - _maxEntries;
    for (var index = 0; index < removeCount; index++) {
      final key = ordered[index].key;
      _entries.remove(key);
      _lastWriteAt.remove(key);
    }
  }
}
