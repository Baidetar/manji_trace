import 'package:animetrace/models/union_history_record.dart';

class HistoryPlus {
  String date;
  List<UnionHistoryRecord> records;

  HistoryPlus(this.date, this.records);

  @override
  String toString() {
    StringBuffer res = StringBuffer();
    for (var item in records) {
      res.writeln(item);
    }
    return "📅 $date:\n$res";
  }
}
