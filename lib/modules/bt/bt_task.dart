import 'dart:io';

/// One file inside a BitTorrent download.
class BtFile {
  const BtFile({
    required this.index,
    required this.path,
    required this.length,
    required this.completedLength,
    this.selected = true,
  });

  /// aria2 file index (1-based).
  final int index;
  final String path;
  final int length;
  final int completedLength;
  final bool selected;

  bool get isVideo => _videoExtensions.any(path.toLowerCase().endsWith);

  double get progress =>
      length <= 0 ? 0 : (completedLength / length).clamp(0.0, 1.0).toDouble();

  /// aria2 reports paths relative to the download directory only when it
  /// cannot resolve them; normalize both cases before touching the filesystem.
  String resolvePath(String downloadDir) =>
      File(path).isAbsolute ? path : '$downloadDir${Platform.pathSeparator}$path';

  static const _videoExtensions = [
    '.mp4',
    '.mkv',
    '.webm',
    '.avi',
    '.mov',
    '.m4v',
    '.ts',
    '.flv',
    '.wmv',
  ];

  factory BtFile.fromJson(Map<String, dynamic> json) {
    return BtFile(
      index: _asInt(json['index']),
      path: json['path']?.toString() ?? '',
      length: _asInt(json['length']),
      completedLength: _asInt(json['completedLength']),
      selected: json['selected']?.toString() != 'false',
    );
  }

  Map<String, dynamic> toJson() => {
        'index': index,
        'path': path,
        'length': length,
        'completedLength': completedLength,
        'selected': selected,
      };
}

/// A BitTorrent task as reported by aria2.
class BtTask {
  const BtTask({
    required this.gid,
    required this.status,
    required this.name,
    required this.totalLength,
    required this.completedLength,
    required this.downloadSpeed,
    required this.uploadSpeed,
    required this.connections,
    required this.directory,
    required this.files,
    this.errorMessage = '',
    this.bittorrentName = '',
    this.followedBy = const [],
  });

  final String gid;

  /// active / waiting / paused / error / complete / removed
  final String status;
  final String name;
  final int totalLength;
  final int completedLength;
  final int downloadSpeed;
  final int uploadSpeed;
  final int connections;
  final String directory;
  final List<BtFile> files;
  final String errorMessage;
  final String bittorrentName;
  final List<String> followedBy;

  bool get isActive => status == 'active' || status == 'waiting';

  bool get isPaused => status == 'paused';

  bool get isComplete => status == 'complete';

  bool get isFailed => status == 'error' || status == 'removed';

  bool get isMetadata => bittorrentName.isEmpty && status == 'active';

  bool get isUnfinished => !isComplete && !isFailed;

  double get progress =>
      totalLength <= 0
          ? 0
          : (completedLength / totalLength).clamp(0.0, 1.0).toDouble();

  String get displayName =>
      name.isNotEmpty ? name : (bittorrentName.isNotEmpty ? bittorrentName : gid);

  /// Picks the largest playable file so multi-file torrents open the episode
  /// instead of a sample or a subtitle.
  BtFile? get primaryVideoFile {
    BtFile? best;
    for (final file in files) {
      if (!file.isVideo || !file.selected) continue;
      if (best == null || file.length > best.length) {
        best = file;
      }
    }
    return best;
  }

  String? get videoPath {
    final file = primaryVideoFile;
    if (file == null) return null;
    return file.resolvePath(directory);
  }

  factory BtTask.fromJson(Map<String, dynamic> json) {
    final files = <BtFile>[];
    final rawFiles = json['files'];
    if (rawFiles is List) {
      for (final raw in rawFiles) {
        if (raw is Map) {
          files.add(BtFile.fromJson(Map<String, dynamic>.from(raw)));
        }
      }
    }
    final bittorrent = json['bittorrent'];
    return BtTask(
      gid: json['gid']?.toString() ?? '',
      status: json['status']?.toString() ?? 'unknown',
      name: json['name']?.toString() ?? '',
      totalLength: _asInt(json['totalLength']),
      completedLength: _asInt(json['completedLength']),
      downloadSpeed: _asInt(json['downloadSpeed']),
      uploadSpeed: _asInt(json['uploadSpeed']),
      connections: _asInt(json['connections']),
      directory: json['dir']?.toString() ?? '',
      files: files,
      errorMessage: json['errorMessage']?.toString() ?? '',
      bittorrentName: bittorrent is Map
          ? bittorrent['info'] is Map
              ? (bittorrent['info']['name']?.toString() ?? '')
              : ''
          : '',
      followedBy: json['followedBy'] is List
          ? (json['followedBy'] as List).map((e) => e.toString()).toList()
          : const [],
    );
  }

  /// Snapshot stored in Hive so the source panel and history work without a
  /// running engine.
  Map<String, dynamic> toJson() => {
        'gid': gid,
        'status': status,
        'name': name,
        'totalLength': totalLength,
        'completedLength': completedLength,
        'downloadSpeed': downloadSpeed,
        'uploadSpeed': uploadSpeed,
        'connections': connections,
        'dir': directory,
        'files': files.map((file) => file.toJson()).toList(),
        'errorMessage': errorMessage,
        'bittorrent': bittorrentName.isEmpty
            ? null
            : {
                'info': {'name': bittorrentName},
              },
        'followedBy': followedBy,
      };
}

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}
