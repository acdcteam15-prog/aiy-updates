import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../state/app_log.dart';
import '../widgets/common.dart';

/// The last lines AIy logged (keys removed): copy or share them when something goes wrong.
class LogScreen extends StatefulWidget {
  const LogScreen({super.key});
  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  @override
  Widget build(BuildContext context) {
    final text = AppLog.text;
    return Scaffold(
      appBar: AppBar(
        title: Text('Log (${AppLog.count} lines)'),
        actions: [
          IconButton(
            tooltip: 'Copy',
            icon: const Icon(Icons.copy_rounded),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: text));
              snack(context, 'Log copied');
            },
          ),
          IconButton(tooltip: 'Share', icon: const Icon(Icons.ios_share_rounded), onPressed: () => SharePlus.instance.share(ShareParams(text: text, subject: 'AIy log'))),
          IconButton(
            tooltip: 'Clear',
            icon: const Icon(Icons.delete_outline_rounded),
            onPressed: () async {
              if (await confirmDialog(context, 'Clear the log?', yes: 'Clear')) {
                await AppLog.clear();
                setState(() {});
              }
            },
          ),
        ],
      ),
      body: text.isEmpty
          ? const Center(child: Text('Nothing logged yet.'))
          : SingleChildScrollView(reverse: true, padding: const EdgeInsets.all(12), child: SelectableText(text, style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5, height: 1.45))),
    );
  }
}
