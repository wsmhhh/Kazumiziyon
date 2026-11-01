import 'package:flutter/material.dart';

class PlayerContentTabs extends StatelessWidget {
  const PlayerContentTabs({
    super.key,
    required this.controller,
    required this.onEpisodesSelected,
    this.showComments = true,
  });

  final TabController controller;
  final VoidCallback onEpisodesSelected;

  /// 本地文件没有关联的番剧条目，此时只展示选集。
  final bool showComments;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final height = (MediaQuery.textScalerOf(context).scale(14) * 1.5 + 16)
        .clamp(48.0, double.infinity);

    return Material(
      color: colors.surface,
      child: TabBar(
        controller: controller,
        padding: EdgeInsets.zero,
        dividerHeight: 0,
        splashBorderRadius: BorderRadius.zero,
        indicatorSize: TabBarIndicatorSize.label,
        indicatorWeight: 4,
        labelColor: colors.primary,
        unselectedLabelColor: colors.onSurfaceVariant,
        labelStyle: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w700,
        ),
        unselectedLabelStyle: theme.textTheme.titleSmall,
        labelPadding: const EdgeInsets.symmetric(horizontal: 4),
        onTap: (index) {
          if (index == 0) onEpisodesSelected();
        },
        tabs: [
          Tab(text: '选集', height: height),
          if (showComments) Tab(text: '评论', height: height),
        ],
      ),
    );
  }
}
