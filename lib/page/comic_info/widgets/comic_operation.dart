import 'package:auto_route/auto_route.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:zephyr/config/global/global_setting.dart';
import 'package:zephyr/cubit/plugin_registry_cubit.dart';
import 'package:zephyr/network/http/plugin/unauthorized_payload.dart';
import 'package:zephyr/page/comic_info/models/auto_cloud_favorite.dart';
import 'package:zephyr/plugin/bridge/plugin_config_bridge.dart';
import 'package:zephyr/page/comic_info/models/favorite_workflow.dart';
import 'package:zephyr/page/comic_info/json/normal/normal_comic_all_info.dart';
import 'package:zephyr/page/comic_info/models/collect_comic.dart';
import 'package:zephyr/page/comic_follow/cubit/comic_follow_cubit.dart';
import 'package:zephyr/util/context/context_extensions.dart';
import 'package:zephyr/util/error_filter.dart';
import 'package:zephyr/config/router/router.gr.dart';
import 'package:zephyr/i18n/strings.g.dart';

import 'package:zephyr/widgets/dialog.dart';
import 'package:zephyr/widgets/glass/ios_glass_surface.dart';
import 'package:zephyr/widgets/toast.dart';

class ComicOperationWidget extends StatefulWidget {
  final NormalComicAllInfo normalInfo;
  final String from;
  final String? collectionTargetId;
  final String? collectionTargetName;
  final dynamic comicInfo;

  const ComicOperationWidget({
    super.key,
    required this.normalInfo,
    required this.from,
    this.collectionTargetId,
    this.collectionTargetName,
    required this.comicInfo,
  });

  @override
  State<ComicOperationWidget> createState() => _ComicOperationWidgetState();
}

class _ComicOperationWidgetState extends State<ComicOperationWidget> {
  dynamic get comicInfo => widget.comicInfo;
  NormalComicAllInfo get normalInfo => widget.normalInfo;
  ComicInfo get comicInfoView => normalInfo.comicInfo;
  bool isCollected = false;
  bool isLiked = false;
  bool isCloudCollected = false;
  bool _localFavoriteBusy = false;
  bool _cloudFavoriteBusy = false;
  bool _followBusy = false;

  @override
  void initState() {
    super.initState();
    _syncLocalCollectStatus();
    isLiked = normalInfo.isLiked;
    isCloudCollected = normalInfo.isFavourite;
  }

  Future<void> _syncLocalCollectStatus() async {
    final localCollected = await isLocalComicCollected(
      from: widget.from,
      comicId: comicInfoView.id,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      isCollected = localCollected;
    });
  }

  Future<void> _autoFollowIfEnabled() async {
    if (!context.read<GlobalSettingCubit>().state.autoFollowOnCollect) {
      return;
    }
    final followCubit = context.read<ComicFollowCubit>();
    final comicId = comicInfoView.id;
    if (followCubit.isFollowing(widget.from, comicId)) {
      return;
    }
    await followCubit.addOrUpdateFollow(
      source: widget.from,
      comicId: comicId,
      info: normalInfo,
      lastChapterCount: normalInfo.eps.length,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isFollowing = context.select<ComicFollowCubit, bool>(
      (cubit) => cubit.isFollowing(widget.from, comicInfoView.id),
    );
    final localCollectItem = _OperationItemData(
      icon: isCollected ? Icons.star : Icons.star_border,
      text: isCollected ? t.comicInfo.collected : t.comicInfo.collect,
      highlighted: isCollected,
      accentColor: const Color(0xFFE6A700),
      enabled: true,
      onTap: _localFavoriteBusy || _cloudFavoriteBusy
          ? null
          : _toggleLocalFavorite,
    );
    final cloudCollectItem = _OperationItemData(
      icon: isCloudCollected ? Icons.cloud_done_outlined : Icons.cloud_outlined,
      text: isCloudCollected
          ? t.comicInfo.cloudCollected
          : t.comicInfo.cloudCollect,
      highlighted: isCloudCollected,
      accentColor: Colors.pink,
      enabled: true,
      onTap: _localFavoriteBusy || _cloudFavoriteBusy
          ? null
          : _toggleCloudFavorite,
    );
    final followItem = _OperationItemData(
      icon: isFollowing ? Icons.notifications_active : Icons.notifications_none,
      text: isFollowing ? t.comicInfo.unfollow : t.comicInfo.follow,
      highlighted: isFollowing,
      accentColor: context.theme.colorScheme.primary,
      enabled: !_followBusy,
      onTap: _followBusy ? null : () => _toggleFollow(isFollowing),
    );
    final commentItem = _OperationItemData(
      icon: Icons.mode_comment_outlined,
      text: t.comicInfo.comments(count: normalInfo.totalComments),
      enabled: normalInfo.allowComments,
      onTap: _openComments,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 560;
        final lowerItems = [followItem, cloudCollectItem, commentItem];
        return IosGlassSurface(
          cornerRadius: 24,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _OperationCard(item: localCollectItem, fullWidth: true),
                const SizedBox(height: 8),
                Flex(
                  direction: compact ? Axis.vertical : Axis.horizontal,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < lowerItems.length; i++) ...[
                      if (i > 0)
                        SizedBox(
                          width: compact ? 0 : 8,
                          height: compact ? 8 : 0,
                        ),
                      if (compact)
                        _OperationCard(item: lowerItems[i])
                      else
                        Expanded(child: _OperationCard(item: lowerItems[i])),
                    ],
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _toggleFollow(bool isFollowing) async {
    if (_followBusy) return;
    setState(() => _followBusy = true);
    try {
      final followCubit = context.read<ComicFollowCubit>();
      if (isFollowing) {
        await followCubit.removeFollow(widget.from, comicInfoView.id);
      } else {
        await followCubit.addOrUpdateFollow(
          source: widget.from,
          comicId: comicInfoView.id,
          info: normalInfo,
          lastChapterCount: normalInfo.eps.length,
        );
      }
    } finally {
      if (mounted) setState(() => _followBusy = false);
    }
  }

  void _openComments() {
    if (!normalInfo.allowComments) {
      final reason = normalInfo.allowCommentsReason.trim();
      commonDialog(
        context,
        t.comicInfo.commentForbiddenTitle,
        reason.isNotEmpty ? reason : t.comicInfo.commentForbidden,
      );
      return;
    }

    context.pushRoute(
      PluginCommentsScaffoldRoute(
        from: widget.from,
        comicId: comicInfoView.id.toString(),
        comicTitle: comicInfoView.title,
      ),
    );
  }

  Future<void> _toggleLocalFavorite() async {
    if (_localFavoriteBusy || _cloudFavoriteBusy) return;
    setState(() => _localFavoriteBusy = true);
    try {
      // 取消收藏需要确认，因为会删除所有文件夹中的记录
      if (isCollected) {
        final confirmed = await _showUncollectConfirmDialog();
        if (!confirmed) {
          return;
        }
      }

      final next = await toggleLocalComicFavorite(
        from: widget.from,
        normalInfo: normalInfo,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        isCollected = next;
      });
      if (next) {
        showSuccessToast(t.comicInfo.addedToCollection);
        try {
          await _autoFollowIfEnabled();
        } finally {
          if (mounted) await _autoCloudCollectIfEnabled();
        }
      } else {
        showSuccessToast(t.comicInfo.removedFromCollection);
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      showErrorToast(
        t.comicInfo.localCollectFailed(
          error: normalizeSearchErrorMessage(error),
        ),
        duration: const Duration(seconds: 5),
      );
    } finally {
      if (mounted) setState(() => _localFavoriteBusy = false);
    }
  }

  Future<void> _autoCloudCollectIfEnabled() async {
    final enabled = context
        .read<GlobalSettingCubit>()
        .state
        .autoCloudCollectOnCollect;
    if (!enabled || isCloudCollected) return;

    try {
      final pluginId = widget.from.trim();
      final registry = context.read<PluginRegistryCubit>().state;
      final next = await autoCollectToCloud(
        enabled: enabled,
        pluginReady: registry.isReady(pluginId),
        supportsCloudFavorite: registry.hasCapability(
          pluginId,
          'haveCloudFavorite',
        ),
        currentStatus: isCloudCollected,
        loginConfig: loadPluginConfigValue<Map<String, dynamic>>(
          pluginId,
          '',
          fallback: const {},
        ),
        addFavorite: () => toggleCloudComicFavorite(
          context: context,
          from: pluginId,
          comicId: comicInfoView.id,
          currentStatus: false,
          legacyAllowCollected: normalInfo.allowCollected,
          legacyAllowCollectedReason: normalInfo.allowCollectedReason,
          suppressNeedLoginEvent: true,
        ),
      );
      if (mounted && next != null) {
        setState(() => isCloudCollected = next);
        if (next) showSuccessToast(t.comicInfo.cloudCollectSuccess);
      }
    } on PluginUnauthorizedException {
      // 会话过期也不自动打开登录页，本地收藏已经保存。
    } catch (error) {
      if (!mounted) return;
      final message = error is FavoriteWorkflowIncompleteException
          ? error.result.message ?? t.comicInfo.cloudCollectIncomplete
          : normalizeSearchErrorMessage(error);
      showInfoToast(t.settings.autoCloudCollectFailed(error: message));
    }
  }

  Future<void> _toggleCloudFavorite() async {
    if (_localFavoriteBusy || _cloudFavoriteBusy) return;
    setState(() => _cloudFavoriteBusy = true);
    try {
      showInfoToast(
        isCloudCollected
            ? t.comicInfo.removingCloudCollection
            : t.comicInfo.collectingToCloud,
      );
      final next = await toggleCloudComicFavorite(
        context: context,
        from: widget.from,
        comicId: comicInfoView.id,
        currentStatus: isCloudCollected,
        legacyAllowCollected: normalInfo.allowCollected,
        legacyAllowCollectedReason: normalInfo.allowCollectedReason,
        collectionTargetId: widget.collectionTargetId,
        collectionTargetName: widget.collectionTargetName,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        isCloudCollected = next;
      });
      if (next) {
        await _autoFollowIfEnabled();
      }
      showSuccessToast(
        next
            ? t.comicInfo.cloudCollectSuccess
            : t.comicInfo.cloudUncollectSuccess,
      );
    } on FavoriteWorkflowUnsupportedException catch (error) {
      if (mounted) {
        final reason = error.reason.trim();
        showInfoToast(
          reason.isNotEmpty ? reason : t.comicInfo.cloudCollectDisabled,
        );
      }
    } on FavoriteWorkflowIncompleteException catch (error) {
      if (mounted) {
        showInfoToast(
          error.result.message ?? t.comicInfo.cloudCollectIncomplete,
        );
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      showErrorToast(
        normalizeSearchErrorMessage(error),
        duration: const Duration(seconds: 5),
      );
    } finally {
      if (mounted) setState(() => _cloudFavoriteBusy = false);
    }
  }

  Future<bool> _showUncollectConfirmDialog() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(t.comicInfo.confirmUncollectTitle),
          content: Text(t.comicInfo.confirmUncollectContent),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(t.common.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(t.common.confirm),
            ),
          ],
        );
      },
    );
    return result == true;
  }

  Future<void> _toggleCloudLike() async {
    if (!normalInfo.allowLike) {
      final reason = normalInfo.allowLikeReason.trim();
      showInfoToast(reason.isNotEmpty ? reason : t.comicInfo.likeDisabled);
      return;
    }
    try {
      showInfoToast(isLiked ? t.comicInfo.unliking : t.comicInfo.liking);
      final next = await toggleCloudComicLike(
        from: widget.from,
        comicId: comicInfoView.id,
        currentStatus: isLiked,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        isLiked = next;
      });
      showSuccessToast(
        next ? t.comicInfo.likeSuccess : t.comicInfo.unlikeSuccess,
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      showErrorToast(
        t.comicInfo.likeFailed(error: normalizeSearchErrorMessage(error)),
        duration: const Duration(seconds: 5),
      );
    }
  }
}

class _OperationItemData {
  const _OperationItemData({
    required this.icon,
    required this.text,
    this.onTap,
    this.enabled = true,
    this.highlighted = false,
    this.accentColor,
  });

  final IconData icon;
  final String text;
  final VoidCallback? onTap;
  final bool enabled;
  final bool highlighted;
  final Color? accentColor;
}

class _OperationCard extends StatelessWidget {
  const _OperationCard({required this.item, this.compact = false, this.fullWidth = false});

  final _OperationItemData item;
  final bool compact;
  final bool fullWidth;

  @override
  Widget build(BuildContext context) {
    final accent = item.accentColor ?? context.theme.colorScheme.primary;
    final background = item.highlighted
        ? accent.withValues(alpha: 0.18)
        : context.theme.colorScheme.surfaceContainerLowest.withValues(
            alpha: 0.34,
          );
    final foreground = !item.enabled
        ? context.theme.colorScheme.onSurface.withValues(alpha: 0.38)
        : item.highlighted
        ? accent
        : context.textColor;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: item.onTap,
        child: Ink(
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(fullWidth ? 18 : 15),
            border: Border.all(
              color: accent.withValues(alpha: item.highlighted ? 0.35 : 0.16),
            ),
          ),
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 8 : 12,
            vertical: fullWidth ? 14 : (compact ? 10 : 12),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(item.icon, size: compact ? 18 : 20, color: foreground),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  item.text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.theme.textTheme.labelLarge?.copyWith(
                    color: foreground,
                    fontWeight: FontWeight.w700,
                    fontSize: compact ? 13 : null,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
