import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:animetrace/controllers/labels_controller.dart';
import 'package:animetrace/controllers/remote_controller.dart';
import 'package:animetrace/controllers/update_record_controller.dart';
import 'package:animetrace/dao/history_dao.dart';
import 'package:animetrace/dao/label_dao.dart';
import 'package:animetrace/models/params/result.dart';
import 'package:animetrace/models/sync_version_model.dart';
import 'package:animetrace/pages/anime_collection/checklist_controller.dart';
import 'package:animetrace/pages/network/sources/pages/dedup/dedup_controller.dart';
import 'package:animetrace/utils/sp_util.dart';
import 'package:animetrace/utils/sqlite_util.dart';
import 'package:animetrace/utils/sqlite_sync_util.dart';
import 'package:animetrace/utils/webdav_util.dart';
import 'package:animetrace/utils/image_util.dart';
import 'package:animetrace/values/values.dart';
import 'package:get/get.dart';
import 'package:animetrace/utils/toast_util.dart';
import 'package:path_provider/path_provider.dart';
import 'package:animetrace/utils/log.dart';
import 'package:webdav_client/webdav_client.dart' as dav_client;

class BackupUtil {
  static String backupZipNamePrefix = "backup";
  static String descFileName = "desc";
  static int rbrMaxCnt = 20;

  /// 备份时，用于生成文件名
  static Future<String> generateZipName() async {
    // 2020-02-22 01:01:01.182096取到秒
    String time = DateTime.now().toString().split(".")[0];
    // :和空格转为-，文件名不能包含英文冒号，否则会提示文件名、目录名或卷标语法不正确
    time = time.replaceAll(":", "-");
    time = time.replaceAll(" ", "-");

    String zipName =
        "$backupZipNamePrefix-$time-${Platform.operatingSystem}.zip";
    return zipName;
  }

  /// 创建临时备份文件（包含数据库、图片和描述信息）
  static Future<File> createTempBackUpFile(String zipName) async {
    var encoder = ZipFileEncoder();
    String dirPath = (await getTemporaryDirectory()).path;

    String tempZipFilePath = "$dirPath/$zipName";
    encoder.create(tempZipFilePath);
    
    // 1. 添加数据库文件
    encoder.addFile(File(SqliteUtil.dbPath));
    AppLog.info("✓ 备份数据库文件");
    
    // 2. 添加笔记图片文件夹
    String noteImageDir = ImageUtil.getNoteImageRootDirPath();
    int noteImageCount = 0;
    if (Directory(noteImageDir).existsSync()) {
      final files = Directory(noteImageDir).listSync(recursive: true).whereType<File>();
      noteImageCount = files.length;
      _addDirectoryToZip(encoder, noteImageDir, "images/note_images/");
      AppLog.info("✓ 备份笔记图片 ($noteImageCount 个文件)");
    }
    
    // 3. 添加封面图片文件夹
    String coverImageDir = ImageUtil.getCoverImageRootDirPath();
    int coverImageCount = 0;
    if (Directory(coverImageDir).existsSync()) {
      final files = Directory(coverImageDir).listSync(recursive: true).whereType<File>();
      coverImageCount = files.length;
      _addDirectoryToZip(encoder, coverImageDir, "images/cover_images/");
      AppLog.info("✓ 备份封面图片 ($coverImageCount 个文件)");
    }
    
    // 4. 添加描述信息
    File descFile = File("$dirPath/desc");
    String desc = "";
    desc += "清单：${ChecklistController.to.desc}\n";
    // 因为要打开历史页，才会创建HistoryController，所以此处可能还未创建，因此使用dao
    desc += "历史：${await HistoryDao.getCount()}条记录\n";
    desc += "笔记图片数：$noteImageCount\n";
    desc += "封面图片数：$coverImageCount";
    descFile.writeAsStringSync(desc);
    await encoder.addFile(descFile);
    AppLog.info("✓ 备份描述信息");

    await encoder.close();
    return File(tempZipFilePath);
  }
  
  /// 递归添加目录到ZIP中
  static void _addDirectoryToZip(ZipFileEncoder encoder, String dirPath, String zipDirPrefix) {
    Directory dir = Directory(dirPath);
    if (!dir.existsSync()) return;
    
    List<FileSystemEntity> entities = dir.listSync(recursive: true);
    for (var entity in entities) {
      if (entity is File) {
        String relativePath = entity.path.replaceFirst(dirPath, "");
        // 移除开头的分隔符
        if (relativePath.startsWith("/") || relativePath.startsWith("\\")) {
          relativePath = relativePath.substring(1);
        }
        String zipPath = zipDirPrefix + relativePath.replaceAll("\\", "/");
        encoder.addFile(entity, zipPath);
      }
    }
  }
  
  /// 生成版本ID（时间戳+随机数）
  static String generateVersionId() {
    String timestamp = DateTime.now().millisecondsSinceEpoch.toString();
    String random = DateTime.now().microsecond.toString().padLeft(6, '0');
    return "v_${timestamp}_$random";
  }
  
  /// 获取当前备份的统计信息
  static Future<Map<String, dynamic>> getBackupStats() async {
    String noteImageDir = ImageUtil.getNoteImageRootDirPath();
    String coverImageDir = ImageUtil.getCoverImageRootDirPath();
    
    int noteCount = Directory(noteImageDir).existsSync()
        ? Directory(noteImageDir).listSync(recursive: true).whereType<File>().length
        : 0;
    int coverCount = Directory(coverImageDir).existsSync()
        ? Directory(coverImageDir).listSync(recursive: true).whereType<File>().length
        : 0;
    
    return {
      'recordCount': int.tryParse(ChecklistController.to.desc.split("/")[0].trim()) ?? 0,
      'labelCount': await LabelDao.getAllLabels().then((list) => list.length),
      'noteImageCount': noteCount,
      'coverImageCount': coverCount,
    };
  }
  
  /// 保存备份版本信息到数据库
  static Future<void> saveSyncVersion({
    required String versionId,
    required String backupMode, // 'full' or 'incremental'
    required String source,     // 'manual', 'automatic', 'sync'
    String? localPath,
    String? remotePath,
  }) async {
    try {
      final stats = await getBackupStats();
      int versionNumber = 1;
      
      // 获取最新的版本号
      final allVersions = await SqliteSyncUtil.getAllSyncVersions(SqliteUtil.database);
      if (allVersions.isNotEmpty) {
        versionNumber = allVersions.first.versionNumber + 1;
      }
      
      final version = SyncVersion(
        id: versionId,
        versionNumber: versionNumber,
        createTime: DateTime.now(),
        backupMode: backupMode,
        source: source,
        device: Platform.operatingSystem,
        recordCount: stats['recordCount'] ?? 0,
        labelCount: stats['labelCount'] ?? 0,
        noteImageCount: stats['noteImageCount'] ?? 0,
        coverImageCount: stats['coverImageCount'] ?? 0,
        totalSize: localPath != null ? File(localPath).lengthSync() : 0,
        parentVersionId: null, // 暂时不支持增量链
        localPath: localPath,
        remotePath: remotePath,
      );
      
      await SqliteSyncUtil.insertSyncVersion(SqliteUtil.database, version);
      AppLog.info("✓ 备份版本信息已保存: $versionId");
    } catch (e) {
      AppLog.error("保存备份版本信息失败: $e");
    }
  }

  static Future<Result> autoBackupRemote() async {
    await BackupUtil.backup(
      remoteBackupDirPath: await WebDavUtil.getRemoteDirPath(),
      showToastFlag: false,
      automatic: true,
    );

    return Result.success("", msg: "远程备份成功");
  }

  // 应该返回webdav包中的File，可惜加上后会和io中的File冲突
  static Future<String> backup({
    String localBackupDirPath = "",
    String remoteBackupDirPath = "",
    bool showToastFlag = true,
    bool automatic = false,
  }) async {
    String zipName = await generateZipName();
    String versionId = generateVersionId();
    File tempZipFile = await createTempBackUpFile(zipName);
    
    String? savedLocalPath;

    if (localBackupDirPath.isNotEmpty) {
      // 已设置路径，直接备份
      if (localBackupDirPath != "unset") {
        String localBackupFilePath;
        if (automatic) {
          // 不管是否都会先创建文件夹，确保存在，否则不能拷贝
          await Directory("$localBackupDirPath/automatic").create();
          localBackupFilePath = "$localBackupDirPath/automatic/$zipName";
        } else {
          localBackupFilePath = "$localBackupDirPath/$zipName";
        }
        await tempZipFile.copy(localBackupFilePath);
        savedLocalPath = localBackupFilePath;
        if (showToastFlag) ToastUtil.showText("本地备份成功");
        // 如果还要备份到webdav，则先不删除
        if (remoteBackupDirPath.isEmpty) {
          tempZipFile.delete();
          // 保存备份版本信息
          await saveSyncVersion(
            versionId: versionId,
            backupMode: 'full',
            source: automatic ? 'automatic' : 'manual',
            localPath: localBackupFilePath,
          );
          return localBackupFilePath;
        }
      } else {
        if (showToastFlag) {
          ToastUtil.showText("请先设置本地备份目录");
          return "";
        }
      }
    }
    if (remoteBackupDirPath.isNotEmpty) {
      if (RemoteController.to.isOffline) {
        AppLog.info("远程备份失败，请检查网络状态");
        ToastUtil.showText("远程备份失败，请检查网络状态");
        tempZipFile.delete(); // 备份失败后需要删掉临时备份文件
        return "";
      }
      String remoteBackupFilePath;
      if (automatic) {
        // 即使不存在automatic目录，上传文件到坚果云、TeraCloud时也会成功
        remoteBackupFilePath = "$remoteBackupDirPath/automatic/$zipName";
      } else {
        remoteBackupFilePath = "$remoteBackupDirPath/$zipName";
      }
      await WebDavUtil.upload(tempZipFile.path, remoteBackupFilePath);
      SPUtil.setString(latestDavBackupFilePath, remoteBackupFilePath);
      if (showToastFlag) {
        ToastUtil.showText("远程备份成功");
      }
      // 因为之前upload里的上传没有await，导致还没有上传完毕就删除了文件。从而导致上传失败
      tempZipFile.delete();
      deleteOldAutoBackupFileFromRemote(remoteBackupDirPath); // 删除自动备份中超过用户备份数量的文件
      
      // 保存备份版本信息
      await saveSyncVersion(
        versionId: versionId,
        backupMode: 'full',
        source: automatic ? 'automatic' : 'manual',
        localPath: savedLocalPath,
        remotePath: remoteBackupFilePath,
      );
      
      return remoteBackupFilePath;
      // 可以备份，但不是增量备份。
      // ！无法还原：Unhandled Exception: FormatException: Could not find End of Central Directory Record
      // Uint8List uint8list = File(tempZipFilePath).readAsBytesSync();
      // WebDavUtil.client.write(remoteBackupFilePath, uint8list).then((value) {
      //   if (showToastFlag) ToastUtil.showText("备份成功：$remoteBackupFilePath");
      //   File(tempZipFilePath).delete();
      // });
      // 移动。会导致无法连接，第一次还没有效果
      // WebDavUtil.client
      //     .copy(tempZipFilePath, remoteBackupFilePath, false)
      //     .then((value) {
      //   ToastUtil.showText("备份成功：$remoteBackupFilePath");
      //   File(tempZipFilePath).delete();
      // });
      // 报错
      // WebDavUtil.upload("$dirPath/mydb.db", remoteBackupFilePath)
      //     .then((value) {
      //   ToastUtil.showText("备份成功：$remoteBackupFilePath");
      //   File(tempZipFilePath).delete();
      // });
    }
    return "";
  }

  static deleteOldAutoBackupFileFromRemote(String autoBackupDirPath) async {
    var files = await WebDavUtil.client.readDir("/animetrace/automatic");
    files.sort((a, b) {
      return a.mTime.toString().compareTo(b.mTime.toString());
    });
    int totalNumber = files.length;
    int autoBackupWebDavNumber =
        SPUtil.getInt("autoBackupWebDavNumber", defaultValue: 20);
    for (int i = 0; i < totalNumber - autoBackupWebDavNumber; ++i) {
      String? path = files[i].path;
      if (path != null &&
          path.contains('backup') && // 包含backup
          // && path.startsWith(
          // "/animetrace/automatic/animetrace-backup") && // 以animetrace-backup开头
          // "/animetrace/automatic/$backupZipNamePrefix") && // 以$backupZipNamePrefix开头
          path.endsWith(".zip")) {
        AppLog.info("删除文件：$path");
        WebDavUtil.client.remove(path);
      }
    }
  }

  static deleteRemoteFile(String filePath) {
    WebDavUtil.client.remove(filePath);
  }

  // static deleteOldAutoBackupFileFromLocal(String autoBackupDirPath) async {
  //   Stream<FileSystemEntity> files = Directory(autoBackupDirPath).list();
  //   await for (FileSystemEntity file in files) {}
  // }

  static Future<Result> restoreFromLocal(
    String localBackupFilePath, {
    bool delete = false,
    bool recordBeforeRestore = true,
    bool overwriteImages = false,
  }) async {
    bool restoreOk = false;

    // 1.还原前先备份当前数据库文件
    if (recordBeforeRestore) {
      try {
        String dirPath = await getRBRPath();
        // 时间取到秒
        String time = DateTime.now().toString().split(".")[0];
        // :和空格转为-，文件名不能包含英文冒号，否则会提示文件名、目录名或卷标语法不正确
        time = time.replaceAll(":", "-");
        time = time.replaceAll(" ", "-");
        String recordFileName = "record-$time.zip";
        var recordFile = await BackupUtil.createTempBackUpFile(recordFileName);
        File rbrFile = await recordFile.rename("$dirPath/$recordFileName");
        AppLog.info("✓ 还原前备份已创建: ${rbrFile.path}");
        
        // 清理超出限制的旧RBR文件
        var stream = Directory(dirPath).list();
        List<File> files = [];
        await for (var fse in stream) {
          if (fse is File) {
            files.add(fse);
          }
        }
        if (files.length > rbrMaxCnt) {
          // 按名字排序，日期最小的是第1个
          files.sort((a, b) => a.path.compareTo(b.path));
          await files.first.delete();
          AppLog.info("⊘ 删除旧RBR备份: ${files.first.path}");
        }
      } catch (e) {
        AppLog.error("创建RBR备份失败: $e");
        // RBR备份失败不应该中断还原过程
      }
    }

    // 2.然后进行还原
    if (localBackupFilePath.endsWith(".db")) {
      // 对于手机：将该文件拷贝到新路径SqliteUtil.dbPath下，可以直接拷贝：await File(selectedFilePath).copy(SqliteUtil.dbPath);
      // 而window需要手动代码删除，否则：(OS Error: 当文件已存在时，无法创建该文件。
      // 然而并不能删除：(OS Error: 另一个程序正在使用此文件，进程无法访问：await File(SqliteUtil.dbPath).delete();
      // 可以直接在里面写入即可，writeAsBytes会清空原先内容
      try {
        var content = await File(localBackupFilePath).readAsBytes();
        await File(SqliteUtil.dbPath).writeAsBytes(content);
        await SqliteUtil.ensureDBTable();
        AppLog.info("✓ 数据库文件已还原");
        restoreOk = true;
      } catch (e) {
        AppLog.error("还原数据库文件失败: $e");
      }
    } else if (localBackupFilePath.endsWith(".zip")) {
      try {
        await unzip(localBackupFilePath, overwriteImages: overwriteImages);
        await SqliteUtil.ensureDBTable();
        if (delete) File(localBackupFilePath).delete();
        restoreOk = true;
      } catch (e) {
        AppLog.error("解压并还原失败: $e");
      }
    }

    if (restoreOk) {
      // 重新获取更新记录、标签、清单
      try {
        UpdateRecordController.to.updateData();
        LabelsController.to.getAllLabels();
        ChecklistController.to.restore();
        // 直接删除相关控制器(注意有些控制器不能删除，因为是在Global.init里put的，不过应该可以再次调用它就好，待测试)
        Get.delete<DedupController>();
        AppLog.info("✓ 所有控制器已刷新");
      } catch (e) {
        AppLog.error("刷新控制器失败: $e");
      }

      AppLog.info("✓ 还原成功，已刷新所有数据");
      return Result.success("", msg: "还原成功");
    } else {
      return Result.failure(404, "备份文件不正确，无法还原");
    }
  }

  static Future<Result> restoreFromWebDav(dav_client.File file, {bool overwriteImages = false}) async {
    String localRootDirPath = await SqliteUtil.getLocalRootDirPath();

    if (file.path == null) {
      return Result.failure(404, "空文件路径，无法还原");
    }
    AppLog.info("开始从WebDav还原: ${file.path}");
    String localBackupFilePath = "$localRootDirPath/${file.name}";
    
    try {
      await WebDavUtil.client.read2File(file.path as String, localBackupFilePath);
      AppLog.info("✓ 备份文件已下载到本地: $localBackupFilePath");

      AppLog.info("localRootDirPath: $localRootDirPath\nlocalZipPath: $localBackupFilePath");
      // 下载到本地后，使用本地还原，还原结束后删除下载的文件
      return restoreFromLocal(localBackupFilePath, delete: true, overwriteImages: overwriteImages);
    } catch (e) {
      AppLog.error("从WebDav还原失败: $e");
      return Result.failure(500, "从WebDav下载备份文件失败: $e");
    }
  }

  static Future<void> unzip(String localZipPath, {bool overwriteImages = false}) async {
    String localRootDirPath = await SqliteUtil.getLocalRootDirPath();
    
    // 初始化图片目录（确保目录存在）
    await ImageUtil.initializePrivateDirs();
    String noteImageDir = ImageUtil.getNoteImageRootDirPath();
    String coverImageDir = ImageUtil.getCoverImageRootDirPath();

    // Read the Zip file from disk.
    final bytes = File(localZipPath).readAsBytesSync();
    
    // Decode the Zip file
    final archive = ZipDecoder().decodeBytes(bytes);

    AppLog.info("开始解压，覆盖图片: $overwriteImages");
    AppLog.info("笔记图片目录: $noteImageDir");
    AppLog.info("封面图片目录: $coverImageDir");
    
    int fileCount = 0;
    int skippedCount = 0;
    
    // Extract the contents of the Zip archive to disk.
    for (final file in archive) {
      final filename = file.name;
      if (file.isFile) {
        String actualFilePath;
        
        // 根据文件类型确定实际保存路径
        if (filename.startsWith("images/note_images/")) {
          // 提取相对路径（去掉 "images/note_images/" 前缀）
          String relativePath = filename.replaceFirst("images/note_images/", "");
          actualFilePath = noteImageDir + relativePath;
        } else if (filename.startsWith("images/cover_images/")) {
          // 提取相对路径（去掉 "images/cover_images/" 前缀）
          String relativePath = filename.replaceFirst("images/cover_images/", "");
          actualFilePath = coverImageDir + relativePath;
        } else {
          // 其他文件（如数据库、描述）放在根目录
          actualFilePath = "$localRootDirPath/$filename";
        }
        
        // 检查是否已存在，如果是图片且已存在，根据overwriteImages决定
        bool isImageFile = filename.startsWith("images/");
        if (isImageFile && File(actualFilePath).existsSync() && !overwriteImages) {
          AppLog.info("⊘ 跳过已存在的图片: $actualFilePath");
          skippedCount++;
          continue;
        }
        
        try {
          // 创建父目录（包括所有中间目录）
          Directory parentDir = File(actualFilePath).parent;
          if (!parentDir.existsSync()) {
            await parentDir.create(recursive: true);
          }
          
          // 写入文件
          AppLog.info("✓ 解压文件: $actualFilePath");
          final data = file.content as List<int>;
          await File(actualFilePath).writeAsBytes(data);
          fileCount++;
        } catch (e) {
          AppLog.error("解压文件失败 [$actualFilePath]: $e");
        }
      } else {
        // 处理目录
        Directory dirPath;
        if (filename.startsWith("images/note_images/")) {
          String relativePath = filename.replaceFirst("images/note_images/", "");
          dirPath = Directory(noteImageDir + relativePath);
        } else if (filename.startsWith("images/cover_images/")) {
          String relativePath = filename.replaceFirst("images/cover_images/", "");
          dirPath = Directory(coverImageDir + relativePath);
        } else {
          dirPath = Directory("$localRootDirPath/$filename");
        }
        
        if (!dirPath.existsSync()) {
          try {
            await dirPath.create(recursive: true);
            AppLog.info("✓ 创建目录: ${dirPath.path}");
          } catch (e) {
            AppLog.error("创建目录失败 [${dirPath.path}]: $e");
          }
        }
      }
    }
    
    AppLog.info("✓ 解压完成 (已解压: $fileCount 个文件, 跳过: $skippedCount 个)");
  }

  /// 获取远程所有备份文件列表，包括手动和自动
  static Future<List<dav_client.File>> getAllBackupFiles() async {
    List<dav_client.File> files = [];

    String backupDir = await WebDavUtil.getRemoteDirPath();
    if (backupDir.isEmpty) {
      AppLog.info("远程备份路径为空");
      return [];
    }

    String autoDir = await WebDavUtil.getRemoteAutoDirPath(backupDir);
    files.addAll(await WebDavUtil.client.readDir(backupDir));
    files.addAll(await WebDavUtil.client.readDir(autoDir));

    // 去除目录
    files.removeWhere(
        (element) => element.isDir ?? element.path?.endsWith("/") ?? false);

    AppLog.info("获取完毕，共${files.length}个文件");
    files.sort((a, b) => b.mTime.toString().compareTo(a.mTime.toString()));
    return files;
  }

  /// 获取最新远程备份文件
  static Future<dav_client.File?> getLatestBackupFile() async {
    var files = await getAllBackupFiles();
    if (files.isEmpty) {
      return null;
    } else {
      return files.first;
    }
  }

  /// 获取还原时备份当前数据所应存放的目录路径
  static Future<String> getRBRPath() async {
    String dirPath =
        "${(await getApplicationSupportDirectory()).path}/backup_before_restore";
    Directory(dirPath).createSync();
    return dirPath;
  }
}
