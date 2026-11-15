/// Picks the real errors out of a build log.
library;

class Problem {
  final String title;
  final String detail;
  final String file;
  final int line;
  const Problem(this.title, this.detail, this.file, this.line);
}

final _kt = RegExp(r'^e: (?:file://)?(.+?\.kts?):(\d+):(\d+):?\s*(.*)$');
final _analyze = RegExp(r'^error\s+[•-]\s+(.*?)\s+[•-]\s+(\S+?\.dart):(\d+):(\d+)\s+[•-]\s+\S+$');
final _dart = RegExp(r'^(\S+?\.dart):(\d+):(\d+): Error: (.*)$');
final _java = RegExp(r'^(\S+?\.java):(\d+): error: (.*)$');
final _stamp = RegExp(r'^\S*\d{4}-\d\d-\d\dT[\d:.]+Z ');
final _titles = RegExp(r'^(?:> )?(Execution failed for task .*|Could not (?:resolve|find|get|download) .*|Unresolved reference.*|Task .* FAILED|BUILD FAILED.*|Error: .*)$');

List<Problem> parseProblems(List<String> raw) {
  final lines = [for (final l in raw) l.replaceFirst('\uFEFF', '').trimLeft().replaceFirst(_stamp, '').trim()];
  final out = <Problem>[];
  final seen = <String>{};
  void add(String title, {String detail = '', String file = '', int line = 0}) {
    final t = title.trim();
    if (t.isEmpty || out.length >= 12 || !seen.add('$t|$file|$line')) return;
    out.add(Problem(t.length > 220 ? t.substring(0, 220) : t, detail.trim().length > 400 ? detail.trim().substring(0, 400) : detail.trim(), file, line));
  }

  String base(String p) => p.split('/').last;
  for (var i = 0; i < lines.length; i++) {
    final s = lines[i];
    final an = _analyze.firstMatch(s);
    final k = _kt.firstMatch(s);
    final d = _dart.firstMatch(s);
    final j = _java.firstMatch(s);
    if (an != null) {
      add(an.group(1)!, file: base(an.group(2)!), line: int.parse(an.group(3)!));
    } else if (k != null) {
      add(k.group(4)!.isEmpty ? 'Kotlin compile error' : k.group(4)!, file: base(k.group(1)!), line: int.parse(k.group(2)!));
    } else if (d != null) {
      add(d.group(4)!, file: base(d.group(1)!), line: int.parse(d.group(2)!));
    } else if (j != null) {
      add(j.group(3)!, file: base(j.group(1)!), line: int.parse(j.group(2)!));
    } else if (s.startsWith('* What went wrong:')) {
      final next = lines.skip(i + 1).take(4).where((l) => l.isNotEmpty && !l.startsWith('*')).toList();
      if (next.isNotEmpty) add(next[0], detail: next.skip(1).take(2).join(' '));
    } else if (s.contains('##[error]')) {
      add(s.replaceAll('##[error]', ''));
    } else if (_titles.hasMatch(s)) {
      add(s);
    }
  }
  int rank(Problem p) => p.file.isNotEmpty ? 0 : (RegExp(r'BUILD FAILED|Execution failed|Process completed').hasMatch(p.title) ? 2 : 1);
  final sorted = [...out]..sort((a, b) => rank(a).compareTo(rank(b)));
  return sorted;
}

/// A build failure that comes from the build's own setup (Android/Gradle versions, a plugin's requirements), not from
/// the project's code. Asking a model to "fix the code" cannot help and only costs money.
/// Returns a plain-language description of what failed, or '' when it looks like a normal code error.
String environmentFailure(String text) {
  final t = text;
  final aar = RegExp(r"task ':([\w.\-]+):(?:check(?:Debug|Release)AarMetadata|check\w*AarMetadata)'").firstMatch(t) ??
      RegExp(r"(?:^|\s)([\w\-]+):check(?:Debug|Release)AarMetadata\b").firstMatch(t);
  if (aar != null) return 'the plugin "${aar.group(1)}" needs a newer Android version than the build uses';
  if (RegExp(r'requires libraries and applications that depend on it to compile against version \d+', caseSensitive: false).hasMatch(t) ||
      t.contains('AAR metadata')) {
    return 'a plugin needs a newer Android version than the build uses';
  }
  final jdk = RegExp(r'Unsupported class file major version|Android Gradle plugin requires Java \d+|requires Java \d+ to run').firstMatch(t);
  if (jdk != null) return 'the Java version used by the build does not match Gradle or Android';
  if (RegExp(r"Execution failed for task ':[\w.\-]+:(?:processDebugManifest|processReleaseManifest|mergeDebugNativeLibs|mergeReleaseNativeLibs|checkDebugDuplicateClasses|checkReleaseDuplicateClasses)'").hasMatch(t) &&
      !RegExp(r'^e: ', multiLine: true).hasMatch(t)) {
    return 'two parts of the app or its plugins clash (dependency problem)';
  }
  return '';
}
