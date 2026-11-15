import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/keys.dart';
import '../../state/store.dart';
import '../screens/connect_screen.dart';

/// Shown at the top of the app when something about the phone's own data needs the person:
/// a damaged file that was kept aside, a save that failed, or keys that cannot be opened on this phone.
class HealthBanner extends StatelessWidget {
  const HealthBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final keys = context.watch<KeyVault>();
    return ValueListenableBuilder<List<String>>(
      valueListenable: Store.notices,
      builder: (context, notes, _) {
        final items = <(String, VoidCallback?, VoidCallback)>[
          if (keys.problem.isNotEmpty)
            (
              keys.problem,
              () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ConnectScreen())),
              keys.dismissProblem,
            ),
          for (final n in notes.toSet()) (n, null, Store.clearNotices),
        ];
        if (items.isEmpty) return const SizedBox.shrink();
        final s = Theme.of(context).colorScheme;
        return Column(children: [
          for (final it in items.take(3))
            Container(
              margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
              padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
              decoration: BoxDecoration(color: s.tertiaryContainer, borderRadius: BorderRadius.circular(18)),
              child: Row(children: [
                Icon(Icons.info_outline_rounded, color: s.onTertiaryContainer, size: 20),
                const SizedBox(width: 10),
                Expanded(child: Text(it.$1, style: TextStyle(color: s.onTertiaryContainer, fontSize: 13))),
                if (it.$2 != null) TextButton(onPressed: it.$2, child: const Text('Connect')),
                IconButton(
                  tooltip: 'Dismiss',
                  icon: Icon(Icons.close_rounded, color: s.onTertiaryContainer, size: 18),
                  onPressed: it.$3,
                ),
              ]),
            ),
        ]);
      },
    );
  }
}
