import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'native.dart';
import 'net.dart';
import 'app_log.dart';
import 'prefs.dart';
import 'store.dart';

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
  ///
  /// Safe order: every file is first checked (it must be valid JSON) and written to a staging folder.
  /// Only when ALL of them are good are the current files moved aside to `pre-restore-<time>/`
  /// and the restored ones moved in. While this runs, the app does not save (so it cannot overwrite
  /// the restored files with what it still has in memory); the caller reloads everything afterwards.
  /// If anything fails, the phone's files are left exactly as they were.
  static Future<int> restore(String zip, LocalPrefs prefs) async {
    final entries = await Native.zipScan(zip);
    final names = [
      for (final e in entries)
        if (e.name.startsWith(_root) && e.name.endsWith('.json')) e.name
    ];
    if (names.isEmpty) throw ApiError('This file is not an AIy backup (no aiy-backup/ folder inside). Pick a file made with Settings > Backup > Export.');
    final texts = await Native.zipRead(zip, names, maxBytes: 30 * 1024 * 1024);
    final base = await _base();

    // 1. check everything first
    Map<String, dynamic>? settings;
    final files = <String, String>{};
    final bad = <String>[];
    for (final e in texts.entries) {
      final rel = e.key.substring(_root.length);
      if (!_safeRel(rel)) {
        AppLog.i('restore: skipped unsafe name $rel');
        continue;
      }
      try {
        final j = jsonDecode(e.value);
        if (rel == 'settings.json') {
          if (j is Map) settings = Map<String, dynamic>.from(j);
          continue;
        }
        files[rel] = e.value;
      } catch (_) {
        bad.add(rel);
      }
    }
    if (bad.isNotEmpty) {
      throw ApiError('The backup is damaged: ${bad.join(', ')} cannot be read. Nothing was changed on this phone. Try an older backup file.');
    }
    if (files.isEmpty && settings == null) throw ApiError('The backup is empty. Nothing was changed on this phone.');

    final n = DateTime.now();
    String t(int v) => v.toString().padLeft(2, '0');
    final stamp = '${n.year}${t(n.month)}${t(n.day)}-${t(n.hour)}${t(n.minute)}${t(n.second)}';
    final stage = Directory('$base/.restore-$stamp');
    final aside = Directory('$base/pre-restore-$stamp');
    Store.frozen = true;
    try {
      // 2. write the staging copy
      try {
        for (final e in files.entries) {
          final f = File('${stage.path}/${e.key}');
          f.parent.createSync(recursive: true);
          await f.writeAsString(e.value, flush: true);
        }
      } on FileSystemException catch (e) {
        throw ApiError('${fileErrorText(e, 'the backup')} Nothing was changed on this phone.');
      }
      // 3. swap: current file -> pre-restore folder, staged file -> place
      final moved = <String>[];
      try {
        for (final rel in files.keys) {
          final live = File('$base/$rel');
          if (live.existsSync()) {
            final keep = File('${aside.path}/$rel');
            keep.parent.createSync(recursive: true);
            await live.rename(keep.path);
          }
          for (final x in ['$base/$rel.bak', '$base/$rel.tmp']) {
            if (File(x).existsSync()) File(x).deleteSync();
          }
          live.parent.createSync(recursive: true);
          await File('${stage.path}/$rel').rename(live.path);
          moved.add(rel);
        }
      } catch (e) {
        // put back what was already swapped
        for (final rel in moved) {
          try {
            final keep = File('${aside.path}/$rel');
            if (keep.existsSync()) await keep.rename('$base/$rel');
          } catch (e2) {
            AppLog.i('restore undo $rel: $e2');
          }
        }
        throw ApiError('Restoring stopped part-way (${fileErrorText(e, 'a file')}) and was undone. Your files are as before.');
      }
      if (settings != null) {
        try {
          await prefs.importSettings(settings);
        } catch (e) {
          AppLog.i('restore settings: $e');
          Store.notices.value = [...Store.notices.value, 'The chats and projects were restored, but the settings in the backup could not be applied ($e).'];
        }
      }
      AppLog.i('restore: ${files.length} file(s), previous files kept in ${aside.path.split('/').last}');
      return files.length + (settings == null ? 0 : 1);
    } finally {
      try {
        if (stage.existsSync()) stage.deleteSync(recursive: true);
      } catch (_) {}
      // Store.frozen stays on: the caller reloads every list from the restored files and then calls Store.frozen = false.
    }
  }

  static bool _safeRel(String rel) =>
      rel.isNotEmpty && !rel.startsWith('/') && !rel.contains('\\') && !rel.split('/').any((p) => p.isEmpty || p == '.' || p == '..');
}
