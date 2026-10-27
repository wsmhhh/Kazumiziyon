import 'dart:convert';
import 'dart:io';

import 'package:hive_ce/hive.dart';
import 'package:kazumi/services/logging/logger.dart';

/// 单条规则的登录凭证快照。
///
/// Cookie 通常与登录时 WebView 实际使用的 User-Agent 绑定，故一并保存；
/// [loginUrl] 记录用户完成登录的页面，下次登录时优先打开该地址，
/// [savedAt] 用于在 UI 上展示最近一次登录时间。
class PluginCredential {
  const PluginCredential({
    required this.pluginName,
    required this.cookies,
    required this.userAgent,
    required this.loginUrl,
    required this.savedAt,
    this.fromLogin = false,
  });

  final String pluginName;
  final List<Cookie> cookies;
  final String userAgent;
  final String loginUrl;
  final DateTime savedAt;

  /// true 表示凭证来自「网站登录」，false 表示来自验证码自动验证。
  final bool fromLogin;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'cookies': cookies.map(_cookieToJson).toList(),
      'userAgent': userAgent,
      'loginUrl': loginUrl,
      'savedAt': savedAt.millisecondsSinceEpoch,
      'fromLogin': fromLogin,
    };
  }

  static PluginCredential? fromJson(
    String pluginName,
    Map<String, dynamic> json,
  ) {
    final rawCookies = json['cookies'];
    if (rawCookies is! List) return null;
    final cookies = <Cookie>[];
    for (final raw in rawCookies) {
      if (raw is! Map) continue;
      final cookie = _cookieFromJson(Map<String, dynamic>.from(raw));
      if (cookie != null) cookies.add(cookie);
    }
    final savedAt = json['savedAt'];
    return PluginCredential(
      pluginName: pluginName,
      cookies: cookies,
      userAgent: json['userAgent']?.toString() ?? '',
      loginUrl: json['loginUrl']?.toString() ?? '',
      savedAt: savedAt is int
          ? DateTime.fromMillisecondsSinceEpoch(savedAt)
          : DateTime.fromMillisecondsSinceEpoch(0),
      fromLogin: json['fromLogin'] == true,
    );
  }

  static Map<String, dynamic> _cookieToJson(Cookie cookie) {
    return <String, dynamic>{
      'name': cookie.name,
      'value': cookie.value,
      'domain': cookie.domain,
      'path': cookie.path,
      'expires': cookie.expires?.millisecondsSinceEpoch,
      'secure': cookie.secure,
      'httpOnly': cookie.httpOnly,
    };
  }

  static Cookie? _cookieFromJson(Map<String, dynamic> json) {
    final name = json['name']?.toString() ?? '';
    if (name.isEmpty) return null;
    final value = json['value']?.toString() ?? '';
    try {
      final cookie = Cookie(name, value);
      final domain = json['domain']?.toString();
      if (domain != null && domain.isNotEmpty) cookie.domain = domain;
      final path = json['path']?.toString();
      if (path != null && path.isNotEmpty) cookie.path = path;
      final expires = json['expires'];
      if (expires is int && expires > 0) {
        cookie.expires = DateTime.fromMillisecondsSinceEpoch(expires);
      }
      cookie.secure = json['secure'] == true;
      cookie.httpOnly = json['httpOnly'] == true;
      return cookie;
    } catch (_) {
      // 名称或值不符合 Cookie 规范时跳过该条，不影响其余凭证。
      return null;
    }
  }
}

/// 登录凭证的本地持久化存储。
///
/// 每条规则在 Hive 中以 JSON 字符串保存一份凭证，重启后仍可继续使用。
/// Hive 尚未初始化或 Box 打开失败时降级为仅内存模式：读写均不抛异常，
/// 以保证登录流程本身不会被存储问题打断。
class PluginCredentialStore {
  PluginCredentialStore._();
  static final PluginCredentialStore instance = PluginCredentialStore._();

  static const String boxName = 'pluginCredentials';

  Box<String>? _box;
  bool _openFailed = false;
  Future<void>? _opening;

  Future<Box<String>?> _ensureOpen() async {
    if (_box != null || _openFailed) return _box;
    _opening ??= _open();
    await _opening;
    return _box;
  }

  Future<void> _open() async {
    try {
      _box = await Hive.openBox<String>(boxName);
    } catch (error) {
      _openFailed = true;
      KazumiLogger().w(
        '[PluginCredentialStore] Failed to open "$boxName", '
        'credentials will not survive restart',
        error: error,
      );
    }
  }

  Future<Map<String, PluginCredential>> loadAll() async {
    final box = await _ensureOpen();
    if (box == null) return <String, PluginCredential>{};
    final credentials = <String, PluginCredential>{};
    for (final key in box.keys) {
      final raw = box.get(key);
      if (raw == null) continue;
      try {
        final decoded = json.decode(raw);
        if (decoded is! Map) continue;
        final credential = PluginCredential.fromJson(
          key.toString(),
          Map<String, dynamic>.from(decoded),
        );
        if (credential != null) credentials[key.toString()] = credential;
      } catch (error) {
        KazumiLogger().w(
          '[PluginCredentialStore] Failed to parse credentials for $key',
          error: error,
        );
      }
    }
    return credentials;
  }

  Future<void> save(PluginCredential credential) async {
    final box = await _ensureOpen();
    if (box == null) return;
    try {
      await box.put(credential.pluginName, json.encode(credential.toJson()));
      await box.flush();
    } catch (error) {
      KazumiLogger().w(
        '[PluginCredentialStore] Failed to save credentials for '
        '${credential.pluginName}',
        error: error,
      );
    }
  }

  Future<void> delete(String pluginName) async {
    final box = await _ensureOpen();
    if (box == null) return;
    try {
      await box.delete(pluginName);
      await box.flush();
    } catch (error) {
      KazumiLogger().w(
        '[PluginCredentialStore] Failed to delete credentials for $pluginName',
        error: error,
      );
    }
  }
}
