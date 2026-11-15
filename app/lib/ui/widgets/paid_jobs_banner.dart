import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_builder.dart';
import '../../state/code_state.dart';
import '../../state/paid_jobs.dart';

/// Paid jobs that were waiting for the internet when AIy was closed. They are never continued by themselves:
/// the person sees the price again and taps Continue or Discard.
class PaidJobsBanner extends StatelessWidget {
  /// Switches the home screen to a tab (1 = Code, 2 = Build).
  final void Function(int tab) onOpen;
  const PaidJobsBanner({super.key, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final jobs = context.watch<PaidJobs>().leftOver;
    if (jobs.isEmpty) return const SizedBox.shrink();
    final s = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Column(children: [
      for (final j in jobs)
        Container(
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
          padding: const EdgeInsets.fromLTRB(14, 10, 8, 6),
          decoration: BoxDecoration(color: s.secondaryContainer, borderRadius: BorderRadius.circular(18)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Waiting for your OK', style: t.labelMedium?.copyWith(color: s.onSecondaryContainer)),
            const SizedBox(height: 2),
            Text(j.title, style: t.bodyMedium?.copyWith(color: s.onSecondaryContainer, fontWeight: FontWeight.w600), maxLines: 2, overflow: TextOverflow.ellipsis),
            Text('${j.modelName}: ${j.price}. Continuing sends it again at this price.', style: t.bodySmall?.copyWith(color: s.onSecondaryContainer)),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(onPressed: () => PaidJobs.instance.done(j.id), child: const Text('Discard')),
              FilledButton.tonal(
                onPressed: () {
                  if (j.kind == 'code') {
                    onOpen(1);
                    context.read<CodeState>().resumePaid(j);
                  } else {
                    onOpen(2);
                    context.read<AppBuilder>().resumePaid(j);
                  }
                },
                child: const Text('Continue'),
              ),
            ]),
          ]),
        ),
    ]);
  }
}
