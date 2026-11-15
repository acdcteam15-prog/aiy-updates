import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_builder.dart';
import '../../state/build_state.dart';
import '../../state/code_state.dart';
import '../../state/native.dart';
import '../../state/storage.dart';
import '../widgets/common.dart';
import '../widgets/fx.dart';

/// What AIy keeps on the phone and how much space it takes, with cleanup.
class StorageScreen extends StatefulWidget {
  const StorageScreen({super.key});
  @override
  State<StorageScreen> createState() => _StorageScreenState();
}

class _StorageScreenState extends State<StorageScreen> {
  List<StorageItem>? _items;
  int _free = -1;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    final items = await StorageInfo.scan();
    final free = await Native.storageFree();
    if (mounted) setState(() {
          _items = items;
          _free = free;
        });
  }

  Future<void> _clear(StorageItem it) async {
    final busy = context.read<CodeState>().isBusy || context.read<AppBuilder>().isBusy || context.read<BuildState>().running;
    if (it.id == 'temp' && busy) {
      snack(context, 'Something is running. Clear temporary files when it has finished.');
      return;
    }
    if (!await confirmDialog(context, 'Delete ${it.title.toLowerCase()}?', body: '${StorageInfo.fmt(it.bytes)} will be freed. ${it.note}', yes: 'Delete')) return;
    if (!mounted) return;
    var freed = it.bytes;
    if (it.id == 'apks') {
      await context.read<BuildState>().deleteAllApks();
    } else {
      freed = await StorageInfo.clear(it.id);
    }
    if (mounted) snack(context, '${StorageInfo.fmt(freed)} freed');
    await _scan();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final items = _items;
    final total = items?.fold<int>(0, (s, e) => s + e.bytes) ?? 0;
    return Scaffold(
      appBar: AppBar(title: const Text('Storage')),
      body: items == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _scan,
              child: ListView(padding: const EdgeInsets.all(12), children: [
                Text('AIy uses ${StorageInfo.fmt(total)}${_free < 0 ? '' : ' · ${StorageInfo.fmt(_free)} free on the phone'}', style: t.textTheme.titleMedium),
                const SizedBox(height: 10),
                for (final it in items)
                  StepCard(
                    child: Row(children: [
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(it.title, style: t.textTheme.titleSmall),
                          Text('${StorageInfo.fmt(it.bytes)} · ${it.files} file${it.files == 1 ? '' : 's'}', style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.primary)),
                          Text(it.note, style: t.textTheme.bodySmall),
                        ]),
                      ),
                      if (it.canClear && it.bytes > 0) TextButton(onPressed: () => _clear(it), child: const Text('Clear')),
                    ]),
                  ),
              ]),
            ),
    );
  }
}
