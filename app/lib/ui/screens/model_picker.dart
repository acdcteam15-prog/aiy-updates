import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/ai.dart';
import '../../state/net.dart';
import '../widgets/common.dart';

/// Every OpenRouter model, fetched live, with search. Free models and well-known coding models are highlighted.
class ModelPicker extends StatefulWidget {
  final String selected;

  /// Only models that cost nothing (used where AIy must never spend money, for example in chat).
  final bool freeOnly;
  const ModelPicker({super.key, required this.selected, this.freeOnly = false});
  @override
  State<ModelPicker> createState() => _ModelPickerState();
}

class _ModelPickerState extends State<ModelPicker> {
  List<OrModel>? _all;
  String? _error;
  String _q = '';
  late int _filter = widget.freeOnly ? 1 : 0; // 0 recommended, 1 free, 2 all

  @override
  void initState() {
    super.initState();
    _load(false);
  }

  Future<void> _load(bool force) async {
    setState(() {
      _error = null;
      if (force) _all = null;
    });
    try {
      final l = await context.read<AiEngine>().orModels(force: force);
      if (mounted) setState(() => _all = l);
    } catch (e) {
      if (mounted) setState(() => _error = e is ApiError ? e.message : '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final q = _q.trim().toLowerCase();
    var list = (_all ?? const <OrModel>[]).where((m) {
      if (widget.freeOnly && !m.free) return false;
      if (q.isNotEmpty) return m.id.toLowerCase().contains(q) || m.name.toLowerCase().contains(q);
      if (_filter == 1) return m.free;
      if (_filter == 0) return m.coding;
      return true;
    }).toList();
    // Free first, then cheapest.
    list.sort((a, b) {
      if (a.free != b.free) return a.free ? -1 : 1;
      return (a.promptPrice + a.completionPrice).compareTo(b.promptPrice + b.completionPrice);
    });
    return Scaffold(
      appBar: AppBar(title: const Text('Choose a model'), actions: [IconButton(tooltip: 'Refresh the list', icon: const Icon(Icons.refresh_rounded), onPressed: () => _load(true))]),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: TextField(
            onChanged: (v) => setState(() => _q = v),
            decoration: InputDecoration(
              hintText: 'Search ${_all?.length ?? ''} models',
              prefixIcon: const Icon(Icons.search_rounded),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(999), borderSide: BorderSide.none),
            ),
          ),
        ),
        if (q.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              for (final (i, label) in const ['Good for coding', 'Free', 'All'].indexed)
                if (!widget.freeOnly || i != 0)
                Padding(padding: const EdgeInsets.only(right: 8), child: ChoiceChip(label: Text(label), selected: _filter == i, onSelected: (_) => setState(() => _filter = i))),
            ]),
          ),
        const SizedBox(height: 6),
        Expanded(
          child: _error != null
              ? Padding(padding: const EdgeInsets.all(20), child: ErrorBox(_error!, action: 'Try again', onAction: () => _load(true)))
              : _all == null
                  ? const Center(child: CircularProgressIndicator())
                  : list.isEmpty
                      ? const Center(child: Text('No model matches.'))
                      : ListView.builder(
                          padding: const EdgeInsets.only(bottom: 24),
                          itemCount: list.length,
                          itemBuilder: (_, i) {
                            final m = list[i];
                            final sel = m.id == widget.selected;
                            return ListTile(
                              selected: sel,
                              leading: Icon(m.free ? Icons.card_giftcard_rounded : (m.coding ? Icons.star_rounded : Icons.memory_rounded), color: m.free ? const Color(0xFF34C759) : (m.coding ? t.colorScheme.primary : t.colorScheme.onSurfaceVariant)),
                              title: Text(m.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text('${m.priceLabel}${m.context > 0 ? ' · reads ${(m.context / 1000).round()}k tokens' : ''}', maxLines: 2),
                              trailing: sel ? const Icon(Icons.check_rounded) : null,
                              onTap: () => Navigator.pop(context, m),
                            );
                          },
                        ),
        ),
      ]),
    );
  }
}
