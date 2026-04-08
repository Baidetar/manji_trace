import 'dart:io';

import 'package:flutter/material.dart';
import 'package:manji_trace/models/journal_note.dart';
import 'package:manji_trace/models/relative_local_image.dart';
import 'package:manji_trace/models/enum/note_type.dart';
import 'package:manji_trace/utils/image_util.dart';
import 'package:manji_trace/utils/time_util.dart';
import 'package:manji_trace/utils/toast_util.dart';
import 'package:manji_trace/utils/sqlite_util.dart';
import 'package:manji_trace/components/note/note_img_item.dart';
import 'package:manji_trace/values/theme.dart';
import 'package:manji_trace/global.dart';
import 'package:manji_trace/dao/image_dao.dart';
import 'package:manji_trace/dao/journal_note_dao.dart';
import 'package:manji_trace/pages/journal_note/journal_note_controller.dart';
import 'package:manji_trace/pages/history/history_controller.dart';
import 'package:get/get.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:reorderable_grid_view/reorderable_grid_view.dart';
import 'package:manji_trace/widgets/responsive.dart';
import 'package:manji_trace/utils/log.dart';
import 'package:path/path.dart' as p;

import '../../../widgets/picker/date_time_picker.dart';

class JournalNoteEditor extends StatefulWidget {
  final JournalNote? note;
  final Function(String title, String content, String createTime) onSave;

  const JournalNoteEditor({
    Key? key,
    this.note,
    required this.onSave,
  }) : super(key: key);

  @override
  State<JournalNoteEditor> createState() => _JournalNoteEditorState();
}

class _JournalNoteEditorState extends State<JournalNoteEditor> {
  late TextEditingController _titleController;
  late TextEditingController _contentController;
  late String _createTime;
  bool changeOrderIdx = false;
  final scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.note?.title ?? "");
    _contentController = TextEditingController(text: widget.note?.content ?? "");
    _createTime = widget.note?.createTime ?? TimeUtil.getDateTimeNowStr();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    scrollController.dispose();
    super.dispose();
  }

  void _onWillPop() async {
    // 如果没有任何内容且没有图片，则自动删除该记录并返回（针对新建后又放弃的情况）
    if (_titleController.text.isEmpty && 
        _contentController.text.isEmpty && 
        (widget.note?.relativeLocalImages.isEmpty ?? true)) {
      if (widget.note != null) {
        // 直接从数据库和列表中删除
        try {
          // 确保控制器存在
          final controller = Get.isRegistered<JournalNoteController>() 
              ? Get.find<JournalNoteController>() 
              : Get.put(JournalNoteController());
          await controller.deleteNote(widget.note!.id);
        } catch (e) {
          // 如果还是失败，直接调用 DAO
          await JournalNoteDao.deleteNote(widget.note!.id);
          try {
             Get.find<HistoryController>().onNoteDeleted(widget.note!.id);
          } catch (_) {}
        }
      }
      Navigator.of(context).pop();
      return;
    }

    // 检查是否有修改
    bool isChanged = _titleController.text != (widget.note?.title ?? "") ||
        _contentController.text != (widget.note?.content ?? "") ||
        _createTime != (widget.note?.createTime ?? "") ||
        changeOrderIdx;

    if (isChanged) {
      // 执行保存回调
      widget.onSave(_titleController.text, _contentController.text, _createTime);

      // 如果图片顺序发生了改变，异步更新数据库
      if (changeOrderIdx && widget.note != null) {
        for (int i = 0; i < widget.note!.relativeLocalImages.length; i++) {
          ImageDao.updateImageOrderIdxById(
            widget.note!.relativeLocalImages[i].imageId, 
            i
          );
        }
      }
    }
    Navigator.of(context).pop();
  }

  bool _dragging = false;

  Widget _buildImageDroppable({required Widget child}) {
    return DropTarget(
      onDragDone: (detail) async {
        for (var file in detail.files) {
          String? relativePath = await _copyImageAndGetPath(file.path);
          if (relativePath != null && relativePath.isNotEmpty) {
            await _addImage(relativePath);
          }
        }
        if (mounted) setState(() {});
      },
      onDragEntered: (detail) => setState(() => _dragging = true),
      onDragExited: (detail) => setState(() => _dragging = false),
      child: Container(
        color: _dragging
            ? Theme.of(context).brightness == Brightness.dark
                ? Colors.white10
                : Colors.black.withValues(alpha: 0.08)
            : Colors.transparent,
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        _onWillPop();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            onPressed: _onWillPop,
            icon: const Icon(Icons.arrow_back_rounded),
            tooltip: "返回并自动保存",
          ),
        ),
        body: _buildImageDroppable(
          child: Scrollbar(
            controller: scrollController,
            child: ListView(
              controller: scrollController,
              children: [
                _buildHeaderInfo(),
                _buildTitleField(),
                _buildContentField(),
                Responsive(
                  mobile: _buildReorderNoteImgGridView(crossAxisCount: 3),
                  tablet: _buildReorderNoteImgGridView(crossAxisCount: 5),
                  desktop: _buildReorderNoteImgGridView(crossAxisCount: 7),
                ),
                const SizedBox(height: 100),
              ],
            ),
          ),
        ),
      ),
    );
  }


  Widget _buildHeaderInfo() {
    return ListTile(
      style: ListTileStyle.drawer,
      leading: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          Icons.book_outlined,
          color: Theme.of(context).colorScheme.onPrimaryContainer,
        ),
      ),
      title: const Text(
        "日记随笔",
        style: TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: InkWell(
        onTap: _showEditTimePicker,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Text(
            TimeUtil.getHumanReadableDateTimeStr(_createTime),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                  decoration: TextDecoration.underline,
                ),
          ),
        ),
      ),
    );
  }

  _showEditTimePicker() async {
    DateTime? initialDate = DateTime.tryParse(_createTime);
    initialDate ??= DateTime.now();

    DateTime? selectedDate = await showCommonDateTimePicker(
      context: context,
      initialValue: initialDate,
    );

    if (selectedDate != null) {
      setState(() {
        _createTime = selectedDate.toString().substring(0, 19);
      });
    }
  }

  Widget _buildTitleField() {
    return TextField(
      controller: _titleController,
      decoration: const InputDecoration(
        hintText: "标题",
        contentPadding: EdgeInsets.fromLTRB(16, 16, 16, 8),
        border: InputBorder.none,
        filled: false,
        focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.transparent)),
      ),
      style: Theme.of(context).textTheme.titleLarge?.copyWith(
        fontWeight: FontWeight.bold,
      ),
      maxLines: 1,
    );
  }

  Widget _buildContentField() {
    return TextField(
      controller: _contentController,
      decoration: const InputDecoration(
        hintText: "正文",
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        border: InputBorder.none,
        filled: false,
        focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.transparent)),
      ),
      style: AppTheme.noteStyle,
      maxLines: null,
    );
  }

  Widget _buildReorderNoteImgGridView({required int crossAxisCount}) {
    return ReorderableGridView.count(
      padding: const EdgeInsets.fromLTRB(15, 15, 15, 0),
      crossAxisCount: crossAxisCount,
      crossAxisSpacing: AppTheme.noteImageSpacing,
      mainAxisSpacing: AppTheme.noteImageSpacing,
      childAspectRatio: 1,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      children: List.generate(
        widget.note?.relativeLocalImages.length ?? 0,
        (index) => Container(
          key: UniqueKey(),
          child: _buildNoteItem(index),
        ),
      ),
      dragStartDelay: const Duration(milliseconds: 200),
      onReorder: (oldIndex, newIndex) {
        if (oldIndex == newIndex || widget.note == null) return;
        setState(() {
          final element = widget.note!.relativeLocalImages.removeAt(oldIndex);
          widget.note!.relativeLocalImages.insert(newIndex, element);
        });
        changeOrderIdx = true;
      },
      dragWidgetBuilder: (int index, Widget child) => Material(
        color: Colors.transparent,
        elevation: 12,
        child: _buildNoteItem(index, showDelButton: false),
      ),
      footer: [
        if (FeatureFlag.enableSelectLocalImage) _buildAddButton(),
      ],
    );
  }

  Widget _buildAddButton() {
    final radius = BorderRadius.circular(AppTheme.noteImgRadius);
    final primary = Theme.of(context).colorScheme.primary;

    return Material(
      color: primary.withValues(alpha: 0.1),
      borderRadius: radius,
      child: InkWell(
        onTap: () async {
          if (widget.note == null) {
            // 如果是新建笔记，先保存一次以获取 ID，否则无法关联图片
            widget.onSave(_titleController.text, _contentController.text, _createTime);
            // 这里需要注意：如果是新建，父组件需要确保立即更新并重新打开或传递 ID
            // 简化处理：提示用户先输入内容
            if (_titleController.text.isEmpty && _contentController.text.isEmpty) {
              ToastUtil.showText("请先输入标题或正文");
              return;
            }
          }
          _pickLocalImages();
        },
        borderRadius: radius,
        child: Icon(Icons.add, color: primary.withValues(alpha: 0.5)),
      ),
    );
  }

  Stack _buildNoteItem(int imageIndex, {bool showDelButton = true}) {
    return Stack(
      children: [
        NoteImgItem(
          relativeLocalImages: widget.note!.relativeLocalImages,
          isJournalImage: true,
          initialIndex: imageIndex,
        ),
        if (showDelButton)
          Positioned(
            right: 2,
            top: 2,
            child: GestureDetector(
              onTap: () => _dialogRemoveImage(imageIndex),
              child: Container(
                padding: const EdgeInsets.all(4.0),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(99),
                  color: Colors.black54,
                ),
                child: const Icon(Icons.close, color: Colors.white, size: 12),
              ),
            ),
          )
      ],
    );
  }

  Future<void> _pickLocalImages() async {
    if (widget.note == null) return;
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['jpg', 'jpeg', 'png', 'gif'],
        allowMultiple: true,
      );
      
      if (result == null || result.files.isEmpty) return;
      
      for (var platformFile in result.files) {
        String? relativePath = await _copyImageAndGetPath(platformFile.path ?? "");
        if (relativePath != null) {
          await _addImage(relativePath);
        }
      }
      setState(() {});
    } catch (e) {
      AppLog.error("选择图片出错: $e");
    }
  }

  Future<String?> _copyImageAndGetPath(String absolutePath) async {
    try {
      final File sourceFile = File(absolutePath);
      if (!await sourceFile.exists()) return null;
      final targetDirPath = ImageUtil.getJournalImageRootDirPath();
      final fileName = '${DateTime.now().millisecondsSinceEpoch}_${p.basename(absolutePath)}';
      final targetPath = p.join(targetDirPath, fileName);
      await sourceFile.copy(targetPath);
      return ImageUtil.getRelativeJournalImagePath(targetPath);
    } catch (e) {
      AppLog.error("复制图片失败：$e");
      return null;
    }
  }

  Future<void> _addImage(String relativeImagePath) async {
    if (widget.note == null || relativeImagePath.isEmpty) return;
    int imageId = await SqliteUtil.insertNoteIdAndImageLocalPath(
      widget.note!.id,
      relativeImagePath,
      widget.note!.relativeLocalImages.length,
      noteType: NoteType.journal,
    );
    widget.note!.relativeLocalImages.add(RelativeLocalImage(imageId, relativeImagePath));
  }

  void _dialogRemoveImage(int index) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("确定移除吗？"),
        content: const Text("这并不会删除您的图片文件"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("取消")),
          TextButton(
            onPressed: () {
              final img = widget.note!.relativeLocalImages[index];
              SqliteUtil.deleteLocalImageByImageId(img.imageId);
              widget.note!.relativeLocalImages.removeAt(index);
              setState(() {});
              Navigator.pop(context);
            }, 
            child: const Text("移除")
          ),
        ],
      ),
    );
  }
}

