enum NoteType {
  episode(0, "集笔记"),
  rate(1, "评价笔记"),
  journal(2, "日记随笔");

  final int value;
  final String title;
  const NoteType(this.value, this.title);

  static NoteType fromValue(int value) {
    return NoteType.values.firstWhere((e) => e.value == value, orElse: () => NoteType.episode);
  }
}
