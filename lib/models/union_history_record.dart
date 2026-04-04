import 'package:animetrace/models/anime_history_record.dart';
import 'package:animetrace/models/journal_note.dart';

/// 统一的历史记录模型，可以是动画历史或日记
class UnionHistoryRecord {
  final AnimeHistoryRecord? animeRecord;
  final JournalNote? noteRecord;

  UnionHistoryRecord.anime(this.animeRecord) : noteRecord = null;
  UnionHistoryRecord.note(this.noteRecord) : animeRecord = null;

  bool get isAnime => animeRecord != null;
  bool get isNote => noteRecord != null;

  @override
  String toString() {
    if (isAnime) return animeRecord.toString();
    return noteRecord.toString();
  }
}
