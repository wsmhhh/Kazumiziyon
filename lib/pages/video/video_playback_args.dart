import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/modules/local/local_video_module.dart';
import 'package:kazumi/modules/roads/road_module.dart';
import 'package:kazumi/plugins/plugins.dart';

/// Route arguments for '/video/'. Entry points hand playback context over
/// through the route instead of pre-filling a shared controller, which lets
/// [VideoPageController] live and die with the route.
sealed class VideoPlaybackArgs {
  const VideoPlaybackArgs({required this.bangumiItem});

  final BangumiItem bangumiItem;
}

class OnlineVideoPlaybackArgs extends VideoPlaybackArgs {
  const OnlineVideoPlaybackArgs({
    required super.bangumiItem,
    required this.plugin,
    required this.title,
    required this.src,
    required this.roads,
  });

  final Plugin plugin;
  final String title;
  final String src;
  final List<Road> roads;
}

class OfflineVideoPlaybackArgs extends VideoPlaybackArgs {
  const OfflineVideoPlaybackArgs({
    required super.bangumiItem,
    required this.pluginName,
    required this.episodeNumber,
    required this.road,
    required this.downloadedEpisodes,
  });

  final String pluginName;
  final int episodeNumber;
  final int road;
  final List<DownloadEpisode> downloadedEpisodes;
}

/// 用内置播放器播放用户选择的本地视频文件。
///
/// [bangumiItem] 只作为播放器内部的标识（弹幕检索历史、媒体会话等）使用；
/// 本地文件不会写入番剧观看历史。
class LocalVideoPlaybackArgs extends VideoPlaybackArgs {
  const LocalVideoPlaybackArgs({
    required super.bangumiItem,
    required this.playlistName,
    required this.files,
    this.startIndex = 0,
  });

  /// 播放列表标题，展示在选集面板和播放器标题栏。
  final String playlistName;

  /// 本地视频列表，顺序即剧集顺序。
  final List<LocalVideoEntry> files;

  /// 起播的列表下标（从 0 开始）。
  final int startIndex;
}
