import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/rss/rss_parser.dart';

void main() {
  const parser = RssParser();

  group('RSS parser', () {
    test('parses an AniBT feed with namespaced torrent metadata', () {
      const xml = '''
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom"
     xmlns:anibt="https://anibt.net/xmlns/rss/1.0/">
  <channel>
    <title>AniBT Anime Releases</title>
    <link>https://anibt.net/magnets</link>
    <item>
      <title>[黒ネズミたち] 宝可梦 地平线 / Pokemon (2023) - 155 (ABEMA 1920x1080 AVC AAC MKV)</title>
      <link>https://anibt.net/release/rel_SZ-MztUpzl-c</link>
      <guid isPermaLink="false">rel_SZ-MztUpzl-c</guid>
      <pubDate>Fri, 30 Oct 2026 18:30:58 +0800</pubDate>
      <anibt:torrentUrl>https://anibt.net/api/torrent/rel_SZ-MztUpzl-c.torrent</anibt:torrentUrl>
      <anibt:episode>155</anibt:episode>
      <anibt:resolution>1080p</anibt:resolution>
      <anibt:groupName>Kirara Fantasia</anibt:groupName>
      <anibt:fileSize>771101902</anibt:fileSize>
      <description><![CDATA[<p>Pokemon Horizons</p>]]></description>
    </item>
  </channel>
</rss>
''';

      final result = parser.parse(xml, feedId: 'anibt-test');

      expect(result.feedTitle, 'AniBT Anime Releases');
      expect(result.items, hasLength(1));
      final item = result.items.single;
      expect(item.title, contains('宝可梦 地平线'));
      expect(item.episode, 155);
      expect(item.resolution, '1080p');
      expect(item.group, 'Kirara Fantasia');
      expect(item.sizeBytes, 771101902);
      expect(item.torrentUrl,
          'https://anibt.net/api/torrent/rel_SZ-MztUpzl-c.torrent');
      expect(item.magnet, isEmpty);
      expect(item.downloadable, isTrue);
      // +0800 must be converted to UTC.
      expect(item.publishedAt?.toUtc().hour, 10);
      expect(item.publishedAt?.toUtc().minute, 30);
    });

    test('parses a Mikan feed using the enclosure torrent', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:torrent="https://mikanani.me/0.1/">
  <channel>
    <title>Mikan Project - 葬送的芙莉莲</title>
    <item>
      <title>[喵萌奶茶屋&amp;LoliHouse] 葬送的芙莉莲 / Sousou no Frieren - 12 [WebRip 1080p HEVC-10bit AAC][简繁日内封字幕]</title>
      <link>https://mikanani.me/Home/Episode/abc123</link>
      <guid isPermaLink="false">abc123</guid>
      <pubDate>Mon, 26 Oct 2026 20:05:00 +0800</pubDate>
      <enclosure url="https://mikanani.me/Download/20261026/abc123.torrent"
                 type="application/x-bittorrent" length="35678" />
      <torrent:contentLength>35678</torrent:contentLength>
    </item>
  </channel>
</rss>
''';

      final item = parser.parse(xml, feedId: 'mikan-test').items.single;

      expect(item.episode, 12);
      expect(item.resolution, '1080p');
      expect(item.group, '喵萌奶茶屋&LoliHouse');
      expect(item.sizeBytes, 35678);
      expect(item.torrentUrl, endsWith('abc123.torrent'));
      expect(item.guid, 'abc123');
    });

    test('falls back to a magnet link embedded in the description', () {
      const magnet =
          'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=test';
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0">
  <channel>
    <title>DMHY</title>
    <item>
      <title>[Lilith-Raws] 葬送的芙莉莲 - 13 [Baha][WEB-DL][1080p][AVC AAC][CHT][MP4]</title>
      <link>https://share.dmhy.org/topics/view/123456.html</link>
      <guid>https://share.dmhy.org/topics/view/123456.html</guid>
      <description><![CDATA[<a href="$magnet">Magnet</a>]]></description>
    </item>
  </channel>
</rss>
''';

      final item = parser.parse(xml, feedId: 'dmhy-test').items.single;

      expect(item.episode, 13);
      expect(item.resolution, '1080p');
      expect(item.group, 'Lilith-Raws');
      expect(item.magnet, magnet);
      expect(item.downloadUri, magnet);
      expect(item.downloadable, isTrue);
    });

    test('sorts items newest first', () {
      const xml = '''
<rss version="2.0"><channel><title>t</title>
<item><title>A - 1</title><guid>a</guid><pubDate>Mon, 26 Oct 2026 10:00:00 +0800</pubDate></item>
<item><title>A - 2</title><guid>b</guid><pubDate>Tue, 27 Oct 2026 10:00:00 +0800</pubDate></item>
</channel></rss>
''';

      final items = parser.parse(xml, feedId: 'sort-test').items;
      expect(items.first.guid, 'b');
      expect(items.last.guid, 'a');
    });
  });
}
