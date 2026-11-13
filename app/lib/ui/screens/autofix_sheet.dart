import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/ai.dart';
import '../../state/build_state.dart';
import '../../state/code_state.dart';
import '../../state/prefs.dart';
import '../widgets/common.dart';
import '../widgets/fx.dart';
import 'model_picker.dart';

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

  Future<void> _restore() async {
    final id = context.read<LocalPrefs>().codeModel;
    if (id.isEmpty) return;
    try {
      final all = await context.read<AiEngine>().orModels();
      final m = all.where((m) => m.id == id).toList();
      if (mounted && m.isNotEmpty) setState(() => _model = m.first);
    } catch (_) {}
  }

  Future<void> _choose() async {
    final m = await Navigator.push<OrModel>(context, MaterialPageRoute(builder: (_) => ModelPicker(selected: _model?.id ?? '')));
    if (m == null || !mounted) return;
    setState(() => _model = m);
    context.read<LocalPrefs>().setCodeModel(m.id);
  }

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
        const SizedBox(height: 12),
        Text('How many tries at most?', style: t.textTheme.titleSmall),
        const SizedBox(height: 6),
        Wrap(spacing: 8, children: [for (final n in const [1, 2, 3]) ChoiceChip(label: Text('$n'), selected: _rounds == n, onSelected: (_) => setState(() => _rounds = n))]),
        if (est != null) ...[
          const SizedBox(height: 10),
          Text(
            est.blocked ?? (_model!.free ? 'Free model: no cost.' : 'Each try: about ${fmtMoney(est.cost)}, never more than your limit of \$${cap.toStringAsFixed(2)}. With $_rounds ${_rounds == 1 ? 'try' : 'tries'}: at most about ${fmtMoney(est.worstCase * _rounds)}.'),
            style: sub?.copyWith(color: est.blocked != null ? t.colorScheme.error : null),
          ),
        ],
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))),
          const SizedBox(width: 12),
          Expanded(child: FilledButton(onPressed: _model == null || _problem != null || (est?.blocked != null) ? null : () => Navigator.pop(context, (_model!, _rounds)), child: const Text('Start'))),
        ]),
      ]),
    );
  }
}
