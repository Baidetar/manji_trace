import 'dart:io';

import 'package:flutter/material.dart';
import 'package:animetrace/models/journal_note.dart';
import 'package:animetrace/models/relative_local_image.dart';
import 'package:animetrace/utils/toast_util.dart';
import 'package:animetrace/utils/image_util.dart';
import 'package:animetrace/utils/sqlite_util.dart';
import 'package:animetrace/components/note/note_img_item.dart';
import 'package:animetrace/values/theme.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:reorderable_grid_view/reorderable_grid_view.dart';
import 'package:animetrace/widgets/responsive.dart';
import 'package:animetrace/utils/log.dart';
import 'package:path/path.dart' as p;

class JournalNoteEditor extends StatefulWidget {
  final JournalNote? note;
  final Function(String title, String content) onSave;

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
  bool _hasChanges = false;
  bool changeOrderIdx = false;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.note?.title ?? "");
    _contentController = TextEditingController(text: widget.note?.content ?? "");

    _titleController.addListener(_onChanged);
    _contentController.addListener(_onChanged);
  }

  void _onChanged() {
    setState(() {
      _hasChanges = true;
    });
  }

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  void _onSave() {
    if (_titleController.text.isEmpty && _contentController.text.isEmpty && (widget.note?.relativeLocalImages.isEmpty ?? true)) {
      ToastUtil.showText('请输入标题、内容或添加图片');
      return;
    }

    widget.onSave(_titleController.text, _contentController.text);
  }

  bool _dragging = false;

  Widget _buildImageDroppable({required Widget child}) {
    return DropTarget(
      onDragDone: (detail) async {
        for (var file in detail.files) {
          // 复制图片到私有目录并获取相对路径
          String? relativePath = await _copyImageAndGetPath(file.path);
          if (relativePath != null && relativePath.isNotEmpty) {
            await _addImage(relativePath);
          }
        }
        if (mounted) setState(() {});
      },
      onDragEntered: (detail) {
        setState(() {
          _dragging = true;
        });
      },
      onDragExited: (detail) {
        setState(() {
          _dragging = false;
        });
      },
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
        if (_hasChanges) {
          final result = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text("提示"),
              content: const Text("笔记未保存，是否放弃修改？"),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text("继续编辑"),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text("放弃"),
                ),
              ],
            ),
          );
          if (result ?? false) {
            Navigator.of(context).pop();
          }
        } else {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.note == null ? "新建笔记" : "编辑笔记"),
          actions: [
            IconButton(
              icon: const Icon(Icons.image),
              onPressed: () => _pickLocalImages(),
              tooltip: "添加图片",
            ),
            IconButton(
              icon: const Icon(Icons.done),
              onPressed: _onSave,
              tooltip: "保存",
            )
          ],
        ),
        body: _buildImageDroppable(
          child: ListView(
            children: [
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
    );
  }

  Widget _buildTitleField() {
    return Padding(
      padding: const EdgeInsets.all(12.0),
      child: TextField(
        controller: _titleController,
        decoration: const InputDecoration(
          hintText: "标题（可选）",
          border: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
          ),
          contentPadding: EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 10,
          ),
        ),
        maxLines: 1,
        style: const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  Widget _buildContentField() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12.0),
      child: TextField(
        controller: _contentController,
        decoration: const InputDecoration(
          hintText: "开始记录你的想法...",
          border: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
          ),
          contentPadding: EdgeInsets.all(12),
        ),
        maxLines: null,
        expands: false,
        minLines: 3,
        style: const TextStyle(fontSize: 16),
      ),
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
        if (oldIndex == newIndex) return;

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
        _buildAddButton(),
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
        onTap: () => _pickLocalImages(),
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
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['jpg', 'jpeg', 'png', 'gif'],
        allowMultiple: true,
      );
      
      if (result == null || result.files.isEmpty) return;
      
      List<PlatformFile> platformFiles = result.files;
      for (var platformFile in platformFiles) {
        String absoluteImagePath = platformFile.path ?? "";
        // 复制图片到私有目录并获取相对路径
        String? relativePath = await _copyImageAndGetPath(absoluteImagePath);
        if (relativePath != null && relativePath.isNotEmpty) {
          await _addImage(relativePath);
        }
      }

      setState(() {});
    } catch (e) {
      AppLog.error("选择图片出错: $e");
      ToastUtil.showText("选择图片失败");
    }
  }

  /// 复制图片到私有目录并返回相对路径
  Future<String?> _copyImageAndGetPath(String absolutePath) async {
    try {
      final File sourceFile = File(absolutePath);
      if (!await sourceFile.exists()) {
        AppLog.error("源图片文件不存在：$absolutePath");
        return null;
      }

      // 获取目标目录
      final targetDirPath = ImageUtil.getNoteImageRootDirPath();
      
      // 生成唯一的文件名（使用时间戳）
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final originalName = p.basename(absolutePath);
      final fileName = '${timestamp}_$originalName';
      final targetPath = p.join(targetDirPath, fileName);

      // 复制文件
      await sourceFile.copy(targetPath);
      AppLog.info("图片已复制到私有目录：$targetPath");

      // 返回相对路径
      final relativePath = ImageUtil.getRelativeNoteImagePath(targetPath);
      return relativePath;
    } catch (e) {
      AppLog.error("复制图片失败：$e");
      return null;
    }
  }

  Future<void> _addImage(String relativeImagePath) async {
    if (relativeImagePath.isEmpty) return;

    int imageId = await SqliteUtil.insertNoteIdAndImageLocalPath(
      widget.note!.id,
      relativeImagePath,
      widget.note!.relativeLocalImages.length,
    );
    widget.note!.relativeLocalImages.add(RelativeLocalImage(imageId, relativeImagePath));
  }

  void _dialogRemoveImage(int index) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text("确定移除吗？"),
          content: const Text("这并不会删除您的图片文件"),
          actions: <Widget>[
            TextButton(
              child: const Text("取消"),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
            TextButton(
              child: const Text("移除"),
              onPressed: () {
                RelativeLocalImage relativeLocalImage = widget.note!.relativeLocalImages[index];
                SqliteUtil.deleteLocalImageByImageId(relativeLocalImage.imageId);
                widget.note!.relativeLocalImages.removeWhere((element) =>
                    element.imageId == relativeLocalImage.imageId);
                setState(() {});
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }
}
