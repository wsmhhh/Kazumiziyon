import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/modules/bt/bt_task.dart';
import 'package:kazumi/pages/bt/bt_player_page.dart';
import 'package:kazumi/services/bt/bt_download_controller.dart';
import 'package:kazumi/utils/format.dart';

class BtPage extends StatefulWidget {
  const BtPage({super.key});

  @override
  State<BtPage> createState() => _BtPageState();
}

class _BtPageState extends State<BtPage> {
  final BtDownloadController _controller = BtDownloadController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
    if (!_controller.isEngineRunning) {
      _controller.startEngine();
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _addMagnet() async {
    final textController = TextEditingController();
    final uri = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加 BT 任务'),
        content: TextField(
          controller: textController,
          autofocus: true,
          maxLines: 3,
          minLines: 1,
          decoration: const InputDecoration(
            hintText: '粘贴磁力链接或 .torrent 地址',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(context).pop();
              final file = await FilePicker.platform.pickFiles(
                type: FileType.custom,
                allowedExtensions: const ['torrent'],
              );
              final path = file?.files.single.path;
              if (path == null) return;
              final gid = await _controller.addTorrentFile(path);
              _afterAdd(gid);
            },
            child: const Text('选择种子文件'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop(textController.text.trim()),
            child: const Text('添加'),
          ),
        ],
      ),
    );

    if (uri == null || uri.isEmpty) return;
    if (!uri.startsWith('magnet:') &&
        !uri.startsWith('http://') &&
        !uri.startsWith('https://')) {
      KazumiDialog.showToast(message: '请输入磁力链接或 torrent 地址');
      return;
    }
    final gid = uri.startsWith('magnet:')
        ? await _controller.addUri(uri)
        : await _controller.addTorrentUrl(uri);
    _afterAdd(gid);
  }

  void _afterAdd(String? gid) {
    if (gid == null) {
      KazumiDialog.showToast(
        message: _controller.lastError ?? '添加任务失败',
      );
      return;
    }
    KazumiDialog.showToast(message: '已添加，开始解析种子');
  }

  void _play(BtTask task) {
    final path = task.videoPath;
    if (path == null) {
      KazumiDialog.showToast(message: '种子元数据尚未下载完成，请稍候');
      return;
    }
    if (!File(path).existsSync()) {
      KazumiDialog.showToast(
        message: task.isComplete
            ? '文件不存在，可能已被移动或删除'
            : '文件还没有写入磁盘，请等几秒后再试',
      );
      return;
    }
    context.pushNamed(
      '/bt/player',
      arguments: BtPlayerArgs(
        path: path,
        title: task.displayName,
        subtitle: task.isComplete
            ? '已完成'
            : '边下边播 · ${(task.progress * 100).toStringAsFixed(1)}%',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tasks = _controller.downloading;
    final completed = _controller.completed;
    return Scaffold(
      appBar: SysAppBar(
        title: const Text('BT 下载'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _controller.refreshNow,
            icon: const Icon(Icons.refresh_rounded),
          ),
          IconButton(
            tooltip: 'RSS 订阅',
            onPressed: () => context.pushNamed('/settings/rss'),
            icon: const Icon(Icons.rss_feed_rounded),
          ),
          IconButton(
            tooltip: 'BT 设置',
            onPressed: () => context.pushNamed('/settings/bt'),
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addMagnet,
        icon: const Icon(Icons.add_rounded),
        label: const Text('添加任务'),
      ),
      body: RefreshIndicator(
        onRefresh: _controller.refreshNow,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
          children: [
            _engineCard(),
            if (_controller.lastError != null) _errorCard(),
            const SizedBox(height: 8),
            _sectionTitle('下载中', tasks.length),
            if (tasks.isEmpty)
              _empty('没有进行中的任务', Icons.downloading_rounded)
            else
              ...tasks.map(_taskCard),
            const SizedBox(height: 8),
            _sectionTitle('已完成', completed.length),
            if (completed.isEmpty)
              _empty('还没有已完成的 BT 任务', Icons.check_circle_outline)
            else
              ...completed.map(_taskCard),
          ],
        ),
      ),
    );
  }

  Widget _engineCard() {
    final running = _controller.isEngineRunning;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
        child: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: running ? Colors.green : scheme.outline,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _controller.isStarting
                        ? 'BT 引擎启动中…'
                        : running
                            ? 'BT 引擎运行中'
                            : 'BT 引擎未运行',
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    running
                        ? '↓ ${formatSpeed(_controller.downloadSpeed.toDouble())}'
                            '   ↑ ${formatSpeed(_controller.uploadSpeed.toDouble())}'
                            '${_controller.freePort > 0 ? '   端口 ${_controller.freePort}' : ''}'
                        : _controller.aria2Version.isEmpty
                            ? '需要内置 aria2 引擎'
                            : 'aria2 ${_controller.aria2Version}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: _controller.isStarting
                  ? null
                  : running
                      ? _controller.stopEngine
                      : _controller.startEngine,
              child: Text(running ? '停止' : '启动'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _errorCard() {
    final scheme = Theme.of(context).colorScheme;
    final message = _controller.lastError!;
    return Card(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              message,
              style: TextStyle(color: scheme.onErrorContainer),
            ),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => context.pushNamed('/settings/bt'),
                child: const Text('查看 BT 设置'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String title, int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
      child: Row(
        children: [
          Text(
            title,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(width: 8),
          Text(
            '$count',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _empty(String message, IconData icon) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Column(
        children: [
          Icon(icon, size: 40, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 8),
          Text(message, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }

  Widget _taskCard(BtTask task) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isPaused = task.isPaused;
    final hasVideo = task.primaryVideoFile != null;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    task.displayName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  tooltip: isPaused ? '继续' : '暂停',
                  visualDensity: VisualDensity.compact,
                  onPressed: task.isComplete || task.isFailed
                      ? null
                      : () => isPaused
                          ? _controller.resume(task)
                          : _controller.pause(task),
                  icon: Icon(
                    isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                  ),
                ),
                IconButton(
                  tooltip: '删除任务',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _confirmRemove(task),
                  icon: const Icon(Icons.delete_outline_rounded),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: task.progress,
                minHeight: 6,
                backgroundColor: scheme.surfaceContainerHighest,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${formatBytes(task.completedLength)} / '
                    '${formatBytes(task.totalLength)}'
                    '  ·  ${(task.progress * 100).toStringAsFixed(1)}%',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                if (!task.isComplete && !task.isFailed)
                  Text(
                    isPaused
                        ? '已暂停'
                        : '↓ ${formatSpeed(task.downloadSpeed.toDouble())}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: isPaused ? scheme.outline : scheme.primary,
                    ),
                  ),
                if (task.isComplete)
                  Text(
                    '已完成',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.primary),
                  ),
                if (task.isFailed)
                  Text(
                    '失败',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.error),
                  ),
              ],
            ),
            if (task.isFailed && task.errorMessage.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  task.errorMessage,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.error),
                ),
              ),
            Row(
              children: [
                TextButton.icon(
                  onPressed: hasVideo ? () => _play(task) : null,
                  icon: const Icon(Icons.play_circle_outline_rounded, size: 20),
                  label: Text(task.isComplete ? '播放' : '边下边播'),
                ),
                if (task.isMetadata)
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Text(
                      '正在获取种子信息…',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmRemove(BtTask task) async {
    final confirmed = await KazumiDialog.show<bool>(
      builder: (context) => AlertDialog(
        title: const Text('删除任务'),
        content: Text(
          '将停止「${task.displayName}」并从任务列表移除。已下载的文件会保留在下载目录中。',
        ),
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
      await _controller.removeTask(task);
    }
  }
}
