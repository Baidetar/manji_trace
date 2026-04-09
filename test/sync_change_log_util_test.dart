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
        anime_episode_cnt INTEGER,
        update_time TEXT
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

    await db.update(
      'anime',
      {
        'anime_name': 'LocalTemp',
        'anime_episode_cnt': 1,
      },
      where: 'anime_id = ?',
      whereArgs: [7],
    );

    final int beforeApplyLatest = await SyncChangeLogUtil.getLatestChangeId();
    final applyResult = await SyncChangeLogUtil.applyDeltaManifest(manifest);
    final int afterApplyLatest = await SyncChangeLogUtil.getLatestChangeId();

    expect(applyResult.ok, true);
    expect(applyResult.appliedCount >= 2, true);
    expect(applyResult.skippedByLocalNewer >= 0, true);
    expect(applyResult.skippedByTombstone >= 0, true);

    final rows =
        await db.query('anime', where: 'anime_id = ?', whereArgs: [7], limit: 1);
    expect(rows.length, 1);
    expect(rows.first['anime_name'], 'New');

    expect(afterApplyLatest, beforeApplyLatest);
  });

  test('tombstone blocks stale upsert after delete', () async {
    await db.insert('anime', {
      'anime_id': 9,
      'anime_name': 'ToDelete',
      'anime_episode_cnt': 1,
      'update_time': '2026-04-10 10:00:00',
    });
    await db.delete('anime', where: 'anime_id = ?', whereArgs: [9]);

    final applyResult = await SyncChangeLogUtil.applyDeltaManifest({
      'changes': [
        {
          'table_name': 'anime',
          'pk': 'anime_id',
          'row_id': '9',
          'op': 'update',
          'changed_at': 1,
          'row': {
            'anime_id': 9,
            'anime_name': 'StaleRemote',
            'anime_episode_cnt': 1,
            'update_time': '2020-01-01 00:00:00',
          }
        }
      ]
    });

    expect(applyResult.ok, true);
    expect(applyResult.appliedCount, 0);
    expect(applyResult.skippedCount, 1);

    final rows =
        await db.query('anime', where: 'anime_id = ?', whereArgs: [9], limit: 1);
    expect(rows, isEmpty);
  });

  test('newer upsert can revive row and clear tombstone', () async {
    await db.insert('anime', {
      'anime_id': 10,
      'anime_name': 'ToDelete',
      'anime_episode_cnt': 1,
      'update_time': '2026-04-10 10:00:00',
    });
    await db.delete('anime', where: 'anime_id = ?', whereArgs: [10]);

    final tombstoneRows = await db.query(
      SyncChangeLogUtil.tombstoneTable,
      where: 'table_name = ? AND row_id = ?',
      whereArgs: ['anime', '10'],
      limit: 1,
    );
    expect(tombstoneRows.length, 1);
    final int tombstoneAt = tombstoneRows.first['deleted_at'] as int;

    final applyResult = await SyncChangeLogUtil.applyDeltaManifest({
      'changes': [
        {
          'table_name': 'anime',
          'pk': 'anime_id',
          'row_id': '10',
          'op': 'update',
          'changed_at': tombstoneAt + 1000,
          'row': {
            'anime_id': 10,
            'anime_name': 'RemoteNewer',
            'anime_episode_cnt': 12,
            'update_time': '2026-04-10 23:59:59',
          }
        }
      ]
    });

    expect(applyResult.ok, true);
    expect(applyResult.appliedCount, 1);

    final rows = await db
        .query('anime', where: 'anime_id = ?', whereArgs: [10], limit: 1);
    expect(rows.length, 1);
    expect(rows.first['anime_name'], 'RemoteNewer');

    final tombstoneAfter = await db.query(
      SyncChangeLogUtil.tombstoneTable,
      where: 'table_name = ? AND row_id = ?',
      whereArgs: ['anime', '10'],
      limit: 1,
    );
    expect(tombstoneAfter, isEmpty);
  });

  test('pruneTombstones removes old tombstones only', () async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final int oldTs = now - 200 * 24 * 60 * 60 * 1000;
    final int freshTs = now - 2 * 24 * 60 * 60 * 1000;

    await db.insert(
      SyncChangeLogUtil.tombstoneTable,
      {'table_name': 'anime', 'row_id': '100', 'deleted_at': oldTs},
    );
    await db.insert(
      SyncChangeLogUtil.tombstoneTable,
      {'table_name': 'anime', 'row_id': '101', 'deleted_at': freshTs},
    );

    final removed = await SyncChangeLogUtil.pruneTombstones(retentionDays: 30);
    expect(removed, 1);

    final leftOld = await db.query(
      SyncChangeLogUtil.tombstoneTable,
      where: 'table_name = ? AND row_id = ?',
      whereArgs: ['anime', '100'],
    );
    expect(leftOld, isEmpty);

    final leftFresh = await db.query(
      SyncChangeLogUtil.tombstoneTable,
      where: 'table_name = ? AND row_id = ?',
      whereArgs: ['anime', '101'],
    );
    expect(leftFresh.length, 1);
  });

  test('delete arriving after remote update removes row and keeps tombstone',
      () async {
    final int updateAt =
      DateTime.parse('2026-04-10T10:10:00').millisecondsSinceEpoch;
    final int deleteAt =
      DateTime.parse('2026-04-10T10:20:00').millisecondsSinceEpoch;

    await db.insert('anime', {
      'anime_id': 11,
      'anime_name': 'Base',
      'anime_episode_cnt': 1,
      'update_time': '2026-04-10 10:00:00',
    });

    final updateFirst = await SyncChangeLogUtil.applyDeltaManifest({
      'changes': [
        {
          'table_name': 'anime',
          'pk': 'anime_id',
          'row_id': '11',
          'op': 'update',
          'changed_at': updateAt,
          'row': {
            'anime_id': 11,
            'anime_name': 'RemoteUpdateFirst',
            'anime_episode_cnt': 2,
            'update_time': '2026-04-10 10:10:00',
          }
        }
      ]
    });
    expect(updateFirst.ok, true);
    expect(updateFirst.appliedCount, 1);

    final deleteSecond = await SyncChangeLogUtil.applyDeltaManifest({
      'changes': [
        {
          'table_name': 'anime',
          'pk': 'anime_id',
          'row_id': '11',
          'op': 'delete',
          'changed_at': deleteAt,
        }
      ]
    });
    expect(deleteSecond.ok, true);
    expect(deleteSecond.appliedCount, 1);

    final rows = await db
        .query('anime', where: 'anime_id = ?', whereArgs: [11], limit: 1);
    expect(rows, isEmpty);

    final tombstone = await db.query(
      SyncChangeLogUtil.tombstoneTable,
      where: 'table_name = ? AND row_id = ?',
      whereArgs: ['anime', '11'],
      limit: 1,
    );
    expect(tombstone.length, 1);
  });

  test('older delete arriving after newer local update is skipped', () async {
    await db.insert('anime', {
      'anime_id': 12,
      'anime_name': 'LocalNewer',
      'anime_episode_cnt': 1,
      'update_time': '2026-04-10 12:00:00',
    });

    final deleteApply = await SyncChangeLogUtil.applyDeltaManifest({
      'changes': [
        {
          'table_name': 'anime',
          'pk': 'anime_id',
          'row_id': '12',
          'op': 'delete',
          'changed_at': 1000,
        }
      ]
    });

    expect(deleteApply.ok, true);
    expect(deleteApply.appliedCount, 0);
    expect(deleteApply.skippedByLocalNewer, 1);

    final rows = await db
        .query('anime', where: 'anime_id = ?', whereArgs: [12], limit: 1);
    expect(rows.length, 1);
    expect(rows.first['anime_name'], 'LocalNewer');
  });
}
