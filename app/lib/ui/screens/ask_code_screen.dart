import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/code_state.dart';
import '../widgets/common.dart';
import '../widgets/fx.dart';
import '../widgets/markdown.dart';

/// Questions about the open project in plain English. Nothing is changed.
class AskCodeScreen extends StatefulWidget {
  const AskCodeScreen({super.key});
  @override
  State<AskCodeScreen> createState() => _AskCodeScreenState();
}

class _AskCodeScreenState extends State<AskCodeScreen> {
  final _q = TextEditingController();
  final _scroll = ScrollController();

  @override
  void dispose() {
    _q.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _ask(CodeState code, [String? preset]) async {
    final q = (preset ?? _q.text).trim();
    if (q.isEmpty || code.asking) return;
    _q.clear();
    FocusScope.of(context).unfocus();
    final f = code.askAbout(q);
    _toEnd();
    await f;
    _toEnd();
  }

  void _follow() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients && _scroll.position.maxScrollExtent - _scroll.position.pixels < 200) _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });

  void _toEnd() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic);
      });

  @override
  Widget build(BuildContext context) {
    final code = context.watch<CodeState>();
    if (code.asking && code.askLive.isNotEmpty) _follow();
    final t = Theme.of(context);
    const ideas = ['What does this project do?', 'Which files are the most important?', 'Where is the data saved?', 'How would I add a settings screen?'];
    return Scaffold(
      appBar: AppBar(title: Text('Ask about ${code.sourceName.isEmpty ? 'the project' : code.sourceName}', maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: AuroraBackground(
        strength: 0.3,
        child: Column(children: [
          Expanded(
            child: code.asks.isEmpty && !code.asking
                ? ListView(padding: const EdgeInsets.all(20), children: [
                    Text('Ask anything about this project in plain English. AIy reads the project map and the files it needs, and answers. Nothing is changed.', style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                    const SizedBox(height: 16),
                    Wrap(spacing: 8, runSpacing: 8, children: [for (final i in ideas) ActionChip(label: Text(i), onPressed: () => _ask(code, i))]),
                  ])
                : SelectionArea(
                    child: ListView(controller: _scroll, padding: const EdgeInsets.fromLTRB(16, 8, 16, 16), children: [
                      for (final a in code.asks) ...[
                        Align(
                          alignment: Alignment.centerRight,
                          child: Container(
                            margin: const EdgeInsets.only(left: 48, top: 8, bottom: 8),
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                            decoration: BoxDecoration(color: t.colorScheme.primary.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(20)),
                            child: Text(a.$1),
                          ),
                        ),
                        MdText(a.$2),
                        if (a.$3.isNotEmpty) Align(alignment: Alignment.centerLeft, child: ModelBadge(a.$3)),
                        const SizedBox(height: 10),
                      ],
                      if (code.asking && code.askLive.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 10), child: Row(children: [Orb(size: 30, mode: OrbMode.thinking), SizedBox(width: 12), ThinkingDots()])),
                      if (code.asking && code.askLive.isNotEmpty) ...[MdText(code.askLive), const Orb(size: 26, mode: OrbMode.writing)],
                    ]),
                  ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(12, 4, 12, 10 + MediaQuery.of(context).padding.bottom),
            child: TextField(
              controller: _q,
              minLines: 1,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: 'Ask about the project',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(26), borderSide: BorderSide.none),
                suffixIcon: IconButton.filled(onPressed: _q.text.trim().isEmpty || code.asking ? null : () => _ask(code), icon: const Icon(Icons.arrow_upward_rounded)),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
