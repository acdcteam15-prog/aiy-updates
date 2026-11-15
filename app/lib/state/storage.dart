import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'app_log.dart';
import 'native.dart';
import 'store.dart';

/// One kind of data AIy keeps on the phone, with its size.
class StorageItem {
  final String id;
  final String title;
  final String note;
  final int bytes;
  final int files;
  final bool canClear;
  const StorageItem(this.id, this.title, this.note, this.bytes, this.files, this.canClear);
}

/// What AIy stores, how big it is, and cleaning it up.
class StorageInfo {
  static Future<String> _base() async => '${(await getApplicationDocumentsDirectory()).path}/aiy';

  static ({int bytes, int files}) _size(FileSystemEntity e, {bool Function(String path)? only}) {
    var b = 0, n = 0;
    try {
      if (e is File) {
        if (only == null || only(e.path)) return (bytes: e.lengthSync(), files: 1);
        return (bytes: 0, files: 0);
      }
      if (e is Directory && e.existsSync()) {
        for (final f in e.listSync(recursive: true, followLinks: false)) {
          if (f is File && (only == null || only(f.path))) {
            b += f.lengthSync();
            n++;
          }
        }
      }
    } catch (err) {
      AppLog.i('storage size ${e.path}: $err');
    }
    return (bytes: b, files: n);
  }

  static Future<List<StorageItem>> scan() async {
    final base = await _base();
    final tmp = await getTemporaryDirectory();
    StorageItem item(String id, String title, String note, ({int bytes, int files}) s, bool clear) => StorageItem(id, title, note, s.bytes, s.files, clear);
    bool spare(String p) => p.contains('.broken-') || p.contains('/pre-restore-') || p.endsWith('.tmp');
    return [
      item('apks', 'Built apps (APKs)', 'The newest apps built on GitHub, ready to install again.', _size(Directory('$base/apks')), true),
      item('updates', 'Downloaded AIy updates', 'The new AIy that is downloading or waiting to be installed. It is downloaded again if you clear it.', _size(Directory('$base/updates')), true),
      item('builds', 'Changed projects (zips)', 'The zip of every change in History.', _size(Directory('$base/builds')), false),
      item('projects', 'App ideas', 'Your app ideas and the apps written from them.', _size(Directory('$base/projects')), false),
      item('lists', 'Chats, history and settings', 'Never cleared here (use Settings > Backup to keep a copy).', _size(Directory(base), only: (p) => p.endsWith('.json') || p.endsWith('.json.bak')), false),
      item('spare', 'Kept copies', 'Damaged files kept aside and copies made before a restore.', _size(Directory(base), only: spare), true),
      item('temp', 'Temporary files', 'Picked zips, downloads in progress, shared files. Safe to clear when nothing is running.', _size(tmp), true),
    ];
  }

  /// Deletes one kind of data. Returns the bytes freed.
  static Future<int> clear(String id) async {
    final base = await _base();
    var freed = 0;
    void del(FileSystemEntity e) {
      try {
        final s = _size(e).bytes;
        e.deleteSync(recursive: true);
        freed += s;
      } catch (err) {
        AppLog.i('storage clear ${e.path}: $err');
      }
    }

    switch (id) {
      case 'temp':
        final tmp = await getTemporaryDirectory();
        if (tmp.existsSync()) {
          for (final e in tmp.listSync(followLinks: false)) {
            del(e);
          }
        }
      case 'updates':
        del(Directory('$base/updates'));
      case 'spare':
        final d = Directory(base);
        if (d.existsSync()) {
          for (final e in d.listSync(followLinks: false)) {
            final n = e.path.split('/').last;
            if (n.startsWith('pre-restore-') || n.contains('.broken-') || n.endsWith('.tmp')) del(e);
          }
        }
    }
    AppLog.i('storage: cleared $id, ${fmt(freed)}');
    return freed;
  }

  static String fmt(int b) {
    if (b < 0) return '?';
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
    if (b < 1024 * 1024 * 1024) return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
    return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  /// The start-up check: little free space, and leftovers of saves that were cut off.
  static Future<void> startupCheck() async {
    try {
      final free = await Native.storageFree();
      if (free >= 0 && free < 300 * 1024 * 1024) {
        Store.notices.value = [
          ...Store.notices.value,
          'Only ${fmt(free)} of storage is free on the phone. Building and downloading apps may fail. Free some space (Settings > Storage shows what AIy keeps).',
        ];
      }
      final d = Directory(await _base());
      if (d.existsSync()) {
        for (final f in d.listSync(recursive: true, followLinks: false)) {
          // a save that was cut off before it finished: the real file (or its .bak) is still there
          if (f is File && f.path.endsWith('.json.tmp')) {
            try {
              f.deleteSync();
            } catch (_) {}
          }
        }
      }
    } catch (e) {
      AppLog.i('startup check: $e');
    }
  }
}
