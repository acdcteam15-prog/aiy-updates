import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/ai.dart';
import '../../state/build_state.dart';
import '../../state/code_state.dart';
import '../../state/prefs.dart';
import '../widgets/common.dart';
import '../widgets/fx.dart';
import 'model_picker.dart';
import '../../state/app_log.dart';

/// "Fix and rebuild automatically": the model, how many rounds, and what it can cost.
class AutoFixSheet extends StatefulWidget {
  const AutoFixSheet({super.key});
  @override
  State<AutoFixSheet> createState() => _AutoFixSheetState();
}

class _AutoFixSheetState extends State<AutoFixSheet> {
  OrModel? _model;
  int _rounds = 2;
  String? _problem;

  @override
  void initState() {
    super.initState();
    final b = context.read<BuildState>();
    _problem = context.read<CodeState>().startFix(b.problems, b.log);
    _restore();
  }

  String _hint = '';
  OrModel? _free;
  bool _freeFirst = true;

  /// The free model to try first: a known coding family with the biggest context, else any free one with 32k+.
  static OrModel? pickFree(List<OrModel> all) {
    final free = all.where((m) => m.free && m.context >= 32000).toList()
      ..sort((a, b) {
        if (a.coding != b.coding) return a.coding ? -1 : 1;
        return b.context.compareTo(a.context);
      });
    return free.isEmpty ? null : free.first;
  }

  Future<void> _restore() async {
    final b = context.read<BuildState>();
    final engine = context.read<AiEngine>();
    final prefsId = context.read<LocalPrefs>().codeModel;
    final fixer = await b.modelThatFixed(b.problems);
    final id = fixer ?? prefsId;
    try {
      final all = await engine.orModels();
      final f = pickFree(all);
      if (mounted) setState(() => _free = f);
      final m = id.isEmpty ? <OrModel>[] : all.where((m) => m.id == id).toList();
      if (mounted && m.isNotEmpty) {
        setState(() {
          _model = m.first;
          if (fixer != null) _hint = '${m.first.name} fixed this kind of error last time, so it is picked.';
        });
      }
    } catch (e) {
      AppLog.i('autofix_sheet:39: $e');
    }
  }

  Future<void> _choose() async {
    final m = await Navigator.push<OrModel>(context, MaterialPageRoute(builder: (_) => ModelPicker(selected: _model?.id ?? '')));
    if (m == null || !mounted) return;
    setState(() => _model = m);
    context.read<LocalPrefs>().setCodeModel(m.id);
  }

  bool get _useFree => _freeFirst && _free != null && _model != null && !_model!.free;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final sub = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final code = context.read<CodeState>();
    final cap = context.watch<LocalPrefs>().capUsd;
    final est = _model == null || _problem != null ? null : code.estimate(_model!);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(22, 0, 22, 22),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Fix and rebuild automatically', style: t.textTheme.titleLarge),
        const SizedBox(height: 4),
        Text('The model writes a fix, AIy pushes it and checks it on GitHub (about 2 minutes, no APK). If it still fails, it tries again. When the check passes, the real build starts.', style: sub),
        const SizedBox(height: 14),
        if (_problem != null) ErrorBox(_problem!),
        Pressable(
          onTap: _choose,
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
            decoration: BoxDecoration(color: t.colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(16)),
            child: Row(children: [
              Expanded(child: _model == null ? Text('Choose a model', style: t.textTheme.titleSmall) : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(_model!.name, style: t.textTheme.titleSmall), Text(_model!.priceLabel, style: sub)])),
              const Icon(Icons.unfold_more_rounded),
            ]),
          ),
        ),
        if (_hint.isNotEmpty) ...[const SizedBox(height: 6), Text(_hint, style: sub)],
        if (_free != null && _model != null && !_model!.free) ...[
          const SizedBox(height: 6),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _freeFirst,
            onChanged: (v) => setState(() => _freeFirst = v),
            title: Text('Try a free model first', style: t.textTheme.titleSmall),
            subtitle: Text('${_free!.name} gets one free try. Only if its fix does not work does ${_model!.name} take over (and cost money).', style: sub),
          ),
        ],
        const SizedBox(height: 12),
        Text('How many tries at most?', style: t.textTheme.titleSmall),
        const SizedBox(height: 6),
        Wrap(spacing: 8, children: [for (final n in const [1, 2, 3]) ChoiceChip(label: Text('$n'), selected: _rounds == n, onSelected: (_) => setState(() => _rounds = n))]),
        if (est != null) ...[
          const SizedBox(height: 10),
          Text(
            est.blocked ?? (_model!.free ? 'Free model: no cost.' : '${_useFree ? 'First try free (${_free!.name}). Then each' : 'Each'} try: about ${fmtMoney(est.cost)}, never more than your limit of \$${cap.toStringAsFixed(2)}. With $_rounds ${_rounds == 1 ? 'try' : 'tries'}: at most about ${fmtMoney(est.worstCase * _rounds)}.'),
            style: sub?.copyWith(color: est.blocked != null ? t.colorScheme.error : null),
          ),
        ],
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))),
          const SizedBox(width: 12),
          Expanded(child: FilledButton(onPressed: _model == null || _problem != null || (est?.blocked != null) ? null : () => Navigator.pop(context, (_model!, _rounds, _useFree ? _free : null)), child: const Text('Start'))),
        ]),
      ]),
    );
  }
}
