import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/storage.dart';
import '../../state/updater.dart';
import '../screens/update_screen.dart';
import 'job_stepper.dart';

/// On the home screen: an update is available, downloading, waiting for Wi-Fi, or ready to install.
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final u = context.watch<UpdateService>();
    if (!u.visible) return const SizedBox.shrink();
    final info = u.latest!;
    final t = Theme.of(context);
    final s = t.colorScheme;
    final ready = u.status == UpdateStatus.ready || u.status == UpdateStatus.installing;
    final downloading = u.status == UpdateStatus.downloading;
    final (icon, title, sub) = switch (u.status) {
      UpdateStatus.ready || UpdateStatus.installing => (Icons.download_done_rounded, 'AIy ${info.versionName} is ready to install', 'Downloaded and checked'),
      UpdateStatus.downloading => (Icons.downloading_rounded, 'Downloading AIy ${info.versionName}', '${(u.progress * 100).round()}%${u.speedBps > 1 ? ' · ${StorageInfo.fmt(u.speedBps.round())}/s' : ''}${u.etaSec >= 0 ? ' · ${fmtSeconds(u.etaSec)} left' : ''}'),
      UpdateStatus.paused => (Icons.pause_circle_outline_rounded, 'Update paused', 'AIy ${info.versionName} · ${(u.progress * 100).round()}%'),
      _ when u.waiting.isNotEmpty => (Icons.wifi_rounded, 'AIy ${info.versionName} is waiting', u.waiting == 'offline' ? 'Waiting for the internet' : 'Waiting for Wi-Fi'),
      _ => (Icons.system_update_rounded, 'AIy ${info.versionName} is available', 'Tap for what is new'),
    };
    final tint = ready ? JobColors.done : s.primary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: Material(
        color: s.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const UpdateScreen())),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
            child: Column(children: [
              Row(children: [
                Container(width: 36, height: 36, decoration: BoxDecoration(color: tint.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(12)), child: Icon(icon, color: tint, size: 20)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, style: t.textTheme.titleSmall),
                    Text(sub, style: t.textTheme.bodySmall?.copyWith(color: s.onSurfaceVariant)),
                  ]),
                ),
                if (ready)
                  FilledButton(
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 38), padding: const EdgeInsets.symmetric(horizontal: 16), backgroundColor: JobColors.done, foregroundColor: const Color(0xFF0B0D14)),
                    onPressed: u.status == UpdateStatus.installing ? null : u.install,
                    child: const Text('Install'),
                  )
                else
                  Icon(Icons.chevron_right_rounded, color: s.onSurfaceVariant),
              ]),
              if (downloading) ...[const SizedBox(height: 8), ShineBar(value: u.total > 0 ? u.progress : null)],
            ]),
          ),
        ),
      ),
    );
  }
}
