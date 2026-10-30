import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:kazumi/modules/bt/bt_task.dart';
import 'package:kazumi/services/logging/logger.dart';

class Aria2Exception implements Exception {
  const Aria2Exception(this.message, {this.code});

  final String message;
  final int? code;

  @override
  String toString() => message;
}

/// Thin JSON-RPC 2.0 client for a local aria2c process.
///
/// aria2 speaks JSON-RPC over HTTP; every call is a POST to `/jsonrpc` and,
/// when a secret is configured, `token:<secret>` is the first positional
/// parameter.
class Aria2Client {
  Aria2Client({
    required this.port,
    required this.secret,
    this.host = '127.0.0.1',
    Dio? dio,
  }) : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 2),
              receiveTimeout: const Duration(seconds: 30),
              sendTimeout: const Duration(seconds: 10),
              headers: const {'Content-Type': 'application/json'},
              // aria2 answers with `application/json-rpc`, which Dio's default
              // transformer does not treat as JSON. Read the body as text and
              // decode it ourselves so the content type cannot break RPC.
              responseType: ResponseType.plain,
            ));

  final int port;
  final String secret;

  /// Loopback address used for RPC. A few Android builds only expose the IPv6
  /// loopback, so the engine probes 127.0.0.1, ::1 and localhost in turn.
  final String host;
  final Dio _dio;
  int _requestId = 0;

  Uri get endpoint =>
      Uri(scheme: 'http', host: host, port: port, path: '/jsonrpc');

  Future<dynamic> call(
    String method, [
    List<dynamic> params = const [],
  ]) async {
    final payload = <String, dynamic>{
      'jsonrpc': '2.0',
      'id': 'kazumi-${++_requestId}',
      'method': method,
      'params': [
        if (secret.isNotEmpty) 'token:$secret',
        ...params,
      ],
    };

    try {
      final response = await _dio.post<dynamic>(endpoint.toString(), data: payload);
      final data = _decodeBody(response.data);
      if (data == null) {
        final preview = _preview(response.data);
        throw Aria2Exception(
          'aria2 返回了无法解析的响应${preview.isEmpty ? '' : '：$preview'}',
        );
      }
      final error = data['error'];
      if (error is Map) {
        throw Aria2Exception(
          error['message']?.toString() ?? 'aria2 调用失败',
          code: _asInt(error['code']),
        );
      }
      return data['result'];
    } on DioException catch (e) {
      throw Aria2Exception(_describeDioError(e));
    }
  }

  Future<String> getVersion() async {
    final result = await call('aria2.getVersion');
    return result is Map ? (result['version']?.toString() ?? '') : '';
  }

  Future<String> addUri(
    List<String> uris, {
    Map<String, String>? options,
    int? position,
  }) async {
    final result = await call('aria2.addUri', [
      uris,
      if (options != null) options,
      if (position != null) position,
    ]);
    return result?.toString() ?? '';
  }

  Future<String> addTorrent(
    String base64Torrent, {
    List<String> uris = const [],
    Map<String, String>? options,
    int? position,
  }) async {
    final result = await call('aria2.addTorrent', [
      base64Torrent,
      uris,
      if (options != null) options,
      if (position != null) position,
    ]);
    return result?.toString() ?? '';
  }

  Future<BtTask?> tellStatus(String gid, {List<String>? keys}) async {
    try {
      final result = await call('aria2.tellStatus', [
        gid,
        if (keys != null) keys,
      ]);
      if (result is Map) {
        return BtTask.fromJson(Map<String, dynamic>.from(result));
      }
      return null;
    } on Aria2Exception catch (e) {
      // Asking about a gid that was just removed is expected during polling.
      if (e.message.contains('is not found')) return null;
      rethrow;
    }
  }

  Future<List<BtTask>> tellActive({List<String>? keys}) =>
      _tellList('aria2.tellActive', [if (keys != null) keys]);

  Future<List<BtTask>> tellWaiting(
    int offset,
    int num, {
    List<String>? keys,
  }) =>
      _tellList('aria2.tellWaiting', [offset, num, if (keys != null) keys]);

  Future<List<BtTask>> tellStopped(
    int offset,
    int num, {
    List<String>? keys,
  }) =>
      _tellList('aria2.tellStopped', [offset, num, if (keys != null) keys]);

  Future<List<BtTask>> _tellList(
    String method,
    List<dynamic> params,
  ) async {
    final result = await call(method, params);
    if (result is! List) return const [];
    return result
        .whereType<Map>()
        .map((raw) => BtTask.fromJson(Map<String, dynamic>.from(raw)))
        .toList();
  }

  Future<List<BtFile>> getFiles(String gid) async {
    final result = await call('aria2.getFiles', [gid]);
    if (result is! List) return const [];
    return result
        .whereType<Map>()
        .map((raw) => BtFile.fromJson(Map<String, dynamic>.from(raw)))
        .toList();
  }

  Future<Map<String, dynamic>> getGlobalStat() async {
    final result = await call('aria2.getGlobalStat');
    return result is Map ? Map<String, dynamic>.from(result) : const {};
  }

  Future<void> pause(String gid) => call('aria2.pause', [gid]);

  Future<void> forcePause(String gid) => call('aria2.forcePause', [gid]);

  Future<void> unpause(String gid) => call('aria2.unpause', [gid]);

  Future<void> remove(String gid) => call('aria2.remove', [gid]);

  Future<void> removeDownloadResult(String gid) =>
      call('aria2.removeDownloadResult', [gid]);

  Future<void> changeOption(String gid, Map<String, String> options) =>
      call('aria2.changeOption', [gid, options]);

  Future<void> changeGlobalOption(Map<String, String> options) =>
      call('aria2.changeGlobalOption', [options]);

  Future<void> saveSession() => call('aria2.saveSession');

  Future<void> shutdown() => call('aria2.shutdown');

  Future<void> forceShutdown() => call('aria2.forceShutdown');

  /// Decodes an RPC body without trusting the `Content-Type` header.
  static Map<String, dynamic>? _decodeBody(Object? body) {
    if (body is Map) return Map<String, dynamic>.from(body);
    if (body is List<int>) {
      try {
        return _decodeBody(utf8.decode(body));
      } catch (_) {
        return null;
      }
    }
    if (body is String) {
      final text = body.trim();
      if (text.isEmpty) return null;
      try {
        final decoded = jsonDecode(text);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  static String _preview(Object? body) {
    if (body == null) return '';
    final text = body is String ? body : body.toString();
    final single = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (single.isEmpty) return '';
    return single.length > 160 ? '${single.substring(0, 160)}…' : single;
  }

  static String _describeDioError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return '连接 aria2 超时';
      case DioExceptionType.connectionError:
        return 'aria2 未启动或端口不可用';
      default:
        if (e.response != null) {
          return 'aria2 请求失败（HTTP ${e.response?.statusCode}）';
        }
        KazumiLogger().e('Aria2: RPC request failed', error: e);
        return 'aria2 请求失败';
    }
  }

  static int _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}
