/// The "Screens" bullets of an app brief, so a screen can be taken out before any code is written.
library;

String _norm(String s) => s.replaceAll('\r\n', '\n');
final _bullet = RegExp(r'^\s*[-*•]\s+');
final _screensHead = RegExp(r'^#{1,4}\s*screens\b', caseSensitive: false);

List<String> screensOf(String brief) {
  final out = <String>[];
  var inScreens = false;
  for (final l in _norm(brief).split('\n')) {
    final t = l.trim();
    if (t.startsWith('#')) {
      inScreens = _screensHead.hasMatch(t);
      continue;
    }
    if (inScreens && _bullet.hasMatch(l)) out.add(l);
  }
  return out;
}

String removeScreen(String brief, String line) {
  final ls = _norm(brief).split('\n');
  final i = ls.indexOf(line);
  if (i < 0) return brief;
  ls.removeAt(i);
  return ls.join('\n');
}

String restoreScreen(String brief, String line) {
  final ls = _norm(brief).split('\n');
  var head = -1, last = -1;
  var inScreens = false;
  for (var i = 0; i < ls.length; i++) {
    final t = ls[i].trim();
    if (t.startsWith('#')) {
      inScreens = _screensHead.hasMatch(t);
      if (inScreens) head = i;
      continue;
    }
    if (inScreens && _bullet.hasMatch(ls[i])) last = i;
  }
  if (head < 0) return '${_norm(brief).trimRight()}\n$line\n';
  ls.insert((last >= 0 ? last : head) + 1, line);
  return ls.join('\n');
}

/// "- **Home**: the list of habits" -> "Home". Shown as the name of the screen in the checklist.
String screenTitle(String line) {
  var t = line.replaceFirst(_bullet, '').replaceAll('**', '').replaceAll('`', '').trim();
  final cut = RegExp(r'\s[-–—:]\s|:\s|\s\(').firstMatch(t);
  if (cut != null && cut.start > 1) t = t.substring(0, cut.start);
  return t.length > 38 ? '${t.substring(0, 38)}…' : t;
}
