import 'package:sqflite/sqflite.dart';
import 'package:animetrace/models/sync_version_model.dart';
import 'package:animetrace/utils/log.dart';

/// SQLite同步版本数据库工具
class SqliteSyncUtil {
  static const String tableName = 'sync_version';

  /// 创建sync_version表（在应用启动时调用）
  static Future<void> createSyncVersionTable(Database db) async {
    try {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS $tableName (
          id TEXT PRIMARY KEY,
          version_number INTEGER NOT NULL,
          create_time TEXT NOT NULL,
          backup_mode TEXT NOT NULL,
          source TEXT NOT NULL,
          device TEXT NOT NULL,
          record_count INTEGER NOT NULL DEFAULT 0,
          label_count INTEGER NOT NULL DEFAULT 0,
          note_image_count INTEGER NOT NULL DEFAULT 0,
          cover_image_count INTEGER NOT NULL DEFAULT 0,
          total_size INTEGER NOT NULL DEFAULT 0,
          parent_version_id TEXT,
          added_records INTEGER,
          modified_records INTEGER,
          deleted_records INTEGER,
          changed_image_ids TEXT,
          local_path TEXT,
          remote_path TEXT,
          md5_checksum TEXT,
          created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
          FOREIGN KEY(parent_version_id) REFERENCES $tableName(id)
        )
      ''');
      
      // 创建索引以加快查询速度
      await db.execute('''
        CREATE INDEX IF NOT EXISTS idx_sync_version_create_time 
        ON $tableName(create_time DESC)
      ''');
      
      await db.execute('''
        CREATE INDEX IF NOT EXISTS idx_sync_version_source 
        ON $tableName(source)
      ''');
      
      AppLog.info("✓ sync_version表创建成功");
    } catch (e) {
      AppLog.error("创建sync_version表失败: $e");
    }
  }

  /// 插入新版本记录
  static Future<void> insertSyncVersion(Database db, SyncVersion version) async {
    try {
      await db.insert(tableName, version.toMap());
      AppLog.info("✓ 版本记录已保存: ${version.id}");
    } catch (e) {
      AppLog.error("插入版本记录失败: $e");
    }
  }

  /// 更新版本记录（用于补充信息如备份路径）
  static Future<void> updateSyncVersion(Database db, SyncVersion version) async {
    try {
      await db.update(
        tableName,
        version.toMap(),
        where: 'id = ?',
        whereArgs: [version.id],
      );
      AppLog.info("✓ 版本记录已更新: ${version.id}");
    } catch (e) {
      AppLog.error("更新版本记录失败: $e");
    }
  }

  /// 获取所有版本按创建时间倒序
  static Future<List<SyncVersion>> getAllSyncVersions(Database db) async {
    try {
      final List<Map<String, dynamic>> maps = await db.query(
        tableName,
        orderBy: 'create_time DESC',
      );
      return List.generate(maps.length, (i) => SyncVersion.fromMap(maps[i]));
    } catch (e) {
      AppLog.error("获取版本列表失败: $e");
      return [];
    }
  }

  /// 获取最新的完整备份版本
  static Future<SyncVersion?> getLatestFullBackup(Database db) async {
    try {
      final List<Map<String, dynamic>> maps = await db.query(
        tableName,
        where: 'backup_mode = ?',
        whereArgs: ['full'],
        orderBy: 'create_time DESC',
        limit: 1,
      );
      if (maps.isNotEmpty) {
        return SyncVersion.fromMap(maps.first);
      }
      return null;
    } catch (e) {
      AppLog.error("获取最新完整备份失败: $e");
      return null;
    }
  }

  /// 获取指定版本ID的记录
  static Future<SyncVersion?> getSyncVersionById(Database db, String id) async {
    try {
      final List<Map<String, dynamic>> maps = await db.query(
        tableName,
        where: 'id = ?',
        whereArgs: [id],
      );
      if (maps.isNotEmpty) {
        return SyncVersion.fromMap(maps.first);
      }
      return null;
    } catch (e) {
      AppLog.error("获取版本记录失败: $e");
      return null;
    }
  }

  /// 获取给定版本号后的所有增量备份（用于快速恢复）
  static Future<List<SyncVersion>> getIncrementalChain(
    Database db,
    String fromVersionId,
  ) async {
    try {
      final List<SyncVersion> chain = [];
      SyncVersion? current = await getSyncVersionById(db, fromVersionId);
      
      while (current != null) {
        chain.insert(0, current);
        if (current.parentVersionId == null) {
          break;
        }
        current = await getSyncVersionById(db, current.parentVersionId!);
      }
      
      return chain;
    } catch (e) {
      AppLog.error("获取增量链失败: $e");
      return [];
    }
  }

  /// 删除版本记录及其增量链（如果没有其他版本依赖）
  static Future<void> deleteSyncVersion(Database db, String id) async {
    try {
      // 检查是否有其他版本依赖此版本
      final List<Map<String, dynamic>> dependents = await db.query(
        tableName,
        where: 'parent_version_id = ?',
        whereArgs: [id],
      );
      
      if (dependents.isNotEmpty) {
        AppLog.warn("无法删除版本 $id：有 ${dependents.length} 个依赖版本");
        return;
      }
      
      await db.delete(
        tableName,
        where: 'id = ?',
        whereArgs: [id],
      );
      AppLog.info("✓ 版本记录已删除: $id");
    } catch (e) {
      AppLog.error("删除版本记录失败: $e");
    }
  }

  /// 获取指定来源的备份（用于分页查看备份历史）
  static Future<List<SyncVersion>> getBackupsBySource(
    Database db,
    String source, {
    int limit = 50,
    int offset = 0,
  }) async {
    try {
      final List<Map<String, dynamic>> maps = await db.query(
        tableName,
        where: 'source = ?',
        whereArgs: [source],
        orderBy: 'create_time DESC',
        limit: limit,
        offset: offset,
      );
      return List.generate(maps.length, (i) => SyncVersion.fromMap(maps[i]));
    } catch (e) {
      AppLog.error("获取$source备份列表失败: $e");
      return [];
    }
  }

  /// 获取近期备份的统计信息
  static Future<Map<String, dynamic>> getBackupStatistics(Database db) async {
    try {
      final totalCount = await db.rawQuery(
        'SELECT COUNT(*) as count FROM $tableName'
      );
      
      final fullBackupCount = await db.rawQuery(
        'SELECT COUNT(*) as count FROM $tableName WHERE backup_mode = "full"'
      );
      
      final latestVersion = await db.rawQuery(
        'SELECT MAX(version_number) as max_version FROM $tableName'
      );
      
      final totalSize = await db.rawQuery(
        'SELECT SUM(total_size) as total FROM $tableName'
      );
      
      return {
        'totalCount': (totalCount.first['count'] as int?) ?? 0,
        'fullBackupCount': (fullBackupCount.first['count'] as int?) ?? 0,
        'maxVersionNumber': (latestVersion.first['max_version'] as int?) ?? 0,
        'totalSize': (totalSize.first['total'] as int?) ?? 0,
      };
    } catch (e) {
      AppLog.error("获取备份统计失败: $e");
      return {};
    }
  }

  /// 清理旧备份记录（保留最近N个）
  static Future<void> cleanupOldVersions(Database db, {int keepCount = 50}) async {
    try {
      final List<Map<String, dynamic>> allVersions = await db.query(tableName);
      
      if (allVersions.length > keepCount) {
        final toDelete = allVersions.length - keepCount;
        await db.execute(
          'DELETE FROM $tableName WHERE id NOT IN '
          '(SELECT id FROM $tableName ORDER BY create_time DESC LIMIT $keepCount)'
        );
        AppLog.info("✓ 已清理 $toDelete 条旧备份记录");
      }
    } catch (e) {
      AppLog.error("清理旧备份记录失败: $e");
    }
  }
}
