import 'dart:convert';

import 'package:hive_ce/hive.dart';
import 'package:kazumi/modules/rss/rss_models.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';

/// JSON-in-Hive persistence for subscriptions and the "already handled" log.
///
/// Keeping these as strings avoids Hive codegen for two small models and makes
/// forward-compatible changes trivial (unknown keys are simply ignored).
class RssStore {
  Box<String> get _subscriptions => GStorage.btRssSubscriptions;
  Box<String> get _seen => GStorage.btRssSeen;

  static const _maxSeenEntries = 4000;

  List<RssSubscription> loadSubscriptions() {
    final result = <RssSubscription>[];
    for (final raw in _subscriptions.values) {
      try {
        final json = jsonDecode(raw);
        if (json is Map<String, dynamic>) {
          result.add(RssSubscription.fromJson(json));
        }
      } catch (e) {
        KazumiLogger().w('RSS: skipping unreadable subscription', error: e);
      }
    }
    result.sort((a, b) => a.createdAtMs.compareTo(b.createdAtMs));
    return result;
  }

  Future<void> saveSubscription(RssSubscription subscription) async {
    await _subscriptions.put(subscription.id, jsonEncode(subscription.toJson()));
  }

  Future<void> deleteSubscription(String id) async {
    await _subscriptions.delete(id);
    await clearSeenForFeed(id);
  }

  bool isSeen(String feedId, String itemKey) =>
      _seen.containsKey(_seenKey(feedId, itemKey));

  Future<void> markSeen(String feedId, Iterable<String> itemKeys) async {
    final now = DateTime.now().millisecondsSinceEpoch.toString();
    final entries = {
      for (final key in itemKeys) _seenKey(feedId, key): now,
    };
    if (entries.isEmpty) return;
    await _seen.putAll(entries);
    await _pruneIfNeeded();
  }

  Future<void> clearSeenForFeed(String feedId) async {
    final prefix = '$feedId|';
    final stale = _seen.keys
        .whereType<String>()
        .where((key) => key.startsWith(prefix))
        .toList(growable: false);
    if (stale.isNotEmpty) {
      await _seen.deleteAll(stale);
    }
  }

  Future<void> _pruneIfNeeded() async {
    if (_seen.length <= _maxSeenEntries) return;
    final entries = _seen.toMap().entries.toList()
      ..sort((a, b) => (a.value).compareTo(b.value));
    final removeCount = _seen.length - _maxSeenEntries ~/ 2;
    await _seen.deleteAll(
      entries.take(removeCount).map((entry) => entry.key).toList(),
    );
    KazumiLogger().i('RSS: pruned $removeCount old seen entries');
  }

  String _seenKey(String feedId, String itemKey) => '$feedId|$itemKey';
}
