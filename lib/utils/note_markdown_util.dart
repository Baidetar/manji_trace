import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:manji_trace/utils/log.dart';
import 'package:manji_trace/utils/sqlite_util.dart';
import 'package:path/path.dart' as p;

class NoteMarkdownMeta {
  final String relativePath;
  final String digest;
  final String summary;

  const NoteMarkdownMeta({
    required this.relativePath,
    required this.digest,
    required this.summary,
  });
}

class NoteMarkdownUtil {
  static const String _rootRelative = 'notes/note';
  static const int _maxCacheEntries = 300;
  static final Map<String, _MarkdownCacheEntry> _cache = {};

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
    text = text.replaceAll(RegExp(r'```[\s\S]*?```'), ' ');
    text = text.replaceAll(RegExp(r'`[^`]*`'), ' ');
    text = text.replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), ' ');
    text = text.replaceAll(RegExp(r'\[([^\]]*)\]\([^)]*\)'), r'$1');
    text = text.replaceAll(
        RegExp(r'^\s{0,3}(#{1,6}|>|-\s\[.?\]|[-*+])\s*', multiLine: true), '');
    text = text.replaceAll(RegExp(r'[*_~]+'), '');

    final String trimmed = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (trimmed.length <= maxLen) {
      return trimmed;
    }
    return '${trimmed.substring(0, maxLen).trimRight()}...';
  }

  static Future<NoteMarkdownMeta> writeMarkdown({
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
    final int modifiedMs = (await file.stat()).modified.millisecondsSinceEpoch;
    _putCache(relativePath, content, modifiedMs);

    return NoteMarkdownMeta(
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
        _cache.remove(relativePath);
        return null;
      }
      final int modifiedMs =
          (await file.stat()).modified.millisecondsSinceEpoch;
      final _MarkdownCacheEntry? cached = _cache[relativePath];
      if (cached != null && cached.modifiedMs == modifiedMs) {
        return cached.content;
      }
      final String content = await file.readAsString();
      _putCache(relativePath, content, modifiedMs);
      return content;
    } catch (e) {
      AppLog.warn('读取笔记Markdown失败($relativePath): $e');
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
      _cache.remove(relativePath);
    } catch (e) {
      AppLog.warn('删除笔记Markdown失败($relativePath): $e');
    }
  }

  static void _putCache(String relativePath, String content, int modifiedMs) {
    if (_cache.length >= _maxCacheEntries &&
        !_cache.containsKey(relativePath)) {
      _cache.remove(_cache.keys.first);
    }
    _cache[relativePath] = _MarkdownCacheEntry(
      content: content,
      modifiedMs: modifiedMs,
    );
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

class _MarkdownCacheEntry {
  final String content;
  final int modifiedMs;

  const _MarkdownCacheEntry({required this.content, required this.modifiedMs});
}
