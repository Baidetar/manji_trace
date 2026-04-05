import 'package:flutter/material.dart';
import 'package:manji_trace/models/journal_note.dart';
// import 'package:manji_trace/models/params/page_params.dart';
import 'package:manji_trace/pages/journal_note/journal_note_controller.dart';
import 'package:manji_trace/pages/journal_note/widgets/journal_note_editor.dart';
import 'package:manji_trace/components/empty_data_hint.dart';
import 'package:manji_trace/utils/time_util.dart';
import 'package:manji_trace/widgets/common_scaffold_body.dart';
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

  @override
  void initState() {
    super.initState();
    controller.loadNotes();
  }

  @override
  void dispose() {
    _refreshController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("日记"),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: _createNewNote,
            tooltip: "新建日记",
          )
        ],
      ),
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
                  child: emptyDataHint(msg: "暂无笔记，点击右上角+快速创建"),
                );
              }

              return ListView.builder(
                itemCount: ctrl.noteList.length,
                itemBuilder: (context, index) {
                  return _buildNoteItem(ctrl.noteList[index]);
                },
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildNoteItem(JournalNote note) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: ListTile(
        title: Text(
          note.title.isEmpty ? "未命名笔记" : note.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w500),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (note.relativeLocalImages.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    const Icon(Icons.image, size: 16, color: Colors.grey),
                    const SizedBox(width: 4),
                    Text(
                      '${note.relativeLocalImages.length} 张图片',
                      style: TextStyle(
                        color: Colors.grey[600],
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 4),
            Text(
              note.content.isEmpty ? "无内容" : note.content,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.grey[600],
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              TimeUtil.getHumanReadableDateTimeStr(note.createTime),
              style: TextStyle(
                color: Colors.grey[400],
                fontSize: 12,
              ),
            ),
          ],
        ),
        onTap: () => _editNote(note),
        onLongPress: () => _showDeleteDialog(note),
        trailing: PopupMenuButton(
          itemBuilder: (context) => [
            PopupMenuItem(
              child: const Text("编辑"),
              onTap: () => _editNote(note),
            ),
            PopupMenuItem(
              child: const Text("删除"),
              onTap: () => _showDeleteDialog(note),
            ),
          ],
        ),
      ),
    );
  }

  void _createNewNote() {
    Get.to(() => JournalNoteEditor(
      onSave: (title, content, createTime) async {
        final note = JournalNote(
          title: title,
          content: content,
          createTime: createTime,
          relativeLocalImages: [], // 新笔记没有图片
        );
        await controller.createNote(note);
        Get.back();
      },
    ));
  }

  void _editNote(JournalNote note) {
    Get.to(() => JournalNoteEditor(
      note: note,
      onSave: (title, content, createTime) async {
        note.title = title;
        note.content = content;
        note.createTime = createTime;
        await controller.updateNote(note);
        Get.back();
      },
    ));
  }

  void _showDeleteDialog(JournalNote note) {
    Get.defaultDialog(
      title: "删除笔记",
      middleText: "确定删除笔记 \"${note.title.isEmpty ? "未命名笔记" : note.title}\" 吗？",
      onConfirm: () async {
        await controller.deleteNote(note.id);
        Get.back();
        _refreshController.requestRefresh();
      },
      onCancel: () {},
      confirmTextColor: Colors.white,
      cancelTextColor: Colors.black,
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
