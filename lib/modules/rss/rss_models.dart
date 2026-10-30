import 'package:kazumi/services/rss/rss_presets.dart';

/// A subscribed RSS/Atom feed, usually one per anime or one per search.
class RssSubscription {
  const RssSubscription({
    required this.id,
    required this.name,
    required this.url,
    required this.source,
    this.keyword = '',
    this.exclude = '',
    this.autoDownload = false,
    this.minEpisode = 0,
    this.enabled = true,
    required this.createdAtMs,
    this.lastFetchedMs = 0,
    this.lastItemCount = 0,
  });

  final String id;
  final String name;
  final String url;
  final RssSource source;

  /// Only items whose title contains this keyword are auto-downloaded.
  /// Empty means "every item in the feed".
  final String keyword;

  /// Comma-separated fragments that disqualify an item.
  final String exclude;
  final bool autoDownload;

  /// 0 disables the lower bound.
  final int minEpisode;
  final bool enabled;
  final int createdAtMs;
  final int lastFetchedMs;
  final int lastItemCount;

  RssSubscription copyWith({
    String? name,
    String? url,
    RssSource? source,
    String? keyword,
    String? exclude,
    bool? autoDownload,
    int? minEpisode,
    bool? enabled,
    int? lastFetchedMs,
    int? lastItemCount,
  }) {
    return RssSubscription(
      id: id,
      name: name ?? this.name,
      url: url ?? this.url,
      source: source ?? this.source,
      keyword: keyword ?? this.keyword,
      exclude: exclude ?? this.exclude,
      autoDownload: autoDownload ?? this.autoDownload,
      minEpisode: minEpisode ?? this.minEpisode,
      enabled: enabled ?? this.enabled,
      createdAtMs: createdAtMs,
      lastFetchedMs: lastFetchedMs ?? this.lastFetchedMs,
      lastItemCount: lastItemCount ?? this.lastItemCount,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'source': source.name,
        'keyword': keyword,
        'exclude': exclude,
        'autoDownload': autoDownload,
        'minEpisode': minEpisode,
        'enabled': enabled,
        'createdAtMs': createdAtMs,
        'lastFetchedMs': lastFetchedMs,
        'lastItemCount': lastItemCount,
      };

  factory RssSubscription.fromJson(Map<String, dynamic> json) {
    return RssSubscription(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '未命名订阅',
      url: json['url']?.toString() ?? '',
      source: RssSource.values.firstWhere(
        (source) => source.name == json['source'],
        orElse: () => RssSource.custom,
      ),
      keyword: json['keyword']?.toString() ?? '',
      exclude: json['exclude']?.toString() ?? '',
      autoDownload: json['autoDownload'] == true,
      minEpisode: _asInt(json['minEpisode']),
      enabled: json['enabled'] != false,
      createdAtMs: _asInt(json['createdAtMs']),
      lastFetchedMs: _asInt(json['lastFetchedMs']),
      lastItemCount: _asInt(json['lastItemCount']),
    );
  }
}

class RssItem {
  const RssItem({
    required this.guid,
    required this.title,
    required this.link,
    required this.feedId,
    required this.feedName,
    this.torrentUrl = '',
    this.magnet = '',
    this.publishedAt,
    this.sizeBytes = 0,
    this.episode = 0,
    this.resolution = '',
    this.group = '',
  });

  final String guid;
  final String title;
  final String link;
  final String feedId;
  final String feedName;
  final String torrentUrl;
  final String magnet;
  final DateTime? publishedAt;
  final int sizeBytes;
  final int episode;
  final String resolution;
  final String group;

  /// Magnet wins because it does not depend on the feed's HTTP host staying up.
  String get downloadUri => magnet.isNotEmpty ? magnet : torrentUrl;

  bool get downloadable => downloadUri.isNotEmpty;

  /// Stable identity for the "already handled" bookkeeping.
  String get key => guid.isNotEmpty ? guid : '$title|${publishedAt?.millisecondsSinceEpoch ?? 0}';

  bool get isVideoRelease => episode > 0 || title.contains('[');
}

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}
