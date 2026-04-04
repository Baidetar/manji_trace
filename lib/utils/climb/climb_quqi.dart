import 'package:manji_trace/models/params/page_params.dart';
import 'package:manji_trace/models/anime_filter.dart';
import 'package:manji_trace/models/anime.dart';
import 'package:manji_trace/models/week_record.dart';
import 'package:manji_trace/utils/climb/climb.dart';
import 'package:manji_trace/utils/climb/climb_yhdm.dart';

class ClimbQuqi with Climb {
  // 单例
  static final ClimbQuqi _instance = ClimbQuqi._();
  factory ClimbQuqi() => _instance;
  ClimbQuqi._();

  @override
  String get idName => "quqi";

  @override
  String get defaultBaseUrl => "https://www.quqim.net";

  @override
  String get sourceName => "曲奇动漫";

  @override
  Future<Anime> climbAnimeInfo(Anime anime) async {
    return ClimbYhdm().climbAnimeInfo(anime, foreignSourceName: sourceName);
  }

  @override
  Future<List<Anime>> climbDirectory(
      AnimeFilter filter, PageParams pageParams) {
    return ClimbYhdm().climbDirectory(filter, pageParams,
        foreignBaseUrl: baseUrl, foreignSourceName: sourceName);
  }

  @override
  Future<List<Anime>> searchAnimeByKeyword(String keyword) {
    return ClimbYhdm().searchAnimeByKeyword(keyword,
        foreignBaseUrl: baseUrl, foreignSourceName: sourceName);
  }

  @override
  Future<List<List<WeekRecord>>> climbWeeklyTable() async {
    return ClimbYhdm().climbWeeklyTable(
        foreignBaseUrl: baseUrl, foreignSourceName: sourceName);
  }
}
