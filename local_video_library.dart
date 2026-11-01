import 'dart:io';

import 'package:kazumi/modules/local/local_video_module.dart';
import 'package:path/path.dart' as path;

/// 允许本地播放的视频扩展名（小写，不含点）。
const Set<String> localVideoExtensions = {
  '3gp',
  'asf',
  'avi',
  'divx',
  'f4v',
  'flv',
  'm2ts',
  'm4v',
  'mkv',
  'mov',
  'mp4',
  'mpeg',
  'mpg',
  'mts',
  'ogv',
  'rm',
  'rmvb',
  'ts',
  'vob',
  'webm',
  'wmv',
};

/// 文件名是否是受支持的视频。
bool isLocalVideoFile(String filePath) {
  final extension = path.extension(filePath).toLowerCase();
  if (extension.length < 2 || !extension.startsWith('.')) {
    return false;
  }
  return localVideoExtensions.contains(extension.substring(1));
}

bool _isDigit(int codeUnit) => codeUnit >= 0x30 && codeUnit <= 0x39;

/// 比较两段数字字符串，避免超出 int 范围时退化成逐字符比较。
int _compareDigitStrings(String left, String right) {
  var leftStart = 0;
  while (leftStart < left.length - 1 && left.codeUnitAt(leftStart) == 0x30) {
    leftStart++;
  }
  var rightStart = 0;
  while (rightStart < right.length - 1 && right.codeUnitAt(rightStart) == 0x30) {
    rightStart++;
  }
  final leftDigits = left.substring(leftStart);
  final rightDigits = right.substring(rightStart);
  if (leftDigits.length != rightDigits.length) {
    return leftDigits.length.compareTo(rightDigits.length);
  }
  final result = leftDigits.compareTo(rightDigits);
  if (result != 0) {
    return result;
  }
  // 数值相同（例如 `01` 与 `1`），保持较短写法在前，顺序稳定。
  return left.length.compareTo(right.length);
}

/// 按自然顺序比较文件名：`第2集` 排在 `第10集` 之前。
int compareLocalVideoNames(String left, String right) {
  final a = left.toLowerCase();
  final b = right.toLowerCase();
  var i = 0;
  var j = 0;
  while (i < a.length && j < b.length) {
    final aIsDigit = _isDigit(a.codeUnitAt(i));
    final bIsDigit = _isDigit(b.codeUnitAt(j));
    if (aIsDigit && bIsDigit) {
      var aEnd = i;
      while (aEnd < a.length && _isDigit(a.codeUnitAt(aEnd))) {
        aEnd++;
      }
      var bEnd = j;
      while (bEnd < b.length && _isDigit(b.codeUnitAt(bEnd))) {
        bEnd++;
      }
      final result = _compareDigitStrings(
        a.substring(i, aEnd),
        b.substring(j, bEnd),
      );
      if (result != 0) {
        return result;
      }
      i = aEnd;
      j = bEnd;
      continue;
    }
    final aCode = a.codeUnitAt(i);
    final bCode = b.codeUnitAt(j);
    if (aCode != bCode) {
      return aCode.compareTo(bCode);
    }
    i++;
    j++;
  }
  return a.length.compareTo(b.length);
}

bool _hasHiddenSegment(String relativePath) {
  return relativePath
      .split(RegExp(r'[\\/]'))
      .any((segment) => segment.startsWith('.'));
}

/// 递归扫描 [directory] 下的视频文件，按相对路径的自然顺序排序。
///
/// [maxFiles] 只是安全上限，避免误选一个巨大的目录时卡住 UI。
Future<List<LocalVideoEntry>> scanLocalVideoDirectory(
  String directory, {
  int maxFiles = 500,
}) async {
  final root = Directory(directory);
  if (!await root.exists()) {
    return const [];
  }

  final found = <({String absolutePath, String relativePath})>[];
  try {
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (found.length >= maxFiles) {
        break;
      }
      if (entity is! File) {
        continue;
      }
      final relativePath = path.relative(entity.path, from: directory);
      if (_hasHiddenSegment(relativePath) || !isLocalVideoFile(entity.path)) {
        continue;
      }
      found.add((absolutePath: entity.path, relativePath: relativePath));
    }
  } on FileSystemException {
    // 目录不可读时返回已扫描到的结果，由调用方提示用户。
  }

  found.sort(
    (a, b) => compareLocalVideoNames(a.relativePath, b.relativePath),
  );
  return [
    for (final item in found)
      LocalVideoEntry(
        path: item.absolutePath,
        title: path.basenameWithoutExtension(item.absolutePath),
      ),
  ];
}

/// 由用户选择的文件生成播放列表，保留用户选择的顺序。
List<LocalVideoEntry> buildLocalVideoEntries(Iterable<String> filePaths) {
  return [
    for (final filePath in filePaths)
      LocalVideoEntry(
        path: filePath,
        title: path.basenameWithoutExtension(filePath),
      ),
  ];
}

/// 播放列表名称：单文件用文件名，多文件用共同的父文件夹名。
String localPlaylistName(Iterable<String> filePaths) {
  final paths = filePaths.toList();
  if (paths.isEmpty) {
    return '本地播放';
  }
  if (paths.length == 1) {
    return path.basenameWithoutExtension(paths.first);
  }
  final parents = paths.map((item) => path.dirname(item)).toSet();
  if (parents.length == 1) {
    final name = path.basename(parents.first);
    final isGenericPickerFolder = name.toLowerCase() == 'file_picker';
    if (name.isNotEmpty &&
        name != '.' &&
        name != path.separator &&
        // Android 选择文件后会被复制到插件的缓存目录，目录名没有意义。
        !isGenericPickerFolder) {
      return name;
    }
  }
  return '本地播放';
}

/// 断点续播记录的键。
///
/// 部分平台（如 Android）选择文件后拿到的是缓存副本，路径每次选择都会变化，
/// 因此用“文件名 + 文件大小”而不是绝对路径作为文件身份。
String localVideoProgressKey(String filePath) {
  final name = path.basename(filePath);
  try {
    return '${name}_${File(filePath).lengthSync()}';
  } on FileSystemException {
    return name;
  }
}
