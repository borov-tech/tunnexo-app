import 'package:flutter/material.dart';

/// Text whose digits roll like a drum when they change (e.g. 00:01:09 →
/// 00:01:10 rolls only the last two digits). Non-digit characters are drawn
/// statically. Falls back to plain [Text] when animations are disabled.
class RollingText extends StatelessWidget {
  const RollingText(
    this.text, {
    super.key,
    this.style,
    this.duration = const Duration(milliseconds: 320),
  });

  final String text;
  final TextStyle? style;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduce) return Text(text, style: style, maxLines: 1);
    final chars = text.characters.toList();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < chars.length; i++)
          _RollingChar(
            // Keyed by position counted from the end, so "9.9" → "10.0"
            // keeps the decimal places in place.
            key: ValueKey('rc${chars.length - i}'),
            char: chars[i],
            style: style,
            duration: duration,
          ),
      ],
    );
  }
}

class _RollingChar extends StatelessWidget {
  const _RollingChar({
    super.key,
    required this.char,
    required this.style,
    required this.duration,
  });

  final String char;
  final TextStyle? style;
  final Duration duration;

  static bool _isDigit(String c) =>
      c.length == 1 && c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x39;

  @override
  Widget build(BuildContext context) {
    final text = Text(char, key: ValueKey(char), style: style, maxLines: 1);
    if (!_isDigit(char)) return text;
    return ClipRect(
      child: AnimatedSwitcher(
        duration: duration,
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        layoutBuilder: (current, previous) => Stack(
          alignment: Alignment.center,
          children: [...previous, if (current != null) current],
        ),
        transitionBuilder: (child, animation) {
          final incoming = child.key == ValueKey(char);
          final offset = Tween<Offset>(
            begin: incoming ? const Offset(0, 1) : const Offset(0, -1),
            end: Offset.zero,
          ).animate(animation);
          return SlideTransition(
            position: offset,
            child: FadeTransition(opacity: animation, child: child),
          );
        },
        child: text,
      ),
    );
  }
}
