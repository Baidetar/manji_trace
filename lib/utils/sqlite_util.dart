import 'dart:io';
import 'dart:async';
import 'package:path_provider/path_provider.dart';
import 'package:manji_trace/utils/log.dart';
import 'package:manji_trace/utils/image_util.dart';
import 'package:manji_trace/utils/platform.dart';
import 'package:manji_trace/utils/sync_change_log_util.dart';
import 'package:manji_trace/utils/episode.dart';
import 'package:manji_trace/utils/escape_util.dart';
import 'package:manji_trace/dao/anime_dao.dart';
import 'package:manji_trace/dao/anime_label_dao.dart';
import 'package:manji_trace/dao/anime_series_dao.dart';
import 'package:manji_trace/dao/episode_desc_dao.dart';
import 'package:manji_trace/dao/key_value_dao.dart';
import 'package:manji_trace/dao/label_dao.dart';
import 'package:manji_trace/dao/series_dao.dart';
import 'package:manji_trace/dao/journal_note_dao.dart';
import 'package:manji_trace/models/anime.dart';
import 'package:manji_trace/models/episode.dart';
import 'package:manji_trace/models/enum/note_type.dart';
import 'package:manji_trace/models/params/anime_sort_cond.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class SqliteUtil {
  // 单例模式
  static SqliteUtil? _instance;

  SqliteUtil._();

  static Future<SqliteUtil> getInstance() async {
    if (_instance == null) {
      database = await _initDatabase();
      _instance = SqliteUtil._();
    }
    return _instance!;
  }

  static const sqlFileName = 'mydb.db';
  static late Database database;
  static late String dbPath;
  static const dbVersion = 1;

  static Future<bool> ensureDBTable() async {
    await ImageUtil.getInstance();
    await SqliteUtil.getInstance();

    // 先创建表，再添加列
    await SqliteUtil.createTableEpisodeNote();
    await SqliteUtil.createTableImage();
    // 创建独立笔记表
    await JournalNoteDao.createTable();
    // 添加回顾号列
    await SqliteUtil.addColumnReviewNumberToHistoryAndNote();
    // 为动漫表添加列
    await SqliteUtil.addColumnInfoToAnime();

    // 创建动漫更新表
    await SqliteUtil.createTableUpdateRecord();
    // 创建键值对表
    await KeyValueDao.createTable();
    // 为动漫表增加评分列
    await SqliteUtil.addColumnRateToAnime();
    // 评分列支持半星
    await AnimeDao.doubleRateToSupportHalfStar();
    // 为动漫表增加起始集数列
    await SqliteUtil.addColumnEpisodeStartNumberToAnime();
    // 为动漫表增加集号是否从第1集计算
    await SqliteUtil.addColumnCalEpisodeNumberFromOneToAnime();
    // 为动漫表增加搜索源
    await AnimeDao.addColumnSourceForAnime();
    // 增加bangumi subjectId列
    await AnimeDao.addColumnBgmSubjectId();

    // 为笔记增加创建时间和修改时间列，主要用于评分时显示
    await SqliteUtil.addColumnTwoTimeToEpisodeNote();
    // 为图片表增加顺序列，支持自定义排序
    await SqliteUtil.addColumnOrderIdxToImage();
    // 为图片表增加笔记类型列，支持独立笔记
    await SqliteUtil.addColumnNoteTypeToImage();

    // 自动修复旧版日记图片与数据库映射
    await SqliteUtil.migrateOldImageData();
    await SqliteUtil.migrateJournalImageFilesToNewRoot();

    // 创建标签表、动漫标签表、集描述表
    await LabelDao.createTable();
    await LabelDao.addColumnOrder();
    await AnimeLabelDao.createTable();
    await EpisodeDescDao.createTable();
    // 创建系列表、动漫系列表
    await SeriesDao.createTable();
    await AnimeSeriesDao.createTable();

    // 创建增量同步变更日志基础设施（表+触发器）
    await SyncChangeLogUtil.ensureChangeLogInfra();

    return true;
  }

  static Future<String> getLocalRootDirPath() async {
    String rootPath;
    if (PlatformUtil.isMobile || Platform.isWindows) {
      rootPath = (await getApplicationSupportDirectory()).path;
    } else {
      throw ("未适配平台：${Platform.operatingSystem}");
    }
    return rootPath;
  }

  static Future<String> getDBPath() async {
    return "${await getLocalRootDirPath()}/$sqlFileName";
  }

  static Future<Database> _initDatabase() async {
    dbPath = await getDBPath();
    AppLog.info("💾 db path: $dbPath");

    if (PlatformUtil.isMobile) {
      return await openDatabase(
        dbPath,
        onCreate: _createDb,
        version: dbVersion,
      );
    } else if (Platform.isWindows) {
      return await databaseFactoryFfi.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          onCreate: _createDb,
          version: dbVersion,
        ),
      );
    } else {
      throw ("未适配平台：${Platform.operatingSystem}");
    }
  }

  static FutureOr<void> _createDb(Database db, int version) async {
    await _createInitTable(db);
    await _insertInitData(db);
  }

  static Future<void> _createInitTable(Database db) async {
    AppLog.info('init db');
    await db.execute('''
      CREATE TABLE tag (
          tag_name  TEXT    PRIMARY KEY NOT NULL,
          tag_order INTEGER
      );
      ''');
    await db.execute('''
      CREATE TABLE anime (
          anime_id            INTEGER PRIMARY KEY AUTOINCREMENT,
          anime_name          TEXT    NOT NULL,
          anime_episode_cnt   INTEGER NOT NULL,
          anime_desc          TEXT,
          tag_name            TEXT,
          last_mode_tag_time  TEXT,
          FOREIGN KEY (
              tag_name
          )
          REFERENCES tag (tag_name)
      );
      ''');
    await db.execute('''
      CREATE TABLE history (
          history_id     INTEGER PRIMARY KEY AUTOINCREMENT,
          date           TEXT,
          anime_id       INTEGER NOT NULL,
          episode_number INTEGER NOT NULL,
          FOREIGN KEY (
              anime_id
          )
          REFERENCES anime (anime_id)
      );
      ''');
    await db.execute('''
      CREATE INDEX index_anime_name ON anime (anime_name);
      ''');
    await db.execute('''
      CREATE INDEX index_date ON history (date);
      ''');
  }

  static Future<void> _insertInitData(Database db) async {
    await db.rawInsert('''
      insert into tag(tag_name, tag_order)
      values('收集', 0), ('旅途', 1), ('终点', 2), ('搁置', 3), ('放弃', 4);
    ''');
  }

  static Future<void> addColumnInfoToAnime() async {
    Map<String, String> columns = {};
    columns['anime_cover_url'] = 'TEXT';
    columns['premiere_time'] = 'TEXT';
    columns['name_another'] = 'TEXT';
    columns['name_ori'] = 'TEXT';
    columns['author_ori'] = 'TEXT';
    columns['area'] = 'TEXT';
    columns['play_status'] = 'TEXT';
    columns['category'] = 'TEXT';
    columns['production_company'] = 'TEXT';
    columns['official_site'] = 'TEXT';
    columns['anime_url'] = 'TEXT';
    columns['review_number'] = 'INTEGER';

    for (var entry in columns.entries) {
      var list = await database.rawQuery('''
        select * from sqlite_master where name = 'anime' and sql like '%${entry.key}%';
      ''');
      if (list.isEmpty) {
        await database.execute('''
          alter table anime
          add column ${entry.key} ${entry.value};
        ''').then((_) async {
          if (entry.key == 'review_number') {
            await database.rawUpdate('''
              update anime
              set review_number = 1
              where review_number is NULL;
            ''');
          }
        });
      }
    }
  }

  static Future<void> addColumnReviewNumberToHistoryAndNote() async {
    var list = await database.rawQuery('''
    select * from sqlite_master where name = 'history' and sql like '%review_number%';
    ''');
    if (list.isEmpty) {
      await database
          .execute('alter table history add column review_number INTEGER;');
      await database.rawUpdate(
          'update history set review_number = 1 where review_number is NULL;');
    }
    list = await database.rawQuery('''
    select * from sqlite_master where name = 'episode_note' and sql like '%review_number%';
    ''');
    if (list.isEmpty) {
      await database.execute(
          'alter table episode_note add column review_number INTEGER;');
      await database.rawUpdate(
          'update episode_note set review_number = 1 where review_number is NULL;');
    }
  }

  static Future<void> addColumnRateToAnime() async {
    var list = await database.rawQuery('''
    select * from sqlite_master where name = 'anime' and sql like '%rate%';
    ''');
    if (list.isEmpty) {
      await database.execute('alter table anime add column rate INTEGER;');
      await database.rawUpdate('update anime set rate = 0 where rate is NULL;');
    }
  }

  static Future<void> addColumnEpisodeStartNumberToAnime() async {
    await addColumnName(
      tableName: 'anime',
      columnName: 'episode_start_number',
      columnType: 'INTEGER',
      logName: 'addColumnEpisodeStartNumberToAnime',
    );
  }

  static Future<void> addColumnCalEpisodeNumberFromOneToAnime() async {
    await addColumnName(
      tableName: 'anime',
      columnName: 'cal_episode_number_from_one',
      columnType: 'INTEGER',
      logName: 'addColumnCalEpisodeNumberFromOneToAnime',
    );
  }

  static Future<void> addColumnName({
    required String tableName,
    required String columnName,
    required String columnType,
    dynamic initialValue,
    String logName = '',
    Function()? whenAddSuccess,
  }) async {
    var list = await database.rawQuery('''
      select * from sqlite_master where name = '$tableName' and sql like '%$columnName%';
      ''');
    if (list.isNotEmpty) return;
    AppLog.info("sql: $logName");
    await database.execute('''
      alter table $tableName
      add column $columnName $columnType;
    ''');

    if (initialValue != null) {
      await database.rawUpdate('''
        update $tableName
        set $columnName = $initialValue
        where $columnName is NULL;
      ''');
    }
    whenAddSuccess?.call();
  }

  static Future<void> addColumnTwoTimeToEpisodeNote() async {
    await addColumnName(
        tableName: 'episode_note',
        columnName: 'create_time',
        columnType: 'TEXT');
    await addColumnName(
        tableName: 'episode_note',
        columnName: 'update_time',
        columnType: 'TEXT');
  }

  static Future<void> createTableEpisodeNote() async {
    await database.execute('''
    CREATE TABLE IF NOT EXISTS episode_note (
      note_id        INTEGER PRIMARY KEY AUTOINCREMENT,
      anime_id       INTEGER NOT NULL,
      episode_number INTEGER NOT NULL,
      note_content   TEXT,
      FOREIGN KEY (anime_id) REFERENCES anime (anime_id)
    );
    ''');
  }

  static Future<void> createTableImage() async {
    await database.execute('''
    CREATE TABLE IF NOT EXISTS image (
      image_id          INTEGER  PRIMARY KEY AUTOINCREMENT,
      note_id           INTEGER,
      image_local_path  TEXT,
      image_url         TEXT,
      image_origin_name TEXT,
      FOREIGN KEY (note_id) REFERENCES episode_note (note_id)
    );
    ''');
  }

  static Future<int> insertNoteIdAndImageLocalPath(
      int noteId, String imageLocalPath, int orderIdx,
      {NoteType noteType = NoteType.episode}) async {
    AppLog.info(
        "sql: insertNoteIdAndLocalImg(noteId=$noteId, imageLocalPath=$imageLocalPath, orderIdx=$orderIdx, noteType=${noteType.value})");
    return await database.rawInsert('''
    insert into image (note_id, image_local_path, order_idx, note_type)
    values ($noteId, '$imageLocalPath', $orderIdx, ${noteType.value});
    ''');
  }

  static deleteLocalImageByImageId(int imageId) async {
    AppLog.info("sql: deleteLocalImageByImageId($imageId)");
    await database.rawDelete('delete from image where image_id = $imageId;');
  }

  static Future<void> addColumnNoteTypeToImage() async {
    await addColumnName(
      tableName: 'image',
      columnName: 'note_type',
      columnType: 'INTEGER',
      initialValue: 0,
      logName: 'addColumnNoteTypeToImage',
    );
  }

  static Future<void> createTableUpdateRecord() async {
    await database.execute('''
      CREATE TABLE IF NOT EXISTS update_record (
          id                 INTEGER PRIMARY KEY AUTOINCREMENT,
          anime_id           INTEGER NOT NULL,
          old_episode_cnt    INTEGER NOT NULL,
          new_episode_cnt    INTEGER NOT NULL,
          manual_update_time TEXT,
          FOREIGN KEY (
              anime_id
          )
          REFERENCES anime (anime_id)
      );
      ''');
  }

  static Future<void> addColumnOrderIdxToImage() async {
    await addColumnName(
        tableName: 'image', columnName: 'order_idx', columnType: 'INTEGER');
  }

  static Future<int> migrateOldImageData({
    bool includeAmbiguousConflicts = false,
  }) async {
    AppLog.info("sql: migrateOldImageData");
    String now = DateTime.now().toString().substring(0, 19);
    await database.rawUpdate('''
      UPDATE journal_note SET create_time = update_time 
      WHERE (create_time IS NULL OR create_time = '') AND (update_time IS NOT NULL AND update_time != '');
    ''');
    await database.rawUpdate('''
      UPDATE journal_note SET update_time = create_time 
      WHERE (update_time IS NULL OR update_time = '') AND (create_time IS NOT NULL AND create_time != '');
    ''');
    await database.rawUpdate('''
      UPDATE journal_note SET create_time = '$now', update_time = '$now' 
      WHERE (create_time IS NULL OR create_time = '') AND (update_time IS NULL OR update_time = '');
    ''');

    int movedCount = await database.rawUpdate('''
      UPDATE image SET note_type = ${NoteType.journal.value} 
      WHERE note_type = 0 AND note_id IN (SELECT id FROM journal_note) 
      AND note_id NOT IN (SELECT note_id FROM episode_note);
    ''');

    int duplicatedCount = 0;
    if (includeAmbiguousConflicts) {
      var conflictRows = await database.rawQuery('''
      SELECT * FROM image WHERE note_type = 0 AND note_id IN (SELECT id FROM journal_note) 
      AND note_id IN (SELECT note_id FROM episode_note);
    ''');

      for (var row in conflictRows) {
        var exist = await database.rawQuery('''
        SELECT image_id FROM image WHERE note_id = ${row['note_id']} 
        AND image_local_path = '${row['image_local_path']}' AND note_type = ${NoteType.journal.value}
      ''');
        if (exist.isEmpty) {
          await database.rawInsert('''
          INSERT INTO image (note_id, image_local_path, order_idx, note_type)
          VALUES (${row['note_id']}, '${row['image_local_path']}', ${row['order_idx'] ?? 0}, ${NoteType.journal.value});
        ''');
          duplicatedCount++;
        }
      }
    } else {
      AppLog.info('跳过歧义ID图片迁移，避免将番剧图片误挂到日记');
    }
    return movedCount + duplicatedCount;
  }

  static Future<int> cleanupMissingImageRows() async {
    AppLog.info("sql: cleanupMissingImageRows");
    final rows = await database.rawQuery(
      'SELECT image_id, image_local_path, note_type FROM image',
    );

    int removedCount = 0;
    for (final row in rows) {
      final int imageId = row['image_id'] as int? ?? 0;
      final String relativePath = row['image_local_path'] as String? ?? '';
      final int noteType = row['note_type'] as int? ?? NoteType.episode.value;
      if (imageId <= 0 || relativePath.isEmpty) {
        continue;
      }

      final String absolutePath = noteType == NoteType.journal.value
          ? ImageUtil.getAbsoluteJournalImagePath(relativePath)
          : ImageUtil.getAbsoluteNoteImagePath(relativePath);
      if (!File(absolutePath).existsSync()) {
        await database
            .rawDelete('DELETE FROM image WHERE image_id = ?', [imageId]);
        removedCount++;
      }
    }
    AppLog.info('清理无效图片记录完成: $removedCount');
    return removedCount;
  }

  static Future<int> migrateJournalImageFilesToNewRoot() async {
    AppLog.info("sql: migrateJournalImageFilesToNewRoot");
    final rows = await database.rawQuery('''
      SELECT image_local_path
      FROM image
      WHERE note_type = ${NoteType.journal.value}
    ''');

    int movedCount = 0;
    for (final row in rows) {
      final String relativePath = row['image_local_path'] as String? ?? '';
      if (relativePath.isEmpty) {
        continue;
      }

      final String legacyPath =
          ImageUtil.getAbsoluteNoteImagePath(relativePath);
      final String targetPath =
          ImageUtil.getAbsoluteJournalImagePath(relativePath);
      final legacyFile = File(legacyPath);
      final targetFile = File(targetPath);

      try {
        if (await targetFile.exists()) {
          if (await legacyFile.exists()) {
            try {
              await legacyFile.delete();
            } catch (_) {}
          }
          continue;
        }

        if (!await legacyFile.exists()) {
          continue;
        }

        await targetFile.parent.create(recursive: true);
        await legacyFile.copy(targetPath);
        try {
          await legacyFile.delete();
        } catch (_) {}
        movedCount++;
      } catch (e) {
        AppLog.warn('迁移日记图片失败($relativePath): $e');
      }
    }

    AppLog.info('日记图片文件迁移完成: $movedCount');
    return movedCount;
  }

  static T? firstRowColumnValue<T>(List<Map<String, Object?>> rows) {
    if (rows.isEmpty || rows.first.values.isEmpty) return null;
    final value = rows.first.values.first;
    return value is T ? value : null;
  }

  static Future<Anime> getAnimeByAnimeId(int animeId) async {
    var list = await database
        .rawQuery('select * from anime where anime_id = $animeId;');
    if (list.isEmpty) {
      return Anime(animeId: 0, animeName: "", animeEpisodeCnt: 0);
    }
    return await AnimeDao.row2Bean(list[0],
        queryCheckedEpisodeCnt: true, queryHasJoinedSeries: true);
  }

  static void insertHistoryItem(
      int animeId, int episodeNumber, String date, int reviewNumber) async {
    await database.rawInsert(
        'insert into history(date, anime_id, episode_number, review_number) values(\'$date\', $animeId, $episodeNumber, $reviewNumber);');
  }

  static void updateHistoryItem(
      int animeId, int episodeNumber, String date, int reviewNumber) async {
    await database.rawUpdate(
        'update history set date = \'$date\' where anime_id = $animeId and episode_number = $episodeNumber and review_number = $reviewNumber;');
  }

  static void deleteHistoryItemByAnimeIdAndEpisodeNumberAndReviewNumber(
      int animeId, int episodeNumber, int reviewNumber) async {
    await database.rawDelete(
        'delete from history where anime_id = $animeId and episode_number = $episodeNumber and review_number = $reviewNumber;');
  }

  static void insertTagName(String tagName, int tagOrder) async {
    await database.rawInsert(
        'insert into tag(tag_name, tag_order) values(\'$tagName\', $tagOrder);');
  }

  static void updateTagName(String oldTagName, String newTagName) async {
    await database.rawUpdate(
        'update tag set tag_name = \'$newTagName\' where tag_name = \'$oldTagName\';');
    await database.rawUpdate(
        'update anime set tag_name = \'$newTagName\' where tag_name = \'$oldTagName\';');
  }

  static Future<bool> updateTagOrder(List<String> tagNames) async {
    for (int i = 0; i < tagNames.length; ++i) {
      await database.rawUpdate(
          'update tag set tag_order = $i where tag_name = \'${tagNames[i]}\';');
    }
    return true;
  }

  static void deleteTagByTagName(String tagName) async {
    await database.rawDelete('delete from tag where tag_name = \'$tagName\';');
  }

  static Future<List<String>> getAllTags() async {
    var list =
        await database.rawQuery('select tag_name from tag order by tag_order');
    return list.map((e) => e["tag_name"] as String).toList();
  }

  static Future<Anime> getAnimeByAnimeUrl(Anime anime) async {
    if (anime.animeUrl.isEmpty) return anime..animeId = 0;
    var list = await database.rawQuery(
        'select * from anime where anime_url = \'${anime.animeUrl}\';');
    if (list.isEmpty) return anime..animeId = 0;
    return await AnimeDao.row2Bean(list[0], queryCheckedEpisodeCnt: true);
  }

  static Future<List<Episode>> getEpisodeHistoryByAnimeIdAndRange(
      Anime anime, int startEpisodeNumber, int endEpisodeNumber) async {
    var list = await database.rawQuery(
        'select date, episode_number from history where anime_id = ${anime.animeId} and review_number = ${anime.reviewNumber} and episode_number >= $startEpisodeNumber and episode_number <= $endEpisodeNumber;');
    List<Episode> episodes = List.generate(
        endEpisodeNumber - startEpisodeNumber + 1,
        (i) => Episode(startEpisodeNumber + i, anime.reviewNumber,
            startNumber: EpisodeUtil.getFakeEpisodeStartNumber(anime)));
    for (var row in list) {
      int idx = (row['episode_number'] as int) - startEpisodeNumber;
      if (idx >= 0 && idx < episodes.length) {
        episodes[idx].dateTime = row['date'] as String;
      }
    }
    return episodes;
  }

  static Future<int> getAnimesCntBytagName(String tagName) async {
    var list = await database.rawQuery(
        'select count(anime_id) cnt from anime where tag_name = \'$tagName\';');
    return list[0]["cnt"] as int;
  }

  static Future<int> getCheckedEpisodeCntByAnimeId(int animeId,
      {int reviewNumber = 0}) async {
    var list = await database.rawQuery(
        'select count(anime_id) cnt from history where anime_id = $animeId and review_number = $reviewNumber;');
    return list[0]["cnt"] as int;
  }

  static Future<List<Anime>> getAllAnimeBytagName(
      String tagName, int offset, int number,
      {required AnimeSortCond animeSortCond}) async {
    // 简化实现，因为这个方法主要被AnimeListPage使用，确保功能存在
    var list = await database.rawQuery(
        'select * from anime where tag_name = \'$tagName\' limit $number offset $offset;');
    List<Anime> res = [];
    for (var row in list) {
      res.add(await AnimeDao.row2Bean(row, queryCheckedEpisodeCnt: true));
    }
    return res;
  }

  static Future<List<int>> getAnimeCntPerTag() async {
    var list = await database.rawQuery(
        'select count(anime_id) as anime_cnt from tag left outer join anime on anime.tag_name = tag.tag_name group by tag.tag_name order by tag.tag_order;');
    return list.map((e) => e['anime_cnt'] as int).toList();
  }

  static Future<Anime> getCustomAnimeByAnimeName(String animeName) async {
    var list = await database.rawQuery(
        'select * from anime where anime_name = \'${EscapeUtil.escapeStr(animeName)}\' and (anime_url is null or length(anime_url) = 0);');
    if (list.isEmpty) return Anime(animeName: animeName, animeEpisodeCnt: 0);
    return await AnimeDao.row2Bean(list[0], queryCheckedEpisodeCnt: true);
  }

  static Future<List<Anime>> getCustomAnimesIfContainAnimeName(
      String animeName) async {
    var list = await database.rawQuery(
        'select * from anime where anime_name like \'%${EscapeUtil.escapeStr(animeName)}%\' and (anime_url is null or length(anime_url) = 0);');
    List<Anime> res = [];
    for (var row in list) {
      res.add(await AnimeDao.row2Bean(row, queryCheckedEpisodeCnt: true));
    }
    return res;
  }

  static Future<int> count(
      {required String tableName,
      String? columnName = 'id',
      String? where,
      List<Object?>? whereArgs}) async {
    final rows = await database.query(tableName,
        columns: ['COUNT(${columnName ?? "*"})'],
        where: where,
        whereArgs: whereArgs);
    if (rows.isEmpty) return 0;
    return rows.first.values.first as int;
  }
}
