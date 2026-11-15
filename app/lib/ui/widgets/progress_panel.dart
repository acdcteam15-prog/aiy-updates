import 'dart:async';

import 'package:flutter/material.dart';

import 'job_stepper.dart';

/// The job-page look for any work in progress: a card with an icon, a title, a shine bar and the steps.
/// [steps] are titles; [at] is the step running now; [live] is what is happening right now.
class ProgressPanel extends StatefulWidget {
  final IconData icon;
  final String title;
  final List<String> steps;
  final int at;
  final String live;

  /// A smaller card (for the chat), without the bar.
  final bool compact;
  const ProgressPanel({super.key, required this.icon, required this.title, required this.steps, required this.at, required this.live, this.compact = false});

  @override
  State<ProgressPanel> createState() => _ProgressPanelState();
}

class _ProgressPanelState extends State<ProgressPanel> {
  final Map<int, int> _start = {};
  final Map<int, int> _took = {};
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _start[widget.at] = DateTime.now().millisecondsSinceEpoch;
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(ProgressPanel old) {
    super.didUpdateWidget(old);
    if (old.at != widget.at || old.steps.length != widget.steps.length) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final s = _start[old.at];
      if (s != null && widget.at > old.at) _took[old.at] = now - s;
      _start.putIfAbsent(widget.at, () => now);
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  String _dur(int ms) {
    final s = (ms / 1000).round();
    return s < 60 ? '$s s' : '${s ~/ 60} min ${s % 60} s';
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = t.colorScheme;
    final now = DateTime.now().millisecondsSinceEpoch;
    final steps = <JobStep>[
      for (var i = 0; i < widget.steps.length; i++)
        JobStep(
          widget.steps[i],
          i < widget.at ? 'done' : (i == widget.at ? 'running' : 'waiting'),
          note: i < widget.at ? (_took[i] == null ? '' : _dur(_took[i]!)) : (i == widget.at && _start[i] != null ? '${_dur(now - _start[i]!)} so far' : ''),
          live: i == widget.at ? widget.live : '',
        ),
    ];
    final pct = widget.steps.isEmpty ? null : (widget.at / widget.steps.length).clamp(0.0, 1.0);
    return Container(
      padding: EdgeInsets.all(widget.compact ? 16 : 20),
      decoration: BoxDecoration(
        color: s.surfaceContainer,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: s.outlineVariant.withValues(alpha: 0.5)),
        boxShadow: widget.compact ? null : [BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 24, offset: const Offset(0, 8))],
      ),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (!widget.compact) ...[
          Row(children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: s.primary.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(12)),
              child: Icon(widget.icon, color: s.primary, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(widget.title, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
            if (pct != null && widget.steps.length > 1)
              TweenAnimationBuilder<double>(
                tween: Tween(end: pct),
                duration: const Duration(milliseconds: 500),
                builder: (_, v, __) => Text('${(v * 100).round()}%', style: t.textTheme.titleMedium?.copyWith(color: s.primary, fontWeight: FontWeight.w700)),
              ),
          ]),
          const SizedBox(height: 14),
          ShineBar(value: widget.steps.length > 1 ? (pct! + 0.5 / widget.steps.length) : null),
          const SizedBox(height: 16),
        ],
        JobStepper(steps: steps),
      ]),
    );
  }
}

/// The Code tab's work as steps, from what it says it is doing.
({List<String> steps, int at}) codeProgress(String busy) {
  final b = busy.toLowerCase();
  if (b.contains('writing the patch') || b.contains('asking') && b.contains('fix') || b.contains('building the new zip')) {
    const steps = ['Read the files', 'Write the change', 'Check and repair', 'Build the zip'];
    if (b.contains('building the new zip')) return (steps: steps, at: 3);
    if (b.contains('problem')) return (steps: steps, at: 2);
    return (steps: steps, at: 1);
  }
  if (b.startsWith('opening') || b.startsWith('downloading') || b.startsWith('looking inside') || b.startsWith('reading') || b.startsWith('mapping')) {
    const steps = ['Get the project', 'Read the files', 'Map the project'];
    if (b.startsWith('mapping') || b.startsWith('reading the project map')) return (steps: steps, at: 2);
    if (b.startsWith('reading') || b.startsWith('looking inside')) return (steps: steps, at: 1);
    return (steps: steps, at: 0);
  }
  if (b.startsWith('finding the files')) return (steps: const ['Pick the files to change', 'Write the change'], at: 0);
  return (steps: const ['Working'], at: 0);
}

/// The Build tab's work (writing an app) as steps, from its phase.
({List<String> steps, int at}) appProgress(String phase, String busy) {
  const steps = ['Plan the files', 'Write the code in parts', 'Link and check', 'Make the zip and icon'];
  return switch (phase) {
    'plan' => (steps: steps, at: 0),
    'write' => (steps: steps, at: 1),
    'check' => (steps: steps, at: 2),
    'zip' => (steps: steps, at: 3),
    _ => (steps: const ['Working'], at: 0),
  };
}
