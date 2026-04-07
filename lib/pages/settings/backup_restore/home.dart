import 'package:flutter/material.dart';
import 'package:manji_trace/pages/settings/backup_restore/local.dart';
import 'package:manji_trace/pages/settings/backup_restore/remote.dart';
import 'package:manji_trace/pages/settings/pages/rbr_page.dart';
import 'package:manji_trace/routes/get_route.dart';
import 'package:manji_trace/utils/backup_util.dart';
import 'package:manji_trace/utils/sqlite_util.dart';
import 'package:manji_trace/utils/toast_util.dart';
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
                    int count = await SqliteUtil.migrateOldImageData();
                    ToastUtil.showText("修复完成，共处理 $count 条记录");
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
