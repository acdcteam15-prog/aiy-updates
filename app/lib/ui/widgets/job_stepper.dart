import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Colours of the job pages: green for done, the theme's primary for running, orange for an error.
/// Orange (not red) also stands apart from green for colour-blind people, and differs in lightness.
class JobColors {
  static const done = Color(0xFF3DDC97);
  static const error = Color(0xFFFF8A4C);
  static const errorSoft = Color(0xFFFFB08A);
}

/// One step of a job. [state]: 'done', 'running', 'failed', 'waiting' or 'skipped' (not reached after a failure).
class JobStep {
  final String title;
  final String state;
  final String note;

  /// A live line under the running step (what is happening right now), shown in a small console box.
  final String live;
  const JobStep(this.title, this.state, {this.note = '', this.live = ''});
}

/// Why a job stopped, shown directly under the step that failed.
class JobError {
  final String what;
  final String where; // file:line and the message, '' when unknown
  final String todo;
  const JobError({required this.what, this.where = '', this.todo = ''});
}

/// The vertical step list of one job: ticks, a pulsing spinner on the running step, a shaking cross and an
/// error card on the step that failed, and dashed "not reached" steps after it.
class JobStepper extends StatelessWidget {
  final List<JobStep> steps;
  final JobError? error;
  const JobStepper({super.key, required this.steps, this.error});

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      for (var i = 0; i < steps.length; i++)
        _StepRow(
          step: steps[i],
          last: i == steps.length - 1,
          next: i + 1 < steps.length ? steps[i + 1].state : '',
          error: steps[i].state == 'failed' ? error : null,
        ),
    ]);
  }
}

class _StepRow extends StatelessWidget {
  final JobStep step;
  final bool last;
  final String next;
  final JobError? error;
  const _StepRow({required this.step, required this.last, required this.next, this.error});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = t.colorScheme;
    final sub = t.textTheme.bodySmall?.copyWith(color: s.onSurfaceVariant);
    final faded = step.state == 'skipped' || step.state == 'waiting';
    final lineColor = switch (step.state) {
      'done' => next == 'failed' ? null : (next == 'running' ? null : JobColors.done),
      _ => s.outlineVariant,
    };
    final gradient = step.state == 'done' && next == 'running'
        ? LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [JobColors.done, s.primary])
        : (step.state == 'done' && next == 'failed' ? const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [JobColors.done, JobColors.error]) : null);
    final dashed = step.state == 'failed' || step.state == 'skipped';
    return Opacity(
      opacity: step.state == 'skipped' ? 0.5 : 1,
      child: IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(
            width: 30,
            child: Column(children: [
              _Node(state: step.state),
              if (!last)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: dashed
                        ? CustomPaint(painter: _Dashes(s.outlineVariant), child: const SizedBox(width: 2))
                        : Container(width: 2, decoration: BoxDecoration(color: gradient == null ? lineColor : null, gradient: gradient, borderRadius: BorderRadius.circular(1))),
                  ),
                ),
            ]),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(top: 4, bottom: last ? 0 : 16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(
                    child: Text(
                      step.state == 'failed' ? '${step.title}: failed' : step.title,
                      style: t.textTheme.titleSmall?.copyWith(
                        color: step.state == 'failed' ? JobColors.errorSoft : (faded ? s.onSurfaceVariant : null),
                        fontWeight: faded ? FontWeight.w500 : FontWeight.w600,
                      ),
                    ),
                  ),
                  if (step.state == 'running') ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(color: s.primary.withValues(alpha: 0.22), borderRadius: BorderRadius.circular(10)),
                      child: Text('Now', style: t.textTheme.labelSmall?.copyWith(color: s.primary, fontWeight: FontWeight.w700)),
                    ),
                  ],
                ]),
                if (step.state == 'skipped') Text('Not reached', style: sub),
                if (step.note.isNotEmpty && step.state != 'skipped') Text(step.note, style: sub),
                if (step.live.isNotEmpty && step.state == 'running') ...[const SizedBox(height: 8), _LiveLine(step.live)],
                if (error != null) ...[const SizedBox(height: 10), _ErrorCard(error!)],
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

/// The circle of a step. Running: pulsing ring and a turning arc. Failed: a cross that shakes once.
class _Node extends StatefulWidget {
  final String state;
  const _Node({required this.state});
  @override
  State<_Node> createState() => _NodeState();
}

class _NodeState extends State<_Node> with TickerProviderStateMixin {
  late final AnimationController _loop = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));
  late final AnimationController _shake = AnimationController(vsync: this, duration: const Duration(milliseconds: 600));

  @override
  void initState() {
    super.initState();
    _sync(null);
  }

  @override
  void didUpdateWidget(_Node old) {
    super.didUpdateWidget(old);
    _sync(old.state);
  }

  void _sync(String? before) {
    final reduce = WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.disableAnimations;
    if (widget.state == 'running' && !reduce) {
      if (!_loop.isAnimating) _loop.repeat();
    } else {
      _loop.stop();
    }
    if (widget.state == 'failed' && before != 'failed' && !reduce) _shake.forward(from: 0);
  }

  @override
  void dispose() {
    _loop.dispose();
    _shake.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    Widget circle(Color bg, Widget child) => Container(width: 28, height: 28, decoration: BoxDecoration(color: bg, shape: BoxShape.circle), alignment: Alignment.center, child: child);
    final Widget node = switch (widget.state) {
      'done' => TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.4, end: 1),
          duration: const Duration(milliseconds: 450),
          curve: Curves.easeOutBack,
          builder: (_, v, c) => Transform.scale(scale: v, child: c),
          child: circle(JobColors.done, const Icon(Icons.check_rounded, size: 17, color: Color(0xFF0B0D14))),
        ),
      'running' => AnimatedBuilder(
          animation: _loop,
          builder: (_, __) {
            final v = _loop.value;
            return SizedBox(
              width: 28,
              height: 28,
              child: Stack(clipBehavior: Clip.none, alignment: Alignment.center, children: [
                // the ring that grows and fades
                Container(
                  width: 28 + 16 * v,
                  height: 28 + 16 * v,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: s.primary.withValues(alpha: 0.35 * (1 - v))),
                ),
                circle(s.primary, Transform.rotate(angle: v * 2 * math.pi * 1.5, child: CustomPaint(size: const Size(16, 16), painter: _Arc(s.onPrimary)))),
              ]),
            );
          },
        ),
      'failed' => AnimatedBuilder(
          animation: _shake,
          builder: (_, c) => Transform.translate(offset: Offset(math.sin(_shake.value * math.pi * 5) * 4 * (1 - _shake.value), 0), child: c),
          child: circle(JobColors.error, const Icon(Icons.close_rounded, size: 17, color: Color(0xFF1A0E08))),
        ),
      'skipped' => _hollow(s, dashed: true),
      _ => _hollow(s),
    };
    return AnimatedSwitcher(duration: const Duration(milliseconds: 250), child: KeyedSubtree(key: ValueKey(widget.state), child: node));
  }

  Widget _hollow(ColorScheme s, {bool dashed = false}) => SizedBox(
        width: 28,
        height: 28,
        child: Center(child: CustomPaint(size: const Size(22, 22), painter: _Ring(s.outlineVariant, dashed))),
      );
}

class _Arc extends CustomPainter {
  final Color c;
  _Arc(this.c);
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = c
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.6
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(Offset.zero & size, 0, math.pi * 1.4, false, p);
  }

  @override
  bool shouldRepaint(_Arc o) => o.c != c;
}

class _Ring extends CustomPainter {
  final Color c;
  final bool dashed;
  _Ring(this.c, this.dashed);
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = c
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final r = Offset.zero & size;
    if (!dashed) {
      canvas.drawOval(r.deflate(1), p);
      return;
    }
    const n = 10;
    for (var i = 0; i < n; i++) {
      canvas.drawArc(r.deflate(1), i * 2 * math.pi / n, math.pi / n, false, p);
    }
  }

  @override
  bool shouldRepaint(_Ring o) => o.c != c || o.dashed != dashed;
}

class _Dashes extends CustomPainter {
  final Color c;
  _Dashes(this.c);
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = c
      ..strokeWidth = 2;
    for (var y = 0.0; y < size.height; y += 8) {
      canvas.drawLine(Offset(size.width / 2, y), Offset(size.width / 2, math.min(y + 4, size.height)), p);
    }
  }

  @override
  bool shouldRepaint(_Dashes o) => o.c != c;
}

/// "Gradle › compiling…" with a blinking cursor.
class _LiveLine extends StatefulWidget {
  final String text;
  const _LiveLine(this.text);
  @override
  State<_LiveLine> createState() => _LiveLineState();
}

class _LiveLineState extends State<_LiveLine> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(color: s.surfaceContainerLowest, borderRadius: BorderRadius.circular(12)),
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) => Text.rich(
          TextSpan(children: [
            TextSpan(text: widget.text),
            TextSpan(text: ' ▍', style: TextStyle(color: _c.value < 0.5 ? s.primary : Colors.transparent)),
          ]),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: s.onSurfaceVariant, height: 1.4),
        ),
      ),
    );
  }
}

/// The card under the failed step: what happened, where, what to do. It glows softly.
class _ErrorCard extends StatefulWidget {
  final JobError e;
  const _ErrorCard(this.e);
  @override
  State<_ErrorCard> createState() => _ErrorCardState();
}

class _ErrorCardState extends State<_ErrorCard> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400))..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;
    final bg = dark ? const Color(0xFF22150F) : const Color(0xFFFFF1EA);
    final border = dark ? const Color(0xFF5A2E1A) : const Color(0xFFF5C3A8);
    final head = dark ? JobColors.errorSoft : const Color(0xFFA2400F);
    final text = dark ? const Color(0xFFF2E6E0) : const Color(0xFF3A1E10);
    final label = t.textTheme.labelSmall?.copyWith(color: head, fontWeight: FontWeight.w700, letterSpacing: 0.8);
    return AnimatedBuilder(
      animation: _c,
      builder: (_, child) => Container(
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: border),
          boxShadow: [BoxShadow(color: JobColors.error.withValues(alpha: 0.18 * _c.value), blurRadius: 0, spreadRadius: 5 * _c.value)],
        ),
        padding: const EdgeInsets.all(14),
        child: child,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('WHAT HAPPENED', style: label),
        const SizedBox(height: 4),
        SelectableText(widget.e.what, style: t.textTheme.bodyMedium?.copyWith(color: text, height: 1.45)),
        if (widget.e.where.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(color: dark ? const Color(0xFF140C08) : const Color(0xFFFBE2D4), borderRadius: BorderRadius.circular(10)),
            child: SelectableText(widget.e.where, style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: dark ? const Color(0xFFFFCFB6) : const Color(0xFF6B2A08))),
          ),
        ],
        if (widget.e.todo.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text('WHAT YOU CAN DO', style: label),
          const SizedBox(height: 4),
          Text(widget.e.todo, style: t.textTheme.bodySmall?.copyWith(color: text, height: 1.45)),
        ],
      ]),
    );
  }
}

/// A progress bar with a moving shine. [value] null = unknown (the shine runs over the whole bar).
class ShineBar extends StatefulWidget {
  final double? value;
  final Color? color;
  const ShineBar({super.key, this.value, this.color});
  @override
  State<ShineBar> createState() => _ShineBarState();
}

class _ShineBarState extends State<ShineBar> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final color = widget.color ?? s.primary;
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        height: 8,
        child: LayoutBuilder(builder: (_, box) {
          final w = box.maxWidth * (widget.value ?? 1).clamp(0.0, 1.0);
          return Stack(children: [
            Container(color: s.surfaceContainerHighest),
            AnimatedContainer(
              duration: const Duration(milliseconds: 500),
              curve: Curves.easeOutCubic,
              width: w,
              color: widget.value == null ? color.withValues(alpha: 0.35) : color,
            ),
            AnimatedBuilder(
              animation: _c,
              builder: (_, __) => Positioned(
                left: -w * 0.4 + (w * 1.4) * _c.value,
                top: 0,
                bottom: 0,
                width: w * 0.4,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: [Colors.white.withValues(alpha: 0), Colors.white.withValues(alpha: 0.4), Colors.white.withValues(alpha: 0)]),
                  ),
                ),
              ),
            ),
          ]);
        }),
      ),
    );
  }
}

/// The big tick of a finished job: it pops in and draws itself, with a ring that fades out.
class DoneBadge extends StatelessWidget {
  final double size;
  const DoneBadge({super.key, this.size = 96});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 1400),
      builder: (_, v, __) {
        final pop = Curves.easeOutBack.transform((v / 0.45).clamp(0.0, 1.0));
        final draw = Curves.easeOut.transform(((v - 0.3) / 0.35).clamp(0.0, 1.0));
        final ring = ((v - 0.35) / 0.65).clamp(0.0, 1.0);
        return SizedBox(
          width: size * 1.6,
          height: size * 1.6,
          child: Stack(alignment: Alignment.center, children: [
            Container(
              width: size * (1 + 0.6 * ring),
              height: size * (1 + 0.6 * ring),
              decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: JobColors.done.withValues(alpha: 0.7 * (1 - ring)), width: 2)),
            ),
            Transform.scale(
              scale: pop,
              child: Container(
                width: size,
                height: size,
                decoration: const BoxDecoration(color: JobColors.done, shape: BoxShape.circle),
                child: CustomPaint(painter: _Tick(draw)),
              ),
            ),
          ]),
        );
      },
    );
  }
}

class _Tick extends CustomPainter {
  final double t;
  _Tick(this.t);
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = const Color(0xFF0B0D14)
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.09
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final a = Offset(size.width * 0.28, size.height * 0.52);
    final b = Offset(size.width * 0.44, size.height * 0.67);
    final c = Offset(size.width * 0.73, size.height * 0.36);
    final l1 = (b - a).distance, l2 = (c - b).distance;
    final len = (l1 + l2) * t;
    final path = Path()..moveTo(a.dx, a.dy);
    if (len <= l1) {
      final e = a + (b - a) * (len / l1);
      path.lineTo(e.dx, e.dy);
    } else {
      path.lineTo(b.dx, b.dy);
      final e = b + (c - b) * ((len - l1) / l2);
      path.lineTo(e.dx, e.dy);
    }
    if (t > 0) canvas.drawPath(path, p);
  }

  @override
  bool shouldRepaint(_Tick o) => o.t != t;
}
