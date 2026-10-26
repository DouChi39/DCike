import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zephyr/widgets/navigation/glass_navigation_insets.dart';
import 'package:zephyr/widgets/navigation/ios_glass_tab_bar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native tab updates follow theme, labels and selection changes', (
    tester,
  ) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    final updates = <Map<Object?, Object?>>[];
    late MethodChannel nativeChannel;
    late Map<Object?, Object?> initialConfiguration;
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
      call,
    ) async {
      if (call.method == 'create') {
        final arguments = call.arguments as Map<Object?, Object?>;
        initialConfiguration =
            const StandardMessageCodec().decodeMessage(
                  ByteData.sublistView(arguments['params'] as Uint8List),
                )
                as Map<Object?, Object?>;
        nativeChannel = MethodChannel(
          'dcike/native_tab_bar/${arguments['id']}',
        );
        messenger.setMockMethodCallHandler(nativeChannel, (call) async {
          if (call.method == 'update') {
            updates.add(call.arguments as Map<Object?, Object?>);
          }
          return null;
        });
      }
      return null;
    });
    final selected = <int>[];

    Widget host({required bool dark, required int index}) => MediaQuery(
      data: const MediaQueryData(),
      child: Directionality(
        textDirection: dark ? TextDirection.rtl : TextDirection.ltr,
        child: SizedBox(
          width: 390,
          height: 80,
          child: IosGlassTabBar(
            labels: dark
                ? const ['Home', 'Cloud', 'Shelf', 'Discover', 'More']
                : const ['首页', '云收藏', '书架', '发现', '更多'],
            selectedIndex: index,
            brightness: dark ? Brightness.dark : Brightness.light,
            textScale: 1.25,
            onSelected: selected.add,
          ),
        ),
      ),
    );

    await tester.pumpWidget(host(dark: false, index: 2));
    await tester.pump();
    expect(initialConfiguration['selectedIndex'], 2);
    expect(initialConfiguration['labels'], ['首页', '云收藏', '书架', '发现', '更多']);

    await tester.pumpWidget(host(dark: true, index: 4));
    await tester.pump();
    expect(updates.last['selectedIndex'], 4);
    expect(updates.last['darkMode'], isTrue);
    expect(updates.last['isRtl'], isTrue);
    expect(updates.last['textScale'], 1.25);
    expect(updates.last['labels'], [
      'Home',
      'Cloud',
      'Shelf',
      'Discover',
      'More',
    ]);

    Future<void> nativeSelect(Object? index) => messenger.handlePlatformMessage(
      nativeChannel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('selectTab', index),
      ),
      (_) {},
    );
    await nativeSelect(3);
    await nativeSelect(-1);
    await nativeSelect(5);
    await nativeSelect('2');
    expect(selected, [3]);

    await tester.pumpWidget(const SizedBox());
    await nativeSelect(1);
    expect(selected, [3]);
    messenger.setMockMethodCallHandler(nativeChannel, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
  });

  testWidgets('glass bottom space stays scoped to the root page', (
    tester,
  ) async {
    final values = <double>[];
    Widget probe() => Builder(
      builder: (context) {
        values.add(GlassNavigationInsets.bottomOf(context));
        values.add(GlassNavigationInsets.floatingBottomOf(context));
        return const SizedBox();
      },
    );
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(padding: EdgeInsets.only(bottom: 34)),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              GlassNavigationInsets(bottom: 114, child: probe()),
              probe(),
            ],
          ),
        ),
      ),
    );
    expect(values, [114, 80, 0, 0]);
  });
}
