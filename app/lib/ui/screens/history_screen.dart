import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../state/build_state.dart';
import '../../state/code_state.dart';
import '../../state/native.dart';
import '../widgets/common.dart';
import '../widgets/fx.dart';
import '../widgets/markdown.dart';
import '../widgets/qr_dialog.dart';
import 'build_screen.dart' show saveOrShare;

/// Earlier changes kept on the phone (read the summary again, get the zip, continue from it) and the apps built on GitHub.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});
  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final code = context.watch<CodeState>();
    final build = context.watch<BuildState>();
    final t = Theme.of(context);
    final empty = _tab == 0 ? code.history.isEmpty : build.apks.isEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('History')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: SizedBox(
            width: double.infinity,
            child: SegmentedButton<int>(
              showSelectedIcon: false,
              segments: [ButtonSegment(value: 0, label: Text('Changes (${code.history.length})')), ButtonSegment(value: 1, label: Text('Apps (${build.apks.length})'))],
              selected: {_tab},
              onSelectionChanged: (s) => setState(() => _tab = s.first),
            ),
          ),
        ),
        Expanded(
          child: empty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(_tab == 0 ? 'Every change AIy makes is kept here (the newest 20), so you can go back to an older version.' : 'Apps you build on GitHub are kept here (the newest 3 of each repository), ready to install again.',
                        textAlign: TextAlign.center, style: TextStyle(color: t.colorScheme.onSurfaceVariant)),
                  ),
                )
              : ListView.separated(
                  key: ValueKey(_tab),
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
                  itemCount: _tab == 0 ? code.history.length : build.apks.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (_, i) => Appear(delay: (i * 50).clamp(0, 300), dy: 10, child: _tab == 0 ? _BuildCard(code.history[i]) : _ApkCard(build.apks[i])),
                ),
        ),
      ]),
    );
  }
}

class _ApkCard extends StatelessWidget {
  final ApkRecord a;
  const _ApkCard(this.a);
  @override
  Widget build(BuildContext context) {
    final b = Provider.of<BuildState>(context, listen: false);
    final t = Theme.of(context);
    final sub = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    return StepCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(fmtDate(a.date), style: sub),
        const SizedBox(height: 4),
        Text('${a.repo.split('/').last} ${a.version}', style: t.textTheme.titleMedium),
        Text('${a.repo} · ${a.branch} · run ${a.run} · ${fmtBytes(a.size)}', style: sub),
        const SizedBox(height: 8),
        Wrap(spacing: 4, children: [
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(64, 40)),
            onPressed: () async {
              final m = await b.install(a.file);
              if (m != null && context.mounted) snack(context, m);
            },
            child: const Text('Install'),
          ),
          TextButton(onPressed: () => saveOrShare(context, b, a.file), child: const Text('Save')),
          TextButton(onPressed: () => SharePlus.instance.share(ShareParams(files: [XFile(a.file)])), child: const Text('Share')),
          if (a.releaseUrl.isNotEmpty) TextButton(onPressed: () => Native.openUrl(a.releaseUrl), child: const Text('Release')),
          if (a.releaseUrl.isNotEmpty) TextButton(onPressed: () => showQrDialog(context, a.releaseUrl), child: const Text('QR')),
          if (a.runUrl.isNotEmpty) TextButton(onPressed: () => Native.openUrl(a.runUrl), child: const Text('GitHub')),
          TextButton(
            onPressed: () async {
              if (await confirmDialog(context, 'Delete this app file?', body: 'It is removed from the phone only.', yes: 'Delete')) b.deleteApk(a);
            },
            child: Text('Delete', style: TextStyle(color: t.colorScheme.error)),
          ),
        ]),
      ]),
    );
  }
}

class _BuildCard extends StatefulWidget {
  final BuildRecord b;
  const _BuildCard(this.b);
  @override
  State<_BuildCard> createState() => _BuildCardState();
}

class _BuildCardState extends State<_BuildCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final b = widget.b;
    final code = Provider.of<CodeState>(context, listen: false);
    final t = Theme.of(context);
    final sub = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final exists = File(b.zip).existsSync();
    final name = code.zipNameFor(b.source, b.id);
    return StepCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(fmtDate(b.date), style: sub)),
          if (b.warnings > 0) Icon(Icons.warning_amber_rounded, size: 18, color: t.colorScheme.error),
        ]),
        const SizedBox(height: 4),
        Text(b.request, maxLines: _open ? 20 : 2, overflow: TextOverflow.ellipsis, style: t.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text('${b.source} · ${b.files.length} file(s) · ${b.model} · ${fmtMoney(b.cost)}', style: sub),
        if (_open) ...[
          const SizedBox(height: 10),
          SelectionArea(child: MdText(b.summary)),
          for (final f in b.files) Text(f, style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5)),
        ],
        const SizedBox(height: 8),
        Wrap(spacing: 4, runSpacing: 0, children: [
          TextButton(onPressed: () => setState(() => _open = !_open), child: Text(_open ? 'Hide summary' : 'Summary')),
          if (exists)
            TextButton(
              onPressed: () async {
                try {
                  final where = await code.saveToDownloads(b.zip, name);
                  if (context.mounted) snack(context, 'Saved to $where');
                } catch (_) {
                  await SharePlus.instance.share(ShareParams(files: [XFile(b.zip)], text: name));
                }
              },
              child: const Text('Save zip'),
            ),
          if (exists) TextButton(onPressed: () => SharePlus.instance.share(ShareParams(files: [XFile(b.zip)], text: name)), child: const Text('Share')),
          if (exists)
            TextButton(
              onPressed: () async {
                await code.openBuild(b);
                if (context.mounted) {
                  Navigator.pop(context);
                  snack(context, 'This version is now the open project (Code tab).');
                }
              },
              child: const Text('Continue from this version'),
            ),
          TextButton(
            onPressed: () async {
              if (await confirmDialog(context, 'Delete this build?', body: 'Its zip is removed from the phone.', yes: 'Delete')) code.deleteBuild(b);
            },
            child: Text('Delete', style: TextStyle(color: t.colorScheme.error)),
          ),
        ]),
      ]),
    );
  }
}
