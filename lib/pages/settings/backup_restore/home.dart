import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:manji_trace/pages/settings/backup_restore/local.dart';
import 'package:manji_trace/pages/settings/backup_restore/remote.dart';
import 'package:manji_trace/pages/settings/pages/rbr_page.dart';
import 'package:manji_trace/routes/get_route.dart';
import 'package:manji_trace/utils/backup_util.dart';
import 'package:manji_trace/utils/sqlite_util.dart';
import 'package:manji_trace/utils/toast_util.dart';
import 'package:manji_trace/controllers/sync_service.dart';
import 'package:manji_trace/widgets/common_scaffold_body.dart';
import 'package:manji_trace/widgets/setting_card.dart';

class BackupAndRestorePage extends StatefulWidget {
  const BackupAndRestorePage({Key? key}) : super(key: key);

  @override
  _BackupAndRestorePageState createState() => _BackupAndRestorePageState();
}

class _BackupAndRestorePageState extends State<BackupAndRestorePage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("备份还原")),
      body: CommonScaffoldBody(
          child: ListView(
        padding: const EdgeInsets.only(bottom: 50),
        children: [
          const LocalBackupPage(),
          const RemoteBackupPage(),
          _buildSyncCard(),
          SettingCard(
            title: '数据迁移',
            children: [
              _buildMigrateOldImagesTile(),
            ],
          ),
          SettingCard(
            title: '撤销还原',
            children: [
              _buildRevokeRestoreTile(),
            ],
          ),
        ],
      )),
    );
  }

  Widget _buildSyncCard() {
    return GetBuilder<SyncService>(builder: (syncService) {
      String syncTimeStr = syncService.lastLocalSyncTime == 0
          ? "从未同步"
          : DateTime.fromMillisecondsSinceEpoch(syncService.lastLocalSyncTime)
              .toString()
              .substring(0, 19);
      String conflictRemoteTimeStr = syncService.pendingRemoteConflict == null
          ? "-"
          : DateTime.fromMillisecondsSinceEpoch(
                  syncService.pendingRemoteConflict!.lastUpdateTime)
              .toString()
              .substring(0, 19);
      String conflictLocalTimeStr = syncService.pendingLocalDbModifiedTime == 0
          ? "-"
          : DateTime.fromMillisecondsSinceEpoch(
                  syncService.pendingLocalDbModifiedTime)
              .toString()
              .substring(0, 19);
        String deltaFallbackTimeStr = syncService.lastDeltaFallbackTime == 0
          ? "-"
          : DateTime.fromMillisecondsSinceEpoch(syncService.lastDeltaFallbackTime)
            .toString()
            .substring(0, 19);

      return SettingCard(
        title: '多设备同步 (WebDAV)',
        children: [
          SwitchListTile(
            title: const Text("启动时自动同步"),
            subtitle: const Text("同步目录统一为 /漫记/sync；若检测到双端改动冲突，不会自动覆盖"),
            value: syncService.enableAutoSync,
            onChanged: (val) {
              setState(() {
                syncService.enableAutoSync = val;
              });
            },
          ),
          if (syncService.hasConflict)
            ListTile(
              title: const Text("检测到同步冲突"),
              subtitle: Text(
                "云端设备: ${syncService.pendingRemoteConflict?.deviceName ?? '-'}\n"
                "云端更新时间: $conflictRemoteTimeStr\n"
                "本地更新时间: $conflictLocalTimeStr",
              ),
            ),
          if (syncService.hasConflict)
            Padding(
              padding: const EdgeInsets.only(left: 16, right: 16, bottom: 8),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: syncService.isSyncing
                          ? null
                          : () async {
                              await syncService.forceUploadLocalVersion();
                              setState(() {});
                            },
                      child: const Text("保留本地并上传"),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: syncService.isSyncing
                          ? null
                          : () async {
                              await syncService.forceDownloadRemoteVersion();
                              setState(() {});
                            },
                      child: const Text("采用云端并下载"),
                    ),
                  ),
                ],
              ),
            ),
          ListTile(
            title: const Text("立即同步"),
            subtitle: Text("上次同步: $syncTimeStr"),
            trailing: syncService.isSyncing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync),
            onTap: syncService.isSyncing
                ? null
                : () async {
                    await syncService.syncData();
                    setState(() {});
                  },
          ),
          if (syncService.lastDeltaFallbackReason.isNotEmpty)
            ListTile(
              title: const Text("最近一次增量回退"),
              subtitle: Text(
                "时间: $deltaFallbackTimeStr\n"
                "原因: ${_formatDeltaFallbackReason(syncService.lastDeltaFallbackReason)}",
              ),
            ),
          ListTile(
            title: const Text("重建云端增量链"),
            subtitle: Text(syncService.needDeltaChainRebase
                ? "状态: 待重建（下次上传会自动清理并重建）"
                : "用于修复增量链断裂/不连续，执行时会强制上传当前本地版本"),
            trailing: const Icon(Icons.build_circle_outlined),
            onTap: syncService.isSyncing
                ? null
                : () async {
                    await syncService.rebuildRemoteDeltaChain();
                    setState(() {});
                  },
          ),
        ],
      );
    });
  }

  String _formatDeltaFallbackReason(String reason) {
    if (reason.contains('delta-digest-mismatch')) {
      return '增量应用后摘要不一致';
    }
    if (reason.contains('delta-apply-failed')) {
      return '增量清单回放失败';
    }
    if (reason.contains('delta-parse-failed')) {
      return '增量清单解析失败';
    }
    if (reason.contains('delta-chain-gap-at-')) {
      return '增量链不连续（缺少中间分片）';
    }
    if (reason.contains('delta-cursor-too-old')) {
      return '本地增量游标过旧（超出远端保留窗口）';
    }
    if (reason.contains('fallback-empty')) {
      return '单清单不可用（为空）';
    }
    if (reason.contains('fallback-json-invalid')) {
      return '单清单不可用（格式错误）';
    }
    if (reason.contains('fallback-range-mismatch')) {
      return '单清单范围与本地游标不匹配';
    }
    return reason;
  }

  ListTile _buildMigrateOldImagesTile() {
    return ListTile(
      title: const Text("修复旧版图片显示"),
      subtitle: const Text("解决升级后旧日记图片不显示的问题"),
      onTap: () async {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text("确认修复？"),
            content: const Text("该操作将尝试修复由于数据库升级导致的旧日记图片无法显示的问题。\n\n"
                "如果您在升级后发现旧日记中的图片消失了，请点击确定。"),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text("取消")),
              TextButton(
                  onPressed: () async {
                    Navigator.pop(context);
                    int dataCount = await SqliteUtil.migrateOldImageData();
                    int fileCount =
                        await SqliteUtil.migrateJournalImageFilesToNewRoot();
                    ToastUtil.showText(
                        "修复完成，共处理 ${dataCount + fileCount} 项旧数据/图片");
                  },
                  child: const Text("确定")),
            ],
          ),
        );
      },
    );
  }

  ListTile _buildRevokeRestoreTile() {
    return ListTile(
      title: const Text("还原前的备份记录"),
      onTap: () {
        RouteUtil.materialTo(context, const RBRPage());
      },
      trailing: IconButton(
          onPressed: _showHelpDialog, icon: const Icon(Icons.help_outline)),
    );
  }

  Future<dynamic> _showHelpDialog() {
    return showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("帮助"),
        content: Text("用户在还原数据前，会备份当前的数据，存放在此处。\n"
            "当用户在还原数据后，如果想要撤销还原，可以在这里恢复之前的数据。\n"
            "注：最多会存放 ${BackupUtil.rbrMaxCnt} 份，超出时会删除旧备份。"),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("我已了解"))
        ],
      ),
    );
  }
}
