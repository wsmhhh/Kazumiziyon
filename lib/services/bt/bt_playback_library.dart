import 'dart:io';

import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/bt/bt_task.dart';
import 'package:kazumi/modules/bt/release_title.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/services/bt/bt_download_controller.dart';
import 'package:path/path.dart' as p;

/// One playable BT video file, normalized into an episode.
class BtPlayableEpisode {
  const BtPlayableEpisode({
    required this.episode,
    required this.path,
    required this.length,
    required this.gid,
    required this.taskName,
    required this.progress,
    required this.complete,
  });

  final int episode;
  final String path;
  final int length;
  final String gid;
  final String taskName;
  final double progress;
  final bool complete;

  String get displayName => '第 $episode 集';
}

/// Bridges BitTorrent downloads into the app's existing offline playback path.
///
/// Tasks are matched to a bangumi by title (Chinese/Japanese/English names and
/// aliases), video files are sorted into episodes, and the result is converted
/// into [DownloadEpisode]s so the original player, its danmaku and history all
/// work unchanged.
class BtPlaybackLibrary {
  const BtPlaybackLibrary();

  /// Shown as the source name in the player-source panel and in history.
  static const String sourceName = 'BT 下载';

  static const int _minVideoBytes = 10 * 1024 * 1024;

  List<BtPlayableEpisode> episodesFor(
    BangumiItem item, {
    List<BtTask>? tasks,
  }) {
    final names = _matchNames(item);
    if (names.isEmpty) return const [];

    final allTasks = tasks ?? BtDownloadController().allTasks;
    final byEpisode = <int, BtPlayableEpisode>{};

    for (final task in allTasks) {
      if (!_matchesTask(task, names)) continue;
      final files = task.files.where(_isCandidateFile).toList()..sort(_compareFiles);
      if (files.isEmpty) continue;

      var fallbackEpisode = 0;
      for (final file in files) {
        final path = file.resolvePath(task.directory);
        if (!File(path).existsSync()) continue;

        var episode = parseReleaseTitle(p.basename(path)).episode;
        if (episode <= 0) {
          episode = parseReleaseTitle(task.displayName).episode;
        }
        if (episode <= 0) {
          fallbackEpisode += 1;
          episode = fallbackEpisode;
        } else if (episode > fallbackEpisode) {
          fallbackEpisode = episode;
        }

        final candidate = BtPlayableEpisode(
          episode: episode,
          path: path,
          length: file.length,
          gid: task.gid,
          taskName: task.displayName,
          progress: file.progress,
          complete: task.isComplete || file.progress >= 1,
        );
        final existing = byEpisode[episode];
        if (existing == null ||
            candidate.progress > existing.progress ||
            (candidate.progress == existing.progress &&
                candidate.length > existing.length)) {
          byEpisode[episode] = candidate;
        }
      }
    }

    final result = byEpisode.values.toList()
      ..sort((a, b) => a.episode.compareTo(b.episode));
    return result;
  }

  List<DownloadEpisode> toDownloadEpisodes(
    List<BtPlayableEpisode> episodes,
  ) {
    return [
      for (final item in episodes)
        DownloadEpisode(
          item.episode,
          item.displayName,
          0,
          DownloadStatus.completed,
          item.progress,
          1,
          1,
          item.path,
          p.dirname(item.path),
          '',
          DateTime.now(),
          '',
          item.length,
          '',
        ),
    ];
  }

  List<String> _matchNames(BangumiItem item) {
    final normalized = <String>{};
    for (final name in [item.nameCn, item.name, ...item.alias]) {
      final value = _normalize(name);
      if (value.length < 2) continue;
      // A purely numeric title ("86") would match almost any release name.
      if (RegExp(r'^\d+$').hasMatch(value)) continue;
      normalized.add(value);
    }
    return normalized.toList(growable: false);
  }

  bool _matchesTask(BtTask task, List<String> names) {
    final haystack = _normalize(
      '${task.displayName} ${task.files.map((file) => file.path).join(' ')}',
    );
    if (haystack.isEmpty) return false;
    return names.any(haystack.contains);
  }

  bool _isCandidateFile(BtFile file) {
    if (!file.isVideo || !file.selected) return false;
    if (file.length > 0 && file.length < _minVideoBytes) return false;
    return !p.basename(file.path).toLowerCase().contains('sample');
  }

  int _compareFiles(BtFile a, BtFile b) {
    final left = _fileSortNumber(a);
    final right = _fileSortNumber(b);
    if (left != right) return left.compareTo(right);
    return a.path.compareTo(b.path);
  }

  int _fileSortNumber(BtFile file) {
    final name = p.basename(file.path);
    final parsed = parseReleaseTitle(name).episode;
    if (parsed > 0) return parsed;
    final match = RegExp(r'(\d{1,4})').firstMatch(name);
    final value = int.tryParse(match?.group(1) ?? '');
    return value ?? 9999;
  }

  String _normalize(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[^0-9a-z一-鿿぀-ヿ]'), '');
}
