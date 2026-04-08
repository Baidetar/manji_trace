import 'package:manji_trace/utils/image_util.dart';
import 'package:manji_trace/models/relative_local_image.dart';
import 'package:manji_trace/models/enum/note_type.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../utils/sqlite_util.dart';
import 'package:manji_trace/utils/log.dart';

class ImageDao {
  static Database get database => SqliteUtil.database;

  /// 获取笔记的相对本地图片列表
  static Future<List<RelativeLocalImage>> getRelativeLocalImgsByNoteId(
      int noteId, {NoteType noteType = NoteType.episode}) async {
    var lm = await database.rawQuery('''
    select image_id, image_local_path from image
    where note_id = $noteId and note_type = ${noteType.value}
    order by order_idx, note_id;
    ''');
    List<RelativeLocalImage> relativeLocalImages = [];
    for (var item in lm) {
      relativeLocalImages.add(RelativeLocalImage(
          item['image_id'] as int, item['image_local_path'] as String));
    }
    return relativeLocalImages;
  }

  /// 编辑好笔记后，退出时更新图片的顺序
  static updateImageOrderIdxById(int imageId, int newOrderIdx) {
    AppLog.info(
        "updateImageOrderIdxById(imageId=$imageId, newOrderIdx=$newOrderIdx)");
    // 只有调用await updateImageOrderIdxById，才有延时效果，而直接调用updateImageOrderIdxById，才有延时效果，而没有
    // await Future.delayed(const Duration(seconds: 2));
    // 更新不用await等待
    database.rawUpdate('''
    update image
    set order_idx = $newOrderIdx
    where image_id = $imageId
    ''');
  }

  /// 获取所有图片
  static Future<List<String>> getAllImages() async {
    AppLog.info('sql: getAllImages');

    List<String> images = [];
    List<Map> rows =
        await database.rawQuery('select image_local_path, note_type from image');
    for (var row in rows) {
      String relativePath = row['image_local_path'];
      final int noteType = row['note_type'] as int? ?? NoteType.episode.value;
      String path = noteType == NoteType.journal.value
          ? ImageUtil.getAbsoluteJournalImagePath(relativePath)
          : ImageUtil.getAbsoluteNoteImagePath(relativePath);
      images.add(path);
    }

    return images;
  }

  /// 获取某个动漫的所有图片
  static Future<List<String>> getImages(int animeId) async {
    AppLog.info('sql: getImages(animeId=$animeId)');

    List<String> images = [];
    List<Map> rows = await database.rawQuery('''
      select image_local_path
      from image left join episode_note on episode_note.note_id = image.note_id
      where anime_id = $animeId and image.note_type = ${NoteType.episode.value};
      ''');
    for (var row in rows) {
      String relativePath = row['image_local_path'];
      String path = ImageUtil.getAbsoluteNoteImagePath(relativePath);
      images.add(path);
    }

    return images;
  }
}
