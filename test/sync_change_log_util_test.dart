import 'package:flutter_test/flutter_test.dart';
import 'package:manji_trace/utils/sqlite_util.dart';
import 'package:manji_trace/utils/sync_change_log_util.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;

  Future<void> createWatchedTables(Database database) async {
    await database.execute('''
      CREATE TABLE anime (
        anime_id INTEGER PRIMARY KEY,
        anime_name TEXT,
        anime_episode_cnt INTEGER
      )
    ''');
    await database.execute(
        'CREATE TABLE history (history_id INTEGER PRIMARY KEY, anime_id INTEGER, episode_number INTEGER)');
    await database.execute(
        'CREATE TABLE episode_note (note_id INTEGER PRIMARY KEY, note_content TEXT)');
    await database.execute(
        'CREATE TABLE journal_note (id INTEGER PRIMARY KEY, content TEXT)');
    await database
        .execute('CREATE TABLE image (image_id INTEGER PRIMARY KEY, note_id INTEGER)');
    await database.execute('CREATE TABLE label (id INTEGER PRIMARY KEY, name TEXT)');
    await database.execute('CREATE TABLE series (id INTEGER PRIMARY KEY, name TEXT)');
  }

  setUp(() async {
    sqfliteFfiInit();
    db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(version: 1),
    );
    SqliteUtil.database = db;
    await createWatchedTables(db);
    await SyncChangeLogUtil.ensureChangeLogInfra();
  });

  tearDown(() async {
    await db.close();
  });

  test('buildDeltaManifest returns ordered changes with snapshots', () async {
    await db.insert('anime', {
      'anime_id': 1,
      'anime_name': 'A',
      'anime_episode_cnt': 12,
    });
    await db.update(
      'anime',
      {'anime_name': 'B'},
      where: 'anime_id = ?',
      whereArgs: [1],
    );

    final int latestBeforeDelete = await SyncChangeLogUtil.getLatestChangeId();
    final manifestBeforeDelete = await SyncChangeLogUtil.buildDeltaManifest(
      fromId: 0,
      toId: latestBeforeDelete,
    );

    final changesBeforeDelete =
        (manifestBeforeDelete['changes'] as List).cast<Map<String, dynamic>>();
    expect(changesBeforeDelete.length, 2);
    expect(changesBeforeDelete[0]['op'], 'insert');
    expect(changesBeforeDelete[1]['op'], 'update');
    expect(changesBeforeDelete[0]['row'], isA<Map<String, dynamic>>());
    expect(changesBeforeDelete[1]['row'], isA<Map<String, dynamic>>());

    await db.delete('anime', where: 'anime_id = ?', whereArgs: [1]);

    final int latest = await SyncChangeLogUtil.getLatestChangeId();
    final manifest = await SyncChangeLogUtil.buildDeltaManifest(
      fromId: latestBeforeDelete,
      toId: latest,
    );

    expect(manifest['fromId'], latestBeforeDelete);
    expect(manifest['toId'], latest);

    final changes = (manifest['changes'] as List).cast<Map<String, dynamic>>();
    expect(changes.length, 1);
    expect(changes[0]['op'], 'delete');
    expect(changes[0].containsKey('row'), false);
  });

  test('applyDeltaManifest replays data and does not generate new changelog rows',
      () async {
    await db.insert('anime', {
      'anime_id': 7,
      'anime_name': 'Old',
      'anime_episode_cnt': 24,
    });
    await db.update(
      'anime',
      {'anime_name': 'New'},
      where: 'anime_id = ?',
      whereArgs: [7],
    );

    final int latest = await SyncChangeLogUtil.getLatestChangeId();
    final manifest =
        await SyncChangeLogUtil.buildDeltaManifest(fromId: 0, toId: latest);

    await db.delete('anime', where: 'anime_id = ?', whereArgs: [7]);

    final int beforeApplyLatest = await SyncChangeLogUtil.getLatestChangeId();
    final applyResult = await SyncChangeLogUtil.applyDeltaManifest(manifest);
    final int afterApplyLatest = await SyncChangeLogUtil.getLatestChangeId();

    expect(applyResult['ok'], true);
    expect((applyResult['appliedCount'] as int) >= 2, true);

    final rows =
        await db.query('anime', where: 'anime_id = ?', whereArgs: [7], limit: 1);
    expect(rows.length, 1);
    expect(rows.first['anime_name'], 'New');

    expect(afterApplyLatest, beforeApplyLatest);
  });
}
