import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:zephyr/config/global/global_setting.dart';
import 'package:zephyr/main.dart';
import 'package:zephyr/network/http/picture/picture.dart';
import 'package:zephyr/network/http/plugin/unified_comic_plugin.dart';
import 'package:zephyr/network/sync/sync_service.dart' as sync;
import 'package:zephyr/page/comic_follow/cubit/comic_follow_cubit.dart';
import 'package:zephyr/page/comic_info/method/get_plugin_detail.dart';
import 'package:zephyr/page/comic_info/models/auto_cloud_favorite.dart';
import 'package:zephyr/page/comic_info/models/collect_comic.dart';
import 'package:zephyr/page/comic_info/json/normal/normal_comic_all_info.dart'
    as normal;
import 'package:zephyr/page/comic_read/method/get_plugin_read_snapshot.dart';
import 'package:zephyr/page/comic_read/method/get_local_info.dart';
import 'package:zephyr/page/comic_read/controller/reader_orientation_controller.dart';
import 'package:zephyr/page/comic_read/model/normal_comic_ep_info.dart';
import 'package:zephyr/page/plugin_store/models/cloud_plugin_item.dart';
import 'package:zephyr/page/setting/data_backup/method.dart';
import 'package:zephyr/plugin/bridge/plugin_config_bridge.dart';
import 'package:zephyr/plugin/plugin_install_service.dart';
import 'package:zephyr/plugin/plugin_registry_service.dart';
import 'package:zephyr/plugin/utils/plugin_cloud_download_utils.dart';
import 'package:zephyr/service/download/download_queue_manager.dart';
import 'package:zephyr/service/download/models/download_task_json.dart';
import 'package:zephyr/service/native/native_settings_patch.dart';
import 'package:zephyr/service/native/native_reader_state.dart';
import 'package:zephyr/service/reader/reader_history_service.dart';
import 'package:zephyr/type/enum.dart';
import 'package:zephyr/util/get_path.dart';
import 'package:zephyr/util/json/json_value.dart';
import 'package:zephyr/widgets/gesture_lock.dart'
    show hashGesturePattern, hashPinCode;

/// In-process UI bridge. No network transport, credentials or diagnostic logs.
class IosNativeBridge {
  static const channel = MethodChannel('dcike/swiftui');
  static IosNativeBridge? _instance;
  final GlobalSettingCubit _settings;
  final ComicFollowCubit _follows;
  final _subscriptions = <StreamSubscription<dynamic>>[];
  final _details = <String, PluginComicDetail>{};
  NormalComicEpInfo? _reading;
  int _readPage = 0;
  int _readOrder = 0;
  bool _initialized = false;
  bool _mounted = false;
  ReaderOrientationController? _orientation;

  IosNativeBridge._(BuildContext context)
    : _settings = context.read<GlobalSettingCubit>(),
      _follows = context.read<ComicFollowCubit>();

  GlobalSettingCubit get settings => _settings;
  ComicFollowCubit get follows => _follows;

  static IosNativeBridge _forContext(BuildContext context) =>
      _instance ??= IosNativeBridge._(context);

  static Future<bool> mountForBootstrap(BuildContext context) =>
      _forContext(context).mount();

  static Future<bool> mountForNavigation(BuildContext context) =>
      _forContext(context).mount();

  static Future<bool> completeBootstrap() async =>
      await channel.invokeMethod<bool>('completeBootstrap') ?? false;

  Future<bool> mount() async {
    if (!_initialized) {
      channel.setMethodCallHandler((call) async {
        try {
          return await _request(call.method, asJsonMap(call.arguments));
        } catch (error) {
          // Do not send raw plugin errors, which can contain URLs/tokens.
          throw PlatformException(
            code: 'NATIVE_REQUEST_FAILED',
            message: '操作未完成，请检查网络、图源是否可用，以及是否已登录后重试。',
          );
        }
      });
      _subscriptions.add(settings.stream.listen((_) => _changed()));
      _subscriptions.add(
        PluginRegistryService.I.stream.listen((_) => _changed()),
      );
      _subscriptions.add(
        PluginRegistryService.I.initOkStream.listen((_) => _changed()),
      );
      _subscriptions.add(follows.stream.listen((_) => _changed()));
      _initialized = true;
    }
    if (_mounted) return true;
    _mounted = await channel.invokeMethod<bool>('mount') ?? false;
    return _mounted;
  }

  void _changed() => unawaited(channel.invokeMethod<void>('changed'));
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    ReaderHistoryService.instance.stop();
    channel.setMethodCallHandler(null);
  }

  Future<dynamic> plugin(
    String source,
    String fn,
    Map<String, dynamic> core, [
    Map<String, dynamic> extern = const {},
  ]) => callUnifiedComicPlugin(
    from: source,
    fnPath: fn,
    core: core,
    extern: extern,
    suppressNeedLoginEvent: true,
  );

  Future<PluginComicDetail> _detail(String source, String id) async {
    final key = '$source:$id';
    final local = objectbox.unifiedDownloadBox
        .getAll()
        .where((d) => d.uniqueKey == key && !d.deleted)
        .firstOrNull;
    try {
      final detail = await getComicDetailByPlugin(id, source);
      _details[key] = detail;
      return detail;
    } catch (_) {
      if (local == null) rethrow;
      final info = normal.NormalComicAllInfo.fromJson(
        asJsonMap(jsonDecode(local.detailJson)),
      );
      final detail = PluginComicDetail(
        normalInfo: info,
        source: PluginComicDetailSource(
          from: source,
          normalInfo: info,
          raw: const {},
        ),
      );
      _details[key] = detail;
      return detail;
    }
  }

  Future<dynamic> _request(String method, Map<String, dynamic> a) async {
    final source = a['source']?.toString() ?? '';
    final id = a['comicId']?.toString() ?? '';
    switch (method) {
      case 'bootstrap':
        return {'settings': settings.state.toJson(), 'plugins': _plugins()};
      case 'verifyGesture':
        final pattern =
            (a['pattern'] as List?)
                ?.map((value) => (value as num).toInt())
                .toList(growable: false) ??
            const <int>[];
        return pattern.length >= 4 &&
            hashGesturePattern(pattern) ==
                settings.state.appLockSetting.gesturePasswordHash;
      case 'verifyPin':
        final pin = a['pin']?.toString() ?? '';
        return hashPinCode(pin) == settings.state.appLockSetting.resetPinHash;
      case 'clearLock':
        settings.updateState(
          (current) =>
              current.copyWith(appLockSetting: const AppLockSettingState()),
        );
        return true;
      case 'setLock':
        final patternHash = a['gesturePasswordHash']?.toString() ?? '';
        final pinHash = a['resetPinHash']?.toString() ?? '';
        if (patternHash.isEmpty || pinHash.isEmpty) {
          throw StateError('请完成手势密码和 PIN 设置。');
        }
        settings.updateState(
          (current) => current.copyWith(
            appLockSetting: AppLockSettingState(
              enabled: a['enabled'] != false,
              gesturePasswordHash: patternHash,
              resetPinHash: pinHash,
            ),
          ),
        );
        return settings.state.appLockSetting.toJson();
      case 'plugin':
        return plugin(
          source,
          a['fn'] as String,
          asJsonMap(a['core']),
          asJsonMap(a['extern']),
        );
      case 'settings':
        final patch = asJsonMap(a['patch']);
        settings.updateALl(
          GlobalSettingState.fromJson(
            mergeNativeSettings(settings.state.toJson(), patch),
          ),
        );
        return settings.state.toJson();
      case 'image':
        final image = asJsonMap(a['image']);
        final url = (image['url'] ?? image['fileServer'] ?? '').toString();
        var path = image['path']?.toString() ?? '';
        if (path.isEmpty && url.isNotEmpty) {
          path = Uri.tryParse(url)?.path ?? '';
        }
        return getCachePicture(
          from: source,
          url: url,
          path: path,
          cartoonId: id.isEmpty ? (image['id']?.toString() ?? 'cover') : id,
          chapterId: a['chapterId']?.toString() ?? '',
          storageChapterId: image['storageChapterId']?.toString() ?? '',
          pictureType: switch (a['pictureType']?.toString()) {
            'category' => PictureType.category,
            'page' => PictureType.page,
            'cover' => PictureType.cover,
            _ => a['page'] == true ? PictureType.page : PictureType.cover,
          },
          extern: asJsonMap(image['extern']),
          index: (a['index'] as num?)?.toInt() ?? 0,
        );
      case 'asset':
        final asset = a['name'] == 'avatar'
            ? 'asset/image/dcike-about-avatar.png'
            : 'asset/image/dcike-about-avatar.png';
        final bytes = await rootBundle.load(asset);
        return bytes.buffer.asUint8List(
          bytes.offsetInBytes,
          bytes.lengthInBytes,
        );
      case 'detail':
        final d = await _detail(source, id);
        final history = objectbox.unifiedHistoryBox
            .getAll()
            .where((h) => h.uniqueKey == '$source:$id' && !h.deleted)
            .firstOrNull;
        return {
          ...d.normalInfo.toJson(),
          'localFavorite': await isLocalComicCollected(
            from: source,
            comicId: id,
          ),
          'following': follows.isFollowing(source, id),
          'history': history?.toJson(),
        };
      case 'favorite':
        final d = _details['$source:$id'] ?? await _detail(source, id);
        final value = await toggleLocalComicFavorite(
          from: source,
          normalInfo: d.normalInfo,
          showToast: false,
        );
        if (value && settings.state.autoFollowOnCollect) {
          await follows.addOrUpdateFollow(
            source: source,
            comicId: id,
            info: d.normalInfo,
          );
        }
        var cloud = d.normalInfo.isFavourite;
        String? warning;
        try {
          if (value) {
            final result = await autoCollectToCloud(
              enabled: settings.state.autoCloudCollectOnCollect,
              pluginReady: PluginRegistryService.I.isPluginInitOk(source),
              supportsCloudFavorite: d.normalInfo.allowCollected,
              currentStatus: cloud,
              loginConfig: loadPluginConfigValue<Map<String, dynamic>>(
                source,
                '',
                fallback: {},
              ),
              addFavorite: () => _cloudFavorite(source, id, false),
            );
            cloud = result ?? cloud;
          }
        } catch (_) {
          warning = '本地收藏已保存，云收藏未完成，请手动重试。';
        }
        return {
          'localFavorite': value,
          'following': follows.isFollowing(source, id),
          'isFavourite': cloud,
          'warning': warning,
        };
      case 'cloudFavorite':
        return _cloudFavorite(source, id, a['current'] == true);
      case 'follow':
        if (follows.isFollowing(source, id)) {
          await follows.removeFollow(source, id);
        } else {
          final d = _details['$source:$id'] ?? await _detail(source, id);
          await follows.addOrUpdateFollow(
            source: source,
            comicId: id,
            info: d.normalInfo,
          );
        }
        return follows.isFollowing(source, id);
      case 'library':
        return _library(a['kind']?.toString() ?? 'favorite');
      case 'chapter':
        final d = _details['$source:$id'] ?? await _detail(source, id);
        final chapter = asJsonMap(a['chapter']);
        final order = (chapter['order'] as num?)?.toInt() ?? 0;
        ReaderHistoryService.instance.stop();
        await ReaderHistoryService.instance.flush();
        NormalComicEpInfo ep;
        try {
          ep = await getPluginReadSnapshot(
            id,
            order,
            source,
            d.source,
            chapter['id']?.toString(),
            chapter['requestId']?.toString() ?? '',
            chapter['logicalKey']?.toString() ?? '',
            chapter['storageChapterId']?.toString() ?? '',
            asJsonMap(chapter['extern']),
          );
        } catch (_) {
          ep = await getPluginInfoFromLocal(source, id, order);
        }
        _reading = ep;
        _readOrder = order;
        await ReaderHistoryService.instance.loadHistory(
          source: source,
          comicId: id,
          comicInfo: d.source,
        );
        final saved = objectbox.unifiedHistoryBox
            .getAll()
            .where(
              (h) =>
                  h.uniqueKey == '$source:$id' &&
                  h.chapterId == ep.epId &&
                  !h.deleted,
            )
            .firstOrNull;
        final initialPage = nativePageFromHistory(
          saved?.pageIndex ?? 0,
          ep.docs.length,
        );
        _readPage = nativePageToHistory(initialPage);
        ReaderHistoryService.instance.markLoaded();
        ReaderHistoryService.instance.startPeriodicSave(
          () => HistorySnapshot(
            pageIndex: _readPage,
            chapterOrder: _readOrder,
            epInfo: _reading!,
          ),
        );
        return {
          'id': ep.epId,
          'title': ep.epName,
          'pages': ep.docs.map((e) => e.toJson()).toList(),
          'pageIndex': initialPage,
        };
      case 'progress':
        if (a['chapterId'] == _reading?.epId) {
          _readPage = nativePageToHistory((a['page'] as num?)?.toInt() ?? 0);
        }
        return null;
      case 'endReading':
        ReaderHistoryService.instance.stop();
        if (a['chapterId'] == _reading?.epId && a['page'] is num) {
          _readPage = nativePageToHistory((a['page'] as num).toInt());
        }
        await ReaderHistoryService.instance.flush();
        await _orientation?.restorePortrait();
        _orientation = null;
        await follows.refreshHistories();
        return null;
      case 'readerOrientation':
        _orientation ??= ReaderOrientationController();
        await _orientation!.setLandscape(a['landscape'] == true);
        return null;
      case 'saveReading':
        if (a['chapterId'] == _reading?.epId && a['page'] is num) {
          _readPage = nativePageToHistory((a['page'] as num).toInt());
        }
        await ReaderHistoryService.instance.flush();
        return null;
      case 'download':
        final d = _details['$source:$id'] ?? await _detail(source, id);
        if (!d.normalInfo.allowDownload) {
          throw StateError(d.normalInfo.allowDownloadReason);
        }
        final selected =
            (a['chapters'] as List?)?.map(asJsonMap).toList() ?? [];
        DownloadQueueManager.instance.addTasks(
          selected
              .map(
                (c) => DownloadTaskJson(
                  from: source,
                  comicId: id,
                  comicName: d.normalInfo.comicInfo.title,
                  chapterRef: DownloadChapterTaskRef(
                    chapterId: c['id']?.toString() ?? '',
                    requestId: c['requestId']?.toString() ?? '',
                    storageChapterId: c['storageChapterId']?.toString() ?? '',
                    logicalKey: c['logicalKey']?.toString() ?? '',
                    title: c['name']?.toString() ?? '',
                    groupTitle: c['groupTitle']?.toString() ?? '',
                    order: (c['order'] as num?)?.toInt() ?? 0,
                    extern: asJsonMap(c['extern']),
                  ),
                ),
              )
              .toList(),
        );
        return null;
      case 'tasks':
        return objectbox.downloadTaskBox
            .getAll()
            .map(
              (t) => {
                'id': t.id,
                'title': t.comicName,
                'status': t.status,
                'completed': t.isCompleted,
                'task': t.taskInfo?.toJson(),
              },
            )
            .toList();
      case 'retryTask':
        await DownloadQueueManager.instance.retryTask((a['id'] as num).toInt());
        return null;
      case 'pluginField':
        final f = asJsonMap(a['field']);
        final key = f['key']?.toString() ?? '';
        final fn = f['fnPath']?.toString() ?? '';
        dynamic response;
        if (fn.isNotEmpty) {
          response = await plugin(source, fn, {
            'key': key,
            'value': a['value'],
          });
        }
        if (f['persist'] != false && key.isNotEmpty) {
          await savePluginConfigValue(source, key, a['value']);
        }
        return response;
      case 'pluginEnabled':
        await PluginRegistryService.I.setEnabled(source, a['value'] == true);
        return null;
      case 'pluginStore':
        return jsonDecode(await fetchCloudPluginListWithCdnFallback());
      case 'installPlugin':
        if (a['item'] is Map) {
          return PluginInstallService.I.installFromCloud(
            CloudPluginItem.fromJson(asJsonMap(a['item'])),
          );
        }
        if (a['path'] is String) {
          return PluginInstallService.I.installFromLocalBytes(
            await File(a['path'] as String).readAsBytes(),
            fileName: a['name']?.toString() ?? '',
            allowReplaceExisting: true,
          );
        }
        return PluginInstallService.I.installFromNetworkUrl(
          a['url'] as String,
          allowReplaceExisting: true,
        );
      case 'sync':
        final args = settings.state;
        if (a['direction'] == 'upload') {
          await sync.manualUploadToCloud(
            state: args,
            globalSettingCubit: settings,
            comicFollowCubit: follows,
          );
        } else if (a['direction'] == 'download') {
          await sync.manualDownloadFromCloud(
            state: args,
            globalSettingCubit: settings,
            comicFollowCubit: follows,
          );
        } else {
          await sync.autoSync(
            args,
            globalSettingCubit: settings,
            comicFollowCubit: follows,
          );
        }
        return null;
      case 'export':
        final root = await getFilePath();
        return exportBreezeBackup(
          zipPath: '$root/DCike-backup.zip',
          includeDownloads: a['includeDownloads'] == true,
        );
      case 'import':
        if (a['confirmed'] != true) throw StateError('请先确认恢复备份');
        final config = await readBackupConfig(a['path'] as String);
        await applyBreezeBackupImport(config);
        await settings.initBox();
        await follows.loadFromDatabase();
        return null;
      default:
        throw MissingPluginException('Unknown native operation');
    }
  }

  List<Map<String, dynamic>> _plugins() => PluginRegistryService
      .I
      .snapshot
      .values
      .where((p) => !p.isDeleted)
      .map((p) {
        final info =
            PluginRegistryService.I.getCachedPluginInfo(p.uuid) ??
            <String, dynamic>{};
        return {
          'id': p.uuid,
          'name': info['name'] ?? p.uuid,
          'version': p.version,
          'enabled': p.isEnabled,
          'ready': PluginRegistryService.I.isPluginInitOk(p.uuid),
          'sortOrder': p.sortOrder,
          'insertedAt': p.insertedAt.toIso8601String(),
          'info': info,
        };
      })
      .toList();

  List<Map<String, dynamic>> _library(String kind) {
    final List<Map<String, dynamic>> rows = switch (kind) {
      'history' =>
        objectbox.unifiedHistoryBox
            .getAll()
            .where((v) => !v.deleted)
            .map((v) => v.toJson())
            .toList(),
      'download' =>
        objectbox.unifiedDownloadBox
            .getAll()
            .where((v) => !v.deleted)
            .map((v) => v.toJson())
            .toList(),
      'follow' =>
        objectbox.comicFollowBox
            .getAll()
            .where((v) => !v.deleted)
            .map((v) => v.toJson())
            .toList(),
      _ =>
        objectbox.unifiedFavoriteBox
            .getAll()
            .where((v) => !v.deleted)
            .map((v) => v.toJson())
            .toList(),
    };
    rows.sort(
      (a, b) => (b['updatedAt']?.toString() ?? '').compareTo(
        a['updatedAt']?.toString() ?? '',
      ),
    );
    return rows
        .map(
          (r) => {
            ...r,
            'id': r['comicId'],
            'cover': r['cover'] is String
                ? jsonDecode(r['cover'] as String)
                : r['cover'],
          },
        )
        .toList();
  }

  Future<bool> _cloudFavorite(String source, String id, bool current) async {
    final action = current ? 'removeAll' : 'add';
    Map<String, dynamic> response;
    try {
      response = asJsonMap(
        await plugin(source, 'startFavoriteAction', {
          'comicId': id,
          'action': action,
          'currentFavorite': current,
        }),
      );
    } catch (error) {
      final text = error.toString().toLowerCase();
      if (!text.contains('startfavoriteaction') ||
          !(text.contains('function') || text.contains('undefined'))) {
        rethrow;
      }
      final legacy = asJsonMap(
        await plugin(source, 'toggleFavorite', {
          'comicId': id,
          'currentFavorite': current,
        }),
      );
      if (legacy['favorited'] is! bool) throw StateError('图源未返回收藏结果');
      // Modern built-in sources use the workflow protocol.
      if (legacy['nextStep'] == 'selectFolder') {
        throw StateError('已云收藏，但此旧版图源的文件夹选择需要更新图源。');
      }
      return legacy['favorited'] as bool;
    }
    for (var step = 0; step < 16; step++) {
      final data = asJsonMap(response['data']);
      final result = data.containsKey('status') ? data : response;
      final status = result['status'];
      if (status == 'completed' && result['favorited'] is bool) {
        return result['favorited'] as bool;
      }
      if (status != 'awaitingInput') {
        throw StateError(result['message']?.toString() ?? '云收藏未完成');
      }
      final input = await channel.invokeMapMethod<String, dynamic>(
        'input',
        asJsonMap(result['input']),
      );
      response = asJsonMap(
        await plugin(source, 'continueFavoriteAction', {
          'comicId': id,
          'action': action,
          'continuationToken': result['continuationToken'],
          'input': input ?? {'cancelled': true},
        }),
      );
    }
    throw StateError('云收藏交互步骤过多');
  }
}
