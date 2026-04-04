import 'package:get/get.dart';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:animetrace/dao/history_dao.dart';
import 'package:animetrace/models/history_plus.dart';
import 'package:animetrace/models/journal_note.dart';
import 'package:animetrace/models/params/page_params.dart';
import 'package:animetrace/utils/log.dart';
import 'package:animetrace/utils/sp_util.dart';
import 'package:ming_cute_icons/ming_cute_icons.dart';

enum HistoryLabel {
  year("年", MingCuteIcons.mgc_calendar_line),
  month("月", MingCuteIcons.mgc_calendar_line),
  day("日", MingCuteIcons.mgc_calendar_line);

  final String title;
  final IconData iconData;
  const HistoryLabel(this.title, this.iconData);
}

class HistoryView {
  HistoryLabel label;
  PageParams pageParams;
  int dateLength; // 用于匹配数据库中日期xxxx-xx-xx的子串
  List<HistoryPlus> historyRecords = [];
  ScrollController scrollController = ScrollController();

  HistoryView(
      {required this.label,
      required this.pageParams,
      required this.dateLength});
}

class HistoryController extends GetxController {
  static HistoryController get to => Get.find();

  List<HistoryView> views = [
    HistoryView(
        label: HistoryLabel.year,
        pageParams: PageParams(pageIndex: 0, pageSize: 5),
        dateLength: 4),
    HistoryView(
        label: HistoryLabel.month,
        pageParams: PageParams(pageIndex: 0, pageSize: 10),
        dateLength: 7),
    HistoryView(
        label: HistoryLabel.day,
        pageParams: PageParams(pageIndex: 0, pageSize: 15),
        dateLength: 10)
  ];

  bool loadOk = false;

  int curViewIndex =
      SPUtil.getInt("selectedViewIndexInHistoryPage", defaultValue: 1);
  HistoryLabel get selectedHistoryLabel => views[curViewIndex].label;
  bool _loadingFirst = false;

  PageController? pageController;

  // 缓存最后一次加载的数据，避免快速重复查询
  final Map<String, DateTime> _lastLoadTime = {};
  static const Duration _cacheValidDuration = Duration(seconds: 5);

  @override
  void onClose() {
    for (var view in views) {
      view.scrollController.dispose();
    }
    pageController?.dispose();
    super.onClose();
  }

  Future<void> loadData() async {
    AppLog.info("HistoryController.loadData: 加载全部视图");
    // 切换导航后重新渲染State中的PageView时，展示的页号始终是initialPage(可能和curViewIndex不对应)，所以此处重新创建PageController
    pageController?.dispose();
    pageController = PageController(initialPage: curViewIndex);
    _loadingFirst = true;

    final futures = <Future>[];
    for (var view in views) {
      view.pageParams.resetPageIndex();
      futures.add(Future(() async {
        view.historyRecords = await HistoryDao.getHistoryPageable(
            pageParams: view.pageParams, dateLength: view.dateLength);
      }));
    }
    await Future.wait(futures);

    loadOk = true;
    _loadingFirst = false;
    update();
  }

  /// 只刷新当前视图，避免不必要的数据库查询
  Future<void> refreshCurrentViewOnly() async {
    if (_loadingFirst) return;

    final view = views[curViewIndex];
    final cacheKey = "view_${view.label.name}";
    final lastLoad = _lastLoadTime[cacheKey];

    // 检查缓存是否有效（5秒内不重复加载）
    if (lastLoad != null &&
        DateTime.now().difference(lastLoad) < _cacheValidDuration) {
      AppLog.info(
          "HistoryController.refreshCurrentViewOnly: 缓存有效，跳过重新加载 (${view.label.title})");
      return;
    }

    AppLog.info("HistoryController.refreshCurrentViewOnly: 刷新视图 (${view.label.title})");
    view.pageParams.resetPageIndex();
    view.historyRecords = await HistoryDao.getHistoryPageable(
        pageParams: view.pageParams, dateLength: view.dateLength);

    _lastLoadTime[cacheKey] = DateTime.now();
    update();
  }

  /// 当添加新日记时的增量更新
  Future<void> onNoteAdded(JournalNote note) async {
    AppLog.info("HistoryController.onNoteAdded: 日记已添加，刷新当前视图");
    // 清除缓存，强制刷新
    _lastLoadTime.clear();
    await refreshCurrentViewOnly();
  }

  /// 当更新日记时的增量更新
  Future<void> onNoteUpdated(JournalNote note) async {
    AppLog.info("HistoryController.onNoteUpdated: 日记已更新，刷新当前视图");
    // 清除缓存，强制刷新
    _lastLoadTime.clear();
    await refreshCurrentViewOnly();
  }

  /// 当删除日记时的增量更新
  Future<void> onNoteDeleted(int noteId) async {
    AppLog.info("HistoryController.onNoteDeleted: 日记已删除，刷新当前视图");
    // 清除缓存，强制刷新
    _lastLoadTime.clear();
    await refreshCurrentViewOnly();
  }

  Future<void> loadMoreData() async {
    if (_loadingFirst) return;

    final view = views[curViewIndex];
    view.pageParams.pageIndex++;
    views[curViewIndex].historyRecords.addAll(
        await HistoryDao.getHistoryPageable(
            pageParams: view.pageParams, dateLength: view.dateLength));
    update();
  }
}
