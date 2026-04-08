import 'dart:io';

import 'package:manji_trace/components/dialog/dialog_share_error_log.dart';
import 'package:flutter/material.dart';
import 'package:manji_trace/controllers/backup_service.dart';
import 'package:manji_trace/utils/backup_util.dart';
import 'package:manji_trace/utils/file_picker_util.dart';
import 'package:manji_trace/utils/platform.dart';
import 'package:manji_trace/utils/sp_util.dart';
import 'package:manji_trace/utils/toast_util.dart';
import 'package:manji_trace/widgets/setting_card.dart';
import 'package:get/get.dart';

class LocalBackupPage extends StatefulWidget {
  const LocalBackupPage({super.key});

  @override
  State<LocalBackupPage> createState() => _LocalBackupPageState();
}

class _LocalBackupPageState extends State<LocalBackupPage> {
  String autoBackupLocal = SPUtil.getBool("auto_backup_local") ? "开启" : "关闭";
  int autoBackupLocalNumber =
      SPUtil.getInt("autoBackupLocalNumber", defaultValue: 20);

  @override
  Widget build(BuildContext context) {
    return GetBuilder<BackupService>(builder: (backupService) {
      return SettingCard(
        title: '本地备份',
        children: [
          if (backupService.isBackingUp &&
              (backupService.backupProgressScope == 'local' ||
                  backupService.backupProgressScope == 'export' ||
                  backupService.backupProgressScope.isEmpty))
            ListTile(
              title: Text(
                backupService.backupProgressText.isEmpty
                    ? '正在备份'
                    : backupService.backupProgressText,
              ),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: LinearProgressIndicator(
                  value: backupService.backupProgress <= 0 ||
                          backupService.backupProgress >= 1
                      ? null
                      : backupService.backupProgress,
                ),
              ),
            ),
          if (PlatformUtil.isMobile)
            ListTile(
              title: const Text("立即备份"),
              subtitle: const Text("先打包后弹出系统保存窗口"),
              onTap: () async {
                await backupService.exportBackupWithSystemPicker();
              },
            ),
          if (Platform.isWindows)
            ListTile(
              title: const Text("立即备份"),
              subtitle: const Text("单击进行备份，备份目录为设置的本地目录"),
              // subtitle: Text(getDuration()),
              onTap: backupService.isBackingUp
                  ? null
                  : () async {
                      // 注意这里是本地手动备份
                      ToastUtil.showText("正在备份");
                      await backupService.runBackupWithProgress(
                        localBackupDirPath: SPUtil.getString("backup_local_dir",
                            defaultValue: "unset"),
                        progressScope: 'local',
                      );
                    },
            ),
          if (Platform.isWindows)
            ListTile(
              title: const Text("本地备份目录"),
              subtitle: Text(SPUtil.getString("backup_local_dir")),
              onTap: () async {
                String? selectedDirectory = await selectDirectory();
                if (selectedDirectory != null) {
                  SPUtil.setString("backup_local_dir", selectedDirectory);
                  setState(() {});
                }
              },
            ),
          if (Platform.isWindows)
            SwitchListTile(
              title: const Text("自动备份"),
              subtitle: const Text("每次进入应用后会自动备份"),
              value: SPUtil.getBool("auto_backup_local"),
              onChanged: (bool value) {
                if (SPUtil.getString("backup_local_dir",
                        defaultValue: "unset") ==
                    "unset") {
                  ToastUtil.showText("请先设置本地备份目录，再进行备份！");
                  return;
                }
                if (SPUtil.getBool("auto_backup_local")) {
                  // 如果是开启，点击后则关闭
                  SPUtil.setBool("auto_backup_local", false);
                  autoBackupLocal = "关闭";
                } else {
                  SPUtil.setBool("auto_backup_local", true);
                  // 开启后先备份一次，防止因为用户没有点击过手动备份，而无法得到上一次备份时间，从而无法求出备份间隔
                  // WebDavUtil.backupData(true);
                  autoBackupLocal = "开启";
                }
                setState(() {});
              },
            ),
          ListTile(
            title: const Text("还原本地备份"),
            subtitle: const Text("还原动漫记录"),
            onTap: () async {
              // 获取备份文件
              String? selectedFilePath = await selectFile();
              if (selectedFilePath != null) {
                ToastUtil.showLoading(
                  msg: "还原数据中",
                  task: () {
                    return BackupUtil.restoreFromLocal(selectedFilePath);
                  },
                  onTaskSuccess: (taskValue) {
                    ToastUtil.showText(taskValue.msg);
                    if (taskValue.isFailure) {
                      showShareErrorLog();
                    }
                  },
                  onTaskError: (e) {
                    showShareErrorLog();
                  },
                );
              }
            },
          ),
        ],
      );
    });
  }
}
