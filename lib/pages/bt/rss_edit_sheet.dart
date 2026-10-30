import 'package:flutter/material.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/modules/rss/rss_models.dart';
import 'package:kazumi/services/rss/rss_controller.dart';
import 'package:kazumi/services/rss/rss_presets.dart';
import 'package:kazumi/services/storage/storage.dart';

/// Bottom sheet for creating or editing a subscription.
class RssEditSheet extends StatefulWidget {
  const RssEditSheet({super.key, this.existing});

  final RssSubscription? existing;

  @override
  State<RssEditSheet> createState() => _RssEditSheetState();
}

class _RssEditSheetState extends State<RssEditSheet> {
  late RssSource _source;
  late final TextEditingController _keyword;
  late final TextEditingController _name;
  late final TextEditingController _customUrl;
  late final TextEditingController _exclude;
  late final TextEditingController _minEpisode;
  late bool _autoDownload;
  bool _saving = false;

  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _source = existing?.source ?? RssSource.mikan;
    _keyword = TextEditingController(text: existing?.keyword ?? '');
    _name = TextEditingController(text: existing?.name ?? '');
    _customUrl = TextEditingController(
      text: existing != null
          ? ((existing.source == RssSource.custom ||
                  existing.source == RssSource.anibt)
              ? existing.url
              : '')
          : (existing == null && _source == RssSource.anibt
              ? 'https://anibt.net/rss/magnets.xml'
              : ''),
    );
    _exclude = TextEditingController(text: existing?.exclude ?? '');
    _minEpisode = TextEditingController(
      text: (existing?.minEpisode ?? 0) > 0
          ? existing!.minEpisode.toString()
          : '',
    );
    _autoDownload = existing?.autoDownload ??
        GStorage.getSetting(SettingsKeys.btDefaultAutoDownload);
  }

  @override
  void dispose() {
    _keyword.dispose();
    _name.dispose();
    _customUrl.dispose();
    _exclude.dispose();
    _minEpisode.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final url = buildFeedUrl(
        source: _source,
        keyword: _keyword.text,
        customUrl: _customUrl.text,
      );
      final name = _name.text.trim().isEmpty
          ? suggestedSubscriptionName(_source, _keyword.text)
          : _name.text.trim();
      final existing = widget.existing;
      final subscription = existing != null
          ? existing.copyWith(
              name: name,
              url: url,
              source: _source,
              keyword: _keyword.text.trim(),
              exclude: _exclude.text.trim(),
              autoDownload: _autoDownload,
              minEpisode: int.tryParse(_minEpisode.text.trim()) ?? 0,
            )
          : RssSubscription(
              id: DateTime.now().microsecondsSinceEpoch.toString(),
              name: name,
              url: url,
              source: _source,
              keyword: _keyword.text.trim(),
              exclude: _exclude.text.trim(),
              autoDownload: _autoDownload,
              minEpisode: int.tryParse(_minEpisode.text.trim()) ?? 0,
              createdAtMs: DateTime.now().millisecondsSinceEpoch,
            );

      final controller = RssController();
      if (existing != null) {
        await controller.updateSubscription(subscription);
      } else {
        await controller.addSubscription(subscription);
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
      KazumiDialog.showToast(
        message: existing != null ? '订阅已更新' : '订阅已添加，正在拉取条目',
      );
    } on ArgumentError catch (e) {
      KazumiDialog.showToast(message: e.message.toString());
    } catch (e) {
      KazumiDialog.showToast(message: '订阅失败：$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final preset = rssPresets[_source]!;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _isEditing ? '编辑订阅' : '添加 RSS 订阅',
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<RssSource>(
              initialValue: _source,
              decoration: const InputDecoration(
                labelText: '订阅源',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final entry in rssPresets.values)
                  DropdownMenuItem(
                    value: entry.source,
                    child: Text(entry.label),
                  ),
              ],
              onChanged: _saving
                  ? null
                  : (value) {
                      if (value == null) return;
                      setState(() {
                        _source = value;
                        if (value == RssSource.anibt &&
                            _customUrl.text.trim().isEmpty) {
                          _customUrl.text =
                              'https://anibt.net/rss/magnets.xml';
                        }
                      });
                    },
            ),
            const SizedBox(height: 6),
            Text(
              preset.description,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            if (preset.supportsKeyword)
              TextField(
                controller: _keyword,
                decoration: InputDecoration(
                  labelText: '搜索关键词',
                  hintText: preset.keywordHint,
                  border: const OutlineInputBorder(),
                ),
              )
            else if (_source == RssSource.custom)
              TextField(
                controller: _customUrl,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'RSS 地址',
                  hintText: 'https://example.com/feed.xml',
                  border: OutlineInputBorder(),
                ),
              )
            else
              TextField(
                controller: _customUrl,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  labelText: '订阅地址',
                  hintText: 'https://anibt.net/rss/magnets.xml',
                  helperText: '默认地址已填好，可按需替换',
                  border: const OutlineInputBorder(),
                ),
              ),
            if (!preset.supportsKeyword) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _keyword,
                decoration: InputDecoration(
                  labelText: '本地筛选关键词（可选）',
                  hintText: preset.keywordHint,
                  helperText: '只在标题包含该关键词时才自动下载，留空表示全部',
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: '显示名称（可选）',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _exclude,
              decoration: const InputDecoration(
                labelText: '排除关键词（可选）',
                hintText: '合集, 简体, 繁体',
                helperText: '多个关键词用英文逗号分隔，命中则跳过',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _minEpisode,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '起始集数（可选）',
                helperText: '例如填 2 可跳过第 1 集，0 或留空表示不限制',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('自动下载新条目'),
              subtitle: const Text('订阅后出现的新条目匹配关键词时自动加入 BT 下载'),
              value: _autoDownload,
              onChanged:
                  _saving ? null : (value) => setState(() => _autoDownload = value),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(_isEditing ? '保存' : '添加订阅'),
            ),
          ],
        ),
      ),
    );
  }
}
