import 'package:manji_trace/widgets/connected_button_groups.dart';
import 'package:flutter/material.dart';

import 'package:manji_trace/components/anime_list_cover.dart';
import 'package:manji_trace/components/empty_data_hint.dart';
import 'package:manji_trace/animation/fade_animated_switcher.dart';
import 'package:manji_trace/dao/history_dao.dart';
import 'package:manji_trace/models/anime_history_record.dart';
import 'package:manji_trace/models/union_history_record.dart';
import 'package:manji_trace/pages/anime_detail/anime_detail.dart';
import 'package:manji_trace/pages/history/history_controller.dart';
import 'package:manji_trace/pages/journal_note/journal_note_controller.dart';
import 'package:manji_trace/pages/journal_note/widgets/journal_note_editor.dart';
import 'package:manji_trace/utils/log.dart';
import 'package:manji_trace/utils/sp_util.dart';
import 'package:manji_trace/utils/time_util.dart';
import 'package:manji_trace/values/theme.dart';
import 'package:manji_trace/widgets/common_divider.dart';
import 'package:manji_trace/widgets/responsive.dart';
import 'package:manji_trace/widgets/setting_title.dart';
import 'package:get/get.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({Key? key}) : super(key: key);

  @override
  _HistoryPageState createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  HistoryController historyController = Get.put(HistoryController());
  List<HistoryView> get views => historyController.views;

  @override
  void initState() {
    historyController.loadData();
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _buildMaterialViewSwitch(),
            Expanded(
              child: GetBuilder<HistoryController>(
                init: historyController,
                builder: (_) => PageView(
                  // 后期如果需要滑动切换视图可以放开
                  physics: const NeverScrollableScrollPhysics(),
                  controller: historyController.pageController,
                  children: historyController.views
                      .map((e) => _buildHistoryPage(e))
                      .toList(),
                  onPageChanged: (index) {
                    setState(() {
                      historyController.curViewIndex = index;
                    });
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMaterialViewSwitch() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ConnectedButtonGroups<int>(
            items: historyController.views
                .map((e) => ConnectedButtonItem(
                      // icon: Icon(e.label.iconData),
                      label: e.label.title,
                      value: e.label.index,
                    ))
                .toList(),
            selected: {historyController.selectedHistoryLabel.index},
            onSelectionChanged: (newSelection) {
              final to = newSelection.first;
              setState(() {
                historyController.curViewIndex = to;
              });
              historyController.pageController?.jumpToPage(to);
              SPUtil.setInt("selectedViewIndexInHistoryPage", to);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildHistoryPage(HistoryView view) {
    return FadeAnimatedSwitcher(
      loadOk: historyController.loadOk,
      destWidget: view.historyRecords.isEmpty
          ? emptyDataHint(msg: "没有历史。")
          : RefreshIndicator(
              onRefresh: () async => await historyController.loadData(),
              child: _RecordListView(
                view: view,
                loadMoreData: historyController.loadMoreData,
              ),
            ),
    );
  }
}

class _RecordListView extends StatefulWidget {
  const _RecordListView({required this.view, required this.loadMoreData});
  final HistoryView view;
  final VoidCallback loadMoreData;

  @override
  State<_RecordListView> createState() => __RecordListViewState();
}

class __RecordListViewState extends State<_RecordListView>
    with AutomaticKeepAliveClientMixin {
  HistoryView get view => widget.view;

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);

    return Scrollbar(
      controller: view.scrollController,
      child: SuperListView.separated(
        separatorBuilder: (context, index) => const CommonDivider(thinkness: 0),
        // 保留滚动位置，注意：如果滚动位置在加载更多的数据中，那么重新打开当前页面若重新加载数据，则恢复滚动位置不合适，故不采用
        // key: PageStorageKey("history-page-view-$selectedViewIndex"),
        // 指定key后，才能保证切换回历史页时，update()后显示最新数据
        // key: UniqueKey(),
        // 但不能指定为UniqueKey，否则加载更多时会直接跳转到顶部。可是指定这个下面key又会导致没有显示最新数据，并且新增历史后不匹配
        // 推测是RecordItem的key问题，后来为RecordItem添加UniqueKey后正确。
        // key: Key("history-page-view-$selectedViewIndex"),
        controller: view.scrollController,
        itemCount: view.historyRecords.length,
        itemBuilder: (context, cardIndex) {
          int threshold = view.pageParams.getQueriedSize();
          if (cardIndex + 2 == threshold) {
            AppLog.info("index=$cardIndex, threshold=$threshold");
            widget.loadMoreData();
          }

          String date = view.historyRecords[cardIndex].date;
          final records = view.historyRecords[cardIndex].records;

          return Card(
            child: Column(
              children: [
                // 卡片标题
                SettingTitle(
                  title: TimeUtil.isUnRecordedDateTimeStr(date)
                      ? '其他'
                      : date.replaceAll("-", "/"),
                  // trailing: Text(
                  //   "${view.historyRecords[cardIndex].records.length}个动漫",
                  //   style: Theme.of(context).textTheme.bodySmall,
                  // ),
                ),
                // 卡片主体
                Responsive(
                  mobile: ListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                itemCount: records.length,
                itemBuilder: (context, recordIndex) {
                  final record = records[recordIndex];
                  return _RecordItem(
                      record: record, date: date, useCard: false);
                },
              ),
              desktop: GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate:
                    const SliverGridDelegateWithMaxCrossAxisExtent(
                        mainAxisExtent: 80, maxCrossAxisExtent: 320),
                itemCount: records.length,
                itemBuilder: (context, recordIndex) {
                  final record = records[recordIndex];
                  return _RecordItem(
                      record: record, date: date, useCard: true);
                },
              ),
                ),
                // 避免最后一项太靠近卡片底部，因为标题没有紧靠顶部，所以会导致不美观
                const SizedBox(height: 5)
              ],
            ),
          );
        },
      ),
    );
  }
}

class _RecordItem extends StatefulWidget {
  final UnionHistoryRecord record;
  final String date;
  final bool useCard;

  const _RecordItem(
      {required this.record, required this.date, this.useCard = true});

  @override
  State<_RecordItem> createState() => _RecordItemState();
}

class _RecordItemState extends State<_RecordItem> {
  UnionHistoryRecord get record => widget.record;

  @override
  Widget build(BuildContext context) {
    // 根据类型渲染不同的UI
    if (record.isAnime) {
      return _buildAnimeItem(context);
    } else {
      return _buildNoteItem(context);
    }
  }

  // 动画历史项目
  Widget _buildAnimeItem(BuildContext context) {
    final animeRecord = record.animeRecord!;
    if (widget.useCard) {
      return Card(
        margin: const EdgeInsets.symmetric(horizontal: 8),
        child: Center(
          child: _buildAnimeItemContent(context, animeRecord),
        ),
      );
    }
    return _buildAnimeItemContent(context, animeRecord);
  }

  InkWell _buildAnimeItemContent(
      BuildContext context, AnimeHistoryRecord animeRecord) {
    return InkWell(
      borderRadius:
          widget.useCard ? BorderRadius.circular(AppTheme.cardRadius) : null,
      onTap: () {
        Navigator.of(context).push(MaterialPageRoute(
          builder: (context) {
            return AnimeDetailPage(animeRecord.anime);
          },
        )).then((value) async {
          final newRecord =
              await HistoryDao.getRecordByAnimeIdAndReviewNumberAndDate(
                  animeRecord.anime, animeRecord.reviewNumber, widget.date);
          animeRecord.assign(newRecord);
          setState(() {});
        });
      },
      child: ListTile(
        leading: AnimeListCover(
          animeRecord.anime,
          reviewNumber: animeRecord.reviewNumber,
          showReviewNumber: true,
        ),
        subtitle: Text(
          (animeRecord.startEpisodeNumber == animeRecord.endEpisodeNumber
              ? animeRecord.startEpisodeNumber.toString()
              : "${animeRecord.startEpisodeNumber}~${animeRecord.endEpisodeNumber}"),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        title: Text(
          animeRecord.anime.animeName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  // 日记项目
  Widget _buildNoteItem(BuildContext context) {
    final note = record.noteRecord!;
    if (widget.useCard) {
      return Card(
        margin: const EdgeInsets.symmetric(horizontal: 8),
        child: Center(
          child: _buildNoteItemContent(context, note),
        ),
      );
    }
    return _buildNoteItemContent(context, note);
  }

  InkWell _buildNoteItemContent(BuildContext context, final note) {
    return InkWell(
      borderRadius:
          widget.useCard ? BorderRadius.circular(AppTheme.cardRadius) : null,
      onTap: () {
        Get.to(() => JournalNoteEditor(
          note: note,
          onSave: (title, content, createTime) async {
            note.title = title;
            note.content = content;
            note.createTime = createTime;
            await Get.find<JournalNoteController>().updateNote(note);
            setState(() {});
          },
        ));
      },
      child: ListTile(
        leading: Icon(
          Icons.note,
          color: Theme.of(context).primaryColor,
          size: 32,
        ),
        title: Text(
          note.title.isEmpty ? '未命名笔记' : note.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (note.content.isNotEmpty)
              Text(
                note.content,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.grey[600],
                  fontSize: 12,
                ),
              ),
            if (note.relativeLocalImages.isNotEmpty)
              Text(
                '${note.relativeLocalImages.length} 张图片',
                style: TextStyle(
                  color: Colors.grey[500],
                  fontSize: 11,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
