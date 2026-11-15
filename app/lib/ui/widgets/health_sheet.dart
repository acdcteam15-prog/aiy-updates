import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/ai.dart';

/// How each AI service did since AIy was opened. Services that keep failing are tried last for a while.
Future<void> showHealthSheet(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final ai = ctx.read<AiEngine>();
        final t = Theme.of(ctx);
        final all = ai.health.all;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('AI services since AIy was opened', style: t.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text('A service that fails twice in a row (busy, limit, too slow) is tried last for 2 minutes; after 4 failures, for 10 minutes. It is still used when the others fail.', style: t.textTheme.bodySmall),
              const SizedBox(height: 10),
              if (all.isEmpty) const Text('No answers yet.'),
              for (final e in all.entries)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(ai.health.cooling(e.key) ? Icons.hourglass_bottom_rounded : Icons.check_circle_outline_rounded, color: ai.health.cooling(e.key) ? t.colorScheme.error : const Color(0xFF34C759)),
                  title: Text(AiEngine.names[e.key] ?? e.key),
                  subtitle: Text('${e.value.ok} answered, ${e.value.failed} failed${e.value.avgMs > 0 ? ' · about ${(e.value.avgMs / 1000).toStringAsFixed(1)} s per answer' : ''}'
                      '${ai.health.cooling(e.key) ? '\nTried last for now: ${e.value.lastError}' : ''}'),
                ),
            ]),
          ),
        );
      },
    );
