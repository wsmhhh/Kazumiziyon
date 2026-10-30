import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:kazumi/modules/rss/rss_models.dart';
import 'package:kazumi/services/bt/bt_download_controller.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/rss/rss_parser.dart';
import 'package:kazumi/services/rss/rss_store.dart';
import 'package:kazumi/services/storage/storage.dart';

/// Fetches RSS feeds, keeps the latest items per subscription and turns
/// matching new items into BitTorrent downloads.
class RssController extends ChangeNotifier {
  RssController._();

  static final RssController _instance = RssController._();

  factory RssController() => _instance;

  final RssStore _store = RssStore();
  final RssParser _parser = const RssParser();

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 20),
    receiveTimeout: const Duration(seconds: 30),
    headers: const {
      'User-Agent':
          'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Kazumi',
      'Accept': 'application/rss+xml, application/atom+xml, application/xml, text/xml, */*',
    },
  ));

  List<RssSubscription> subscriptions = const [];
  final Map<String, List<RssItem>> _items = {};
  final Map<String, String> _feedErrors = {};

  bool isRefreshing = false;
  DateTime? lastRefreshAt;
  int autoDownloadedCount = 0;

  Timer? _timer;
  bool _disposed = false;
  bool _initialized = false;

  bool get isInitialized => _initialized;

  List<RssItem> itemsFor(String subscriptionId) =>
      _items[subscriptionId] ?? const [];

  String? errorFor(String subscriptionId) => _feedErrors[subscriptionId];

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    subscriptions = _store.loadSubscriptions();
    _scheduleAutoRefresh();
    _notify();
    if (subscriptions.any((sub) => sub.enabled)) {
      // Let the first frame settle before the first network burst.
      unawaited(Future<void>.delayed(
        const Duration(seconds: 3),
        () => refreshAll(manual: false),
      ));
    }
  }

  void _scheduleAutoRefresh() {
    _timer?.cancel();
    final configured = GStorage.getSetting(SettingsKeys.btRssIntervalMinutes);
    final minutes = configured < 5 ? 5 : (configured > 240 ? 240 : configured);
    _timer = Timer.periodic(
      Duration(minutes: minutes),
      (_) => refreshAll(manual: false),
    );
  }

  Future<void> refreshAll({bool manual = true}) async {
    if (isRefreshing) return;
    isRefreshing = true;
    autoDownloadedCount = 0;
    _notify();
    try {
      for (final subscription in List<RssSubscription>.from(subscriptions)) {
        if (!subscription.enabled) continue;
        try {
          await _refreshSubscription(subscription);
          _feedErrors.remove(subscription.id);
        } catch (e) {
          _feedErrors[subscription.id] = _describeError(e);
          KazumiLogger().w(
            'RSS: refresh failed for ${subscription.name}',
            error: e,
          );
        }
      }
      lastRefreshAt = DateTime.now();
    } finally {
      isRefreshing = false;
      _notify();
    }
    if (manual && autoDownloadedCount == 0) {
      // Callers show the toast; keeping the count lets them mention downloads.
      _notify();
    }
  }

  Future<List<RssItem>> refreshSubscription(
    RssSubscription subscription, {
    bool manual = true,
  }) async {
    try {
      final items = await _refreshSubscription(subscription);
      _feedErrors.remove(subscription.id);
      _notify();
      return items;
    } catch (e) {
      _feedErrors[subscription.id] = _describeError(e);
      _notify();
      rethrow;
    }
  }

  Future<List<RssItem>> _refreshSubscription(RssSubscription subscription) async {
    final items = await _fetch(subscription);
    _items[subscription.id] = items.take(300).toList(growable: false);

    final unseen = items
        .where((item) => !_store.isSeen(subscription.id, item.key))
        .toList(growable: false);

    var downloaded = 0;
    final handled = <String>[];
    final btController = BtDownloadController();
    for (final item in unseen) {
      if (!_matches(subscription, item)) {
        handled.add(item.key);
        continue;
      }
      if (downloaded >= 5) continue;
      final gid = await btController.addDownloadUri(item.downloadUri);
      if (gid != null) {
        downloaded++;
        autoDownloadedCount++;
        handled.add(item.key);
        KazumiLogger().i('RSS: auto-download ${item.title} ($gid)');
      } else if (btController.lastError != null) {
        // Engine problems (missing binary, port busy) are actionable; surface
        // them on the subscription instead of failing silently.
        _feedErrors[subscription.id] = btController.lastError!;
        break;
      }
      // A failed add stays unseen so the next refresh retries it.
    }

    await _store.markSeen(subscription.id, handled);

    final updated = subscription.copyWith(
      lastFetchedMs: DateTime.now().millisecondsSinceEpoch,
      lastItemCount: items.length,
    );
    _replaceSubscription(updated);
    await _store.saveSubscription(updated);
    return items;
  }

  Future<List<RssItem>> _fetch(RssSubscription subscription) async {
    final response = await _dio.get<String>(
      subscription.url,
      options: Options(responseType: ResponseType.plain),
    );
    final body = response.data;
    if (body == null || body.trim().isEmpty) {
      throw const FormatException('RSS 内容为空');
    }
    final result = _parser.parse(body, feedId: subscription.id);
    return result.items;
  }

  bool _matches(RssSubscription subscription, RssItem item) {
    if (!subscription.autoDownload || !item.downloadable) return false;
    final keyword = subscription.keyword.trim().toLowerCase();
    if (keyword.isNotEmpty && !item.title.toLowerCase().contains(keyword)) {
      return false;
    }
    for (final part in subscription.exclude.split(',')) {
      final fragment = part.trim().toLowerCase();
      if (fragment.isNotEmpty && item.title.toLowerCase().contains(fragment)) {
        return false;
      }
    }
    if (subscription.minEpisode > 0 &&
        item.episode > 0 &&
        item.episode < subscription.minEpisode) {
      return false;
    }
    return true;
  }

  Future<void> addSubscription(
    RssSubscription subscription, {
    bool seedExistingItems = true,
  }) async {
    await _store.saveSubscription(subscription);
    subscriptions = [...subscriptions, subscription];
    _notify();
    if (seedExistingItems) {
      try {
        final items = await _fetch(subscription);
        _items[subscription.id] = items.take(300).toList(growable: false);
        await _store.markSeen(
          subscription.id,
          items.map((item) => item.key),
        );
        final updated = subscription.copyWith(
          lastFetchedMs: DateTime.now().millisecondsSinceEpoch,
          lastItemCount: items.length,
        );
        _replaceSubscription(updated);
        await _store.saveSubscription(updated);
        _feedErrors.remove(subscription.id);
        _notify();
      } catch (e) {
        _feedErrors[subscription.id] = _describeError(e);
        _notify();
        rethrow;
      }
    }
    if (subscriptions.any((sub) => sub.enabled)) {
      _scheduleAutoRefresh();
    }
  }

  Future<void> updateSubscription(RssSubscription subscription) async {
    _replaceSubscription(subscription);
    await _store.saveSubscription(subscription);
    _scheduleAutoRefresh();
    _notify();
  }

  Future<void> setEnabled(RssSubscription subscription, bool enabled) async {
    await updateSubscription(subscription.copyWith(enabled: enabled));
  }

  Future<void> removeSubscription(String id) async {
    subscriptions =
        subscriptions.where((sub) => sub.id != id).toList(growable: false);
    _items.remove(id);
    _feedErrors.remove(id);
    await _store.deleteSubscription(id);
    _notify();
  }

  void _replaceSubscription(RssSubscription subscription) {
    subscriptions = [
      for (final sub in subscriptions)
        if (sub.id == subscription.id) subscription else sub,
    ];
  }

  String _describeError(Object error) {
    if (error is DioException) {
      switch (error.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.sendTimeout:
          return '请求超时，请检查网络或代理';
        case DioExceptionType.badResponse:
          return '服务器返回 ${error.response?.statusCode}';
        case DioExceptionType.connectionError:
          return '无法连接到 RSS 服务器';
        default:
          return 'RSS 请求失败';
      }
    }
    if (error is FormatException) {
      return 'RSS 格式无法解析';
    }
    return 'RSS 刷新失败：$error';
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
