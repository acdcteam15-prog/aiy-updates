import 'package:flutter/material.dart';

import '../../logic/versioning.dart';
import '../../state/build_state.dart';
import '../../state/github.dart';
import '../../state/net.dart';
import '../widgets/common.dart';

/// "Push to GitHub": which repository, which branch, commit straight in or open a pull request.
class PushSheet extends StatefulWidget {
  final String token;
  final String currentRepo;
  final String currentBranch;
  final String suggestedName;
  const PushSheet({super.key, required this.token, required this.currentRepo, required this.currentBranch, required this.suggestedName});
  @override
  State<PushSheet> createState() => _PushSheetState();
}

class _PushSheetState extends State<PushSheet> {
  late final GitHubApi _api = GitHubApi(widget.token);
  final _name = TextEditingController();
  String _stage = 'main'; // pick | main
  String _repo = '';
  String _base = '';
  bool _create = false;
  bool _private = true;
  bool _whole = false;
  bool _newBranch = false;
  List<GhRepo>? _repos;
  List<String>? _branches;
  String? _error;
  String _q = '';

  @override
  void initState() {
    super.initState();
    _repo = widget.currentRepo;
    _base = widget.currentBranch;
    _name.text = widget.suggestedName;
    _stage = _repo.isEmpty ? 'pick' : 'main';
    if (_stage == 'pick') {
      _loadRepos();
    } else {
      _loadBranches();
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _loadRepos() async {
    try {
      final r = await _api.repos();
      if (mounted) setState(() => _repos = r);
    } catch (e) {
      if (mounted) setState(() => _error = e is ApiError ? e.message : '$e');
    }
  }

  Future<void> _loadBranches() async {
    try {
      final b = await _api.branches(_repo);
      b.sort((x, y) => x == _base ? -1 : (y == _base ? 1 : x.compareTo(y)));
      if (mounted) setState(() => _branches = b);
    } catch (e) {
      if (mounted) setState(() => _error = e is ApiError ? e.message : '$e');
    }
  }

  bool get _nameOk => RegExp(r'^[A-Za-z0-9._-]{1,100}$').hasMatch(_name.text.trim());
  bool get _showWhole => _create || _repo != widget.currentRepo;

  void _go() {
    Navigator.pop(
      context,
      PushPlan(
        repo: _create ? _name.text.trim() : _repo,
        base: _base,
        newBranch: !_create && _newBranch,
        whole: _create || (_showWhole && _whole),
        createRepo: _create,
        privateRepo: _private,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final sub = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final size = MediaQuery.of(context).size.height;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: _stage == 'pick' ? size * 0.8 : null,
        child: _stage == 'pick' ? _pick(t) : SingleChildScrollView(padding: const EdgeInsets.fromLTRB(22, 0, 22, 22), child: _main(t, sub)),
      ),
    );
  }

  Widget _pick(ThemeData t) {
    final list = _repos?.where((r) => r.full.toLowerCase().contains(_q.toLowerCase())).toList();
    return Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(22, 0, 22, 10), child: Align(alignment: Alignment.centerLeft, child: Text('Where should it go?', style: t.textTheme.titleLarge))),
      ListTile(
        leading: CircleAvatar(backgroundColor: t.colorScheme.primary.withValues(alpha: 0.14), child: Icon(Icons.add_rounded, color: t.colorScheme.primary)),
        title: const Text('Create a new repository'),
        subtitle: const Text('The whole project is uploaded to it'),
        onTap: () => setState(() {
          _create = true;
          _stage = 'main';
          _base = 'main';
          _error = null;
        }),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: TextField(onChanged: (v) => setState(() => _q = v), decoration: const InputDecoration(isDense: true, hintText: 'Search your repositories', prefixIcon: Icon(Icons.search_rounded, size: 20))),
      ),
      Expanded(
        child: _error != null
            ? Padding(padding: const EdgeInsets.all(20), child: ErrorBox(_error!))
            : list == null
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    itemCount: list.length,
                    itemBuilder: (_, i) => ListTile(
                      leading: Icon(list[i].private ? Icons.lock_outline_rounded : Icons.public_rounded),
                      title: Text(list[i].full),
                      onTap: () => setState(() {
                        _repo = list[i].full;
                        _base = list[i].defaultBranch;
                        _create = false;
                        _whole = false;
                        _branches = null;
                        _stage = 'main';
                        _loadBranches();
                      }),
                    ),
                  ),
      ),
    ]);
  }

  Widget _main(ThemeData t, TextStyle? sub) {
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Push to GitHub', style: t.textTheme.titleLarge),
      const SizedBox(height: 14),
      if (_create) ...[
        TextField(controller: _name, onChanged: (_) => setState(() {}), decoration: InputDecoration(labelText: 'Name of the new repository', errorText: _nameOk ? null : 'Letters, numbers, dots, dashes and underscores only')),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Private'), subtitle: const Text('Only you can see it'), value: _private, onChanged: (v) => setState(() => _private = v)),
      ] else
        Container(
          padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
          decoration: BoxDecoration(color: t.colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(16)),
          child: Row(children: [
            const Icon(Icons.code_rounded, size: 20),
            const SizedBox(width: 10),
            Expanded(child: Text(_repo, style: t.textTheme.titleSmall)),
            TextButton(
              onPressed: () => setState(() {
                _stage = 'pick';
                _repos ??= null;
                if (_repos == null) _loadRepos();
              }),
              child: const Text('Change'),
            ),
          ]),
        ),
      if (!_create) ...[
        const SizedBox(height: 14),
        Row(children: [
          Text('Branch', style: t.textTheme.titleSmall),
          const SizedBox(width: 14),
          Expanded(
            child: _branches == null
                ? Align(alignment: Alignment.centerLeft, child: _error != null ? Text(_error!, style: TextStyle(color: t.colorScheme.error)) : const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
                : _branches!.isEmpty
                ? Align(alignment: Alignment.centerLeft, child: Text('This repository has no branches yet: the first push creates one.', style: TextStyle(color: t.colorScheme.onSurfaceVariant)))
                : DropdownButton<String>(
                    isExpanded: true,
                    value: _branches!.contains(_base) ? _base : _branches!.first,
                    items: [for (final b in _branches!) DropdownMenuItem(value: b, child: Text(b, overflow: TextOverflow.ellipsis))],
                    onChanged: (v) => setState(() => _base = v ?? _base),
                  ),
          ),
        ]),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: const [ButtonSegment(value: false, label: Text('Commit to it')), ButtonSegment(value: true, label: Text('New branch'))],
            selected: {_newBranch},
            onSelectionChanged: (s) => setState(() => _newBranch = s.first),
          ),
        ),
        Padding(padding: const EdgeInsets.only(top: 6), child: Text(_newBranch ? 'Safer: your branch stays untouched. You can open a pull request afterwards, and the build runs on the new branch.' : 'The change goes straight into the branch.', style: sub)),
      ],
      if (_showWhole)
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Upload the whole project'),
          subtitle: Text(_create ? 'A new repository starts empty, so everything is uploaded (heavy folders like node_modules are skipped).' : 'Off: only the changed files are sent, so the repository must already contain this project.'),
          value: _create || _whole,
          onChanged: _create ? null : (v) => setState(() => _whole = v),
        ),
      const SizedBox(height: 14),
      Row(children: [
        Expanded(child: OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))),
        const SizedBox(width: 12),
        Expanded(child: FilledButton(onPressed: (_create ? _nameOk : _branches != null) ? _go : null, child: const Text('Push'))),
      ]),
    ]);
  }
}

/// "Which version is this?" - asked before every build, written into the project so the app shows it.
class VersionSheet extends StatefulWidget {
  final String? current;
  final String? foundIn;
  final String notes;
  final bool release;
  const VersionSheet({super.key, required this.current, required this.foundIn, required this.notes, required this.release});
  @override
  State<VersionSheet> createState() => _VersionSheetState();
}

class _VersionSheetState extends State<VersionSheet> {
  final _v = TextEditingController();
  final _notes = TextEditingController();
  late bool _release = widget.release;

  @override
  void initState() {
    super.initState();
    _v.text = widget.current == null ? '1.0.0' : bumpVersion(widget.current!, 'patch');
    _notes.text = widget.notes.length > 600 ? widget.notes.substring(0, 600) : widget.notes;
  }

  @override
  void dispose() {
    _v.dispose();
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cur = widget.current;
    final ok = validVersion(_v.text);
    Widget chip(String label, String value) => ChoiceChip(label: Text(label), selected: _v.text.trim() == value, onSelected: (_) => setState(() => _v.text = value));
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(22, 0, 22, 22),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Which version is this?', style: t.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            cur == null ? 'No version number was found in the project, so it is only used in the file name.' : 'The project says $cur (in ${widget.foundIn}). The version you choose is written there, so the app shows it.',
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _v,
            onChanged: (_) => setState(() {}),
            keyboardType: TextInputType.visiblePassword,
            decoration: InputDecoration(labelText: 'Version', errorText: ok ? null : 'Use numbers and dots, for example 1.2.0'),
          ),
          if (cur != null) ...[
            const SizedBox(height: 10),
            Wrap(spacing: 8, children: [
              chip('Same', cur),
              chip('Small fix ${bumpVersion(cur, 'patch')}', bumpVersion(cur, 'patch')),
              chip('New feature ${bumpVersion(cur, 'minor')}', bumpVersion(cur, 'minor')),
              chip('Big change ${bumpVersion(cur, 'major')}', bumpVersion(cur, 'major')),
            ]),
          ],
          const SizedBox(height: 14),
          TextField(controller: _notes, minLines: 2, maxLines: 5, decoration: const InputDecoration(labelText: 'What is new (shown on the release)')),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Also publish a GitHub Release'),
            subtitle: const Text('Gives the APK a download page you can share with other people.'),
            value: _release,
            onChanged: (v) => setState(() => _release = v),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))),
            const SizedBox(width: 12),
            Expanded(child: FilledButton(onPressed: ok ? () => Navigator.pop(context, (_v.text.trim(), _notes.text.trim(), _release)) : null, child: const Text('Build the app'))),
          ]),
        ]),
      ),
    );
  }
}
