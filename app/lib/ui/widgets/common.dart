import 'package:flutter/material.dart';

void snack(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}

Future<bool> confirmDialog(BuildContext context, String title, {String? body, String yes = 'OK', String no = 'Cancel'}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: body == null ? null : Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: Text(no)),
        FilledButton(style: FilledButton.styleFrom(minimumSize: const Size(64, 44)), onPressed: () => Navigator.pop(c, true), child: Text(yes)),
      ],
    ),
  );
  return r == true;
}

/// The small "who answered" label: provider and model.
class ModelBadge extends StatelessWidget {
  final String text;
  const ModelBadge(this.text, {super.key});
  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: s.primary.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(999)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.bolt_rounded, size: 14, color: s.primary),
        const SizedBox(width: 4),
        Flexible(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: s.primary))),
      ]),
    );
  }
}

/// A red-tinted box with a readable error and an optional action.
class ErrorBox extends StatelessWidget {
  final String text;
  final String? action;
  final VoidCallback? onAction;
  final VoidCallback? onClose;
  const ErrorBox(this.text, {super.key, this.action, this.onAction, this.onClose});
  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      decoration: BoxDecoration(color: s.errorContainer, borderRadius: BorderRadius.circular(18)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 2), child: Icon(Icons.error_outline_rounded, color: s.onErrorContainer, size: 20)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SelectableText(text, style: TextStyle(color: s.onErrorContainer)),
            if (action != null) TextButton(onPressed: onAction, child: Text(action!)),
          ]),
        ),
        if (onClose != null) IconButton(visualDensity: VisualDensity.compact, icon: Icon(Icons.close_rounded, color: s.onErrorContainer, size: 18), onPressed: onClose),
      ]),
    );
  }
}

String fmtBytes(int b) {
  if (b >= 1048576) return '${(b / 1048576).toStringAsFixed(b >= 10485760 ? 0 : 1)} MB';
  if (b >= 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
  return '$b B';
}

String fmtMoney(double v) {
  if (v <= 0) return 'Free';
  if (v < 0.01) return 'less than \$0.01';
  return '\$${v.toStringAsFixed(2)}';
}

String fmtDate(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${d.day} ${months[d.month - 1]} ${d.year}, ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}
