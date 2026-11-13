import 'package:flutter/material.dart';

import 'fx.dart';

/// One step of a [StepTimeline]. [state]: waiting, active, done or failed.
class TimelineStep {
  final String title;
  final String state;
  final String note;
  const TimelineStep(this.title, this.state, {this.note = ''});
}

/// A vertical list of steps joined by a line: done steps get a tick, the running one a small turning orb.
class StepTimeline extends StatelessWidget {
  final List<TimelineStep> steps;
  const StepTimeline(this.steps, {super.key});

  static const _green = Color(0xFF34C759);

  Widget _node(BuildContext context, TimelineStep s) {
    final scheme = Theme.of(context).colorScheme;
    Widget child;
    switch (s.state) {
      case 'done':
        child = const CircleAvatar(key: ValueKey('d'), radius: 11, backgroundColor: _green, child: Icon(Icons.check_rounded, size: 15, color: Colors.white));
      case 'failed':
        child = CircleAvatar(key: const ValueKey('f'), radius: 11, backgroundColor: scheme.error, child: Icon(Icons.close_rounded, size: 15, color: scheme.onError));
      case 'active':
        child = const SizedBox(key: ValueKey('a'), width: 26, height: 26, child: Orb(size: 26, mode: OrbMode.thinking));
      default:
        child = Container(
          key: const ValueKey('w'),
          width: 22,
          height: 22,
          decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: scheme.outlineVariant, width: 2)),
        );
    }
    return SizedBox(width: 26, height: 26, child: Center(child: AnimatedSwitcher(duration: const Duration(milliseconds: 260), transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c), child: child)));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = t.colorScheme;
    return Column(children: [
      for (var i = 0; i < steps.length; i++)
        IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SizedBox(
              width: 30,
              child: Column(children: [
                _node(context, steps[i]),
                if (i < steps.length - 1)
                  Expanded(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      width: 2,
                      margin: const EdgeInsets.symmetric(vertical: 3),
                      color: steps[i].state == 'done' ? _green : s.outlineVariant,
                    ),
                  ),
              ]),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(top: 2, bottom: i < steps.length - 1 ? 14 : 0),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(
                    steps[i].title,
                    style: t.textTheme.titleSmall?.copyWith(
                      color: steps[i].state == 'waiting' ? s.onSurfaceVariant : (steps[i].state == 'failed' ? s.error : null),
                      fontWeight: steps[i].state == 'active' ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                  if (steps[i].note.isNotEmpty) Text(steps[i].note, maxLines: 2, overflow: TextOverflow.ellipsis, style: t.textTheme.bodySmall?.copyWith(color: s.onSurfaceVariant)),
                ]),
              ),
            ),
          ]),
        ),
    ]);
  }
}
