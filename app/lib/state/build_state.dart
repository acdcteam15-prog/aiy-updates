import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;
import 'package:path_provider/path_provider.dart';

import '../logic/buildlog.dart';
import '../logic/project.dart';
import '../logic/versioning.dart';
import '../logic/workflows.dart';
import 'ai.dart' show OrModel;
import 'app_log.dart';
import 'code_state.dart';
import 'github.dart';
import 'keys.dart';
import 'native.dart';
import 'net.dart';
import 'prefs.dart';

/// An app built on GitHub and kept on the phone.
class ApkRecord {
  final String id;
  final String repo;
  final String branch;
  final String version;
  final int run;
  final int date;
  final String file;
  final String runUrl;
  final String releaseUrl;
  final int size;
  const ApkRecord({required this.id, required this.repo, required this.branch, required this.version, required this.run, required this.date, required this.file, this.runUrl = '', this.releaseUrl = '', this.size = 0});

  Map<String, dynamic> toJson() => {'id': id, 'repo': repo, 'branch': branch, 'version': version, 'run': run, 'date': date, 'file': file, 'runUrl': runUrl, 'releaseUrl': releaseUrl, 'size': size};
  factory ApkRecord.fromJson(Map<String, dynamic> j) => ApkRecord(
        id: '${j['id']}',
        repo: '${j['repo'] ?? ''}',
        branch: '${j['branch'] ?? ''}',
        version: '${j['version'] ?? ''}',
        run: (j['run'] as num?)?.toInt() ?? 0,
        date: (j['date'] as num?)?.toInt() ?? 0,
        file: '${j['file'] ?? ''}',
        runUrl: '${j['runUrl'] ?? ''}',
        releaseUrl: '${j['releaseUrl'] ?? ''}',
        size: (j['size'] as num?)?.toInt() ?? 0,
      );
}

/// Where the changes go.
class PushPlan {
  /// "owner/name" of an existing repository, or just the name of a new one.
  final String repo;
  final String base;
  final bool newBranch;

  /// Upload the whole project (new repositories), not only the changed files.
  final bool whole;
  final bool createRepo;
  final bool privateRepo;
  const PushPlan({required this.repo, required this.base, this.newBranch = false, this.whole = false, this.createRepo = false, this.privateRepo = true});
}

/// What was found out about the repository before the version question.
class BuildPrep {
  final VersionInfo? version;
  final ProjectKind kind;
  final String workflow;
  final bool addWorkflow;
  final Map<String, String?> files;
  const BuildPrep(this.version, this.kind, this.workflow, this.addWorkflow, this.files);
}

class _Up {
  final String path;
  final String? text;
  final String? entry;
  const _Up(this.path, this.text, this.entry);
}

Future<void> _parallel(int n, int workers, Future<void> Function(int i) task) async {
  var next = 0;
  Future<void> worker() async {
    while (true) {
      final i = next++;
      if (i >= n) return;
      await task(i);
    }
  }

  await Future.wait([for (var k = 0; k < workers && k < n; k++) worker()]);
}

/// Pushing the changes to GitHub and building the app there: commit, add the build workflow, write the
/// version, start the run, follow it, fetch the APK. A running build survives closing the app: it is picked up again.
class BuildState extends ChangeNotifier {
  final CodeState code;
  final KeyVault keys;
  final LocalPrefs prefs;
  BuildState(this.code, this.keys, this.prefs) {
    _loadApks().then((_) => _resume());
  }

  // ---- pushed
  String repo = '';
  String branch = '';
  String base = '';
  String prUrl = '';
  Object? _pushedFor;
  bool get pushed => _pushedFor != null && identical(_pushedFor, code.changes) && repo.isNotEmpty;

  // ---- build
  /// idle, pushing, preparing, queued, building, downloading, done, failed
  String phase = 'idle';
  String status = '';
  double progress = 0;
  List<StepInfo> steps = [];
  String runUrl = '';
  String version = '';
  String? error;
  File? apk;
  String releaseUrl = '';
  List<Problem> problems = [];
  String log = '';
  List<String> notes = [];
  List<ApkRecord> apks = [];

  bool get running => const {'pushing', 'preparing', 'queued', 'building', 'downloading', 'fixing'}.contains(phase);

  /// True for a "quick check" run (no APK is built).
  bool checkOnly = false;

  /// True while the automatic fix loop drives the steps itself.
  bool _loop = false;
  bool _stopLoop = false;
  ({String repo, String branch, String before, String after, Map<String, String> snap})? _undo;
  bool get canUndo => _undo != null && pushed && !running;
  bool get visible => phase != 'idle' || error != null;

  bool _cancel = false;
  int _runId = 0;
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  GitHubApi get _gh => GitHubApi(keys.get('github'));

  void _tick() {
    final n = DateTime.now();
    if (n.difference(_last).inMilliseconds > 150) {
      _last = n;
      notifyListeners();
    }
  }

  void _say(String s, {String? p}) {
    status = s;
    if (p != null) phase = p;
    notifyListeners();
  }

  void _fail(Object e, {bool build = false}) {
    error = e is ApiError ? e.message : 'Something went wrong: $e';
    AppLog.i('github: $error');
    phase = build ? 'failed' : 'idle';
    status = '';
    notifyListeners();
  }

  void clearError() {
    error = null;
    if (phase == 'failed' || phase == 'done') phase = 'idle';
    notifyListeners();
  }

  void dismiss() {
    if (running) return;
    phase = 'idle';
    error = null;
    status = '';
    notifyListeners();
  }

  // ------------------------------------------------------------------ push
  Future<String> _head(GitHubApi gh, String r, String b) async {
    for (var i = 0; i < 6; i++) {
      try {
        return await gh.branchSha(r, b);
      } on ApiError catch (e) {
        if (i == 5 || (e.status != 404 && e.status != 409)) rethrow; // a repository that was only just created needs a moment
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
    throw ApiError('Could not find the branch $b.');
  }

  String _title() {
    final t = code.request.split('\n').first.trim();
    return t.length > 60 ? '${t.substring(0, 60)}…' : t;
  }

  Future<void> push(PushPlan plan) async {
    if ((running && !_loop) || !code.hasResult) return;
    final changes = code.changes;
    try {
      error = null;
      progress = 0;
      _say('Connecting to GitHub…', p: 'pushing');
      final gh = _gh;
      var r = plan.repo, b = plan.base;
      if (plan.createRepo) {
        _say('Creating the repository…');
        final info = await gh.createRepo(plan.repo, plan.privateRepo);
        r = info.full;
        b = info.defaultBranch;
      }
      final head = await _head(gh, r, b);
      final baseTree = await gh.commitTree(r, head);
      final overrides = {...code.applied, for (final c in changes) c.path: c.after};
      final list = <_Up>[];
      if (plan.whole) {
        final root = code.zipRoot;
        for (final e in code.zipEntries) {
          final rel = e.name.startsWith(root) ? e.name.substring(root.length) : e.name;
          if (!shouldUpload(rel, e.size)) continue;
          list.add(_Up(rel, overrides[rel], e.name));
        }
        for (final o in overrides.entries) {
          if (!list.any((u) => u.path == o.key)) list.add(_Up(o.key, o.value, null));
        }
        if (list.length > 3000) throw ApiError('This project has ${list.length} files to upload. That is more than AIy can send in one go (3000). Zip a smaller part of it.');
      } else {
        for (final c in changes) {
          list.add(_Up(c.path, c.after, null));
        }
      }
      final shas = List<String?>.filled(list.length, null);
      var done = 0;
      await _parallel(list.length, 4, (i) async {
        final u = list[i];
        final bytes = u.text != null ? utf8.encode(u.text!) : await Native.zipBytes(code.zipPath, u.entry!);
        shas[i] = await gh.createBlob(r, bytes);
        done++;
        progress = done / list.length;
        status = 'Uploading files $done / ${list.length}';
        _tick();
      });
      _say('Saving on GitHub…');
      final tree = await gh.createTree(r, baseTree, [for (var i = 0; i < list.length; i++) (list[i].path, isExecutable(list[i].path) ? '100755' : '100644', shas[i]!)]);
      var target = b;
      final ts = DateTime.now();
      String newBranch() => 'aiy/${ts.year}${ts.month.toString().padLeft(2, '0')}${ts.day.toString().padLeft(2, '0')}-${ts.hour.toString().padLeft(2, '0')}${ts.minute.toString().padLeft(2, '0')}${ts.second.toString().padLeft(2, '0')}';
      var nothing = false;
      ({String before, String after})? mark;
      if (tree != baseTree) {
        final msg = 'AIy: ${_title()}\n\n${code.summary}';
        final commit = await gh.createCommit(r, msg, tree, head);
        if (plan.newBranch) {
          target = newBranch();
          await gh.createBranch(r, target, commit);
        } else {
          await gh.updateRef(r, b, commit);
          mark = (before: head, after: commit);
        }
      } else {
        nothing = true;
        if (plan.newBranch) {
          target = newBranch();
          await gh.createBranch(r, target, head);
        }
      }
      repo = r;
      branch = target;
      base = b;
      prUrl = '';
      _pushedFor = changes;
      final snap = Map<String, String>.of(code.applied);
      code.commitApplied(changes);
      _undo = mark == null ? null : (repo: r, branch: target, before: mark.before, after: mark.after, snap: snap);
      code.setGitTarget(r, target);
      phase = 'idle';
      status = nothing ? 'GitHub already had exactly these files.' : 'Pushed to $r ($target).';
      notifyListeners();
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> openPullRequest() async {
    if (running || !pushed || branch == base) return;
    try {
      error = null;
      _say('Opening the pull request…', p: 'pushing');
      prUrl = await _gh.openPullRequest(repo, base, branch, 'AIy: ${_title()}', '${code.summary}\n\n---\nRequest: ${code.request}\nModel: ${code.usedModel}\nMade with AIy.');
      phase = 'idle';
      status = '';
      notifyListeners();
    } catch (e) {
      _fail(e);
    }
  }

  // ------------------------------------------------------------------ build
  static const _probe = [...VersionInfo.files, 'settings.gradle.kts', 'settings.gradle', 'gradlew', '.github/workflows/$kWorkflowName', '.github/workflows/build.yml', '.github/workflows/build.yaml'];

  /// Looks at the repository (which kind of project, which workflow, which version) before the version question.
  Future<BuildPrep?> prepare() async {
    if ((running && !_loop) || repo.isEmpty) return null;
    try {
      error = null;
      _say('Checking the project on GitHub…', p: 'preparing');
      final gh = _gh;
      final t = <String, String?>{};
      await _parallel(_probe.length, 4, (i) async => t[_probe[i]] = await gh.fileText(repo, _probe[i], branch));
      final kind = detectKind((p) => t[p] != null, (p) => t[p]);
      var workflow = '';
      for (final n in const [kWorkflowName, 'build.yml', 'build.yaml']) {
        final x = t['.github/workflows/$n'];
        if (x != null && x.contains('workflow_dispatch')) {
          workflow = n;
          break;
        }
      }
      var add = false;
      if (workflow.isEmpty) {
        if (kind == ProjectKind.unknown) {
          throw ApiError('AIy can build Android (Gradle) and Flutter projects. This repository is neither, and it has no workflow that can be started by hand.');
        }
        workflow = kWorkflowName;
        add = true;
      }
      phase = 'idle';
      status = '';
      notifyListeners();
      return BuildPrep(detectVersion((p) => t[p]), kind, workflow, add, t);
    } catch (e) {
      _fail(e);
      return null;
    }
  }

  void _resetBuild() {
    steps = [];
    problems = [];
    log = '';
    notes = [];
    checkOnly = false;
    apk = null;
    releaseUrl = '';
    runUrl = '';
    error = null;
    progress = 0;
    _runId = 0;
    _cancel = false;
  }

  Future<void> start(BuildPrep prep, {required String versionName, required String releaseNotes, required bool release}) async {
    if (running && !_loop) return;
    _resetBuild();
    version = versionName;
    unawaited(_askNotify());
    try {
      _say('Preparing the build…', p: 'preparing');
      final gh = _gh;
      final r = repo, b = branch;
      var head = await _head(gh, r, b);
      final baseTree = await gh.commitTree(r, head);
      final adds = <(String, List<int>)>[];
      if (prep.addWorkflow) adds.add(('.github/workflows/$kWorkflowName', utf8.encode(workflowFor(prep.kind)!)));
      final v = prep.version;
      if (v == null) {
        notes.add('No version number was found in the project, so the version is only used in the file name.');
      } else {
        final text = prep.files[v.path] ?? '';
        int? codeN;
        if ((v.kind == VersionKind.gradle || v.kind == VersionKind.pubspec) && v.code != null) {
          codeN = nextCode(v.code, prefs.lastCode(r));
          await prefs.setLastCode(r, codeN);
        }
        final updated = applyVersion(v, text, versionName, code: codeN);
        if (updated != text) {
          adds.add((v.path, utf8.encode(updated)));
          notes.add('Version ${v.name} -> $versionName${codeN == null ? '' : ' (build number $codeN)'}');
        }
      }
      if (adds.isNotEmpty) {
        _say('Writing version $versionName into the project…');
        final entries = <(String, String, String)>[];
        for (final a in adds) {
          entries.add((a.$1, '100644', await gh.createBlob(r, a.$2)));
        }
        final tree = await gh.createTree(r, baseTree, entries);
        head = await gh.createCommit(r, 'AIy: version $versionName${prep.addWorkflow ? ' and build workflow' : ''}', tree, head);
        await gh.updateRef(r, b, head);
      }
      if (_cancel) return;
      _say('Starting the build…', p: 'queued');
      var before = 0;
      for (final x in await gh.runs(r, prep.workflow, b)) {
        if (x.id > before) before = x.id;
      }
      for (var attempt = 0; attempt < 8; attempt++) {
        try {
          await gh.dispatch(r, prep.workflow, b);
          break;
        } on ApiError catch (e) {
          // Right after a commit GitHub needs a moment before it knows the workflow.
          if (attempt == 7 || (e.status != 404 && e.status != 422 && e.status != 409)) rethrow;
          await Future<void>.delayed(const Duration(seconds: 5));
        }
      }
      RunInfo? run;
      for (var i = 0; i < 40 && run == null; i++) {
        await Future<void>.delayed(const Duration(seconds: 3));
        if (_cancel) return;
        for (final x in await gh.runs(r, prep.workflow, b)) {
          if (x.id > before) {
            run = x;
            break;
          }
        }
      }
      if (run == null) throw ApiError('The build was started, but AIy could not find it. Open the Actions page of $r on GitHub.');
      await prefs.setActiveBuild(jsonEncode({'repo': r, 'branch': b, 'run': run.id, 'version': versionName, 'notes': releaseNotes, 'release': release, 'check': false}));
      await _watch(gh, r, b, run.id, versionName, releaseNotes, release);
    } catch (e) {
      await prefs.setActiveBuild('');
      _fail(e, build: true);
    }
  }

  Future<void> _resume() async {
    final raw = prefs.activeBuild;
    if (raw.isEmpty || !keys.has('github')) return;
    try {
      final j = jsonDecode(raw) as Map;
      _resetBuild();
      repo = '${j['repo']}';
      branch = '${j['branch']}';
      version = '${j['version']}';
      checkOnly = j['check'] == true;
      _say('Picking the build up again…', p: 'building');
      await _watch(_gh, repo, branch, (j['run'] as num).toInt(), version, '${j['notes'] ?? ''}', j['release'] == true);
    } catch (e) {
      await prefs.setActiveBuild('');
      _fail(e, build: true);
    }
  }

  Future<void> _watch(GitHubApi gh, String r, String b, int runId, String ver, String relNotes, bool release) async {
    _runId = runId;
    phase = 'building';
    var run = await gh.run(r, runId);
    runUrl = run.url;
    final deadline = DateTime.now().add(const Duration(minutes: 70));
    var errors = 0;
    while (true) {
      if (_cancel) return;
      try {
        run = await gh.run(r, runId);
        final (st, cur) = await gh.steps(r, runId);
        steps = st;
        progress = st.isEmpty ? 0 : st.where((s) => s.state == 'done').length / st.length;
        status = '${checkOnly ? 'Checking' : 'Building'} on GitHub (run ${run.number}): $cur';
        errors = 0;
        notifyListeners();
        if (run.done) break;
      } on ApiError catch (e) {
        if (e.status != -1 || ++errors > 25) rethrow;
        status = 'Waiting for the connection…';
        notifyListeners();
      }
      if (DateTime.now().isAfter(deadline)) throw ApiError('The build has been running for more than an hour. Open the run on GitHub to see what is happening.');
      await Future<void>.delayed(const Duration(seconds: 8));
    }
    await prefs.setActiveBuild('');
    if (run.conclusion == 'cancelled') {
      phase = 'idle';
      status = 'The build was cancelled.';
      notifyListeners();
      return;
    }
    if (run.conclusion != 'success') {
      status = 'The build failed.';
      final text = await gh.failedLog(r, runId);
      final lines = text.split('\n');
      problems = parseProblems(lines);
      log = lines.length > 120 ? lines.sublist(lines.length - 120).join('\n') : text;
      phase = 'failed';
      notifyListeners();
      _notify('AIy', checkOnly ? 'The check found errors.' : 'The build failed.');
      return;
    }
    if (checkOnly) {
      phase = 'done';
      status = 'No errors found: the code compiles.';
      notifyListeners();
      _notify('AIy', 'The check passed: no errors found.');
      return;
    }
    phase = 'downloading';
    _say('Downloading the app…');
    final arts = await gh.artifacts(r, runId);
    if (arts.isEmpty) throw ApiError('The build succeeded, but it produced no download.');
    final art = arts.firstWhere((a) => a.$2.toLowerCase().contains('apk'), orElse: () => arts.first);
    final tmp = Directory('${(await getTemporaryDirectory()).path}/cloud')..createSync(recursive: true);
    final zipF = File('${tmp.path}/artifact.zip');
    await gh.downloadArtifact(r, art.$1, zipF);
    final extracted = await Native.zipExtractFirst(zipF.path, '.apk', tmp.path);
    zipF.deleteSync();
    if (extracted == null) throw ApiError('The build finished, but its download has no APK in it.');
    final app = r.split('/').last.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final name = '$app-${ver.replaceAll('.', '_')}-build${run.number}.apk';
    final dir = Directory('${(await getApplicationDocumentsDirectory()).path}/aiy/apks')..createSync(recursive: true);
    final dest = File('${dir.path}/$name');
    await File(extracted).copy(dest.path);
    File(extracted).deleteSync();
    var relUrl = '';
    if (release) {
      _say('Publishing a GitHub Release…');
      try {
        var tag = 'v$ver-build${run.number}';
        final title = '$app $ver';
        final body = relNotes.trim().isEmpty ? 'Built with AIy.' : relNotes.trim();
        ({int id, String url}) rel;
        try {
          rel = await gh.createRelease(r, tag, title, body, b);
        } on ApiError catch (e) {
          if (e.status != 422) rethrow;
          tag = '$tag-${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
          rel = await gh.createRelease(r, tag, title, body, b);
        }
        await gh.uploadAsset(r, rel.id, dest, name);
        relUrl = rel.url;
        notes.add('Release published');
      } catch (e) {
        notes.add('The release was not published: ${e is ApiError ? e.message : e}');
      }
    }
    final rec = ApkRecord(id: '${DateTime.now().millisecondsSinceEpoch}', repo: r, branch: b, version: ver, run: run.number, date: DateTime.now().millisecondsSinceEpoch, file: dest.path, runUrl: run.url, releaseUrl: relUrl, size: dest.lengthSync());
    apks = [rec, ...apks];
    // The newest three of each repository stay on the phone.
    final mine = apks.where((a) => a.repo == r).toList();
    for (final old in mine.skip(3)) {
      try {
        File(old.file).deleteSync();
      } catch (_) {}
      apks.remove(old);
    }
    await _saveApks();
    apk = dest;
    releaseUrl = relUrl;
    phase = 'done';
    status = 'Your app is ready: $name';
    notifyListeners();
    _notify('AIy', 'Version $ver is ready to install.');
  }

  // ------------------------------------------------------------------ quick check, automatic repair, undo
  /// Compiles / analyzes the code on GitHub without building the APK (1-2 minutes instead of 5).
  Future<void> check() async {
    if ((running && !_loop) || repo.isEmpty) return;
    try {
      _resetBuild();
      checkOnly = true;
      version = '';
      _say('Preparing the quick check…', p: 'preparing');
      final gh = _gh;
      final r = repo, b = branch;
      const probe = ['pubspec.yaml', 'settings.gradle.kts', 'settings.gradle', 'gradlew', 'app/build.gradle.kts', 'app/build.gradle', '.github/workflows/$kCheckWorkflowName'];
      final t = <String, String?>{};
      await _parallel(probe.length, 4, (i) async => t[probe[i]] = await gh.fileText(r, probe[i], b));
      final yaml = checkWorkflowFor(detectKind((p) => t[p] != null, (p) => t[p]));
      final has = (t['.github/workflows/$kCheckWorkflowName'] ?? '').contains('workflow_dispatch');
      if (yaml == null && !has) throw ApiError('AIy can check Android (Gradle) and Flutter projects. This repository is neither.');
      var head = await _head(gh, r, b);
      if (!has) {
        _say('Adding the check workflow…');
        final baseTree = await gh.commitTree(r, head);
        final blob = await gh.createBlob(r, utf8.encode(yaml!));
        final tree = await gh.createTree(r, baseTree, [('.github/workflows/$kCheckWorkflowName', '100644', blob)]);
        head = await gh.createCommit(r, 'AIy: quick check workflow', tree, head);
        await gh.updateRef(r, b, head);
      }
      if (_cancel) return;
      _say('Starting the check…', p: 'queued');
      var before = 0;
      for (final x in await gh.runs(r, kCheckWorkflowName, b)) {
        if (x.id > before) before = x.id;
      }
      for (var attempt = 0; attempt < 8; attempt++) {
        try {
          await gh.dispatch(r, kCheckWorkflowName, b);
          break;
        } on ApiError catch (e) {
          if (attempt == 7 || (e.status != 404 && e.status != 422 && e.status != 409)) rethrow;
          await Future<void>.delayed(const Duration(seconds: 5));
        }
      }
      RunInfo? run;
      for (var i = 0; i < 40 && run == null; i++) {
        await Future<void>.delayed(const Duration(seconds: 3));
        if (_cancel) return;
        for (final x in await gh.runs(r, kCheckWorkflowName, b)) {
          if (x.id > before) {
            run = x;
            break;
          }
        }
      }
      if (run == null) throw ApiError('The check was started, but AIy could not find it. Open the Actions page of $r on GitHub.');
      await prefs.setActiveBuild(jsonEncode({'repo': r, 'branch': b, 'run': run.id, 'version': '', 'notes': '', 'release': false, 'check': true}));
      await _watch(gh, r, b, run.id, '', '', false);
    } catch (e) {
      await prefs.setActiveBuild('');
      _fail(e, build: true);
    }
  }

  /// After a failed build or check: the model writes a fix, AIy pushes it and checks it on GitHub (quick, no APK),
  /// and repeats up to [rounds] times. When the check passes, the real build starts again. Every fix is limited by the spending limit.
  Future<void> autoFix(OrModel m, int rounds) async {
    if (phase != 'failed' || _loop) return;
    _loop = true;
    _stopLoop = false;
    final ver = version;
    var last = '';
    var same = 0;
    var ok = false;
    try {
      for (var i = 1; i <= rounds; i++) {
        if (_stopLoop) break;
        final key = problems.isEmpty ? 'log' : problems.first.title;
        if (key == last && ++same >= 2) {
          error = 'The same error came back twice, so AIy stopped to save money. Read it below, or try a different model.';
          break;
        }
        last = key;
        _say('Fix $i of $rounds: ${m.name} is writing a fix…', p: 'fixing');
        final msg = code.startFix(problems, log);
        if (msg != null) {
          error = msg;
          break;
        }
        await code.patch(m);
        if (_stopLoop) break;
        if (code.error != null) {
          error = code.error;
          code.clearError();
          break;
        }
        if (!code.hasResult) {
          error = 'The model did not give a usable fix.';
          break;
        }
        _say('Fix $i of $rounds: pushing it…', p: 'fixing');
        await push(PushPlan(repo: repo, base: branch));
        if (_stopLoop || error != null || !pushed) break;
        await check();
        if (_stopLoop) break;
        if (phase == 'done') {
          ok = true;
          break;
        }
        if (phase != 'failed') break;
      }
      if (ok && !_stopLoop) {
        final prep = await prepare();
        if (prep != null) {
          await start(prep, versionName: ver.isEmpty ? (prep.version?.name ?? '1.0.0') : ver, releaseNotes: 'Fixed by AIy', release: false);
        }
      } else if (phase == 'fixing' || phase == 'idle') {
        phase = 'failed';
      }
    } catch (e) {
      _fail(e, build: true);
    } finally {
      _loop = false;
      notifyListeners();
    }
  }

  /// Puts the branch back to how it was before AIy's last push. Only while nobody has pushed since (a build adds a commit).
  Future<void> undoPush() async {
    final u = _undo;
    if (u == null || running) return;
    try {
      error = null;
      _say('Undoing the push…', p: 'pushing');
      final gh = _gh;
      final now = await gh.branchSha(u.repo, u.branch);
      if (now != u.after) {
        throw ApiError('The branch has new commits since AIy pushed (a build adds one), so AIy will not undo it for you. Undo it on GitHub: open the repository, Commits, and revert the commit.');
      }
      await gh.updateRef(u.repo, u.branch, u.before, force: true);
      code.restoreApplied(u.snap);
      _pushedFor = null;
      _undo = null;
      phase = 'idle';
      status = 'The push was undone: ${u.repo} (${u.branch}) is as it was.';
      notifyListeners();
    } catch (e) {
      _fail(e);
    }
  }

  void _notify(String title, String text) {
    try {
      final s = WidgetsBinding.instance.lifecycleState;
      if (s != null && s != AppLifecycleState.resumed) unawaited(Native.notify(title, text));
    } catch (_) {}
  }

  Future<void> _askNotify() async {
    if (prefs.askedNotifications) return;
    await prefs.setAskedNotifications(true);
    await Native.requestNotifications();
  }

  Future<void> cancel() async {
    if (!running) return;
    _cancel = true;
    _stopLoop = true;
    final id = _runId;
    if (id != 0 && repo.isNotEmpty) await _gh.cancelRun(repo, id);
    await prefs.setActiveBuild('');
    phase = 'idle';
    status = 'The build was cancelled.';
    notifyListeners();
  }

  // ------------------------------------------------------------------ the apps on the phone
  Future<File> _file() async {
    final d = Directory('${(await getApplicationDocumentsDirectory()).path}/aiy')..createSync(recursive: true);
    return File('${d.path}/apks.json');
  }

  Future<void> _loadApks() async {
    try {
      final f = await _file();
      if (f.existsSync()) {
        final j = jsonDecode(await f.readAsString());
        if (j is List) {
          apks = [
            for (final a in j)
              if (a is Map) ApkRecord.fromJson(Map<String, dynamic>.from(a))
          ].where((a) => File(a.file).existsSync()).toList();
        }
      }
    } catch (e) {
      debugPrint('apks load: $e');
    }
    notifyListeners();
  }

  Future<void> _saveApks() async {
    try {
      await (await _file()).writeAsString(jsonEncode([for (final a in apks) a.toJson()]));
    } catch (e) {
      debugPrint('apks save: $e');
    }
  }

  Future<void> deleteApk(ApkRecord a) async {
    try {
      File(a.file).deleteSync();
    } catch (_) {}
    apks = [...apks]..remove(a);
    notifyListeners();
    await _saveApks();
  }

  /// Opens the Android installer for an APK. Returns a message when it cannot.
  Future<String?> install(String apkPath) async {
    if (!await Native.canInstallApks()) {
      await Native.openInstallSettings();
      return 'Android needs your permission once: switch on "Allow from this source" for AIy, come back and tap Install again.';
    }
    try {
      final dir = Directory('${(await getTemporaryDirectory()).path}/updates')..createSync(recursive: true);
      final copy = File('${dir.path}/${apkPath.split('/').last}');
      await File(apkPath).copy(copy.path);
      await Native.installApk(copy.path);
      return null;
    } catch (e) {
      return 'Could not open the installer: $e';
    }
  }

  Future<String> saveApk(String apkPath) => Native.saveToDownloads(apkPath, apkPath.split('/').last);
}
