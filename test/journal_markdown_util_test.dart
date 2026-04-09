import 'package:flutter_test/flutter_test.dart';
import 'package:manji_trace/utils/journal_markdown_util.dart';

void main() {
  test('buildRelativePath generates expected year/month path', () {
    final rel = JournalMarkdownUtil.buildRelativePath(
      noteId: 42,
      createTime: '2026-04-10 12:34:56',
    );
    expect(rel, 'notes/journal/2026/04/42.md');
  });

  test('buildSummary trims markdown syntax and limits length', () {
    final summary = JournalMarkdownUtil.buildSummary(
      '# Hello\n- [ ] **world** [link](https://example.com)\n`code`',
      maxLen: 12,
    );
    expect(summary, 'Hello world...');
  });

  test('buildDigest returns stable hash for same content', () {
    final d1 = JournalMarkdownUtil.buildDigest('abc');
    final d2 = JournalMarkdownUtil.buildDigest('abc');
    expect(d1, d2);
  });
}
