import 'dart:io';
import 'package:get/get.dart';
import 'package:manji_trace/controllers/remote_controller.dart';
import 'package:manji_trace/dao/journal_note_dao.dart';
import 'package:manji_trace/dao/note_dao.dart';
import 'package:manji_trace/global.dart';
import 'package:manji_trace/models/sync_version_model.dart';
import 'package:manji_trace/utils/backup_util.dart';
import 'package:manji_trace/utils/log.dart';
import 'package:manji_trace/utils/sp_util.dart';
import 'package:manji_trace/utils/sqlite_util.dart';
import 'package:manji_trace/utils/toast_util.dart';
import 'package:manji_trace/utils/webdav_util.dart';
import 'package:path_provider/path_provider.dart';

class SyncService extends GetxController {
  static SyncService get to => Get.find();

  bool isSyncing = false;
  final String syncInfoFileName = "sync_info.json";
  final String dbBackupFileName = "sync_db_backup.db";

  // 是否开启自动同步（启动时检查）
  bool get enableAutoSync => SPUtil.getBool("enable_auto_sync", defaultValue: true);
  set enableAutoSync(bool val) => SPUtil.setBool("enable_auto_sync", val);

  // 记录上次同步成功的时间，用于本地对比
  int get lastLocalSyncTime => SPUtil.getInt("last_local_sync_time", defaultValue: 0);
  set lastLocalSyncTime(int val) => SPUtil.setInt("last_local_sync_time", val);

  /// 启动时检查同步
  Future<void> checkAndSyncOnStart() async {
    if (!enableAutoSync) return;
    
    // 延迟几秒，等待网络和 WebDAV 初始化
    await Future.delayed(const Duration(seconds: 3));
    
    if (RemoteController.to.isOffline) {
      AppLog.info("WebDAV 离线，跳过自动同步检查");
      return;
    }

    await syncData(showToast: false);
  }

  /// 核心同步逻辑
  Future<void> syncData({bool showToast = true}) async {
    if (isSyncing) return;
    isSyncing = true;
    update();

    try {
      String remoteDir = await WebDavUtil.getRemoteDirPath();
      if (remoteDir.isEmpty) return;
      
      String remoteInfoPath = "$remoteDir/$syncInfoFileName";
      String remoteDbPath = "$remoteDir/$dbBackupFileName";

      // 1. 获取远程元数据
      String? jsonStr = await WebDavUtil.readString(remoteInfoPath);
      SyncVersionModel? remoteModel = jsonStr != null ? SyncVersionModel.fromJsonString(jsonStr) : null;

      if (remoteModel == null) {
        AppLog.info("同步：远程无元数据，准备首次上传");
        await uploadLocalData(remoteInfoPath, remoteDbPath);
        if (showToast) ToastUtil.showText("首次同步上传成功");
        return;
      }

      // 2. 对比版本
      AppLog.info("同步：远程更新时间 ${remoteModel.lastUpdateTime}, 本地上次同步时间 $lastLocalSyncTime");
      
      if (remoteModel.lastUpdateTime > lastLocalSyncTime) {
        // 远程更新，拉取
        await downloadRemoteData(remoteDbPath, remoteModel);
        if (showToast) ToastUtil.showText("已自动同步最新数据（来自 ${remoteModel.deviceName}）");
      } else if (remoteModel.lastUpdateTime < lastLocalSyncTime) {
        // 本地更新（可能是手动触发了备份或者在其他设备未同步的情况下进行了操作）
        AppLog.info("同步：本地数据较新，准备上传");
        await uploadLocalData(remoteInfoPath, remoteDbPath);
      } else {
        AppLog.info("同步：数据已是最新");
        if (showToast) ToastUtil.showText("数据已是最新");
      }
    } catch (e) {
      AppLog.error("同步失败: $e");
      if (showToast) ToastUtil.showError("同步失败: $e");
    } finally {
      isSyncing = false;
      update();
    }
  }

  /// 上传本地数据到云端
  Future<void> uploadLocalData(String remoteInfoPath, String remoteDbPath) async {
    // 获取当前数据库路径
    String dbPath = await SqliteUtil.getDBPath();
    
    // 生成元数据
    SyncVersionModel model = SyncVersionModel(
      deviceId: Global.deviceId,
      deviceName: Global.deviceName,
      lastUpdateTime: DateTime.now().millisecondsSinceEpoch,
      fileCount: await _getTotalRecordCount(),
    );

    // 上传数据库文件
    await WebDavUtil.upload(dbPath, remoteDbPath);
    // 上传元数据
    await WebDavUtil.uploadString(model.toJsonString(), remoteInfoPath);
    
    // 更新本地同步记录
    lastLocalSyncTime = model.lastUpdateTime;
  }

  /// 从云端下载并恢复数据
  Future<void> downloadRemoteData(String remoteDbPath, SyncVersionModel remoteModel) async {
    final tempDir = await getTemporaryDirectory();
    final tempDbPath = "${tempDir.path}/temp_sync.db";
    
    // 下载
    await WebDavUtil.client.read2File(remoteDbPath, tempDbPath);
    
    // 简单校验
    if (!await File(tempDbPath).exists()) {
      throw "下载数据库文件失败";
    }

    // 执行还原
    var result = await BackupUtil.restoreFromLocal(tempDbPath, recordBeforeRestore: true, delete: true);
    
    if (result.isSuccess) {
      lastLocalSyncTime = remoteModel.lastUpdateTime;
    } else {
      throw "数据库还原失败: ${result.msg}";
    }
  }

  /// 粗略计算记录总数，用于校验
  Future<int> _getTotalRecordCount() async {
    int animeCount = await SqliteUtil.count(tableName: 'anime');
    int noteCount = await NoteDao.getRateNoteTotal();
    int journalCount = await JournalNoteDao.getNoteCount();
    return animeCount + noteCount + journalCount;
  }
}
