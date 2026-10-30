/// Where a subscription came from. The value only affects URL building and
/// display hints; parsing is identical for every source.
enum RssSource { mikan, dmhy, anibt, custom }

class RssPreset {
  const RssPreset({
    required this.source,
    required this.label,
    required this.description,
    required this.host,
    required this.supportsKeyword,
    this.keywordHint = '番剧名，例如：葬送的芙莉莲',
  });

  final RssSource source;
  final String label;
  final String description;
  final String host;
  final bool supportsKeyword;
  final String keywordHint;
}

const rssPresets = <RssSource, RssPreset>{
  RssSource.mikan: RssPreset(
    source: RssSource.mikan,
    label: 'Mikan 蜜柑',
    description: '按关键词搜索订阅，标题含集数，适合追新番',
    host: 'mikanani.me',
    supportsKeyword: true,
  ),
  RssSource.dmhy: RssPreset(
    source: RssSource.dmhy,
    label: 'DMHY 动漫花园',
    description: '按关键词搜索订阅，资源更新快',
    host: 'share.dmhy.org',
    supportsKeyword: true,
  ),
  RssSource.anibt: RssPreset(
    source: RssSource.anibt,
    label: 'AniBT',
    description: '全站最新发布，订阅后按关键词在本地筛选',
    host: 'anibt.net',
    supportsKeyword: false,
    keywordHint: '用于本地筛选的关键词，例如：宝可梦',
  ),
  RssSource.custom: RssPreset(
    source: RssSource.custom,
    label: '自定义 RSS',
    description: '粘贴任意 RSS/Atom 地址，自动识别 magnet / .torrent',
    host: '自定义',
    supportsKeyword: false,
    keywordHint: '本地筛选关键词，可留空',
  ),
};

/// Builds the feed URL for a preset. Throws [ArgumentError] with a Chinese
/// message when a required field is missing.
String buildFeedUrl({
  required RssSource source,
  String keyword = '',
  String customUrl = '',
}) {
  final trimmedKeyword = keyword.trim();
  switch (source) {
    case RssSource.mikan:
      if (trimmedKeyword.isEmpty) {
        throw ArgumentError('请输入要订阅的番剧关键词');
      }
      return 'https://mikanani.me/RSS/Search?searchstr=${Uri.encodeQueryComponent(trimmedKeyword)}';
    case RssSource.dmhy:
      if (trimmedKeyword.isEmpty) {
        throw ArgumentError('请输入要订阅的番剧关键词');
      }
      return 'https://share.dmhy.org/topics/rss/rss.xml?keyword=${Uri.encodeQueryComponent(trimmedKeyword)}';
    case RssSource.anibt:
      final override = customUrl.trim();
      return override.isNotEmpty ? override : 'https://anibt.net/rss/magnets.xml';
    case RssSource.custom:
      final url = customUrl.trim();
      if (url.isEmpty) {
        throw ArgumentError('请粘贴 RSS 地址');
      }
      final uri = Uri.tryParse(url);
      if (uri == null || !uri.hasScheme || !uri.isAbsolute) {
        throw ArgumentError('RSS 地址格式不正确');
      }
      return url;
  }
}

String suggestedSubscriptionName(RssSource source, String keyword) {
  final trimmed = keyword.trim();
  if (trimmed.isNotEmpty) return trimmed;
  return rssPresets[source]?.label ?? 'RSS 订阅';
}
