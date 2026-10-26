import 'package:flutter/widgets.dart';

const iosGlassTabBarHeight = 80.0;

/// Applied only inside the five iPhone root pages, never to pushed routes.
/// Lists can scroll behind the glass while their last row remains reachable.
class GlassNavigationInsets extends InheritedWidget {
  const GlassNavigationInsets({
    super.key,
    required this.bottom,
    required super.child,
  });

  final double bottom;

  static double bottomOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<GlassNavigationInsets>()
          ?.bottom ??
      0;

  /// Scaffolds already account for the system's bottom safe area for FABs.
  static double floatingBottomOf(BuildContext context) =>
      (bottomOf(context) - MediaQuery.paddingOf(context).bottom).clamp(
        0,
        double.infinity,
      );

  @override
  bool updateShouldNotify(GlassNavigationInsets oldWidget) =>
      bottom != oldWidget.bottom;
}
