import 'package:manji_trace/utils/log.dart';
import 'package:manji_trace/utils/sqlite_util.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class SyncChangeLogUtil {
  static const String tableName = 'sync_change_log';
  static const String runtimeFlagTable = 'sync_runtime_flag';
  static const String suspendChangeLogKey = 'suspend_change_log';

  static const List<Map<String, String>> _watchedTables = [
    {'table': 'anime', 'pk': 'anime_id'},
    {'table': 'history', 'pk': 'history_id'},
    {'table': 'episode_note', 'pk': 'note_id'},
    {'table': 'journal_note', 'pk': 'id'},
    {'table': 'image', 'pk': 'image_id'},
    {'table': 'label', 'pk': 'id'},
    {'table': 'series', 'pk': 'id'},
  ];

  static Future<void> ensureChangeLogInfra() async {
    final db = SqliteUtil.database;

    await db.execute('''
      CREATE TABLE IF NOT EXISTS $tableName (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        table_name TEXT NOT NULL,
        row_id TEXT NOT NULL,
        op TEXT NOT NULL,
        changed_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_sync_change_log_changed_at
      ON $tableName(changed_at DESC)
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_sync_change_log_table_row
      ON $tableName(table_name, row_id)
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS $runtimeFlagTable (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');

    await db.insert(
      runtimeFlagTable,
      {'key': suspendChangeLogKey, 'value': '0'},
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );

    for (final table in _watchedTables) {
      final String tableName = table['table']!;
      final String pk = table['pk']!;
      await _ensureTriggers(tableName: tableName, pk: pk);
    }
  }

  static Future<void> _ensureTriggers({
    required String tableName,
    required String pk,
  }) async {
    final db = SqliteUtil.database;
    await db.execute('DROP TRIGGER IF EXISTS trg_sync_log_${tableName}_insert');
    await db.execute('DROP TRIGGER IF EXISTS trg_sync_log_${tableName}_update');
    await db.execute('DROP TRIGGER IF EXISTS trg_sync_log_${tableName}_delete');

    await db.execute('''
      CREATE TRIGGER trg_sync_log_${tableName}_insert
      AFTER INSERT ON $tableName
      WHEN (SELECT COALESCE(value, '0') FROM $runtimeFlagTable WHERE key = '$suspendChangeLogKey' LIMIT 1) != '1'
      BEGIN
        INSERT INTO ${SyncChangeLogUtil.tableName}(table_name, row_id, op, changed_at)
        VALUES('$tableName', CAST(NEW.$pk AS TEXT), 'insert', CAST(strftime('%s','now') AS INTEGER) * 1000);
      END
    ''');

    await db.execute('''
      CREATE TRIGGER trg_sync_log_${tableName}_update
      AFTER UPDATE ON $tableName
      WHEN (SELECT COALESCE(value, '0') FROM $runtimeFlagTable WHERE key = '$suspendChangeLogKey' LIMIT 1) != '1'
      BEGIN
        INSERT INTO ${SyncChangeLogUtil.tableName}(table_name, row_id, op, changed_at)
        VALUES('$tableName', CAST(NEW.$pk AS TEXT), 'update', CAST(strftime('%s','now') AS INTEGER) * 1000);
      END
    ''');

    await db.execute('''
      CREATE TRIGGER trg_sync_log_${tableName}_delete
      AFTER DELETE ON $tableName
      WHEN (SELECT COALESCE(value, '0') FROM $runtimeFlagTable WHERE key = '$suspendChangeLogKey' LIMIT 1) != '1'
      BEGIN
        INSERT INTO ${SyncChangeLogUtil.tableName}(table_name, row_id, op, changed_at)
        VALUES('$tableName', CAST(OLD.$pk AS TEXT), 'delete', CAST(strftime('%s','now') AS INTEGER) * 1000);
      END
    ''');
  }

  static Future<void> _setSuspendFlag(bool suspend) async {
    await SqliteUtil.database.update(
      runtimeFlagTable,
      {'value': suspend ? '1' : '0'},
      where: 'key = ?',
      whereArgs: [suspendChangeLogKey],
    );
  }

  static Future<T> suspendChangeLogFor<T>(Future<T> Function() action) async {
    await _setSuspendFlag(true);
    try {
      return await action();
    } finally {
      await _setSuspendFlag(false);
    }
  }

  static Future<int> getLatestChangeId() async {
    try {
      final rows = await SqliteUtil.database
          .rawQuery('SELECT MAX(id) AS max_id FROM $tableName');
      return (rows.first['max_id'] as int?) ?? 0;
    } catch (e) {
      AppLog.error('读取最新变更ID失败: $e');
      return 0;
    }
  }

  static Future<int> countChangesSince(int fromId) async {
    try {
      final rows = await SqliteUtil.database.rawQuery(
        'SELECT COUNT(*) AS cnt FROM $tableName WHERE id > ?',
        [fromId],
      );
      return (rows.first['cnt'] as int?) ?? 0;
    } catch (e) {
      AppLog.error('统计变更数量失败: $e');
      return 0;
    }
  }

  static Future<Map<String, dynamic>> buildDeltaManifest({
    required int fromId,
    required int toId,
    int maxRows = 2000,
  }) async {
    if (toId <= fromId) {
      return {
        'fromId': fromId,
        'toId': toId,
        'count': 0,
        'changes': <Map<String, dynamic>>[],
      };
    }

    final rows = await SqliteUtil.database.rawQuery(
      '''
      SELECT id, table_name, row_id, op, changed_at
      FROM $tableName
      WHERE id > ? AND id <= ?
      ORDER BY id ASC
      LIMIT ?
      ''',
      [fromId, toId, maxRows],
    );

    final List<Map<String, dynamic>> enrichedChanges = [];
    for (final row in rows) {
      final String table = row['table_name'] as String? ?? '';
      final String rowId = row['row_id'] as String? ?? '';
      final String op = row['op'] as String? ?? '';
      final String pk = _getPkByTable(table);
      Map<String, dynamic>? snapshot;
      if (op != 'delete' && pk.isNotEmpty && rowId.isNotEmpty) {
        snapshot = await _queryRowSnapshot(table: table, pk: pk, rowId: rowId);
      }

      enrichedChanges.add({
        'id': row['id'],
        'table_name': table,
        'pk': pk,
        'row_id': rowId,
        'op': op,
        'changed_at': row['changed_at'],
        if (snapshot != null) 'row': snapshot,
      });
    }

    return {
      'fromId': fromId,
      'toId': toId,
      'count': enrichedChanges.length,
      'truncated': rows.length == maxRows,
      'changes': enrichedChanges,
    };
  }

  static Future<Map<String, dynamic>?> _queryRowSnapshot({
    required String table,
    required String pk,
    required String rowId,
  }) async {
    if (!_isWatchedTable(table) || pk.isEmpty) {
      return null;
    }
    final rows = await SqliteUtil.database.query(
      table,
      where: '$pk = ?',
      whereArgs: [rowId],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return Map<String, dynamic>.from(rows.first);
  }

  static Future<Map<String, dynamic>> applyDeltaManifest(
      Map<String, dynamic> manifest) async {
    final dynamic changesRaw = manifest['changes'];
    if (changesRaw is! List) {
      return {'ok': false, 'appliedCount': 0, 'reason': 'invalid-manifest'};
    }

    int appliedCount = 0;
    await suspendChangeLogFor(() async {
      await SqliteUtil.database.transaction((txn) async {
        for (final dynamic item in changesRaw) {
          if (item is! Map) continue;
          final map = Map<String, dynamic>.from(item);
          final String table = map['table_name']?.toString() ?? '';
          final String pk = map['pk']?.toString() ?? _getPkByTable(table);
          final String op = map['op']?.toString() ?? '';
          final String rowId = map['row_id']?.toString() ?? '';

          if (!_isWatchedTable(table) || pk.isEmpty || rowId.isEmpty) {
            continue;
          }

          if (op == 'delete') {
            await txn.delete(table, where: '$pk = ?', whereArgs: [rowId]);
            appliedCount++;
            continue;
          }

          final rowRaw = map['row'];
          if (rowRaw is! Map) {
            continue;
          }
          final row = Map<String, Object?>.from(rowRaw);
          if (row.isEmpty) {
            continue;
          }
          await txn.insert(
            table,
            row,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
          appliedCount++;
        }
      });
    });

    return {'ok': true, 'appliedCount': appliedCount};
  }

  static bool _isWatchedTable(String table) {
    return _watchedTables.any((e) => e['table'] == table);
  }

  static String _getPkByTable(String table) {
    final entry = _watchedTables
        .cast<Map<String, String>?>()
        .firstWhere((e) => e?['table'] == table, orElse: () => null);
    return entry?['pk'] ?? '';
  }
}
