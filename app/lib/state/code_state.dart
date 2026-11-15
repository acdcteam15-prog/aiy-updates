import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../logic/fixcontext.dart';
import '../logic/buildlog.dart';
import '../logic/patcher.dart';
import '../logic/project.dart';
import 'ai.dart';
import 'app_log.dart';
import 'connectivity.dart';
import 'error_center.dart';
import 'github.dart';
import 'keys.dart';
import 'native.dart';
import 'net.dart';
import 'prefs.dart';
import 'spend.dart';
import 'store.dart';
import 'paid_jobs.dart';

/// One file touched by a patch.
class FileChange {
  final String path;

  /// Text before the change (null for a new file).
  final String? before;
  String after;

  /// SEARCH parts that could not be found in the file.
  List<String> failures = [];

  /// A structure problem found after the change (unbalanced bracket, broken JSON...).
  String? problem;
  FileChange(this.path, this.before, this.after);

  /// What the model wrote (kept so changes that were turned off can be turned on again).
  String? written;

  /// Changed parts the person turned off in the review (numbers of [diffHunks]).
  Set<int> rejected = {};

  bool get isNew => before == null;
  bool get changed => before != after;
  bool get ok => failures.isEmpty && problem == null;
}

/// A finished build kept in the history.
class BuildRecord {
  final String id;
  final int date;
  final String source;
  final String request;
  final String summary;
  final String model;
  final List<String> files;
  final String zip;
  final String repo;
  final String branch;
  final double cost;
  final int warnings;
  const BuildRecord({
    required this.id,
    required this.date,
    required this.source,
    required this.request,
    required this.summary,
    required this.model,
    required this.files,
    required this.zip,
    this.repo = '',
    this.branch = '',
    this.cost = 0,
    this.warnings = 0,
  });

  Map<String, dynamic> toJson() =>
      {'id': id, 'date': date, 'source': source, 'request': request, 'summary': summary, 'model': model, 'files': files, 'zip': zip, 'repo': repo, 'branch': branch, 'cost': cost, 'warnings': warnings};
  factory BuildRecord.fromJson(Map<String, dynamic> j) => BuildRecord(
        id: '${j['id']}',
        date: (j['date'] as num?)?.toInt() ?? 0,
        source: '${j['source'] ?? ''}',
        request: '${j['request'] ?? ''}',
        summary: '${j['summary'] ?? ''}',
        model: '${j['model'] ?? ''}',
        files: [for (final f in (j['files'] as List? ?? const [])) '$f'],
        zip: '${j['zip'] ?? ''}',
        repo: '${j['repo'] ?? ''}',
        branch: '${j['branch'] ?? ''}',
        cost: (j['cost'] as num?)?.toDouble() ?? 0,
        warnings: (j['warnings'] as num?)?.toInt() ?? 0,
      );
}

/// What a request to the chosen model will cost, worked out before it is sent.
class CostEstimate {
  final int inTokens;
  final int outTokens;
  final double cost;

  /// The most the request can cost (input + the output limit).
  final double worstCase;
  final int maxTokens;

  /// Why the request cannot be sent (over the spending cap, too big for the model), or null.
  final String? blocked;
  const CostEstimate(this.inTokens, this.outTokens, this.cost, this.worstCase, this.maxTokens, this.blocked);
}

/// Programming Mode. Everything happens on the phone: the zip is scanned, the clean source tree is read,
/// the free models choose the files, the chosen OpenRouter model writes the patch, the patch is applied,
/// checked, and a complete new zip is written (original bloat folders included).
class CodeState extends ChangeNotifier {
  final AiEngine engine;
  final KeyVault keys;
  final LocalPrefs prefs;
  final SpendLog? spend;
  CodeState(this.engine, this.keys, this.prefs, [this.spend]) {
    _loadHistory();
  }

  // ---- source
  String sourceName = '';
  String zipPath = '';
  String repo = '';
  String branch = '';
  String _root = '';
  int allCount = 0;
  int allBytes = 0;
  int srcBytes = 0;
  Set<String> _allRel = {};

  /// Clean source tree: path (without the zip's top folder) -> text.
  Map<String, String> texts = {};
  String projectMap = '';

  // ---- work in progress
  String busy = '';
  String? error;
  String explanation = '';
  String explainBadge = '';
  String request = '';
  List<String> targets = [];
  String routeBadge = '';

  /// Everything already pushed or applied since the project was opened (path -> text): the base for the next change.
  final Map<String, String> applied = {};
  String _fixPrompt = '';
  List<({String name, int size})> zipEntries = [];
  String get zipRoot => _root;

  // ---- result
  String summary = '';
  List<FileChange> changes = [];
  String usedModel = '';
  double spent = 0;
  bool healed = false;
  String outZip = '';

  List<BuildRecord> history = [];

  bool get hasSource => zipPath.isNotEmpty;
  bool get hasResult => changes.isNotEmpty;
  bool get isBusy => busy.isNotEmpty;
  int get warnings => changes.where((c) => !c.ok).length;

  void _busy(String label) {
    heldOffline = false;
    busy = label;
    error = null;
    notifyListeners();
  }

  /// True while the last job is waiting for the internet (the auto-fix loop pauses on this).
  bool heldOffline = false;

  /// Title under which the last job waits for the internet ('' when none).
  String heldTitle = '';

  void _fail(Object e, {String where = '', Future<void> Function()? retry, Future<void> Function(OrModel m)? retryWith, String modelId = '', PaidJob? paid}) {
    // No internet: the job waits and is sent again by itself when the connection is back.
    // A paid job is also written to the phone, so after a restart AIy can ask (with the price) whether to continue.
    if (retry != null &&
        where.isNotEmpty &&
        Offline.hold(e, title: where, run: () async {
          heldOffline = false;
          heldTitle = '';
          if (paid != null) {
            // A paid job never restarts by itself: the person sees the price again and decides.
            await PaidJobs.instance.askNow(paid.id);
            return;
          }
          await retry();
        }, onCancel: () {
          heldOffline = false;
          heldTitle = '';
          if (paid != null) unawaited(PaidJobs.instance.done(paid.id));
        })) {
      heldOffline = true;
      heldTitle = where;
      if (paid != null) unawaited(PaidJobs.instance.hold(paid));
      busy = '';
      error = 'No internet. "$where" will be sent again by itself when the connection is back.';
      notifyListeners();
      return;
    }
    busy = '';
    error = e is ApiError ? e.message : '$e';
    AppLog.i('code: $error');
    notifyListeners();
    // An OpenRouter problem also opens a pop-up, so it is seen at once wherever the person is looking.
    ErrorCenter.report(e, where: where, retry: retry, retryWith: retryWith, modelId: modelId, general: true, costOf: (m) {
      final est = estimate(m);
      return (cost: est.cost, worst: est.worstCase);
    });
  }

  int _paintAt = 0;

  /// Repaints at most about 14 times a second while an answer is arriving.
  void _liveNotify() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _paintAt < 70) return;
    _paintAt = now;
    notifyListeners();
  }

  /// Text of an answer that is being written (shown while [explain] works).
  String explainLive = '';

  /// Text of an answer to a question about the project that is being written.
  String askLive = '';

  /// Opens a zip that another app shared into AIy.
  Future<void> openShared(SharedFile f) async {
    if (isBusy) return;
    try {
      if (f.size > 100 * 1024 * 1024) throw ApiError('This file is ${(f.size / 1048576).toStringAsFixed(0)} MB. The limit is 100 MB.');
      _busy('Opening ${f.name}…');
      await _open(f.path, f.name, '', '');
    } catch (e) {
      _fail(e is ApiError ? e : ApiError('Could not open this file: ${_msg(e)}'));
    }
  }

  void clearError() {
    error = null;
    notifyListeners();
  }

  Future<Directory> _dir([String sub = '']) async {
    final d = Directory('${(await getApplicationDocumentsDirectory()).path}/aiy${sub.isEmpty ? '' : '/$sub'}');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  // ------------------------------------------------------------------ source
  void closeProject() {
    sourceName = zipPath = repo = branch = _root = '';
    texts = {};
    projectMap = '';
    _resetWork();
    notifyListeners();
  }

  void _resetWork() {
    explanation = explainBadge = request = routeBadge = summary = usedModel = outZip = _fixPrompt = '';
    applied.clear();
    asks.clear();
    shotNote = shotPath = '';
    targets = [];
    changes = [];
    spent = 0;
    healed = false;
    error = null;
  }

  Future<void> pickZip() async {
    if (isBusy) return;
    try {
      _busy('Opening the file picker…');
      final f = await Native.pickZip();
      if (f == null) {
        busy = '';
        notifyListeners();
        return;
      }
      if (f.size > 100 * 1024 * 1024) throw ApiError('This file is ${(f.size / 1048576).toStringAsFixed(0)} MB. The limit is 100 MB.');
      await _open(f.path, f.name, '', '');
    } catch (e) {
      _fail(e is ApiError ? e : ApiError('Could not open this file: ${_msg(e)}'));
    }
  }

  Future<void> loadGitHub(String full, String br) async {
    if (isBusy) return;
    try {
      _busy('Downloading $full…');
      final dir = Directory('${(await getTemporaryDirectory()).path}/picked');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final out = File('${dir.path}/github.zip');
      var last = 0;
      await GitHubApi(keys.get('github')).downloadZip(full, br, out, onProgress: (got) {
        if (got - last > 512 * 1024) {
          last = got;
          busy = 'Downloading $full… ${(got / 1048576).toStringAsFixed(1)} MB';
          notifyListeners();
        }
      });
      await _open(out.path, '$full ($br)', full, br);
    } catch (e) {
      _fail(e is ApiError ? e : ApiError('Could not download the repository: ${_msg(e)}'));
    }
  }

  /// Starts again from an earlier build (its complete zip).
  Future<void> openBuild(BuildRecord b) async {
    if (isBusy) return;
    try {
      if (!File(b.zip).existsSync()) throw ApiError('The zip of this build is no longer on the phone.');
      _busy('Opening the build…');
      await _open(b.zip, b.source, b.repo, b.branch);
    } catch (e) {
      _fail(e);
    }
  }

  static String _msg(Object e) {
    final s = '$e';
    final m = RegExp(r'PlatformException\([^,]*,\s*(.*?),\s*null').firstMatch(s);
    return m?.group(1) ?? s;
  }

  Future<void> _open(String path, String name, String repoFull, String br) async {
    _busy('Looking inside the project…');
    final entries = await Native.zipScan(path);
    if (entries.isEmpty) throw ApiError('This zip is empty.');
    final root = commonRoot(entries.map((e) => e.name));
    final wanted = [
      for (final e in entries)
        if (isSource(e.name.substring(root.length), e.size)) e.name
    ];
    if (wanted.isEmpty) throw ApiError('No source code files were found in this zip.');
    if (wanted.length > 5000) throw ApiError('This project has ${wanted.length} source files, more than AIy can map (5000). Zip a smaller part of it.');
    _busy('Reading ${wanted.length} source files…');
    final read = await Native.zipRead(path, wanted, maxBytes: kMaxSourceBytes);
    final t = <String, String>{for (final e in read.entries) e.key.substring(root.length): e.value};
    _busy('Mapping the project…');
    final map = buildProjectMap(t.keys.toList(), t);
    sourceName = name;
    zipPath = path;
    repo = repoFull;
    branch = br;
    _root = root;
    zipEntries = entries;
    allCount = entries.length;
    allBytes = entries.fold(0, (s, e) => s + (e.size > 0 ? e.size : 0));
    _allRel = {for (final e in entries) e.name.substring(root.length)};
    texts = t;
    srcBytes = t.values.fold(0, (s, v) => s + v.length);
    projectMap = map;
    _resetWork();
    busy = '';
    notifyListeners();
  }

  // ------------------------------------------------------------------ explain
  Future<void> explain() async {
    if (isBusy || !hasSource) return;
    try {
      _busy('Reading the project map…');
      explainLive = '';
      final readmeKey = texts.keys.firstWhere((k) => RegExp(r'^readme(\.(md|txt|rst|markdown))?$', caseSensitive: false).hasMatch(k), orElse: () => '');
      var readme = readmeKey.isEmpty ? '' : texts[readmeKey]!;
      if (readme.length > 4000) readme = readme.substring(0, 4000);
      final r = await engine.ask(
        'Project: $sourceName\n\n'
        '${readme.isEmpty ? '' : 'README (start):\n$readme\n\n'}'
        'Project map (every source file, with its line count and its import lines):\n$projectMap\n\n'
        'Explain this codebase in plain English for someone who is not a programmer:\n'
        '1. What the project is and what it does.\n'
        '2. The main parts (folders / layers) and what each is for.\n'
        '3. How the parts connect (who calls whom), in a few sentences.\n'
        '4. Where to look to change the most common things.\n'
        'Use short Markdown headings and bullet points. Mention real file and folder names. Do not invent files.',
        system: 'You explain software projects clearly and honestly to non-programmers.',
        onText: (t) {
          explainLive = t;
          _liveNotify();
        },
      );
      explainLive = '';
      explanation = r.text;
      explainBadge = '${r.provider} · ${r.model}';
      busy = '';
      notifyListeners();
    } catch (e) {
      explainLive = '';
      _fail(e, where: 'Explaining the project', retry: explain);
    }
  }

  // ------------------------------------------------------------------ step 1: choose the files (free models)
  Future<void> route(String req) async {
    if (isBusy || !hasSource || req.trim().isEmpty) return;
    try {
      request = req.trim();
      summary = usedModel = outZip = _fixPrompt = '';
      changes = [];
      targets = [];
      _busy('Finding the files that need to change…');
      final r = await engine.ask(
        'Project map (every source file, with its line count and its import lines):\n$projectMap\n\n'
        'Requested change:\n$request\n\n${shotNote.isEmpty ? '' : 'Screenshot of the problem (described by an AI that saw it):\n$shotNote\n\n'}'
        'Return a JSON array with the paths of ALL files that must be created or modified for this change. '
        'Include the files that depend on the change too (interfaces, routes, registrations, imports, manifests, build files, tests), so nothing breaks. '
        'Use paths exactly as written in the map. A file that must be created gets its intended new path. '
        'Choose carefully: at most 15 files, and only files that really need an edit. '
        'Answer with the JSON array only, for example: ["src/app.js", "src/routes/index.js"]',
        system: 'You are a senior software engineer who decides which files a change touches. You answer with a JSON array of file paths and nothing else.',
        json: true,
      );
      final picked = <String>[];
      for (final raw in parseFileList(r.text)) {
        final p = _resolve(raw);
        if (p.isNotEmpty && !picked.contains(p)) picked.add(p);
      }
      if (picked.isEmpty) throw ApiError('The AI did not name any files. Describe the change with a little more detail and try again.');
      // A file that exists in the zip but is not part of the clean tree (too big, or filtered): try to read it now.
      final extra = [
        for (final p in picked)
          if (!texts.containsKey(p) && _allRel.contains(p)) p
      ];
      if (extra.isNotEmpty) {
        final read = await Native.zipRead(zipPath, [for (final p in extra) '$_root$p'], maxBytes: 600000);
        for (final e in read.entries) {
          texts[e.key.substring(_root.length)] = e.value;
        }
        picked.removeWhere((p) => !texts.containsKey(p) && _allRel.contains(p));
      }
      targets = picked.take(20).toList();
      routeBadge = '${r.provider} · ${r.model}';
      busy = '';
      notifyListeners();
    } catch (e) {
      _fail(e, where: 'Choosing the files', retry: () => route(req));
    }
  }

  /// Maps a path from a model's answer onto a real file of the project (models sometimes add or drop a folder).
  String _resolve(String raw) {
    var p = raw.trim().replaceAll('\\', '/');
    while (p.startsWith('./') || p.startsWith('/')) {
      p = p.substring(p.startsWith('./') ? 2 : 1);
    }
    if (p.isEmpty || p.contains('..')) return '';
    if (texts.containsKey(p) || _allRel.contains(p)) return p;
    if (_root.isNotEmpty && p.startsWith(_root)) {
      final q = p.substring(_root.length);
      if (texts.containsKey(q) || _allRel.contains(q)) return q;
    }
    final ends = texts.keys.where((k) => k.endsWith('/$p')).toList();
    if (ends.length == 1) return ends.first;
    return p; // a new file
  }

  bool isNewFile(String path) => !texts.containsKey(path) && !applied.containsKey(path);

  /// The current text of a file: what was pushed since opening, else what the project had.
  String? cur(String path) => applied[path] ?? texts[path];

  void removeTarget(String path) {
    targets = [...targets]..remove(path);
    notifyListeners();
  }

  void addTarget(String path) {
    if (!targets.contains(path)) targets = [...targets, path];
    notifyListeners();
  }

  // ------------------------------------------------------------------ step 2: cost estimate + patch (OpenRouter)
  static const _system = 'You are an expert software engineer making one precise change to an existing project. '
      'You are shown only the files that need to change. Keep the existing style, names and formatting. Change only what the request needs.\n$kPatchFormat';

  String _userPrompt() {
    if (_fixPrompt.isNotEmpty) return _fixPrompt;
    final sb = StringBuffer('Project: $sourceName\n\nRequested change:\n$request\n\n${shotNote.isEmpty ? '' : 'Screenshot of the problem (described by an AI that saw it):\n$shotNote\n\n'}');
    final fresh = targets.where(isNewFile).toList();
    if (fresh.isNotEmpty) sb.writeln('Files to CREATE (they do not exist yet): ${fresh.join(', ')}\n');
    sb.writeln('Current files:\n');
    for (final p in targets.where((p) => !isNewFile(p))) {
      sb.writeln('=== FILE: $p ===\n${cur(p)}\n=== END OF $p ===\n');
    }
    return sb.toString();
  }

  CostEstimate estimate(OrModel m) {
    final inTok = estimateTokens(_system) + estimateTokens(_userPrompt());
    final outTok = (inTok * 0.4).clamp(1500, 12000).round();
    final cost = inTok * m.promptPrice + outTok * m.completionPrice;
    var maxTokens = 16000;
    String? blocked;
    if (m.context > 0 && inTok + 3000 > m.context) {
      blocked = 'These files are too big for this model (about $inTok tokens, the model reads ${m.context}). Pick a model with a larger context, or remove a file.';
    } else if (!m.free) {
      final cap = prefs.capUsd;
      final afford = m.completionPrice > 0 ? ((cap - inTok * m.promptPrice) / m.completionPrice).floor() : 16000;
      if (afford < 1200) {
        blocked = 'This would cost more than your limit of \$${cap.toStringAsFixed(2)} for one request. Pick a cheaper model, remove a file, or raise the limit in Settings.';
      } else if (afford < maxTokens) {
        maxTokens = afford;
      }
    }
    final worst = m.free ? 0.0 : inTok * m.promptPrice + maxTokens * m.completionPrice;
    if (!m.free && blocked == null) blocked = spend?.budgetBlock(worst, dayCap: prefs.dayCapUsd, monthCap: prefs.monthCapUsd);
    return CostEstimate(inTok, outTok, m.free ? 0 : cost, worst, maxTokens, blocked);
  }

  void _apply(PatchPlan plan, Map<String, FileChange> state) {
    for (final edit in plan.edits) {
      final path = _resolve(edit.path);
      if (path.isEmpty) continue;
      final fc = state.putIfAbsent(path, () => FileChange(path, cur(path), cur(path) ?? ''));
      if (edit.whole) {
        fc.after = edit.content;
        fc.failures = [];
      } else if (fc.before == null && fc.after.isEmpty) {
        fc.failures = ['The model tried to edit this file, but it does not exist in the project.'];
      } else {
        final r = applyBlocks(fc.after, edit.blocks);
        fc.after = r.text;
        fc.failures = r.failures;
      }
    }
    for (final fc in state.values) {
      fc.problem = validateChange(fc.path, fc.before, fc.after);
    }
  }

  Future<void> patch(OrModel m) async {
    if (isBusy || targets.isEmpty) return;
    final est = estimate(m);
    if (est.blocked != null) {
      _fail(ApiError(est.blocked!));
      return;
    }
    try {
      _busy('${m.name} is writing the patch…');
      final user = _userPrompt();
      var r = await engine.openRouter(m.id, _system, user, maxTokens: est.maxTokens, track: !m.free, onRetry: (n) {
        busy = '${m.name}: $n';
        notifyListeners();
      }, onText: (t) {
        if (t.isEmpty) return;
        busy = '${m.name} is writing the patch… ${'\n'.allMatches(t).length} lines so far';
        _liveNotify();
      });
      var cost = r.inTokens * m.promptPrice + r.outTokens * m.completionPrice;
      final plan = parsePatch(r.text);
      if (plan.edits.isEmpty) {
        throw ApiError(r.cut
            ? 'The answer was cut off before any change was complete (the spending limit keeps answers short). Raise the limit in Settings or pick a cheaper model.'
            : 'The model answered, but not with changes in the expected format. Try again or pick another model.\n\nIt said: ${r.text.length > 300 ? '${r.text.substring(0, 300)}…' : r.text}');
      }
      final state = <String, FileChange>{};
      _apply(plan, state);
      var sum = plan.summary;
      var didHeal = false;
      final bad = state.values.where((c) => !c.ok).toList();
      if (bad.isNotEmpty) {
        // Self-healing: send the exact problems back once.
        didHeal = true;
        _busy('Found ${bad.length} problem(s). Asking ${m.name} to fix them…');
        final sb = StringBuffer('Your previous answer was applied, but these problems were found:\n\n');
        for (final c in bad) {
          for (final f in c.failures) {
            sb.writeln('- ${c.path}: $f');
          }
          if (c.problem != null) sb.writeln('- ${c.path}: after your change the file has a syntax problem: ${c.problem}');
        }
        sb.writeln('\nThe original request was:\n$request\n\nHere are those files AS THEY ARE NOW (your edits that worked are already in them):\n');
        for (final c in bad) {
          sb.writeln('=== FILE: ${c.path} ===\n${c.after}\n=== END OF ${c.path} ===\n');
        }
        sb.writeln('Send corrected SEARCH/REPLACE blocks for these files only, in the same format. Copy the SEARCH parts from the files as shown above.');
        try {
          r = await engine.openRouter(m.id, _system, sb.toString(), maxTokens: est.maxTokens, track: !m.free, onRetry: (n) {
            busy = '${m.name}: $n';
            notifyListeners();
          });
          cost += r.inTokens * m.promptPrice + r.outTokens * m.completionPrice;
          final fix = parsePatch(r.text);
          for (final e in fix.edits) {
            state[_resolve(e.path)]?.failures = [];
          }
          _apply(fix, state);
          if (sum.isEmpty) sum = fix.summary;
        } on ApiError catch (e) {
          debugPrint('heal failed: ${e.message}');
        }
      }
      final list = state.values.where((c) => c.changed).toList()..sort((a, b) => a.path.compareTo(b.path));
      if (list.isEmpty) throw ApiError('The model\'s changes could not be applied to the files (nothing matched). Try again or pick another model.');
      _busy('Building the new zip…');
      final id = DateTime.now().millisecondsSinceEpoch.toString();
      final out = '${(await _dir('builds')).path}/$id.zip';
      await Native.zipRebuild(zipPath, out, {for (final e in applied.entries) '$_root${e.key}': e.value, for (final c in list) '$_root${c.path}': c.after});
      summary = sum.isEmpty ? 'The model did not write a summary.' : sum;
      changes = list;
      usedModel = m.name;
      spent = m.free ? 0 : cost;
      unawaited(spend?.add(_fixPrompt.isNotEmpty ? 'fix' : 'change', sourceName, m.name, spent) ?? Future<void>.value());
      healed = didHeal;
      outZip = out;
      history = [
        BuildRecord(
          id: id,
          date: DateTime.now().millisecondsSinceEpoch,
          source: sourceName,
          request: request,
          summary: summary,
          model: m.name,
          files: [for (final c in list) c.path],
          zip: out,
          repo: repo,
          branch: branch,
          cost: spent,
          warnings: warnings,
        ),
        ...history,
      ];
      await _saveHistory();
      busy = '';
      notifyListeners();
    } catch (e) {
      _fail(e is ApiError ? e : ApiError('Something went wrong: ${_msg(e)}'), where: 'Writing the patch with ${m.name}', retry: () => patch(m), retryWith: patch, modelId: m.id, paid: m.free ? null : _paidJob(m, est));
    }
  }

  // ------------------------------------------------------------------ output
  /// "MyApp-aiy-1234.zip"
  String zipNameFor(String source, String id) {
    var base = source.replaceAll(RegExp(r'\.zip$', caseSensitive: false), '').replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-');
    if (base.length > 40) base = base.substring(0, 40);
    final tail = id.length > 4 ? id.substring(id.length - 4) : id;
    return '${base.isEmpty ? 'project' : base}-aiy-$tail.zip';
  }

  Future<String> saveToDownloads(String zip, String name) => Native.saveToDownloads(zip, name);

  /// An app the Build tab has just written becomes the open project, so Publish, Build and Code mode work on it.
  Future<void> adoptGenerated({required String zip, required String name, required Map<String, String> texts, required String summary, required String request, required String model, required double cost}) async {
    try {
      await _open(zip, name, '', '');
      this.request = request;
      this.summary = summary;
      usedModel = model;
      spent = cost;
      outZip = zip;
      healed = false;
      changes = [for (final k in (texts.keys.toList()..sort())) FileChange(k, null, texts[k]!)];
      history = [
        BuildRecord(id: DateTime.now().millisecondsSinceEpoch.toString(), date: DateTime.now().millisecondsSinceEpoch, source: name, request: request, summary: summary, model: model, files: [for (final c in changes) c.path], zip: zip, cost: cost),
        ...history.where((h) => h.zip != zip),
      ];
      await _saveHistory();
      busy = '';
      notifyListeners();
    } catch (e) {
      _fail(e is ApiError ? e : ApiError('Could not open the new app: ${_msg(e)}'));
    }
  }

  // ------------------------------------------------------------------ ask about the project (nothing is changed)
  /// Question, answer, who answered.
  final List<(String, String, String)> asks = [];
  bool asking = false;

  Future<void> askAbout(String q) async {
    if (!hasSource || asking || q.trim().isEmpty) return;
    asking = true;
    notifyListeners();
    try {
      final r1 = await engine.ask(
        'Project map (every source file, with its line count and its import lines):\n$projectMap\n\nQuestion from a non-programmer:\n$q\n\nWhich files must be READ to answer well? Return a JSON array of at most 4 paths from the map, or [] when the map is enough.',
        system: 'You decide which files to read to answer a question about a software project. You answer with a JSON array only.',
        json: true,
      );
      final paths = [for (final raw in parseFileList(r1.text)) _resolve(raw)].where((p) => cur(p) != null).toSet().take(4).toList();
      final sb = StringBuffer('Project: $sourceName\n\nProject map:\n${projectMap.length > 30000 ? projectMap.substring(0, 30000) : projectMap}\n\n');
      for (final p in paths) {
        final t = cur(p)!;
        sb.writeln('=== FILE: $p ===\n${t.length > 12000 ? '${t.substring(0, 12000)}\n…' : t}\n=== END ===\n');
      }
      sb.writeln('Question:\n$q\n\nAnswer clearly for someone who is not a programmer. Mention real file names. Use short Markdown. If the answer is not in what you were shown, say so instead of guessing.');
      askLive = '';
      final r2 = await engine.ask(sb.toString(), system: 'You explain software projects honestly and simply.', onText: (t) {
        askLive = t;
        _liveNotify();
      });
      asks.add((q.trim(), r2.text, '${r2.provider} · ${r2.model}'));
    } catch (e) {
      if (Offline.hold(e, title: 'Question: ${q.length > 30 ? '${q.substring(0, 30)}…' : q}', run: () async {
        if (asks.isNotEmpty && asks.last.$1 == q.trim() && asks.last.$3.isEmpty) asks.removeLast();
        await askAbout(q);
      })) {
        asks.add((q.trim(), 'No internet. AIy will answer when the connection is back.', ''));
      } else {
        asks.add((q.trim(), 'Could not answer: ${e is ApiError ? e.message : e}', ''));
        ErrorCenter.report(e, where: 'Asking about the project', retry: () => askAbout(q));
      }
    }
    askLive = '';
    asking = false;
    notifyListeners();
  }

  // ------------------------------------------------------------------ a photo of the problem
  String shotPath = '';
  String shotNote = '';
  bool shotBusy = false;

  /// A vision model describes the screenshot once; the description travels with the request to ANY model.
  Future<void> attachShot(String path) async {
    shotBusy = true;
    shotPath = path;
    shotNote = '';
    error = null;
    notifyListeners();
    try {
      final r = await engine.chat(
        [ChatMsg(role: 'user', text: 'This is a screenshot of a mobile app that has a problem. In under 150 words, describe exactly what you see and what looks wrong or unusual (cut-off or overlapping text, error messages, empty screens, wrong colours). Quote any visible text. Write it as a bug report for a developer.', imagePath: path)],
        search: false,
      );
      shotNote = r.text.trim();
    } catch (e) {
      if (Offline.hold(e, title: 'Reading the photo', run: () => attachShot(path))) {
        error = 'No internet. The photo will be read when the connection is back.';
      } else {
        shotPath = '';
        error = e is ApiError ? e.message : 'Could not read the photo: $e';
      }
    }
    shotBusy = false;
    notifyListeners();
  }

  void removeShot() {
    shotPath = shotNote = '';
    notifyListeners();
  }

  PaidJob _paidJob(OrModel m, CostEstimate est) => PaidJob(
        id: 'code',
        kind: 'code',
        title: 'Code: ${request.length > 60 ? '${request.substring(0, 60)}…' : request} ($sourceName)',
        modelId: m.id,
        modelName: m.name,
        cost: est.cost,
        worst: est.worstCase,
        data: {'zip': zipPath, 'name': sourceName, 'repo': repo, 'branch': branch, 'request': request, 'targets': targets, 'shot': shotNote, 'applied': applied},
      );

  /// Continues a paid patch that was waiting when AIy was closed (only after the person said yes, with the price shown).
  Future<void> resumePaid(PaidJob j) async {
    if (isBusy) return;
    await PaidJobs.instance.done(j.id);
    final d = j.data;
    try {
      final zip = '${d['zip'] ?? ''}';
      final repoFull = '${d['repo'] ?? ''}';
      final br = '${d['branch'] ?? ''}';
      if (zip.isNotEmpty && File(zip).existsSync()) {
        await _open(zip, '${d['name'] ?? ''}', repoFull, br);
      } else if (repoFull.isNotEmpty && keys.has('github')) {
        await loadGitHub(repoFull, br);
        if (!hasSource) return; // loadGitHub showed its own error
      } else {
        throw ApiError('The project of this job is no longer on the phone. Open it again in the Code tab and write the request again (nothing was charged).');
      }
      final ap = d['applied'];
      if (ap is Map) restoreApplied({for (final e in ap.entries) '${e.key}': '${e.value}'});
      request = '${d['request'] ?? ''}';
      shotNote = '${d['shot'] ?? ''}';
      targets = [for (final t in (d['targets'] as List? ?? const [])) '$t'].where(texts.containsKey).toList();
      if (targets.isEmpty) throw ApiError('The files of this job are not in the project any more. Write the request again.');
      _busy('Finding ${j.modelName}…');
      final models = await engine.orModels();
      final m = models.where((x) => x.id == j.modelId).firstOrNull;
      if (m == null) throw ApiError('The model ${j.modelName} is no longer offered by OpenRouter. Pick another model and tap "Write the change".');
      busy = '';
      await patch(m);
    } catch (e) {
      _fail(e is ApiError ? e : ApiError('Could not continue the job: ${_msg(e)}'));
    }
  }

  /// The person turned changed parts of a file on or off in the review. The file, its check, and the zip follow.
  Future<void> reviewChange(FileChange c, Set<int> rejected) async {
    if (isBusy) return;
    c.written ??= c.after;
    final full = c.written!;
    final d = diffLines(c.before ?? '', full);
    c.rejected = {...rejected};
    c.after = mergeHunks(d, c.rejected, crlf: full.contains('\r\n'));
    c.problem = validateChange(c.path, c.before, c.after);
    // A new list: anything already pushed is no longer the same change, so Publish offers to push again.
    changes = [...changes];
    notifyListeners();
    await _rebuildOut();
  }

  /// Writes the result zip again from the current (reviewed) changes.
  Future<void> _rebuildOut() async {
    if (outZip.isEmpty || zipPath.isEmpty) return;
    try {
      _busy('Updating the zip…');
      await Native.zipRebuild(zipPath, outZip, {for (final e in applied.entries) '$_root${e.key}': e.value, for (final c in changes.where((c) => c.changed)) '$_root${c.path}': c.after});
      busy = '';
      notifyListeners();
    } catch (e) {
      _fail(e is ApiError ? e : ApiError('The zip could not be updated: ${_msg(e)}'));
    }
  }

  void restoreApplied(Map<String, String> snapshot) {
    applied
      ..clear()
      ..addAll(snapshot);
    notifyListeners();
  }

  Future<void> reload() async {
    history = [];
    await _loadHistory();
  }

  /// After a push: the changes are now the project's current state, and GitHub is where it lives.
  void commitApplied(List<FileChange> done) {
    for (final c in done) {
      applied[c.path] = c.after;
    }
  }

  void setGitTarget(String repoFull, String br) {
    repo = repoFull;
    branch = br;
    notifyListeners();
  }

  /// Prepares a repair round after a failed build: picks the files the errors point to, then the person
  /// confirms the model and the cost as usual. Returns a message when it cannot.
  /// What the previous repair round tried, so the next one does not repeat it.
  static const _fixPrefix = 'Fix the build errors of: ';
  String _prevFix = '';

  String? startFix(List<Problem> problems, String log) {
    if (isBusy) return null;
    final all = <String, String>{...texts, ...applied};
    final wasFix = request.startsWith(_fixPrefix);
    if (wasFix && changes.isNotEmpty) {
      final sb = StringBuffer();
      for (final c in changes.take(6)) {
        final a = c.after;
        sb.writeln('- ${c.path}${c.before == null ? ' (new file)' : ''}: ${a.length > 1500 ? '${a.substring(0, 1500)}\n…' : a}');
      }
      _prevFix = '$_prevFix\nAttempt: these files were changed, but the build still FAILED with the errors above:\n$sb';
      if (_prevFix.length > 12000) _prevFix = _prevFix.substring(_prevFix.length - 12000);
    } else if (!wasFix) {
      _prevFix = '';
    }
    final files = pickFixFiles(problems: problems, files: all, changed: [for (final c in changes) c.path]);
    if (files.isEmpty) return 'AIy could not tell which files the errors come from. Describe the problem in the request box instead.';
    final orig = wasFix ? request.substring(_fixPrefix.length) : request;
    final sb = StringBuffer('Project: $sourceName\n\nThe change "$orig" was applied and pushed, but the build on GitHub FAILED.\n\nErrors found in the build log:\n');
    for (final p in problems.take(8)) {
      sb.writeln('- ${p.file.isEmpty ? '' : '${p.file}${p.line > 0 ? ':${p.line}' : ''}: '}${p.title}${p.detail.isEmpty ? '' : ' (${p.detail})'}');
    }
    final tail = log.split('\n').map((l) => l.replaceFirst(RegExp(r'^\S*\d{4}-\d\d-\d\dT[\d:.]+Z '), '')).where((l) => l.trim().isNotEmpty).toList();
    final lastLines = errorWindows(tail);
    sb.writeln('\nLast lines of the log:\n${lastLines.length > 4500 ? lastLines.substring(lastLines.length - 4500) : lastLines}\n');
    if (_prevFix.isNotEmpty) {
      sb.writeln('EARLIER FIX ATTEMPTS THAT DID NOT WORK (do not repeat them; find the real cause):$_prevFix');
    }
    sb.writeln('Rules: if a method, field or class is missing, look in the files below for where it should be defined. '
        'Either add it there, or call the name that really exists. Never invent a name that is not defined in these files. '
        'Fix every error listed, with the smallest possible change. These are the current files (the files the errors point at, '
        'the files that define the names in the errors, their imports, and nearby files):\n');
    for (final p in files) {
      sb.writeln('=== FILE: $p ===\n${cur(p)}\n=== END OF $p ===\n');
    }
    _fixPrompt = sb.toString();
    targets = files;
    request = '$_fixPrefix$orig';
    routeBadge = 'from the build log';
    changes = [];
    summary = outZip = usedModel = '';
    error = null;
    notifyListeners();
    return null;
  }

  // ------------------------------------------------------------------ history
  Future<void> _loadHistory() async {
    try {
      final f = File('${(await _dir()).path}/history.json');
      {
        final j = await Store.readJson(f);
        if (j is List) {
          history = [
            for (final b in j)
              if (b is Map) BuildRecord.fromJson(Map<String, dynamic>.from(b))
          ];
        }
      }
    } catch (e) {
      debugPrint('history load: $e');
    }
    notifyListeners();
  }

  Future<void> _saveHistory() async {
    try {
      // Keep the newest 20 builds; older zips are removed to save space.
      while (history.length > 20) {
        final old = history.removeLast();
        try {
          File(old.zip).deleteSync();
        } catch (_) {}
      }
      await Store.writeJson(File('${(await _dir()).path}/history.json'), [for (final b in history) b.toJson()]);
    } catch (e) {
      debugPrint('history save: $e');
    }
  }

  Future<void> deleteBuild(BuildRecord b) async {
    history = [...history]..remove(b);
    try {
      File(b.zip).deleteSync();
    } catch (_) {}
    notifyListeners();
    await _saveHistory();
  }
}
