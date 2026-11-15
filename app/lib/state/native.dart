import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'app_log.dart';

/// One file that another app shared into AIy (already copied into AIy's cache).
class SharedFile {
  final String path;
  final String name;
  final int size;
  final String mime;
  const SharedFile(this.path, this.name, this.size, this.mime);
  String get lower => name.toLowerCase();
  bool get isZip => lower.endsWith('.zip') || mime.contains('zip');
  bool get isPdf => lower.endsWith('.pdf') || mime == 'application/pdf';
  bool get isImage => mime.startsWith('image/') || lower.endsWith('.png') || lower.endsWith('.jpg') || lower.endsWith('.jpeg') || lower.endsWith('.webp');
}

/// What another app shared into AIy: some text and/or up to five files.
class SharedItem {
  final String text;
  final String subject;
  final List<SharedFile> files;
  final String problem;
  const SharedItem({this.text = '', this.subject = '', this.files = const [], this.problem = ''});
  bool get isEmpty => text.trim().isEmpty && files.isEmpty;

  /// The shared text, with the subject in front when the other app gave one.
  String get fullText => subject.trim().isEmpty || text.contains(subject) ? text.trim() : '${subject.trim()}\n${text.trim()}'.trim();

  /// A short line for the "where should this go" sheet.
  String get preview {
    final parts = <String>[];
    if (text.trim().isNotEmpty) parts.add(text.trim().replaceAll(RegExp(r'\s+'), ' '));
    for (final f in files) {
      parts.add(f.name);
    }
    final l = parts.join(' · ');
    return l.length > 120 ? '${l.substring(0, 120)}…' : l;
  }
}

/// Native bridge written into MainActivity by the setup wizard: app updates, the key vault (Android Keystore),
/// picking a project zip, streamed zip reading/rebuilding, saving to Downloads and opening links.
class Native {
  static const _ch = MethodChannel('aiy/native');

  /// True while AIy reads an answer aloud (the orb shows it).
  static final ValueNotifier<bool> speaking = ValueNotifier<bool>(false);

  // ---- share into AIy
  static void Function()? _onShared;
  static final List<void Function()> _onWorkStop = [];
  static bool _handlerSet = false;

  static void _install() {
    if (_handlerSet) return;
    _handlerSet = true;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'onShared') _onShared?.call();
      if (call.method == 'onWorkStop') {
        for (final f in List.of(_onWorkStop)) {
          f();
        }
      }
      return null;
    });
  }

  /// Called when another app shares something while AIy is already open (the data is fetched with [takeShared]).
  static void listenShared(void Function() onShared) {
    _onShared = onShared;
    _install();
  }

  /// Called when the person taps "Stop" in the "AIy is working" notification.
  static void listenWorkStop(void Function() onStop) {
    _onWorkStop.add(onStop);
    _install();
  }

  /// Shows (or updates) the "AIy is working" notification and keeps the app running in the background.
  static Future<void> workShow(String title, String text) async {
    try {
      await _ch.invokeMethod<bool>('workShow', {'title': title, 'text': text});
    } catch (e) {
      debugPrint('native workShow: $e');
    }
  }

  /// Removes the notification; the app may sleep in the background again.
  static Future<void> workHide() async {
    try {
      await _ch.invokeMethod<bool>('workHide');
    } catch (e) {
      AppLog.i('native:89: $e');
    }
  }

  /// What was shared into AIy (once; null when nothing is waiting).
  static Future<SharedItem?> takeShared() async {
    try {
      final m = await _ch.invokeMethod<Map<Object?, Object?>>('takeShared');
      if (m == null) return null;
      return SharedItem(
        text: '${m['text'] ?? ''}',
        subject: '${m['subject'] ?? ''}',
        problem: '${m['problem'] ?? ''}',
        files: [
          for (final f in (m['files'] as List? ?? const []))
            if (f is Map) SharedFile('${f['path']}', '${f['name']}', (f['size'] as num?)?.toInt() ?? 0, '${f['mime'] ?? ''}')
        ],
      );
    } catch (e) {
      debugPrint('native takeShared: $e');
      return null;
    }
  }

  /// Installed app version: name ("1.0.0") and build number (the Android versionCode).
  static Future<({String name, int build})> buildInfo() async {
    try {
      final m = await _ch.invokeMethod<Map<Object?, Object?>>('buildInfo');
      return (name: '${m?['name'] ?? ''}', build: (m?['build'] as num?)?.toInt() ?? 0);
    } catch (e) {
      debugPrint('native buildInfo: $e');
      return (name: '', build: 0);
    }
  }

  static Future<bool> canInstallApks() async {
    try {
      return (await _ch.invokeMethod<bool>('canInstallApks')) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> openInstallSettings() async {
    try {
      await _ch.invokeMethod<bool>('openInstallSettings');
    } catch (e) {
      AppLog.i('native:134: $e');
    }
  }

  static Future<void> installApk(String path) async {
    await _ch.invokeMethod<bool>('installApk', {'path': path});
  }

  // ---- key vault (values are encrypted with a key that never leaves the phone's secure hardware)
  /// The kind of connection: wifi (not metered), metered (a hotspot that costs data), cellular, other, none,
  /// or unknown when the phone cannot tell. Updates download by themselves only on "wifi".
  static Future<String> networkKind() async {
    try {
      return (await _ch.invokeMethod<String>('networkKind')) ?? 'unknown';
    } catch (_) {
      return 'unknown';
    }
  }

  /// Free space for AIy's files in bytes (-1 when unknown, e.g. an older wizard build).
  static Future<int> storageFree() async {
    try {
      return (await _ch.invokeMethod<int>('storageFree')) ?? -1;
    } catch (_) {
      return -1;
    }
  }

  /// '' when nothing is stored. Throws [VaultError] when something is stored but cannot be opened on this phone.
  static Future<String> secretGet(String name) async {
    try {
      return (await _ch.invokeMethod<String>('secretGet', {'name': name})) ?? '';
    } on PlatformException catch (e) {
      throw VaultError(name, e.code == 'KEY_LOST', '${e.code}: ${e.message ?? ''}');
    } on MissingPluginException {
      return '';
    }
  }

  static Future<void> secretSet(String name, String value) async {
    try {
      await _ch.invokeMethod<bool>('secretSet', {'name': name, 'value': value});
    } on PlatformException catch (e) {
      throw VaultError(name, false, '${e.code}: ${e.message ?? ''}');
    }
  }

  /// Opens a web page in the phone's browser.
  static Future<bool> openUrl(String url) async {
    try {
      return (await _ch.invokeMethod<bool>('openUrl', {'url': url})) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Lets the person choose any file (a text file or a PDF to ask about). Copied into the app's cache. Null when cancelled.
  static Future<({String path, String name, int size})?> pickFile() async {
    final m = await _ch.invokeMethod<Map<Object?, Object?>>('pickFile');
    if (m == null) return null;
    return (path: '${m['path']}', name: '${m['name']}', size: (m['size'] as num?)?.toInt() ?? 0);
  }

  /// Makes a photo smaller (at most [maxSide] pixels on the long side, JPEG [quality]) and returns the new file, or null.
  static Future<String?> shrinkImage(String path, {int maxSide = 1024, int quality = 65}) async {
    try {
      return await _ch.invokeMethod<String>('shrinkImage', {'path': path, 'maxSide': maxSide, 'quality': quality});
    } catch (e) {
      debugPrint('native shrinkImage: $e');
      return null;
    }
  }

  /// Reads text aloud with the phone's own voice.
  static Future<void> speak(String text) async {
    try {
      await _ch.invokeMethod<bool>('speak', {'text': text});
    } catch (e) {
      debugPrint('native speak: $e');
    }
  }

  static Future<void> stopSpeaking() async {
    speaking.value = false;
    try {
      await _ch.invokeMethod<bool>('stopSpeaking');
    } catch (e) {
      AppLog.i('native:200: $e');
    }
  }

  /// A notification (used when a build finishes while AIy is in the background).
  static Future<void> notify(String title, String text) async {
    try {
      await _ch.invokeMethod<bool>('notify', {'title': title, 'text': text});
    } catch (e) {
      debugPrint('native notify: $e');
    }
  }

  static Future<void> requestNotifications() async {
    try {
      await _ch.invokeMethod<bool>('requestNotifications');
    } catch (e) {
      AppLog.i('native:215: $e');
    }
  }

  // ---- project zips
  /// Lets the person choose a .zip; it is copied into the app's cache. Null when cancelled.
  static Future<({String path, String name, int size})?> pickZip() async {
    final m = await _ch.invokeMethod<Map<Object?, Object?>>('pickZip');
    if (m == null) return null;
    return (path: '${m['path']}', name: '${m['name']}', size: (m['size'] as num?)?.toInt() ?? 0);
  }

  /// Every file in the zip with its size.
  static Future<List<({String name, int size})>> zipScan(String path) async {
    final l = await _ch.invokeMethod<List<Object?>>('zipScan', {'path': path}) ?? const [];
    return [
      for (final e in l)
        if (e is Map) (name: '${e['name']}', size: (e['size'] as num?)?.toInt() ?? 0)
    ];
  }

  /// Text of the named files (files that are too big or binary are left out).
  static Future<Map<String, String>> zipRead(String path, List<String> names, {int maxBytes = 400000}) async {
    final m = await _ch.invokeMethod<Map<Object?, Object?>>('zipRead', {'path': path, 'names': names, 'maxBytes': maxBytes}) ?? const {};
    return {for (final e in m.entries) '${e.key}': '${e.value}'};
  }

  /// Copies the whole zip to [dst] with [files] replaced or added. Returns how many files were written from [files].
  static Future<int> zipRebuild(String src, String dst, Map<String, String> files) async {
    return (await _ch.invokeMethod<int>('zipRebuild', {'src': src, 'dst': dst, 'files': files})) ?? 0;
  }

  /// The raw bytes of one file inside a zip (for uploading pictures and other binary files).
  static Future<Uint8List> zipBytes(String path, String name) async {
    final b = await _ch.invokeMethod<Uint8List>('zipBytes', {'path': path, 'name': name});
    if (b == null) throw StateError('Could not read $name from the zip.');
    return b;
  }

  /// Takes the first file ending in [ext] (".apk") out of a zip into [dir]. Returns its path, or null.
  static Future<String?> zipExtractFirst(String zip, String ext, String dir) =>
      _ch.invokeMethod<String>('zipExtractFirst', {'path': zip, 'ext': ext, 'dir': dir});

  /// Writes a new zip from text files and binary files (path inside the zip -> content).
  static Future<int> zipCreate(String dst, Map<String, String> files, Map<String, Uint8List> bytes) async =>
      (await _ch.invokeMethod<int>('zipCreate', {'dst': dst, 'files': files, 'bytes': bytes})) ?? 0;

  /// Copies a file into Downloads/AIy. Returns the place shown to the person.
  static Future<String> saveToDownloads(String path, String name) async {
    return (await _ch.invokeMethod<String>('saveToDownloads', {'path': path, 'name': name})) ?? '';
  }
}


/// The phone's key vault could not read or save a key.
class VaultError implements Exception {
  final String name;

  /// True when the key is stored but this phone cannot open it (the data was copied from another phone).
  final bool lost;
  final String detail;
  VaultError(this.name, this.lost, this.detail);

  @override
  String toString() => lost
      ? 'The saved $name key cannot be opened on this phone (it was probably copied from another phone). Connect it again: Settings > Connect.'
      : 'The phone\'s secure key store did not accept the $name key ($detail). Restart the phone and try again; if it keeps failing, remove and add the screen lock once, then connect again.';
}
