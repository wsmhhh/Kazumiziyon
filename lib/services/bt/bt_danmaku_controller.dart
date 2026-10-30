import 'package:canvas_danmaku/canvas_danmaku.dart' as canvas;
import 'package:flutter/material.dart';
import 'package:kazumi/modules/bt/release_title.dart';
import 'package:kazumi/modules/danmaku/danmaku_module.dart';
import 'package:kazumi/modules/danmaku/danmaku_search_response.dart';
import 'package:kazumi/request/apis/danmaku_api.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';

/// Danmaku for BT playback.
///
/// BT files carry no bangumi identity, so the controller guesses an anime name
/// and episode from the release title, searches DanDanPlay and groups comments
/// by second. The player exposes a manual picker for when the guess is wrong.
class BtDanmakuController extends ChangeNotifier {
  BtDanmakuController({this.isBlocked});

  /// Applies the user's shield rules (MyController.isDanmakuBlocked).
  final bool Function(String message)? isBlocked;

  canvas.DanmakuController? canvasController;

  bool enabled = false;
  bool loading = false;
  bool autoLoaded = false;
  String? error;
  String? notice;

  String searchTitle = '';
  String animeTitle = '';
  int animeId = 0;
  int episode = 0;

  final Map<int, List<DanmakuEntry>> _bySecond = {};
  int _lastSecond = -1;

  bool get hasData => _bySecond.isNotEmpty;

  String? get statusText {
    if (loading) return '正在加载弹幕…';
    if (error != null) return error;
    if (notice != null) return notice;
    if (animeTitle.isEmpty) return null;
    return '$animeTitle${episode > 0 ? ' · 第 $episode 集' : ''} · ${_count()} 条';
  }

  int _count() {
    var total = 0;
    for (final list in _bySecond.values) {
      total += list.length;
    }
    return total;
  }

  Future<void> autoLoad(String rawTitle) async {
    if (autoLoaded) return;
    autoLoaded = true;
    final parsed = parseReleaseTitle(rawTitle);
    searchTitle = parsed.searchTitle;
    if (!parsed.hasSearchTitle) {
      error = '无法从文件名识别番剧名，可手动选择弹幕';
      _notify();
      return;
    }
    await _searchAndLoad(
      parsed.searchTitle,
      parsed.episode > 0 ? parsed.episode : 1,
      exactEpisode: parsed.episode > 0,
    );
  }

  Future<List<DanmakuSearchAnime>> search(String query) async {
    final response = await DanmakuApi.searchAnimes(query.trim());
    return response.animes;
  }

  Future<void> _searchAndLoad(
    String query,
    int targetEpisode, {
    required bool exactEpisode,
  }) async {
    loading = true;
    error = null;
    notice = null;
    _notify();
    try {
      final animes = await search(query);
      if (animes.isEmpty) {
        loading = false;
        error = '没有找到「$query」，可手动搜索番剧';
        _notify();
        return;
      }
      final best = animes.firstWhere(
        (anime) => anime.animeTitle == query,
        orElse: () => animes.first,
      );
      await loadFor(best.animeId, best.animeTitle, targetEpisode);
      if (hasData && !exactEpisode) {
        notice = '未识别到集数，默认加载第 1 集，可手动修正';
        _notify();
      }
    } catch (e) {
      KazumiLogger().w('BT: danmaku search failed', error: e);
      loading = false;
      error = '弹幕搜索失败，请检查网络';
      _notify();
    }
  }

  Future<void> loadFor(int animeId, String title, int episode) async {
    this.animeId = animeId;
    animeTitle = title;
    this.episode = episode;
    loading = true;
    error = null;
    notice = null;
    _bySecond.clear();
    _lastSecond = -1;
    canvasController?.clear();
    _notify();
    try {
      final entries = await DanmakuApi.getDanDanmaku(animeId, episode);
      for (final entry in entries) {
        final second = entry.time.floor();
        (_bySecond[second] ??= <DanmakuEntry>[]).add(entry);
      }
      enabled = _bySecond.isNotEmpty;
      if (_bySecond.isEmpty) {
        error = '第 $episode 集还没有弹幕';
      }
      loading = false;
      _notify();
    } catch (e) {
      KazumiLogger().w('BT: danmaku load failed', error: e);
      loading = false;
      enabled = false;
      error = '弹幕加载失败，请稍后重试';
      _notify();
    }
  }

  void setEnabled(bool value) {
    if (value && !hasData) return;
    enabled = value;
    if (!value) {
      canvasController?.clear();
    }
    _notify();
  }

  void toggle() => setEnabled(!enabled);

  /// Called once per second from the player's ticker.
  void tick(Duration position, {required bool playing}) {
    if (!enabled || !playing) return;
    final second = position.inSeconds;
    if (second == _lastSecond) return;
    final previous = _lastSecond;
    _lastSecond = second;

    // A seek or stall gap invalidates the current on-screen comments.
    if (second < previous || second - previous > 2) {
      canvasController?.clear();
      return;
    }

    final entries = _bySecond[second];
    if (entries == null || entries.isEmpty) return;
    final useSourceColor = GStorage.getSetting(SettingsKeys.danmakuColor);
    for (final entry in entries) {
      if (isBlocked?.call(entry.message) ?? false) continue;
      canvasController?.addDanmaku(
        canvas.DanmakuContentItem(
          entry.message,
          color: useSourceColor ? entry.color : Colors.white,
          type: _itemType(entry.type),
        ),
      );
    }
  }

  canvas.DanmakuItemType _itemType(int type) {
    if (type == 4) return canvas.DanmakuItemType.bottom;
    if (type == 5) return canvas.DanmakuItemType.top;
    return canvas.DanmakuItemType.scroll;
  }

  void _notify() {
    notifyListeners();
  }

  @override
  void dispose() {
    canvasController = null;
    super.dispose();
  }
}
