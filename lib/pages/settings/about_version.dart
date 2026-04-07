import 'dart:io';
import 'package:flutter/material.dart';
import 'package:manji_trace/controllers/app_upgrade_controller.dart';
import 'package:manji_trace/pages/changelog/view.dart';
import 'package:manji_trace/utils/launch_uri_util.dart';
import 'package:manji_trace/utils/log.dart';
import 'package:manji_trace/values/values.dart';
import 'package:manji_trace/widgets/common_scaffold_body.dart';
import 'package:manji_trace/widgets/rotated_logo.dart';
import 'package:manji_trace/widgets/svg_asset_icon.dart';
import 'package:manji_trace/modules/load_status/status.dart';

class AboutVersion extends StatefulWidget {
  const AboutVersion({Key? key}) : super(key: key);

  @override
  _AboutVersionState createState() => _AboutVersionState();
}

class _AboutVersionState extends State<AboutVersion> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("关于版本"),
      ),
      body: CommonScaffoldBody(child: _buildBody(context)),
    );
  }

  Stack _buildBody(BuildContext context) {
    return Stack(
      children: [
        ListView(
          children: [
            Column(
              children: [
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: RotatedLogo(size: 72),
                ),
                Text("当前版本: ${AppUpgradeController.to.curVersion}"),
                _buildWebsiteIconsRow(context),
              ],
            ),
            ListTile(
                title: const Text("更新日志"),
                onTap: () {
                  Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (context) => const ChangelogPage()));
                }),
            const ListTile(title: Text("导出日志"), onTap: AppLog.share),
          ],
        ),
      ],
    );
  }

  Row _buildWebsiteIconsRow(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          splashRadius: 20,
          onPressed: () {
            LaunchUrlUtil.launch(
                context: context,
                uriStr: "https://github.com/Baidetar/anime_trace");
          },
          icon: SvgAssetIcon(
            assetPath: Assets.icons.github,
            color: Theme.of(context).brightness == Brightness.dark
                ? Colors.white
                : Colors.black,
          ),
        ),
      ],
    );
  }
}
