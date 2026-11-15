import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/connectivity.dart';
import '../../state/prefs.dart';
import '../../state/slow_line.dart';

/// Shown at the top of the app while the internet is gone (with the requests that wait), while they are sent
/// again, and for a moment afterwards when something needs to be said.
class OfflineBanner extends StatefulWidget {
  const OfflineBanner({super.key});
  @override
  State<OfflineBanner> createState() => _OfflineBannerState();
}

class _OfflineBannerState extends State<OfflineBanner> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final c = context.watch<ConnectivityService>();
    final t = Theme.of(context);
    final s = t.colorScheme;
    final n = c.jobs.length;
    Widget? body;
    if (c.offline) {
      body = Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        decoration: BoxDecoration(color: s.errorContainer, borderRadius: BorderRadius.circular(18)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.wifi_off_rounded, size: 20, color: s.onErrorContainer),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('No internet connection', style: t.textTheme.titleSmall?.copyWith(color: s.onErrorContainer)),
                Text(
                  n == 0 ? 'AIy is waiting for the connection.' : (n == 1 ? '1 request is waiting. AIy sends it again by itself when the connection is back.' : '$n requests are waiting. AIy sends them again by itself when the connection is back.'),
                  style: t.textTheme.bodySmall?.copyWith(color: s.onErrorContainer),
                ),
              ]),
            ),
            TextButton(onPressed: c.nudge, child: const Text('Try now')),
            if (n > 0) IconButton(visualDensity: VisualDensity.compact, icon: Icon(_open ? Icons.expand_less_rounded : Icons.expand_more_rounded, color: s.onErrorContainer), onPressed: () => setState(() => _open = !_open)),
          ]),
          if (_open)
            for (final j in List.of(c.jobs))
              Padding(
                padding: const EdgeInsets.only(left: 30, top: 2),
                child: Row(children: [
                  Expanded(child: Text(j.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.bodyMedium?.copyWith(color: s.onErrorContainer))),
                  TextButton(onPressed: () => c.cancel(j), child: const Text('Cancel')),
                ]),
              ),
        ]),
      );
    } else if (c.resending) {
      body = Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(color: s.primaryContainer, borderRadius: BorderRadius.circular(18)),
        child: Row(children: [
          const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 12),
          Expanded(child: Text('The internet is back. Sending again…', style: t.textTheme.titleSmall?.copyWith(color: s.onPrimaryContainer))),
        ]),
      );
    } else if (c.note.isNotEmpty) {
      body = Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: s.primaryContainer, borderRadius: BorderRadius.circular(18)),
        child: Text(c.note, style: t.textTheme.bodySmall?.copyWith(color: s.onPrimaryContainer)),
      );
    }
    return AnimatedSize(duration: const Duration(milliseconds: 250), curve: Curves.easeOutCubic, alignment: Alignment.topCenter, child: body ?? const SizedBox(width: double.infinity));
  }
}

/// Offered when requests keep timing out: Lite mode sends less data. The person chooses.
class SlowLineBanner extends StatelessWidget {
  const SlowLineBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final slow = context.watch<SlowLine>();
    final net = context.watch<ConnectivityService>();
    final prefs = context.watch<LocalPrefs>();
    final t = Theme.of(context);
    final s = t.colorScheme;
    final show = slow.offer && !prefs.liteMode && !net.offline && !net.resending;
    return AnimatedSize(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: !show
          ? const SizedBox(width: double.infinity)
          : Container(
              margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
              padding: const EdgeInsets.fromLTRB(14, 10, 8, 6),
              decoration: BoxDecoration(color: s.tertiaryContainer, borderRadius: BorderRadius.circular(18)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(Icons.network_check_rounded, size: 20, color: s.onTertiaryContainer),
                  const SizedBox(width: 10),
                  Expanded(child: Text('The internet is slow', style: t.textTheme.titleSmall?.copyWith(color: s.onTertiaryContainer))),
                ]),
                Padding(
                  padding: const EdgeInsets.fromLTRB(30, 2, 8, 0),
                  child: Text('AIy now waits longer for answers. Lite mode sends less data (smaller photos, shorter history, no live search, shorter answers), so answers arrive sooner.', style: t.textTheme.bodySmall?.copyWith(color: s.onTertiaryContainer)),
                ),
                Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  TextButton(onPressed: slow.hideOffer, child: const Text('Keep waiting')),
                  FilledButton.tonal(
                    onPressed: () {
                      prefs.setLiteMode(true);
                      slow.hideOffer();
                    },
                    child: const Text('Turn on Lite mode'),
                  ),
                ]),
              ]),
            ),
    );
  }
}
