import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

const EdgeInsets kSettingPagePadding = EdgeInsets.fromLTRB(16, 12, 16, 24);

const WidgetStateProperty<Icon> kSettingSwitchThumbIcon =
    WidgetStateProperty<Icon>.fromMap(<WidgetStatesConstraint, Icon>{
      WidgetState.selected: Icon(Icons.check),
      WidgetState.any: Icon(Icons.close),
    });

/// A settings switch backed by UIKit on iOS.
///
/// iOS 26 renders the switch surface through the native
/// `UIGlassEffect`; older iOS releases use Apple's native material blur and
/// other platforms keep the regular Material switch. Keeping the row in
/// Flutter means all existing setting callbacks and accessibility labels are
/// preserved.
class GlassSwitchListTile extends StatefulWidget {
  const GlassSwitchListTile({
    super.key,
    this.leading,
    this.secondary,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
    this.thumbIcon,
    this.contentPadding,
    this.dense,
  });

  final Widget? leading;
  final Widget? secondary;
  final Widget title;
  final Widget? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final WidgetStateProperty<Icon>? thumbIcon;
  final EdgeInsetsGeometry? contentPadding;
  final bool? dense;

  @override
  State<GlassSwitchListTile> createState() => _GlassSwitchListTileState();
}

class _GlassSwitchListTileState extends State<GlassSwitchListTile> {
  static int _nextViewId = 0;
  late final int _viewId = _nextViewId++;
  MethodChannel? _channel;

  bool get _nativeIOS => defaultTargetPlatform == TargetPlatform.iOS;

  Map<String, Object> get _configuration => {
        'value': widget.value,
        'enabled': widget.onChanged != null,
        'darkMode': Theme.of(context).brightness == Brightness.dark,
      };

  @override
  void didUpdateWidget(covariant GlassSwitchListTile oldWidget) {
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
    final channel = MethodChannel('dcike/native_glass_switch/$id');
    _channel = channel;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'valueChanged' && mounted && widget.onChanged != null) {
        final value = call.arguments;
        if (value is bool) widget.onChanged!(value);
      }
    });
    _sendConfiguration();
  }

  Widget _switch(BuildContext context) {
    if (!_nativeIOS) {
      return Switch(
        value: widget.value,
        onChanged: widget.onChanged,
        thumbIcon: widget.thumbIcon ?? kSettingSwitchThumbIcon,
      );
    }
    return SizedBox(
      width: 58,
      height: 34,
      child: UiKitView(
        key: ValueKey('dcike-glass-switch-$_viewId'),
        viewType: 'dcike/native_glass_switch',
        creationParams: _configuration,
        creationParamsCodec: const StandardMessageCodec(),
        onPlatformViewCreated: _onPlatformViewCreated,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_nativeIOS) {
      return SwitchListTile(
        leading: widget.leading,
        secondary: widget.secondary,
        title: widget.title,
        subtitle: widget.subtitle,
        value: widget.value,
        onChanged: widget.onChanged,
        thumbIcon: widget.thumbIcon ?? kSettingSwitchThumbIcon,
        contentPadding: widget.contentPadding,
        dense: widget.dense,
      );
    }
    return ListTile(
      leading: widget.leading ?? widget.secondary,
      title: widget.title,
      subtitle: widget.subtitle,
      trailing: _switch(context),
      onTap: widget.onChanged == null
          ? null
          : () => widget.onChanged!(!widget.value),
      contentPadding: widget.contentPadding,
      dense: widget.dense,
    );
  }

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }
}

/// 设置页统一外壳：AppBar + 居中限宽内容区。
class SettingPageShell extends StatelessWidget {
  const SettingPageShell({super.key, required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          title,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        centerTitle: false,
        scrolledUnderElevation: 0,
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 768),
          child: child,
        ),
      ),
    );
  }
}

Widget settingSectionTitle(
  BuildContext context,
  String title, {
  IconData? icon,
}) {
  return Padding(
    padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
    child: Row(
      children: [
        if (icon != null) ...[
          Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
        ],
        Text(
          title,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.primary,
            letterSpacing: 0.5,
          ),
        ),
      ],
    ),
  );
}

Widget settingCategoryTile({
  required IconData icon,
  required String title,
  required String subtitle,
  required VoidCallback onTap,
}) {
  return ListTile(
    leading: Icon(icon),
    title: Text(title),
    subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
    trailing: const Icon(Icons.chevron_right),
    onTap: onTap,
  );
}

class SettingSectionCard extends StatelessWidget {
  const SettingSectionCard({
    super.key,
    required this.title,
    required this.icon,
    required this.children,
  });

  final String title;
  final IconData icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Column(
        children: [
          ListTile(
            leading: Icon(icon),
            title: Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          const Divider(height: 1),
          ..._withDividers(children),
        ],
      ),
    );
  }

  List<Widget> _withDividers(List<Widget> children) {
    final widgets = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      widgets.add(children[i]);
      if (i != children.length - 1) {
        widgets.add(const Divider(height: 1));
      }
    }
    return widgets;
  }
}

ButtonStyle settingDangerButtonStyle(BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  return FilledButton.styleFrom(
    minimumSize: const Size.fromHeight(44),
    backgroundColor: scheme.errorContainer,
    foregroundColor: scheme.onErrorContainer,
  );
}
