import 'dart:ui' as ui;

import 'package:auto_route/auto_route.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zephyr/config/router/router.gr.dart';
import 'package:zephyr/i18n/strings.g.dart';
import 'package:zephyr/page/comic_list/cubit/comic_list_cubit.dart';
import 'package:zephyr/page/discover/service/discover_router.dart';
import 'package:zephyr/page/plugin_home/cubit/plugin_home_cubit.dart';
import 'package:zephyr/page/plugin_home/plugin_home_bundle.dart';
import 'package:zephyr/page/plugin_home/view/plugin_home_tab_body.dart';
import 'package:zephyr/page/plugin_home/view/plugin_selector_dialog.dart';
import 'package:zephyr/cubit/plugin_registry_cubit.dart';
import 'package:zephyr/widgets/toast.dart';
import 'package:zephyr/widgets/navigation/glass_navigation_insets.dart';

/// 插件通用 TabView 骨架：标题位即 TabBar（可横滑）+ 右上随 tab 切换 + 左侧图标切插件。
///
/// [pageTitle] 为无 tab 时的标题；左侧图标为切换入口 + 当前插件定位。
/// 内容每次重进重载，不保活。
class PluginHomeScaffold extends StatefulWidget {
  const PluginHomeScaffold({
    super.key,
    required this.pageTitle,
    required this.selectorTitle,
    required this.createCubit,
  });

  final String pageTitle;
  final String selectorTitle;
  final PluginHomeCubit Function() createCubit;

  @override
  State<PluginHomeScaffold> createState() => _PluginHomeScaffoldState();
}

class _PluginHomeScaffoldState extends State<PluginHomeScaffold>
    with TickerProviderStateMixin {
  late final PluginHomeCubit _cubit;
  final Map<String, ComicListCubit> _sceneCubits = {};
  TabController? _tabController;
  int _tabIndex = 0;

  @override
  void initState() {
    super.initState();
    _cubit = widget.createCubit();
    // init 结束后直接加载，无延迟 hack。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _cubit.load();
      }
    });
  }

  @override
  void dispose() {
    _tabController?.dispose();
    for (final cubit in _sceneCubits.values) {
      cubit.close();
    }
    _cubit.close();
    super.dispose();
  }

  void _syncSceneCubits(PluginHomeState state) {
    final bundle = state.bundle;
    if (bundle == null) {
      _disposeSceneCubits();
      return;
    }
    final wanted = <String>{};
    for (var i = 0; i < bundle.tabs.length; i++) {
      final tab = bundle.tabs[i];
      if (tab.scene == null) {
        continue;
      }
      final key = '${tab.id}#$i';
      wanted.add(key);
      _sceneCubits.putIfAbsent(
        key,
        // 新两页内的 scene：登录错误不出全局弹窗，由 tab 错误体出登录/刷新。
        () => ComicListCubit(
          initialScene: tab.scene,
          suppressNeedLoginEvent: true,
        ),
      );
    }
    final stale = _sceneCubits.keys
        .where((key) => !wanted.contains(key))
        .toList();
    for (final key in stale) {
      _sceneCubits.remove(key)?.close();
    }
    _syncTabController(bundle.tabs.length);
  }

  void _disposeSceneCubits() {
    _tabController?.dispose();
    _tabController = null;
    _tabIndex = 0;
    for (final cubit in _sceneCubits.values) {
      cubit.close();
    }
    _sceneCubits.clear();
  }

  void _syncTabController(int tabCount) {
    if (tabCount <= 1) {
      _tabController?.dispose();
      _tabController = null;
      _tabIndex = 0;
      return;
    }
    if (_tabController == null || _tabController!.length != tabCount) {
      final previousIndex = _tabIndex.clamp(0, tabCount - 1);
      _tabController?.dispose();
      _tabController = TabController(
        length: tabCount,
        vsync: this,
        initialIndex: previousIndex,
      );
      _tabController!.addListener(_onTabChanged);
      _tabIndex = previousIndex;
    }
  }

  void _onTabChanged() {
    final controller = _tabController;
    if (controller == null || controller.indexIsChanging) {
      return;
    }
    if (_tabIndex != controller.index) {
      setState(() => _tabIndex = controller.index);
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider.value(
      value: _cubit,
      child: BlocConsumer<PluginHomeCubit, PluginHomeState>(
        listenWhen: (previous, current) =>
            previous.pluginId != current.pluginId ||
            previous.bundle != current.bundle ||
            previous.reloadSignal != current.reloadSignal,
        listener: (context, state) => _syncSceneCubits(state),
        builder: (context, state) {
          final bundle = state.bundle;
          final tabs = bundle?.tabs ?? const <PluginHomeTab>[];
          final activeIndex = tabs.isEmpty
              ? 0
              : _tabIndex.clamp(0, tabs.length - 1);
          final activeTab = tabs.isEmpty ? null : tabs[activeIndex];
          // 多 tab：标题位直接放 TabBar（isScrollable 横向可滚），右上 actions 常驻。
          // 单 tab / 无 tab：显示插件名（可点切换），没插件显示页标题。
          final hasTabBar = tabs.length > 1 && _tabController != null;
          final pluginName = state.pluginId.isEmpty
              ? ''
              : context.select<PluginRegistryCubit, String>(
                  (cubit) => cubit.state.pluginName(state.pluginId),
                );
          return Scaffold(
            appBar: AppBar(
              titleSpacing: hasTabBar ? 8 : null,
              title: hasTabBar
                  ? _GlassHomeCategoryBar(
                      controller: _tabController!,
                      tabs: tabs,
                    )
                  : InkWell(
                      onTap: () => _openSelector(context, state),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              pluginName.isNotEmpty
                                  ? pluginName
                                  : widget.pageTitle,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const Icon(Icons.arrow_drop_down),
                        ],
                      ),
                    ),
              actions: activeTab == null
                  ? const []
                  : _buildActions(context, state, activeTab, activeIndex),
            ),
            body: _HomeScrollFade(child: _buildBody(context, state)),
            floatingActionButton: Padding(
              padding: EdgeInsets.only(
                bottom: GlassNavigationInsets.floatingBottomOf(context),
              ),
              child: FloatingActionButton(
                heroTag: null,
                tooltip: widget.selectorTitle,
                onPressed: () => _openSelector(context, state),
                child: const Icon(Icons.extension_outlined),
              ),
            ),
          );
        },
      ),
    );
  }

  List<Widget> _buildActions(
    BuildContext context,
    PluginHomeState state,
    PluginHomeTab activeTab,
    int activeIndex,
  ) {
    if (activeTab.scene != null) {
      final sceneCubit = _sceneCubits['${activeTab.id}#$activeIndex'];
      if (sceneCubit == null) {
        return const [];
      }
      return [
        BlocProvider.value(
          value: sceneCubit,
          child: BlocBuilder<ComicListCubit, ComicListState>(
            builder: (context, sceneState) {
              if (sceneState.scene?.filter == null) {
                return const SizedBox.shrink();
              }
              return _GlassCircleActionButton(
                tooltip: t.comicList.filter,
                icon: Icons.filter_alt,
                onPressed: () =>
                    openPluginHomeFilterDialog(context, sceneCubit),
              );
            },
          ),
        ),
      ];
    }
    if (activeTab.headerActions.isEmpty) {
      return const [];
    }
    return [
      for (final action in activeTab.headerActions)
        _GlassCircleActionButton(
          tooltip: action['title']?.toString() ?? t.oldHome.function,
          icon: _iconForAction(action),
          onPressed: () => DiscoverRouter.route(
            context,
            action: DiscoverRouter.attachSource(action, state.pluginId),
            currentFrom: state.pluginId,
          ),
        ),
    ];
  }

  IconData _iconForAction(Map<String, dynamic> action) {
    final icon = action['icon']?.toString().trim() ?? '';
    if (icon.isNotEmpty) {
      return switch (icon) {
        'search' => Icons.search,
        'filter' => Icons.filter_alt,
        'settings' => Icons.settings_outlined,
        'refresh' => Icons.refresh,
        _ => Icons.play_arrow_outlined,
      };
    }
    return switch (action['type']?.toString().trim() ?? '') {
      'openSearch' => Icons.search,
      'openComicList' => Icons.view_list_outlined,
      'openPluginFunction' => Icons.extension_outlined,
      'openCloudFavorite' => Icons.cloud_outlined,
      'openWeb' => Icons.open_in_browser_outlined,
      'openComicInfo' => Icons.menu_book_outlined,
      _ => Icons.play_arrow_outlined,
    };
  }

  Widget _buildBody(BuildContext context, PluginHomeState state) {
    if (state.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.error.isNotEmpty) {
      final loginPluginId = state.loginPluginId;
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(state.error, textAlign: TextAlign.center),
            ),
            const SizedBox(height: 12),
            if (loginPluginId.isNotEmpty)
              Wrap(
                spacing: 12,
                alignment: WrapAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: () => _openLogin(context, loginPluginId),
                    icon: const Icon(Icons.login_outlined),
                    label: Text(t.login.loginButton),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _cubit.retry(),
                    icon: const Icon(Icons.refresh),
                    label: Text(t.common.retry),
                  ),
                ],
              )
            else
              ElevatedButton(
                onPressed: () => _cubit.retry(),
                child: Text(t.common.retry),
              ),
          ],
        ),
      );
    }
    final bundle = state.bundle;
    if (bundle == null || bundle.tabs.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(t.common.empty),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () => _openSelector(context, state),
              child: Text(widget.selectorTitle),
            ),
          ],
        ),
      );
    }
    final tabs = bundle.tabs;
    if (tabs.length <= 1 || _tabController == null) {
      final index = _tabIndex.clamp(0, tabs.length - 1);
      final tab = tabs[index];
      return PluginHomeTabBody(
        key: ValueKey('${state.pluginId}_${tab.id}_$index'),
        pluginId: state.pluginId,
        tab: tab,
        sceneCubit: tab.scene == null ? null : _sceneCubits['${tab.id}#$index'],
      );
    }
    // 多 tab：TabBarView 支持左右滑动切换，controller 与 TabBar 共用。
    // page tab（scheme 渲染）是 ListView，scene tab 是分页列表，
    // TabBarView 的横向手势与纵向滚动不冲突。
    return TabBarView(
      controller: _tabController,
      children: [
        for (var i = 0; i < tabs.length; i++)
          PluginHomeTabBody(
            key: ValueKey('${state.pluginId}_${tabs[i].id}_$i'),
            pluginId: state.pluginId,
            tab: tabs[i],
            sceneCubit: tabs[i].scene == null
                ? null
                : _sceneCubits['${tabs[i].id}#$i'],
          ),
      ],
    );
  }

  Future<void> _openSelector(
    BuildContext context,
    PluginHomeState state,
  ) async {
    final picked = await showPluginHomeSelector(
      context,
      candidates: state.candidates,
      selectedId: state.pluginId,
    );
    if (picked == null || !mounted) {
      return;
    }
    setState(() => _tabIndex = 0);
    await _cubit.switchPlugin(picked);
    if (!mounted) {
      return;
    }
    if (_cubit.state.error.isNotEmpty) {
      showErrorToast(_cubit.state.error);
    }
  }

  /// 登录错误页的登录按钮：进登录页，回来后重试拉 bundle。
  /// 登录成功会触发全局 initOk/插件状态变化，retry 即能拿到数据。
  Future<void> _openLogin(BuildContext context, String pluginId) async {
    await context.pushRoute(LoginRoute(from: pluginId));
    if (!mounted) {
      return;
    }
    await _cubit.retry();
  }
}

/// A compact, scrollable liquid-glass category strip used by plugin home pages.
/// The selected item is a blue capsule while the unselected items remain text
/// only, matching the iOS reference style and following the current theme.
class _GlassHomeCategoryBar extends StatelessWidget {
  const _GlassHomeCategoryBar({required this.controller, required this.tabs});

  final TabController controller;
  final List<PluginHomeTab> tabs;

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return _NativeGlassHomeCategoryBar(controller: controller, tabs: tabs);
    }
    return _FlutterGlassHomeCategoryBar(controller: controller, tabs: tabs);
  }
}

class _FlutterGlassHomeCategoryBar extends StatelessWidget {
  const _FlutterGlassHomeCategoryBar({required this.controller, required this.tabs});

  final TabController controller;
  final List<PluginHomeTab> tabs;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.surface.withValues(alpha: isDark ? .42 : .62),
            border: Border.all(
              color: scheme.outline.withValues(alpha: isDark ? .28 : .18),
            ),
            borderRadius: BorderRadius.circular(22),
          ),
          child: AnimatedBuilder(
            animation: controller,
            builder: (context, _) => SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < tabs.length; i++)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: _GlassCategoryChip(
                        label: tabs[i].title,
                        selected: controller.index == i,
                        onTap: () => controller.animateTo(
                          i,
                          duration: const Duration(milliseconds: 280),
                          curve: Curves.easeOutCubic,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// iOS category strip backed by UIKit's UIGlassEffect (iOS 26+) with a native
/// UIBlurEffect fallback on older iOS versions. Flutter only owns the labels
/// and tab controller state through the method channel.
class _NativeGlassHomeCategoryBar extends StatefulWidget {
  const _NativeGlassHomeCategoryBar({required this.controller, required this.tabs});

  final TabController controller;
  final List<PluginHomeTab> tabs;

  @override
  State<_NativeGlassHomeCategoryBar> createState() => _NativeGlassHomeCategoryBarState();
}

class _NativeGlassHomeCategoryBarState extends State<_NativeGlassHomeCategoryBar> {
  MethodChannel? _channel;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
  }

  void _onControllerChanged() => _sendConfiguration();

  Map<String, Object> get _configuration => {
        'labels': [for (final tab in widget.tabs) tab.title],
        'selectedIndex': widget.controller.index,
        'darkMode': Theme.of(context).brightness == Brightness.dark,
        'isRtl': Directionality.of(context) == TextDirection.rtl,
      };

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sendConfiguration();
  }

  @override
  void didUpdateWidget(covariant _NativeGlassHomeCategoryBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
    }
    _sendConfiguration();
  }

  void _sendConfiguration() {
    final channel = _channel;
    if (channel != null) {
      channel.invokeMethod<void>('update', _configuration);
    }
  }

  void _onPlatformViewCreated(int id) {
    final channel = MethodChannel('dcike/native_home_categories/$id');
    _channel = channel;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'selectCategory' && mounted) {
        final index = call.arguments;
        if (index is int && index >= 0 && index < widget.tabs.length) {
          widget.controller.animateTo(
            index,
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
          );
        }
      }
    });
    _sendConfiguration();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) => SizedBox(
        // AppBar title layout can briefly report an unbounded height while a
        // route is entering. Keep the platform view finite for UIKit.
        height: kToolbarHeight,
        child: UiKitView(
          viewType: 'dcike/native_home_categories',
          layoutDirection: Directionality.of(context),
          creationParams: _configuration,
          creationParamsCodec: const StandardMessageCodec(),
          onPlatformViewCreated: _onPlatformViewCreated,
        ),
      ),
    );
  }
}

class _GlassCategoryChip extends StatelessWidget {
  const _GlassCategoryChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
          decoration: BoxDecoration(
            color: selected
                ? scheme.primary.withValues(alpha: .92)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

/// Adds a subtle edge fade so vertical page movement has the soft transition
/// seen in the reference video. The overlay is pointer-transparent.
class _HomeScrollFade extends StatelessWidget {
  const _HomeScrollFade({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        IgnorePointer(
          child: Column(
            children: [
              SizedBox(
                height: 18,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [scheme.surface, scheme.surface.withValues(alpha: 0)],
                    ),
                  ),
                ),
              ),
              const Spacer(),
              SizedBox(
                height: 22,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [scheme.surface.withValues(alpha: 0), scheme.surface],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _GlassCircleActionButton extends StatelessWidget {
  const _GlassCircleActionButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 5),
      // Keep action buttons transparent. The old BackdropFilter + Material
      // combination produced a white translucent disk over every icon.
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon),
        visualDensity: VisualDensity.compact,
        style: IconButton.styleFrom(
          backgroundColor: Colors.transparent,
          overlayColor: Colors.transparent,
          shadowColor: Colors.transparent,
        ),
      ),
    );
  }
}
