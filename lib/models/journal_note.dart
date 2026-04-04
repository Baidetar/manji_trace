import 'dart:convert';
import 'package:manji_trace/models/relative_local_image.dart';

class JournalNote {
  int id;
  String title;
  String content;
  List<RelativeLocalImage> relativeLocalImages; // 修改：使用RelativeLocalImage列表
  String createTime;
  String updateTime;

  JournalNote({
    this.id = 0,
    this.title = "",
    this.content = "",
    List<RelativeLocalImage>? relativeLocalImages, // 修改
    this.createTime = "",
    this.updateTime = "",
  }) : relativeLocalImages = relativeLocalImages ?? [];

  bool get isEmpty => title.isEmpty && content.isEmpty && relativeLocalImages.isEmpty; // 修改

  // 从JSON字符串创建relativeLocalImages（向后兼容）
  factory JournalNote.fromJson(String jsonStr) {
    List<RelativeLocalImage> images = [];
    if (jsonStr.isNotEmpty) {
      try {
        List<dynamic> list = json.decode(jsonStr);
        images = list.map((item) => RelativeLocalImage(item['imageId'] ?? 0, item['path'] ?? "")).toList();
      } catch (e) {
        // 忽略解析错误
      }
    }
    return JournalNote(relativeLocalImages: images);
  }

  // 转换为JSON字符串（向后兼容）
  String toJson() {
    return json.encode(relativeLocalImages.map((img) => {'imageId': img.imageId, 'path': img.path}).toList());
  }

  @override
  String toString() {
    return title.isNotEmpty ? title : "未命名笔记";
  }
}
