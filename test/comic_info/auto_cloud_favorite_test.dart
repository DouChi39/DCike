import 'package:flutter_test/flutter_test.dart';
import 'package:zephyr/page/comic_info/models/auto_cloud_favorite.dart';

void main() {
  test('account and password alone are not a logged in session', () {
    expect(hasPluginLoginSession({}), isFalse);
    expect(
      hasPluginLoginSession({
        'auth.username': 'reader',
        'auth.password': 'saved-password',
        'auth.token': '',
        'auth.userInfo': '{}',
      }),
      isFalse,
    );
  });

  test('recognizes Copy, Bika and JM saved sessions', () {
    for (final config in <Map<String, dynamic>>[
      {'auth.token': 'copy-session'},
      {'auth.authorization': 'bika-session'},
      {'auth.userInfo': '{"uid":"123","username":"reader"}'},
      {
        'auth.userInfo': {'uid': 123},
      },
    ]) {
      expect(hasPluginLoginSession(config), isTrue);
    }
    expect(
      hasPluginLoginSession({
        'auth.userInfo': {'uid': 0},
      }),
      isFalse,
    );
  });

  test('skips without any cloud call for each ineligible condition', () async {
    var calls = 0;
    for (var condition = 0; condition < 5; condition++) {
      final result = await autoCollectToCloud(
        enabled: condition != 0,
        pluginReady: condition != 1,
        supportsCloudFavorite: condition != 2,
        currentStatus: condition == 3,
        loginConfig: condition == 4 ? {} : {'auth.token': 'session'},
        addFavorite: () async {
          calls++;
          return true;
        },
      );
      expect(result, isNull);
    }
    expect(calls, 0);
  });

  test('eligible local favorite requests one cloud addition', () async {
    var calls = 0;
    expect(
      await autoCollectToCloud(
        enabled: true,
        pluginReady: true,
        supportsCloudFavorite: true,
        currentStatus: false,
        loginConfig: {'auth.token': 'session'},
        addFavorite: () async {
          calls++;
          return true;
        },
      ),
      isTrue,
    );
    expect(calls, 1);
  });

  test('cloud failure is reported to caller without retrying', () async {
    var calls = 0;
    await expectLater(
      autoCollectToCloud(
        enabled: true,
        pluginReady: true,
        supportsCloudFavorite: true,
        currentStatus: false,
        loginConfig: {'auth.token': 'session'},
        addFavorite: () async {
          calls++;
          throw StateError('offline');
        },
      ),
      throwsStateError,
    );
    expect(calls, 1);
  });
}
