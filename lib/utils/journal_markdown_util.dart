import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:manji_trace/utils/log.dart';
import 'package:manji_trace/utils/sqlite_util.dart';
import 'package:path/path.dart' as p;

class JournalMarkdownMeta {
  final String relativePath;
  final String digest;
  final String summary;

  const JournalMarkdownMeta({
    required this.relativePath,
    required this.digest,
    required this.summary,
  });
}

class JournalMarkdownUtil {
  static const String _rootRelative = 'notes/journal';

  static Future<String> getMarkdownRootDirPath() async {
    final String root = await SqliteUtil.getLocalRootDirPath();
    return p.join(root, _rootRelative);
  }

  static String buildRelativePath({
    required int noteId,
    required String createTime,
  }) {
    final DateTime dt = _parseCreateTime(createTime);
    final String year = dt.year.toString().padLeft(4, '0');
    final String month = dt.month.toString().padLeft(2, '0');
    return '$_rootRelative/$year/$month/$noteId.md';
  }

  static String buildDigest(String content) {
    return sha256.convert(utf8.encode(content)).toString();
  }

  static String buildSummary(String content, {int maxLen = 120}) {
    String text = content;
    text =
        text.replaceAll(RegExp(r'```[\s\S]*?```'), ' '); // Remove code blocks.
    text = text.replaceAll(RegExp(r'`[^`]*`'), ' '); // Remove inline code.
    text =
        text.replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), ' '); // Remove images.
    text = text.replaceAll(
        RegExp(r'\[([^\]]*)\]\([^)]*\)'), r'$1'); // Keep link text.
    text = text.replaceAll(
        RegExp(r'^\s{0,3}(#{1,6}|>|-\s\[.?\]|[-*+])\s*', multiLine: true), '');
    text = text.replaceAll(RegExp(r'[*_~]+'), '');

    final String trimmed = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (trimmed.length <= maxLen) {
      return trimmed;
    }
    return '${trimmed.substring(0, maxLen).trimRight()}...';
  }

  static Future<JournalMarkdownMeta> writeMarkdown({
    required int noteId,
    required String createTime,
    required String content,
    String? preferredRelativePath,
  }) async {
    final String relativePath = (preferredRelativePath != null &&
            preferredRelativePath.trim().isNotEmpty)
        ? preferredRelativePath.trim().replaceAll('\\', '/')
        : buildRelativePath(noteId: noteId, createTime: createTime);

    final File file = await _getFileByRelativePath(relativePath);
    await file.parent.create(recursive: true);
    await file.writeAsString(content, flush: true);

    return JournalMarkdownMeta(
      relativePath: relativePath,
      digest: buildDigest(content),
      summary: buildSummary(content),
    );
  }

  static Future<String?> readMarkdown(String relativePath) async {
    if (relativePath.trim().isEmpty) {
      return null;
    }
    try {
      final File file = await _getFileByRelativePath(relativePath);
      if (!await file.exists()) {
        return null;
      }
      return await file.readAsString();
    } catch (e) {
      AppLog.warn('读取日记Markdown失败($relativePath): $e');
      return null;
    }
  }

  static Future<void> deleteMarkdown(String relativePath) async {
    if (relativePath.trim().isEmpty) {
      return;
    }
    try {
      final File file = await _getFileByRelativePath(relativePath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      AppLog.warn('删除日记Markdown失败($relativePath): $e');
    }
  }

  static Future<File> _getFileByRelativePath(String relativePath) async {
    final String root = await SqliteUtil.getLocalRootDirPath();
    final String rel = relativePath.replaceAll('\\', '/');
    return File(p.join(root, rel));
  }

  static DateTime _parseCreateTime(String createTime) {
    final String text = createTime.trim();
    if (text.isEmpty) {
      return DateTime.now();
    }
    final DateTime? dt = DateTime.tryParse(
      text.contains('T') ? text : text.replaceFirst(' ', 'T'),
    );
    return dt ?? DateTime.now();
  }
}
