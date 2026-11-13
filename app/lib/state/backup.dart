import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'native.dart';
import 'net.dart';
import 'prefs.dart';

/// One file with the chats, the app ideas, the history of changes, the spending and the settings.
/// The keys are NEVER in it: they stay in the phone's key vault. Written apps (zips) and installed-app files are not in it either.
class BackupService {
  static const _root = 'aiy-backup/';

  static Future<String> _base() async => '${(await getApplicationDocumentsDirectory()).path}/aiy';

  static Future<String> export(LocalPrefs prefs) async {
    final base = await _base();
    final files = <String, String>{};
    for (final n in const ['chats.json', 'history.json', 'spend.json']) {
      final f = File('$base/$n');
      if (f.existsSync()) files['$_root$n'] = f.readAsStringSync();
    }
    final pd = Directory('$base/projects');
    if (pd.existsSync()) {
      for (final f in pd.listSync()) {
        if (f is File && f.path.endsWith('.json')) files['${_root}projects/${f.path.split('/').last}'] = f.readAsStringSync();
      }
    }
    files['${_root}settings.json'] = jsonEncode(prefs.exportSettings());
    files['${_root}README.txt'] = 'AIy backup. Restore it in AIy: Settings > Backup > Restore.\nNo keys are included: connect your accounts again after restoring on a new phone.\n';
    final n = DateTime.now();
    String t(int v) => v.toString().padLeft(2, '0');
    final out = '${(await getTemporaryDirectory()).path}/AIy-backup-${n.year}${t(n.month)}${t(n.day)}.zip';
    await Native.zipCreate(out, files, {});
    return out;
  }

  /// Puts the backup back. Returns how many files were restored.
  static Future<int> restore(String zip, LocalPrefs prefs) async {
    final entries = await Native.zipScan(zip);
    final names = [
      for (final e in entries)
        if (e.name.startsWith(_root) && e.name.endsWith('.json')) e.name
    ];
    if (names.isEmpty) throw ApiError('This file is not an AIy backup.');
    final texts = await Native.zipRead(zip, names, maxBytes: 30 * 1024 * 1024);
    final base = await _base();
    var n = 0;
    for (final e in texts.entries) {
      final rel = e.key.substring(_root.length);
      if (rel.contains('..')) continue;
      if (rel == 'settings.json') {
        try {
          await prefs.importSettings(jsonDecode(e.value) as Map<String, dynamic>);
          n++;
        } catch (_) {}
        continue;
      }
      final f = File('$base/$rel');
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(e.value);
      n++;
    }
    return n;
  }
}
