import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/native.dart';
import '../../state/storage.dart';
import '../../state/updater.dart';
import '../widgets/common.dart';
import '../widgets/fx.dart';
import '../widgets/job_stepper.dart';
import '../widgets/markdown.dart';

/// "1 min 20 s", "45 s".
String fmtSeconds(int s) {
  if (s < 0) return '';
  if (s < 60) return '$s s';
  if (s < 3600) return '${s ~/ 60} min ${s % 60} s';
  return '${s ~/ 3600} h ${(s % 3600) ~/ 60} min';
}

/// The update, in one place: what is new, how far the download is (size, speed, time left), pause and resume,
/// then Install. Also "Remind me tomorrow" and "Skip this version".
class UpdateScreen extends StatefulWidget {
  const UpdateScreen({super.key});
  @override
  State<UpdateScreen> createState() => _UpdateScreenState();
}

class _UpdateScreenState extends State<UpdateScreen> {
  @override
  void initState() {
    super.initState();
    // The "update is ready" notification needs Android's permission (asked once, a no-op when granted).
    Native.requestNotifications();
  }

  String _waitText(UpdateService u) => switch (u.waiting) {
        'cellular' => 'Waiting for Wi-Fi. Updates only download on Wi-Fi by themselves, so your mobile data is not used.',
        'metered' => 'This Wi-Fi is metered (a phone hotspot, for example), so AIy waits for a normal Wi-Fi.',
        'offline' => 'Waiting for the internet. It continues by itself from where it stopped.',
        'unknown' => 'AIy cannot tell whether you are on Wi-Fi, so it waits for you.',
        _ => '',
      };

  @override
  Widget build(BuildContext context) {
    final u = context.watch<UpdateService>();
    final t = Theme.of(context);
    final s = t.colorScheme;
    final info = u.latest;
    final sub = t.textTheme.bodySmall?.copyWith(color: s.onSurfaceVariant);
    if (info == null || !u.hasUpdate) {
      return Scaffold(
        appBar: AppBar(title: const Text('Update')),
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.check_circle_outline_rounded, size: 56, color: JobColors.done),
            const SizedBox(height: 12),
            Text('You have the newest version${u.installedName.isEmpty ? '' : ' (${u.installedName})'}.', style: t.textTheme.bodyLarge),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: u.busy ? null : () => u.check(), child: Text(u.status == UpdateStatus.checking ? 'Checking…' : 'Check again')),
          ]),
        ),
      );
    }
    final pct = (u.progress * 100).round();
    final steps = <JobStep>[
      const JobStep('Update found', 'done'),
      JobStep(
        'Download',
        u.status == UpdateStatus.ready || u.status == UpdateStatus.installing ? 'done' : (u.status == UpdateStatus.downloading ? 'running' : 'waiting'),
        note: u.status == UpdateStatus.downloading || u.status == UpdateStatus.paused
            ? '${StorageInfo.fmt(u.got)} of ${StorageInfo.fmt(u.total)}${u.speedBps > 1 && u.status == UpdateStatus.downloading ? ' · ${StorageInfo.fmt(u.speedBps.round())}/s' : ''}${u.etaSec >= 0 && u.status == UpdateStatus.downloading ? ' · about ${fmtSeconds(u.etaSec)} left' : ''}'
            : '',
        live: u.status == UpdateStatus.downloading ? 'AIy keeps downloading when you leave the app' : '',
      ),
      JobStep('Check the file', u.status == UpdateStatus.ready || u.status == UpdateStatus.installing ? 'done' : 'waiting', note: u.status == UpdateStatus.ready ? 'Size and SHA-256 match' : ''),
      JobStep('Install', u.status == UpdateStatus.installing ? 'running' : 'waiting'),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('Update')),
      body: Column(children: [
        Expanded(
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 16), children: [
            StepCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(color: s.primary.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(14)),
                    child: Icon(Icons.system_update_rounded, color: s.primary),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('AIy ${info.versionName}', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                      Text('${u.required ? 'Required update · ' : ''}You have ${u.installedName}${info.size > 0 ? ' · ${StorageInfo.fmt(info.size)}' : ''}', style: sub),
                    ]),
                  ),
                  if (u.status == UpdateStatus.downloading) Text('$pct%', style: t.textTheme.titleLarge?.copyWith(color: s.primary, fontWeight: FontWeight.w700)),
                ]),
                if (u.status == UpdateStatus.downloading || u.status == UpdateStatus.paused) ...[
                  const SizedBox(height: 16),
                  u.status == UpdateStatus.downloading ? ShineBar(value: u.total > 0 ? u.progress : null) : ShineBar(value: u.progress, color: s.outline),
                ],
                const SizedBox(height: 16),
                JobStepper(steps: steps),
                if (_waitText(u).isNotEmpty) ...[const SizedBox(height: 12), Text(_waitText(u), style: sub)],
                if (u.status == UpdateStatus.paused) ...[const SizedBox(height: 12), Text('Paused at $pct%. The part is kept: Resume continues from there.', style: sub)],
                if (u.status == UpdateStatus.error) ...[
                  const SizedBox(height: 12),
                  ErrorBox(u.error == 'corrupt' ? 'The download was damaged, so AIy threw it away. Tap Download to get it again.' : 'The update could not be downloaded: ${u.error}'),
                ],
                if (u.needsPermission)
                  Padding(padding: const EdgeInsets.only(top: 12), child: Text('Android needs your permission once: switch on "Allow from this source" for AIy, come back, and tap Install again.', style: sub?.copyWith(color: s.error))),
              ]),
            ),
            const SizedBox(height: 12),
            StepCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text("What's new in ${info.versionName}", style: t.textTheme.titleSmall),
                const SizedBox(height: 8),
                if (info.notes.trim().isEmpty) Text('No notes were published for this version.', style: sub) else MdText(info.notes),
              ]),
            ),
          ]),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                Expanded(child: _mainButton(u)),
              ]),
              if (!u.required) ...[
                const SizedBox(height: 4),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  TextButton(
                    onPressed: () async {
                      await u.remindLater();
                      if (context.mounted) {
                        Navigator.pop(context);
                        snack(context, 'AIy will remind you tomorrow.');
                      }
                    },
                    child: const Text('Remind me tomorrow'),
                  ),
                  TextButton(
                    onPressed: () async {
                      if (!await confirmDialog(context, 'Skip version ${info.versionName}?', body: 'AIy stops showing this version and downloads nothing for it. The next version is shown again. You can still update from Settings by tapping "Check for updates".', yes: 'Skip')) return;
                      await u.skip();
                      if (context.mounted) Navigator.pop(context);
                    },
                    child: const Text('Skip this version'),
                  ),
                ]),
              ],
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _mainButton(UpdateService u) {
    switch (u.status) {
      case UpdateStatus.ready:
        return FilledButton.icon(onPressed: u.install, icon: const Icon(Icons.download_done_rounded), label: const Text('Install'));
      case UpdateStatus.installing:
        return const FilledButton(onPressed: null, child: Text('Opening the installer…'));
      case UpdateStatus.downloading:
        return OutlinedButton.icon(onPressed: () => u.pause(), icon: const Icon(Icons.pause_rounded), label: const Text('Pause'));
      case UpdateStatus.paused:
        return FilledButton.icon(onPressed: u.resume, icon: const Icon(Icons.play_arrow_rounded), label: const Text('Resume'));
      default:
        final wifiWait = u.waiting == 'cellular' || u.waiting == 'metered' || u.waiting == 'unknown';
        return Column(mainAxisSize: MainAxisSize.min, children: [
          FilledButton.icon(
            onPressed: u.busy ? null : () => u.startDownload(mobileOk: wifiWait),
            icon: const Icon(Icons.download_rounded),
            label: Text(wifiWait ? 'Download now (uses mobile data)' : 'Download'),
          ),
        ]);
    }
  }
}
