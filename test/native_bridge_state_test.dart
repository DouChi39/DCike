import 'package:flutter_test/flutter_test.dart';
import 'package:zephyr/service/native/native_reader_state.dart';
import 'package:zephyr/service/native/native_settings_patch.dart';

void main() {
  test(
    'editing one sync setting preserves credentials and other preferences',
    () {
      final original = <String, dynamic>{
        'syncSetting': {
          'type': 'webdav',
          'webdav': {
            'host': 'https://example.invalid',
            'password': 'test-only',
          },
        },
        'readSetting': {'doubleTapZoom': true},
      };
      final merged = mergeNativeSettings(original, {
        'syncSetting': {
          'webdav': {'host': 'https://other.invalid'},
        },
      });
      expect((merged['syncSetting'] as Map)['webdav'], {
        'host': 'https://other.invalid',
        'password': 'test-only',
      });
      expect(merged['readSetting'], {'doubleTapZoom': true});
      expect(
        ((original['syncSetting'] as Map)['webdav'] as Map)['host'],
        'https://example.invalid',
      );
    },
  );

  test(
    'list edits replace rather than merge and false values are retained',
    () {
      expect(
        mergeNativeSettings(
          {
            'terms': ['old'],
            'enabled': true,
          },
          {'terms': <String>[], 'enabled': false},
        ),
        {'terms': <String>[], 'enabled': false},
      );
    },
  );

  test('history is compatible with existing page-plus-two convention', () {
    for (var page = 0; page < 10; page++) {
      expect(nativePageFromHistory(nativePageToHistory(page), 10), page);
    }
    expect(nativePageFromHistory(0, 10), 0);
    expect(nativePageFromHistory(99, 10), 9);
    expect(nativePageFromHistory(2, 0), 0);
  });
}
