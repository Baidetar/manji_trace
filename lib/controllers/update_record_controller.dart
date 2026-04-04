import 'package:manji_trace/dao/anime_dao.dart';
import 'package:manji_trace/models/anime.dart';
import 'package:manji_trace/models/params/page_params.dart';
import 'package:manji_trace/models/anime_update_record.dart';
import 'package:manji_trace/models/vo/update_record_vo.dart';
import 'package:manji_trace/dao/update_record_dao.dart';
import 'package:get/get.dart';
import 'package:manji_trace/utils/log.dart';

class UpdateRecordController extends GetxController {
  static UpdateRecordController get to => Get.find();

  PageParams pageParams =
      PageParams(pageSize: 10, pageIndex: 0); // 动漫列表页刷新时也要传入该变量
  RxInt updateOkCnt = 0.obs, needUpdateCnt = 0.obs;
  String get updateProgressStr =>
      '${updateOkCnt.value} / ${needUpdateCnt.value}';
  double get updateProgress => needUpdateCnt.value > 0
      ? (updateOkCnt.value / needUpdateCnt.value).clamp(0, 1)
      : 0;

  bool get updateOk => updateOkCnt.value == needUpdateCnt.value;
  var updating = false.obs;

  RxList<UpdateRecordVo> updateRecordVos = RxList.empty();
  RxBool loadOk = false.obs;
  List<Anime> needUpdateAnimes = [];

  @override
  void onInit() {
    super.onInit();
    AppLog.info("UpdateRecordController: init");
    updateData();
  }

  // 更新记录页全局更新
  Future<void> updateData() async {
    // await Future.delayed(const Duration(seconds: 3));
    AppLog.info("重新获取数据库内容并覆盖");
    pageParams.resetPageIndex();
    updateRecordVos.value = await UpdateRecordDao.findAll(pageParams);

    // 获取需要更新的动漫数量
    needUpdateAnimes = await AnimeDao.getAllNeedUpdateAnimes();
    needUpdateCnt.value = needUpdateAnimes.length;

    loadOk.value = true;
  }

  // 加载更多，追加而非直接赋值
  loadMore() async {
    AppLog.info("加载更多更新记录中...");
    pageParams.pageIndex++;
    updateRecordVos.value =
        updateRecordVos.toList() + await UpdateRecordDao.findAll(pageParams);
  }

  // 动漫详细页更新
  updateSingleAnimeData(Anime oldAnime, Anime newAnime) {
    if (newAnime.animeEpisodeCnt <= oldAnime.animeEpisodeCnt) return;

    AnimeUpdateRecord updateRecord = AnimeUpdateRecord(
        animeId: newAnime.animeId,
        oldEpisodeCnt: oldAnime.animeEpisodeCnt,
        newEpisodeCnt: newAnime.animeEpisodeCnt,
        manualUpdateTime: DateTime.now().toString().substring(0, 10));
    UpdateRecordDao.batchInsert([updateRecord]);

    // 要么重新获取所有数据，要么直接转Vo添加
    UpdateRecordVo updateRecordVo = updateRecord.toVo(newAnime);
    updateRecordVos.add(updateRecordVo);
    AppLog.info("添加$updateRecordVo，长度=${updateRecordVos.length}");
    // 排序
    updateRecordVos
        .sort((a, b) => b.manualUpdateTime.compareTo(a.manualUpdateTime));
  }

  incrementUpdateOkCnt() {
    updateOkCnt++;
  }

  // 更新前重置为0
  resetUpdateOkCnt() {
    updateOkCnt.value = 0;
  }

  // 强制更新完成
  forceUpdateOk() {
    AppLog.info("强制更新完成");
    updateOkCnt.value = needUpdateCnt.value;
  }

  setNeedUpdateCnt(int value) {
    needUpdateCnt.value = value;
  }

  // 直接往list中添加，并按更新时间排序，而不是重新查询数据库
  void addUpdateRecord(UpdateRecordVo updateRecordVo) {
    // 第二次刷新时，如果已经添加了(old、new、anime、time都一样)，则不进行添加
    if (updateRecordVos.contains(updateRecordVo)) {
      AppLog.info("已有updateRecordVo=$updateRecordVo，跳过");
      return;
    }
    AppLog.info("添加$updateRecordVo，长度=${updateRecordVos.length}");

    // 直接插入到开头
    updateRecordVos.insert(0, updateRecordVo);
    // 不能先添加再排序，否则添加后会检测到然后显示，后来又因为排序重新显示一次
    // updateRecordVos.add(updateRecordVo);
    // updateRecordVos
    //     .sort((a, b) => b.manualUpdateTime.compareTo(a.manualUpdateTime));
  }

  void removeAnime(int animeId) {
    updateRecordVos.removeWhere(
      (record) =>
          record.anime.animeId == animeId ||
          // 如果从更新页进入的动漫详情页，删除动漫后id为置为0，导致该动漫id为0无法删除，因此这里统一删除未收藏的动漫
          !record.anime.isCollected(),
    );
    needUpdateAnimes.removeWhere((anime) => anime.animeId == animeId);
  }
}
