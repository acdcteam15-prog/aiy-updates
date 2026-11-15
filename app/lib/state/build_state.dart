import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;
import 'package:path_provider/path_provider.dart';

import '../logic/fixcontext.dart';
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
import 'store.dart';
import 'connectivity.dart';

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

  /// The project's own workflow with its Android SDK setup step allowed to fail (null when nothing to change).
  final String? relaxed;

  /// The person agreed to write [relaxed] into the project.
  bool fixSetup = false;
  BuildPrep(this.version, this.kind, this.workflow, this.addWorkflow, this.files, {this.relaxed});
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

  /// When each phase of the current build started (ms since epoch), for the step times on screen.
  final Map<String, int> phaseAt = {};

  /// The phase the last build or check was in when it failed ('' when none).
  String failedPhase = '';
  String _seenPhase = '';

  @override
  void notifyListeners() {
    if (phase != _seenPhase) {
      if (phase == 'failed') failedPhase = _seenPhase;
      if (phase != 'failed' && phase != 'idle') phaseAt.putIfAbsent(phase, () => DateTime.now().millisecondsSinceEpoch);
      _seenPhase = phase;
    }
    super.notifyListeners();
  }

  void _say(String s, {String? p}) {
    status = s;
    if (p != null) phase = p;
    notifyListeners();
  }

  /// The GitHub step that failed when it is one of the build's SETUP steps (Java, Android SDK, Gradle, Flutter,
  /// checkout) - not the project's code. '' otherwise. Fixing the code with AI cannot help then.
  String get setupStepFailed {
    for (var i = 0; i < steps.length; i++) {
      final s = steps[i];
      if (s.state != 'failed') continue;
      // Only when the run really stopped there (a setup step allowed to fail, with later steps run, does not count).
      if (steps.skip(i + 1).any((x) => x.state == 'done' || x.state == 'failed' || x.state == 'running')) continue;
      final n = s.name.toLowerCase();
      if (n.startsWith('run ') && n.contains('@') && !n.contains('compile') && !n.contains('build the')) return s.name;
      if (n.startsWith('set up ') || n == 'use one fixed signing key') return s.name;
    }
    return '';
  }

  /// A build failure caused by the build's own setup or a plugin's requirements (not the project's code). '' otherwise.
  String get environmentProblem {
    if (phase != 'failed') return '';
    return environmentFailure('${problems.map((p) => '${p.title} ${p.detail}').join('\n')}\n$log');
  }

  /// Anything that makes "Fix it with AI" pointless: a failed setup step or an environment problem.
  bool get aiCannotFix => setupStepFailed.isNotEmpty || environmentProblem.isNotEmpty;

  /// True when the last failure was only the internet connection.
  bool lastWasConnection = false;

  void _fail(Object e, {bool build = false}) {
    lastWasConnection = e is ApiError && e.isConnection;
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
      // The previous run's steps are not this push's: clear them so "Details" does not show an old failure.
      steps = [];
      failedPhase = '';
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
      _say(list.length > 200 ? 'Saving ${list.length} files on GitHub… (big projects can take a minute or two)' : 'Saving on GitHub…');
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
    if (running && !_loop) {
      error = 'A build or quick check is still running. Wait for it, or cancel it in Settings > Running and waiting.';
      notifyListeners();
      return null;
    }
    if (repo.isEmpty) {
      error = 'Push the change to GitHub first, then build.';
      notifyListeners();
      return null;
    }
    try {
      error = null;
      _say('Checking the project on GitHub…', p: 'preparing');
      final gh = _gh;
      final t = <String, String?>{};
      await _parallel(_probe.length, 4, (i) async => t[_probe[i]] = await gh.fileText(repo, _probe[i], branch));
      final kind = detectKind((p) => t[p] != null, (p) => t[p]);
      var workflow = '';
      var add = false;
      final own = t['.github/workflows/$kWorkflowName'];
      if (own != null && kind != ProjectKind.unknown && (!isAiyWorkflow(own) || !isCurrentAiyWorkflow(own))) {
        // AIy's workflow from an older version (no push trigger): replace it so the build also starts on branches.
        if (isAiyWorkflow(own)) {
          workflow = kWorkflowName;
          add = true;
        }
      }
      if (workflow.isEmpty) {
        for (final n in const [kWorkflowName, 'build.yml', 'build.yaml']) {
          final x = t['.github/workflows/$n'];
          if (x != null && x.contains('workflow_dispatch')) {
            workflow = n;
            break;
          }
        }
      }
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
      final ownYaml = workflow != kWorkflowName && !add ? t['.github/workflows/$workflow'] : null;
      return BuildPrep(detectVersion((p) => t[p]), kind, workflow, add, t, relaxed: ownYaml == null ? null : relaxSetupAndroid(ownYaml));
    } catch (e) {
      _fail(e);
      return null;
    }
  }

  void _resetBuild() {
    phaseAt.clear();
    failedPhase = '';
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

  String _lastNotes = '';
  bool _lastRelease = false;

  /// After a build stopped in a setup step (not the code): AIy updates its workflow and builds again with the same
  /// version, notes and release choice. Nothing is spent on a model.
  Future<void> rebuildAfterSetup() async {
    if (running || repo.isEmpty) return;
    final ver = version;
    final prep = await prepare();
    if (prep == null) return;
    AppLog.i('build: rebuilding after a setup failure (${setupStepFailed.isEmpty ? (environmentProblem.isEmpty ? 'setup step' : environmentProblem) : setupStepFailed})');
    await start(prep, versionName: ver.isEmpty ? (prep.version?.name ?? '1.0.0') : ver, releaseNotes: _lastNotes, release: _lastRelease);
  }

  Future<void> start(BuildPrep prep, {required String versionName, required String releaseNotes, required bool release}) async {
    if (running && !_loop) return;
    _lastNotes = releaseNotes;
    _lastRelease = release;
    _resetBuild();
    version = versionName;
    unawaited(_askNotify());
    try {
      _say('Preparing the build…', p: 'preparing');
      final gh = _gh;
      final r = repo, b = branch;
      final adds = <(String, List<int>)>[];
      if (prep.addWorkflow) adds.add(('.github/workflows/$kWorkflowName', utf8.encode(workflowFor(prep.kind)!)));
      if (prep.fixSetup && prep.relaxed != null) {
        adds.add(('.github/workflows/${prep.workflow}', utf8.encode(prep.relaxed!)));
        notes.add('${prep.workflow}: the Android SDK setup step may no longer stop the build');
      }
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
      final own = prep.workflow == kWorkflowName;
      if (adds.isNotEmpty) _say('Writing version $versionName into the project…');
      final run = await _launch(gh, r, b,
          workflow: prep.workflow,
          trigger: kBuildTrigger,
          own: own,
          adds: adds,
          message: 'AIy: build version $versionName${prep.addWorkflow ? ' (and the build workflow)' : ''}',
          what: 'build');
      if (run == null) return; // cancelled
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
      final current = t['.github/workflows/$kCheckWorkflowName'];
      final has = (current ?? '').contains('workflow_dispatch');
      if (yaml == null && !has) throw ApiError('AIy can check Android (Gradle) and Flutter projects. This repository is neither.');
      // Add it when missing; replace AIy's older version (no push trigger) so it also starts on branches.
      final write = yaml != null && (!has || (isAiyWorkflow(current) && !isCurrentAiyWorkflow(current)));
      final own = yaml != null && (write || isCurrentAiyWorkflow(current));
      if (write) _say('Adding the check workflow…');
      final run = await _launch(gh, r, b,
          workflow: kCheckWorkflowName,
          trigger: kCheckTrigger,
          own: own,
          adds: [if (write) ('.github/workflows/$kCheckWorkflowName', utf8.encode(yaml))],
          message: 'AIy: quick check',
          what: 'check');
      if (run == null) return;
      await prefs.setActiveBuild(jsonEncode({'repo': r, 'branch': b, 'run': run.id, 'version': '', 'notes': '', 'release': false, 'check': true}));
      await _watch(gh, r, b, run.id, '', '', false);
    } catch (e) {
      await prefs.setActiveBuild('');
      _fail(e, build: true);
    }
  }

  /// Commits [adds] on the branch and returns the run GitHub started for it (null when cancelled).
  ///
  /// AIy's own workflows ([own]) are started by the commit itself: the commit also changes [trigger], and the
  /// workflow runs on a push that touches it, on ANY branch. Hand-starting ("workflow_dispatch") only works when
  /// the workflow is on the default branch, so it is used for other workflows, and for AIy's as a second try.
  Future<RunInfo?> _launch(GitHubApi gh, String r, String b,
      {required String workflow, required String trigger, required bool own, required List<(String, List<int>)> adds, required String message, required String what}) async {
    var head = await _head(gh, r, b);
    var before = 0;
    try {
      for (final x in await gh.runs(r, workflow, b, event: '')) {
        if (x.id > before) before = x.id;
      }
    } on ApiError catch (e) {
      if (e.status != 404) rethrow; // a workflow GitHub does not know yet
    }
    final all = [...adds, if (own) (trigger, utf8.encode('AIy $what request ${DateTime.now().toUtc().toIso8601String()}\n'))];
    if (all.isNotEmpty) {
      final baseTree = await gh.commitTree(r, head);
      final entries = <(String, String, String)>[];
      for (final a in all) {
        entries.add((a.$1, '100644', await gh.createBlob(r, a.$2)));
      }
      final tree = await gh.createTree(r, baseTree, entries);
      head = await gh.createCommit(r, message, tree, head);
      try {
        await gh.updateRef(r, b, head);
      } on ApiError catch (e) {
        if (e.status == 404 || e.status == 403) {
          throw ApiError('GitHub did not let AIy change the workflow files (${e.status}). The GitHub sign-in needs the "workflow" permission: Settings > Accounts & keys, disconnect GitHub and connect it again.', e.status);
        }
        if (e.status == 422 && e.message.toLowerCase().contains('protected')) {
          throw ApiError('The branch $b is protected, so AIy cannot add its commit. Push to a new branch instead (Publish > Push somewhere else).', e.status);
        }
        rethrow;
      }
    }
    if (_cancel) return null;
    _say('Waiting for GitHub to start the $what…', p: 'queued');
    var dispatched = false;
    String? lastDispatchError;
    final until = DateTime.now().add(const Duration(minutes: 4));
    for (var i = 0; DateTime.now().isBefore(until); i++) {
      if (_cancel) return null;
      if (own) {
        final l = await gh.runsForCommit(r, workflow, head);
        if (l.isNotEmpty) return l.first;
        // any newer run on the branch (push or hand-started) also counts
        try {
          for (final x in await gh.runs(r, workflow, b, event: '')) {
            if (x.id > before) return x;
          }
        } on ApiError catch (e) {
          if (e.status != 404) rethrow;
        }
      }
      // Other workflows: start by hand at once. AIy's own: only if the push did not start it within ~60 s.
      if (!dispatched && (!own || i >= 20)) {
        try {
          await gh.dispatch(r, workflow, b);
          dispatched = true;
        } on ApiError catch (e) {
          lastDispatchError = e.message;
          if (e.status != 404 && e.status != 422 && e.status != 409) rethrow;
          if (own) dispatched = true; // the default branch does not have it: the push trigger is the way, keep waiting
        }
      }
      if (dispatched) {
        try {
          for (final x in await gh.runs(r, workflow, b)) {
            if (x.id > before) return x;
          }
        } on ApiError catch (e) {
          if (e.status != 404) rethrow;
        }
      }
      if (i > 0 && i % 10 == 0) _say('Waiting for GitHub to start the $what… (${i * 3} s, GitHub can be slow)');
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    final on = await gh.actionsEnabled(r);
    if (on == false) {
      throw ApiError('GitHub Actions is switched off for $r, so nothing can be built there. On GitHub: the repository > Settings > Actions > General > "Allow all actions", then try again.');
    }
    throw ApiError('GitHub did not start the $what within 4 minutes${lastDispatchError == null ? '' : ' (last answer: $lastDispatchError)'}. '
        'Open the Actions page of $r on GitHub: if a run is there, AIy will find it when you tap ${what == 'build' ? 'Build' : 'Quick check'} again; '
        'if GitHub asks to enable workflows for this repository, enable them first.');
  }

  /// After a failed build or check: the model writes a fix, AIy pushes it and checks it on GitHub (quick, no APK),
  /// and repeats up to [rounds] times. When the check passes, the real build starts again. Every fix is limited by the spending limit.
  /// The auto-fix loop stopped because the internet went away. [Continue] starts it again from where it stopped:
  /// [fixReady] = the fix was already written (and paid for), so only the push and the check are repeated.
  ({OrModel model, int rounds, bool fixReady})? paused;

  void _pause(OrModel m, int left, bool fixReady) {
    paused = (model: m, rounds: left, fixReady: fixReady);
    error = fixReady
        ? 'Auto-fix paused: the internet went away after the fix was written. The fix is kept. Tap Continue when you are back online (it pushes and checks it; the fix is not paid for again).'
        : 'Auto-fix paused: the internet went away before the fix was written (nothing was charged for it). Tap Continue when you are back online.';
    AppLog.i('auto-fix paused (fixReady=$fixReady, rounds left $left)');
  }

  /// Continues a paused auto-fix loop (the person tapped Continue).
  Future<void> continueFix() async {
    final p = paused;
    if (p == null || _loop) return;
    paused = null;
    error = null;
    phase = 'failed';
    await autoFix(p.model, p.rounds, fixReady: p.fixReady);
  }

  void dropPause() {
    paused = null;
    notifyListeners();
  }

  static String _money(double v) => '\$${v.toStringAsFixed(v < 0.01 ? 4 : 2)}';

  /// What the current auto-fix has cost so far (all rounds).
  double fixSpent = 0;

  Future<File> _fixModelsFile() async => File('${(await getApplicationDocumentsDirectory()).path}/aiy/fix_models.json');

  /// The model that last fixed this kind of error (its id), or null.
  Future<String?> modelThatFixed(List<Problem> problems) async {
    try {
      final j = await Store.readJson(await _fixModelsFile());
      if (j is Map) return j[errorKind(problems)] as String?;
    } catch (_) {}
    return null;
  }

  Future<void> _rememberFixer(String kind, String modelId) async {
    try {
      final f = await _fixModelsFile();
      final j = await Store.readJson(f);
      final m = j is Map ? Map<String, dynamic>.from(j) : <String, dynamic>{};
      m[kind] = modelId;
      f.parent.createSync(recursive: true);
      await Store.writeJson(f, m);
    } catch (_) {}
  }

  String get _spentNote => fixSpent > 0 ? ' · spent so far: ${_money(fixSpent)}' : '';

  /// [free] = try this free model first (one round). If its fix does not work, the paid model [m] takes over for
  /// [rounds] rounds. Nothing is charged for the free round.
  Future<void> autoFix(OrModel m, int rounds, {bool fixReady = false, OrModel? free}) async {
    if (phase != 'failed' || _loop) return;
    if (setupStepFailed.isEmpty && environmentProblem.isNotEmpty) {
      error = 'This is not a mistake in your code: ${environmentProblem}. AI cannot fix it from your files, so AIy did not spend any money. Tap "Update and build again": AIy updates its build so plugins use a new enough Android version.';
      notifyListeners();
      return;
    }
    if (setupStepFailed.isNotEmpty) {
      // Nothing in the project's code to fix: do not spend money on a model.
      error = 'The step "$setupStepFailed" is part of GitHub\'s build setup, not your code, so AI cannot fix it. Tap "Update and build again": AIy updates its build workflow so this step can no longer stop the build.';
      notifyListeners();
      return;
    }
    _loop = true;
    _stopLoop = false;
    paused = null;
    final ver = version;
    var last = '';
    var same = 0;
    var ok = false;
    final kind = errorKind(problems);
    if (!fixReady) fixSpent = 0;
    final plan = [if (free != null && !m.free && !fixReady) free, for (var k = 0; k < rounds; k++) m];
    final total = plan.length;
    OrModel? prevModel;
    var winner = m;
    try {
      for (var i = 1; i <= total; i++) {
        if (_stopLoop) break;
        final cur = plan[i - 1];
        // a free round that fails hands over to the paid model instead of stopping
        final canEscalate = cur.free && !m.free && i < total;
        // rounds still to go if the loop pauses now (a paused free round goes on with the paid model)
        int left() => canEscalate ? total - i : total - i + 1;
        OrModel resumeWith() => canEscalate ? m : cur;
        void handOver(String why) {
          notes.add('Free try with ${cur.name}: $why. Switched to ${m.name}.');
          error = null;
          code.clearError();
          // its unpushed edits are not an "earlier attempt that was built": do not show them to the paid model as one
          if (!pushed) code.changes = [];
        }
        if (prevModel != null && prevModel.id != cur.id) {
          last = '';
          same = 0;
        }
        prevModel = cur;
        final key = errorSetKey(problems, log);
        if (key == last && ++same >= 2) {
          error = 'The exact same errors came back after the fix, so AIy stopped to save money${fixSpent > 0 ? ' (spent ${_money(fixSpent)})' : ''}. Read them below, or try a different model.';
          break;
        }
        if (key != last) same = 0;
        last = key;
        final skipPatch = fixReady && i == 1;
        if (!skipPatch) {
          _say('Fix $i of $total: ${cur.name}${cur.free ? ' (free)' : ''} is writing a fix…$_spentNote', p: 'fixing');
          final msg = code.startFix(problems, log);
          if (msg != null) {
            error = msg;
            break;
          }
          await code.patch(cur);
          fixSpent += code.spent;
        }
        if (_stopLoop) break;
        if (!skipPatch && code.heldOffline) {
          // The Code tab would send the patch again by itself, but then the loop would not go on. Pause the loop instead.
          Offline.drop(code.heldTitle);
          code.heldOffline = false;
          code.clearError();
          _pause(resumeWith(), left(), false);
          break;
        }
        if (code.error != null) {
          if (canEscalate) {
            handOver('it failed (${code.error})');
            continue;
          }
          error = code.error;
          code.clearError();
          break;
        }
        if (!code.hasResult) {
          if (canEscalate) {
            handOver('no usable fix');
            continue;
          }
          error = 'The model did not give a usable fix.';
          break;
        }
        if (!skipPatch && canEscalate && !code.changes.any((c) => c.after != (c.before ?? '\u0000'))) {
          handOver('its edits did not match your code');
          continue;
        }
        if (!skipPatch && !code.changes.any((c) => c.after != (c.before ?? '\u0000'))) {
          // Every edit pointed at text that is not in the files: pushing would rebuild the SAME code and fail the same way.
          error = 'The fix from ${cur.name} did not match your code (its edits point at lines that are not in the files), so nothing would change. AIy stopped before rebuilding, so no build was wasted. Try a stronger model.';
          break;
        }
        _say('Fix $i of $total: pushing it…$_spentNote', p: 'fixing');
        await push(PushPlan(repo: repo, base: branch));
        if (!_stopLoop && error != null && lastWasConnection) {
          _pause(resumeWith(), left() + (canEscalate ? 1 : 0), true);
          break;
        }
        if (_stopLoop || error != null || !pushed) break;
        if (status.startsWith('GitHub already had exactly these files')) {
          if (canEscalate) {
            handOver('its fix changed nothing');
            continue;
          }
          error = 'The fix changed nothing on GitHub, so checking again would give the same errors. AIy stopped. Try a different model.';
          break;
        }
        await check();
        if (_stopLoop) break;
        if (error != null && lastWasConnection) {
          // pushed, but the check could not be followed: continuing pushes nothing new and checks again
          _pause(resumeWith(), left() + (canEscalate ? 1 : 0), true);
          break;
        }
        if (phase == 'done') {
          ok = true;
          winner = cur;
          break;
        }
        if (phase != 'failed') break;
      }
      if (ok && !_stopLoop) {
        unawaited(_rememberFixer(kind, winner.id));
        notes.add(fixSpent > 0 ? 'Fixed by ${winner.name} for ${_money(fixSpent)} in total' : 'Fixed by ${winner.name} (free)');
        final prep = await prepare();
        if (prep != null) {
          await start(prep, versionName: ver.isEmpty ? (prep.version?.name ?? '1.0.0') : ver, releaseNotes: 'Fixed by AIy', release: false);
        }
      } else if (phase == 'fixing' || phase == 'idle' || paused != null) {
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
    } catch (e) {
      AppLog.i('build_state:711: $e');
    }
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
      {
        final j = await Store.readJson(f);
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
      await Store.writeJson(await _file(), [for (final a in apks) a.toJson()]);
    } catch (e) {
      debugPrint('apks save: $e');
    }
  }

  /// Removes every downloaded APK (Settings > Storage).
  Future<void> deleteAllApks() async {
    for (final a in apks) {
      try {
        final f = File(a.file);
        if (f.existsSync()) f.deleteSync();
      } catch (e) {
        AppLog.i('apk delete: $e');
      }
    }
    apks = [];
    notifyListeners();
    await _saveApks();
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
