import 'dart:async';
import 'dart:io';

/// 服务端错误可能带有私有地址、账号或响应正文，只对外返回本地固定提示。
class WebDavConnectionException implements Exception {
  const WebDavConnectionException(this.message);

  final String message;

  @override
  String toString() => message;
}

Future<T> runWebDavOperation<T>(Future<T> Function() operation) async {
  try {
    return await operation();
  } catch (error) {
    throw safeWebDavException(error);
  }
}

WebDavConnectionException safeWebDavException(Object error) {
  if (error is WebDavConnectionException) return error;
  if (error is TimeoutException) {
    return const WebDavConnectionException('WebDAV 连接超时，请检查网络和服务地址');
  }
  if (error is SocketException) {
    return const WebDavConnectionException(
      '无法连接 WebDAV，请检查服务地址、端口和 iOS 本地网络权限',
    );
  }
  // Rust 异常经 FFI 到达 Dart 后不再保留原生网络异常类型。
  final message = error.toString().toLowerCase();
  if (error is HandshakeException ||
      error is TlsException ||
      message.contains('certificate') ||
      message.contains('tls') ||
      message.contains('handshake')) {
    return const WebDavConnectionException('WebDAV HTTPS 连接失败，请检查服务器 TLS 配置');
  }
  if (message.contains('timeout') || message.contains('timed out')) {
    return const WebDavConnectionException('WebDAV 连接超时，请检查网络和服务地址');
  }
  for (final code in [401, 403, 404, 405, 409, 423, 429, 500, 502, 503, 504]) {
    if (!RegExp('\\b$code\\b').hasMatch(message)) continue;
    final hint = switch (code) {
      401 => 'WebDAV 身份验证失败，请检查账号和密码',
      403 => 'WebDAV 访问被拒绝，请检查目录权限',
      404 => 'WebDAV 目录或文件不存在，请检查服务地址',
      405 => '服务器不支持所需操作，请确认填写的是 WebDAV 地址',
      _ => 'WebDAV 服务器暂时无法完成请求，请稍后重试',
    };
    return WebDavConnectionException('$hint（HTTP $code）');
  }
  return const WebDavConnectionException(
    'WebDAV 连接或同步失败，请检查地址、账号、网络和 iOS 本地网络权限',
  );
}
