import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../logic/redact.dart';

/// A small log kept on the phone (the last few hundred lines, keys removed) so a problem can be copied and sent.
class AppLog {
  static final List<String> _lines = [];
  static File? _file;

  static Future<void> init() async {
    try {
      final d = Directory('${(await getApplicationDocumentsDirectory()).path}/aiy')..createSync(recursive: true);
      final f = File('${d.path}/log.txt');
      _file = f;
      if (f.existsSync()) {
        final all = f.readAsLinesSync();
        _lines.addAll(all.length > 300 ? all.sublist(all.length - 300) : all);
        if (all.length > 600) f.writeAsStringSync('${_lines.join('\n')}\n');
      }
    } catch (_) {}
    i('--- AIy started ---');
  }

  static String _stamp() {
    final n = DateTime.now();
    String t(int v) => v.toString().padLeft(2, '0');
    return '${n.year}-${t(n.month)}-${t(n.day)} ${t(n.hour)}:${t(n.minute)}:${t(n.second)}';
  }

  static void i(String message) {
    final line = '${_stamp()}  ${redact(message).replaceAll('\n', ' | ')}';
    _lines.add(line.length > 700 ? '${line.substring(0, 700)}…' : line);
    if (_lines.length > 400) _lines.removeRange(0, _lines.length - 400);
    try {
      _file?.writeAsStringSync('${_lines.last}\n', mode: FileMode.append);
    } catch (_) {}
  }

  static String get text => _lines.join('\n');
  static int get count => _lines.length;

  static Future<void> clear() async {
    _lines.clear();
    try {
      _file?.writeAsStringSync('');
    } catch (_) {}
  }
}
