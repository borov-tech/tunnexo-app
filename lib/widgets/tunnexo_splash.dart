import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Tunnexo emblem (two open rings, a core dot and the exit line) drawn on a
/// 48x48 grid — the same geometry as the site/app SVG. [progress] 0..1 draws
/// it in: outer ring, inner ring, core, then the exit line.
class TunnexoEmblemPainter extends CustomPainter {
  TunnexoEmblemPainter({required this.progress});

  final double progress;

  static const _primary = Color(0xFFFF5A3C);
  static const _inner = Color(0xFF8A281B);
  static const _core = Color(0xFFFFE3D8);

  static double _seg(double t, double a, double b) =>
      ((t - a) / (b - a)).clamp(0.0, 1.0);

  @override
  void paint(Canvas canvas, Size size) {
    const deg = math.pi / 180;
    const c = Offset(24, 24);
    canvas.save();
    canvas.scale(size.width / 48.0, size.height / 48.0);

    Paint stroke(Color color) => Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.6
      ..strokeCap = StrokeCap.round
      ..color = color;

    final outer = Curves.easeOutCubic.transform(_seg(progress, 0.0, 0.55));
    if (outer > 0) {
      canvas.drawArc(Rect.fromCircle(center: c, radius: 19), -35 * deg,
          -290 * deg * outer, false, stroke(_primary));
    }
    final inner = Curves.easeOutCubic.transform(_seg(progress, 0.15, 0.65));
    if (inner > 0) {
      canvas.drawArc(Rect.fromCircle(center: c, radius: 12), -40 * deg,
          -280 * deg * inner, false, stroke(_inner));
    }
    final dot = Curves.easeOutBack.transform(_seg(progress, 0.45, 0.75));
    if (dot > 0) {
      canvas.drawCircle(c, 5.5 * dot, Paint()..color = _core);
    }
    final line = Curves.easeOutCubic.transform(_seg(progress, 0.6, 0.9));
    if (line > 0) {
      canvas.drawLine(
          const Offset(28, 24), Offset(28 + 16 * line, 24), stroke(_primary));
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(TunnexoEmblemPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

/// Launch splash: the emblem draws itself in, "TUNNEXO" fades up, then the
/// whole overlay fades away to reveal the app. Shown once per process start;
/// skipped when the system asks for reduced motion.
class TunnexoSplash extends StatefulWidget {
  const TunnexoSplash({super.key, required this.child});

  final Widget child;

  @override
  State<TunnexoSplash> createState() => _TunnexoSplashState();
}

class _TunnexoSplashState extends State<TunnexoSplash>
    with TickerProviderStateMixin {
  late final AnimationController _draw = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  );
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
  );
  bool _started = false;
  bool _done = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduce) {
      _done = true;
      return;
    }
    _run();
  }

  Future<void> _run() async {
    try {
      await _draw.forward().orCancel;
      await Future<void>.delayed(const Duration(milliseconds: 180));
      if (!mounted) return;
      await _fade.forward().orCancel;
    } on TickerCanceled {
      // disposed mid-animation
    }
    if (mounted) setState(() => _done = true);
  }

  @override
  void dispose() {
    _draw.dispose();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_done) return widget.child;
    return Stack(
      children: [
        widget.child,
        Positioned.fill(
          child: AnimatedBuilder(
            animation: Listenable.merge([_draw, _fade]),
            builder: (context, _) {
              final t = _draw.value;
              final title =
                  Curves.easeOut.transform(((t - 0.55) / 0.45).clamp(0.0, 1.0));
              return Opacity(
                opacity: 1 - Curves.easeIn.transform(_fade.value),
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: RadialGradient(
                      center: Alignment(0, -0.25),
                      radius: 0.9,
                      colors: [
                        Color(0xFF3A0A08),
                        Color(0xFF1E0102),
                        Color(0xFF160001),
                      ],
                      stops: [0, 0.55, 1],
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Transform.scale(
                        scale: 1 + 0.06 * _fade.value,
                        child: CustomPaint(
                          size: const Size(112, 112),
                          painter: TunnexoEmblemPainter(progress: t),
                        ),
                      ),
                      const SizedBox(height: 22),
                      Opacity(
                        opacity: title,
                        child: Transform.translate(
                          offset: Offset(0, 8 * (1 - title)),
                          child: Text(
                            'TUNNEXO',
                            style: TextStyle(
                              color: const Color(0xFFFDF3EA),
                              fontSize: 26,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 6 + 6 * (1 - title),
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
