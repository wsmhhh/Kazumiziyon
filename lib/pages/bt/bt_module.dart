import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/pages/bt/bt_page.dart';
import 'package:kazumi/pages/bt/bt_player_page.dart';
import 'package:kazumi/pages/route_error_page.dart';

final btModule = createModule(
  path: '/bt',
  register: (c) {
    c
      ..route(
        '/',
        child: (context, state) => const BtPage(),
      )
      ..route(
        '/player',
        child: (context, state) {
          final args = state.arguments;
          if (args is! BtPlayerArgs) {
            return const RouteErrorPage(message: '播放参数无效，请返回后重试。');
          }
          return BtPlayerPage(args: args);
        },
      );
  },
);
