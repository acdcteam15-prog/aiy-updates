// Picks the files a repair round sends to the model.
//
// Before 1.21.2 only the file an error POINTS AT was sent (plus changed files). For errors like
// "The method 'selectFilter' isn't defined for the type 'FilterService'" the file that DEFINES
// FilterService was never sent, so every model guessed blindly and the same error came back.
//
// Order: 1) files the errors point at, 2) files that define the names in the errors,
// 3) files those import, 4) recently changed files, 5) other source files near them,
// all within a character budget.
import 'buildlog.dart';

const kFixBudgetChars = 60000;
const kFixMaxFiles = 24;

final _quoted = RegExp(r"'([A-Za-z_$][\w$]*)'");
final _pascal = RegExp(r'\b([A-Z][A-Za-z0-9_]{2,})\b');
final _import = RegExp(r'''^\s*(?:import|export|part)\s+['"]([^'"]+)['"]''', multiLine: true);
const _noise = {'The', 'Try', 'Undefined', 'Error', 'Warning', 'String', 'List', 'Map', 'Set', 'Future', 'Stream', 'Widget', 'Object', 'Null', 'Process', 'Type', 'Kotlin', 'Gradle', 'FAILURE', 'BUILD'};

/// Identifiers named in the errors: quoted names first, then CapitalisedNames.
List<String> symbolsIn(List<Problem> problems) {
  final out = <String>[];
  void add(String s) {
    if (!_noise.contains(s) && !out.contains(s)) out.add(s);
  }

  for (final p in problems) {
    final t = '${p.title} ${p.detail}';
    for (final m in _quoted.allMatches(t)) add(m.group(1)!);
    for (final m in _pascal.allMatches(t)) add(m.group(1)!);
  }
  return out;
}

bool _isSource(String p) => RegExp(r'\.(dart|kt|kts|java|swift|ts|tsx|js|py)$').hasMatch(p);

/// Files that declare [name] as a type, or (for lowercase names) as a top-level function / member.
Iterable<String> definersOf(String name, Map<String, String> files) sync* {
  final e = RegExp.escape(name);
  final type = RegExp(r'\b(?:class|mixin|enum|extension|typedef|interface|object|struct|protocol)\s+' + e + r'\b');
  final member = RegExp(r'(?:^|[\s;{])(?:[\w<>?,\[\] ]+\s+)?' + e + r'\s*\(', multiLine: true);
  final upper = name[0].toUpperCase() == name[0];
  for (final kv in files.entries) {
    if (!_isSource(kv.key)) continue;
    if (type.hasMatch(kv.value) || (!upper && member.hasMatch(kv.value) && kv.value.contains('$name('))) yield kv.key;
  }
}

String? _packageName(Map<String, String> files) {
  for (final kv in files.entries) {
    if (kv.key == 'pubspec.yaml' || kv.key.endsWith('/pubspec.yaml')) {
      final m = RegExp(r'^name:\s*(\S+)', multiLine: true).firstMatch(kv.value);
      if (m != null) return m.group(1);
    }
  }
  return null;
}

String _normalize(String path) {
  final out = <String>[];
  for (final s in path.split('/')) {
    if (s == '..') {
      if (out.isNotEmpty) out.removeLast();
    } else if (s.isNotEmpty && s != '.') {
      out.add(s);
    }
  }
  return out.join('/');
}

/// Project files that [path] imports (relative and package:<own>/ imports).
List<String> importsOf(String path, Map<String, String> files) {
  final text = files[path];
  if (text == null) return const [];
  final pkg = _packageName(files);
  final dir = path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : '';
  final out = <String>[];
  for (final m in _import.allMatches(text)) {
    final u = m.group(1)!;
    String? want;
    if (pkg != null && u.startsWith('package:$pkg/')) {
      want = 'lib/${u.substring('package:$pkg/'.length)}';
    } else if (!u.contains(':')) {
      want = _normalize(dir.isEmpty ? u : '$dir/$u');
    }
    if (want == null) continue;
    for (final k in files.keys) {
      if ((k == want || k.endsWith('/$want')) && !out.contains(k)) out.add(k);
    }
  }
  return out;
}

/// The ordered, budget-capped list of files for a repair round.
List<String> pickFixFiles({
  required List<Problem> problems,
  required Map<String, String> files,
  required List<String> changed,
  int budget = kFixBudgetChars,
  int maxFiles = kFixMaxFiles,
}) {
  final picked = <String>[];
  var used = 0;
  bool add(String p) {
    if (picked.contains(p) || picked.length >= maxFiles) return false;
    final n = files[p]?.length;
    if (n == null) return false;
    // the files the errors point at always go in; the rest only while the budget lasts
    if (picked.isNotEmpty && used + n > budget) return false;
    picked.add(p);
    used += n;
    return true;
  }

  final pointed = <String>[];
  for (final n in {for (final p in problems) if (p.file.isNotEmpty) p.file}) {
    for (final k in files.keys.where((k) => k == n || k.endsWith('/$n') || n.endsWith('/$k'))) {
      if (!pointed.contains(k)) pointed.add(k);
    }
  }
  pointed.forEach(add);
  for (final s in symbolsIn(problems)) {
    definersOf(s, files).forEach(add);
  }
  for (final p in [...pointed]) {
    importsOf(p, files).forEach(add);
  }
  changed.forEach(add);
  // fill: source files in the same folders first, then the rest of lib/ / src/
  final dirs = {for (final p in picked) p.contains('/') ? p.substring(0, p.lastIndexOf('/')) : ''};
  final rest = files.keys.where(_isSource).where((k) => !picked.contains(k)).toList()
    ..sort((a, b) {
      int rank(String k) {
        final d = k.contains('/') ? k.substring(0, k.lastIndexOf('/')) : '';
        if (dirs.contains(d)) return 0;
        if (k.startsWith('lib/') || k.contains('/lib/') || k.contains('/src/')) return 1;
        return 2;
      }

      final r = rank(a).compareTo(rank(b));
      return r != 0 ? r : (files[a]!.length).compareTo(files[b]!.length);
    });
  for (final k in rest) {
    if (rank2(k) && !add(k) && used >= budget) break;
  }
  return picked;
}

bool rank2(String k) => !k.contains('/test/') && !k.startsWith('test/') && !k.contains('.g.dart') && !k.contains('.freezed.dart');

/// A stable key for "the same errors came back": every error, not only the first.
String errorSetKey(List<Problem> problems, String log) {
  if (problems.isEmpty) {
    final tail = log.trim().split('\n');
    return 'log:${tail.isEmpty ? '' : tail.last.trim()}';
  }
  final keys = {for (final p in problems) '${p.file}|${p.title}'}.toList()..sort();
  return keys.join('\n');
}

final _errLine = RegExp(r"(error|Error:|^e: |FAILED|What went wrong|Exception|isn't defined|Undefined|Unresolved)");
final _noiseLine = RegExp(r'^(Downloading|Resolving dependencies|Got dependencies|Changed \d+ dependenc|  [+>] |Running Gradle|\s*\d+(\.\d+)?%|Post job|##\[group\]|##\[endgroup\])');

/// The log lines around each error (6 before, 3 after), without download / setup noise.
/// Falls back to the last 45 lines when no error line is found.
String errorWindows(List<String> lines, {int maxChars = 4500}) {
  final clean = [for (final l in lines) if (!_noiseLine.hasMatch(l)) l];
  final keep = <int>{};
  for (var i = 0; i < clean.length; i++) {
    if (_errLine.hasMatch(clean[i])) {
      for (var k = i - 6; k <= i + 3; k++) {
        if (k >= 0 && k < clean.length) keep.add(k);
      }
    }
  }
  String out;
  if (keep.isEmpty) {
    out = clean.skip(clean.length > 45 ? clean.length - 45 : 0).join('\n');
  } else {
    final sb = StringBuffer();
    var prev = -2;
    for (final k in keep.toList()..sort()) {
      if (k != prev + 1 && sb.isNotEmpty) sb.writeln('…');
      sb.writeln(clean[k]);
      prev = k;
    }
    out = sb.toString();
  }
  return out.length > maxChars ? out.substring(out.length - maxChars) : out;
}

/// A rough "kind" of error, used to remember which model fixed which kind.
String errorKind(List<Problem> problems) {
  final t = problems.map((p) => '${p.title} ${p.detail}').join(' ').toLowerCase();
  if (t.contains("isn't defined") || t.contains('undefined') || t.contains('unresolved reference')) return 'missing-name';
  if (t.contains("can't be assigned") || t.contains('type mismatch') || t.contains('argument type')) return 'type';
  if (t.contains('expected') || t.contains('unexpected') || t.contains('syntax')) return 'syntax';
  if (t.contains('import') || t.contains('not found') || t.contains('could not resolve')) return 'import';
  if (t.contains('null')) return 'null-safety';
  return 'other';
}
