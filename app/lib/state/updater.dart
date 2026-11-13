import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'native.dart';
import 'prefs.dart';

/// What the wizard publishes next to the APK (update/version.json on Firebase Hosting).
class UpdateInfo {
  final String versionName;
  final int build;
  final String apk;
  final String sha256;
  final int size;

  /// Phones with an older build than this must update (0 = nobody is forced).
  final int minBuild;
  final String date;
  final String notes;
  const UpdateInfo({
    required this.versionName,
    required this.build,
    required this.apk,
    this.sha256 = '',
    this.size = 0,
    this.minBuild = 0,
    this.date = '',
    this.notes = '',
  });

  factory UpdateInfo.fromJson(Map<String, dynamic> m) => UpdateInfo(
        versionName: '${m['versionName'] ?? ''}',
        build: (m['build'] as num?)?.toInt() ?? 0,
        apk: '${m['apk'] ?? ''}',
        sha256: '${m['sha256'] ?? ''}',
        size: (m['size'] as num?)?.toInt() ?? 0,
        minBuild: (m['minBuild'] as num?)?.toInt() ?? 0,
        date: '${m['date'] ?? ''}',
        notes: '${m['notes'] ?? ''}',
      );

  String get key => '$versionName+$build';
}

enum UpdateStatus { idle, checking, upToDate, available, downloading, installing, error }

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

/// In-app updates without Google Play: the wizard publishes the APK and version.json on Firebase Hosting
/// (https://PROJECT.web.app/update/). The app checks them, downloads the APK, checks its SHA-256 and hands it
/// to the Android installer. The update keeps the data because it is signed with the same key.
class UpdateService extends ChangeNotifier {
  final LocalPrefs prefs;
  UpdateStatus status = UpdateStatus.idle;
  UpdateInfo? latest;
  String installedName = '';
  int installedBuild = 0;
  double progress = 0;
  String? error;

  /// The person must first allow installing from AIy (Android setting); the screen explains it.
  bool needsPermission = false;

  /// The update that was just installed (shown once as "What's new").
  UpdateInfo? whatsNew;

  Timer? _timer;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  UpdateService(this.prefs) {
    if (prefs.autoUpdateCheck) {
      _timer = Timer(const Duration(seconds: 5), () => check(auto: true));
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  bool get hasUpdate => latest != null && latest!.build > installedBuild;
  bool get required => hasUpdate && latest!.minBuild > installedBuild;
  bool get busy => status == UpdateStatus.checking || status == UpdateStatus.downloading || status == UpdateStatus.installing;

  String get _base => 'https://${Firebase.app().options.projectId}.web.app/update/';

  Future<String> _getText(Uri u) async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await c.getUrl(u);
      final res = await req.close().timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) throw 'HTTP ${res.statusCode}';
      return await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 15));
    } finally {
      c.close(force: true);
    }
  }

  /// Looks for a newer version. [auto]: the quiet check at start (at most every 6 hours, no error shown).
  Future<void> check({bool auto = false}) async {
    if (busy) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (auto && now - prefs.updateLastCheck < const Duration(hours: 6).inMilliseconds) return;
    status = UpdateStatus.checking;
    error = null;
    notifyListeners();
    try {
      final b = await Native.buildInfo();
      installedName = b.name;
      installedBuild = b.build;
      final text = await _getText(Uri.parse('${_base}version.json?t=$now'));
      final info = UpdateInfo.fromJson(jsonDecode(text) as Map<String, dynamic>);
      latest = info;
      await prefs.setUpdateLastCheck(now);
      if (hasUpdate) {
        status = UpdateStatus.available;
      } else {
        status = UpdateStatus.upToDate;
        // Just updated to this very version: show what is new, once.
        if (info.build == installedBuild && info.notes.isNotEmpty && prefs.whatsNewSeen != info.key) {
          whatsNew = info;
        }
        unawaited(_cleanup());
      }
    } catch (e) {
      debugPrint('update check: $e');
      status = UpdateStatus.idle;
      if (!auto) {
        status = UpdateStatus.error;
        error = '$e';
      }
    }
    notifyListeners();
  }

  Future<void> dismissWhatsNew() async {
    final w = whatsNew;
    whatsNew = null;
    if (w != null) await prefs.setWhatsNewSeen(w.key);
    notifyListeners();
  }

  Future<Directory> _dir() async {
    final d = Directory('${(await getTemporaryDirectory()).path}/updates');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  /// Old downloaded APKs are not needed any more.
  Future<void> _cleanup() async {
    try {
      final d = await _dir();
      for (final f in d.listSync()) {
        if (f is File) f.deleteSync();
      }
    } catch (_) {}
  }

  void _tick(double p, {bool force = false}) {
    progress = p;
    final now = DateTime.now();
    if (force || now.difference(_lastNotify).inMilliseconds > 150) {
      _lastNotify = now;
      notifyListeners();
    }
  }

  /// Downloads the new APK, checks it and opens the Android installer.
  Future<void> downloadAndInstall() async {
    final info = latest;
    if (info == null || busy) return;
    needsPermission = false;
    if (!await Native.canInstallApks()) {
      needsPermission = true;
      notifyListeners();
      await Native.openInstallSettings();
      return;
    }
    status = UpdateStatus.downloading;
    error = null;
    progress = 0;
    notifyListeners();
    HttpClient? client;
    try {
      final dir = await _dir();
      await _cleanup();
      final file = File('${dir.path}/AIy.apk');
      client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
      // The wizard stores the APK on GitHub Releases (Firebase Hosting's free plan refuses APK files):
      // version.json holds the full https address. A plain file name still means "next to version.json".
      final apkUri = Uri.parse(info.apk.startsWith('http') ? info.apk : '$_base${info.apk}');
      if (apkUri.scheme != 'https') throw 'The update address is not https.';
      final req = await client.getUrl(apkUri);
      final res = await req.close();
      if (res.statusCode != 200) throw 'HTTP ${res.statusCode}';
      final total = res.contentLength > 0 ? res.contentLength : info.size;
      final sink = file.openWrite();
      final acc = _DigestSink();
      final hash = sha256.startChunkedConversion(acc);
      var got = 0;
      try {
        await for (final chunk in res.timeout(const Duration(seconds: 30))) {
          sink.add(chunk);
          hash.add(chunk);
          got += chunk.length;
          if (total > 0) _tick(got / total);
        }
      } finally {
        await sink.flush();
        await sink.close();
      }
      hash.close();
      _tick(1, force: true);
      final got256 = acc.value?.toString().toLowerCase() ?? '';
      if (info.sha256.isNotEmpty && got256 != info.sha256.toLowerCase()) {
        await _cleanup();
        throw 'corrupt';
      }
      status = UpdateStatus.installing;
      notifyListeners();
      await Native.installApk(file.path);
      // Android now shows its installer; when it finishes it restarts the app.
      status = UpdateStatus.available;
    } catch (e) {
      debugPrint('update download: $e');
      status = UpdateStatus.error;
      error = '$e';
    } finally {
      client?.close(force: true);
    }
    notifyListeners();
  }
}
