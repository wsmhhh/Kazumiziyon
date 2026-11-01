import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:path/path.dart' as path;

import 'package:kazumi/bean/dialog/adaptive_bottom_sheet.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/local/local_video_module.dart';
import 'package:kazumi/pages/video/video_playback_args.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/player/local_video_library.dart';
import 'package:kazumi/utils/device.dart';

enum _LocalVideoSource { files, folder }

/// 让用户选择本地视频（多选文件或整个文件夹），然后用内置播放器打开。
Future<void> pickAndOpenLocalVideos(BuildContext context) async {
  final source = await showAdaptiveBottomSheet<_LocalVideoSource>(
    context: context,
    builder: (sheetContext) => const _LocalVideoSourceSheet(),
  );
  if (source == null || !context.mounted) {
    return;
  }
  switch (source) {
    case _LocalVideoSource.files:
      await _pickLocalVideoFiles(context);
    case _LocalVideoSource.folder:
      await _pickLocalVideoFolder(context);
  }
}

Future<void> _pickLocalVideoFiles(BuildContext context) async {
  FilePickerResult? result;
  try {
    final extensions = localVideoExtensions.toList()..sort();
    result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: extensions,
      dialogTitle: '选择本地视频',
    );
  } catch (error) {
    KazumiLogger().w('LocalVideoPicker: failed to pick files', error: error);
    KazumiDialog.showToast(message: '打开文件选择器失败');
    return;
  }
  if (result == null) {
    return;
  }
  final paths = [
    for (final file in result.files)
      if (file.path != null && file.path!.isNotEmpty) file.path!,
  ];
  if (paths.isEmpty) {
    return;
  }
  paths.sort(compareLocalVideoNames);
  if (!context.mounted) {
    return;
  }
  openLocalVideoPlaylist(
    context,
    buildLocalVideoEntries(paths),
    playlistName: localPlaylistName(paths),
  );}

Future<void> _pickLocalVideoFolder(BuildContext context) async {
  String? directory;
  try {
    directory = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择视频文件夹',
    );
  } catch (error) {
    KazumiLogger().w('LocalVideoPicker: failed to pick folder', error: error);
    KazumiDialog.showToast(message: '打开文件夹选择器失败');
    return;
  }
  if (directory == null || directory.isEmpty) {
    return;
  }
  final entries = await scanLocalVideoDirectory(directory);
  if (entries.isEmpty) {
    KazumiDialog.showToast(message: '该文件夹中没有找到视频文件');
    return;
  }
  if (!context.mounted) {
    return;
  }
  final folderName = path.basename(directory);
  openLocalVideoPlaylist(
    context,
    entries,
    playlistName: folderName.isEmpty ? '本地播放' : folderName,
  );
}

/// 用内置播放器打开一组本地视频。[startIndex] 是起播的列表下标。
void openLocalVideoPlaylist(
  BuildContext context,
  List<LocalVideoEntry> files, {
  required String playlistName,
  int startIndex = 0,
}) {
  if (files.isEmpty) {
    KazumiDialog.showToast(message: '没有可播放的视频文件');
    return;
  }
  context.pushNamed(
    '/video/',
    arguments: LocalVideoPlaybackArgs(
      bangumiItem: localVideoBangumiItem(
        playlistName: playlistName,
        files: files,
      ),
      playlistName: playlistName,
      files: files,
      startIndex: startIndex,
    ),
  );
}

/// 为本地播放列表构造一个只用于播放器内部的番剧条目。
///
/// ID 取负值并基于文件名哈希，避免与 Bangumi 的真实条目冲突；该条目不会
/// 写入收藏或观看历史。
BangumiItem localVideoBangumiItem({
  required String playlistName,
  required List<LocalVideoEntry> files,
}) {
  final seed = files.isEmpty ? playlistName : files.first.path;
  final name = playlistName.isEmpty ? '本地播放' : playlistName;
  return BangumiItem(
    id: -_stableLocalVideoId(seed),
    type: 2,
    name: name,
    nameCn: name,
    summary: '',
    airDate: '',
    airWeekday: 0,
    rank: 0,
    images: const {},
    tags: const [],
    alias: const [],
    ratingScore: 0.0,
    votes: 0,
    votesCount: const [],
    info: '',
  );
}

int _stableLocalVideoId(String seed) {
  var hash = 0x811c9dc5;
  for (final codeUnit in seed.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return (hash & 0x7FFFFFFF) + 1;
}

class _LocalVideoSourceSheet extends StatelessWidget {
  const _LocalVideoSourceSheet();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
          child: Text(
            '本地播放',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
              color: colors.onSurface,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
          child: Text(
            '选择视频文件或整个文件夹，用内置播放器播放',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
        ),
        _SourceTile(
          icon: Icons.movie_outlined,
          title: '选择视频文件',
          subtitle: '可多选，按文件名顺序连播',
          onTap: () => Navigator.of(context).pop(_LocalVideoSource.files),
        ),
        if (isDesktop())
          _SourceTile(
            icon: Icons.folder_open_rounded,
            title: '选择文件夹',
            subtitle: '自动扫描文件夹中的视频',
            onTap: () => Navigator.of(context).pop(_LocalVideoSource.folder),
          ),
      ],
    );
  }
}

class _SourceTile extends StatelessWidget {
  const _SourceTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: colors.surfaceContainerLow,
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: onTap,
        leading: Icon(icon, color: colors.primary),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right_rounded),
      ),
    );
  }
}
