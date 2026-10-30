import 'dart:async';

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/modules/danmaku/danmaku_search_response.dart';
import 'package:kazumi/pages/my/my_controller.dart';
import 'package:kazumi/services/bt/bt_danmaku_controller.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

class BtPlayerArgs {
  const BtPlayerArgs({
    required this.path,
    required this.title,
    this.subtitle = '',
  });

  final String path;
  final String title;
  final String subtitle;
}

/// Minimal local-file player for BitTorrent content.
///
/// mpv (media_kit) plays a file that is still growing; aria2's sequential
/// piece selection keeps the head of the file ahead of the playhead, so the
/// same route works for both finished and in-progress downloads.
class BtPlayerPage extends StatefulWidget {
  const BtPlayerPage({super.key, required this.args});

  final BtPlayerArgs args;

  @override
  State<BtPlayerPage> createState() => _BtPlayerPageState();
}

class _BtPlayerPageState extends State<BtPlayerPage> {
  late final Player _player;
  late final VideoController _videoController;
  late final BtDanmakuController _danmaku;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final GlobalKey _danmakuKey = GlobalKey();

  bool _controlsVisible = true;
  bool _fullscreen = false;
  String? _error;
  Timer? _hideTimer;
  Timer? _danmakuTimer;
  Duration _position = Duration.zero;
  bool _playing = false;

  @override
  void initState() {
    super.initState();
    _player = Player();
    _videoController = VideoController(_player);
    final shield = inject<MyController>();
    _danmaku = BtDanmakuController(isBlocked: shield.isDanmakuBlocked);
    _danmaku.addListener(_onDanmakuChanged);
    _subscriptions.add(_player.stream.error.listen((message) {
      if (!mounted) return;
      setState(() => _error = message);
    }));
    _subscriptions.add(_player.stream.playing.listen((playing) {
      _playing = playing;
      _scheduleHide();
    }));
    _subscriptions.add(_player.stream.position.listen((position) {
      _position = position;
    }));
    _danmakuTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _danmaku.tick(_position, playing: _playing);
    });
    unawaited(_open());
    unawaited(_danmaku.autoLoad(widget.args.title));
  }

  void _onDanmakuChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _open() async {
    try {
      await _player.open(Media(widget.args.path), play: true);
      _scheduleHide();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      setState(() => _controlsVisible = false);
    });
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleHide();
  }

  Future<void> _toggleFullscreen() async {
    final next = !_fullscreen;
    setState(() => _fullscreen = next);
    if (next) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _danmakuTimer?.cancel();
    _danmaku.removeListener(_onDanmakuChanged);
    _danmaku.dispose();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    unawaited(_player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_fullscreen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _fullscreen) {
          unawaited(_toggleFullscreen());
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _toggleControls,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Center(
                child: Video(
                  controller: _videoController,
                  controls: NoVideoControls,
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: Opacity(
                    opacity: _danmaku.enabled ? 1 : 0,
                    child: DanmakuScreen(
                      key: _danmakuKey,
                      createdController: (controller) {
                        _danmaku.canvasController = controller;
                      },
                      option: _danmakuOption(),
                    ),
                  ),
                ),
              ),
              if (_error != null) _errorView(),
              AnimatedOpacity(
                opacity: _controlsVisible ? 1 : 0,
                duration: const Duration(milliseconds: 180),
                child: IgnorePointer(
                  ignoring: !_controlsVisible,
                  child: _controls(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _errorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.white70, size: 40),
            const SizedBox(height: 12),
            Text(
              _error!,
              style: const TextStyle(color: Colors.white70),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              '边下边播需要顺序下载，刚添加的种子可能需要几秒到几十秒缓冲。',
              style: TextStyle(color: Colors.white38, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  DanmakuOption _danmakuOption() {
    return DanmakuOption(
      area: GStorage.getSetting(SettingsKeys.danmakuArea),
      opacity: GStorage.getSetting(SettingsKeys.danmakuOpacity),
      fontSize: GStorage.getSetting(SettingsKeys.danmakuFontSize),
      duration: GStorage.getSetting(SettingsKeys.danmakuDuration),
      lineHeight: GStorage.getSetting(SettingsKeys.danmakuLineHeight),
      strokeWidth: GStorage.getSetting(SettingsKeys.danmakuBorder)
          ? GStorage.getSetting(SettingsKeys.danmakuBorderSize)
          : 0.0,
      massiveMode: GStorage.getSetting(SettingsKeys.danmakuMassive),
    );
  }

  Future<void> _showDanmakuPicker() async {
    final queryController = TextEditingController(text: _danmaku.searchTitle);
    final episodeController = TextEditingController(
      text: '${_danmaku.episode > 0 ? _danmaku.episode : 1}',
    );
    var results = <DanmakuSearchAnime>[];
    DanmakuSearchAnime? selected = _danmaku.animeId > 0
        ? DanmakuSearchAnime(
            animeId: _danmaku.animeId,
            animeTitle: _danmaku.animeTitle,
            typeDescription: '当前使用',
          )
        : null;
    var searching = false;
    String? searchError;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          Future<void> runSearch() async {
            if (searching) return;
            setDialogState(() {
              searching = true;
              searchError = null;
            });
            try {
              final found = await _danmaku.search(queryController.text);
              if (!dialogContext.mounted) return;
              setDialogState(() {
                results = found;
                searching = false;
                if (selected == null && found.isNotEmpty) {
                  selected = found.first;
                }
                if (found.isEmpty) {
                  searchError = '没有找到匹配的番剧';
                }
              });
            } catch (_) {
              if (!dialogContext.mounted) return;
              setDialogState(() {
                searching = false;
                searchError = '搜索失败，请检查网络';
              });
            }
          }

          return AlertDialog(
            title: const Text('选择弹幕番剧'),
            content: SizedBox(
              width: 460,
              height: 440,
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: queryController,
                          textInputAction: TextInputAction.search,
                          onSubmitted: (_) => runSearch(),
                          decoration: const InputDecoration(
                            hintText: '番剧名，例如：葬送的芙莉莲',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        onPressed: searching ? null : runSearch,
                        icon: searching
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.search),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      SizedBox(
                        width: 110,
                        child: TextField(
                          controller: episodeController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: '集数',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _danmaku.searchTitle.isEmpty
                              ? '按文件名自动识别'
                              : '识别为：${_danmaku.searchTitle}',
                          style: Theme.of(dialogContext).textTheme.bodySmall,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: results.isEmpty
                        ? Center(
                            child: Text(
                              searchError ?? '输入番剧名后点击搜索',
                              textAlign: TextAlign.center,
                            ),
                          )
                        : ListView.builder(
                            itemCount: results.length,
                            itemBuilder: (context, index) {
                              final anime = results[index];
                              final isSelected =
                                  selected?.animeId == anime.animeId;
                              return ListTile(
                                dense: true,
                                leading: Icon(
                                  isSelected
                                      ? Icons.radio_button_checked
                                      : Icons.radio_button_unchecked,
                                  size: 20,
                                ),
                                title: Text(anime.animeTitle),
                                subtitle: anime.typeDescription.isEmpty
                                    ? null
                                    : Text(anime.typeDescription),
                                onTap: () =>
                                    setDialogState(() => selected = anime),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: selected == null
                    ? null
                    : () => Navigator.of(dialogContext).pop(true),
                child: const Text('加载'),
              ),
            ],
          );
        },
      ),
    );

    final chosen = selected;
    if (confirmed == true && chosen != null) {
      final episode = int.tryParse(episodeController.text.trim()) ?? 1;
      await _danmaku.loadFor(chosen.animeId, chosen.animeTitle, episode);
    }
    queryController.dispose();
    episodeController.dispose();
  }

  Widget _controls(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black54, Colors.transparent, Colors.black87],
          stops: [0, .35, 1],
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            Row(
              children: [
                IconButton(
                  onPressed: () {
                    if (_fullscreen) {
                      unawaited(_toggleFullscreen());
                    } else {
                      Navigator.of(context).maybePop();
                    }
                  },
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.args.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (widget.args.subtitle.isNotEmpty)
                        Text(
                          widget.args.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                          ),
                        ),
                      if (_danmaku.statusText != null)
                        Text(
                          _danmaku.statusText!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: _danmaku.error != null
                                ? Colors.orangeAccent
                                : Colors.white54,
                            fontSize: 11,
                          ),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '搜索弹幕番剧',
                  onPressed: _showDanmakuPicker,
                  icon: const Icon(Icons.search_rounded,
                      color: Colors.white),
                ),
                IconButton(
                  tooltip: _danmaku.enabled ? '关闭弹幕' : '开启弹幕',
                  onPressed: _danmaku.hasData
                      ? _danmaku.toggle
                      : _showDanmakuPicker,
                  icon: Icon(
                    _danmaku.loading
                        ? Icons.hourglass_empty_rounded
                        : _danmaku.enabled
                            ? Icons.subtitles_rounded
                            : Icons.subtitles_off_rounded,
                    color: _danmaku.enabled ? Colors.white : Colors.white54,
                  ),
                ),
                IconButton(
                  onPressed: _toggleFullscreen,
                  icon: Icon(
                    _fullscreen
                        ? Icons.fullscreen_exit
                        : Icons.fullscreen_rounded,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
            const Spacer(),
            StreamBuilder<bool>(
              stream: _player.stream.buffering,
              initialData: true,
              builder: (context, snapshot) {
                if (snapshot.data != true) return const SizedBox.shrink();
                return const Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white70,
                    ),
                  ),
                );
              },
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 16, 8),
              child: Row(
                children: [
                  StreamBuilder<bool>(
                    stream: _player.stream.playing,
                    initialData: false,
                    builder: (context, snapshot) {
                      final playing = snapshot.data ?? false;
                      return IconButton(
                        iconSize: 42,
                        onPressed: () =>
                            playing ? _player.pause() : _player.play(),
                        icon: Icon(
                          playing ? Icons.pause_circle : Icons.play_circle,
                          color: Colors.white,
                        ),
                      );
                    },
                  ),
                  Expanded(child: _progressBar()),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _progressBar() {
    return StreamBuilder<Duration>(
      stream: _player.stream.position,
      initialData: Duration.zero,
      builder: (context, positionSnapshot) {
        return StreamBuilder<Duration>(
          stream: _player.stream.duration,
          initialData: Duration.zero,
          builder: (context, durationSnapshot) {
            final position = positionSnapshot.data ?? Duration.zero;
            final duration = durationSnapshot.data ?? Duration.zero;
            final total = duration.inMilliseconds.toDouble();
            final value = position.inMilliseconds
                .clamp(0, duration.inMilliseconds)
                .toDouble();
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 6),
                  ),
                  child: Slider(
                    value: total <= 0 ? 0 : value,
                    max: total <= 0 ? 1 : total,
                    onChanged: total <= 0
                        ? null
                        : (next) => _player
                            .seek(Duration(milliseconds: next.round())),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        _formatDuration(position),
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                      Text(
                        _formatDuration(duration),
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  String _formatDuration(Duration value) {
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }
}
