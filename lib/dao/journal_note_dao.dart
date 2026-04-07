import 'package:manji_trace/models/journal_note.dart';
import 'package:manji_trace/models/params/page_params.dart';
import 'package:manji_trace/models/relative_local_image.dart';
import 'package:manji_trace/models/enum/note_type.dart';
import 'package:manji_trace/utils/sqlite_util.dart';
import 'package:manji_trace/utils/log.dart';
import 'package:manji_trace/utils/time_util.dart';
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

  // map转为对象
  static Future<JournalNote> row2bean(Map row) async {
    int noteId = row['id'] as int;
    List<RelativeLocalImage> images = await ImageDao.getRelativeLocalImgsByNoteId(noteId, noteType: NoteType.journal);
    
    return JournalNote(
      id: noteId,
      title: row['title'] as String? ?? "",
      content: row['content'] as String? ?? "",
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
    if (searchKeyword != null && searchKeyword.trim().isNotEmpty) {
        where = "title LIKE '%$searchKeyword%' OR content LIKE '%$searchKeyword%'";
    }

    // String whereClause = "";
    // if (searchKeyword != null && searchKeyword.isNotEmpty) {
    //   whereClause =
    //       "where title like '%$searchKeyword%' or content like '%$searchKeyword%'";
    // }

    final rows = await database.query(
      'journal_note',
      where: where,
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
    if (searchKeyword != null && searchKeyword.isNotEmpty) {
      whereClause =
          "where title like '%$searchKeyword%' or content like '%$searchKeyword%'";
    }

    List<Map<String, Object?>> list = await database.rawQuery(
      'select count(*) cnt from journal_note ${whereClause.isEmpty ? "" : whereClause}',
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
        'create_time': createTime,
        'update_time': now,
      },
    );
    return noteId;
  }

  // 更新笔记
  static Future<int> updateNote(JournalNote note) async {
    AppLog.info("sql: updateNote");
    String now = TimeUtil.getDateTimeNowStr();
    int count = await database.update(
      'journal_note',
      {
        'title': note.title,
        'content': note.content,
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
    String idList = ids.join(',');

    // 先删除图片
    await database.delete(
      'image',
      where: 'note_id in ($idList) and note_type = ?',
      whereArgs: [NoteType.journal.value],
    );

    int count = await database.delete(
      'journal_note',
      where: 'id in ($idList)',
    );
    return count;
  }
}
