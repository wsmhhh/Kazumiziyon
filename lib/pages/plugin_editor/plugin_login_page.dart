import 'dart:io' as io;

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/bean/widget/loading_indicator.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/plugin/plugin_cookie_manager.dart';
import 'package:kazumi/utils/http_headers.dart';

/// 网站登录页
///
/// Android / iOS / macOS 使用 App 内嵌 WebView 打开网站登录页，由用户自行完成
/// 账号密码、扫码或验证码登录；确认后抓取站点 Cookie 与 User-Agent 写入
/// [PluginCookieManager]，后续规则请求会自动携带。
///
/// 打开页面前会先把已保存的 Cookie 注入 WebView，凭证仍然有效时无需重复登录。
/// Windows / Linux 没有可交互的内嵌 WebView，退化为「浏览器登录后粘贴 Cookie」。
class PluginLoginPage extends StatefulWidget {
  const PluginLoginPage({super.key, required this.plugin});

  final Plugin plugin;

  @override
  State<PluginLoginPage> createState() => _PluginLoginPageState();
}

class _PluginLoginPageState extends State<PluginLoginPage> {
  final _fallbackUrlController = TextEditingController();
  final _fallbackCookieController = TextEditingController();

  PlatformInAppWebViewController? _controller;
  PlatformInAppWebViewWidget? _webView;
  String _initialUrl = '';
  String _currentUrl = '';
  int _progress = 0;
  bool _canGoBack = false;
  bool _preparing = true;
  bool _saving = false;
  bool _desktopMode = true;
  String? _loadError;

  bool get _supportsEmbeddedWebView =>
      io.Platform.isAndroid ||
      io.Platform.isIOS ||
      io.Platform.isMacOS;

  @override
  void initState() {
    super.initState();
    _initialUrl = _resolveInitialUrl();
    _fallbackUrlController.text = _initialUrl;
    if (_supportsEmbeddedWebView) {
      _prepareWebView();
    } else {
      _preparing = false;
    }
  }

  @override
  void dispose() {
    _fallbackUrlController.dispose();
    _fallbackCookieController.dispose();
    super.dispose();
  }

  /// 默认打开上次完成登录的页面，其次是规则站点首页。
  String _resolveInitialUrl() {
    final manager = PluginCookieManager.instance;
    final saved = _normalizeUrl(manager.loginUrlFor(widget.plugin.name));
    if (saved.isNotEmpty) return saved;
    final base = _normalizeUrl(widget.plugin.baseUrl);
    if (base.isNotEmpty) return base;
    final searchUri = Uri.tryParse(widget.plugin.searchURL.trim());
    if (searchUri != null &&
        searchUri.hasScheme &&
        searchUri.host.isNotEmpty) {
      return '${searchUri.scheme}://${searchUri.host}';
    }
    return '';
  }

  /// 只接受带协议和域名的绝对地址，避免 WebUri 构造时抛异常。
  String _normalizeUrl(String candidate) {
    final uri = Uri.tryParse(candidate.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return '';
    return uri.toString();
  }

  Future<void> _prepareWebView() async {
    await PluginCookieManager.instance.init();
    if (!mounted) return;
    if (_initialUrl.isEmpty) {
      setState(() => _preparing = false);
      return;
    }
    try {
      await _seedCookies();
    } catch (error) {
      KazumiLogger().d('[PluginLogin] seed cookies failed: $error');
    }
    if (!mounted) return;
    setState(() {
      _webView = _buildWebView();
      _preparing = false;
    });
  }

  /// 把已保存的 Cookie 注入 WebView 的 Cookie 存储，避免登录状态丢失。
  Future<void> _seedCookies() async {
    final saved = PluginCookieManager.instance.cookiesFor(widget.plugin.name);
    if (saved.isEmpty) return;
    final cookieManager = PlatformCookieManager(
      const PlatformCookieManagerCreationParams(),
    );
    for (final cookie in saved) {
      final domain = cookie.domain?.trim() ?? '';
      final host = domain.startsWith('.') ? domain.substring(1) : domain;
      final url = host.isEmpty
          ? _initialUrl
          : 'https://$host${cookie.path ?? '/'}';
      try {
        await cookieManager.setCookie(
          url: WebUri(url),
          name: cookie.name,
          value: cookie.value,
          domain: domain.isEmpty ? null : domain,
          path: cookie.path ?? '/',
          expiresDate: cookie.expires?.millisecondsSinceEpoch,
          isSecure: cookie.secure,
          isHttpOnly: cookie.httpOnly,
        );
      } catch (error) {
        KazumiLogger().d('[PluginLogin] seed cookie failed: $error');
      }
    }
  }

  PlatformInAppWebViewWidget _buildWebView() {
    return PlatformInAppWebViewWidget(
      PlatformInAppWebViewWidgetCreationParams(
        initialUrlRequest: URLRequest(url: WebUri(_initialUrl)),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          domStorageEnabled: true,
          databaseEnabled: true,
          thirdPartyCookiesEnabled: true,
          sharedCookiesEnabled: true,
          cacheEnabled: true,
          mediaPlaybackRequiresUserGesture: false,
          supportMultipleWindows: false,
          userAgent: _resolveUserAgent(),
          // 桌面视图：按站点桌面宽度排版并允许双指缩放，
          // 避免部分只提供电脑版界面的站点在手机上无法操作。
          useWideViewPort: true,
          loadWithOverviewMode: true,
          supportZoom: true,
          builtInZoomControls: true,
          displayZoomControls: false,
        ),
        onWebViewCreated: (controller) {
          _controller = controller;
        },
        onLoadStart: (controller, url) {
          if (!mounted) return;
          setState(() {
            _loadError = null;
            _progress = 0;
            _currentUrl = url?.toString() ?? _currentUrl;
          });
        },
        onLoadStop: (controller, url) {
          if (!mounted) return;
          setState(() {
            _currentUrl = url?.toString() ?? _currentUrl;
            _progress = 100;
          });
          _refreshCanGoBack();
        },
        onProgressChanged: (controller, progress) {
          if (!mounted) return;
          setState(() => _progress = progress);
        },
        onUpdateVisitedHistory: (controller, url, isReload) {
          if (!mounted || url == null) return;
          setState(() => _currentUrl = url.toString());
          _refreshCanGoBack();
        },
        onReceivedError: (controller, request, error) {
          if (!mounted || request.isForMainFrame != true) return;
          setState(() => _loadError = error.description);
        },
      ),
    );
  }

  /// 解析登录页 WebView 的 User-Agent。
  ///
  /// 桌面模式优先复用与当前模式匹配的已保存 UA（保持 Cookie 指纹一致），
  /// 否则使用内置桌面 Chrome UA；移动模式交给系统默认移动 UA。
  String? _resolveUserAgent() {
    final saved =
        PluginCookieManager.instance.userAgentFor(widget.plugin.name)?.trim();
    final ruleUserAgent = widget.plugin.userAgent.trim();
    for (final candidate in <String>[
      if (saved != null) saved,
      ruleUserAgent,
    ]) {
      if (candidate.isEmpty) continue;
      if (_looksMobile(candidate) != _desktopMode) return candidate;
    }
    return _desktopMode ? getRandomUA() : null;
  }

  bool _looksMobile(String userAgent) {
    return RegExp(
      r'Mobi|Android|iPhone|iPad|iPod|HarmonyOS',
      caseSensitive: false,
    ).hasMatch(userAgent);
  }

  /// 在桌面版与移动版网页之间切换，并停留在当前地址。
  Future<void> _toggleDesktopMode() async {
    if (_preparing) return;
    var target = _currentUrl;
    final controller = _controller;
    if (controller != null) {
      try {
        target = (await controller.getUrl())?.toString() ?? target;
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _desktopMode = !_desktopMode;
      if (target.trim().isNotEmpty) _initialUrl = target;
      _currentUrl = target;
      _controller = null;
      _webView = null;
      _preparing = true;
    });
    await _prepareWebView();
  }

  Future<void> _refreshCanGoBack() async {
    final controller = _controller;
    if (controller == null) return;
    try {
      final canGoBack = await controller.canGoBack();
      if (!mounted) return;
      setState(() => _canGoBack = canGoBack);
    } catch (_) {}
  }

  void _showMessage(String message) {
    KazumiDialog.showToast(message: message);
  }

  Future<void> _openUrl(String raw) async {
    var value = raw.trim();
    if (value.isEmpty) return;
    if (!value.contains('://')) value = 'https://$value';
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      _showMessage('登录页地址无效');
      return;
    }
    final controller = _controller;
    if (controller != null) {
      await controller.loadUrl(urlRequest: URLRequest(url: WebUri(value)));
      return;
    }
    // 规则没有站点地址时，用用户输入的地址创建登录 WebView。
    setState(() {
      _initialUrl = value;
      _preparing = true;
    });
    await _prepareWebView();
  }

  Future<void> _editLoginUrl() async {
    final input = TextEditingController(
      text: _currentUrl.isNotEmpty ? _currentUrl : _initialUrl,
    );
    final value = await KazumiDialog.show<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('登录页地址'),
        content: TextField(
          controller: input,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: 'https://example.com/login',
            helperText: '默认使用规则站点首页，可改成站点实际的登录页',
          ),
          onSubmitted: (text) => Navigator.of(dialogContext).pop(text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(input.text),
            child: const Text('打开'),
          ),
        ],
      ),
    );
    input.dispose();
    if (!mounted) return;
    if (value == null || value.trim().isEmpty) return;
    await _openUrl(value);
  }

  /// 把 flutter_inappwebview 的 Cookie 转成用于请求的 dart:io Cookie。
  io.Cookie? _toIoCookie(Cookie cookie, Uri fallbackUri) {
    final name = cookie.name.trim();
    if (name.isEmpty) return null;
    try {
      final parsed = io.Cookie(name, cookie.value?.toString() ?? '');
      final domain = (cookie.domain ?? fallbackUri.host).trim();
      if (domain.isNotEmpty) {
        parsed.domain =
            domain.startsWith('.') ? domain.substring(1) : domain;
      }
      final path = cookie.path ?? '/';
      parsed.path = path.isEmpty ? '/' : path;
      final expiresDate = cookie.expiresDate;
      if (expiresDate != null && expiresDate > 0) {
        parsed.expires = DateTime.fromMillisecondsSinceEpoch(expiresDate);
      }
      parsed.secure = cookie.isSecure == true;
      parsed.httpOnly = cookie.isHttpOnly == true;
      return parsed;
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveLogin() async {
    final controller = _controller;
    if (controller == null || _saving) return;
    setState(() => _saving = true);
    try {
      final currentUrl = (await controller.getUrl())?.toString() ?? _currentUrl;
      final targets = <String>{};
      for (final candidate in <String>[
        currentUrl,
        _initialUrl,
        widget.plugin.baseUrl,
      ]) {
        final uri = Uri.tryParse(candidate.trim());
        if (uri != null && uri.hasScheme && uri.host.isNotEmpty) {
          targets.add(uri.toString());
        }
      }
      if (targets.isEmpty) {
        _showMessage('还没有打开任何登录页面');
        return;
      }

      final cookieManager = PlatformCookieManager(
        const PlatformCookieManagerCreationParams(),
      );
      final collected = <String, io.Cookie>{};
      for (final target in targets) {
        try {
          final cookies = await cookieManager.getCookies(url: WebUri(target));
          final targetUri = Uri.parse(target);
          for (final cookie in cookies) {
            final parsed = _toIoCookie(cookie, targetUri);
            if (parsed == null) continue;
            collected['${parsed.domain}|${parsed.path}|${parsed.name}'] =
                parsed;
          }
        } catch (error) {
          KazumiLogger()
              .d('[PluginLogin] getCookies failed for $target: $error');
        }
      }
      if (collected.isEmpty) {
        _showMessage('没有获取到 Cookie，请确认已经在网页中登录');
        return;
      }

      var userAgent = '';
      try {
        final result = await controller.evaluateJavascript(
          source: 'navigator.userAgent;',
        );
        userAgent = result?.toString() ?? '';
      } catch (_) {}

      final loginUrl = currentUrl.trim().isNotEmpty ? currentUrl : _initialUrl;
      await PluginCookieManager.instance.saveLogin(
        widget.plugin.name,
        cookies: collected.values.toList(growable: false),
        userAgent: userAgent,
        loginUrl: loginUrl,
      );
      if (!mounted) return;
      _showMessage('登录凭证已保存（${collected.length} 个 Cookie）');
      Navigator.of(context).pop(true);
    } catch (error, stackTrace) {
      KazumiLogger().w(
        '[PluginLogin] failed to save credentials',
        error: error,
        stackTrace: stackTrace,
      );
      _showMessage('保存失败：$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _savePastedCookies() async {
    if (_saving) return;
    final url = _fallbackUrlController.text.trim();
    final raw = _fallbackCookieController.text.trim();
    if (url.isEmpty) {
      _showMessage('请先填写网站地址');
      return;
    }
    if (raw.isEmpty) {
      _showMessage('请先粘贴 Cookie');
      return;
    }
    setState(() => _saving = true);
    try {
      final count = await PluginCookieManager.instance.saveLoginCookieString(
        widget.plugin.name,
        url,
        raw,
      );
      if (!mounted) return;
      if (count == 0) {
        _showMessage('Cookie 格式无法识别，请检查后再试');
        return;
      }
      _showMessage('登录凭证已保存（$count 个 Cookie）');
      Navigator.of(context).pop(true);
    } catch (error) {
      KazumiLogger().w('[PluginLogin] failed to save pasted cookies',
          error: error);
      _showMessage('保存失败：$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _formatSavedAt(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}';
  }

  Widget _buildCredentialStatus(ThemeData theme) {
    final manager = PluginCookieManager.instance;
    final count = manager.cookieCountFor(widget.plugin.name);
    final savedAt = manager.savedAtFor(widget.plugin.name);
    final text = count > 0
        ? '已保存 $count 个 Cookie'
            '${savedAt == null ? '' : ' · ${_formatSavedAt(savedAt)}'}'
        : '尚未保存凭证';
    return Text(
      text,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SettingsDetailScaffold(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('网站登录'),
          Text(
            widget.plugin.name,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      actions: [
        if (_supportsEmbeddedWebView)
          TextButton(
            onPressed: _saving ? null : _saveLogin,
            child: Text(_saving ? '保存中…' : '完成登录'),
          ),
      ],
      body: _supportsEmbeddedWebView
          ? _buildEmbeddedBody(theme)
          : _buildFallbackBody(theme),
    );
  }

  Widget _buildEmbeddedBody(ThemeData theme) {
    if (_preparing) {
      return const Center(
        child: LoadingIndicator(size: 44, semanticsLabel: '正在准备登录页'),
      );
    }
    if (_initialUrl.isEmpty) {
      return _buildInvalidUrlBody(theme);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildUrlBar(theme),
        if (_progress > 0 && _progress < 100)
          LinearProgressIndicator(value: _progress / 100),
        if (_loadError != null)
          Material(
            color: theme.colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                '页面加载失败：$_loadError',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                ),
              ),
            ),
          ),
        Expanded(
          child: _webView == null
              ? const SizedBox.shrink()
              : _PlatformWebViewHost(platform: _webView!),
        ),
        _buildFooter(theme),
      ],
    );
  }

  Widget _buildUrlBar(ThemeData theme) {
    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
        child: Row(
          children: [
            IconButton(
              tooltip: '后退',
              onPressed: _canGoBack
                  ? () => _controller?.goBack()
                  : null,
              icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
            ),
            IconButton(
              tooltip: '刷新',
              onPressed: () => _controller?.reload(),
              icon: const Icon(Icons.refresh_rounded, size: 20),
            ),
            Expanded(
              child: Text(
                _currentUrl.isEmpty ? _initialUrl : _currentUrl,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            IconButton(
              tooltip: '更改登录页地址',
              onPressed: _editLoginUrl,
              icon: const Icon(Icons.edit_outlined, size: 18),
            ),
            IconButton(
              tooltip: _desktopMode ? '切换到移动版网页' : '切换到桌面版网页',
              onPressed: _preparing ? null : _toggleDesktopMode,
              icon: Icon(
                _desktopMode
                    ? Icons.desktop_windows_rounded
                    : Icons.smartphone_rounded,
                size: 18,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFooter(ThemeData theme) {
    return SafeArea(
      top: false,
      child: Material(
        color: theme.colorScheme.surfaceContainerLow,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '在网页中完成登录（账号密码、扫码或验证码均可），'
                '看到已登录状态后点击「完成登录」。'
                '若网站只提供电脑版界面，可用地址栏右侧的图标切换桌面/移动版。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              _buildCredentialStatus(theme),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: _saving ? null : _saveLogin,
                child: Text(_saving ? '正在保存…' : '完成登录'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInvalidUrlBody(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.link_off_rounded,
                size: 40, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              '这条规则没有填写站点地址，无法打开登录页。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () async {
                await _editLoginUrl();
              },
              child: const Text('手动输入登录页地址'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFallbackBody(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      children: [
        Text(
          '当前平台暂不支持 App 内嵌网页登录。',
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        Text(
          '请先在电脑浏览器中登录该网站，然后从开发者工具 → Network → '
          '任意请求的请求头中复制 Cookie，粘贴到下方保存。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _fallbackUrlController,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: '网站地址',
            hintText: 'https://example.com',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _fallbackCookieController,
          minLines: 4,
          maxLines: 8,
          decoration: const InputDecoration(
            labelText: 'Cookie',
            hintText: 'name=value; name2=value2',
            alignLabelWithHint: true,
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        _buildCredentialStatus(theme),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _saving ? null : _savePastedCookies,
          child: Text(_saving ? '正在保存…' : '保存 Cookie'),
        ),
      ],
    );
  }
}

/// 把平台无关的 WebView widget delegate 渲染进 Flutter 组件树。
class _PlatformWebViewHost extends StatefulWidget {
  const _PlatformWebViewHost({required this.platform});

  final PlatformInAppWebViewWidget platform;

  @override
  State<_PlatformWebViewHost> createState() => _PlatformWebViewHostState();
}

class _PlatformWebViewHostState extends State<_PlatformWebViewHost> {
  @override
  void dispose() {
    widget.platform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.platform.build(context);
}
