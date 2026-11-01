import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:flutter_modular/flutter_modular.dart';

import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/pages/menu/route_visibility.dart';
import 'package:kazumi/pages/my/my_controller.dart';
import 'package:kazumi/pages/my/my_space_view.dart';
import 'package:kazumi/services/player/local_video_picker.dart';

class MyPage extends StatefulWidget {
  const MyPage({super.key, required this.controller});

  final MyController controller;

  @override
  State<MyPage> createState() => _MyPageState();
}

class _MyPageState extends State<MyPage> {
  bool _attached = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _setAttached(!RouteVisibility.isCoveredOf(context));
  }

  @override
  void didUpdateWidget(covariant MyPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_attached && oldWidget.controller != widget.controller) {
      oldWidget.controller.detach();
      widget.controller.attach();
    }
  }

  @override
  void dispose() {
    _setAttached(false);
    super.dispose();
  }

  void _setAttached(bool value) {
    if (_attached == value) return;
    _attached = value;
    if (value) {
      widget.controller.attach();
    } else {
      widget.controller.detach();
    }
  }

  static const Map<MyDestination, String> _routes = {
    MyDestination.theme: '/settings/theme',
    MyDestination.player: '/settings/player',
    MyDestination.danmaku: '/settings/danmaku/',
    MyDestination.rules: '/settings/plugin/',
    MyDestination.history: '/settings/history/',
    MyDestination.downloads: '/settings/download/',
    MyDestination.sync: '/settings/sync',
    MyDestination.storage: '/settings/storage',
    MyDestination.about: '/settings/about/',
  };

  void _open(MyDestination destination) {
    final route = _routes[destination];
    if (route == null) {
      // 本地播放不是独立页面，先选择视频再跳转播放器。
      unawaited(pickAndOpenLocalVideos(context));
      return;
    }
    context.pushNamed(route);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SysAppBar(
        toolbarHeight: 72,
        title: Text(
          '我的',
          style: Theme.of(context)
              .textTheme
              .headlineSmall
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
        needTopOffset: false,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: MySettingsButton(
              onTap: () => context.pushNamed('/settings/'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        bottom: false,
        child: Observer(
          builder: (context) => MySpaceView(
            stats: widget.controller.watchStats,
            onOpen: _open,
          ),
        ),
      ),
    );
  }
}
