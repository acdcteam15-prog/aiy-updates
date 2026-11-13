import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../state/ai.dart' show OrModel;
import '../../state/build_state.dart';
import '../../state/code_state.dart';
import '../../state/native.dart';
import '../widgets/common.dart';
import '../widgets/qr_dialog.dart';
import 'autofix_sheet.dart';
import '../widgets/fx.dart';
import '../widgets/timeline.dart';

/// Follows a build on GitHub: steps, then the APK (install, save, share) or the errors (fix with AI).
class BuildScreen extends StatelessWidget {
  const BuildScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final b = context.watch<BuildState>();
    final t = Theme.of(context);
    final sub = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final running = b.running;
    final done = b.phase == 'done';
    final failed = b.phase == 'failed';
    const green = Color(0xFF34C759);
    final title = b.phase == 'fixing'
        ? 'Fixing the errors'
        : (b.checkOnly
            ? (running ? 'Checking the code' : (done ? 'No errors found' : (failed ? 'The check found errors' : 'Check')))
            : (running ? 'Building version ${b.version}' : (done ? 'Your app is ready' : (failed ? 'The build failed' : 'Build'))));
    return Scaffold(
      appBar: AppBar(title: const Text('Build on GitHub')),
      body: AuroraBackground(
        strength: 0.45,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 40), children: [
          StepCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
                  child: running
                      ? const Orb(key: ValueKey('orb'), size: 44, busy: true)
                      : Icon(done ? Icons.check_circle_rounded : (failed ? Icons.error_rounded : Icons.info_outline_rounded), key: ValueKey(b.phase), size: 44, color: done ? green : (failed ? t.colorScheme.error : t.colorScheme.primary)),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, style: t.textTheme.titleLarge),
                    if (b.status.isNotEmpty) Text(b.status, style: sub),
                  ]),
                ),
              ]),
              if (running) ...[
                const SizedBox(height: 14),
                LinearProgressIndicator(value: b.phase == 'building' && b.progress > 0 ? b.progress : null, borderRadius: BorderRadius.circular(8), minHeight: 6),
                const SizedBox(height: 10),
                Text('A build takes a few minutes. You can leave AIy: the build keeps running on GitHub, and AIy picks it up again when you come back.', style: sub),
              ],
            ]),
          ),
          if (b.error != null) ...[const SizedBox(height: 12), ErrorBox(b.error!, onClose: b.clearError)],
          if (running || done || failed) ...[const SizedBox(height: 12), Appear(child: StepCard(child: StepTimeline(_bigSteps(b, running, done, failed))))],
          if (b.steps.isNotEmpty) ...[
            const SizedBox(height: 12),
            Appear(
              child: StepCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Steps', style: t.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  for (final s in b.steps)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(children: [
                        SizedBox(
                          width: 22,
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 250),
                            child: switch (s.state) {
                              'done' => const Icon(Icons.check_rounded, key: ValueKey('d'), size: 18, color: green),
                              'failed' => Icon(Icons.close_rounded, key: const ValueKey('f'), size: 18, color: t.colorScheme.error),
                              'running' => const SizedBox(key: ValueKey('r'), width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                              _ => Icon(Icons.circle_outlined, key: const ValueKey('w'), size: 14, color: t.colorScheme.onSurfaceVariant),
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(child: Text(s.name, style: t.textTheme.bodyMedium?.copyWith(color: s.state == 'waiting' ? t.colorScheme.onSurfaceVariant : null))),
                      ]),
                    ),
                ]),
              ),
            ),
          ],
          if (done && b.checkOnly) ...[
            const SizedBox(height: 12),
            Appear(
              child: StepCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('The code compiles. Go back and tap "Build the app" to make the APK.', style: t.textTheme.bodyMedium),
                  const SizedBox(height: 10),
                  FilledButton(
                    style: FilledButton.styleFrom(minimumSize: const Size(64, 46)),
                    onPressed: () {
                      b.dismiss();
                      Navigator.pop(context);
                    },
                    child: const Text('Back'),
                  ),
                ]),
              ),
            ),
          ],
          if (done && b.apk != null && !b.checkOnly) ...[const SizedBox(height: 12), Appear(child: _Ready(b))],
          if (failed) ...[const SizedBox(height: 12), Appear(child: _Failed(b))],
          if (running) ...[
            const SizedBox(height: 16),
            Row(children: [
              if (b.runUrl.isNotEmpty) Expanded(child: OutlinedButton(onPressed: () => Native.openUrl(b.runUrl), child: const Text('Open on GitHub'))),
              if (b.runUrl.isNotEmpty) const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton(
                  onPressed: () async {
                    if (await confirmDialog(context, 'Cancel the build?', yes: 'Cancel the build', no: 'Keep building')) b.cancel();
                  },
                  child: const Text('Cancel'),
                ),
              ),
            ]),
          ],
        ]),
      ),
    );
  }
}

class _Ready extends StatelessWidget {
  final BuildState b;
  const _Ready(this.b);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final apk = b.apk!;
    final name = apk.path.split('/').last;
    return StepCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(name, style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
        Text('Version ${b.version} · ${fmtBytes(apk.lengthSync())}', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size(64, 46)),
            onPressed: () async {
              final m = await b.install(apk.path);
              if (m != null && context.mounted) snack(context, m);
            },
            icon: const Icon(Icons.install_mobile_rounded, size: 18),
            label: const Text('Install'),
          ),
          OutlinedButton.icon(onPressed: () => saveOrShare(context, b, apk.path), icon: const Icon(Icons.download_rounded, size: 18), label: const Text('Save')),
          OutlinedButton.icon(onPressed: () => SharePlus.instance.share(ShareParams(files: [XFile(apk.path)], text: name)), icon: const Icon(Icons.ios_share_rounded, size: 18), label: const Text('Share')),
          if (b.releaseUrl.isNotEmpty) OutlinedButton.icon(onPressed: () => Native.openUrl(b.releaseUrl), icon: const Icon(Icons.open_in_new_rounded, size: 18), label: const Text('Release page')),
          if (b.releaseUrl.isNotEmpty) OutlinedButton.icon(onPressed: () => showQrDialog(context, b.releaseUrl), icon: const Icon(Icons.qr_code_2_rounded, size: 18), label: const Text('QR code')),
        ]),
        if (b.notes.isNotEmpty) ...[
          const SizedBox(height: 12),
          for (final n in b.notes) Padding(padding: const EdgeInsets.only(bottom: 2), child: Text('• $n', style: t.textTheme.bodySmall)),
        ],
      ]),
    );
  }
}

Future<void> saveOrShare(BuildContext context, BuildState b, String path) async {
  try {
    final where = await b.saveApk(path);
    if (context.mounted) snack(context, 'Saved to $where');
  } catch (_) {
    await SharePlus.instance.share(ShareParams(files: [XFile(path)]));
  }
}

class _Failed extends StatelessWidget {
  final BuildState b;
  const _Failed(this.b);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final code = Provider.of<CodeState>(context, listen: false);
    return StepCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(b.problems.isEmpty ? 'AIy could not pick out a single error from the log. Open the log below or the run on GitHub.' : 'What went wrong', style: t.textTheme.titleSmall),
        const SizedBox(height: 6),
        for (final p in b.problems.take(8))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.error_outline_rounded, size: 18, color: t.colorScheme.error),
              const SizedBox(width: 8),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (p.file.isNotEmpty) Text('${p.file}${p.line > 0 ? ':${p.line}' : ''}', style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5, fontWeight: FontWeight.w700)),
                  Text(p.title, style: t.textTheme.bodyMedium),
                ]),
              ),
            ]),
          ),
        if (b.log.isNotEmpty)
          Theme(
            data: t.copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text('Build log (the end of it)', style: t.textTheme.titleSmall),
              children: [
                SingleChildScrollView(scrollDirection: Axis.horizontal, child: SelectableText(b.log.split('\n').map((l) => l.replaceFirst(RegExp(r'^\S*\d{4}-\d\d-\d\dT[\d:.]+Z '), '')).join('\n'), style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5))),
              ],
            ),
          ),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size(64, 46)),
            onPressed: () async {
              final r = await showModalBottomSheet<(OrModel, int)>(context: context, isScrollControlled: true, useSafeArea: true, builder: (_) => const AutoFixSheet());
              if (r != null) b.autoFix(r.$1, r.$2);
            },
            icon: const Icon(Icons.autorenew_rounded, size: 18),
            label: const Text('Fix and rebuild automatically'),
          ),
          OutlinedButton.icon(
            onPressed: () {
              final m = code.startFix(b.problems, b.log);
              if (m != null) {
                snack(context, m);
                return;
              }
              b.dismiss();
              Navigator.pop(context);
              snack(context, 'AIy picked the files from the errors. Choose a model and tap "Write the change".');
            },
            icon: const Icon(Icons.auto_fix_high_rounded, size: 18),
            label: const Text('Fix it myself with AI'),
          ),
          if (b.runUrl.isNotEmpty) OutlinedButton(onPressed: () => Native.openUrl(b.runUrl), child: const Text('Open on GitHub')),
          TextButton(
            onPressed: () {
              b.dismiss();
              Navigator.pop(context);
            },
            child: const Text('Close'),
          ),
        ]),
        Padding(padding: const EdgeInsets.only(top: 8), child: Text('"Fix it with AI" sends the errors and the files they point to to the model you choose (you see the cost first). Then push and build again.', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant))),
      ]),
    );
  }
}

/// The big picture: send the code, build (or check) it on GitHub, download the app, install it.
List<TimelineStep> _bigSteps(BuildState b, bool running, bool done, bool failed) {
  final check = b.checkOnly;
  // 0 = sending, 1 = building, 2 = downloading, 3 = ready
  var at = 0;
  switch (b.phase) {
    case 'queued':
    case 'building':
    case 'fixing':
      at = 1;
    case 'downloading':
      at = 2;
    case 'done':
      at = 3;
    case 'failed':
      // A run address means GitHub had started: the failure is in the build itself.
      at = b.runUrl.isNotEmpty ? 1 : 0;
  }
  String st(int i) {
    if (failed) return i < at ? 'done' : (i == at ? 'failed' : 'waiting');
    if (done) return 'done';
    return i < at ? 'done' : (i == at ? 'active' : 'waiting');
  }

  return [
    TimelineStep('Send the code to GitHub', st(0)),
    TimelineStep(check ? 'Check the code' : 'Build the app', st(1), note: b.phase == 'fixing' ? 'Fixing errors automatically' : (b.phase == 'queued' ? 'Waiting for GitHub to start' : '')),
    if (!check) TimelineStep('Download the app', st(2)),
    if (!check) TimelineStep('Install it on this phone', done ? 'active' : 'waiting', note: done ? 'Tap Install below' : ''),
  ];
}
