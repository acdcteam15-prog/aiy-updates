import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/prefs.dart';
import '../theme.dart';

bool _still(BuildContext c) => MediaQuery.of(c).disableAnimations;

/// The living backdrop: a dark (or light) page with soft colour glows drifting at the bottom.
class AuroraBackground extends StatefulWidget {
  final Widget child;

  /// 0..1: how strong the glow is (the empty home screen glows more than a long chat).
  final double strength;
  const AuroraBackground({super.key, required this.child, this.strength = 1});
  @override
  State<AuroraBackground> createState() => _AuroraState();
}

class _AuroraState extends State<AuroraBackground> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 24));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_still(context)) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final glow = presetAt(context.watch<LocalPrefs>().preset).glow;
    final scheme = Theme.of(context).colorScheme;
    return Stack(children: [
      Positioned.fill(
        child: RepaintBoundary(
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: widget.strength),
            duration: const Duration(milliseconds: 700),
            curve: Curves.easeOutCubic,
            builder: (_, s, __) => AnimatedBuilder(
              animation: _c,
              builder: (_, __) => CustomPaint(painter: _AuroraPainter(_c.value, glow, scheme.surface, scheme.brightness == Brightness.dark, s)),
            ),
          ),
        ),
      ),
      widget.child,
    ]);
  }
}

class _AuroraPainter extends CustomPainter {
  final double t;
  final List<Color> glow;
  final Color base;
  final bool dark;
  final double strength;
  _AuroraPainter(this.t, this.glow, this.base, this.dark, this.strength);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = base);
    if (strength <= 0.01) return;
    final a = t * 2 * math.pi;
    final w = size.width, h = size.height;
    void blob(Color c, double x, double y, double r, double alpha) {
      final center = Offset(x, y);
      canvas.drawCircle(
        center,
        r,
        Paint()..shader = RadialGradient(colors: [c.withValues(alpha: alpha * strength), c.withValues(alpha: 0)]).createShader(Rect.fromCircle(center: center, radius: r)),
      );
    }

    final k = dark ? 0.55 : 0.28;
    blob(glow[0], w * (0.20 + 0.10 * math.sin(a)), h * (1.02 + 0.03 * math.cos(a)), w * 0.95, k);
    blob(glow[1], w * (0.80 + 0.10 * math.cos(a * 2)), h * (1.05 + 0.04 * math.sin(a)), w * 0.90, k);
    blob(glow[2], w * (0.50 + 0.22 * math.sin(a + 1.3)), h * (1.12 + 0.03 * math.sin(a * 2)), w * 0.75, k * 0.8);
  }

  @override
  bool shouldRepaint(_AuroraPainter o) => o.t != t || o.strength != strength || o.base != base || o.glow != glow;
}

/// What the orb is doing: it looks different for each state so the person can tell at a glance.
enum OrbMode { idle, listening, thinking, writing, speaking }

/// AIy's mark: a softly breathing orb with a slowly turning colour ring.
/// idle: slow turn. listening: rings spread out like sound waves. thinking: fast spin and a pulsing glow.
/// writing: steady turn with a bigger moving dot. speaking: the orb swells and shrinks like a voice.
class Orb extends StatefulWidget {
  final double size;

  /// Old way of saying [OrbMode.thinking].
  final bool busy;
  final OrbMode? mode;
  const Orb({super.key, this.size = 72, this.busy = false, this.mode});
  OrbMode get effective => mode ?? (busy ? OrbMode.thinking : OrbMode.idle);
  @override
  State<Orb> createState() => _OrbState();
}

class _OrbState extends State<Orb> with TickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 6));
  late final AnimationController _p = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500));

  static int _turnMs(OrbMode m) => switch (m) {
        OrbMode.idle => 6000,
        OrbMode.thinking => 1400,
        OrbMode.writing => 2600,
        OrbMode.listening => 4200,
        OrbMode.speaking => 3200,
      };

  void _sync() {
    if (_still(context)) {
      _c.stop();
      _p.stop();
      return;
    }
    final m = widget.effective;
    _c.duration = Duration(milliseconds: _turnMs(m));
    _c.repeat();
    _p.duration = Duration(milliseconds: m == OrbMode.speaking ? 1100 : 1700);
    if (m == OrbMode.idle) {
      _p.stop();
    } else {
      _p.repeat();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(Orb old) {
    super.didUpdateWidget(old);
    if (old.effective != widget.effective) _sync();
  }

  @override
  void dispose() {
    _c.dispose();
    _p.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final glow = presetAt(context.watch<LocalPrefs>().preset).glow;
    final mode = widget.effective;
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(animation: Listenable.merge([_c, _p]), builder: (_, __) => CustomPaint(painter: _OrbPainter(_c.value, _p.value, glow, mode))),
    );
  }
}

class _OrbPainter extends CustomPainter {
  final double t;
  final double p;
  final List<Color> glow;
  final OrbMode mode;
  _OrbPainter(this.t, this.p, this.glow, this.mode);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final two = 2 * math.pi;
    var breathe = 1 + 0.04 * math.sin(t * two);
    var halo = 0.35;
    var dot = 0.16;
    var ring = 0.34;
    if (mode == OrbMode.speaking) {
      // an uneven swell, like a voice
      breathe = 1 + 0.075 * math.sin(p * two * 2) * (0.65 + 0.35 * math.sin(p * two * 3 + 1));
      halo = 0.42;
      ring = 0.34 + 0.06 * math.sin(p * two * 2);
    } else if (mode == OrbMode.thinking) {
      halo = 0.28 + 0.22 * (0.5 + 0.5 * math.sin(p * two));
    } else if (mode == OrbMode.writing) {
      dot = 0.2;
      halo = 0.32 + 0.1 * math.sin(p * two);
    }
    // keeps the swelling orb inside its own square
    final r = size.width / 2 * (mode == OrbMode.listening ? 0.72 : 0.86) * breathe;
    final rect = Rect.fromCircle(center: c, radius: r);
    // soft halo
    canvas.drawCircle(c, size.width / 2, Paint()..shader = RadialGradient(colors: [glow[1].withValues(alpha: halo), glow[1].withValues(alpha: 0)], stops: const [0.55, 1]).createShader(Rect.fromCircle(center: c, radius: size.width / 2)));
    // sound waves while listening
    if (mode == OrbMode.listening) {
      for (final off in const [0.0, 0.5]) {
        final f = (p + off) % 1.0;
        final rr = r * (1.0 + 0.38 * f);
        canvas.drawCircle(
          c,
          rr,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = math.max(1.2, r * 0.06)
            ..color = glow[2].withValues(alpha: (1 - f) * 0.7),
        );
      }
    }
    // turning colour ring
    canvas.drawCircle(
      c,
      r * 0.80,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * ring
        ..shader = SweepGradient(colors: [glow[1], glow[2], Colors.white, glow[0], glow[1]], transform: GradientRotation(t * two)).createShader(rect),
    );
    // the small orbiting dot
    final a = -t * two - math.pi / 4;
    canvas.drawCircle(c + Offset(math.cos(a), math.sin(a)) * (r * 0.80), r * dot, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_OrbPainter o) => o.t != t || o.p != p || o.glow != glow || o.mode != mode;
}

/// Fades and slides its child in once (use [delay] to stagger a list).
class Appear extends StatelessWidget {
  final Widget child;
  final int delay;
  final double dy;
  const Appear({super.key, required this.child, this.delay = 0, this.dy = 18});

  @override
  Widget build(BuildContext context) {
    if (_still(context)) return child;
    final total = 420 + delay;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: total),
      builder: (_, v, c) {
        final p = Curves.easeOutCubic.transform(((v * total - delay) / 420).clamp(0.0, 1.0));
        return Opacity(opacity: p, child: Transform.translate(offset: Offset(0, (1 - p) * dy), child: c));
      },
      child: child,
    );
  }
}

/// Shrinks a little while pressed, like a physical button.
class Pressable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  const Pressable({super.key, required this.child, this.onTap, this.onLongPress});
  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;
  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: widget.onTap == null ? null : (_) => setState(() => _down = true),
        onTapCancel: () => setState(() => _down = false),
        onTapUp: (_) => setState(() => _down = false),
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        child: AnimatedScale(scale: _down ? 0.96 : 1, duration: const Duration(milliseconds: 110), child: widget.child),
      );
}

/// Three dots that pulse one after another ("AIy is thinking").
class ThinkingDots extends StatefulWidget {
  const ThinkingDots({super.key});
  @override
  State<ThinkingDots> createState() => _ThinkingDotsState();
}

class _ThinkingDotsState extends State<ThinkingDots> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) => Row(mainAxisSize: MainAxisSize.min, children: [
        for (var i = 0; i < 3; i++)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: Opacity(
              opacity: 0.3 + 0.7 * (0.5 + 0.5 * math.sin((_c.value - i * 0.18) * 2 * math.pi)),
              child: CircleAvatar(radius: 4, backgroundColor: color),
            ),
          ),
      ]),
    );
  }
}

/// A card with the app's rounded shape that animates its size when its content changes.
class StepCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final Color? color;
  const StepCard({super.key, required this.child, this.padding = const EdgeInsets.all(18), this.color});
  @override
  Widget build(BuildContext context) => Card(
        color: color ?? Theme.of(context).colorScheme.surfaceContainerHigh.withValues(alpha: 0.92),
        clipBehavior: Clip.antiAlias,
        child: AnimatedSize(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: Padding(padding: padding, child: child),
        ),
      );
}
