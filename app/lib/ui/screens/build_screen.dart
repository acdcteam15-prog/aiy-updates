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
import '../widgets/build_steps.dart';
import '../widgets/job_stepper.dart';

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
                ShineBar(value: buildView(b).percent),
                const SizedBox(height: 10),
                Text('A build takes a few minutes. You can leave AIy: the build keeps running on GitHub, and AIy picks it up again when you come back.', style: sub),
              ],
            ]),
          ),
          // A failed build or check explains itself under the step where it stopped; other errors keep the box.
          if (b.error != null && !failed) ...[const SizedBox(height: 12), ErrorBox(b.error!, onClose: b.clearError)],
          if (running || done || failed) ...[
            const SizedBox(height: 12),
            Appear(
              child: StepCard(
                child: Builder(builder: (_) {
                  final v = buildView(b);
                  return JobStepper(steps: v.steps, error: v.error);
                }),
              ),
            ),
          ],
          if (b.steps.isNotEmpty) ...[
            const SizedBox(height: 12),
            Appear(
              child: StepCard(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                child: ExpansionTile(
                  // Folded by default: the big steps above say enough. Opens by itself when something failed.
                  key: ValueKey('details-${b.phase == 'failed'}'),
                  initiallyExpanded: b.phase == 'failed' || b.steps.any((s) => s.state == 'failed'),
                  shape: const Border(),
                  collapsedShape: const Border(),
                  title: Text('Details', style: t.textTheme.titleSmall),
                  subtitle: Text('${b.steps.where((s) => s.state == 'done').length} of ${b.steps.length} GitHub steps done${b.steps.any((s) => s.state == 'failed') ? ' · 1 failed' : ''}', style: t.textTheme.bodySmall),
                  childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  expandedCrossAxisAlignment: CrossAxisAlignment.start,
                  children: [
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
                              'skipped' => Icon(Icons.remove_rounded, key: const ValueKey('s'), size: 16, color: t.colorScheme.onSurfaceVariant),
                              _ => Icon(Icons.circle_outlined, key: const ValueKey('w'), size: 14, color: t.colorScheme.onSurfaceVariant),
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(child: Text(s.state == 'skipped' ? '${s.name} (not run)' : s.name, style: t.textTheme.bodyMedium?.copyWith(color: s.state == 'waiting' || s.state == 'skipped' ? t.colorScheme.onSurfaceVariant : null))),
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
        if (b.aiCannotFix) ...[
          Text(b.setupStepFailed.isNotEmpty
              ? 'GitHub\'s build setup failed ("${b.setupStepFailed}"). This is not a problem in your code, so "Fix it with AI" cannot help: tap "Update and build again" below.'
              : 'This is not a mistake in your code: ${b.environmentProblem}. "Fix it with AI" cannot solve it (it only sees your files), so it is switched off to save you money. Tap "Update and build again": AIy updates its build so plugins use a new enough Android version.', style: t.textTheme.bodyMedium),
          const SizedBox(height: 10),
        ],
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
          if (b.paused != null) ...[
            FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size(64, 46)),
              onPressed: () => b.continueFix(),
              icon: const Icon(Icons.play_arrow_rounded, size: 18),
              label: Text('Continue auto-fix (${b.paused!.rounds} round${b.paused!.rounds == 1 ? '' : 's'} left)'),
            ),
            TextButton(onPressed: b.dropPause, child: const Text('Stop auto-fix')),
          ],
          if (b.aiCannotFix)
            FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size(64, 46)),
              onPressed: () => b.rebuildAfterSetup(),
              icon: const Icon(Icons.restart_alt_rounded, size: 18),
              label: const Text('Update and build again'),
            ),
          if (b.paused == null && !b.aiCannotFix) FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size(64, 46)),
            onPressed: () async {
              final r = await showModalBottomSheet<(OrModel, int, OrModel?)>(context: context, isScrollControlled: true, useSafeArea: true, builder: (_) => const AutoFixSheet());
              if (r != null) b.autoFix(r.$1, r.$2, free: r.$3);
            },
            icon: const Icon(Icons.autorenew_rounded, size: 18),
            label: const Text('Fix and rebuild automatically'),
          ),
          if (!b.aiCannotFix) OutlinedButton.icon(
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
