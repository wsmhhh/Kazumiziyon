import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/modules/rss/rss_models.dart';
import 'package:kazumi/pages/bt/rss_edit_sheet.dart';
import 'package:kazumi/services/rss/rss_controller.dart';
import 'package:kazumi/services/rss/rss_presets.dart';

class RssPage extends StatefulWidget {
  const RssPage({super.key});

  @override
  State<RssPage> createState() => _RssPageState();
}

class _RssPageState extends State<RssPage> {
  final RssController _controller = RssController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
    _controller.init();
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _add() async {
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => const RssEditSheet(),
    );
  }

  Future<void> _edit(RssSubscription subscription) async {
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => RssEditSheet(existing: subscription),
    );
  }

  Future<void> _remove(RssSubscription subscription) async {
    final confirmed = await KazumiDialog.show<bool>(
      builder: (context) => AlertDialog(
        title: const Text('删除订阅'),
        content: Text('确定删除「${subscription.name}」吗？已下载的内容不会删除。'),
        actions: [
          TextButton(
            onPressed: () => KazumiDialog.dismiss(popWith: false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => KazumiDialog.dismiss(popWith: true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _controller.removeSubscription(subscription.id);
    }
  }

  Future<void> _refreshAll() async {
    await _controller.refreshAll();
    if (!mounted) return;
    KazumiDialog.showToast(
      message: _controller.autoDownloadedCount > 0
          ? '已自动加入 ${_controller.autoDownloadedCount} 个 BT 任务'
          : 'RSS 已刷新',
    );
  }

  @override
  Widget build(BuildContext context) {
    final subscriptions = _controller.subscriptions;
    return Scaffold(
      appBar: SysAppBar(
        title: const Text('RSS 订阅'),
        actions: [
          IconButton(
            tooltip: '刷新全部',
            onPressed: _controller.isRefreshing ? null : _refreshAll,
            icon: _controller.isRefreshing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.add_rounded),
        label: const Text('添加订阅'),
      ),
      body: RefreshIndicator(
        onRefresh: _refreshAll,
        child: subscriptions.isEmpty
            ? _emptyState()
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                children: [
                  const _HintCard(),
                  const SizedBox(height: 8),
                  ...subscriptions.map(_subscriptionCard),
                ],
              ),
      ),
    );
  }

  Widget _emptyState() {
    return ListView(
      children: [
        const SizedBox(height: 120),
        Icon(
          Icons.rss_feed_rounded,
          size: 48,
          color: Theme.of(context).colorScheme.outline,
        ),
        const SizedBox(height: 12),
        Center(
          child: Text(
            '还没有 RSS 订阅',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        const SizedBox(height: 6),
        Center(
          child: Text(
            '用 Mikan / DMHY / AniBT 的订阅链接自动追番',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }

  Widget _subscriptionCard(RssSubscription subscription) {
    final theme = Theme.of(context);
    final error = _controller.errorFor(subscription.id);
    final items = _controller.itemsFor(subscription.id);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => context.pushNamed(
          '/settings/rss/feed',
          arguments: subscription.id,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    subscription.source == RssSource.custom
                        ? Icons.rss_feed_rounded
                        : Icons.podcasts_rounded,
                    size: 20,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      subscription.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                  Switch(
                    value: subscription.enabled,
                    onChanged: (value) =>
                        _controller.setEnabled(subscription, value),
                  ),
                  PopupMenuButton<String>(
                    onSelected: (value) {
                      if (value == 'edit') _edit(subscription);
                      if (value == 'delete') _remove(subscription);
                    },
                    itemBuilder: (context) => const [
                      PopupMenuItem(value: 'edit', child: Text('编辑')),
                      PopupMenuItem(value: 'delete', child: Text('删除')),
                    ],
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(left: 30, right: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      rssPresets[subscription.source]?.label ??
                          subscription.source.name,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    if (subscription.keyword.isNotEmpty)
                      Text(
                        '关键词：${subscription.keyword}',
                        style: theme.textTheme.bodySmall,
                      ),
                    const SizedBox(height: 2),
                    Text(
                      error ??
                          '${items.isEmpty ? subscription.lastItemCount : items.length} 个条目'
                              '${subscription.autoDownload ? ' · 自动下载已开启' : ''}'
                              '${subscription.lastFetchedMs > 0 ? ' · ${_relativeTime(subscription.lastFetchedMs)}' : ''}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: error != null
                            ? theme.colorScheme.error
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _relativeTime(int millis) {
    final time = DateTime.fromMillisecondsSinceEpoch(millis);
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return '刚刚刷新';
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前刷新';
    if (diff.inHours < 24) return '${diff.inHours} 小时前刷新';
    return '${diff.inDays} 天前刷新';
  }
}

class _HintCard extends StatelessWidget {
  const _HintCard();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, size: 18, color: scheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '订阅只会自动下载「添加订阅之后」发布的新条目，避免一次拉取整部番剧。'
              '想补旧集可以在条目列表里手动点下载。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
