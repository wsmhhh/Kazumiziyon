import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/bean/settings/settings_list.dart';
import 'package:kazumi/services/bt/bt_download_controller.dart';
import 'package:kazumi/services/download/download_directory_service.dart';
import 'package:kazumi/services/storage/storage.dart';

class BtSettingsPage extends StatefulWidget {
  const BtSettingsPage({super.key});

  @override
  State<BtSettingsPage> createState() => _BtSettingsPageState();
}

class _BtSettingsPageState extends State<BtSettingsPage> {
  final BtDownloadController _controller = BtDownloadController();

  late int _maxConcurrent;
  late int _rssInterval;
  late bool _defaultAutoDownload;
  String _aria2Path = '';
  String _extraArgs = '';
  String _downloadDirectory = '';

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
    _maxConcurrent = GStorage.getSetting(SettingsKeys.btMaxConcurrent);
    _rssInterval = GStorage.getSetting(SettingsKeys.btRssIntervalMinutes);
    _defaultAutoDownload =
        GStorage.getSetting(SettingsKeys.btDefaultAutoDownload);
    _aria2Path = GStorage.getSetting(SettingsKeys.btAria2Path);
    _extraArgs = GStorage.getSetting(SettingsKeys.btAria2Args);
    _loadDirectory();
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadDirectory() async {
    try {
      final directory =
          await DownloadDirectoryService().getDownloadDirectory();
      if (mounted) setState(() => _downloadDirectory = directory);
    } catch (_) {
      if (mounted) setState(() => _downloadDirectory = '默认下载目录');
    }
  }

  Future<void> _pickBinary() async {
    final picked = await FilePicker.platform.pickFiles();
    final path = picked?.files.single.path;
    if (path == null) return;
    await GStorage.putSetting(SettingsKeys.btAria2Path, path);
    setState(() => _aria2Path = path);
    KazumiDialog.showToast(message: '已保存 aria2 路径，重启引擎后生效');
  }

  Future<void> _editExtraArgs() async {
    final textController = TextEditingController(text: _extraArgs);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('额外 aria2 参数'),
        content: TextField(
          controller: textController,
          maxLines: 3,
          minLines: 1,
          decoration: const InputDecoration(
            hintText: '例如 --bt-tracker=udp://tracker.example:80/announce',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(textController.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (value == null) return;
    await GStorage.putSetting(SettingsKeys.btAria2Args, value.trim());
    setState(() => _extraArgs = value.trim());
    KazumiDialog.showToast(message: '参数已保存，重启引擎后生效');
  }

  Future<void> _restartEngine() async {
    await _controller.restartEngine();
    if (!mounted) return;
    KazumiDialog.showToast(
      message: _controller.isEngineRunning ? 'BT 引擎已重启' : 'BT 引擎启动失败',
    );
  }

  @override
  Widget build(BuildContext context) {
    final running = _controller.isEngineRunning;
    return SettingsDetailScaffold(
      title: const Text('BT 下载设置'),
      body: SettingsList(
        sections: [
          SettingsSection(
            title: const Text('引擎状态'),
            tiles: [
              SettingsTile(
                leading: Icons.memory_rounded,
                title: Text(running ? 'aria2 运行中' : 'aria2 未运行'),
                description: Text(
                  running
                      ? '${_controller.aria2Version.isEmpty ? '版本未知' : 'aria2 ${_controller.aria2Version}'}'
                          '${_controller.freePort > 0 ? ' · 端口 ${_controller.freePort}' : ''}'
                      : (_controller.lastError ?? '点击右侧按钮启动引擎'),
                ),
                trailing: TextButton(
                  onPressed: running ? _restartEngine : _controller.startEngine,
                  child: Text(running ? '重启' : '启动'),
                ),
              ),
              if (running)
                SettingsTile(
                  leading: Icons.stop_circle_outlined,
                  title: const Text('停止引擎'),
                  description: const Text('停止后所有 BT 任务会暂停，重启应用后可重新开始'),
                  onPressed: (_) => _controller.stopEngine(),
                ),
              SettingsTile(
                leading: Icons.terminal_rounded,
                title: const Text('aria2 可执行文件'),
                description: Text(
                  _aria2Path.isEmpty
                      ? (Platform.isAndroid
                          ? '使用内置 libaria2c.so（打包在 jniLibs 中）'
                          : '自动在应用目录或系统 PATH 中查找 aria2c')
                      : _aria2Path,
                ),
                trailing: Platform.isAndroid
                    ? null
                    : IconButton(
                        tooltip: '选择文件',
                        onPressed: _pickBinary,
                        icon: const Icon(Icons.folder_open_rounded),
                      ),
                onPressed: Platform.isAndroid ? null : (_) => _pickBinary(),
              ),
              SettingsTile(
                leading: Icons.tune_rounded,
                title: const Text('额外启动参数'),
                description: Text(
                  _extraArgs.isEmpty ? '未设置（可选，用于自定义 tracker 等）' : _extraArgs,
                ),
                onPressed: (_) => _editExtraArgs(),
              ),
            ],
          ),
          SettingsSection(
            title: const Text('下载'),
            tiles: [
              SettingsSliderTile(
                leading: Icons.download_rounded,
                title: const Text('同时下载任务数'),
                description: const Text('aria2 同时进行的 BT 任务上限'),
                value: _maxConcurrent.toDouble(),
                min: 1,
                max: 10,
                divisions: 9,
                valueLabel: '$_maxConcurrent 个',
                onChanged: (value) {
                  setState(() => _maxConcurrent = value.toInt());
                  GStorage.putSetting(
                    SettingsKeys.btMaxConcurrent,
                    _maxConcurrent,
                  );
                },
              ),
              SettingsTile(
                leading: Icons.folder_copy_rounded,
                title: const Text('保存位置'),
                description: Text(
                  _downloadDirectory.isEmpty ? '正在读取…' : _downloadDirectory,
                ),
                onPressed: (_) => context.pushNamed('/settings/download-settings'),
              ),
            ],
          ),
          SettingsSection(
            title: const Text('RSS'),
            tiles: [
              SettingsSliderTile(
                leading: Icons.schedule_rounded,
                title: const Text('自动检查间隔'),
                description: const Text('应用运行时按此间隔刷新所有启用的订阅'),
                value: _rssInterval.toDouble(),
                min: 5,
                max: 240,
                divisions: 47,
                valueLabel: '$_rssInterval 分钟',
                onChanged: (value) {
                  setState(() => _rssInterval = value.toInt());
                  GStorage.putSetting(
                    SettingsKeys.btRssIntervalMinutes,
                    _rssInterval,
                  );
                  KazumiDialog.showToast(message: '重新打开应用后生效');
                },
              ),
              SettingsTile.switchTile(
                leading: Icons.rss_feed_rounded,
                title: const Text('新订阅默认自动下载'),
                description: const Text('添加 RSS 订阅时默认勾选自动下载新条目'),
                initialValue: _defaultAutoDownload,
                onToggle: (value) {
                  setState(
                      () => _defaultAutoDownload = value ?? !_defaultAutoDownload);
                  GStorage.putSetting(
                    SettingsKeys.btDefaultAutoDownload,
                    _defaultAutoDownload,
                  );
                },
              ),
              SettingsTile(
                leading: Icons.list_alt_rounded,
                title: const Text('管理 RSS 订阅'),
                onPressed: (_) => context.pushNamed('/settings/rss'),
              ),
            ],
          ),
          if (Platform.isAndroid)
            SettingsSection(
              title: const Text('内置引擎说明'),
              tiles: [
                SettingsTile(
                  leading: Icons.info_outline_rounded,
                  title: const Text('如何打包 aria2'),
                  description: const Text(
                    'Android 10 起不能再执行应用数据目录中的二进制，因此需要把 aria2c '
                    '重命名为 libaria2c.so 放进 android/app/src/main/jniLibs/<abi>/'
                    '（arm64-v8a、armeabi-v7a、x86_64），随 APK 一起安装。'
                    '仓库中的 tool/fetch_aria2_android.sh 可自动下载静态 aria2c 并打包。',
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
