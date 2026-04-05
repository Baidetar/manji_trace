import 'package:flutter/material.dart';
import 'package:manji_trace/models/journal_note.dart';
import 'package:manji_trace/pages/journal_note/journal_note_controller.dart';
import 'package:manji_trace/pages/journal_note/widgets/journal_note_editor.dart';
import 'package:manji_trace/components/empty_data_hint.dart';
import 'package:manji_trace/utils/time_util.dart';
import 'package:manji_trace/widgets/common_scaffold_body.dart';
import 'package:manji_trace/components/search_app_bar.dart';
import 'package:manji_trace/components/common_image.dart';
import 'package:get/get.dart';
import 'package:pull_to_refresh/pull_to_refresh.dart';

class JournalNoteListPage extends StatefulWidget {
  const JournalNoteListPage({Key? key}) : super(key: key);

  @override
  State<JournalNoteListPage> createState() => _JournalNoteListPageState();
}

class _JournalNoteListPageState extends State<JournalNoteListPage> {
  final controller = Get.put(JournalNoteController());
  final RefreshController _refreshController = RefreshController();
  final TextEditingController _searchController = TextEditingController();
  bool _isSearching = false;

  @override
  void initState() {
    super.initState();
    controller.loadNotes();
  }

  @override
  void dispose() {
    _refreshController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _buildAppBar(),
      body: CommonScaffoldBody(
        child: SmartRefresher(
          controller: _refreshController,
          enablePullDown: true,
          enablePullUp: true,
          onRefresh: _onRefresh,
          onLoading: _onLoading,
          child: GetBuilder<JournalNoteController>(
            builder: (ctrl) {
              if (ctrl.noteList.isEmpty) {
                return Center(
                  child: emptyDataHint(
                    msg: _isSearching ? "没有找到匹配的笔记" : "暂无笔记，点击右上角+快速创建",
                  ),
                );
              }

              return ListView.builder(
                padding: const EdgeInsets.only(bottom: 80),
                itemCount: ctrl.noteList.length,
                itemBuilder: (context, index) {
                  return _buildNoteItem(ctrl.noteList[index]);
                },
              );
            },
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _createNewNote,
        tooltip: "新建日记",
        child: const Icon(Icons.add),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    if (_isSearching) {
      return SearchAppBar(
        inputController: _searchController,
        hintText: "搜索日记标题或内容...",
        onChanged: (val) {
          controller.searchNotes(val);
        },
        onTapClear: () {
          _searchController.clear();
          controller.searchNotes("");
        },
        showCancelButton: true,
        onTapCancelButton: () {
          setState(() {
            _isSearching = false;
            _searchController.clear();
            controller.searchNotes("");
          });
        },
      );
    }

    return AppBar(
      title: const Text("日记"),
      actions: [
        IconButton(
          icon: const Icon(Icons.search),
          onPressed: () {
            setState(() {
              _isSearching = true;
            });
          },
        ),
        const SizedBox(width: 8),
      ],
    );
  }

  Widget _buildNoteItem(JournalNote note) {
    final hasImages = note.relativeLocalImages.isNotEmpty;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      elevation: 0,
      // 移除显式的 side 边框和深色背景，使用透明或默认效果
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _editNote(note),
        onLongPress: () => _showDeleteDialog(note),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 统一图标风格：使用与编辑器一致的 book_outlined，并增加轻量背景
              if (!hasImages)
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      Icons.book_outlined,
                      size: 24,
                      color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.6),
                    ),
                  ),
                ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      note.title.isEmpty ? "未命名笔记" : note.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      note.content.isEmpty ? "无内容" : note.content,
                      maxLines: 2, // 保持与笔记列表一致的紧凑感
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                            height: 1.3,
                          ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Text(
                          TimeUtil.getHumanReadableDateTimeStr(note.createTime),
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                color: Theme.of(context).colorScheme.outline,
                              ),
                        ),
                        if (hasImages) ...[
                          const SizedBox(width: 12),
                          Icon(
                            Icons.image_outlined,
                            size: 12,
                            color: Theme.of(context).colorScheme.outline,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '${note.relativeLocalImages.length}',
                            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                  color: Theme.of(context).colorScheme.outline,
                                ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              if (hasImages)
                Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: 64, // 略微缩小图片，使其更精致
                      height: 64,
                      child: CommonImage(
                        note.relativeLocalImages.first.path,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _createNewNote() async {
    final note = JournalNote(
      title: "",
      content: "",
      createTime: TimeUtil.getDateTimeNowStr(),
      relativeLocalImages: [],
    );
    // 使用 silent 模式静默创建，不触发列表刷新，防止列表闪烁
    await controller.createNote(note, silent: true);

    // 等待跳转返回
    await Get.to(() => JournalNoteEditor(
          note: note,
          onSave: (title, content, createTime) async {
            note.title = title;
            note.content = content;
            note.createTime = createTime;
            await controller.updateNote(note);
          },
        ));
    
    // 从编辑器返回后，全量刷新列表以同步状态
    controller.loadNotes();
  }

  void _editNote(JournalNote note) {
    Get.to(() => JournalNoteEditor(
          note: note,
          onSave: (title, content, createTime) async {
            note.title = title;
            note.content = content;
            note.createTime = createTime;
            await controller.updateNote(note);
          },
        ));
  }

  void _showDeleteDialog(JournalNote note) {
    Get.defaultDialog(
      title: "删除确认",
      titleStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      middleText: "确定删除笔记 \"${note.title.isEmpty ? "未命名笔记" : note.title}\" 吗？此操作不可撤销。",
      textConfirm: "删除",
      textCancel: "取消",
      confirmTextColor: Colors.white,
      buttonColor: Theme.of(context).colorScheme.error,
      onConfirm: () async {
        await controller.deleteNote(note.id);
        Get.back();
      },
    );
  }

  void _onRefresh() async {
    controller.currentPage = 1;
    await controller.loadNotes();
    _refreshController.refreshCompleted();
  }

  void _onLoading() async {
    controller.currentPage++;
    bool hasMore = await controller.loadMoreNotes();
    if (hasMore) {
      _refreshController.loadComplete();
    } else {
      _refreshController.loadNoData();
    }
  }
}

