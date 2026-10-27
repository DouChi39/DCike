import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';

/// A reusable surface backed by UIKit's UIGlassEffect on iOS 26+.
/// The child remains Flutter-owned so existing actions and accessibility stay
/// intact; the native view supplies the actual platform material.
class IosGlassSurface extends StatelessWidget {
  const IosGlassSurface({
    super.key,
    required this.child,
    this.cornerRadius = 20,
    this.style = IosGlassSurfaceStyle.regular,
    this.darkMode,
  });

  final Widget child;
  final double cornerRadius;
  final IosGlassSurfaceStyle style;
  final bool? darkMode;

  @override
  Widget build(BuildContext context) {
    final isDark = darkMode ?? MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    final fallback = DecoratedBox(
      decoration: BoxDecoration(
        color: isDark
            ? const Color(0xCC202124)
            : const Color(0xCCFFFFFF),
        borderRadius: BorderRadius.circular(cornerRadius),
        border: Border.all(
          color: isDark
              ? const Color(0x33FFFFFF)
              : const Color(0x33000000),
        ),
      ),
      child: child,
    );
    if (kIsWeb || !Platform.isIOS) return fallback;

    final params = <String, Object>{
      'darkMode': isDark,
      'cornerRadius': cornerRadius,
      'style': style.name,
    };
    return ClipRRect(
      borderRadius: BorderRadius.circular(cornerRadius),
      child: Stack(
        // Let the Flutter child determine the card's intrinsic height first.
        // A non-positioned UiKitView in a loose Column can otherwise receive
        // an infinite height and make FlutterTouchInterceptingView use NaN.
        fit: StackFit.loose,
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: UiKitView(
                viewType: 'dcike/native_glass_surface',
                layoutDirection: Directionality.of(context),
                creationParams: params,
                creationParamsCodec: const StandardMessageCodec(),
                gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

enum IosGlassSurfaceStyle { regular, clear }
