import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:manji_trace/controllers/labels_controller.dart';
import 'package:manji_trace/controllers/remote_controller.dart';
import 'package:manji_trace/controllers/update_record_controller.dart';
import 'package:manji_trace/dao/history_dao.dart';
import 'package:manji_trace/dao/label_dao.dart';
import 'package:manji_trace/models/params/result.dart';
import 'package:manji_trace/models/sync_version.dart';
import 'package:manji_trace/pages/anime_collection/checklist_controller.dart';
import 'package:manji_trace/pages/network/sources/pages/dedup/dedup_controller.dart';
import 'package:manji_trace/utils/sp_util.dart';
import 'package:manji_trace/utils/sqlite_util.dart';
import 'package:manji_trace/utils/sqlite_sync_util.dart';
import 'package:manji_trace/utils/webdav_util.dart';
import 'package:manji_trace/utils/image_util.dart';
import 'package:manji_trace/utils/journal_markdown_util.dart';
import 'package:manji_trace/utils/note_markdown_util.dart';
import 'package:manji_trace/values/values.dart';
import 'package:get/get.dart';
import 'package:manji_trace/utils/toast_util.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:manji_trace/utils/log.dart';
import 'package:webdav_client/webdav_client.dart' as dav_client;

class BackupUtil {
  static String backupZipNamePrefix = "backup";
  static String descFileName = "desc";
  static int rbrMaxCnt = 20;
  static const double _minProgress = 0.0;
  static const double _maxProgress = 1.0;

  static void _reportProgress(
    void Function(double progress, String message)? onProgress,
    double progress,
    String message,
  ) {
    if (onProgress == null) {
      return;
    }
    final double safeProgress = progress.clamp(_minProgress, _maxProgress);
    onProgress(safeProgress, message);
  }

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
  static Future<File> createTempBackUpFile(
    String zipName, {
    void Function(double progress, String message)? onProgress,
  }) async {
    String dirPath = (await getTemporaryDirectory()).path;
    final String resolvedDbPath = await SqliteUtil.getDBPath();

    String tempZipFilePath = "$dirPath/$zipName";
    String noteImageDir = ImageUtil.getNoteImageRootDirPath();
    String journalImageDir = ImageUtil.getJournalImageRootDirPath();
    String coverImageDir = ImageUtil.getCoverImageRootDirPath();
    final String markdownDir =
        await JournalMarkdownUtil.getMarkdownRootDirPath();
    final String noteMarkdownDir =
        await NoteMarkdownUtil.getMarkdownRootDirPath();
    final String checklistDesc = ChecklistController.to.desc;
    final int historyCount = await HistoryDao.getCount();

    _reportProgress(onProgress, 0.05, "正在准备备份文件");
    if (Platform.isWindows) {
      _reportProgress(onProgress, 0.1, "正在后台压缩备份包");
      final counts = await Isolate.run(() {
        return _createZipOnBackground(
          tempZipFilePath: tempZipFilePath,
          dbPath: resolvedDbPath,
          noteImageDir: noteImageDir,
          journalImageDir: journalImageDir,
          coverImageDir: coverImageDir,
          markdownDir: markdownDir,
          noteMarkdownDir: noteMarkdownDir,
          checklistDesc: checklistDesc,
          historyCount: historyCount,
        );
      });
      AppLog.info("✓ 备份笔记图片 (${counts['note'] ?? 0} 个文件)");
      AppLog.info("✓ 备份日记图片 (${counts['journal'] ?? 0} 个文件)");
      AppLog.info("✓ 备份封面图片 (${counts['cover'] ?? 0} 个文件)");
      AppLog.info("✓ 备份日记Markdown (${counts['markdown'] ?? 0} 个文件)");
      AppLog.info("✓ 备份笔记Markdown (${counts['noteMarkdown'] ?? 0} 个文件)");
      _reportProgress(onProgress, 1.0, "备份包生成完成");
      return File(tempZipFilePath);
    }

    var encoder = ZipFileEncoder();
    encoder.create(tempZipFilePath);

    // 1. 添加数据库文件
    encoder.addFile(File(resolvedDbPath));
    AppLog.info("✓ 备份数据库文件");
    _reportProgress(onProgress, 0.2, "已打包数据库");

    // 2. 添加笔记图片文件夹
    int noteImageCount = 0;
    final List<File> noteFiles = await _listFilesRecursively(noteImageDir);
    if (noteFiles.isNotEmpty) {
      noteImageCount = noteFiles.length;
      await _addFilesToZip(
        encoder,
        rootDir: noteImageDir,
        files: noteFiles,
        zipDirPrefix: "images/note_images/",
        onProgress: onProgress,
        progressStart: 0.22,
        progressEnd: 0.4,
        progressText: "正在打包笔记图片",
      );
      AppLog.info("✓ 备份笔记图片 ($noteImageCount 个文件)");
    }
    _reportProgress(onProgress, 0.4, "已处理笔记图片");

    // 2.5 添加日记图片文件夹
    int journalImageCount = 0;
    final List<File> journalFiles =
        await _listFilesRecursively(journalImageDir);
    if (journalFiles.isNotEmpty) {
      journalImageCount = journalFiles.length;
      await _addFilesToZip(
        encoder,
        rootDir: journalImageDir,
        files: journalFiles,
        zipDirPrefix: "images/journal_images/",
        onProgress: onProgress,
        progressStart: 0.42,
        progressEnd: 0.6,
        progressText: "正在打包日记图片",
      );
      AppLog.info("✓ 备份日记图片 ($journalImageCount 个文件)");
    }
    _reportProgress(onProgress, 0.6, "已处理日记图片");

    // 3. 添加封面图片文件夹
    int coverImageCount = 0;
    final List<File> coverFiles = await _listFilesRecursively(coverImageDir);
    if (coverFiles.isNotEmpty) {
      coverImageCount = coverFiles.length;
      await _addFilesToZip(
        encoder,
        rootDir: coverImageDir,
        files: coverFiles,
        zipDirPrefix: "images/cover_images/",
        onProgress: onProgress,
        progressStart: 0.62,
        progressEnd: 0.75,
        progressText: "正在打包封面图片",
      );
      AppLog.info("✓ 备份封面图片 ($coverImageCount 个文件)");
    }
    _reportProgress(onProgress, 0.75, "已处理封面图片");

    // 3.5 添加日记Markdown文件
    int markdownCount = 0;
    final List<File> markdownFiles = await _listFilesRecursively(markdownDir);
    if (markdownFiles.isNotEmpty) {
      markdownCount = markdownFiles.length;
      await _addFilesToZip(
        encoder,
        rootDir: markdownDir,
        files: markdownFiles,
        zipDirPrefix: "notes/journal/",
        onProgress: onProgress,
        progressStart: 0.76,
        progressEnd: 0.88,
        progressText: "正在打包日记Markdown",
      );
      AppLog.info("✓ 备份日记Markdown ($markdownCount 个文件)");
    }
    _reportProgress(onProgress, 0.88, "已处理日记Markdown");

    int noteMarkdownCount = 0;
    final List<File> noteMarkdownFiles =
        await _listFilesRecursively(noteMarkdownDir);
    if (noteMarkdownFiles.isNotEmpty) {
      noteMarkdownCount = noteMarkdownFiles.length;
      await _addFilesToZip(
        encoder,
        rootDir: noteMarkdownDir,
        files: noteMarkdownFiles,
        zipDirPrefix: "notes/note/",
        onProgress: onProgress,
        progressStart: 0.89,
        progressEnd: 0.94,
        progressText: "正在打包笔记Markdown",
      );
      AppLog.info("✓ 备份笔记Markdown ($noteMarkdownCount 个文件)");
    }
    _reportProgress(onProgress, 0.94, "已处理笔记Markdown");

    // 4. 添加描述信息
    File descFile = File("$dirPath/desc");
    String desc = "";
    desc += "清单：$checklistDesc\n";
    desc += "历史：$historyCount条记录\n";
    desc += "笔记图片数：$noteImageCount\n";
    desc += "日记图片数：$journalImageCount\n";
    desc += "封面图片数：$coverImageCount\n";
    desc += "日记Markdown数：$markdownCount\n";
    desc += "笔记Markdown数：$noteMarkdownCount";
    descFile.writeAsStringSync(desc);
    await encoder.addFile(descFile);
    AppLog.info("✓ 备份描述信息");
    _reportProgress(onProgress, 0.9, "正在封装备份包");

    await encoder.close();
    _reportProgress(onProgress, 1.0, "备份包生成完成");
    return File(tempZipFilePath);
  }

  static Map<String, int> _createZipOnBackground({
    required String tempZipFilePath,
    required String dbPath,
    required String noteImageDir,
    required String journalImageDir,
    required String coverImageDir,
    required String markdownDir,
    required String noteMarkdownDir,
    required String checklistDesc,
    required int historyCount,
  }) {
    final encoder = ZipFileEncoder();
    encoder.create(tempZipFilePath);
    encoder.addFile(File(dbPath));

    final int noteCount =
        _addDirectoryToZipSync(encoder, noteImageDir, "images/note_images/");
    final int journalCount = _addDirectoryToZipSync(
        encoder, journalImageDir, "images/journal_images/");
    final int coverCount =
        _addDirectoryToZipSync(encoder, coverImageDir, "images/cover_images/");
    final int markdownCount =
        _addDirectoryToZipSync(encoder, markdownDir, "notes/journal/");
    final int noteMarkdownCount =
        _addDirectoryToZipSync(encoder, noteMarkdownDir, "notes/note/");

    final String dirPath = File(tempZipFilePath).parent.path;
    final File descFile = File("$dirPath/desc");
    final String desc = "清单：$checklistDesc\n"
        "历史：$historyCount条记录\n"
        "笔记图片数：$noteCount\n"
        "日记图片数：$journalCount\n"
        "封面图片数：$coverCount\n"
        "日记Markdown数：$markdownCount\n"
        "笔记Markdown数：$noteMarkdownCount";
    descFile.writeAsStringSync(desc);
    encoder.addFile(descFile);
    encoder.closeSync();

    return {
      'note': noteCount,
      'journal': journalCount,
      'cover': coverCount,
      'markdown': markdownCount,
      'noteMarkdown': noteMarkdownCount,
    };
  }

  static int _addDirectoryToZipSync(
    ZipFileEncoder encoder,
    String dirPath,
    String zipDirPrefix,
  ) {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) {
      return 0;
    }

    int count = 0;
    final entities = dir.listSync(recursive: true);
    for (final entity in entities) {
      if (entity is! File) {
        continue;
      }
      String relativePath = entity.path.replaceFirst(dirPath, "");
      if (relativePath.startsWith("/") || relativePath.startsWith("\\")) {
        relativePath = relativePath.substring(1);
      }
      final String zipPath = zipDirPrefix + relativePath.replaceAll("\\", "/");
      encoder.addFile(entity, zipPath);
      count++;
    }
    return count;
  }

  /// 异步递归读取文件，避免 listSync 造成长时间阻塞。
  static Future<List<File>> _listFilesRecursively(String dirPath) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) {
      return <File>[];
    }

    final List<File> files = <File>[];
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        files.add(entity);
      }
    }
    return files;
  }

  /// 分批写入 ZIP，并周期性让出事件循环，提升 UI 响应。
  static Future<void> _addFilesToZip(
    ZipFileEncoder encoder, {
    required String rootDir,
    required List<File> files,
    required String zipDirPrefix,
    void Function(double progress, String message)? onProgress,
    required double progressStart,
    required double progressEnd,
    required String progressText,
  }) async {
    if (files.isEmpty) {
      return;
    }

    const int yieldEvery = 12;
    for (int i = 0; i < files.length; i++) {
      final File file = files[i];
      String relativePath = file.path.replaceFirst(rootDir, "");
      if (relativePath.startsWith("/") || relativePath.startsWith("\\")) {
        relativePath = relativePath.substring(1);
      }
      final String zipPath = zipDirPrefix + relativePath.replaceAll("\\", "/");
      encoder.addFile(file, zipPath);

      final double percent = (i + 1) / files.length;
      final double progress =
          progressStart + (progressEnd - progressStart) * percent;
      _reportProgress(
          onProgress, progress, '$progressText (${i + 1}/${files.length})');

      if ((i + 1) % yieldEvery == 0) {
        await Future<void>.delayed(Duration.zero);
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
    String journalImageDir = ImageUtil.getJournalImageRootDirPath();
    String coverImageDir = ImageUtil.getCoverImageRootDirPath();
    String markdownDir = await JournalMarkdownUtil.getMarkdownRootDirPath();
    String noteMarkdownDir = await NoteMarkdownUtil.getMarkdownRootDirPath();

    int noteCount = Directory(noteImageDir).existsSync()
        ? Directory(noteImageDir)
            .listSync(recursive: true)
            .whereType<File>()
            .length
        : 0;
    int journalCount = Directory(journalImageDir).existsSync()
        ? Directory(journalImageDir)
            .listSync(recursive: true)
            .whereType<File>()
            .length
        : 0;
    int coverCount = Directory(coverImageDir).existsSync()
        ? Directory(coverImageDir)
            .listSync(recursive: true)
            .whereType<File>()
            .length
        : 0;
    int markdownCount = Directory(markdownDir).existsSync()
        ? Directory(markdownDir)
            .listSync(recursive: true)
            .whereType<File>()
            .length
        : 0;
    int noteMarkdownCount = Directory(noteMarkdownDir).existsSync()
        ? Directory(noteMarkdownDir)
            .listSync(recursive: true)
            .whereType<File>()
            .length
        : 0;

    return {
      'recordCount':
          int.tryParse(ChecklistController.to.desc.split("/")[0].trim()) ?? 0,
      'labelCount': await LabelDao.getAllLabels().then((list) => list.length),
      'noteImageCount': noteCount,
      'journalImageCount': journalCount,
      'coverImageCount': coverCount,
      'journalMarkdownCount': markdownCount,
      'noteMarkdownCount': noteMarkdownCount,
    };
  }

  /// 保存备份版本信息到数据库
  static Future<void> saveSyncVersion({
    required String versionId,
    required String backupMode, // 'full' or 'incremental'
    required String source, // 'manual', 'automatic', 'sync'
    String? localPath,
    String? remotePath,
  }) async {
    try {
      final stats = await getBackupStats();
      int versionNumber = 1;

      // 获取最新的版本号
      final allVersions =
          await SqliteSyncUtil.getAllSyncVersions(SqliteUtil.database);
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
      remoteBackupDirPath: await WebDavUtil.getRemoteBackupDirPath(),
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
    void Function(double progress, String message)? onProgress,
  }) async {
    _reportProgress(onProgress, 0.01, "开始备份");
    String zipName = await generateZipName();
    String versionId = generateVersionId();
    File tempZipFile = await createTempBackUpFile(
      zipName,
      onProgress: onProgress,
    );

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
        _reportProgress(onProgress, 0.96, "已保存到本地目录");
        savedLocalPath = localBackupFilePath;
        if (showToastFlag) ToastUtil.showText("本地备份成功");
        // 如果还要备份到webdav，则先不删除
        if (remoteBackupDirPath.isEmpty) {
          tempZipFile.delete();
          _reportProgress(onProgress, 1.0, "本地备份完成");
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
      _reportProgress(onProgress, 0.98, "远程文件上传完成");
      SPUtil.setString(latestDavBackupFilePath, remoteBackupFilePath);
      if (showToastFlag) {
        ToastUtil.showText("远程备份成功");
      }
      // 因为之前upload里的上传没有await，导致还没有上传完毕就删除了文件。从而导致上传失败
      tempZipFile.delete();
      deleteOldAutoBackupFileFromRemote(
          remoteBackupDirPath); // 删除自动备份中超过用户备份数量的文件

      // 保存备份版本信息
      await saveSyncVersion(
        versionId: versionId,
        backupMode: 'full',
        source: automatic ? 'automatic' : 'manual',
        localPath: savedLocalPath,
        remotePath: remoteBackupFilePath,
      );
      _reportProgress(onProgress, 1.0, "远程备份完成");

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
    _reportProgress(onProgress, 1.0, "备份结束");
    return "";
  }

  static deleteOldAutoBackupFileFromRemote(String autoBackupDirPath) async {
    final String autoDirPath = "$autoBackupDirPath/automatic";
    List<dav_client.File> files = [];
    try {
      files = await WebDavUtil.client.readDir(autoDirPath);
    } catch (_) {
      return;
    }
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
          // "/manji_trace/automatic/animetrace-backup") && // 以animetrace-backup开头
          // "/manji_trace/automatic/$backupZipNamePrefix") && // 以$backupZipNamePrefix开头
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
        File rbrFile = await recordFile.rename(p.join(dirPath, recordFileName));
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
        // 还原后清理“有记录但文件不存在”的图片，避免显示损坏占位图。
        await SqliteUtil.cleanupMissingImageRows();
        if (delete) {
          await File(localBackupFilePath).delete();
        }
        restoreOk = true;
      } catch (e) {
        AppLog.error("解压并还原失败: $e");
        if (e.toString().contains('End of Central Directory')) {
          return Result.failure(404, '备份文件可能已损坏或不是标准ZIP文件');
        }
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

  static Future<Result> restoreFromWebDav(dav_client.File file,
      {bool overwriteImages = false}) async {
    String localRootDirPath = await SqliteUtil.getLocalRootDirPath();

    if (file.path == null) {
      return Result.failure(404, "空文件路径，无法还原");
    }
    AppLog.info("开始从WebDav还原: ${file.path}");
    String localBackupFilePath = p.join(localRootDirPath, file.name);

    try {
      await WebDavUtil.client
          .read2File(file.path as String, localBackupFilePath);
      AppLog.info("✓ 备份文件已下载到本地: $localBackupFilePath");

      AppLog.info(
          "localRootDirPath: $localRootDirPath\nlocalZipPath: $localBackupFilePath");
      // 下载到本地后，使用本地还原，还原结束后删除下载的文件
      return restoreFromLocal(localBackupFilePath,
          delete: true, overwriteImages: overwriteImages);
    } catch (e) {
      AppLog.error("从WebDav还原失败: $e");
      return Result.failure(500, "从WebDav下载备份文件失败: $e");
    }
  }

  static Future<void> unzip(String localZipPath,
      {bool overwriteImages = false}) async {
    String localRootDirPath = await SqliteUtil.getLocalRootDirPath();

    // 初始化图片目录（确保目录存在）
    await ImageUtil.initializePrivateDirs();
    String noteImageDir = ImageUtil.getNoteImageRootDirPath();
    String journalImageDir = ImageUtil.getJournalImageRootDirPath();
    String coverImageDir = ImageUtil.getCoverImageRootDirPath();
    String markdownDir = await JournalMarkdownUtil.getMarkdownRootDirPath();
    String noteMarkdownDir = await NoteMarkdownUtil.getMarkdownRootDirPath();

    // Read the Zip file from disk.
    final bytes = File(localZipPath).readAsBytesSync();

    // Decode the Zip file
    final archive = _decodeZipArchiveRobustly(bytes);

    AppLog.info("开始解压，覆盖图片: $overwriteImages");
    AppLog.info("笔记图片目录: $noteImageDir");
    AppLog.info("日记图片目录: $journalImageDir");
    AppLog.info("封面图片目录: $coverImageDir");

    int fileCount = 0;
    int skippedCount = 0;

    // Extract the contents of the Zip archive to disk.
    for (final file in archive) {
      final filename = file.name;
      if (file.isFile) {
        String actualFilePath;
        final String normalizedName = filename.replaceAll('\\', '/');

        String? extractLegacyImagePath(String prefix, String baseDir) {
          final int idx = normalizedName.indexOf(prefix);
          if (idx < 0) return null;
          final String relativePath =
              normalizedName.substring(idx + prefix.length);
          return p.join(baseDir, relativePath);
        }

        // 根据文件类型确定实际保存路径
        final notePath =
            extractLegacyImagePath('images/note_images/', noteImageDir) ??
                extractLegacyImagePath('note_images/', noteImageDir);
        final journalPath =
            extractLegacyImagePath('images/journal_images/', journalImageDir) ??
                extractLegacyImagePath('journal_images/', journalImageDir);
        final coverPath =
            extractLegacyImagePath('images/cover_images/', coverImageDir) ??
                extractLegacyImagePath('cover_images/', coverImageDir);
        final markdownPath =
            extractLegacyImagePath('notes/journal/', markdownDir);
        final noteMarkdownPath =
            extractLegacyImagePath('notes/note/', noteMarkdownDir);

        if (notePath != null) {
          actualFilePath = notePath;
        } else if (journalPath != null) {
          actualFilePath = journalPath;
        } else if (coverPath != null) {
          actualFilePath = coverPath;
        } else if (markdownPath != null) {
          actualFilePath = markdownPath;
        } else if (noteMarkdownPath != null) {
          actualFilePath = noteMarkdownPath;
        } else if (normalizedName.endsWith('.db')) {
          // 兼容旧版备份中数据库文件名不是固定 mydb.db 的情况
          actualFilePath = SqliteUtil.dbPath;
        } else {
          // 其他文件（如数据库、描述）放在根目录
          actualFilePath = p.join(localRootDirPath, filename);
        }

        // 检查是否已存在，如果是图片且已存在，根据overwriteImages决定
        bool isImageFile = normalizedName.startsWith("images/") ||
            normalizedName.startsWith("note_images/") ||
            normalizedName.startsWith("journal_images/") ||
            normalizedName.startsWith("cover_images/");
        if (isImageFile &&
            File(actualFilePath).existsSync() &&
            !overwriteImages) {
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
        final String normalizedName = filename.replaceAll('\\', '/');

        String? extractLegacyDirPath(String prefix, String baseDir) {
          final int idx = normalizedName.indexOf(prefix);
          if (idx < 0) return null;
          final String relativePath =
              normalizedName.substring(idx + prefix.length);
          return p.join(baseDir, relativePath);
        }

        final noteDirPath =
            extractLegacyDirPath('images/note_images/', noteImageDir) ??
                extractLegacyDirPath('note_images/', noteImageDir);
        final journalDirPath =
            extractLegacyDirPath('images/journal_images/', journalImageDir) ??
                extractLegacyDirPath('journal_images/', journalImageDir);
        final coverDirPath =
            extractLegacyDirPath('images/cover_images/', coverImageDir) ??
                extractLegacyDirPath('cover_images/', coverImageDir);
        final markdownDirPath =
            extractLegacyDirPath('notes/journal/', markdownDir);
        final noteMarkdownDirPath =
            extractLegacyDirPath('notes/note/', noteMarkdownDir);

        if (noteDirPath != null) {
          dirPath = Directory(noteDirPath);
        } else if (journalDirPath != null) {
          dirPath = Directory(journalDirPath);
        } else if (coverDirPath != null) {
          dirPath = Directory(coverDirPath);
        } else if (markdownDirPath != null) {
          dirPath = Directory(markdownDirPath);
        } else if (noteMarkdownDirPath != null) {
          dirPath = Directory(noteMarkdownDirPath);
        } else {
          dirPath = Directory(p.join(localRootDirPath, filename));
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

  static Archive _decodeZipArchiveRobustly(List<int> bytes) {
    try {
      return ZipDecoder().decodeBytes(bytes);
    } catch (e) {
      AppLog.warn('标准ZIP解码失败，尝试提取有效ZIP段: $e');
    }

    final extracted = _extractZipPayload(bytes);
    if (extracted != null) {
      try {
        return ZipDecoder().decodeBytes(extracted);
      } catch (e) {
        AppLog.warn('提取ZIP段后仍解码失败: $e');
      }
    }

    throw const FormatException(
        'Could not find End of Central Directory Record');
  }

  static Uint8List? _extractZipPayload(List<int> bytes) {
    if (bytes.length < 4) return null;

    final int start = _findSignature(bytes, const [0x50, 0x4B, 0x03, 0x04]);
    if (start < 0) return null;

    final int eocd = _findLastSignature(bytes, const [0x50, 0x4B, 0x05, 0x06]);
    if (eocd < 0 || eocd + 22 > bytes.length) return null;

    final int commentLen = bytes[eocd + 20] | (bytes[eocd + 21] << 8);
    final int endExclusive = eocd + 22 + commentLen;
    if (endExclusive > bytes.length || endExclusive <= start) return null;

    return Uint8List.fromList(bytes.sublist(start, endExclusive));
  }

  static int _findSignature(List<int> bytes, List<int> sig) {
    for (int i = 0; i <= bytes.length - sig.length; i++) {
      bool ok = true;
      for (int j = 0; j < sig.length; j++) {
        if (bytes[i + j] != sig[j]) {
          ok = false;
          break;
        }
      }
      if (ok) return i;
    }
    return -1;
  }

  static int _findLastSignature(List<int> bytes, List<int> sig) {
    for (int i = bytes.length - sig.length; i >= 0; i--) {
      bool ok = true;
      for (int j = 0; j < sig.length; j++) {
        if (bytes[i + j] != sig[j]) {
          ok = false;
          break;
        }
      }
      if (ok) return i;
    }
    return -1;
  }

  /// 获取远程所有备份文件列表，包括手动和自动
  static Future<List<dav_client.File>> getAllBackupFiles() async {
    List<dav_client.File> files = [];

    final List<String> backupDirs =
        await WebDavUtil.getRemoteBackupDirPathsForRead();
    if (backupDirs.isEmpty) {
      AppLog.info("远程备份路径为空");
      return [];
    }

    for (final backupDir in backupDirs) {
      files.addAll(await _safeReadRemoteDir(backupDir));
      files.addAll(await _safeReadRemoteDir("$backupDir/automatic"));
    }

    // 去除目录
    files.removeWhere(
        (element) => element.isDir ?? element.path?.endsWith("/") ?? false);

    AppLog.info("获取完毕，共${files.length}个文件");
    files.sort((a, b) => b.mTime.toString().compareTo(a.mTime.toString()));
    return files;
  }

  static Future<List<dav_client.File>> _safeReadRemoteDir(
      String dirPath) async {
    try {
      return await WebDavUtil.client.readDir(dirPath);
    } catch (_) {
      return [];
    }
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
    String dirPath = p.join(
      (await getApplicationSupportDirectory()).path,
      'backup_before_restore',
    );
    Directory(dirPath).createSync();
    return dirPath;
  }
}
