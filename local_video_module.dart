/// 本地播放列表中的一个视频文件。
class LocalVideoEntry {
  const LocalVideoEntry({
    required this.path,
    required this.title,
  });

  /// 视频文件的绝对路径。
  final String path;

  /// 剧集列表中显示的名称，通常是去掉扩展名的文件名。
  final String title;

  @override
  String toString() => 'LocalVideoEntry(path: $path, title: $title)';
}
