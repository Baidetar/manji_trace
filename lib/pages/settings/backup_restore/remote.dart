import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:manji_trace/components/dialog/dialog_select_uint.dart';
import 'package:manji_trace/controllers/backup_service.dart';
import 'package:manji_trace/controllers/remote_controller.dart';
import 'package:manji_trace/pages/anime_collection/checklist_controller.dart';
import 'package:manji_trace/pages/settings/backup_file_list.dart';
import 'package:manji_trace/pages/settings/backup_restore/home.dart';
import 'package:manji_trace/pages/settings/backup_restore/login_form.dart';
import 'package:manji_trace/routes/get_route.dart';
import 'package:manji_trace/utils/backup_util.dart';
import 'package:manji_trace/utils/sp_util.dart';
import 'package:manji_trace/utils/webdav_util.dart';
import 'package:manji_trace/values/values.dart';
import 'package:manji_trace/utils/toast_util.dart';
import 'package:manji_trace/widgets/common_status_prompt.dart';
import 'package:manji_trace/widgets/setting_card.dart';
import 'package:get/get.dart';
import 'package:ming_cute_icons/ming_cute_icons.dart';

class RemoteBackupPage extends StatefulWidget {
  const RemoteBackupPage({
    Key? key,
    this.fromHome = false,
  }) : super(key: key);
  final bool fromHome;

  @override
  State<RemoteBackupPage> createState() => _RemoteBackupPageState();
}

class _RemoteBackupPageState extends State<RemoteBackupPage> {
  int autoBackupWebDavNumber =
      SPUtil.getInt("autoBackupWebDavNumber", defaultValue: 20);
  int webdavTimeout =
      SPUtil.getInt("webdav_timeout", defaultValue: 30000);
  bool canManualBackup = true;

  BackupService get backupService => BackupService.to;

  bool get autoBackupIsOff =>
      backupService.curRemoteBackupMode == BackupMode.close;
  bool get autoBackupIsOn => !autoBackupIsOff;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      WebDavUtil.pingWebDav();
    });
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        children: [
          SettingCard(
            title: 'WebDav 备份',
            useCard: !widget.fromHome,
            titleStyle: widget.fromHome
                ? Theme.of(context).textTheme.titleMedium
                : null,
            trailing: widget.fromHome
                ? IconButton(
                    color: Theme.of(context).iconTheme.color,
                    splashRadius: 20,
                    onPressed: () {
                      RouteUtil.materialTo(
                          context, const BackupAndRestorePage());
                    },
                    icon: const Icon(MingCuteIcons.mgc_arrow_right_line))
                : null,
            children: [
              GetBuilder(
                init: RemoteController.to,
                builder: (_) => ListTile(
                  title: const Text("登录帐号"),
                  trailing: Icon(
                    Icons.circle,
                    size: 12,
                    color: RemoteController.to.isOnline
                        ? AppTheme.connectableColor
                        : Colors.grey,
                  ),
                  onTap: () {
                    _toWebDavLoginPage();
                  },
                ),
              ),
              ListTile(
                title: const Text("立即备份"),
                subtitle: const Text("点击进行备份，备份目录为 /animetrace"),
                onTap: () async {
                  if (RemoteController.to.isOffline) {
                    ToastUtil.showText("请先配置帐号，再进行备份");
                    return;
                  }

                  if (!canManualBackup) {
                    ToastUtil.showText("备份间隔为10s");
                    return;
                  }

                  canManualBackup = false;
                  Future.delayed(const Duration(seconds: 10))
                      .then((value) => canManualBackup = true);

                  ToastUtil.showText("正在备份");
                  String remoteBackupDirPath =
                      await WebDavUtil.getRemoteDirPath();
                  if (remoteBackupDirPath.isNotEmpty) {
                    BackupUtil.backup(remoteBackupDirPath: remoteBackupDirPath);
                  }
                },
              ),
              ListTile(
                title: const Text("还原备份"),
                subtitle: const Text("选择备份文件进行还原"),
                onTap: () async {
                  if (RemoteController.to.isOffline) {
                    ToastUtil.showText("请先配置帐号，再进行还原");
                    return;
                  }

                  RouteUtil.materialTo(context, const BackUpFileListPage());
                },
              ),
              _buildAutoBackupPrompt(),
              ListTile(
                title: const Text("连接超时"),
                subtitle: Text("当前超时时间: ${webdavTimeout ~/ 1000}s"),
                trailing: const Icon(Icons.chevron_right),
                onTap: _handleSelectWebDavTimeout,
              ),
            ],
          ),
          if (!widget.fromHome)
            SettingCard(
              title: '高级配置',
              children: [
                SwitchListTile(
                  title: const Text("自动还原"),
                  subtitle: const Text("进入应用前还原最新数据\n注意：选择「打开应用后自动备份」时不会生效"),
                  value: backupService.enableAutoRestoreFromRemote,
                  onChanged: (value) {
                    backupService.setAutoRestoreFromRemote(value);
                    // 重绘页面
                    setState(() {});
                  },
                ),
                SwitchListTile(
                  title: const Text("下拉还原"),
                  subtitle: const Text("动漫收藏页下拉时，会尝试还原最新数据"),
                  value: SPUtil.getBool(
                      pullDownRestoreLatestBackupInChecklistPage),
                  onChanged: (value) {
                    SPUtil.setBool(
                        pullDownRestoreLatestBackupInChecklistPage, value);
                    // 重绘页面
                    setState(() {});
                    // 重绘收藏页，以便于允许或取消下拉刷新
                    ChecklistController.to.update();
                  },
                ),
                if (Platform.isWindows)
                  SwitchListTile(
                    title: const Text("快捷键还原"),
                    subtitle: const Text("动漫收藏页中按下 Ctrl+R 时，会尝试还原最新数据"),
                    value: Config.enableRestoreLatestHotkey,
                    onChanged: (value) {
                      Config.toggleEnableRestoreLatestHotkey(value);
                      setState(() {});
                      if (value) {
                        ChecklistController.to.tryRegisterRestoreLatestHotkey();
                      } else {
                        ChecklistController.to.unregisterRestoreLatestHotkey();
                      }
                    },
                  ),
              ],
            ),
        ],
      ),
    );
  }

  void _handleSelectAutoBackupNumber() async {
    int? number = await dialogSelectUint(context, "备份数量",
        initialValue: autoBackupWebDavNumber, minValue: 10, maxValue: 20);
    if (number != null) {
      autoBackupWebDavNumber = number;
      SPUtil.setInt("autoBackupWebDavNumber", number);
      setState(() {});
    }
  }

  void _handleSelectWebDavTimeout() async {
    final Map<int, String> options = {
      8000: "8秒 (原默认)",
      15000: "15秒",
      30000: "30秒 (推荐)",
      60000: "60秒",
      120000: "120秒",
    };

    int? selected = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text("设置超时时间"),
        children: options.entries.map((e) {
          return RadioListTile<int>(
            title: Text(e.value),
            value: e.key,
            groupValue: webdavTimeout,
            onChanged: (value) {
              Navigator.pop(context, value);
            },
          );
        }).toList(),
      ),
    );

    if (selected != null && selected != webdavTimeout) {
      setState(() {
        webdavTimeout = selected;
      });
      SPUtil.setInt("webdav_timeout", selected);
      ToastUtil.showText("超时时间已设置为 ${selected ~/ 1000}s，下次连接生效");

      // 尝试重新初始化以立即应用设置
      if (RemoteController.to.isOnline) {
        WebDavUtil.initWebDav(
          SPUtil.getString("webdav_uri"),
          SPUtil.getString("webdav_user"),
          SPUtil.getString("webdav_password"),
        );
      }
    }
  }

  _buildAutoBackupPrompt() {
    const configTitleStyle = TextStyle(fontSize: 14);
    final configSubtitleStyle = TextStyle(
      fontSize: 13,
      color: Theme.of(context).hintColor,
    );

    return autoBackupIsOff
        ? CommonStatusPrompt(
            icon: const Icon(Icons.cloud_off),
            titleText: '自动备份未开启',
            subtitleText: '开启自动备份后，可在打开应用时或关闭应用前自动进行备份',
            buttonText: '开启自动备份',
            onTapButton: () {
              backupService.setBackupMode(BackupMode.backupAfterOpenApp.name);
              setState(() {});
            },
          )
        : CommonStatusPrompt(
            icon: Icon(Icons.cloud_outlined,
                color: Theme.of(context).colorScheme.primary),
            titleText: '自动备份已开启',
            // subtitleText: '开启自动备份后，可在打开应用时或关闭应用前自动进行备份',
            subtitle: Column(
              children: [
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () {
                    _handleSelectAutoBackupMode();
                  },
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(vertical: 12, horizontal: 5),
                    child: Row(
                      children: [
                        const Text("备份时机", style: configTitleStyle),
                        const Spacer(),
                        Row(
                          children: [
                            Text(backupService.curRemoteBackupMode.title,
                                style: configSubtitleStyle),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () {
                    _handleSelectAutoBackupNumber();
                  },
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(vertical: 10, horizontal: 5),
                    child: Row(
                      children: [
                        const Text("备份数量", style: configTitleStyle),
                        const Spacer(),
                        Text("$autoBackupWebDavNumber",
                            style: configSubtitleStyle),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            buttonText: '关闭自动备份',
            onTapButton: () {
              backupService.setBackupMode(BackupMode.close.name);
              setState(() {});
            },
          );
  }

  Future<dynamic> _handleSelectAutoBackupMode() {
    return showDialog(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text("备份时机"),
        children: [
          for (int i = 0; i < BackupMode.values.length; ++i)
            BackupMode.values[i] == BackupMode.close
                ? const SizedBox()
                : RadioListTile( // ignore: deprecated_member_use
                    title: Text(BackupMode.values[i].title),
                    value: BackupMode.values[i].name,
                    groupValue: backupService.curRemoteBackupModeName,
                    onChanged: (String? value) {
                      if (value == null) return;

                      backupService.setBackupMode(value);
                      // 关闭对话框
                      Navigator.pop(context);
                      // 重绘页面
                      setState(() {});
                    }),
        ],
      ),
    );
  }

  void _toWebDavLoginPage() async {
    await RouteUtil.materialTo(context, const WebDavLoginForm());
    setState(() {});
  }
}
