/// Follow-up suggestions: the model ends its answer with `[[follow-ups: a | b | c]]`; AIy shows them as
/// tappable chips and never shows (or sends back) the tag itself.
const String kFollowUpRule = '\nAfter your answer, on one last separate line, write 2 or 3 very short follow-up questions the person '
    'might ask next (in their language), exactly like this: [[follow-ups: question one | question two | question three]]. '
    'Skip that line for greetings, thanks or one-word replies.';

final RegExp _tag = RegExp(r'\[\[\s*follow-?ups?\s*:(.*?)\]\]\s*$', caseSensitive: false, dotAll: true);

/// The answer without the tag, and the questions found in it.
({String text, List<String> questions}) splitFollowUps(String raw) {
  final m = _tag.firstMatch(raw);
  if (m == null) return (text: hideFollowUpTail(raw), questions: const []);
  final qs = m.group(1)!
      .split('|')
      .map((q) => q.trim().replaceAll(RegExp(r'^[-*\d.\s"]+|["\s]+$'), ''))
      .where((q) => q.length >= 3 && q.length <= 120)
      .take(3)
      .toList();
  return (text: raw.substring(0, m.start).trimRight(), questions: qs);
}

/// While the answer is still arriving: hides a tag that has started but not finished.
String hideFollowUpTail(String s) {
  final i = s.lastIndexOf('[[');
  if (i >= 0 && s.length - i < 400 && !s.substring(i).contains(']]')) return s.substring(0, i).trimRight();
  if (s.endsWith('[')) return s.substring(0, s.length - 1);
  return s;
}
