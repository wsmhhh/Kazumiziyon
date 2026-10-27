import 'package:cookie_jar/cookie_jar.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/plugin/plugin_credential_store.dart';

/// 每条规则的 Cookie 管理器
///
/// 为每条规则维护一个内存 [CookieJar]，并把整份凭证（Cookie、User-Agent、
/// 登录页地址）同步到 [PluginCredentialStore] 持久化，重启 App 后由
/// [init] 重新载入。规则请求执行器按需读取并组装 Cookie 请求头；
/// 登录页面在打开前也会读回已保存的 Cookie 注入 WebView。
///
/// 验证 Cookie 通常与 User-Agent 绑定，故同时记录 WebView 的 UA，
/// 供后续 dio 请求对齐指纹。
class PluginCookieManager {
  PluginCookieManager._();
  static final PluginCookieManager instance = PluginCookieManager._();

  final Map<String, CookieJar> _jars = {};
  final Map<String, Map<String, Cookie>> _cookies = {};
  final Map<String, String> _userAgents = {};
  final Map<String, String> _loginUrls = {};
  final Map<String, DateTime> _savedAt = {};
  final Map<String, bool> _fromLogin = {};

  bool _loaded = false;
  Future<void>? _loading;

  /// 规则名大小写不敏感，与 `pluginNameKey` 保持一致。
  String _key(String pluginName) => pluginName.toLowerCase();

  CookieJar _getJar(String pluginName) {
    return _jars.putIfAbsent(pluginName, () => CookieJar());
  }

  /// 载入持久化凭证。应用启动时调用；其余入口也会按需等待同一次载入。
  Future<void> init() => _ensureLoaded();

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loading ??= _loadFromStore();
    await _loading;
  }

  Future<void> _loadFromStore() async {
    try {
      final credentials = await PluginCredentialStore.instance.loadAll();
      for (final credential in credentials.values) {
        await _applyCredential(credential);
      }
      KazumiLogger().i(
        '[PluginCookieManager] Loaded ${credentials.length} credential sets',
      );
    } catch (error) {
      KazumiLogger().w(
        '[PluginCookieManager] Failed to load stored credentials',
        error: error,
      );
    }
    _loaded = true;
  }

  Future<void> _applyCredential(PluginCredential credential) async {
    final key = _key(credential.pluginName);
    if (credential.userAgent.trim().isNotEmpty) {
      _userAgents[key] = credential.userAgent.trim();
    }
    _loginUrls[key] = credential.loginUrl;
    _savedAt[key] = credential.savedAt;
    _fromLogin[key] = credential.fromLogin;

    final jar = _getJar(key);
    final map = _cookies.putIfAbsent(key, () => <String, Cookie>{});
    for (final cookie in credential.cookies) {
      if (!_isAlive(cookie)) continue;
      map[_cookieKey(cookie)] = cookie;
      await jar.saveFromResponse(
        _uriForCookie(cookie, credential.loginUrl),
        <Cookie>[cookie],
      );
    }
  }

  /// 保存验证码 WebView 捕获的 document.cookie 字符串。
  Future<void> saveFromWebView(
    String pluginName,
    String pageUrl,
    String cookieString, {
    String? userAgent,
  }) async {
    await _ensureLoaded();
    final uri = Uri.tryParse(pageUrl);
    if (uri == null) return;

    final key = _key(pluginName);
    if (userAgent != null && userAgent.trim().isNotEmpty) {
      _userAgents[key] = userAgent.trim();
    }

    final cookies = _parseCookieString(cookieString, uri);
    if (cookies.isEmpty) return;

    final jar = _getJar(key);
    final map = _cookies.putIfAbsent(key, () => <String, Cookie>{});
    for (final cookie in cookies) {
      map[_cookieKey(cookie)] = cookie;
      await jar.saveFromResponse(uri, <Cookie>[cookie]);
    }
    // 验证流程不覆盖登录信息，仅在尚未记录时补上页面地址。
    _loginUrls.putIfAbsent(key, () => pageUrl);
    _savedAt[key] = DateTime.now();
    _fromLogin.putIfAbsent(key, () => false);

    await _persist(key);
    KazumiLogger().i(
      '[PluginCookieManager] Saved ${cookies.length} cookies for $pluginName',
    );
  }

  /// 保存「网站登录」抓取到的整份站点 Cookie。
  ///
  /// 重新登录时整体替换旧 Cookie，避免上一次会话的残留与本次登录冲突。
  Future<void> saveLogin(
    String pluginName, {
    required List<Cookie> cookies,
    required String userAgent,
    required String loginUrl,
  }) async {
    await _ensureLoaded();
    final key = _key(pluginName);

    if (userAgent.trim().isNotEmpty) {
      _userAgents[key] = userAgent.trim();
    }

    final jar = _getJar(key);
    await jar.deleteAll();

    final map = <String, Cookie>{};
    for (final cookie in cookies) {
      if (!_isAlive(cookie)) continue;
      map[_cookieKey(cookie)] = cookie;
      await jar.saveFromResponse(
        _uriForCookie(cookie, loginUrl),
        <Cookie>[cookie],
      );
    }
    _cookies[key] = map;
    _loginUrls[key] = loginUrl;
    _savedAt[key] = DateTime.now();
    _fromLogin[key] = true;

    await _persist(key);
    KazumiLogger().i(
      '[PluginCookieManager] Saved ${map.length} login cookies for $pluginName',
    );
  }

  /// 从手动粘贴的 Cookie 字符串保存登录凭证（桌面端兜底）。
  ///
  /// 返回解析并保存的 Cookie 数量，未解析出 Cookie 时返回 0。
  Future<int> saveLoginCookieString(
    String pluginName,
    String url,
    String raw, {
    String? userAgent,
  }) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return 0;
    final cookies = _parseCookieString(raw, uri);
    if (cookies.isEmpty) return 0;
    await saveLogin(
      pluginName,
      cookies: cookies,
      userAgent: userAgent ?? '',
      loginUrl: uri.toString(),
    );
    return cookies.length;
  }

  /// 解析字符串为 [Cookie] 列表
  List<Cookie> _parseCookieString(String raw, Uri uri) {
    final cookies = <Cookie>[];
    for (final part in raw.split(';')) {
      final trimmed = part.trim();
      if (trimmed.isEmpty) continue;
      final eqIndex = trimmed.indexOf('=');
      if (eqIndex <= 0) continue;
      final name = trimmed.substring(0, eqIndex).trim();
      final value = trimmed.substring(eqIndex + 1).trim();
      try {
        final cookie = Cookie(name, value)
          ..domain = uri.host
          ..path = '/';
        cookies.add(cookie);
      } catch (_) {}
    }
    return cookies;
  }

  Future<List<Cookie>> loadForRequest(
    String pluginName,
    Uri uri,
  ) async {
    await _ensureLoaded();
    final jar = _jars[_key(pluginName)];
    if (jar == null) return <Cookie>[];
    return jar.loadForRequest(uri);
  }

  /// 已保存且未过期的 Cookie，供登录页回填 WebView。
  List<Cookie> cookiesFor(String pluginName) {
    final cookies = _cookies[_key(pluginName)];
    if (cookies == null) return const <Cookie>[];
    return cookies.values.where(_isAlive).toList(growable: false);
  }

  /// 同步组装适用于 [url] 的 Cookie 请求头。
  ///
  /// 供媒体播放等无法等待异步 CookieJar 的场景使用；按域名、路径与
  /// Secure 属性过滤，不匹配的域名不会带上站点凭证。
  String cookieHeaderFor(String pluginName, String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return '';
    final cookies = _cookies[_key(pluginName)];
    if (cookies == null) return '';
    final host = uri.host.toLowerCase();
    final now = DateTime.now();
    final pairs = <String>[];
    for (final cookie in cookies.values) {
      final expires = cookie.expires;
      if (expires != null && !expires.isAfter(now)) continue;
      final domain = _normalizeDomain(cookie.domain);
      if (domain.isNotEmpty &&
          host != domain &&
          !host.endsWith('.$domain')) {
        continue;
      }
      final path = cookie.path ?? '/';
      if (path.isNotEmpty && path != '/' && !uri.path.startsWith(path)) {
        continue;
      }
      if (cookie.secure && uri.scheme != 'https') continue;
      pairs.add('${cookie.name}=${cookie.value}');
    }
    return pairs.join('; ');
  }

  /// 是否存有可用凭证（登录或验证码验证均可）。
  bool hasCredentials(String pluginName) => cookiesFor(pluginName).isNotEmpty;

  /// 是否通过「网站登录」保存过凭证。
  bool isLoggedIn(String pluginName) =>
      (_fromLogin[_key(pluginName)] ?? false) && hasCredentials(pluginName);

  int cookieCountFor(String pluginName) => cookiesFor(pluginName).length;

  DateTime? savedAtFor(String pluginName) => _savedAt[_key(pluginName)];

  String loginUrlFor(String pluginName) => _loginUrls[_key(pluginName)] ?? '';

  /// 验证时 WebView 使用的 User-Agent；未验证过的规则返回 null
  String? userAgentFor(String pluginName) => _userAgents[_key(pluginName)];

  /// 清除某条规则的凭证（退出登录）。
  Future<void> clear(String pluginName) async {
    await _ensureLoaded();
    final key = _key(pluginName);
    _cookies.remove(key);
    _userAgents.remove(key);
    _loginUrls.remove(key);
    _savedAt.remove(key);
    _fromLogin.remove(key);
    final jar = _jars.remove(key);
    await jar?.deleteAll();
    await PluginCredentialStore.instance.delete(key);
    KazumiLogger()
        .i('[PluginCookieManager] Cleared credentials for $pluginName');
  }

  Future<void> _persist(String key) async {
    final cookies = _cookies[key]?.values.where(_isAlive).toList() ?? const [];
    if (cookies.isEmpty) {
      await PluginCredentialStore.instance.delete(key);
      return;
    }
    await PluginCredentialStore.instance.save(PluginCredential(
      pluginName: key,
      cookies: cookies,
      userAgent: _userAgents[key] ?? '',
      loginUrl: _loginUrls[key] ?? '',
      savedAt: _savedAt[key] ?? DateTime.now(),
      fromLogin: _fromLogin[key] ?? false,
    ));
  }

  bool _isAlive(Cookie cookie) {
    final expires = cookie.expires;
    return expires == null || expires.isAfter(DateTime.now());
  }

  String _cookieKey(Cookie cookie) {
    return '${_normalizeDomain(cookie.domain)}|${cookie.path ?? '/'}|'
        '${cookie.name}';
  }

  String _normalizeDomain(String? domain) {
    if (domain == null || domain.isEmpty) return '';
    return domain.startsWith('.')
        ? domain.substring(1).toLowerCase()
        : domain.toLowerCase();
  }

  Uri _uriForCookie(Cookie cookie, String fallbackUrl) {
    final domain = _normalizeDomain(cookie.domain);
    if (domain.isNotEmpty) {
      return Uri(scheme: 'https', host: domain, path: cookie.path ?? '/');
    }
    final parsed = Uri.tryParse(fallbackUrl);
    if (parsed != null && parsed.hasScheme && parsed.host.isNotEmpty) {
      return parsed;
    }
    return Uri(scheme: 'https', host: 'localhost');
  }
}
