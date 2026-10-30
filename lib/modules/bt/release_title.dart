/// Best-effort parsing of a torrent/release filename.
///
/// BT releases are inconsistent by nature: `[Group] 中文名 / Romaji - 12
/// [1080p][CHT]`, `【组】中文名 第12话`, `Show.Name.S01E12.1080p.WEB-DL`, ...
/// The goal is only to produce a query for DanDanPlay and a guessed episode;
/// the player lets the user correct both.
class ParsedReleaseTitle {
  const ParsedReleaseTitle({
    required this.searchTitle,
    required this.episode,
  });

  final String searchTitle;

  /// 0 when no episode number could be found.
  final int episode;

  bool get hasSearchTitle => searchTitle.trim().isNotEmpty;
}

final _extensionPattern =
    RegExp(r'\.(mkv|mp4|avi|webm|m4v|ts|mov|flv|wmv)$', caseSensitive: false);
final _leadingGroupPattern = RegExp(r'^\s*[\[【][^\]】]{1,40}[\]】]\s*');
final _tagPattern = RegExp(r'\[[^\]]*\]|【[^】]*】|\([^)]{1,40}\)');
final _qualityPattern = RegExp(
  r'\b(2160p|1080p|720p|480p|4k|8k|hevc|avc|x26[45]|h\.?26[45]|aac|flac|'
  r'ac3|eac3|ddp?5\.1|10bit|8bit|web-?dl|webrip|web|bluray|bdrip|remux|'
  r'cht|chs|jpn|jap|gb|big5|uncensored|repack)\b',
  caseSensitive: false,
);
final _cjkPattern = RegExp(r'[一-鿿぀-ヿ]');

final _episodePatterns = <RegExp>[
  // 第12话 / 第 12 集
  RegExp(r'第\s*(\d{1,4})(?:\.\d+)?\s*[话話集]'),
  // S01E12 / E12 / EP12
  RegExp(r'[Ss]\d{1,2}[\s._-]?[Ee](\d{1,4})'),
  RegExp(r'[Ee][Pp]?\.?\s*(\d{1,4})(?:v\d+)?'),
  // - 12 / – 12
  RegExp(r'[-–—]\s*(\d{1,4})(?:v\d+)?(?:\s|$|[\[\(（【])'),
  // [12] / [12v2]
  RegExp(r'\[\s*(\d{1,4})(?:v\d+)?\s*\]'),
  // 12 [1080p] / 12 END
  RegExp(r'(?:^|\s)(\d{1,4})(?:v\d+)?\s*(?:\[|END|完|$)', caseSensitive: false),
];

ParsedReleaseTitle parseReleaseTitle(String rawTitle) {
  final raw = rawTitle.trim();
  if (raw.isEmpty) {
    return const ParsedReleaseTitle(searchTitle: '', episode: 0);
  }

  final noExtension = raw.replaceAll(_extensionPattern, '');
  final episode = _parseEpisode(noExtension) ?? _parseEpisode(raw) ?? 0;

  var working = noExtension.replaceFirst(_leadingGroupPattern, '');

  // Drop everything from the episode marker onward (" - 12", " 第12话").
  working = _beforeEpisodeMarker(working);

  // Prefer the Chinese title when the release lists "中文 / Romaji".
  final segments = working
      .split(RegExp(r'\s*[/|｜]\s*'))
      .map((segment) => segment.trim())
      .where((segment) => segment.isNotEmpty)
      .toList();
  var best = segments.firstWhere(
    (segment) => _cjkPattern.hasMatch(segment),
    orElse: () => segments.isEmpty ? working : segments.first,
  );

  best = best
      .replaceAll(_tagPattern, ' ')
      .replaceAll(_qualityPattern, ' ')
      .replaceAll(RegExp(r'[._]+'), ' ')
      .replaceAll(RegExp(r'\s{2,}'), ' ')
      .trim();

  if (best.isEmpty) {
    best = raw.replaceAll(_extensionPattern, '').trim();
  }

  return ParsedReleaseTitle(searchTitle: best, episode: episode);
}

int? _parseEpisode(String text) {
  for (final pattern in _episodePatterns) {
    final match = pattern.firstMatch(text);
    if (match == null) continue;
    final value = int.tryParse(match.group(1) ?? '');
    if (value != null && value > 0 && value <= 2000) return value;
  }
  return null;
}

String _beforeEpisodeMarker(String text) {
  var cut = text.length;
  final markers = <RegExp>[
    RegExp(r'[-–—]\s*\d{1,4}(?:v\d+)?(?:\s|$|[\[\(（【])'),
    RegExp(r'第\s*\d{1,4}(?:\.\d+)?\s*[话話集]'),
    RegExp(r'[Ss]\d{1,2}[\s._-]?[Ee]\d{1,4}'),
    RegExp(r'\s[Ee][Pp]?\.?\s*\d{1,4}(?:v\d+)?(?:\s|$|[\[\(（【])'),
    RegExp(r'\s\d{1,4}(?:v\d+)?\s*(?:\[|END|完|$)'),
  ];
  for (final marker in markers) {
    final match = marker.firstMatch(text);
    if (match != null && match.start < cut) {
      cut = match.start;
    }
  }
  return text.substring(0, cut).trim();
}
