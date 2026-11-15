import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'app_log.dart';

/// Safe saving and loading of AIy's own files (chats, history, projects, spending, APK list).
///
/// Saving: the new text goes to `name.tmp`, is flushed to disk, the old file becomes `name.bak`,
/// and only then `name.tmp` takes its place. A crash or a dead battery in the middle leaves either
/// the old file or the `.bak` - never a half-written file.
///
/// Loading: a file that cannot be read is NOT thrown away. It is kept as `name.broken-<time>`,
/// the last good copy (`name.bak`) is used instead, and the person is told once.
class Store {
  /// True while a backup is being restored: saves wait so they cannot overwrite the restored files.
  static bool frozen = false;

  /// Messages for the person (a damaged file was found). The home screen shows them once.
  static final ValueNotifier<List<String>> notices = ValueNotifier(const []);

  static final Map<String, Future<void>> _queue = {};

  static void _notice(String m) {
    AppLog.i('store: $m');
    notices.value = [...notices.value, m];
  }

  static void clearNotices() => notices.value = const [];

  static String _label(File f) => f.uri.pathSegments.isEmpty ? f.path : f.uri.pathSegments.last;

  /// Reads and decodes a JSON file. Null when there is nothing usable (and nothing was lost).
  static Future<dynamic> readJson(File f) async {
    final bak = File('${f.path}.bak');
    if (f.existsSync()) {
      try {
        return jsonDecode(await f.readAsString());
      } catch (e) {
        final kept = await _quarantine(f);
        AppLog.i('store: ${_label(f)} could not be read ($e)');
        if (bak.existsSync()) {
          try {
            final j = jsonDecode(await bak.readAsString());
            await bak.copy(f.path);
            _notice('${_label(f)} was damaged. The last good copy was loaded; the damaged file was kept as $kept.');
            return j;
          } catch (_) {}
        }
        _notice('${_label(f)} was damaged and there was no good copy. It was kept as $kept, so nothing was deleted. Send it in the chat with the developer if you need it back.');
        return null;
      }
    }
    // The app stopped between the two renames of a save: the previous version is in .bak.
    if (bak.existsSync()) {
      try {
        final j = jsonDecode(await bak.readAsString());
        await bak.copy(f.path);
        AppLog.i('store: ${_label(f)} recovered from .bak');
        return j;
      } catch (_) {}
    }
    return null;
  }

  static Future<String> _quarantine(File f) async {
    final n = DateTime.now();
    String t(int v) => v.toString().padLeft(2, '0');
    final name = '${f.path}.broken-${n.year}${t(n.month)}${t(n.day)}-${t(n.hour)}${t(n.minute)}${t(n.second)}';
    try {
      await f.rename(name);
    } catch (e) {
      try {
        await f.copy(name);
      } catch (e2) {
        AppLog.i('store: could not keep damaged ${_label(f)}: $e2');
      }
    }
    return name.split('/').last;
  }

  /// Saves an object as JSON safely. Saves of the same file run one after another.
  static Future<void> writeJson(File f, Object? data) => writeText(f, jsonEncode(data));

  static Future<void> writeText(File f, String text) {
    final key = f.path;
    final prev = _queue[key] ?? Future<void>.value();
    final next = prev.catchError((_) {}).then((_) => _write(f, text));
    _queue[key] = next;
    return next.whenComplete(() {
      if (identical(_queue[key], next)) _queue.remove(key);
    });
  }

  static Future<void> _write(File f, String text) async {
    if (frozen) {
      AppLog.i('store: save of ${_label(f)} skipped (restore running)');
      return;
    }
    f.parent.createSync(recursive: true);
    final tmp = File('${f.path}.tmp');
    try {
      final raf = await tmp.open(mode: FileMode.write);
      try {
        await raf.writeString(text);
        await raf.flush();
      } finally {
        await raf.close();
      }
      if (f.existsSync()) await f.rename('${f.path}.bak');
      await tmp.rename(f.path);
    } on FileSystemException catch (e) {
      try {
        if (tmp.existsSync()) tmp.deleteSync();
      } catch (_) {}
      throw StoreError.fromFs(e, _label(f));
    }
  }

  /// Removes a file together with its .bak/.tmp companions.
  static void delete(File f) {
    for (final p in [f.path, '${f.path}.bak', '${f.path}.tmp']) {
      try {
        final x = File(p);
        if (x.existsSync()) x.deleteSync();
      } catch (e) {
        AppLog.i('store: delete $p: $e');
      }
    }
  }
}

/// A save that failed, in plain words.
class StoreError implements Exception {
  final String message;
  final bool full;
  StoreError(this.message, {this.full = false});

  factory StoreError.fromFs(FileSystemException e, String what) {
    final code = e.osError?.errorCode ?? 0;
    final msg = '${e.message} ${e.osError?.message ?? ''}'.toLowerCase();
    if (code == 28 || msg.contains('no space')) {
      return StoreError('The phone storage is full, so $what could not be saved. Free some space (Settings > Storage on the phone, or delete old builds in AIy) and try again.', full: true);
    }
    if (code == 13 || msg.contains('permission denied')) {
      return StoreError('Android did not allow AIy to save $what (permission denied). Restart the phone; if it keeps happening, reinstall AIy after making a backup.');
    }
    return StoreError('$what could not be saved: ${e.message}${e.osError == null ? '' : ' (${e.osError!.message})'}.');
  }

  @override
  String toString() => message;
}

/// Turns any file error into plain words (used where errors are shown to the person).
String fileErrorText(Object e, String what) {
  if (e is StoreError) return e.message;
  if (e is FileSystemException) return StoreError.fromFs(e, what).message;
  return '$e';
}
