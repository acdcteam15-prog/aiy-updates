import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../state/native.dart';
import '../theme.dart';

/// A small Markdown renderer for AI answers: headings, lists, **bold**, `code`, links and code blocks
/// (with a copy button). Enough for chat, with no extra package.
class MdText extends StatefulWidget {
  final String data;
  const MdText(this.data, {super.key});
  @override
  State<MdText> createState() => _MdTextState();
}

class _MdTextState extends State<MdText> {
  final List<TapGestureRecognizer> _taps = [];

  void _clear() {
    for (final t in _taps) {
      t.dispose();
    }
    _taps.clear();
  }

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  static final _inline = RegExp(r'\*\*(.+?)\*\*|`([^`\n]+)`|\[([^\]\n]+)\]\((https?://[^)\s]+)\)|(https?://[^\s<>)\]]+)');

  List<InlineSpan> _spans(String text, ThemeData th) {
    final out = <InlineSpan>[];
    var at = 0;
    for (final m in _inline.allMatches(text)) {
      if (m.start > at) out.add(TextSpan(text: text.substring(at, m.start)));
      if (m.group(1) != null) {
        out.add(TextSpan(text: m.group(1), style: const TextStyle(fontWeight: FontWeight.w700)));
      } else if (m.group(2) != null) {
        out.add(TextSpan(text: m.group(2), style: TextStyle(fontFamily: kMono, fontSize: 13.5, backgroundColor: th.colorScheme.surfaceContainerHighest)));
      } else {
        final url = m.group(4) ?? m.group(5)!;
        final tap = TapGestureRecognizer()..onTap = () => Native.openUrl(url);
        _taps.add(tap);
        out.add(TextSpan(text: m.group(3) ?? url, style: TextStyle(color: th.colorScheme.primary, decoration: TextDecoration.underline), recognizer: tap));
      }
      at = m.end;
    }
    if (at < text.length) out.add(TextSpan(text: text.substring(at)));
    return out;
  }

  @override
  Widget build(BuildContext context) {
    _clear();
    final th = Theme.of(context);
    final body = th.textTheme.bodyLarge!.copyWith(height: 1.45);
    final blocks = <Widget>[];
    final lines = widget.data.replaceAll('\r\n', '\n').split('\n');
    final para = <String>[];
    void flush() {
      if (para.isEmpty) return;
      blocks.add(Padding(padding: const EdgeInsets.only(bottom: 8), child: Text.rich(TextSpan(children: _spans(para.join('\n'), th)), style: body)));
      para.clear();
    }

    var i = 0;
    while (i < lines.length) {
      final line = lines[i];
      final t = line.trimLeft();
      if (t.startsWith('```')) {
        flush();
        final lang = t.substring(3).trim();
        final code = <String>[];
        i++;
        while (i < lines.length && !lines[i].trimLeft().startsWith('```')) {
          code.add(lines[i]);
          i++;
        }
        i++;
        blocks.add(_CodeBlock(code.join('\n'), lang));
        continue;
      }
      final h = RegExp(r'^(#{1,4})\s+(.*)$').firstMatch(t);
      if (h != null) {
        flush();
        final lvl = h.group(1)!.length;
        final st = lvl == 1 ? th.textTheme.titleLarge : (lvl == 2 ? th.textTheme.titleMedium : th.textTheme.titleSmall);
        blocks.add(Padding(padding: const EdgeInsets.only(top: 6, bottom: 6), child: Text.rich(TextSpan(children: _spans(h.group(2)!, th)), style: st)));
        i++;
        continue;
      }
      final b = RegExp(r'^(\s*)([-*•]|\d+[.)])\s+(.*)$').firstMatch(line);
      if (b != null) {
        flush();
        final indent = (b.group(1)!.length / 2).floor().clamp(0, 4);
        final mark = RegExp(r'\d').hasMatch(b.group(2)!) ? b.group(2)! : '•';
        blocks.add(Padding(
          padding: EdgeInsets.only(left: 4.0 + indent * 16, bottom: 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: mark == '•' ? 16 : 26, child: Text(mark, style: body.copyWith(color: th.colorScheme.primary, fontWeight: FontWeight.w700))),
            Expanded(child: Text.rich(TextSpan(children: _spans(b.group(3)!, th)), style: body)),
          ]),
        ));
        i++;
        continue;
      }
      if (t.isEmpty) {
        flush();
      } else {
        para.add(line);
      }
      i++;
    }
    flush();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: blocks);
  }
}

class _CodeBlock extends StatelessWidget {
  final String code;
  final String lang;
  const _CodeBlock(this.code, this.lang);
  @override
  Widget build(BuildContext context) {
    final th = Theme.of(context);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10, top: 2),
      decoration: BoxDecoration(color: th.colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(left: 14, right: 4),
          child: Row(children: [
            Expanded(child: Text(lang.isEmpty ? 'code' : lang, style: th.textTheme.labelSmall?.copyWith(color: th.colorScheme.onSurfaceVariant))),
            IconButton(
              tooltip: 'Copy',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.copy_rounded, size: 18),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: code));
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
              },
            ),
          ]),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
          child: Text(code, style: const TextStyle(fontFamily: kMono, fontSize: 13, height: 1.4)),
        ),
      ]),
    );
  }
}

/// Reveals an answer as if it were being typed, then shows it complete.
class TypeReveal extends StatefulWidget {
  final String text;
  final VoidCallback? onTick;
  const TypeReveal(this.text, {super.key, this.onTick});
  @override
  State<TypeReveal> createState() => _TypeRevealState();
}

class _TypeRevealState extends State<TypeReveal> with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  @override
  void initState() {
    super.initState();
    final ms = (widget.text.length * 6).clamp(300, 2600);
    _c = AnimationController(vsync: this, duration: Duration(milliseconds: ms))
      ..addListener(() => widget.onTick?.call())
      ..forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.of(context).disableAnimations) return MdText(widget.text);
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) {
        final n = (widget.text.length * Curves.easeOut.transform(_c.value)).round();
        return MdText(n >= widget.text.length ? widget.text : widget.text.substring(0, n));
      },
    );
  }
}
