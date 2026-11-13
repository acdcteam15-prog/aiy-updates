import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'net.dart';

class GhRepo {
  final String full;
  final String defaultBranch;
  final bool private;
  const GhRepo(this.full, this.defaultBranch, this.private);
}

class RunInfo {
  final int id;
  final int number;
  final String status;
  final String conclusion;
  final String url;
  final String sha;
  const RunInfo(this.id, this.number, this.status, this.conclusion, this.url, this.sha);
  bool get done => status == 'completed';
}

/// One step of a running job, as shown in the build screen.
class StepInfo {
  final String job;
  final String name;

  /// 'done', 'failed', 'running' or 'waiting'.
  final String state;
  const StepInfo(this.job, this.name, this.state);
}

/// The GitHub calls AIy needs: repositories and branches, committing files, starting a build workflow,
/// following the run, fetching the APK, and publishing a release or a pull request.
class GitHubApi {
  final String token;
  GitHubApi(this.token);

  static const _api = 'https://api.github.com';
  Map<String, String> get _h => {'Authorization': 'Bearer $token', 'Accept': 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': 'AIy'};

  String _explain(int status, String body) {
    final d = Net.detail(body);
    switch (status) {
      case 401:
        return 'GitHub rejected the sign-in (401). Connect GitHub again in Settings > Accounts & keys.';
      case 403:
        return 'GitHub refused (403)${d.isEmpty ? '' : ': $d'}. The sign-in needs the "repo" and "workflow" permissions: disconnect GitHub and connect it again.';
      case 404:
        return 'GitHub says "not found" (404)${d.isEmpty ? '' : ': $d'}. If you were adding a workflow file, the sign-in lacks the "workflow" permission: disconnect GitHub and connect it again.';
      case 409:
        return 'GitHub says there is a conflict (409)${d.isEmpty ? '' : ': $d'}. Try again in a moment.';
      case 422:
        return 'GitHub did not accept this (422)${d.isEmpty ? '' : ': $d'}';
      default:
        return Net.explain('GitHub', status, body);
    }
  }

  Future<dynamic> _call(String method, String path, {Object? json, bool allow404 = false}) async {
    final r = await Net.send(method, Uri.parse('$_api$path'), headers: _h, json: json, timeoutSec: 90, who: 'GitHub');
    if (allow404 && r.status == 404) return null;
    if (r.status < 200 || r.status >= 300) throw ApiError(_explain(r.status, r.body), r.status);
    return r.body.isEmpty ? null : jsonDecode(r.body);
  }

  // ------------------------------------------------------------------ account and repositories
  Future<String> login() async => '${(await _call('GET', '/user') as Map)['login']}';

  /// The permissions of a classic token ("repo, workflow"). Empty when GitHub does not say (new-style tokens).
  Future<String> scopes() async {
    final r = await Net.sendWithHeader(Uri.parse('$_api/user'), _h, 'x-oauth-scopes');
    return r;
  }

  Future<List<GhRepo>> repos() async {
    final out = <GhRepo>[];
    for (var page = 1; page <= 3; page++) {
      final l = await _call('GET', '/user/repos?per_page=100&sort=pushed&page=$page&affiliation=owner,collaborator,organization_member');
      if (l is! List || l.isEmpty) break;
      for (final r in l) {
        if (r is! Map || r['archived'] == true) continue;
        final perms = r['permissions'];
        if (perms is Map && perms['push'] == false) continue;
        out.add(GhRepo('${r['full_name']}', '${r['default_branch'] ?? 'main'}', r['private'] == true));
      }
      if (l.length < 100) break;
    }
    return out;
  }

  Future<GhRepo> createRepo(String name, bool private) async {
    final o = await _call('POST', '/user/repos', json: {'name': name, 'private': private, 'auto_init': true, 'description': 'Created with AIy'}) as Map;
    return GhRepo('${o['full_name']}', '${o['default_branch'] ?? 'main'}', o['private'] == true);
  }

  Future<List<String>> branches(String full) async {
    final l = await _call('GET', '/repos/$full/branches?per_page=100');
    return [
      if (l is List)
        for (final b in l)
          if (b is Map) '${b['name']}'
    ];
  }

  /// Downloads the branch as a zip (the same file as GitHub's "Download ZIP").
  Future<void> downloadZip(String full, String branch, File out, {void Function(int got)? onProgress}) =>
      Net.download(Uri.parse('$_api/repos/$full/zipball/${Uri.encodeComponent(branch)}'), out, headers: _h, onProgress: onProgress);

  /// The text of a file in the repository, or null when it is not there.
  Future<String?> fileText(String repo, String path, String ref) async {
    final o = await _call('GET', '/repos/$repo/contents/$path?ref=${Uri.encodeComponent(ref)}', allow404: true);
    if (o is! Map || o['encoding'] != 'base64') return null;
    return utf8.decode(base64.decode('${o['content']}'.replaceAll(RegExp(r'\s'), '')), allowMalformed: true);
  }

  // ------------------------------------------------------------------ committing files
  Future<String> branchSha(String repo, String branch) async => '${((await _call('GET', '/repos/$repo/git/ref/heads/${Uri.encodeComponent(branch)}') as Map)['object'] as Map)['sha']}';

  Future<String> commitTree(String repo, String commitSha) async => '${((await _call('GET', '/repos/$repo/git/commits/$commitSha') as Map)['tree'] as Map)['sha']}';

  Future<String> createBlob(String repo, List<int> bytes) async =>
      '${(await _call('POST', '/repos/$repo/git/blobs', json: {'content': base64Encode(bytes), 'encoding': 'base64'}) as Map)['sha']}';

  /// Entries are (path, mode, blob sha). Files that are not listed stay as they are.
  Future<String> createTree(String repo, String baseTree, List<(String, String, String)> entries) async {
    final r = await _call('POST', '/repos/$repo/git/trees', json: {
      'base_tree': baseTree,
      'tree': [
        for (final (path, mode, sha) in entries) {'path': path, 'mode': mode, 'type': 'blob', 'sha': sha}
      ],
    });
    return '${(r as Map)['sha']}';
  }

  Future<String> createCommit(String repo, String message, String tree, String parent) async =>
      '${(await _call('POST', '/repos/$repo/git/commits', json: {'message': message, 'tree': tree, 'parents': [parent]}) as Map)['sha']}';

  Future<void> updateRef(String repo, String branch, String sha, {bool force = false}) =>
      _call('PATCH', '/repos/$repo/git/refs/heads/${Uri.encodeComponent(branch)}', json: {'sha': sha, 'force': force});

  Future<void> createBranch(String repo, String branch, String sha) => _call('POST', '/repos/$repo/git/refs', json: {'ref': 'refs/heads/$branch', 'sha': sha});

  Future<String> openPullRequest(String repo, String base, String head, String title, String body) async =>
      '${(await _call('POST', '/repos/$repo/pulls', json: {'title': title, 'head': head, 'base': base, 'body': body}) as Map)['html_url']}';

  // ------------------------------------------------------------------ running the workflow
  Future<void> dispatch(String repo, String workflow, String ref) => _call('POST', '/repos/$repo/actions/workflows/$workflow/dispatches', json: {'ref': ref});

  RunInfo _run(Map o) => RunInfo((o['id'] as num).toInt(), (o['run_number'] as num?)?.toInt() ?? 0, '${o['status'] ?? ''}', '${o['conclusion'] ?? ''}', '${o['html_url'] ?? ''}', '${o['head_sha'] ?? ''}');

  /// The newest runs of a workflow that were started by hand on a branch.
  Future<List<RunInfo>> runs(String repo, String workflow, String branch) async {
    final o = await _call('GET', '/repos/$repo/actions/workflows/$workflow/runs?event=workflow_dispatch&branch=${Uri.encodeComponent(branch)}&per_page=8') as Map;
    return [for (final r in (o['workflow_runs'] as List? ?? const [])) if (r is Map) _run(r)];
  }

  Future<RunInfo> run(String repo, int id) async => _run(await _call('GET', '/repos/$repo/actions/runs/$id') as Map);

  Future<List<Map>> _jobs(String repo, int runId) async {
    final o = await _call('GET', '/repos/$repo/actions/runs/$runId/jobs') as Map;
    return [for (final j in (o['jobs'] as List? ?? const [])) if (j is Map) j];
  }

  /// The steps of every job with their state, and the name of the step that is running now.
  Future<(List<StepInfo>, String)> steps(String repo, int runId) async {
    final out = <StepInfo>[];
    var current = 'waiting for a runner';
    for (final j in await _jobs(repo, runId)) {
      for (final s in (j['steps'] as List? ?? const [])) {
        if (s is! Map) continue;
        final name = '${s['name']}';
        if (name.startsWith('Set up job') || name.startsWith('Post ') || name.startsWith('Complete job')) continue;
        final st = '${s['status']}', concl = '${s['conclusion']}';
        final state = st == 'completed' ? ((concl == 'success' || concl == 'skipped') ? 'done' : 'failed') : (st == 'in_progress' ? 'running' : 'waiting');
        if (state == 'running') current = name;
        out.add(StepInfo('${j['name']}', name, state));
      }
    }
    return (out, current);
  }

  /// The log of the first failed job ('' when it cannot be fetched).
  Future<String> failedLog(String repo, int runId) async {
    for (final j in await _jobs(repo, runId)) {
      if (j['conclusion'] != 'failure') continue;
      try {
        final f = File('${Directory.systemTemp.path}/aiy-joblog.txt');
        await Net.download(Uri.parse('$_api/repos/$repo/actions/jobs/${j['id']}/logs'), f, headers: _h);
        final t = await f.readAsString();
        f.deleteSync();
        if (t.isNotEmpty) return t;
      } catch (_) {}
    }
    return '';
  }

  Future<void> cancelRun(String repo, int id) async {
    try {
      await _call('POST', '/repos/$repo/actions/runs/$id/cancel');
    } catch (_) {}
  }

  /// The downloads of a finished run: (id, name).
  Future<List<(int, String)>> artifacts(String repo, int runId) async {
    final o = await _call('GET', '/repos/$repo/actions/runs/$runId/artifacts') as Map;
    return [
      for (final a in (o['artifacts'] as List? ?? const []))
        if (a is Map && a['expired'] != true) ((a['id'] as num).toInt(), '${a['name']}')
    ];
  }

  Future<void> downloadArtifact(String repo, int artifactId, File dest) {
    dest.parent.createSync(recursive: true);
    return Net.download(Uri.parse('$_api/repos/$repo/actions/artifacts/$artifactId/zip'), dest, headers: _h);
  }

  // ------------------------------------------------------------------ releases
  Future<({int id, String url})> createRelease(String repo, String tag, String name, String body, String branch) async {
    final o = await _call('POST', '/repos/$repo/releases', json: {'tag_name': tag, 'target_commitish': branch, 'name': name, 'body': body, 'prerelease': false}) as Map;
    return (id: (o['id'] as num).toInt(), url: '${o['html_url']}');
  }

  Future<void> uploadAsset(String repo, int releaseId, File file, String name) async {
    final r = await Net.upload(Uri.parse('https://uploads.github.com/repos/$repo/releases/$releaseId/assets?name=${Uri.encodeQueryComponent(name)}'), file,
        headers: _h, contentType: 'application/vnd.android.package-archive', who: 'GitHub');
    if (r.status < 200 || r.status >= 300) throw ApiError(_explain(r.status, r.body), r.status);
  }
}

/// Bytes of a text file (helper for committing strings).
Uint8List utf8Bytes(String s) => Uint8List.fromList(utf8.encode(s));
