import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/ai.dart';
import '../../state/net.dart';
import '../../state/prefs.dart';
import '../widgets/common.dart';
import '../widgets/fx.dart';

/// Every OpenRouter model, fetched live: search, filters, sorting, starred and recent models.
class ModelPicker extends StatefulWidget {
  final String selected;

  /// Only models that cost nothing (used where AIy must never spend money, for example in chat).
  final bool freeOnly;
  const ModelPicker({super.key, required this.selected, this.freeOnly = false});
  @override
  State<ModelPicker> createState() => _ModelPickerState();
}

enum _Sort { cheap, context, name }

class _ModelPickerState extends State<ModelPicker> {
  List<OrModel>? _all;
  String? _error;
  String _q = '';
  late int _filter = widget.freeOnly ? 1 : 0; // 0 recommended, 1 free, 2 starred, 3 all
  _Sort _sort = _Sort.cheap;
  String _maker = ''; // '' = every maker

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

  static String makerOf(OrModel m) {
    final i = m.id.indexOf('/');
    return i <= 0 ? 'other' : m.id.substring(0, i);
  }

  static const _makerNames = {
    'anthropic': 'Anthropic', 'openai': 'OpenAI', 'google': 'Google', 'meta-llama': 'Meta', 'mistralai': 'Mistral',
    'deepseek': 'DeepSeek', 'qwen': 'Qwen', 'x-ai': 'xAI', 'moonshotai': 'Kimi', 'z-ai': 'GLM', 'nvidia': 'NVIDIA', 'microsoft': 'Microsoft',
  };
  static String makerName(String k) => _makerNames[k] ?? (k.isEmpty ? k : k[0].toUpperCase() + k.substring(1));

  void _pick(OrModel m) {
    context.read<LocalPrefs>().addRecentModel(m.id);
    Navigator.pop(context, m);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final prefs = context.watch<LocalPrefs>();
    final favs = prefs.favModels.toSet();
    final q = _q.trim().toLowerCase();
    final pool = (_all ?? const <OrModel>[]).where((m) => !widget.freeOnly || m.free).toList();
    final makers = <String, int>{};
    for (final m in pool) {
      makers[makerOf(m)] = (makers[makerOf(m)] ?? 0) + 1;
    }
    final topMakers = (makers.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).take(10).map((e) => e.key).toList();
    var list = pool.where((m) {
      if (_maker.isNotEmpty && makerOf(m) != _maker) return false;
      if (q.isNotEmpty) return m.id.toLowerCase().contains(q) || m.name.toLowerCase().contains(q);
      switch (_filter) {
        case 0:
          return m.coding || favs.contains(m.id);
        case 1:
          return m.free;
        case 2:
          return favs.contains(m.id);
        default:
          return true;
      }
    }).toList();
    list.sort((a, b) {
      final fa = favs.contains(a.id), fb = favs.contains(b.id);
      if (fa != fb) return fa ? -1 : 1;
      switch (_sort) {
        case _Sort.context:
          return b.context.compareTo(a.context);
        case _Sort.name:
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case _Sort.cheap:
          if (a.free != b.free) return a.free ? -1 : 1;
          return (a.promptPrice + a.completionPrice).compareTo(b.promptPrice + b.completionPrice);
      }
    });
    final byId = {for (final m in pool) m.id: m};
    final recent = q.isEmpty && _maker.isEmpty ? [for (final id in prefs.recentModels) if (byId[id] != null) byId[id]!] : <OrModel>[];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Choose a model'),
        actions: [
          PopupMenuButton<_Sort>(
            tooltip: 'Sort',
            icon: const Icon(Icons.sort_rounded),
            initialValue: _sort,
            onSelected: (v) => setState(() => _sort = v),
            itemBuilder: (_) => const [
              PopupMenuItem(value: _Sort.cheap, child: Text('Free and cheapest first')),
              PopupMenuItem(value: _Sort.context, child: Text('Reads the most first')),
              PopupMenuItem(value: _Sort.name, child: Text('By name')),
            ],
          ),
          IconButton(tooltip: 'Refresh the list', icon: const Icon(Icons.refresh_rounded), onPressed: () => _load(true)),
        ],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: TextField(
            onChanged: (v) => setState(() => _q = v),
            decoration: InputDecoration(
              hintText: 'Search ${pool.isEmpty ? '' : '${pool.length} '}models',
              prefixIcon: const Icon(Icons.search_rounded),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(999), borderSide: BorderSide.none),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(999), borderSide: BorderSide.none),
            ),
          ),
        ),
        SizedBox(
          height: 44,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 16), children: [
            for (final (i, label) in const ['Good for coding', 'Free', 'Starred', 'All'].indexed)
              if (!widget.freeOnly || i == 1 || i == 2)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    avatar: i == 2 ? const Icon(Icons.star_rounded, size: 16) : null,
                    label: Text(i == 2 && favs.isNotEmpty ? 'Starred (${favs.length})' : label),
                    selected: q.isEmpty && _filter == i,
                    onSelected: (_) => setState(() => _filter = i),
                  ),
                ),
          ]),
        ),
        if (topMakers.length > 1)
          SizedBox(
            height: 40,
            child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 16), children: [
              for (final k in ['', ...topMakers])
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: FilterChip(
                    visualDensity: VisualDensity.compact,
                    label: Text(k.isEmpty ? 'Every maker' : makerName(k)),
                    selected: _maker == k,
                    showCheckmark: false,
                    onSelected: (_) => setState(() => _maker = k),
                  ),
                ),
            ]),
          ),
        const SizedBox(height: 4),
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: _error != null
                ? Padding(padding: const EdgeInsets.all(20), child: ErrorBox(_error!, action: 'Try again', onAction: () => _load(true)))
                : _all == null
                    ? const SkeletonList()
                    : list.isEmpty && recent.isEmpty
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Text(_filter == 2 && q.isEmpty ? 'No starred models yet.\nTap the star on a model to keep it here.' : 'No model matches.', textAlign: TextAlign.center, style: TextStyle(color: t.colorScheme.onSurfaceVariant)),
                            ),
                          )
                        : ListView(
                            key: ValueKey('$_filter$_maker$_sort$q'),
                            padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                            children: [
                              if (recent.isNotEmpty) ...[
                                _header(t, 'RECENT'),
                                for (final m in recent) _tile(t, m, favs.contains(m.id)),
                                _header(t, 'ALL MATCHING (${list.length})'),
                              ],
                              for (var i = 0; i < list.length; i++) i < 10 ? Appear(delay: i * 25, dy: 8, child: _tile(t, list[i], favs.contains(list[i].id))) : _tile(t, list[i], favs.contains(list[i].id)),
                            ],
                          ),
          ),
        ),
      ]),
    );
  }

  Widget _header(ThemeData t, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 6),
        child: Text(text, style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.primary, letterSpacing: 0.6)),
      );

  Widget _tile(ThemeData t, OrModel m, bool fav) {
    final s = t.colorScheme;
    final sel = m.id == widget.selected;
    final maker = makerOf(m);
    final accent = m.free ? const Color(0xFF34C759) : (m.coding ? s.primary : s.onSurfaceVariant);
    Widget chip(String text, {Color? color}) => Container(
          margin: const EdgeInsets.only(right: 6, top: 6),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(color: (color ?? s.onSurfaceVariant).withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
          child: Text(text, style: t.textTheme.labelSmall?.copyWith(color: color ?? s.onSurfaceVariant, fontWeight: FontWeight.w600)),
        );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Pressable(
        onTap: () => _pick(m),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
          decoration: BoxDecoration(
            color: sel ? s.primary.withValues(alpha: 0.12) : s.surfaceContainer,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: sel ? s.primary : s.outlineVariant.withValues(alpha: 0.35), width: sel ? 1.5 : 1),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: accent.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(12)),
              child: Text(makerName(maker).characters.first.toUpperCase(), style: TextStyle(color: accent, fontWeight: FontWeight.w800, fontSize: 17)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(m.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.titleSmall),
                Text(makerName(maker), style: t.textTheme.bodySmall?.copyWith(color: s.onSurfaceVariant)),
                Wrap(children: [
                  if (m.free) chip('Free', color: const Color(0xFF34C759)) else chip(m.priceLabel.replaceAll(' per 1M tokens', ' /1M')),
                  if (m.context > 0) chip(m.context >= 1000000 ? 'Reads ${(m.context / 1000000).toStringAsFixed(1)}M' : 'Reads ${(m.context / 1000).round()}k'),
                  if (m.coding) chip('Coding', color: s.primary),
                ]),
              ]),
            ),
            Column(children: [
              IconButton(
                tooltip: fav ? 'Remove the star' : 'Star this model',
                icon: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
                  child: Icon(fav ? Icons.star_rounded : Icons.star_outline_rounded, key: ValueKey(fav), color: fav ? const Color(0xFFFFB300) : s.onSurfaceVariant),
                ),
                onPressed: () => context.read<LocalPrefs>().toggleFavModel(m.id),
              ),
              if (sel) Icon(Icons.check_circle_rounded, color: s.primary, size: 20),
            ]),
          ]),
        ),
      ),
    );
  }
}
