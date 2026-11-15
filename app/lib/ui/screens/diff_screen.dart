import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../logic/patcher.dart';
import '../../state/code_state.dart';
import '../widgets/common.dart';

/// Colour-coded view of what changed in one file: green lines were added, red lines were removed.
class DiffScreen extends StatefulWidget {
  final FileChange change;
  const DiffScreen({super.key, required this.change});
  @override
  State<DiffScreen> createState() => _DiffScreenState();
}

class _DiffScreenState extends State<DiffScreen> {
  // The diff of what the model WROTE: parts that were turned off stay visible, so they can be turned on again.
  late final List<DiffLine> _lines = diffLines(widget.change.before ?? '', widget.change.written ?? widget.change.after);
  late final List<({int start, int end})> _hunks = diffHunks(_lines);
  late final Map<DiffLine, int> _hunkAt = {for (var h = 0; h < _hunks.length; h++) _lines[_hunks[h].start]: h};
  late Set<int> _off = {...widget.change.rejected};
  bool _whole = false;

  bool get _canReview => !widget.change.isNew && _hunks.length > 1;

  Future<void> _toggle(int h, bool keep) async {
    setState(() => keep ? _off.remove(h) : _off.add(h));
    _off = {..._off};
    await context.read<CodeState>().reviewChange(widget.change, _off);
    if (mounted) setState(() {});
  }

  /// Changed lines with 3 lines around them; long unchanged stretches become one "… N lines" row (a null entry).
  List<DiffLine?> _folded() {
    const ctx = 3;
    final keep = List<bool>.filled(_lines.length, false);
    for (var i = 0; i < _lines.length; i++) {
      if (_lines[i].kind != ' ') {
        for (var j = (i - ctx).clamp(0, _lines.length - 1); j <= (i + ctx).clamp(0, _lines.length - 1); j++) {
          keep[j] = true;
        }
      }
    }
    final out = <DiffLine?>[];
    var skipped = 0;
    for (var i = 0; i < _lines.length; i++) {
      if (keep[i]) {
        if (skipped > 0) out.add(DiffLine(' ', '$skipped', -1, -1));
        skipped = 0;
        out.add(_lines[i]);
      } else {
        skipped++;
      }
    }
    if (skipped > 0) out.add(DiffLine(' ', '$skipped', -1, -1));
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = widget.change;
    final rows = _whole || c.isNew ? _lines.cast<DiffLine?>() : _folded();
    final st = diffStats(_lines);
    const green = Color(0xFF34C759);
    final red = t.colorScheme.error;
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(c.path.split('/').last, style: t.textTheme.titleMedium),
          Text('${c.isNew ? 'New file · ' : ''}+${st.added}  −${st.removed}', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        ]),
        actions: [
          if (!c.isNew) IconButton(tooltip: _whole ? 'Show only the changes' : 'Show the whole file', icon: Icon(_whole ? Icons.unfold_less_rounded : Icons.unfold_more_rounded), onPressed: () => setState(() => _whole = !_whole)),
        ],
      ),
      body: SelectionArea(
        child: ListView.builder(
          padding: const EdgeInsets.only(bottom: 32),
          itemCount: rows.length + 1,
          itemBuilder: (_, i) {
            if (i == 0) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(c.path, style: t.textTheme.bodySmall?.copyWith(fontFamily: 'monospace', color: t.colorScheme.onSurfaceVariant)),
                  if (c.problem != null) Padding(padding: const EdgeInsets.only(top: 8), child: ErrorBox('Possible syntax problem after the change: ${c.problem}')),
                  for (final f in c.failures) Padding(padding: const EdgeInsets.only(top: 8), child: ErrorBox('This edit was NOT applied: $f')),
                  if (_canReview)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text('${_hunks.length} changes in this file. Turn off any you do not want: the file, the zip and the next push follow.', style: t.textTheme.bodySmall),
                    ),
                ]),
              );
            }
            final l = rows[i - 1]!;
            if (l.oldNo == -1) {
              return Container(
                color: t.colorScheme.surfaceContainerHigh,
                padding: const EdgeInsets.symmetric(vertical: 4),
                alignment: Alignment.center,
                child: Text('⋯ ${l.text} unchanged lines', style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
              );
            }
            final h = _hunkAt[l];
            final off = h != null && _off.contains(h);
            final row = _row(t, l, green, red);
            if (h == null || !_canReview) return _dim(row, l);
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Container(
                color: t.colorScheme.surfaceContainerHighest,
                padding: const EdgeInsets.only(left: 12),
                child: Row(children: [
                  Expanded(child: Text('Change ${h + 1} of ${_hunks.length}${off ? ' · turned off' : ''}', style: t.textTheme.labelMedium)),
                  Text(off ? 'Keep' : 'Keep', style: t.textTheme.labelSmall),
                  Switch(value: !off, onChanged: (v) => _toggle(h, v)),
                ]),
              ),
              _dim(row, l),
            ]);
          },
        ),
      ),
    );
  }

  /// A line of a part that was turned off is shown faded.
  Widget _dim(Widget row, DiffLine l) {
    for (final h in _off) {
      if (h < _hunks.length) {
        final i = _lines.indexOf(l);
        if (i >= _hunks[h].start && i < _hunks[h].end) return Opacity(opacity: 0.35, child: row);
      }
    }
    return row;
  }

  Widget _row(ThemeData t, DiffLine l, Color green, Color red) {
            final bg = l.kind == '+' ? green.withValues(alpha: 0.16) : (l.kind == '-' ? red.withValues(alpha: 0.16) : null);
            final no = l.kind == '-' ? l.oldNo : l.newNo;
            return Container(
              color: bg,
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(width: 44, child: Text('$no', textAlign: TextAlign.right, style: TextStyle(fontFamily: 'monospace', fontSize: 11.5, height: 1.5, color: t.colorScheme.onSurfaceVariant.withValues(alpha: 0.7)))),
                SizedBox(width: 20, child: Text(l.kind == ' ' ? '' : (l.kind == '-' ? '−' : '+'), textAlign: TextAlign.center, style: TextStyle(fontFamily: 'monospace', fontSize: 12.5, height: 1.4, fontWeight: FontWeight.w700, color: l.kind == '+' ? green : red))),
                Expanded(child: Text(l.text.isEmpty ? ' ' : l.text, style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5, height: 1.4))),
                const SizedBox(width: 8),
              ]),
            );
  }
}
