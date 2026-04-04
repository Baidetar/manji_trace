import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:manji_trace/utils/log.dart';
import 'package:manji_trace/utils/image_util.dart';
import 'package:path/path.dart' as p;

Future<String?> selectFile() async {
  FilePickerResult? result = await FilePicker.platform.pickFiles();
  if (result != null) {
    PlatformFile file = result.files.first;
    AppLog.info("选择的文件：${file.name}");
    return file.path;
  } else {
    // 未选择文件
    return null;
  }
}

Future<String?> selectDirectory() async {
  String? selectedDirectory = await FilePicker.platform.getDirectoryPath();
  if (selectedDirectory != null) {
    AppLog.info("选择的目录：$selectedDirectory");
    return selectedDirectory;
  } else {
    // 未选择目录
    return null;
  }
}

/// 选择图片并复制到应用私有目录（用于笔记）
Future<String?> selectAndCopyNoteImage() async {
  FilePickerResult? result = await FilePicker.platform.pickFiles(
    type: FileType.image,
  );
  
  if (result != null && result.files.isNotEmpty) {
    PlatformFile file = result.files.first;
    AppLog.info("选择的图片：${file.name}");
    return await _copyImageToPrivateDir(file.path!, isNoteImage: true);
  }
  return null;
}

/// 选择图片并复制到应用私有目录（用于封面）
Future<String?> selectAndCopyCoverImage() async {
  FilePickerResult? result = await FilePicker.platform.pickFiles(
    type: FileType.image,
  );
  
  if (result != null && result.files.isNotEmpty) {
    PlatformFile file = result.files.first;
    AppLog.info("选择的图片：${file.name}");
    return await _copyImageToPrivateDir(file.path!, isNoteImage: false);
  }
  return null;
}

/// 复制图片到应用私有目录
/// 返回相对路径（用于存储到数据库）
Future<String?> _copyImageToPrivateDir(String sourcePath, {required bool isNoteImage}) async {
  try {
    final sourceFile = File(sourcePath);
    if (!await sourceFile.exists()) {
      AppLog.error("源图片文件不存在：$sourcePath");
      return null;
    }

    // 获取目标目录
    final targetDirPath = isNoteImage 
        ? ImageUtil.getNoteImageRootDirPath()
        : ImageUtil.getCoverImageRootDirPath();
    
    // 生成唯一的文件名（使用时间戳+原始名称）
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final originalName = p.basename(sourcePath);
    final fileName = '${timestamp}_$originalName';
    final targetPath = p.join(targetDirPath, fileName);

    // 复制文件
    await sourceFile.copy(targetPath);
    AppLog.info("图片已复制到私有目录：$targetPath");

    // 返回相对路径（用于存储到数据库）
    final relativePath = ImageUtil.getRelativeNoteImagePath(targetPath);
    return relativePath;
  } catch (e) {
    AppLog.error("复制图片到私有目录失败：$e");
    return null;
  }
}
