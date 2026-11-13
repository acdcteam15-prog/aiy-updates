import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../logic/appgen.dart';
import '../logic/project.dart';
import '../ui/theme.dart';
import '../ui/widgets/icon_maker.dart';
import 'ai.dart';
import 'app_log.dart';
import 'error_center.dart';
import 'code_state.dart';
import 'keys.dart';
import 'native.dart';
import 'net.dart';
import 'prefs.dart';
import 'spend.dart';

class QA {
  String q;
  List<String> options;
  String answer;
  QA(this.q, this.options, [this.answer = '']);
  Map<String, dynamic> toJson() => {'q': q, 'o': options, 'a': answer};
  factory QA.fromJson(Map<String, dynamic> j) => QA('${j['q'] ?? ''}', [for (final o in (j['o'] as List? ?? const [])) '$o'], '${j['a'] ?? ''}');
}

/// An app idea on its way from a description to a finished Flutter project. Kept on the phone so it can be resumed.
class AppProject {
  final String id;
  String name = '';
  String idea = '';

  /// How many questions AIy asks (1 to 30).
  int count = 6;
  int preset = 0;

  /// system, dark or light
  String mode = 'dark';
  String icon = 'letter';
  List<QA> qa = [];

  /// The question on screen.
  int pos = 0;
  String brief = '';

  /// describe, setup, questions, brief, write, done
  String stage = 'describe';
  int updated = DateTime.now().millisecondsSinceEpoch;
  Map<String, String> files = {};
  String zip = '';
  double cost = 0;
  String model = '';
  List<String> problems = [];
  AppProject(this.id);

  String get title => name.trim().isNotEmpty ? name.trim() : (idea.trim().isEmpty ? 'New app' : (idea.trim().length > 32 ? '${idea.trim().substring(0, 32)}…' : idea.trim()));

  Map<String, dynamic> toJson() => {
        'id': id, 'name': name, 'idea': idea, 'count': count, 'preset': preset, 'mode': mode, 'icon': icon, 'qa': [for (final q in qa) q.toJson()], 'pos': pos,
        'brief': brief, 'stage': stage, 'updated': updated, 'files': files, 'zip': zip, 'cost': cost, 'model': model, 'problems': problems,
      };

  factory AppProject.fromJson(Map<String, dynamic> j) {
    final p = AppProject('${j['id']}')
      ..name = '${j['name'] ?? ''}'
      ..idea = '${j['idea'] ?? ''}'
      ..count = ((j['count'] as num?)?.toInt() ?? 6).clamp(1, 30)
      ..preset = (j['preset'] as num?)?.toInt() ?? 0
      ..mode = '${j['mode'] ?? 'dark'}'
      ..icon = '${j['icon'] ?? 'letter'}'
      ..pos = (j['pos'] as num?)?.toInt() ?? 0
      ..brief = '${j['brief'] ?? ''}'
      ..stage = '${j['stage'] ?? 'describe'}'
      ..updated = (j['updated'] as num?)?.toInt() ?? 0
      ..zip = '${j['zip'] ?? ''}'
      ..cost = (j['cost'] as num?)?.toDouble() ?? 0
      ..model = '${j['model'] ?? ''}'
      ..problems = [for (final x in (j['problems'] as List? ?? const [])) '$x'];
    p.qa = [
      for (final q in (j['qa'] as List? ?? const []))
        if (q is Map) QA.fromJson(Map<String, dynamic>.from(q))
    ];
    p.files = {for (final e in ((j['files'] as Map?) ?? const {}).entries) '${e.key}': '${e.value}'};
    return p;
  }
}

/// The Build tab: description -> look -> questions -> brief -> code, all on the phone.
class AppBuilder extends ChangeNotifier {
  final AiEngine engine;
  final KeyVault keys;
  final LocalPrefs prefs;
  final CodeState code;
  final SpendLog? spend;
  AppBuilder(this.engine, this.keys, this.prefs, this.code, [this.spend]) {
    _load();
  }

  List<AppProject> projects = [];
  AppProject? current;
  String busy = '';
  String? error;
  List<String> names = [];

  /// Text of the question or the brief while it is arriving (empty otherwise).
  String liveText = '';

  /// Where the writing of the app is: 'plan', 'write', 'check', 'zip' ('' when nothing runs), the files started and the newest one.
  String phase = '';
  int fileCount = 0;
  String fileNow = '';
  int round = 0;

  int _paintAt = 0;
  void _live() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _paintAt < 70) return;
    _paintAt = now;
    notifyListeners();
  }

  bool get isBusy => busy.isNotEmpty;

  // ------------------------------------------------------------------ the projects list
  Future<Directory> _dir() async {
    final d = Directory('${(await getApplicationDocumentsDirectory()).path}/aiy/projects');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  Future<void> _load() async {
    try {
      final out = <AppProject>[];
      for (final f in (await _dir()).listSync()) {
        if (f is File && f.path.endsWith('.json')) {
          try {
            out.add(AppProject.fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>));
          } catch (_) {}
        }
      }
      out.sort((a, b) => b.updated.compareTo(a.updated));
      projects = out;
    } catch (e) {
      debugPrint('projects load: $e');
    }
    notifyListeners();
  }

  Future<void> save() async {
    final p = current;
    if (p == null) return;
    p.updated = DateTime.now().millisecondsSinceEpoch;
    if (!projects.contains(p)) projects.insert(0, p);
    projects.sort((a, b) => b.updated.compareTo(a.updated));
    try {
      await File('${(await _dir()).path}/${p.id}.json').writeAsString(jsonEncode(p.toJson()));
    } catch (e) {
      debugPrint('project save: $e');
    }
  }

  void newProject() {
    if (isBusy) return;
    current = AppProject(DateTime.now().microsecondsSinceEpoch.toRadixString(36));
    error = null;
    names = [];
    notifyListeners();
  }

  void open(AppProject p) {
    if (isBusy) return;
    current = p;
    error = null;
    names = [];
    notifyListeners();
    if (p.stage == 'done') unawaited(_adopt(p));
  }

  Future<void> closeProject() async {
    if (isBusy) return;
    final p = current;
    // An idea that was never described is not worth keeping.
    if (p != null && p.idea.trim().isEmpty && p.name.trim().isEmpty) {
      projects.remove(p);
    } else {
      await save();
    }
    current = null;
    error = null;
    notifyListeners();
  }

  Future<void> delete(AppProject p) async {
    projects.remove(p);
    if (identical(current, p)) current = null;
    try {
      File('${(await _dir()).path}/${p.id}.json').deleteSync();
      if (p.zip.isNotEmpty) File(p.zip).deleteSync();
    } catch (_) {}
    notifyListeners();
  }

  void clearError() {
    error = null;
    notifyListeners();
  }

  void _fail(Object e, {String where = '', Future<void> Function()? retry, Future<void> Function(OrModel m)? retryWith, String modelId = ''}) {
    busy = '';
    phase = '';
    liveText = '';
    error = e is ApiError ? e.message : 'Something went wrong: $e';
    AppLog.i('build tab: $error');
    notifyListeners();
    ErrorCenter.report(e, where: where, retry: retry, retryWith: retryWith, modelId: modelId, costOf: (m) {
      final est = estimate(m);
      return (cost: est.cost, worst: est.worstCase);
    });
  }

  Future<void> reload() async {
    projects = [];
    await _load();
  }

  // ------------------------------------------------------------------ the look
  String look(AppProject p) =>
      'app name "${p.name}"; colour theme ${presetAt(p.preset).name}; ${p.mode == 'system' ? 'follows the phone\'s light or dark setting' : '${p.mode} mode'}; icon style ${p.icon}';

  String themeNote(AppProject p) {
    final c = presetAt(p.preset).seed;
    final hex = '0x${c.toARGB32().toRadixString(16).toUpperCase().padLeft(8, '0')}';
    final mode = p.mode == 'dark' ? 'ThemeMode.dark' : (p.mode == 'light' ? 'ThemeMode.light' : 'ThemeMode.system');
    return 'Theme: Material 3 with ColorScheme.fromSeed(seedColor: const Color($hex)) for both the light and the dark theme, and themeMode: $mode.';
  }

  Future<void> toSetup(String idea, int count) async {
    final p = current;
    if (p == null) return;
    p.idea = idea.trim();
    p.count = count.clamp(1, 30);
    p.stage = 'setup';
    await save();
    notifyListeners();
  }

  Future<void> suggestNames() async {
    final p = current;
    if (p == null || isBusy) return;
    try {
      busy = 'Thinking of names…';
      error = null;
      notifyListeners();
      final r = await engine.ask(namesPrompt(p.idea), json: true);
      names = parseFileList(r.text).where((n) => n.length <= 40).take(4).toList();
      busy = '';
      notifyListeners();
    } catch (e) {
      _fail(e, where: 'Thinking of names', retry: suggestNames);
    }
  }

  // ------------------------------------------------------------------ the questions
  Future<void> startQuestions({required String name, required String icon, required int preset, required String mode}) async {
    final p = current;
    if (p == null || isBusy) return;
    p.name = name.trim();
    p.icon = icon;
    p.preset = preset;
    p.mode = mode;
    // Same answers kept when the person only came back to change the look.
    if (p.qa.isEmpty) p.pos = 0;
    p.stage = 'questions';
    await save();
    notifyListeners();
    if (p.qa.isEmpty) await _ask();
  }

  QA? get question {
    final p = current;
    if (p == null || p.pos < 0 || p.pos >= p.qa.length) return null;
    return p.qa[p.pos];
  }

  Future<void> _ask() async {
    final p = current;
    if (p == null) return;
    try {
      busy = 'Thinking of the next question…';
      error = null;
      notifyListeners();
      final done = [for (final q in p.qa) (q.q, q.answer)];
      liveText = '';
      final r = await engine.ask(questionPrompt(idea: p.idea, look: look(p), qa: done, n: p.qa.length + 1, total: p.count), system: questionSystem(), json: true, onText: (t) {
        liveText = partialQuestion(t);
        _live();
      });
      liveText = '';
      final q = parseQuestion(r.text);
      if (q == null) throw ApiError('The AI did not give a usable question. Tap "Try again".');
      p.qa.add(QA(q.q, q.options));
      p.pos = p.qa.length - 1;
      busy = '';
      await save();
      notifyListeners();
    } catch (e) {
      _fail(e, where: 'Thinking of the next question', retry: _ask);
    }
  }

  Future<void> retryQuestion() => _ask();

  /// Answer (an empty text means "you decide") and move on.
  Future<void> answer(String a) async {
    final p = current;
    final q = question;
    if (p == null || q == null || isBusy) return;
    q.answer = a.trim();
    await save();
    if (p.pos + 1 < p.qa.length) {
      p.pos++;
      notifyListeners();
    } else if (p.qa.length >= p.count) {
      await writeBrief();
    } else {
      notifyListeners();
      await _ask();
    }
  }

  void back() {
    final p = current;
    if (p == null || isBusy || p.pos <= 0) return;
    p.pos--;
    error = null;
    notifyListeners();
  }

  void backToSetup() {
    final p = current;
    if (p == null || isBusy) return;
    p.stage = 'setup';
    save();
    notifyListeners();
  }

  void backToDescribe() {
    final p = current;
    if (p == null || isBusy) return;
    p.stage = 'describe';
    save();
    notifyListeners();
  }

  void backToQuestions() {
    final p = current;
    if (p == null || isBusy) return;
    p.stage = 'questions';
    if (p.pos >= p.qa.length) p.pos = p.qa.isEmpty ? 0 : p.qa.length - 1;
    save();
    notifyListeners();
  }

  // ------------------------------------------------------------------ the brief
  Future<void> writeBrief() async {
    final p = current;
    if (p == null) return;
    try {
      p.stage = 'brief';
      busy = 'Writing the app brief…';
      error = null;
      notifyListeners();
      liveText = '';
      final r = await engine.ask(briefPrompt(name: p.name, idea: p.idea, look: look(p), qa: [for (final q in p.qa) (q.q, q.answer)]), system: briefSystem(), onText: (t) {
        liveText = t;
        _live();
      });
      liveText = '';
      p.brief = r.text.trim();
      busy = '';
      await save();
      notifyListeners();
    } catch (e) {
      _fail(e, where: 'Writing the app brief', retry: writeBrief);
    }
  }

  Future<void> setBrief(String t) async {
    final p = current;
    if (p == null) return;
    p.brief = t;
    await save();
  }

  Future<void> toWrite() async {
    final p = current;
    if (p == null || p.brief.trim().isEmpty) return;
    p.stage = 'write';
    await save();
    notifyListeners();
  }

  void backToBrief() {
    final p = current;
    if (p == null || isBusy) return;
    p.stage = 'brief';
    save();
    notifyListeners();
  }

  // ------------------------------------------------------------------ writing the code
  CostEstimate estimate(OrModel m) {
    final p = current!;
    final pkg = snakeName(p.name);
    final system = genSystem(pkg);
    final user = genUser(brief: p.brief, name: p.name, pkg: pkg, themeNote: themeNote(p), plan: List.generate(8, (i) => (path: 'lib/file$i.dart', purpose: 'a part of the app that does one thing')));
    final inTok = estimateTokens(system) + estimateTokens(user);
    const outTok = 9000;
    final cost = m.free ? 0.0 : inTok * m.promptPrice + outTok * m.completionPrice;
    var maxTok = 24000;
    String? blocked;
    if (m.context > 0 && inTok + 5000 > m.context) {
      blocked = 'This model reads only ${m.context} tokens, too little for writing a whole app. Pick another model.';
    } else if (!m.free) {
      final cap = prefs.capUsd;
      final afford = m.completionPrice > 0 ? ((cap - inTok * m.promptPrice) / m.completionPrice).floor() : 24000;
      if (afford < 4000) {
        blocked = 'Your limit of \$${cap.toStringAsFixed(2)} is too low to write a whole app with this model. Pick a cheaper model, or raise the limit in Settings > Coding.';
      } else if (afford < maxTok) {
        maxTok = afford;
      }
    }
    final worst = m.free ? 0.0 : inTok * m.promptPrice + maxTok * m.completionPrice;
    return CostEstimate(inTok, outTok, cost, worst, maxTok, blocked);
  }

  /// Files a repair round has to write: the ones named in the problems and the ones that are missing.
  static List<String> _targets(List<String> problems, List<String> missing) {
    final out = <String>{...missing};
    for (final p in problems) {
      final head = p.split(':').first.trim();
      if (head.contains('/') || head.endsWith('.yaml')) out.add(head);
      final m = RegExp(r'(?:file|but) (\S+) does not exist').firstMatch(p);
      if (m != null) out.add(m.group(1)!);
    }
    return out.toList();
  }

  Future<void> generate(OrModel m) async {
    final p = current;
    if (p == null || isBusy) return;
    final est = estimate(m);
    if (est.blocked != null) {
      error = est.blocked;
      notifyListeners();
      return;
    }
    final cap = prefs.capUsd;
    final pkg = snakeName(p.name);
    var spent = 0.0;
    try {
      error = null;
      busy = 'Planning the files…';
      phase = 'plan';
      fileCount = 0;
      fileNow = '';
      round = 0;
      notifyListeners();
      var plan = parsePlan('');
      try {
        final r = await engine.ask(planPrompt(p.brief, p.name), system: 'You are a senior Flutter developer planning a small app.', json: true);
        plan = parsePlan(r.text);
      } on ApiError {
        // The free services are busy: the model writes the files it needs on its own.
      }
      final system = genSystem(pkg);
      final files = <String, String>{};
      var problems = <String>[];
      var cut = false;
      for (var round = 0; round < 3; round++) {
        final missing = [for (final f in plan) if (!files.containsKey(f.path)) f.path];
        final only = round == 0 ? <String>[] : _targets(problems, missing);
        final user = genUser(
          brief: p.brief,
          name: p.name,
          pkg: pkg,
          themeNote: themeNote(p),
          plan: plan,
          written: round == 0 ? const {} : files,
          only: only,
          problems: round == 0 ? const [] : problems,
        );
        final inTok = estimateTokens(system) + estimateTokens(user);
        var maxTok = 24000;
        if (!m.free && m.completionPrice > 0) {
          maxTok = ((cap - spent - inTok * m.promptPrice) / m.completionPrice).floor().clamp(0, 24000);
        }
        if (maxTok < 1500) {
          if (files.isEmpty) throw ApiError('Your limit of \$${cap.toStringAsFixed(2)} was used up before any code was written. Raise the limit in Settings > Coding.');
          break;
        }
        busy = round == 0 ? 'Writing the code with ${m.name}…' : 'Fixing ${problems.length} problem(s) (pass ${round + 1} of 3)…';
        phase = 'write';
        this.round = round + 1;
        fileCount = 0;
        fileNow = '';
        notifyListeners();
        final r = await engine.openRouter(m.id, system, user, maxTokens: maxTok, onText: (t) {
          if (t.isEmpty) return;
          final pr = writingProgress(t);
          fileCount = pr.count;
          fileNow = pr.current;
          busy = round == 0 ? 'Writing ${pr.current.isEmpty ? 'the code' : pr.current} with ${m.name}…' : 'Fixing ${problems.length} problem(s) (pass ${round + 1} of 3)…';
          _live();
        });
        spent += m.free ? 0 : r.inTokens * m.promptPrice + r.outTokens * m.completionPrice;
        cut = r.cut;
        final got = parseFiles(r.text);
        if (got.isEmpty && files.isEmpty) {
          throw ApiError(r.cut
              ? 'The answer was cut off before the first file was finished (the spending limit keeps answers short). Raise the limit in Settings > Coding, or pick another model.'
              : 'The model answered, but not with files in the expected format. Try again, or pick another model.');
        }
        files.addAll(got);
        if (files.containsKey('pubspec.yaml')) files['pubspec.yaml'] = fixPubspec(files['pubspec.yaml']!, pkg);
        problems = checkProject(files, pkg);
        if (problems.isEmpty) break;
        busy = 'Checking the project…';
        phase = 'check';
        notifyListeners();
      }
      if (files.isEmpty) throw ApiError('No files were written.');
      busy = 'Making the zip and the icon…';
      phase = 'zip';
      notifyListeners();
      files['.aiy/app_name.txt'] = '${p.name}\n';
      files['.aiy/brief.md'] = '${p.brief.trim()}\n';
      files['README.md'] = readmeFor(p.name, p.brief);
      files['.gitignore'] = kGitignore;
      final icon = await renderIcon(p.icon, p.name, presetAt(p.preset).glow);
      final zip = await _writeZip(p.id, pkg, files, icon);
      p.files = files;
      p.zip = zip;
      p.cost = spent;
      p.model = m.name;
      p.problems = problems;
      p.stage = 'done';
      unawaited(spend?.add('app', p.title, m.name, spent) ?? Future<void>.value());
      await save();
      busy = '';
      phase = '';
      notifyListeners();
      await _adopt(p);
      if (cut && problems.isNotEmpty) {
        error = 'The model ran out of room before finishing. Open Code mode to continue the app, or write it again with another model.';
        notifyListeners();
      }
    } catch (e) {
      _fail(e, where: 'Writing the app with ${m.name}', retry: () => generate(m), retryWith: generate, modelId: m.id);
    }
  }

  Future<String> _writeZip(String id, String pkg, Map<String, String> files, Uint8List icon) async {
    final dir = Directory('${(await getApplicationDocumentsDirectory()).path}/aiy/builds')..createSync(recursive: true);
    final out = '${dir.path}/app_$id.zip';
    await Native.zipCreate(out, {for (final e in files.entries) '$pkg/${e.key}': e.value}, {'$pkg/.aiy/icon.png': icon});
    return out;
  }

  /// Makes the written app the open project of the Code tab (so Publish, Build and later changes work on it).
  Future<void> _adopt(AppProject p) async {
    // Already the open project (for example after coming back to this screen): leave it as it is.
    if (code.hasSource && code.hasResult && code.sourceName == p.title && !code.isBusy) return;
    try {
      var zip = p.zip;
      if (zip.isEmpty || !File(zip).existsSync()) {
        final icon = await renderIcon(p.icon, p.name, presetAt(p.preset).glow);
        zip = await _writeZip(p.id, snakeName(p.name), p.files, icon);
        p.zip = zip;
        await save();
      }
      await code.adoptGenerated(zip: zip, name: p.title, texts: p.files, summary: p.brief, request: 'Create the app "${p.title}"', model: p.model, cost: p.cost);
    } catch (e) {
      debugPrint('adopt: $e');
    }
  }

  Future<String> saveZip(AppProject p) async => code.saveToDownloads(p.zip, code.zipNameFor('${snakeName(p.name)}.zip', p.id));
}
