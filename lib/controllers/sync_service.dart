import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:get/get.dart';
import 'package:manji_trace/controllers/remote_controller.dart';
import 'package:manji_trace/dao/journal_note_dao.dart';
import 'package:manji_trace/dao/note_dao.dart';
import 'package:manji_trace/global.dart';
import 'package:manji_trace/models/params/result.dart';
import 'package:manji_trace/models/sync_version_model.dart';
import 'package:manji_trace/utils/backup_util.dart';
import 'package:manji_trace/utils/image_util.dart';
import 'package:manji_trace/utils/log.dart';
import 'package:manji_trace/utils/sp_util.dart';
import 'package:manji_trace/utils/sync_change_log_util.dart';
import 'package:manji_trace/utils/sqlite_util.dart';
import 'package:manji_trace/utils/toast_util.dart';
import 'package:manji_trace/utils/webdav_util.dart';
import 'package:path_provider/path_provider.dart';

class SyncService extends GetxController {
  static SyncService get to => Get.find();

  bool isSyncing = false;
  double syncProgress = 0;
  String syncProgressText = '';
  final String syncInfoFileName = "sync_info.json";
  final String dbPayloadFileName = "sync_db_backup.db";
  final String imageIndexFileName = "sync_images_index.json";
  final String deltaManifestFileName = "sync_delta_manifest.json";
  final String deltaManifestDirName = "sync_delta_chain";
  final int maxDeltaChainFilesKeep = 120;
  final String imageRemoteRootDir = "sync_images";
  Timer? _autoSyncTimer;
  int _lastAutoSyncAttemptMs = 0;
  SyncVersionModel? _pendingRemoteConflict;
  int _pendingLocalDbModifiedTime = 0;

  bool get hasConflict => _pendingRemoteConflict != null;
  SyncVersionModel? get pendingRemoteConflict => _pendingRemoteConflict;
  int get pendingLocalDbModifiedTime => _pendingLocalDbModifiedTime;

  // 是否开启自动同步（启动时检查）
  bool get enableAutoSync =>
      SPUtil.getBool("enable_auto_sync", defaultValue: true);
  set enableAutoSync(bool val) {
    SPUtil.setBool("enable_auto_sync", val);
    if (val) {
      startAutoSyncScheduler();
    } else {
      stopAutoSyncScheduler();
    }
  }

  // 自动同步间隔（分钟）
  int get autoSyncIntervalMinutes =>
      SPUtil.getInt("auto_sync_interval_minutes", defaultValue: 10);

  // 记录上次同步成功的时间，用于本地对比
  int get lastLocalSyncTime =>
      SPUtil.getInt("last_local_sync_time", defaultValue: 0);
  set lastLocalSyncTime(int val) => SPUtil.setInt("last_local_sync_time", val);

  String get lastLocalImageIndexDigest =>
      SPUtil.getString("last_local_image_index_digest");
  set lastLocalImageIndexDigest(String val) =>
      SPUtil.setString("last_local_image_index_digest", val);

  int get lastSyncedChangeLogId =>
      SPUtil.getInt("last_synced_change_log_id", defaultValue: 0);
  set lastSyncedChangeLogId(int val) =>
      SPUtil.setInt("last_synced_change_log_id", val);

  String get lastDeltaFallbackReason =>
      SPUtil.getString("last_delta_fallback_reason");
  set lastDeltaFallbackReason(String val) =>
      SPUtil.setString("last_delta_fallback_reason", val);

  int get lastDeltaFallbackTime =>
      SPUtil.getInt("last_delta_fallback_time", defaultValue: 0);
  set lastDeltaFallbackTime(int val) =>
      SPUtil.setInt("last_delta_fallback_time", val);

  bool get needDeltaChainRebase =>
      SPUtil.getBool("need_delta_chain_rebase", defaultValue: false);
  set needDeltaChainRebase(bool val) =>
      SPUtil.setBool("need_delta_chain_rebase", val);

  /// 启动时检查同步
  Future<void> checkAndSyncOnStart() async {
    if (!enableAutoSync) {
      stopAutoSyncScheduler();
      return;
    }

    startAutoSyncScheduler();

    // 延迟几秒，等待网络和 WebDAV 初始化
    await Future.delayed(const Duration(seconds: 3));

    if (RemoteController.to.isOffline) {
      AppLog.info("WebDAV 离线，跳过自动同步检查");
      return;
    }

    await _triggerAutoSyncIfDue(force: true, reason: 'start');
  }

  Future<void> checkAndSyncOnResume() async {
    if (!enableAutoSync) return;
    await _triggerAutoSyncIfDue(reason: 'resume');
  }

  void startAutoSyncScheduler() {
    _autoSyncTimer?.cancel();
    if (!enableAutoSync) return;

    final int minutes =
        autoSyncIntervalMinutes <= 0 ? 10 : autoSyncIntervalMinutes;
    _autoSyncTimer = Timer.periodic(Duration(minutes: minutes), (_) async {
      await _triggerAutoSyncIfDue(reason: 'timer');
    });
  }

  void stopAutoSyncScheduler() {
    _autoSyncTimer?.cancel();
    _autoSyncTimer = null;
  }

  Future<void> _triggerAutoSyncIfDue({
    bool force = false,
    required String reason,
  }) async {
    if (!enableAutoSync || isSyncing || RemoteController.to.isOffline) {
      return;
    }

    final int now = DateTime.now().millisecondsSinceEpoch;
    const int minGapMs = 90 * 1000; // 防抖：90秒内只触发一次自动同步
    if (!force && now - _lastAutoSyncAttemptMs < minGapMs) {
      return;
    }
    _lastAutoSyncAttemptMs = now;

    AppLog.info("自动同步触发: $reason");
    await syncData(showToast: false);
  }

  /// 手动解决冲突：保留本地并覆盖云端
  Future<void> forceUploadLocalVersion({bool showToast = true}) async {
    await syncData(showToast: showToast, forceUpload: true);
  }

  /// 手动解决冲突：采用云端并覆盖本地
  Future<void> forceDownloadRemoteVersion({bool showToast = true}) async {
    await syncData(showToast: showToast, forceDownload: true);
  }

  /// 手动重建云端增量链：设置重建标记并强制上传一次。
  Future<void> rebuildRemoteDeltaChain({bool showToast = true}) async {
    needDeltaChainRebase = true;
    await syncData(showToast: showToast, forceUpload: true);
  }

  /// 核心同步逻辑
  Future<void> syncData({
    bool showToast = true,
    bool forceUpload = false,
    bool forceDownload = false,
  }) async {
    if (isSyncing) return;
    if (forceUpload && forceDownload) {
      throw "forceUpload 和 forceDownload 不能同时为 true";
    }

    isSyncing = true;
    _setSyncProgress(0.02, '正在准备同步');
    update();

    try {
      final String writeRemoteDir = await WebDavUtil.getRemoteSyncDirPath();
      if (writeRemoteDir.isEmpty) return;
      _setSyncProgress(0.08, '已连接同步目录');

      final String writeRemoteInfoPath = "$writeRemoteDir/$syncInfoFileName";
      final String writeRemotePayloadPath =
          "$writeRemoteDir/$dbPayloadFileName";

      // 1. 读取所有兼容目录中的同步元数据，选取最新版本作为比较基准。
      final remoteSnapshot = await _loadLatestRemoteSnapshot();
      _setSyncProgress(0.18, '正在读取云端快照');
      final SyncVersionModel? remoteModel = remoteSnapshot?.model;
      final String? remotePayloadPath = remoteSnapshot?.payloadPath;
      final String? remotePayloadDir = remoteSnapshot?.remoteDir;

      if (remoteModel == null) {
        AppLog.info("同步：远程无元数据，准备首次上传");
        _setSyncProgress(0.3, '云端无数据，正在首次上传');
        await uploadLocalData(writeRemoteInfoPath, writeRemotePayloadPath);
        _setSyncProgress(1.0, '首次同步完成');
        if (showToast) ToastUtil.showText("首次同步上传成功");
        return;
      }
      // 2. 对比版本
      AppLog.info(
          "同步：远程更新时间 ${remoteModel.lastUpdateTime}, 本地上次同步时间 $lastLocalSyncTime");

      final int localDbModifiedTime = await _getLocalDbModifiedTime();
      final int localRecordCount = await _getTotalRecordCount();
      final int localChangeLogId = await SyncChangeLogUtil.getLatestChangeId();
      final Map<String, Map<String, dynamic>> localImageIndex =
          await _buildLocalImageIndex();
      final String localImageIndexDigest =
          _buildImageIndexDigest(localImageIndex);
      final bool remoteChanged = remoteModel.lastUpdateTime > lastLocalSyncTime;
      final bool localChanged = _hasMeaningfulLocalChange(
        localDbModifiedTime: localDbModifiedTime,
        localRecordCount: localRecordCount,
        localChangeLogId: localChangeLogId,
        localImageIndexDigest: localImageIndexDigest,
      );
      final bool crossDevice = remoteModel.deviceId != Global.deviceId;
      _setSyncProgress(0.32, '正在比较本地与云端变更');

      AppLog.info(
        "同步：remoteChanged=$remoteChanged, localChanged=$localChanged, crossDevice=$crossDevice, localDbModifiedTime=$localDbModifiedTime",
      );

      // 多设备双端都发生变化时，进入冲突状态，避免静默覆盖。
      if (!forceUpload &&
          !forceDownload &&
          remoteChanged &&
          localChanged &&
          crossDevice) {
        _setConflict(remoteModel, localDbModifiedTime);
        _setSyncProgress(1.0, '检测到冲突，等待手动处理');
        AppLog.warn("同步冲突：检测到本地与远程都发生了更新，已暂停自动覆盖");
        if (showToast) {
          ToastUtil.showText("检测到多设备同步冲突，请在同步卡片中手动选择处理方式");
        }
        return;
      }

      if (forceDownload || (remoteChanged && !localChanged)) {
        _setSyncProgress(0.45, '检测到云端更新，正在下载');
        if (remotePayloadPath == null || remotePayloadPath.isEmpty) {
          throw "远程同步文件路径不存在";
        }
        await downloadRemoteData(
          remotePayloadPath,
          remotePayloadDir ?? writeRemoteDir,
          remoteModel,
          showDeltaFallbackToast: showToast,
        );
        if (showToast) {
          ToastUtil.showText("已同步云端最新数据（来自 ${remoteModel.deviceName}）");
        }
        _setSyncProgress(1.0, '同步完成');
      } else if (forceUpload || (!remoteChanged && localChanged)) {
        AppLog.info("同步：本地数据较新，准备上传");
        _setSyncProgress(0.45, '检测到本地更新，正在上传');
        await uploadLocalData(
          writeRemoteInfoPath,
          writeRemotePayloadPath,
          remoteModel: remoteModel,
          localImageIndex: localImageIndex,
          localImageIndexDigest: localImageIndexDigest,
        );
        if (showToast) ToastUtil.showText("已上传本地最新数据到云端");
        _setSyncProgress(1.0, '同步完成');
      } else if (remoteChanged && localChanged) {
        // 同设备冲突或强制分支外场景：比较时间戳，较新方覆盖。
        if (remoteModel.lastUpdateTime >= localDbModifiedTime) {
          if (remotePayloadPath == null || remotePayloadPath.isEmpty) {
            throw "远程同步文件路径不存在";
          }
          await downloadRemoteData(
            remotePayloadPath,
            remotePayloadDir ?? writeRemoteDir,
            remoteModel,
            showDeltaFallbackToast: showToast,
          );
          if (showToast) {
            ToastUtil.showText("已同步云端最新数据（来自 ${remoteModel.deviceName}）");
          }
          _setSyncProgress(1.0, '同步完成');
        } else {
          _setSyncProgress(0.45, '双端变更，正在以上传为准同步');
          await uploadLocalData(
            writeRemoteInfoPath,
            writeRemotePayloadPath,
            remoteModel: remoteModel,
            localImageIndex: localImageIndex,
            localImageIndexDigest: localImageIndexDigest,
          );
          if (showToast) ToastUtil.showText("已上传本地最新数据到云端");
          _setSyncProgress(1.0, '同步完成');
        }
      } else {
        AppLog.info("同步：数据已是最新");
        _setSyncProgress(1.0, '数据已是最新');
        if (showToast) ToastUtil.showText("数据已是最新");
      }
    } catch (e) {
      AppLog.error("同步失败: $e");
      _setSyncProgress(syncProgress <= 0 ? 0 : syncProgress, '同步失败: $e');
      if (showToast) ToastUtil.showError("同步失败: $e");
    } finally {
      isSyncing = false;
      update();
    }
  }

  void _setSyncProgress(double progress, String text) {
    syncProgress = progress.clamp(0, 1).toDouble();
    syncProgressText = text;
    update();
  }

  /// 上传本地数据到云端
  Future<void> uploadLocalData(
    String remoteInfoPath,
    String remotePayloadPath, {
    SyncVersionModel? remoteModel,
    Map<String, Map<String, dynamic>>? localImageIndex,
    String? localImageIndexDigest,
  }) async {
    _setSyncProgress(0.52, '正在整理本地变更');
    final String dbPath = await SqliteUtil.getDBPath();
    final File dbFile = File(dbPath);
    final String payloadDigest = await _buildPayloadDigest(dbFile);
    final String remoteDir = _dirname(remotePayloadPath);
    final String deltaManifestPath = "$remoteDir/$deltaManifestFileName";
    final String deltaChainDir = "$remoteDir/$deltaManifestDirName";
    final Map<String, Map<String, dynamic>> imageIndex =
        localImageIndex ?? await _buildLocalImageIndex();
    final String imageDigest =
        localImageIndexDigest ?? _buildImageIndexDigest(imageIndex);
    final int deltaFromId = lastSyncedChangeLogId;
    final int deltaToId = await SyncChangeLogUtil.getLatestChangeId();
    final int deltaCount =
        deltaToId > deltaFromId ? deltaToId - deltaFromId : 0;
    final Map<String, dynamic> deltaManifest =
        await SyncChangeLogUtil.buildDeltaManifest(
      fromId: deltaFromId,
      toId: deltaToId,
      maxRows: 5000,
    );
    final String deltaChainFilePath =
        "$deltaChainDir/${_buildDeltaFileName(deltaFromId, deltaToId)}";

    // 生成元数据
    SyncVersionModel model = SyncVersionModel(
      deviceId: Global.deviceId,
      deviceName: Global.deviceName,
      lastUpdateTime: DateTime.now().millisecondsSinceEpoch,
      fileCount: await _getTotalRecordCount(),
      payloadType: 'db',
      payloadFileName: dbPayloadFileName,
      payloadDigest: payloadDigest,
      imageIndexDigest: imageDigest,
      deltaFromId: deltaFromId,
      deltaToId: deltaToId,
      deltaCount: deltaCount,
    );

    final bool needUploadDb = remoteModel == null ||
        remoteModel.payloadDigest != payloadDigest ||
        remoteModel.payloadFileName != dbPayloadFileName;
    if (needUploadDb) {
      _setSyncProgress(0.62, '正在上传数据库');
      await _withRetry(
        () => WebDavUtil.upload(dbPath, remotePayloadPath),
        actionName: '上传数据库文件',
      );
    }

    final bool needSyncImages =
        remoteModel == null || remoteModel.imageIndexDigest != imageDigest;
    if (needSyncImages) {
      _setSyncProgress(0.72, '正在同步图片资源');
      await _syncImagesToRemoteFast(remoteDir, localIndex: imageIndex);
    }

    _setSyncProgress(0.82, '正在上传增量清单');
    await _withRetry(
      () =>
          WebDavUtil.uploadString(jsonEncode(deltaManifest), deltaManifestPath),
      actionName: '上传增量清单',
    );

    await _withRetry(
      () => WebDavUtil.client.mkdir(deltaChainDir),
      actionName: '创建增量链目录',
    );

    if (needDeltaChainRebase) {
      await _purgeRemoteDeltaChain(deltaChainDir);
      AppLog.warn('检测到增量链异常，已清理远端增量链并准备重建');
    }

    await _withRetry(
      () => WebDavUtil.uploadString(
          jsonEncode(deltaManifest), deltaChainFilePath),
      actionName: '上传增量链分片',
    );
    await _cleanupRemoteDeltaChain(deltaChainDir);

    // 上传元数据（最后上传，避免出现元数据已更新但文件未完成）
    await _withRetry(
      () => WebDavUtil.uploadString(model.toJsonString(), remoteInfoPath),
      actionName: '上传同步元数据',
    );
    _setSyncProgress(0.95, '正在保存同步状态');

    // 更新本地同步记录
    lastLocalSyncTime = model.lastUpdateTime;
    lastLocalImageIndexDigest = imageDigest;
    lastSyncedChangeLogId = deltaToId;
    needDeltaChainRebase = false;
    _clearConflict();
  }

  /// 从云端下载并恢复数据
  Future<void> downloadRemoteData(
    String remotePayloadPath,
    String remoteDir,
    SyncVersionModel remoteModel, {
    bool showDeltaFallbackToast = false,
  }) async {
    _setSyncProgress(0.55, '正在下载云端数据');
    final tempDir = await getTemporaryDirectory();
    final String deltaManifestPath = "$remoteDir/$deltaManifestFileName";
    final bool isZipPayload = remotePayloadPath.toLowerCase().endsWith('.zip');
    final String tempPayloadPath = isZipPayload
        ? "${tempDir.path}/temp_sync_payload.zip"
        : "${tempDir.path}/temp_sync.db";

    // 下载
    await _withRetry(
      () => WebDavUtil.client.read2File(remotePayloadPath, tempPayloadPath),
      actionName: '下载同步文件',
    );
    _setSyncProgress(0.7, '正在校验同步文件');

    // 简单校验
    final payloadFile = File(tempPayloadPath);
    if (!isZipPayload && !await payloadFile.exists()) {
      throw "下载同步文件失败";
    }
    if (!isZipPayload && remoteModel.payloadDigest.isNotEmpty) {
      final String localDigest = await _buildPayloadDigest(payloadFile);
      if (localDigest != remoteModel.payloadDigest) {
        throw "同步文件校验失败，请重试";
      }
    }

    Result? result;
    if (isZipPayload) {
      // 兼容旧版 zip 同步包。
      _setSyncProgress(0.78, '正在恢复旧版同步包');
      result = await BackupUtil.restoreFromLocal(
        tempPayloadPath,
        recordBeforeRestore: true,
        delete: true,
      );
    } else {
      final String localDbPath = await SqliteUtil.getDBPath();
      final localDbFile = File(localDbPath);
      final bool canTryDelta = remoteModel.deltaCount > 0 &&
          remoteModel.deltaFromId > 0 &&
          lastSyncedChangeLogId <= remoteModel.deltaFromId;
      final bool deltaCursorTooOld =
          canTryDelta && lastSyncedChangeLogId < remoteModel.deltaFromId;
      String? deltaFallbackReason;

      if (canTryDelta) {
        result = Result.failure(500, 'delta-not-run');
        if (deltaCursorTooOld) {
          deltaFallbackReason =
              'delta-cursor-too-old(local:$lastSyncedChangeLogId, remoteFrom:${remoteModel.deltaFromId})';
          result = Result.failure(409, deltaFallbackReason);
        } else {
          final chainLoad = await _loadDeltaManifestChain(
            remoteDir: remoteDir,
            fromId: lastSyncedChangeLogId,
            toId: remoteModel.deltaToId,
            fallbackManifestPath: deltaManifestPath,
          );
          final chain = chainLoad.manifests;
          if (chainLoad.usedFallback) {
            AppLog.warn('增量链目录不可用，改用单清单回放: ${chainLoad.reason}');
          }

          if (chain.isNotEmpty) {
            try {
              int appliedTotal = 0;
              bool deltaOk = true;
              for (final manifest in chain) {
                final deltaApply =
                    await SyncChangeLogUtil.applyDeltaManifest(manifest);
                if (deltaApply['ok'] == true) {
                  appliedTotal += (deltaApply['appliedCount'] as int?) ?? 0;
                } else {
                  deltaOk = false;
                  break;
                }
              }

              if (deltaOk &&
                  remoteModel.payloadDigest.isNotEmpty &&
                  await localDbFile.exists()) {
                final String curDigest = await _buildPayloadDigest(localDbFile);
                if (curDigest == remoteModel.payloadDigest) {
                  result = Result.success(
                    true,
                    msg: '已通过增量链快速同步数据库($appliedTotal条变更)',
                  );
                } else {
                  deltaFallbackReason = 'delta-digest-mismatch';
                  AppLog.warn('增量应用后摘要不一致，回退全量恢复');
                  result = Result.failure(500, 'delta-digest-mismatch');
                }
              } else if (deltaOk) {
                result = Result.success(
                  true,
                  msg: '已通过增量链同步数据库($appliedTotal条变更)',
                );
              } else {
                deltaFallbackReason = 'delta-apply-failed';
                result = Result.failure(500, 'delta-apply-failed');
              }
            } catch (e) {
              deltaFallbackReason = 'delta-parse-failed';
              AppLog.warn('解析或应用增量清单失败，回退全量恢复: $e');
              result = Result.failure(500, 'delta-parse-failed');
            }
          } else {
            deltaFallbackReason = chainLoad.reason;
            result = Result.failure(404, deltaFallbackReason);
          }
        }

        if (result.isSuccess) {
          _setSyncProgress(0.9, '增量应用成功，正在同步图片');
          _clearDeltaFallbackStatus();
          await _syncMissingImagesFromRemote(remoteDir);
          lastLocalSyncTime = remoteModel.lastUpdateTime;
          if (remoteModel.imageIndexDigest.isNotEmpty) {
            lastLocalImageIndexDigest = remoteModel.imageIndexDigest;
          }
          if (remoteModel.deltaToId > 0) {
            lastSyncedChangeLogId = remoteModel.deltaToId;
          }
          _clearConflict();
          return;
        }
      }

      if (canTryDelta) {
        if (!result!.isSuccess) {
          final String reason = deltaFallbackReason ?? result.msg;
          lastDeltaFallbackReason = reason;
          lastDeltaFallbackTime = DateTime.now().millisecondsSinceEpoch;
          if (_shouldMarkDeltaChainRebase(reason)) {
            needDeltaChainRebase = true;
          }
          AppLog.warn('增量同步不可用，自动回退全量同步，原因: $reason');
          if (showDeltaFallbackToast) {
            ToastUtil.showText('增量同步不可用，已自动回退全量同步');
          }
        }
      }

      final bool canSkipDbRestore = await localDbFile.exists() &&
          remoteModel.payloadDigest.isNotEmpty &&
          (await _buildPayloadDigest(localDbFile)) == remoteModel.payloadDigest;

      if (canSkipDbRestore) {
        result = Result.success(true, msg: "本地数据库已是最新");
      } else {
        _setSyncProgress(0.85, '正在恢复数据库');
        result = await BackupUtil.restoreFromLocal(
          tempPayloadPath,
          recordBeforeRestore: true,
          delete: true,
        );
      }
    }

    if (result.isSuccess) {
      // DB 恢复成功后，仅补齐缺失图片，避免全量重传/覆盖。
      _setSyncProgress(0.93, '正在补齐图片资源');
      await _syncMissingImagesFromRemote(remoteDir);
      lastLocalSyncTime = remoteModel.lastUpdateTime;
      if (remoteModel.imageIndexDigest.isNotEmpty) {
        lastLocalImageIndexDigest = remoteModel.imageIndexDigest;
      }
      if (remoteModel.deltaToId > 0) {
        lastSyncedChangeLogId = remoteModel.deltaToId;
      }
      _clearConflict();
    } else {
      throw "数据库还原失败: ${result.msg}";
    }
  }

  bool _hasMeaningfulLocalChange({
    required int localDbModifiedTime,
    required int localRecordCount,
    required int localChangeLogId,
    required String localImageIndexDigest,
  }) {
    final bool localDbChanged = localChangeLogId > lastSyncedChangeLogId;
    final bool localImageChanged =
        localImageIndexDigest != lastLocalImageIndexDigest;
    // 首次启动且本地无数据时，不将初始化数据库时间视作“本地有改动”。
    if (lastLocalSyncTime == 0 &&
        localRecordCount == 0 &&
        localImageIndexDigest.isEmpty) {
      return false;
    }
    return localDbChanged || localImageChanged;
  }

  Future<int> _getLocalDbModifiedTime() async {
    final String dbPath = await SqliteUtil.getDBPath();
    final dbFile = File(dbPath);
    if (!await dbFile.exists()) {
      return 0;
    }
    return (await dbFile.stat()).modified.millisecondsSinceEpoch;
  }

  void _setConflict(SyncVersionModel remoteModel, int localDbModifiedTime) {
    _pendingRemoteConflict = remoteModel;
    _pendingLocalDbModifiedTime = localDbModifiedTime;
    update();
  }

  void _clearConflict() {
    _pendingRemoteConflict = null;
    _pendingLocalDbModifiedTime = 0;
  }

  void _clearDeltaFallbackStatus() {
    lastDeltaFallbackReason = '';
    lastDeltaFallbackTime = 0;
  }

  Future<_RemoteSyncSnapshot?> _loadLatestRemoteSnapshot() async {
    final List<String> remoteDirs =
        await WebDavUtil.getRemoteSyncDirPathsForRead();
    _RemoteSyncSnapshot? latest;

    for (final remoteDir in remoteDirs) {
      final String infoPath = "$remoteDir/$syncInfoFileName";
      final String? jsonStr = await WebDavUtil.readString(infoPath);
      if (jsonStr == null) {
        continue;
      }
      final SyncVersionModel? model = SyncVersionModel.fromJsonString(jsonStr);
      if (model == null) {
        continue;
      }

      final String payloadFileName = model.payloadFileName.trim().isEmpty
          ? dbPayloadFileName
          : model.payloadFileName.trim();
      final String payloadPath = "$remoteDir/$payloadFileName";

      if (latest == null ||
          model.lastUpdateTime > latest.model.lastUpdateTime) {
        latest = _RemoteSyncSnapshot(
          model: model,
          payloadPath: payloadPath,
          remoteDir: remoteDir,
        );
      }
    }
    return latest;
  }

  Future<void> _syncImagesToRemoteFast(
    String remoteDir, {
    Map<String, Map<String, dynamic>>? localIndex,
  }) async {
    final Map<String, Map<String, dynamic>> localIndexData =
        localIndex ?? await _buildLocalImageIndex();
    final Map<String, Map<String, dynamic>> remoteIndex =
        await _readRemoteImageIndex(remoteDir);

    final String remoteImageBaseDir = "$remoteDir/$imageRemoteRootDir";
    await WebDavUtil.client.mkdir(remoteImageBaseDir);

    for (final entry in localIndexData.entries) {
      final String key = entry.key;
      final Map<String, dynamic> localMeta = entry.value;
      final Map<String, dynamic>? remoteMeta = remoteIndex[key];

      final bool needUpload = remoteMeta == null ||
          !_imageMetaMatches(localMeta, remoteMeta);
      if (!needUpload) {
        continue;
      }

      final String localPath = localMeta['localPath'];
      final String remotePath = "$remoteImageBaseDir/$key";
      await _ensureRemoteParentDir(remotePath);
      await _withRetry(
        () => WebDavUtil.upload(localPath, remotePath),
        actionName: '上传图片文件',
      );
    }

    await _removeRemoteImageGarbage(
      remoteDir: remoteDir,
      localIndex: localIndexData,
      remoteIndex: remoteIndex,
    );

    await _writeRemoteImageIndex(remoteDir, localIndexData);
  }

  Future<void> _removeRemoteImageGarbage({
    required String remoteDir,
    required Map<String, Map<String, dynamic>> localIndex,
    required Map<String, Map<String, dynamic>> remoteIndex,
  }) async {
    if (remoteIndex.isEmpty) {
      return;
    }

    final String remoteImageBaseDir = "$remoteDir/$imageRemoteRootDir";
    for (final String key in remoteIndex.keys) {
      if (localIndex.containsKey(key)) {
        continue;
      }

      final String remotePath = "$remoteImageBaseDir/$key";
      try {
        await _withRetry(
          () => WebDavUtil.client.remove(remotePath),
          actionName: '删除远端旧图片',
        );
      } catch (e) {
        // 文件可能已不存在，记录日志后继续。
        AppLog.warn("删除远端旧图片失败($remotePath): $e");
      }
    }
  }

  Future<void> _syncMissingImagesFromRemote(String remoteDir) async {
    final Map<String, Map<String, dynamic>> remoteIndex =
        await _readRemoteImageIndex(remoteDir);
    if (remoteIndex.isEmpty) {
      return;
    }

    final String remoteImageBaseDir = "$remoteDir/$imageRemoteRootDir";
    for (final entry in remoteIndex.entries) {
      final String key = entry.key;
      final String? localPath = _keyToLocalImagePath(key);
      if (localPath == null) {
        continue;
      }

      final localFile = File(localPath);
      if (await localFile.exists()) {
        final String remoteDigest = entry.value['digest']?.toString() ?? '';
        if (remoteDigest.isNotEmpty) {
          final String localDigest = await _hashFile(localFile);
          if (localDigest == remoteDigest) {
            continue;
          }
        } else {
          final localStat = await localFile.stat();
          final int remoteSize = (entry.value['size'] as num?)?.toInt() ?? -1;
          final int remoteMtime = (entry.value['mtime'] as num?)?.toInt() ?? -1;
          final bool sameSize = remoteSize >= 0 && localStat.size == remoteSize;
          final bool sameMtime = remoteMtime >= 0 &&
              localStat.modified.millisecondsSinceEpoch == remoteMtime;
          if (sameSize && sameMtime) {
            continue;
          }
        }
      }

      await localFile.parent.create(recursive: true);
      await _withRetry(
        () =>
            WebDavUtil.client.read2File("$remoteImageBaseDir/$key", localPath),
        actionName: '下载图片文件',
      );
    }
  }

  Future<Map<String, Map<String, dynamic>>> _buildLocalImageIndex() async {
    final Map<String, Map<String, dynamic>> index = {};
    await _collectImageIndex(
      rootDir: ImageUtil.getNoteImageRootDirPath(),
      prefix: 'note',
      index: index,
    );
    await _collectImageIndex(
      rootDir: ImageUtil.getJournalImageRootDirPath(),
      prefix: 'journal',
      index: index,
    );
    await _collectImageIndex(
      rootDir: ImageUtil.getCoverImageRootDirPath(),
      prefix: 'cover',
      index: index,
    );
    return index;
  }

  Future<void> _collectImageIndex({
    required String rootDir,
    required String prefix,
    required Map<String, Map<String, dynamic>> index,
  }) async {
    final dir = Directory(rootDir);
    if (!await dir.exists()) {
      return;
    }

    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) {
        continue;
      }
      final stat = await entity.stat();
      String relative = entity.path.substring(rootDir.length);
      relative = relative.replaceAll('\\', '/');
      if (relative.startsWith('/')) {
        relative = relative.substring(1);
      }
      final String key = '$prefix/$relative';
      index[key] = {
        'size': stat.size,
        'mtime': stat.modified.millisecondsSinceEpoch,
        'digest': await _hashFile(entity),
        'localPath': entity.path,
      };
    }
  }

  String _buildImageIndexDigest(Map<String, Map<String, dynamic>> index) {
    if (index.isEmpty) return '';
    final keys = index.keys.toList()..sort();
    final StringBuffer sb = StringBuffer();
    for (final key in keys) {
      final item = index[key] ?? const <String, dynamic>{};
      sb.write(key);
      sb.write('|');
      sb.write(item['digest'] ?? '');
      sb.write(';');
    }
    return sha256.convert(utf8.encode(sb.toString())).toString();
  }

  Future<Map<String, Map<String, dynamic>>> _readRemoteImageIndex(
      String remoteDir) async {
    final String indexPath = "$remoteDir/$imageIndexFileName";
    final String? jsonStr = await _withRetry(
      () => WebDavUtil.readString(indexPath),
      actionName: '读取远程图片索引',
    );
    if (jsonStr == null || jsonStr.isEmpty) {
      return {};
    }
    try {
      final decoded = jsonDecode(jsonStr);
      if (decoded is! Map<String, dynamic>) {
        return {};
      }
      final Map<String, Map<String, dynamic>> result = {};
      for (final e in decoded.entries) {
        if (e.value is Map<String, dynamic>) {
          result[e.key] = Map<String, dynamic>.from(e.value);
        }
      }
      return result;
    } catch (_) {
      return {};
    }
  }

  Future<void> _writeRemoteImageIndex(
      String remoteDir, Map<String, Map<String, dynamic>> index) async {
    final String indexPath = "$remoteDir/$imageIndexFileName";
    final sanitized = <String, Map<String, dynamic>>{};
    for (final entry in index.entries) {
      sanitized[entry.key] = {
        'size': entry.value['size'] ?? 0,
        'mtime': entry.value['mtime'] ?? 0,
        'digest': entry.value['digest'] ?? '',
      };
    }
    await _withRetry(
      () => WebDavUtil.uploadString(jsonEncode(sanitized), indexPath),
      actionName: '上传远程图片索引',
    );
  }

  String? _keyToLocalImagePath(String key) {
    if (key.startsWith('note/')) {
      final rel = key.substring('note/'.length);
      return "${ImageUtil.getNoteImageRootDirPath()}$rel";
    }
    if (key.startsWith('journal/')) {
      final rel = key.substring('journal/'.length);
      return "${ImageUtil.getJournalImageRootDirPath()}$rel";
    }
    if (key.startsWith('cover/')) {
      final rel = key.substring('cover/'.length);
      return "${ImageUtil.getCoverImageRootDirPath()}$rel";
    }
    return null;
  }

  Future<void> _ensureRemoteParentDir(String remotePath) async {
    final String parent = _dirname(remotePath);
    if (parent.isEmpty || parent == '/') {
      return;
    }

    final List<String> parts =
        parent.split('/').where((e) => e.isNotEmpty).toList();
    String current = '';
    for (final part in parts) {
      current += '/$part';
      try {
        await WebDavUtil.client.mkdir(current);
      } catch (_) {
        // 目录已存在时忽略
      }
    }
  }

  Future<String> _hashFile(File file) async {
    final List<int> bytes = await file.readAsBytes();
    return sha256.convert(Uint8List.fromList(bytes)).toString();
  }

  bool _imageMetaMatches(
    Map<String, dynamic> localMeta,
    Map<String, dynamic> remoteMeta,
  ) {
    final String localDigest = localMeta['digest']?.toString() ?? '';
    final String remoteDigest = remoteMeta['digest']?.toString() ?? '';
    if (localDigest.isNotEmpty && remoteDigest.isNotEmpty) {
      return localDigest == remoteDigest;
    }

    final int localSize = (localMeta['size'] as num?)?.toInt() ?? -1;
    final int remoteSize = (remoteMeta['size'] as num?)?.toInt() ?? -1;
    final int localMtime = (localMeta['mtime'] as num?)?.toInt() ?? -1;
    final int remoteMtime = (remoteMeta['mtime'] as num?)?.toInt() ?? -1;
    return localSize >= 0 &&
        remoteSize >= 0 &&
        localSize == remoteSize &&
        localMtime >= 0 &&
        remoteMtime >= 0 &&
        localMtime == remoteMtime;
  }

  String _dirname(String fullPath) {
    final int idx = fullPath.lastIndexOf('/');
    if (idx <= 0) {
      return '/';
    }
    return fullPath.substring(0, idx);
  }

  String _buildDeltaFileName(int fromId, int toId) {
    return "delta_${fromId}_$toId.json";
  }

  Future<_DeltaChainLoadResult> _loadDeltaManifestChain({
    required String remoteDir,
    required int fromId,
    required int toId,
    required String fallbackManifestPath,
  }) async {
    if (toId <= fromId) {
      return const _DeltaChainLoadResult(
        manifests: [],
        reason: 'delta-range-invalid',
      );
    }

    final String chainDir = "$remoteDir/$deltaManifestDirName";
    List<dynamic> chainFiles = [];
    try {
      chainFiles = await _withRetry(
        () => WebDavUtil.client.readDir(chainDir),
        actionName: '读取增量链目录',
      );
    } catch (_) {
      chainFiles = [];
    }

    final List<_DeltaFileRef> refs = [];
    for (final f in chainFiles) {
      final String path = (f.path ?? '').toString();
      final String name = path.split('/').last;
      final parsed = _parseDeltaFileName(name);
      if (parsed != null) {
        refs.add(parsed.copyWith(path: path));
      }
    }

    refs.sort((a, b) => a.fromId.compareTo(b.fromId));

    int cursor = fromId;
    final List<Map<String, dynamic>> chain = [];
    while (cursor < toId) {
      final next = refs.where((r) => r.fromId == cursor).toList();
      if (next.isEmpty) {
        chain.clear();
        break;
      }
      final _DeltaFileRef ref = next.first;
      final String? jsonStr = await _withRetry(
        () => WebDavUtil.readString(ref.path),
        actionName: '读取增量链分片',
      );
      if (jsonStr == null || jsonStr.isEmpty) {
        chain.clear();
        break;
      }
      try {
        chain.add(Map<String, dynamic>.from(jsonDecode(jsonStr)));
      } catch (_) {
        chain.clear();
        break;
      }
      cursor = ref.toId;
    }

    if (chain.isNotEmpty && cursor >= toId) {
      return _DeltaChainLoadResult(manifests: chain, reason: 'ok');
    }

    final String chainReason = cursor < toId
        ? 'delta-chain-gap-at-$cursor'
        : 'delta-chain-unavailable';
    final String? fallbackJson = await _withRetry(
      () => WebDavUtil.readString(fallbackManifestPath),
      actionName: '读取增量清单',
    );
    if (fallbackJson == null || fallbackJson.isEmpty) {
      return _DeltaChainLoadResult(
        manifests: const [],
        reason: '$chainReason|fallback-empty',
      );
    }
    try {
      final m = Map<String, dynamic>.from(jsonDecode(fallbackJson));
      final int f = (m['fromId'] as num?)?.toInt() ?? -1;
      final int t = (m['toId'] as num?)?.toInt() ?? -1;
      if (f == fromId && t == toId) {
        return _DeltaChainLoadResult(
          manifests: [m],
          reason: '$chainReason|fallback-manifest',
          usedFallback: true,
        );
      }
    } catch (_) {
      return _DeltaChainLoadResult(
        manifests: const [],
        reason: '$chainReason|fallback-json-invalid',
      );
    }
    return _DeltaChainLoadResult(
      manifests: const [],
      reason: '$chainReason|fallback-range-mismatch',
    );
  }

  Future<void> _cleanupRemoteDeltaChain(String chainDir) async {
    List<dynamic> files = [];
    try {
      files = await _withRetry(
        () => WebDavUtil.client.readDir(chainDir),
        actionName: '读取增量链目录(清理)',
      );
    } catch (_) {
      return;
    }

    final List<_DeltaFileRef> refs = [];
    for (final f in files) {
      final String path = (f.path ?? '').toString();
      final bool isDir = (f.isDir as bool?) ?? path.endsWith('/');
      if (path.isEmpty || isDir) {
        continue;
      }
      final String name = path.split('/').last;
      final parsed = _parseDeltaFileName(name);
      if (parsed != null) {
        refs.add(parsed.copyWith(path: path));
      }
    }

    if (refs.length <= maxDeltaChainFilesKeep) {
      return;
    }

    refs.sort((a, b) => b.toId.compareTo(a.toId));
    final List<_DeltaFileRef> staleRefs = refs.sublist(maxDeltaChainFilesKeep);
    for (final ref in staleRefs) {
      try {
        await _withRetry(
          () => WebDavUtil.client.remove(ref.path),
          actionName: '清理旧增量分片',
        );
      } catch (e) {
        AppLog.warn('清理旧增量分片失败(${ref.path}): $e');
      }
    }
  }

  static bool shouldMarkDeltaChainRebaseReason(String reason) {
    return reason.contains('delta-chain-gap-at-') ||
        reason.contains('fallback-json-invalid') ||
        reason.contains('fallback-range-mismatch');
  }

  bool _shouldMarkDeltaChainRebase(String reason) {
    return shouldMarkDeltaChainRebaseReason(reason);
  }

  Future<void> _purgeRemoteDeltaChain(String chainDir) async {
    List<dynamic> files = [];
    try {
      files = await _withRetry(
        () => WebDavUtil.client.readDir(chainDir),
        actionName: '读取增量链目录(重建)',
      );
    } catch (_) {
      return;
    }

    for (final f in files) {
      final String path = (f.path ?? '').toString();
      final bool isDir = (f.isDir as bool?) ?? path.endsWith('/');
      if (path.isEmpty || isDir) {
        continue;
      }
      final String name = path.split('/').last;
      if (_parseDeltaFileName(name) == null) {
        continue;
      }
      try {
        await _withRetry(
          () => WebDavUtil.client.remove(path),
          actionName: '清空增量链分片',
        );
      } catch (e) {
        AppLog.warn('清空增量链分片失败($path): $e');
      }
    }
  }

  _DeltaFileRef? _parseDeltaFileName(String name) {
    final RegExp reg = RegExp(r'^delta_(\d+)_(\d+)\.json$');
    final m = reg.firstMatch(name);
    if (m == null) return null;
    final fromId = int.tryParse(m.group(1) ?? '');
    final toId = int.tryParse(m.group(2) ?? '');
    if (fromId == null || toId == null) return null;
    return _DeltaFileRef(fromId: fromId, toId: toId, path: '');
  }

  Future<String> _buildPayloadDigest(File file) async {
    final List<int> bytes = await file.readAsBytes();
    return sha256.convert(Uint8List.fromList(bytes)).toString();
  }

  Future<T> _withRetry<T>(
    Future<T> Function() task, {
    required String actionName,
    int maxAttempts = 3,
  }) async {
    Object? lastError;
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        return await task();
      } catch (e) {
        lastError = e;
        if (attempt < maxAttempts) {
          await Future.delayed(Duration(milliseconds: 400 * attempt));
        }
      }
    }
    throw "$actionName 失败: $lastError";
  }

  /// 粗略计算记录总数，用于校验
  Future<int> _getTotalRecordCount() async {
    int animeCount = await SqliteUtil.count(
      tableName: 'anime',
      columnName: '*',
    );
    int noteCount = await NoteDao.getRateNoteTotal();
    int journalCount = await JournalNoteDao.getNoteCount();
    return animeCount + noteCount + journalCount;
  }

  @override
  void onClose() {
    stopAutoSyncScheduler();
    super.onClose();
  }
}

class _RemoteSyncSnapshot {
  final SyncVersionModel model;
  final String payloadPath;
  final String remoteDir;

  const _RemoteSyncSnapshot({
    required this.model,
    required this.payloadPath,
    required this.remoteDir,
  });
}

class _DeltaChainLoadResult {
  final List<Map<String, dynamic>> manifests;
  final String reason;
  final bool usedFallback;

  const _DeltaChainLoadResult({
    required this.manifests,
    required this.reason,
    this.usedFallback = false,
  });
}

class _DeltaFileRef {
  final int fromId;
  final int toId;
  final String path;

  const _DeltaFileRef({
    required this.fromId,
    required this.toId,
    required this.path,
  });

  _DeltaFileRef copyWith({String? path}) {
    return _DeltaFileRef(
      fromId: fromId,
      toId: toId,
      path: path ?? this.path,
    );
  }
}
