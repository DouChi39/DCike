import 'dart:async';
import 'dart:io';

import 'package:minio/minio.dart';

/// Messages from S3 servers can contain endpoints, bucket names or credentials.
/// Only these local messages may reach the UI and application logs.
class S3ConnectionException implements Exception {
  const S3ConnectionException(this.message);

  final String message;

  @override
  String toString() => message;
}

class S3Endpoint {
  const S3Endpoint({required this.host, required this.port});

  final String host;
  final int? port;
}

S3Endpoint resolveS3Endpoint(
  String endpoint, {
  required bool useSSL,
  int configuredPort = 0,
}) {
  final trimmed = endpoint.trim();
  if (trimmed.isEmpty) {
    throw const S3ConnectionException('S3 服务地址不能为空');
  }
  if (configuredPort < 0 || configuredPort > 65535) {
    throw const S3ConnectionException('S3 端口必须在 1 到 65535 之间，或留空');
  }

  try {
    final hasScheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(trimmed);
    final uri = Uri.parse(
      hasScheme ? trimmed : '${useSSL ? 'https' : 'http'}://$trimmed',
    );
    if ((uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const S3ConnectionException(
        'S3 服务地址格式错误，请只填写域名或 IP，可带 http/https 和端口，不含路径或账号',
      );
    }
    if ((uri.scheme == 'https') != useSSL) {
      throw const S3ConnectionException('S3 地址中的 http/https 与 SSL 开关不一致');
    }
    final port = configuredPort > 0
        ? configuredPort
        : (uri.hasPort ? uri.port : null);
    if (port != null && (port < 1 || port > 65535)) {
      throw const S3ConnectionException('S3 端口必须在 1 到 65535 之间，或留空');
    }
    return S3Endpoint(host: uri.host, port: port);
  } on FormatException {
    throw const S3ConnectionException('S3 服务地址格式错误');
  }
}

Minio createS3Client({
  required String endpoint,
  required String accessKey,
  required String secretKey,
  required String bucket,
  required bool useSSL,
  required int port,
  required String region,
  required bool pathStyle,
}) {
  if (endpoint.trim().isEmpty ||
      accessKey.trim().isEmpty ||
      secretKey.isEmpty ||
      bucket.trim().isEmpty) {
    throw const S3ConnectionException('S3 配置不完整');
  }
  final resolved = resolveS3Endpoint(
    endpoint,
    useSSL: useSSL,
    configuredPort: port,
  );
  try {
    MinioInvalidBucketNameError.check(bucket);
    return Minio(
      endPoint: resolved.host,
      port: resolved.port,
      accessKey: accessKey,
      secretKey: secretKey,
      useSSL: useSSL,
      region: region.trim().isEmpty ? null : region.trim(),
      pathStyle: pathStyle,
    );
  } catch (error) {
    throw safeS3Exception(error);
  }
}

Future<T> runS3Operation<T>(Future<T> Function() operation) async {
  try {
    return await operation();
  } catch (error) {
    throw safeS3Exception(error);
  }
}

S3ConnectionException safeS3Exception(Object error) {
  if (error is S3ConnectionException) return error;
  if (error is HandshakeException || error is TlsException) {
    return const S3ConnectionException('S3 HTTPS 证书验证失败，请检查服务器证书');
  }
  if (error is TimeoutException) {
    return const S3ConnectionException('S3 连接超时，请检查网络和服务地址');
  }
  if (error is SocketException) {
    return const S3ConnectionException('无法连接 S3，请检查服务地址、端口和网络');
  }
  if (error is MinioInvalidBucketNameError) {
    return const S3ConnectionException('S3 Bucket 名称格式错误');
  }
  if (error is MinioInvalidEndpointError || error is MinioInvalidPortError) {
    return const S3ConnectionException('S3 服务地址或端口格式错误');
  }
  if (error is MinioS3Error) {
    switch (error.error?.code) {
      case 'InvalidAccessKeyId':
      case 'SignatureDoesNotMatch':
      case 'InvalidToken':
      case 'ExpiredToken':
        return const S3ConnectionException(
          'S3 身份验证失败，请检查 Access Key 和 Secret Key',
        );
      case 'AccessDenied':
        return const S3ConnectionException('S3 权限不足，请检查 Bucket 的访问权限');
      case 'NoSuchBucket':
        return const S3ConnectionException('S3 Bucket 不存在或没有访问权限');
      case 'NoSuchKey':
      case 'NoSuchObject':
      case 'NotFound':
        return const S3ConnectionException('S3 远端文件不存在');
      case 'AuthorizationHeaderMalformed':
      case 'PermanentRedirect':
      case 'IncorrectEndpoint':
        return const S3ConnectionException('S3 地址或 Region 不匹配，请核对服务商提供的配置');
      case 'RequestTimeTooSkewed':
        return const S3ConnectionException('设备时间与 S3 服务器相差过大，请校准设备时间');
    }
    if (error.response?.statusCode == 403) {
      return const S3ConnectionException('S3 身份验证失败或权限不足，请检查密钥和 Bucket 权限');
    }
    if (error.response?.statusCode == 404) {
      return const S3ConnectionException('S3 资源不存在，请检查 Bucket 和服务地址');
    }
  }
  return const S3ConnectionException('S3 操作失败，请检查服务地址、Region、密钥和访问权限');
}
