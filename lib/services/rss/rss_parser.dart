import 'dart:io';

import 'package:kazumi/modules/rss/rss_models.dart';
import 'package:xml/xml.dart';

class RssParseResult {
  const RssParseResult({required this.feedTitle, required this.items});

  final String feedTitle;
  final List<RssItem> items;
}

/// Parses RSS 2.0 and Atom feeds into [RssItem]s.
///
/// The three supported sites use different ways to expose the torrent:
/// Mikan/DMHY put it in `<enclosure>`, AniBT uses an `anibt:torrentUrl`
/// element, and some feeds only embed a magnet link in the description.
/// All of them are checked, in that order.
class RssParser {
  const RssParser();

  static final _magnetPattern = RegExp(r'magnet:\?[^\s"<>]+');
  static final _torrentUrlPattern =
      RegExp(r'''https?://[^\s"'<>]+\.torrent''', caseSensitive: false);
  static final _episodePatterns = <RegExp>[
    RegExp(r'第\s*(\d{1,4})(?:\.\d+)?\s*[话話集]'),
    RegExp(r'[Ee][Pp]?\.?\s*(\d{1,4})(?:v\d+)?'),
    RegExp(r'[-–—]\s*(\d{1,4})(?:v\d+)?(?:\s|$|[\[\(])'),
    RegExp(r'\[\s*(\d{1,4})(?:v\d+)?\s*\]'),
    RegExp(r'\s(\d{1,4})(?:v\d+)?\s*(?:\[|END|完)'),
  ];
  static final _resolutionPattern = RegExp(r'(\d{3,4})\s*[pP]');
  static final _groupPattern = RegExp(r'^\s*[\[【]([^\]】]{1,40})[\]】]');

  RssParseResult parse(String xmlText, {required String feedId}) {
    final document = XmlDocument.parse(xmlText);
    final elements = document.descendants.whereType<XmlElement>();

    XmlElement? channel;
    for (final element in elements) {
      if (element.name.local == 'channel') {
        channel = element;
        break;
      }
    }
    final feedTitle = _childText(channel, const ['title']) ?? feedId;

    final items = <RssItem>[];
    for (final element in elements) {
      if (element.name.local != 'item' && element.name.local != 'entry') {
        continue;
      }
      final item = _parseItem(element, feedId: feedId, feedName: feedTitle);
      if (item != null) items.add(item);
    }
    items.sort((a, b) {
      final left = a.publishedAt?.millisecondsSinceEpoch ?? 0;
      final right = b.publishedAt?.millisecondsSinceEpoch ?? 0;
      return right.compareTo(left);
    });
    return RssParseResult(feedTitle: feedTitle, items: items);
  }

  RssItem? _parseItem(
    XmlElement element, {
    required String feedId,
    required String feedName,
  }) {
    final title = _childText(element, const ['title']) ?? '';
    if (title.isEmpty) return null;

    final link = _atomLink(element) ??
        _childText(element, const ['link', 'guid', 'id']) ??
        '';
    final guid = _childText(element, const ['guid', 'id']) ?? link;
    final publishedRaw =
        _childText(element, const ['pubDate', 'published', 'updated', 'date']);
    final publishedAt = _parseDate(publishedRaw);

    final enclosureUrl = _enclosureUrl(element);
    final explicitTorrent =
        _childText(element, const ['torrentUrl', 'torrent', 'enclosureUrl']);
    final magnet = _findMagnet(element);
    final torrentUrl = _pickTorrentUrl(
      explicitTorrent: explicitTorrent,
      enclosureUrl: enclosureUrl,
      link: link,
      element: element,
    );

    final episode = _parseEpisode(
      _childText(element, const ['episode', 'episodeKey']),
      title,
    );
    final resolution = _childText(element, const ['resolution']) ??
        _resolutionPattern.firstMatch(title)?.group(1) ??
        '';
    final sizeBytes =
        _asInt(_childText(element, const ['fileSize', 'size'])) > 0
            ? _asInt(_childText(element, const ['fileSize', 'size']))
            : _enclosureLength(element);
    final group = _childText(element, const ['groupName', 'author']) ??
        _groupPattern.firstMatch(title)?.group(1) ??
        '';

    return RssItem(
      guid: guid,
      title: title,
      link: link,
      feedId: feedId,
      feedName: feedName,
      torrentUrl: torrentUrl,
      magnet: magnet,
      publishedAt: publishedAt,
      sizeBytes: sizeBytes,
      episode: episode,
      resolution: resolution,
      group: group,
    );
  }

  String _pickTorrentUrl({
    required String? explicitTorrent,
    required String? enclosureUrl,
    required String link,
    required XmlElement element,
  }) {
    if (explicitTorrent != null && explicitTorrent.isNotEmpty) {
      return explicitTorrent;
    }
    if (enclosureUrl != null && enclosureUrl.isNotEmpty) {
      return enclosureUrl;
    }
    if (link.toLowerCase().endsWith('.torrent')) return link;
    final fromDescription = _torrentUrlPattern.firstMatch(element.innerText);
    return fromDescription?.group(0) ?? '';
  }

  String _findMagnet(XmlElement element) {
    final match = _magnetPattern.firstMatch(element.innerText);
    return match?.group(0) ?? '';
  }

  String? _enclosureUrl(XmlElement element) {
    for (final child in element.children.whereType<XmlElement>()) {
      if (child.name.local != 'enclosure') continue;
      final url = child.getAttribute('url');
      if (url != null && url.isNotEmpty) return url;
    }
    return null;
  }

  int _enclosureLength(XmlElement element) {
    for (final child in element.children.whereType<XmlElement>()) {
      if (child.name.local != 'enclosure') continue;
      final length = int.tryParse(child.getAttribute('length') ?? '');
      if (length != null) return length;
    }
    return 0;
  }

  String? _atomLink(XmlElement element) {
    for (final child in element.children.whereType<XmlElement>()) {
      if (child.name.local != 'link') continue;
      final href = child.getAttribute('href');
      if (href == null || href.isEmpty) continue;
      final rel = child.getAttribute('rel') ?? 'alternate';
      if (rel == 'alternate') return href;
    }
    return null;
  }

  String? _childText(XmlElement? element, List<String> localNames) {
    if (element == null) return null;
    for (final child in element.children.whereType<XmlElement>()) {
      if (!localNames.contains(child.name.local)) continue;
      final text = child.innerText.trim();
      if (text.isNotEmpty) return text;
    }
    return null;
  }

  int _parseEpisode(String? explicit, String title) {
    final fromFeed = int.tryParse((explicit ?? '').trim());
    if (fromFeed != null && fromFeed > 0) return fromFeed;
    for (final pattern in _episodePatterns) {
      final match = pattern.firstMatch(title);
      if (match == null) continue;
      final value = int.tryParse(match.group(1) ?? '');
      if (value != null && value > 0 && value <= 2000) return value;
    }
    return 0;
  }

  DateTime? _parseDate(String? raw) {
    final value = raw?.trim();
    if (value == null || value.isEmpty) return null;

    // RFC 822 with a numeric zone ("Fri, 30 Oct 2026 18:30:58 +0800") is what
    // the supported sites emit; parse it before HttpDate, which is GMT-only.
    final rfc822 = RegExp(
      r'(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})\s+(\d{2}):(\d{2})(?::(\d{2}))?\s+([+-]\d{4}|[A-Za-z]{1,4})',
    ).firstMatch(value);
    if (rfc822 != null && rfc822.group(7)!.startsWith(RegExp('[+-]'))) {
      return _parseRfc822(rfc822);
    }

    final iso = DateTime.tryParse(value);
    if (iso != null) return iso;
    try {
      return HttpDate.parse(value);
    } catch (_) {
      // Not an HTTP date; fall through.
    }
    if (rfc822 != null) return _parseRfc822(rfc822);
    return null;
  }

  DateTime? _parseRfc822(RegExpMatch match) {
    const months = {
      'jan': 1,
      'feb': 2,
      'mar': 3,
      'apr': 4,
      'may': 5,
      'jun': 6,
      'jul': 7,
      'aug': 8,
      'sep': 9,
      'oct': 10,
      'nov': 11,
      'dec': 12,
    };
    final month = months[match.group(2)!.toLowerCase()];
    if (month == null) return null;
    final zone = match.group(7)!;
    var offset = Duration.zero;
    if (zone.startsWith('+') || zone.startsWith('-')) {
      final sign = zone.startsWith('-') ? -1 : 1;
      final hours = int.tryParse(zone.substring(1, 3)) ?? 0;
      final minutes = int.tryParse(zone.substring(3, 5)) ?? 0;
      offset = Duration(hours: sign * hours, minutes: sign * minutes);
    }
    final utc = DateTime.utc(
      int.parse(match.group(3)!),
      month,
      int.parse(match.group(1)!),
      int.parse(match.group(4)!),
      int.parse(match.group(5)!),
      int.tryParse(match.group(6) ?? '') ?? 0,
    );
    return utc.subtract(offset);
  }

  static int _asInt(String? value) => int.tryParse(value ?? '') ?? 0;
}
