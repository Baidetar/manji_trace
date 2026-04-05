import 'package:manji_trace/dao/journal_note_dao.dart';
import 'package:manji_trace/models/journal_note.dart';
import 'package:manji_trace/models/params/page_params.dart';
import 'package:manji_trace/pages/history/history_controller.dart';
import 'package:manji_trace/utils/log.dart';
import 'package:manji_trace/utils/toast_util.dart';
import 'package:get/get.dart';

class JournalNoteController extends GetxController {
  static JournalNoteController get to => Get.find<JournalNoteController>();

  List<JournalNote> noteList = [];
  int currentPage = 1;
  final int pageSize = 20;
  String searchKeyword = "";

  Future<void> loadNotes() async {
    try {
      currentPage = 1;
      final params = PageParams(pageIndex: currentPage - 1, pageSize: pageSize);
      noteList = await JournalNoteDao.getAllNotes(
        pageParams: params,
        searchKeyword: searchKeyword,
      );
      update();
    } catch (e) {
      AppLog.error('加载笔记失败: $e');
      ToastUtil.showError('加载笔记失败');
    }
  }

  Future<bool> loadMoreNotes() async {
    try {
      final params = PageParams(pageIndex: currentPage - 1, pageSize: pageSize);
      final moreNotes = await JournalNoteDao.getAllNotes(
        pageParams: params,
        searchKeyword: searchKeyword,
      );

      if (moreNotes.isEmpty) {
        return false;
      }

      noteList.addAll(moreNotes);
      update();
      return true;
    } catch (e) {
      AppLog.error('加载更多笔记失败: $e');
      return false;
    }
  }

  Future<void> createNote(JournalNote note, {bool silent = false}) async {
    try {
      final id = await JournalNoteDao.insertNote(note);
      note.id = id;
      if (!silent) {
        noteList.insert(0, note);
        update();
        ToastUtil.showText('笔记已创建');
      }

      // 通知历史页面有新日记
      try {
        final historyController = Get.find<HistoryController>();
        await historyController.onNoteAdded(note);
      } catch (e) {
        // HistoryController 可能未初始化，忽略
      }
    } catch (e) {
      AppLog.error('创建笔记失败: $e');
      if (!silent) ToastUtil.showError('创建笔记失败');
    }
  }

  Future<void> updateNote(JournalNote note) async {
    try {
      await JournalNoteDao.updateNote(note);
      final index = noteList.indexWhere((n) => n.id == note.id);
      if (index >= 0) {
        noteList[index] = note;
      }
      update();
      ToastUtil.showText('笔记已更新');

      // 通知历史页面日记已更新
      try {
        final historyController = Get.find<HistoryController>();
        await historyController.onNoteUpdated(note);
      } catch (e) {
        // HistoryController 可能未初始化，忽略
      }
    } catch (e) {
      AppLog.error('更新笔记失败: $e');
      ToastUtil.showError('更新笔记失败');
    }
  }

  Future<void> deleteNote(int id) async {
    try {
      await JournalNoteDao.deleteNote(id);
      noteList.removeWhere((n) => n.id == id);
      update();
      ToastUtil.showText('笔记已删除');

      // 通知历史页面日记已删除
      try {
        final historyController = Get.find<HistoryController>();
        await historyController.onNoteDeleted(id);
      } catch (e) {
        // HistoryController 可能未初始化，忽略
      }
    } catch (e) {
      AppLog.error('删除笔记失败: $e');
      ToastUtil.showError('删除笔记失败');
    }
  }

  Future<void> searchNotes(String keyword) async {
    try {
      searchKeyword = keyword;
      currentPage = 1;
      final params = PageParams(pageIndex: currentPage - 1, pageSize: pageSize);
      noteList = await JournalNoteDao.getAllNotes(
        pageParams: params,
        searchKeyword: searchKeyword,
      );
      update();
    } catch (e) {
      AppLog.error('搜索笔记失败: $e');
      ToastUtil.showError('搜索笔记失败');
    }
  }
}
