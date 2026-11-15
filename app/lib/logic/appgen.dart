/// Build tab, pure logic: the prompts, reading the AI's answers, and checking a generated Flutter project
/// before it is handed to the person.
library;

import 'dart:convert';

import 'patcher.dart';

const _reserved = {
  'test', 'flutter', 'dart', 'assert', 'class', 'enum', 'new', 'this', 'var', 'void', 'with', 'if', 'else', 'for', 'in', 'is', 'do', 'try', 'null', 'true', 'false',
  'final', 'const', 'switch', 'case', 'default', 'return', 'super', 'while', 'import', 'library', 'part', 'show', 'hide', 'as', 'on', 'get', 'set', 'late', 'await',
  'async', 'yield', 'static', 'abstract', 'extends', 'implements', 'mixin', 'typedef', 'external',
};

/// "My Cool App!" -> my_cool_app (a valid Dart package name).
String snakeName(String s) {
  var t = s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
  if (t.isEmpty) t = 'my_app';
  if (RegExp(r'^[0-9]').hasMatch(t)) t = 'app_$t';
  if (_reserved.contains(t)) t = '${t}_app';
  if (t.length > 40) t = t.substring(0, 40).replaceAll(RegExp(r'_+$'), '');
  return t;
}

// ---------------------------------------------------------------------------------------------- questions
String questionSystem() => 'You help a person who is not a programmer design a mobile app. You ask short, friendly, concrete questions in simple words, in the language the person wrote their idea in.';

String questionPrompt({required String idea, required String look, required List<(String, String)> qa, required int n, required int total}) {
  final sb = StringBuffer('The person\'s idea for an app:\n"""\n$idea\n"""\n\nAlready decided (do not ask about these): $look\n\n');
  if (qa.isNotEmpty) {
    sb.writeln('Questions and answers so far:');
    for (var i = 0; i < qa.length; i++) {
      sb.writeln('${i + 1}. ${qa[i].$1}\n   Answer: ${qa[i].$2.isEmpty ? '(skipped)' : qa[i].$2}');
    }
    sb.writeln();
  }
  sb.writeln('Ask question number $n of $total. It must be the single most useful thing that is still unknown, for example: who uses the app, the main screens, what is saved, rules or special behaviour, languages. '
      'Never repeat a topic that is already covered. Do not ask about the name, colours or icon.');
  sb.writeln('Return ONLY a JSON object: {"question": "...", "options": ["...", "...", "..."]}');
  sb.writeln('The question has at most 18 words. "options" has 3 or 4 short suggested answers (at most 6 words each) that the person can tap.');
  return sb.toString();
}

({String q, List<String> options})? parseQuestion(String raw) {
  var t = raw.trim();
  final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(t);
  if (fence != null) t = fence.group(1)!.trim();
  final a = t.indexOf('{'), b = t.lastIndexOf('}');
  if (a < 0 || b <= a) return null;
  try {
    final j = jsonDecode(t.substring(a, b + 1));
    if (j is! Map) return null;
    final q = '${j['question'] ?? ''}'.trim();
    if (q.isEmpty) return null;
    final o = [
      for (final x in (j['options'] as List? ?? const [])) '$x'.trim()
    ].where((e) => e.isNotEmpty).take(5).toList();
    return (q: q, options: o);
  } catch (_) {
    return null;
  }
}

/// The question text out of a JSON answer that is still arriving ('' until the question has begun).
String partialQuestion(String partial) {
  final m = RegExp(r'"question"\s*:\s*"((?:[^"\\]|\\.)*)').firstMatch(partial);
  if (m == null) return '';
  var raw = m.group(1)!;
  // A backslash at the very end is the start of an escape that has not fully arrived yet.
  if (raw.endsWith('\\') && !raw.endsWith('\\\\')) raw = raw.substring(0, raw.length - 1);
  try {
    return jsonDecode('"$raw"') as String;
  } catch (_) {
    return raw;
  }
}

/// How far the writing of the app has come, from the answer so far: files started and the newest one.
({int count, String current}) writingProgress(String partial) {
  var n = 0;
  var last = '';
  for (final m in RegExp(r'^###\s+(?:NEW FILE|FILE):\s*(\S.*?)\s*$', multiLine: true).allMatches(partial)) {
    n++;
    last = m.group(1)!;
  }
  return (count: n, current: last);
}

String namesPrompt(String idea) => 'Suggest 4 short, memorable names for this mobile app (1 to 3 words, no quotes inside). Idea:\n"""\n$idea\n"""\nReturn ONLY a JSON array of 4 strings.';

// ---------------------------------------------------------------------------------------------- brief
String briefSystem() => 'You turn a person\'s app idea and their answers into a clear app brief a developer can build from. Plain English (or the language of the idea), concrete, no filler.';

String briefPrompt({required String name, required String idea, required String look, required List<(String, String)> qa}) {
  final sb = StringBuffer('App name: $name\nIdea:\n"""\n$idea\n"""\nLook: $look\n\nAnswers:\n');
  for (var i = 0; i < qa.length; i++) {
    sb.writeln('- ${qa[i].$1} -> ${qa[i].$2.isEmpty ? '(skipped: you decide)' : qa[i].$2}');
  }
  sb.writeln('\nWrite the app brief in Markdown with exactly these sections: "# $name", "## What it does" (2-3 sentences), "## Screens" (a bullet per screen with what is on it), '
      '"## Data and features" (what is saved on the phone, what the buttons do, rules), "## Look and feel", "## Left out of the first version". '
      'Make sensible choices for anything that was skipped. Keep it under 350 words. Everything must be possible in an offline Flutter app that stores data on the phone.');
  return sb.toString();
}

// ---------------------------------------------------------------------------------------------- plan
String planPrompt(String brief, String name) =>
    'App brief:\n$brief\n\nList the files of a small, working Flutter app for it (package name ${snakeName(name)}). 5 to 12 files, all Dart code under lib/, plus pubspec.yaml. '
    'It must include pubspec.yaml and lib/main.dart. Split screens, models and storage into separate files, each under 300 lines. '
    'Return ONLY a JSON array of objects: [{"path": "lib/main.dart", "purpose": "app start, theme and navigation"}, ...]';

List<({String path, String purpose})> parsePlan(String raw) {
  var t = raw.trim();
  final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(t);
  if (fence != null) t = fence.group(1)!.trim();
  dynamic j;
  final a = t.indexOf('['), b = t.lastIndexOf(']');
  final c = t.indexOf('{'), d = t.lastIndexOf('}');
  try {
    if (a >= 0 && b > a && (c < 0 || a < c)) {
      j = jsonDecode(t.substring(a, b + 1));
    } else if (c >= 0 && d > c) {
      j = jsonDecode(t.substring(c, d + 1));
    }
  } catch (_) {
    j = null;
  }
  final list = j is Map ? j['files'] : j;
  final out = <({String path, String purpose})>[];
  if (list is List) {
    for (final e in list) {
      var path = e is Map ? '${e['path'] ?? ''}' : '$e';
      final purpose = e is Map ? '${e['purpose'] ?? ''}' : '';
      path = path.trim().replaceAll('\\', '/');
      while (path.startsWith('./') || path.startsWith('/')) {
        path = path.substring(path.startsWith('./') ? 2 : 1);
      }
      if (path.isEmpty || path.contains('..') || out.any((x) => x.path == path)) continue;
      if (!(path == 'pubspec.yaml' || path.startsWith('lib/') || path.startsWith('assets/'))) continue;
      out.add((path: path, purpose: purpose.trim()));
    }
  }
  if (!out.any((x) => x.path == 'pubspec.yaml')) out.insert(0, (path: 'pubspec.yaml', purpose: 'packages and app settings'));
  if (!out.any((x) => x.path == 'lib/main.dart')) out.add((path: 'lib/main.dart', purpose: 'app start, theme and navigation'));
  return out;
}

// ---------------------------------------------------------------------------------------------- writing the code
const String kGenFormat = '''
Answer in EXACTLY this format and nothing else (no explanations, no Markdown code fences):

### NEW FILE: pubspec.yaml
<<<<<<< CONTENT
the complete file
>>>>>>> END

### NEW FILE: lib/main.dart
<<<<<<< CONTENT
the complete file
>>>>>>> END

One block per file, each with the COMPLETE content of that file.
''';

String genSystem(String pkg) => '''
You are an expert Flutter developer. You write a complete, working Flutter app that COMPILES the first time.
Rules:
- Flutter with Material 3 and Dart 3. The package name is "$pkg". Import your own files with package:$pkg/... .
- Use only Flutter's built-in widgets, plus these packages when really needed: shared_preferences, provider, intl, path_provider, uuid. Declare every package you import in pubspec.yaml under dependencies. Do not use packages that need native setup (camera, maps, notifications, firebase, permissions).
- The app works offline; keep its data on the phone (shared_preferences or a JSON file).
- pubspec.yaml: name $pkg, version 1.0.0+1, environment sdk '>=3.0.0 <4.0.0', dependencies with flutter (sdk: flutter), and under flutter: uses-material-design: true. Do not list asset files that do not exist.
- Every import must point to a file you write in this answer. Every class and function you use must exist. No placeholders, no TODOs, no "..." in code.
- Null-safe, no deprecated APIs where a replacement exists (use Color.withValues(alpha: x), not withOpacity). Keep each file under 300 lines.
- Make it look polished: rounded cards, spacing, empty states, simple animations, and handle small phone screens (scrolling instead of overflow).
$kGenFormat''';

String genUser({
  required String brief,
  required String name,
  required String pkg,
  required String themeNote,
  required List<({String path, String purpose})> plan,
  Map<String, String> written = const {},
  List<String> only = const [],
  List<String> problems = const [],
}) {
  final sb = StringBuffer('App brief:\n$brief\n\nDisplay name: "$name". Package name: $pkg.\n$themeNote\n\nFiles of the app:\n');
  for (final f in plan) {
    sb.writeln('- ${f.path}${f.purpose.isEmpty ? '' : ': ${f.purpose}'}');
  }
  if (written.isEmpty && problems.isEmpty) {
    sb.writeln('\nWrite EVERY file now.');
    return sb.toString();
  }
  if (written.isNotEmpty) {
    sb.writeln('\nThese files are already written (first lines shown, so you can match their names and types):');
    for (final e in written.entries) {
      final lines = e.value.split('\n');
      sb.writeln('=== ${e.key} ===\n${lines.take(e.key.endsWith('.dart') ? 90 : 25).join('\n')}${lines.length > 90 ? '\n…' : ''}');
    }
  }
  if (problems.isNotEmpty) {
    sb.writeln('\nProblems found when checking the project:');
    for (final p in problems.take(15)) {
      sb.writeln('- $p');
    }
  }
  if (problems.isEmpty && only.isNotEmpty) {
    // Writing in parts: the other files come in other parts, so names must follow the list above exactly.
    sb.writeln('\nThe app is written in parts. Files not shown above are written in other parts: refer to them by the paths and purposes in the list, '
        'and give classes and functions the names those purposes suggest. Use package imports (package:<name>/...) matching the paths exactly.');
  }
  sb.writeln('\nWrite ONLY these files now, each complete${only.isEmpty ? '' : ': ${only.join(', ')}'}.${problems.isEmpty ? '' : ' Fix every problem listed. If a file listed above is missing, write it.'}');
  return sb.toString();
}

// ---------------------------------------------------------------------------------------------- checks
String _resolve(String from, String rel) {
  final parts = from.split('/')..removeLast();
  for (final s in rel.split('/')) {
    if (s == '..') {
      if (parts.isNotEmpty) parts.removeLast();
    } else if (s != '.' && s.isNotEmpty) {
      parts.add(s);
    }
  }
  return parts.join('/');
}

Set<String> declaredPackages(String pubspec) {
  final out = <String>{};
  var inDeps = false;
  for (final l in pubspec.replaceAll('\r\n', '\n').split('\n')) {
    if (RegExp(r'^\S').hasMatch(l)) {
      inDeps = l.startsWith('dependencies:');
      continue;
    }
    if (!inDeps) continue;
    final m = RegExp(r'^  ([a-z0-9_]+):').firstMatch(l);
    if (m != null) out.add(m.group(1)!);
  }
  return out;
}

/// What is wrong with a generated project (empty = looks fine). Not a compiler: brackets and quotes,
/// the files it needs, imports that point nowhere, packages that are not declared.
List<String> checkProject(Map<String, String> files, String pkg) {
  final out = <String>[];
  final pub = files['pubspec.yaml'];
  if (pub == null) {
    out.add('pubspec.yaml: missing');
  } else if (!declaredPackages(pub).contains('flutter')) {
    out.add('pubspec.yaml: it must list flutter (sdk: flutter) under dependencies');
  }
  final main = files['lib/main.dart'];
  if (main == null) {
    out.add('lib/main.dart: missing');
  } else if (!RegExp(r'void\s+main\s*\(').hasMatch(main)) {
    out.add('lib/main.dart: has no main() function');
  }
  final deps = pub == null ? <String>{} : declaredPackages(pub);
  final rx = RegExp(r'''^\s*(?:import|export|part)\s+['"]([^'"]+)['"]''', multiLine: true);
  for (final e in files.entries) {
    if (!e.key.endsWith('.dart')) continue;
    final err = validateChange(e.key, null, e.value);
    if (err != null) out.add('${e.key}: $err');
    for (final m in rx.allMatches(e.value)) {
      final u = m.group(1)!;
      if (u.startsWith('dart:')) continue;
      if (u.startsWith('package:')) {
        final rest = u.substring(8);
        final name = rest.split('/').first;
        if (name == pkg) {
          final p = 'lib/${rest.substring(name.length + 1)}';
          if (!files.containsKey(p)) out.add('${e.key}: imports $u but the file $p does not exist');
        } else if (name != 'flutter' && !deps.contains(name)) {
          out.add('${e.key}: uses the package "$name", which is not declared in pubspec.yaml');
        }
      } else {
        final target = _resolve(e.key, u);
        if (!files.containsKey(target)) out.add('${e.key}: imports $u but $target does not exist');
      }
    }
  }
  return out;
}

/// Makes sure the pubspec has the right name, a version, an SDK range and Material icons.
String fixPubspec(String text, String name) {
  var t = text.replaceAll('\r\n', '\n');
  final nameRx = RegExp(r'^name:.*$', multiLine: true);
  t = nameRx.hasMatch(t) ? t.replaceFirst(nameRx, 'name: $name') : 'name: $name\n$t';
  if (!RegExp(r'^version:', multiLine: true).hasMatch(t)) t = t.replaceFirst('name: $name', 'name: $name\nversion: 1.0.0+1');
  if (!RegExp(r'^publish_to:', multiLine: true).hasMatch(t)) t = t.replaceFirst('name: $name', "name: $name\npublish_to: 'none'");
  if (!RegExp(r'^environment:', multiLine: true).hasMatch(t)) t = "$t\nenvironment:\n  sdk: '>=3.0.0 <4.0.0'\n";
  if (!t.contains('uses-material-design')) {
    final fl = RegExp(r'^flutter:\s*$', multiLine: true);
    t = fl.hasMatch(t) ? t.replaceFirst(fl, 'flutter:\n  uses-material-design: true') : '$t\nflutter:\n  uses-material-design: true\n';
  }
  return t.endsWith('\n') ? t : '$t\n';
}

/// The new files of a model answer (path -> text). Anything that is not a complete new-file block is ignored.
Map<String, String> parseFiles(String answer) {
  final out = <String, String>{};
  for (final e in parsePatch(answer).edits) {
    if (!e.whole) continue;
    var p = e.path.trim().replaceAll('\\', '/');
    while (p.startsWith('./') || p.startsWith('/')) {
      p = p.substring(p.startsWith('./') ? 2 : 1);
    }
    if (p.isEmpty || p.contains('..')) continue;
    out[p] = e.content.endsWith('\n') ? e.content : '${e.content}\n';
  }
  return out;
}

const String kGitignore = '''
.dart_tool/
.packages
build/
.flutter-plugins
.flutter-plugins-dependencies
android/.gradle/
android/local.properties
*.iml
.idea/
''';

String readmeFor(String name, String brief) => '${brief.trim().startsWith('#') ? brief.trim() : '# $name\n\n${brief.trim()}'}\n\n---\nMade with AIy. Build it on GitHub from the AIy app, or run `flutter create --platforms android .` once and then `flutter run`.\n';
