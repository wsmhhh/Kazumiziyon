import 'package:flutter/material.dart';
import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/modules/rss/rss_models.dart';
import 'package:kazumi/pages/bt/rss_edit_sheet.dart';
import 'package:kazumi/services/bt/bt_download_controller.dart';
import 'package:kazumi/services/rss/rss_controller.dart';
import 'package:kazumi/utils/format.dart';

class RssFeedPage extends StatefulWidget {
  const RssFeedPage({super.key, required this.subscriptionId});

  final String subscriptionId;

  @override
  State<RssFeedPage> createState() => _RssFeedPageState();
}

class _RssFeedPageState extends State<RssFeedPage> {
  final RssController _controller = RssController();
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  RssSubscription? get _subscription {
    for (final subscription in _controller.subscriptions) {
      if (subscription.id == widget.subscriptionId) return subscription;
    }
    return null;
  }

  Future<void> _refresh() async {
    final subscription = _subscription;
    if (subscription == null || _refreshing) return;
    setState(() => _refreshing = true);
    try {
      await _controller.refreshSubscription(subscription);
    } catch (e) {
      if (!mounted) return;
      KazumiDialog.showToast(
        message: _controller.errorFor(subscription.id) ?? 'RSS 刷新失败',
      );
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _edit() async {
    final subscription = _subscription;
    if (subscription == null) return;
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => RssEditSheet(existing: subscription),
    );
  }

  Future<void> _download(RssItem item) async {
    if (!item.downloadable) {
      KazumiDialog.showToast(message: '该条目没有可用的种子或磁力链接');
      return;
    }
    final gid = await BtDownloadController().addDownloadUri(item.downloadUri);
    if (!mounted) return;
    KazumiDialog.showToast(
      message: gid == null
          ? (BtDownloadController().lastError ?? '添加失败')
          : '已加入 BT 下载，可在「BT 下载」中查看',
    );
  }

  @override
  Widget build(BuildContext context) {
    final subscription = _subscription;
    if (subscription == null) {
      return Scaffold(
        appBar: const SysAppBar(title: Text('RSS 订阅')),
        body: const Center(child: Text('订阅不存在或已被删除')),
      );
    }
    final items = _controller.itemsFor(subscription.id);
    final error = _controller.errorFor(subscription.id);
    return Scaffold(
      appBar: SysAppBar(
        title: Text(subscription.name),
        actions: [
          IconButton(
            tooltip: '编辑订阅',
            onPressed: _edit,
            icon: const Icon(Icons.edit_outlined),
          ),
          IconButton(
            tooltip: '刷新',
            onPressed: _refreshing ? null : _refresh,
            icon: _refreshing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            if (error != null) _errorCard(error),
            if (subscription.autoDownload)
              _autoDownloadHint(subscription)
            else
              _autoDownloadOffHint(),
            const SizedBox(height: 8),
            if (items.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 80),
                child: Column(
                  children: [
                    Icon(
                      Icons.inbox_rounded,
                      size: 48,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                    const SizedBox(height: 10),
                    const Text('暂无条目，下拉刷新试试'),
                  ],
                ),
              )
            else
              ...items.map(_itemCard),
          ],
        ),
      ),
    );
  }

  Widget _errorCard(String error) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Text(
          error,
          style: TextStyle(color: scheme.onErrorContainer),
        ),
      ),
    );
  }

  Widget _autoDownloadHint(RssSubscription subscription) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: Text(
        '自动下载已开启'
        '${subscription.keyword.isNotEmpty ? '，关键词：${subscription.keyword}' : ''}',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }

  Widget _autoDownloadOffHint() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: Text(
        '自动下载未开启，需要手动点击条目右侧的下载按钮',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }

  Widget _itemCard(RssItem item) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    item.title,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '加入 BT 下载',
                  onPressed:
                      item.downloadable ? () => _download(item) : null,
                  icon: const Icon(Icons.download_rounded),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                if (item.episode > 0) _chip('第 ${item.episode} 集'),
                if (item.resolution.isNotEmpty) _chip(item.resolution),
                if (item.group.isNotEmpty) _chip(item.group),
                if (item.sizeBytes > 0) _chip(formatBytes(item.sizeBytes)),
                if (item.magnet.isNotEmpty) _chip('磁力'),
                if (!item.downloadable) _chip('无下载链接'),
              ],
            ),
            if (item.publishedAt != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _formatDate(item.publishedAt!),
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: scheme.outline),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _chip(String text) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall,
      ),
    );
  }

  String _formatDate(DateTime date) {
    final local = date.toLocal();
    String pad(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${pad(local.month)}-${pad(local.day)} '
        '${pad(local.hour)}:${pad(local.minute)}';
  }
}
