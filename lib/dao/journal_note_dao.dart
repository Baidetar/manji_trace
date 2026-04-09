import 'package:manji_trace/models/journal_note.dart';
import 'package:manji_trace/models/params/page_params.dart';
import 'package:manji_trace/models/relative_local_image.dart';
import 'package:manji_trace/models/enum/note_type.dart';
import 'package:manji_trace/utils/sqlite_util.dart';
import 'package:manji_trace/utils/log.dart';
import 'package:manji_trace/utils/time_util.dart';
import 'package:manji_trace/utils/journal_markdown_util.dart';
import 'package:manji_trace/dao/image_dao.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class JournalNoteDao {
  static Database get database => SqliteUtil.database;

  // 创建表
  static Future<void> createTable() async {
    AppLog.info('sql: create table journal_note');
    await database.execute('''
    CREATE TABLE IF NOT EXISTS journal_note (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      title       TEXT NOT NULL DEFAULT '',
      content     TEXT NOT NULL DEFAULT '',
      images      TEXT NOT NULL DEFAULT '[]',
      create_time TEXT,
      update_time TEXT
    );
    ''');
    // 添加images列（如果不存在）
    await addColumnImages();
    await addColumnMdRelPath();
    await addColumnContentDigest();
    await addColumnSummary();
    await migrateLegacyContentToMarkdown();
  }

  // 添加images列
  static Future<void> addColumnImages() async {
    await SqliteUtil.addColumnName(
      tableName: 'journal_note',
      columnName: 'images',
      columnType: 'TEXT NOT NULL DEFAULT \'[]\'',
      logName: 'addColumnImagesToJournalNote',
    );
  }

  static Future<void> addColumnMdRelPath() async {
    await SqliteUtil.addColumnName(
      tableName: 'journal_note',
      columnName: 'md_rel_path',
      columnType: 'TEXT NOT NULL DEFAULT \'\'',
      logName: 'addColumnMdRelPathToJournalNote',
    );
  }

  static Future<void> addColumnContentDigest() async {
    await SqliteUtil.addColumnName(
      tableName: 'journal_note',
      columnName: 'content_digest',
      columnType: 'TEXT NOT NULL DEFAULT \'\'',
      logName: 'addColumnContentDigestToJournalNote',
    );
  }

  static Future<void> addColumnSummary() async {
    await SqliteUtil.addColumnName(
      tableName: 'journal_note',
      columnName: 'summary',
      columnType: 'TEXT NOT NULL DEFAULT \'\'',
      logName: 'addColumnSummaryToJournalNote',
    );
  }

  static Future<void> migrateLegacyContentToMarkdown() async {
    final List<Map<String, Object?>> rows = await database.rawQuery('''
      SELECT id, content, create_time, md_rel_path
      FROM journal_note
      WHERE content IS NOT NULL
        AND length(trim(content)) > 0
        AND (md_rel_path IS NULL OR md_rel_path = '')
      ORDER BY id ASC
    ''');

    if (rows.isEmpty) {
      return;
    }

    int migratedCount = 0;
    for (final row in rows) {
      final int id = row['id'] as int? ?? 0;
      if (id <= 0) {
        continue;
      }
      final String content = row['content'] as String? ?? '';
      if (content.trim().isEmpty) {
        continue;
      }
      final String createTime = row['create_time'] as String? ?? '';
      final String oldRelPath = row['md_rel_path'] as String? ?? '';

      try {
        final meta = await JournalMarkdownUtil.writeMarkdown(
          noteId: id,
          createTime: createTime,
          content: content,
          preferredRelativePath: oldRelPath,
        );
        await database.update(
          'journal_note',
          {
            'md_rel_path': meta.relativePath,
            'content_digest': meta.digest,
            'summary': meta.summary,
          },
          where: 'id = ?',
          whereArgs: [id],
        );
        migratedCount++;
      } catch (e) {
        AppLog.warn('迁移日记Markdown失败(id=$id): $e');
      }
    }

    if (migratedCount > 0) {
      AppLog.info('已迁移历史日记到Markdown: $migratedCount');
    }
  }

  // map转为对象
  static Future<JournalNote> row2bean(Map row) async {
    int noteId = row['id'] as int;
    List<RelativeLocalImage> images = await ImageDao.getRelativeLocalImgsByNoteId(noteId, noteType: NoteType.journal);
    final String dbContent = row['content'] as String? ?? "";
    final String mdRelPath = row['md_rel_path'] as String? ?? "";
    final String? mdContent = await JournalMarkdownUtil.readMarkdown(mdRelPath);
    final String storedDigest = row['content_digest'] as String? ?? '';
    if (mdRelPath.isNotEmpty && mdContent == null) {
      AppLog.warn('日记Markdown文件缺失，已回退DB内容: id=$noteId, path=$mdRelPath');
    } else if (mdContent != null && storedDigest.isNotEmpty) {
      final String actualDigest = JournalMarkdownUtil.buildDigest(mdContent);
      if (actualDigest != storedDigest) {
        AppLog.warn('日记Markdown摘要校验不一致: id=$noteId, path=$mdRelPath');
      }
    }
    
    return JournalNote(
      id: noteId,
      title: row['title'] as String? ?? "",
      content: mdContent ?? dbContent,
      relativeLocalImages: images,
      createTime: row['create_time'] as String? ?? "",
      updateTime: row['update_time'] as String? ?? "",
    );
  }

  // 获取所有独立笔记，分页
  static Future<List<JournalNote>> getAllNotes(
      {required PageParams pageParams, String? searchKeyword = ""}) async {
    AppLog.info("sql: getAllJournalNotes");
    List<JournalNote> notes = [];

    String? where;
    List<Object?>? whereArgs;
    if (searchKeyword != null && searchKeyword.trim().isNotEmpty) {
      where =
        "title LIKE ? ESCAPE '\\' OR summary LIKE ? ESCAPE '\\' OR content LIKE ? ESCAPE '\\'";
      final String likeKeyword = _buildLikeKeyword(searchKeyword);
      whereArgs = [likeKeyword, likeKeyword, likeKeyword];
    }

    // String whereClause = "";
    // if (searchKeyword != null && searchKeyword.isNotEmpty) {
    //   whereClause =
    //       "where title like '%$searchKeyword%' or content like '%$searchKeyword%'";
    // }

    final rows = await database.query(
      'journal_note',
      where: where,
      whereArgs: whereArgs,
      orderBy: 'create_time desc',
      limit: pageParams.pageSize,
      offset: pageParams.getOffset(),
    );

    for (final row in rows) {
      notes.add(await row2bean(row));
    }

    return notes;
  }

  // 获取笔记总数
  static Future<int> getNoteCount({String? searchKeyword = ""}) async {
    AppLog.info("sql: getNoteCount");
    String whereClause = "";
    List<Object?> whereArgs = [];
    if (searchKeyword != null && searchKeyword.isNotEmpty) {
      whereClause =
          "where title LIKE ? ESCAPE '\\' OR summary LIKE ? ESCAPE '\\' OR content LIKE ? ESCAPE '\\'";
      final String likeKeyword = _buildLikeKeyword(searchKeyword);
      whereArgs = [likeKeyword, likeKeyword, likeKeyword];
    }

    final List<Map<String, Object?>> list = await database.rawQuery(
      'select count(*) cnt from journal_note ${whereClause.isEmpty ? "" : whereClause}',
      whereArgs,
    );
    return list[0]["cnt"] as int;
  }

  // 根据ID获取笔记
  static Future<JournalNote?> getNoteById(int id) async {
    AppLog.info("sql: getNoteById");
    List<Map<String, Object?>> list = await database.query(
      'journal_note',
      where: 'id = ?',
      whereArgs: [id],
    );

    if (list.isEmpty) {
      return null;
    }

    return row2bean(list[0]);
  }

  // 插入笔记
  static Future<int> insertNote(JournalNote note) async {
    AppLog.info("sql: insertNote");
    String now = TimeUtil.getDateTimeNowStr();
    String createTime = note.createTime.isEmpty ? now : note.createTime;
    int noteId = await database.insert(
      'journal_note',
      {
        'title': note.title,
        'content': note.content,
        'summary': JournalMarkdownUtil.buildSummary(note.content),
        'create_time': createTime,
        'update_time': now,
      },
    );

    await _saveMarkdownMeta(
      noteId: noteId,
      createTime: createTime,
      content: note.content,
    );
    return noteId;
  }

  // 更新笔记
  static Future<int> updateNote(JournalNote note) async {
    AppLog.info("sql: updateNote");
    String now = TimeUtil.getDateTimeNowStr();
    final String oldRelPath = await _getMdRelPathById(note.id);
    final meta = await JournalMarkdownUtil.writeMarkdown(
      noteId: note.id,
      createTime: note.createTime,
      content: note.content,
      preferredRelativePath: oldRelPath,
    );

    int count = await database.update(
      'journal_note',
      {
        'title': note.title,
        'content': note.content,
        'md_rel_path': meta.relativePath,
        'content_digest': meta.digest,
        'summary': meta.summary,
        'create_time': note.createTime,
        'update_time': now,
      },
      where: 'id = ?',
      whereArgs: [note.id],
    );
    return count;
  }

  // 删除笔记
  static Future<int> deleteNote(int id) async {
    AppLog.info("sql: deleteNote");
    final String relPath = await _getMdRelPathById(id);
    await JournalMarkdownUtil.deleteMarkdown(relPath);
    // 先删除图片
    await database.delete(
      'image',
      where: 'note_id = ? and note_type = ?',
      whereArgs: [id, NoteType.journal.value],
    );

    int count = await database.delete(
      'journal_note',
      where: 'id = ?',
      whereArgs: [id],
    );
    return count;
  }

  // 删除多个笔记
  static Future<int> deleteNotes(List<int> ids) async {
    AppLog.info("sql: deleteNotes");
    if (ids.isEmpty) {
      return 0;
    }
    final String placeholders = List.filled(ids.length, '?').join(',');

    final List<Map<String, Object?>> rows = await database.rawQuery(
      'SELECT md_rel_path FROM journal_note WHERE id in ($placeholders)',
      ids,
    );
    for (final row in rows) {
      final String relPath = row['md_rel_path'] as String? ?? '';
      await JournalMarkdownUtil.deleteMarkdown(relPath);
    }

    // 先删除图片
    await database.delete(
      'image',
      where: 'note_id in ($placeholders) and note_type = ?',
      whereArgs: [...ids, NoteType.journal.value],
    );

    int count = await database.delete(
      'journal_note',
      where: 'id in ($placeholders)',
      whereArgs: ids,
    );
    return count;
  }

  static Future<void> _saveMarkdownMeta({
    required int noteId,
    required String createTime,
    required String content,
  }) async {
    final meta = await JournalMarkdownUtil.writeMarkdown(
      noteId: noteId,
      createTime: createTime,
      content: content,
    );
    await database.update(
      'journal_note',
      {
        'md_rel_path': meta.relativePath,
        'content_digest': meta.digest,
        'summary': meta.summary,
      },
      where: 'id = ?',
      whereArgs: [noteId],
    );
  }

  static Future<String> _getMdRelPathById(int id) async {
    final rows = await database.query(
      'journal_note',
      columns: ['md_rel_path'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) {
      return '';
    }
    return rows.first['md_rel_path'] as String? ?? '';
  }

  static String _buildLikeKeyword(String keyword) {
    final String escaped = keyword
        .replaceAll('\\', '\\\\')
        .replaceAll('%', '\\%')
        .replaceAll('_', '\\_');
    return '%${escaped.trim()}%';
  }
}
