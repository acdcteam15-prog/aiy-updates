import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/build_state.dart';
import '../../state/code_state.dart';
import '../../state/keys.dart';
import '../../state/native.dart';
import '../../state/prefs.dart';
import '../widgets/common.dart';
import 'build_screen.dart';
import 'connect_screen.dart';
import 'publish_sheet.dart';
import '../../state/app_log.dart';

/// "Publish": push the current project to GitHub, then build the app there. Used under a finished change
/// (Code tab) and under a freshly written app (Build tab).
class PublishPanel extends StatefulWidget {
  const PublishPanel({super.key});
  @override
  State<PublishPanel> createState() => _PublishPanelState();
}

class _PublishPanelState extends State<PublishPanel> {
  Future<void> _push(CodeState code, BuildState b) async {
    final keys = context.read<KeyVault>();
    var name = code.sourceName.replaceAll(RegExp(r'\.zip$', caseSensitive: false), '').replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    if (name.isEmpty) name = 'my-project';
    final plan = await showModalBottomSheet<PushPlan>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => PushSheet(token: keys.get('github'), currentRepo: code.repo, currentBranch: code.branch, suggestedName: name),
    );
    if (plan != null) await b.push(plan);
  }

  void _check(BuildState b) {
    Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const BuildScreen()));
    unawaited(b.check());
  }

  Future<void> _build(CodeState code, BuildState b) async {
    final prefs = context.read<LocalPrefs>();
    // The Code list can rebuild this panel while GitHub is being checked (the panel's state is then replaced),
    // which made "Build the app" stop silently. The navigator outlives it, so the rest uses the navigator.
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    AppLog.i('build: checking ${b.repo} (${b.branch})');
    final prep = await b.prepare();
    if (prep == null) {
      AppLog.i('build: not ready: ${b.error ?? 'no reason given'}');
      if (b.error == null) messenger.showSnackBar(const SnackBar(content: Text('AIy could not get the build ready. Open Settings > Log and send it to the developer.')));
      return;
    }
    AppLog.i('build: ready (${prep.kind.name}, workflow ${prep.workflow}${prep.addWorkflow ? ', will be added/updated' : ''})');
    if (!nav.mounted) return;
    if (prep.relaxed != null) {
      // The project's own workflow has the Android SDK setup step that fails on GitHub: ask before changing it.
      prep.fixSetup = await confirmDialog(
        nav.context,
        'Fix the build setup?',
        body: 'This project builds with its own ${prep.workflow}. Its "setup-android" step fails on GitHub now (the old "tools" package was removed), '
            'although GitHub\'s computers already have the Android tools. AIy can add one line ("continue-on-error: true") so that step can no longer stop the build. Nothing else changes.',
        yes: 'Fix it',
        no: 'Leave it',
      );
      if (!nav.mounted) return;
    }
    final sel = await showModalBottomSheet<(String, String, bool)>(
      context: nav.context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => VersionSheet(current: prep.version?.name, foundIn: prep.version?.path, notes: code.summary, release: prefs.publishRelease),
    );
    if (sel == null) {
      AppLog.i('build: version question closed without a choice');
      return;
    }
    await prefs.setPublishRelease(sel.$3);
    if (!nav.mounted) return;
    unawaited(nav.push(MaterialPageRoute<void>(builder: (_) => const BuildScreen())));
    unawaited(b.start(prep, versionName: sel.$1, releaseNotes: sel.$2, release: sel.$3));
  }

  /// The "Publish" part of the result: push to GitHub, then build the app there.
  List<Widget> _publish(CodeState code, BuildState b, ThemeData t) {
    final sub = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final hasGh = context.watch<KeyVault>().has('github');
    final working = b.phase == 'pushing' || b.phase == 'preparing';
    return [
      Text('Publish', style: t.textTheme.titleSmall),
      const SizedBox(height: 8),
      if (!hasGh) ...[
        Text('Connect GitHub to send the change to your repository and build the app there.', style: sub),
        const SizedBox(height: 8),
        OutlinedButton(onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const ConnectScreen())), child: const Text('Connect GitHub')),
      ] else if (!b.pushed) ...[
        FilledButton.tonalIcon(
          style: FilledButton.styleFrom(minimumSize: const Size(64, 46)),
          onPressed: code.isBusy || b.running ? null : () => _push(code, b),
          icon: const Icon(Icons.cloud_upload_outlined, size: 18),
          label: const Text('Push to GitHub'),
        ),
        Padding(padding: const EdgeInsets.only(top: 6), child: Text('Sends the changed files to your repository. After that you can build the app there.', style: sub)),
      ] else ...[
        Row(children: [
          const Icon(Icons.check_circle_rounded, size: 18, color: Color(0xFF34C759)),
          const SizedBox(width: 8),
          Expanded(child: Text('Pushed to ${b.repo} (${b.branch})', style: t.textTheme.bodyMedium)),
        ]),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size(64, 46)),
            onPressed: b.running ? null : () => _build(code, b),
            icon: const Icon(Icons.rocket_launch_rounded, size: 18),
            label: const Text('Build the app'),
          ),
          OutlinedButton.icon(onPressed: b.running ? null : () => _check(b), icon: const Icon(Icons.fact_check_outlined, size: 18), label: const Text('Quick check')),
          if (b.branch != b.base && b.prUrl.isEmpty) OutlinedButton.icon(onPressed: b.running ? null : b.openPullRequest, icon: const Icon(Icons.merge_rounded, size: 18), label: const Text('Open a pull request')),
          if (b.prUrl.isNotEmpty) OutlinedButton.icon(onPressed: () => Native.openUrl(b.prUrl), icon: const Icon(Icons.open_in_new_rounded, size: 18), label: const Text('View the pull request')),
          TextButton(onPressed: () => Native.openUrl('https://github.com/${b.repo}/tree/${b.branch}'), child: const Text('Open on GitHub')),
          if (b.canUndo)
            TextButton(
              onPressed: () async {
                if (await confirmDialog(context, 'Undo the push?', body: 'The branch goes back to how it was before AIy pushed this change.', yes: 'Undo')) b.undoPush();
              },
              child: const Text('Undo the push'),
            ),
          TextButton(onPressed: () => _push(code, b), child: const Text('Push somewhere else')),
        ]),
        Padding(padding: const EdgeInsets.only(top: 6), child: Text('"Quick check" compiles the code on GitHub in about 2 minutes, without building the APK. "Build the app" asks for the version, writes it into the project, then builds the APK.', style: sub)),
      ],
      if (working) Padding(padding: const EdgeInsets.only(top: 10), child: LinearProgressIndicator(value: b.progress > 0 ? b.progress : null, borderRadius: BorderRadius.circular(8))),
      if (working && b.status.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text(b.status, style: sub)),
      if (b.error != null && b.phase != 'failed') Padding(padding: const EdgeInsets.only(top: 10), child: ErrorBox(b.error!, onClose: b.clearError)),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final code = context.watch<CodeState>();
    final b = context.watch<BuildState>();
    final t = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: _publish(code, b, t));
  }
}
