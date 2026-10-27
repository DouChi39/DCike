import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// UIKit renders the material and gestures; Flutter keeps the existing pages.
/// iOS 26 uses UIGlassEffect, while older iOS versions use UIBlurEffect.
class IosGlassTabBar extends StatefulWidget {
  const IosGlassTabBar({
    super.key,
    required this.labels,
    required this.selectedIndex,
    required this.brightness,
    required this.onSelected,
    this.textScale = 1,
  });

  final List<String> labels;
  final int selectedIndex;
  final Brightness brightness;
  final ValueChanged<int> onSelected;
  final double textScale;

  @override
  State<IosGlassTabBar> createState() => _IosGlassTabBarState();
}

class _IosGlassTabBarState extends State<IosGlassTabBar> {
  MethodChannel? _channel;

  Map<String, Object> get _configuration => {
    'labels': widget.labels,
    'selectedIndex': widget.selectedIndex,
    'darkMode': widget.brightness == Brightness.dark,
    'textScale': widget.textScale,
    'isRtl': Directionality.of(context) == TextDirection.rtl,
  };

  @override
  void didUpdateWidget(covariant IosGlassTabBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sendConfiguration();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sendConfiguration();
  }

  void _sendConfiguration() {
    final channel = _channel;
    if (channel != null) {
      unawaited(channel.invokeMethod<void>('update', _configuration));
    }
  }

  void _onPlatformViewCreated(int id) {
    final channel = MethodChannel('dcike/native_tab_bar/$id');
    _channel = channel;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'selectTab' && mounted) {
        final index = call.arguments;
        if (index is int && index >= 0 && index < widget.labels.length) {
          widget.onSelected(index);
        }
      }
    });
    // Creation parameters can be stale after a fast theme/tab change.
    _sendConfiguration();
  }

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      // Keep UIKit's platform view finite during route transitions and safe
      // area changes; an unbounded height becomes NaN inside UIScrollView.
      height: 80,
      child: UiKitView(
        viewType: 'dcike/native_tab_bar',
        layoutDirection: Directionality.of(context),
        creationParams: _configuration,
        creationParamsCodec: const StandardMessageCodec(),
        onPlatformViewCreated: _onPlatformViewCreated,
        gestureRecognizers: {
          Factory<OneSequenceGestureRecognizer>(() => EagerGestureRecognizer()),
        },
      ),
    );
  }
}
