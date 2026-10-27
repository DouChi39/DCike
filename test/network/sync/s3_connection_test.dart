import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zephyr/config/global/global_setting.dart';
import 'package:zephyr/network/sync/comic_sync_core.dart';
import 'package:zephyr/network/sync/s3_connection.dart';
import 'package:zephyr/network/sync/s3_sync_service.dart';

void main() {
  group('S3 endpoint', () {
    test('host, URL port and explicit port share the same parsing', () {
      final host = resolveS3Endpoint('s3.example.com', useSSL: true);
      expect(host.host, 's3.example.com');
      expect(host.port, isNull);
      final url = resolveS3Endpoint(' HTTP://127.0.0.1:9000/ ', useSSL: false);
      expect(url.host, '127.0.0.1');
      expect(url.port, 9000);
      expect(
        resolveS3Endpoint(
          'https://s3.example.com:9443',
          useSSL: true,
          configuredPort: 8443,
        ).port,
        8443,
      );
    });

    test('protocol conflicts cannot silently downgrade HTTPS', () {
      for (final (address, ssl) in [
        ('http://s3.example.com', true),
        ('https://s3.example.com', false),
      ]) {
        expect(
          () => resolveS3Endpoint(address, useSSL: ssl),
          throwsA(isA<S3ConnectionException>()),
        );
      }
    });

    test('unsupported addresses never echo user input', () {
      for (final address in [
        'https://private-user:private-password@s3.example.com',
        'https://s3.example.com/private-path',
        'https://s3.example.com?token=private-token',
        'https://s3.example.com/#private-fragment',
        'ftp://s3.example.com',
        'https://s3.example.com:70000',
        'https://s3.example.com:0',
      ]) {
        expect(
          () => resolveS3Endpoint(address, useSSL: true),
          throwsA(
            isA<S3ConnectionException>().having(
              (error) => error.toString(),
              'safe error',
              isNot(contains('private-')),
            ),
          ),
        );
      }
    });

    test('unexpected errors cannot reach logs with credentials', () async {
      await expectLater(
        runS3Operation<void>(() async {
          throw const SocketException('private-password at private-endpoint');
        }),
        throwsA(
          isA<S3ConnectionException>().having(
            (error) => error.toString(),
            'safe error',
            isNot(contains('private-')),
          ),
        ),
      );
    });
  });

  group('S3 adapter with a local simulated server', () {
    late _LocalS3 server;
    late S3SyncService adapter;

    setUp(() async {
      server = await _LocalS3.start();
      adapter = S3SyncService(
        GlobalSettingState(
          syncSetting: SyncSettingState(
            s3Setting: S3SettingState(
              endpoint: 'http://127.0.0.1:${server.port}',
              accessKey: 'local-test-access-key',
              secretKey: 'local-test-secret-key',
              bucket: 'test-bucket',
              useSSL: false,
              pathStyle: true,
            ),
          ),
        ),
      );
    });

    tearDown(() => server.close());

    test('connects and round-trips md5 and UTF-8 data, then deletes', () async {
      await adapter.testConnection();
      expect(await adapter.downloadRemoteMd5(), isEmpty);
      await adapter.uploadRemoteMd5('test-md5');
      expect(await adapter.downloadRemoteMd5(), 'test-md5');

      final payload = utf8.encode('仅用于本地测试的漫画记录');
      const path = 'folder with space/测试.bin';
      await adapter.uploadRemoteFile(
        path,
        payload,
        contentType: 'application/x-dcike-test',
      );
      expect(await adapter.downloadRemoteFile(path), payload);
      final managedPath = '${ComicSyncCore.syncRemoteRootName}/$path';
      expect(server.contentTypes[managedPath], 'application/x-dcike-test');
      expect(server.sawSignedRequest, isTrue);
      expect(server.sawRegionRequest, isTrue);
      await adapter.deleteRemoteFiles([path, path]);
      expect(server.objects.containsKey(managedPath), isFalse);
      await adapter.deleteRemoteFiles([path]);
    });

    test('lists current and legacy prefixes across multiple pages', () async {
      final keys = [
        '${ComicSyncCore.syncRemoteRootName}/comic_1.bin',
        '${ComicSyncCore.syncRemoteRootName}/comic_2.bin',
        '${ComicSyncCore.legacyDataRootName}/comic_0.bin',
        '${ComicSyncCore.legacySettingsRootName}/settings_0.bin',
      ];
      for (final key in keys) {
        server.objects[key] = [1, 2, 3];
      }
      expect(await adapter.listRemoteDataFiles(), unorderedEquals(keys));
      expect(server.listRequests, greaterThan(3));
    });

    test(
      'HEAD success does not hide denied write or list permissions',
      () async {
        await adapter.testConnection();
        server.denyWrite = true;
        await expectLater(
          adapter.uploadRemoteFile('comic_1.bin', [1, 2]),
          throwsA(
            isA<S3ConnectionException>()
                .having((error) => error.toString(), 'reason', contains('权限'))
                .having(
                  (error) => error.toString(),
                  'safe error',
                  isNot(contains('private-')),
                ),
          ),
        );
        server.denyList = true;
        await expectLater(
          adapter.listRemoteDataFiles(),
          throwsA(isA<S3ConnectionException>()),
        );
      },
    );
  });
}

class _LocalS3 {
  _LocalS3(this._server);

  final HttpServer _server;
  final objects = <String, List<int>>{};
  final contentTypes = <String, String?>{};
  bool denyWrite = false;
  bool denyList = false;
  bool sawSignedRequest = false;
  bool sawRegionRequest = false;
  int listRequests = 0;

  int get port => _server.port;

  static Future<_LocalS3> start() async {
    final server = _LocalS3(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    server._server.listen(server._handle);
    return server;
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    sawSignedRequest |=
        request.headers
            .value('authorization')
            ?.startsWith('AWS4-HMAC-SHA256 ') ??
        false;
    final key = request.uri.pathSegments.skip(1).join('/');
    if (request.uri.queryParameters.containsKey('location')) {
      sawRegionRequest = true;
      response.write('<LocationConstraint>us-east-1</LocationConstraint>');
    } else if (request.method == 'HEAD') {
      response.statusCode = 200;
    } else if ((request.method == 'PUT' && denyWrite) ||
        (request.uri.queryParameters.containsKey('prefix') && denyList)) {
      _error(response, 403, 'AccessDenied');
    } else if (request.method == 'PUT') {
      objects[key] = await request.fold<List<int>>([], (data, chunk) {
        data.addAll(chunk);
        return data;
      });
      contentTypes[key] = request.headers.contentType?.mimeType;
      response.headers.set('ETag', '"test-etag"');
    } else if (request.method == 'DELETE') {
      objects.remove(key);
      response.statusCode = 204;
    } else if (request.uri.queryParameters.containsKey('prefix')) {
      listRequests++;
      final prefix = request.uri.queryParameters['prefix']!;
      final marker = request.uri.queryParameters['marker'];
      final keys =
          objects.keys
              .where((key) => key.startsWith(prefix))
              .where((key) => marker == null || key.compareTo(marker) > 0)
              .toList()
            ..sort();
      final page = keys.take(1).toList();
      response.write(
        '<ListBucketResult><IsTruncated>${keys.length > 1}</IsTruncated>'
        '${keys.length > 1 ? '<NextMarker>${page.last}</NextMarker>' : ''}'
        '${page.map((key) => '<Contents><Key>$key</Key>'
            '<LastModified>2026-01-01T00:00:00Z</LastModified>'
            '<Size>${objects[key]!.length}</Size></Contents>').join()}'
        '</ListBucketResult>',
      );
    } else if (request.method == 'GET' && objects.containsKey(key)) {
      response.add(objects[key]!);
    } else {
      _error(response, 404, 'NoSuchKey');
    }
    await response.close();
  }

  void _error(HttpResponse response, int status, String code) {
    response.statusCode = status;
    response.headers.contentType = ContentType('application', 'xml');
    response.write(
      '<Error><Code>$code</Code>'
      '<Message>private-password at private-endpoint</Message></Error>',
    );
  }
}
