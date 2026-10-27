import 'dart:convert';

import 'package:zephyr/config/global/global.dart';
import 'package:zephyr/network/sync/s3_connection.dart';
import 'package:zephyr/network/sync/webdav_errors.dart';

import 'package:zephyr/main.dart';

Future<void> testWebDavServer(
  String host,
  String username,
  String password,
) async {
  try {
    final client = WindHttp(
      baseUrl: host,
      headers: {
        'Authorization':
            'Basic ${base64Encode(utf8.encode('$username:$password'))}',
      },
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
      // 与原版和正式同步一致，兼容自建 WebDAV 的自签名证书。
      // 仅覆盖这个客户端，不修改全局 HTTP 设置。
      dangerAcceptInvalidCerts: true,
    );

    final response = await client.fetch('/', method: 'OPTIONS');

    final code = response.status;
    if (code < 200 || code >= 300) {
      throw Exception('WebDAV 服务返回异常状态码: ${response.status}');
    }

    final propfindResponse = await client.fetch(
      '/${appStorageName}_$syncVersion/',
      method: 'PROPFIND',
      headers: {'Depth': '0'},
    );

    final propfindCode = propfindResponse.status;
    if (propfindCode == 207 || propfindCode == 404) {
      return;
    }

    throw Exception('WebDAV PROPFIND 检查失败，状态码: $propfindCode');
  } catch (e) {
    throw safeWebDavException(e);
  }
}

Future<void> testS3Server({
  required String endpoint,
  required String accessKey,
  required String secretKey,
  required String bucket,
  required bool useSSL,
  required int port,
  required String region,
  required bool pathStyle,
}) async {
  final minio = createS3Client(
    endpoint: endpoint,
    bucket: bucket,
    port: port,
    accessKey: accessKey,
    secretKey: secretKey,
    useSSL: useSSL,
    region: region,
    pathStyle: pathStyle,
  );

  await runS3Operation(() async {
    final exists = await minio.bucketExists(bucket);
    if (!exists) {
      throw const S3ConnectionException('S3 Bucket 不存在或没有访问权限');
    }
  });
}
