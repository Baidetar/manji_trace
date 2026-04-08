import 'dart:io';

import 'package:path/path.dart';
import 'package:manji_trace/utils/log.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class ImageUtil {
  static ImageUtil? _instance;

  ImageUtil._();

  static late String noteImageRootDirPath;
  static late String journalImageRootDirPath;
  static late String coverImageRootDirPath;

  // 私有目录子文件夹名称
  static const String _noteImageFolder = "note_images";
  static const String _journalImageFolder = "journal_images";
  static const String _coverImageFolder = "cover_images";

  /// 初始化私有目录，应该在应用启动时调用一次
  static Future<void> initializePrivateDirs() async {
    try {
      final documentDir = await getApplicationDocumentsDirectory();
      final baseDir = await _getImageBaseDir();

      await _migrateLegacyImageDirsIfNeeded(
        oldBasePath: documentDir.path,
        newBasePath: baseDir.path,
      );

      noteImageRootDirPath =
          p.join(baseDir.path, _noteImageFolder) + p.separator;
      journalImageRootDirPath =
          p.join(baseDir.path, _journalImageFolder) + p.separator;
      coverImageRootDirPath =
          p.join(baseDir.path, _coverImageFolder) + p.separator;

      // 创建目录如果不存在
      await Directory(noteImageRootDirPath).create(recursive: true);
      await Directory(journalImageRootDirPath).create(recursive: true);
      await Directory(coverImageRootDirPath).create(recursive: true);

      AppLog.info("图片私有目录初始化完成");
      AppLog.info("笔记图片目录: $noteImageRootDirPath");
      AppLog.info("日记图片目录: $journalImageRootDirPath");
      AppLog.info("封面图片目录: $coverImageRootDirPath");
    } catch (e) {
      AppLog.error("初始化图片私有目录失败: $e");
      rethrow;
    }
  }

  static Future<Directory> _getImageBaseDir() async {
    if (Platform.isAndroid) {
      final externalDir = await getExternalStorageDirectory();
      if (externalDir != null) {
        return externalDir;
      }
    }
    return getApplicationDocumentsDirectory();
  }

  static Future<void> _migrateLegacyImageDirsIfNeeded({
    required String oldBasePath,
    required String newBasePath,
  }) async {
    if (!Platform.isAndroid || oldBasePath == newBasePath) {
      return;
    }

    await _migrateOneImageDir(_noteImageFolder, oldBasePath, newBasePath);
    await _migrateOneImageDir(_journalImageFolder, oldBasePath, newBasePath);
    await _migrateOneImageDir(_coverImageFolder, oldBasePath, newBasePath);
  }

  static Future<void> _migrateOneImageDir(
    String folder,
    String oldBasePath,
    String newBasePath,
  ) async {
    final oldDir = Directory(p.join(oldBasePath, folder));
    if (!await oldDir.exists()) {
      return;
    }

    final newDir = Directory(p.join(newBasePath, folder));
    if (!await newDir.exists()) {
      await newDir.create(recursive: true);
    }

    await for (final entity
        in oldDir.list(recursive: true, followLinks: false)) {
      if (entity is! File) {
        continue;
      }

      final relativePath = p.relative(entity.path, from: oldDir.path);
      final targetPath = p.join(newDir.path, relativePath);
      final targetFile = File(targetPath);
      if (await targetFile.exists()) {
        continue;
      }
      await Directory(p.dirname(targetPath)).create(recursive: true);
      await entity.copy(targetPath);
    }
  }

  static getInstance() async {
    if (_instance == null) {
      await initializePrivateDirs();
      _instance = ImageUtil._();
    }
    return _instance;
  }

  /// 获取笔记图片根目录路径
  static String getNoteImageRootDirPath() {
    return noteImageRootDirPath;
  }

  static String getJournalImageRootDirPath() {
    return journalImageRootDirPath;
  }

  /// 获取封面图片根目录路径
  static String getCoverImageRootDirPath() {
    return coverImageRootDirPath;
  }

  static bool hasNoteImageRootDirPath() {
    return noteImageRootDirPath.isNotEmpty;
  }

  static bool hasJournalImageRootDirPath() {
    return journalImageRootDirPath.isNotEmpty;
  }

  static bool hasCoverImageRootDirPath() {
    return coverImageRootDirPath.isNotEmpty;
  }

  static String getRelativeCoverImagePath(String absoluteImagePath) {
    // 绝对路径去掉根路径，得到相对路径
    AppLog.info("将绝对路径转换为相对路径: $absoluteImagePath");
    String relativeImagePath =
        _removeRootDirPath(absoluteImagePath, coverImageRootDirPath);
    AppLog.info("相对路径: $relativeImagePath");
    return relativeImagePath;
  }

  static String getRelativeNoteImagePath(String absoluteImagePath) {
    // 绝对路径去掉根目录，得到相对路径
    String relativeImagePath =
        _removeRootDirPath(absoluteImagePath, noteImageRootDirPath);
    return relativeImagePath;
  }

  static String getRelativeJournalImagePath(String absoluteImagePath) {
    String relativeImagePath =
        _removeRootDirPath(absoluteImagePath, journalImageRootDirPath);
    return relativeImagePath;
  }

  static String _removeRootDirPath(String path, String rootDirPath) {
    // 移除根目录路径，保留相对路径
    // 在Android上，文件已经在私有目录中，所以能获取完整相对路径
    String relativePath = path.replaceFirst(rootDirPath, "");
    // 确保相对路径以/开头
    if (!relativePath.startsWith('/')) {
      relativePath = '/$relativePath';
    }
    return relativePath;
  }

  static String getAbsoluteNoteImagePath(String relativeImagePath) {
    String absolutePath = noteImageRootDirPath + relativeImagePath;
    absolutePath = _fixPathSeparator(absolutePath);
    return absolutePath;
  }

  static String getAbsoluteJournalImagePath(String relativeImagePath) {
    String absolutePath = journalImageRootDirPath + relativeImagePath;
    absolutePath = _fixPathSeparator(absolutePath);
    if (!File(absolutePath).existsSync()) {
      final String legacyPath = noteImageRootDirPath + relativeImagePath;
      final String fixedLegacyPath = _fixPathSeparator(legacyPath);
      if (File(fixedLegacyPath).existsSync()) {
        return fixedLegacyPath;
      }
    }
    return absolutePath;
  }

  static String getAbsoluteCoverImagePath(String relativeImagePath) {
    String absolutePath = coverImageRootDirPath + relativeImagePath;
    absolutePath = _fixPathSeparator(absolutePath);
    return absolutePath;
  }

  static String _fixPathSeparator(String path) {
    path = path.replaceAll("/", separator);
    path = path.replaceAll("\\", separator);
    return path;
  }
}
