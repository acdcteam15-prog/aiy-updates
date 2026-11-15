import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'app_log.dart';
import 'native.dart';
import 'net.dart';
import 'prefs.dart';
import 'storage.dart';

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

  Map<String, dynamic> toJson() => {'versionName': versionName, 'build': build, 'apk': apk, 'sha256': sha256, 'size': size, 'minBuild': minBuild, 'date': date, 'notes': notes};

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

enum UpdateStatus { idle, checking, upToDate, available, downloading, paused, ready, installing, error }

/// In-app updates without Google Play: the wizard publishes the APK and version.json on Firebase Hosting
/// (https://PROJECT.web.app/update/). The app checks them, downloads the APK in the BACKGROUND (by itself, on Wi-Fi),
/// checks its SHA-256, tells the person it is ready, and hands it to the Android installer when they tap Install.
/// The update keeps the data because it is signed with the same key.
///
/// The download survives leaving the app (a notification keeps AIy running), and it also survives the app being
/// closed: what was found and how far it got is written to the phone, and the next start continues from the part
/// that is already there.
class UpdateService extends ChangeNotifier {
  final LocalPrefs prefs;
  UpdateStatus status = UpdateStatus.idle;
  UpdateInfo? latest;
  String installedName = '';
  int installedBuild = 0;
  double progress = 0;
  String? error;

  /// Bytes received and expected, the speed (bytes per second) and the seconds left (-1 = unknown).
  int got = 0;
  int total = 0;
  double speedBps = 0;
  int etaSec = -1;

  /// Why the download has not started: '' | 'offline' | 'cellular' | 'metered' | 'unknown' (not on Wi-Fi).
  String waiting = '';

  /// The person paused it (it stays paused, also after a restart, until they tap Resume).
  bool userPaused = false;

  /// The person must first allow installing from AIy (Android setting); the screen explains it.
  bool needsPermission = false;

  /// The update that was just installed (shown once as "What's new").
  UpdateInfo? whatsNew;

  Timer? _timer;
  Timer? _retry;
  AiCancel? _cancel;
  bool _mobileOk = false;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastNote = DateTime.fromMillisecondsSinceEpoch(0);
  final List<(int, int)> _samples = [];

  UpdateService(this.prefs) {
    unawaited(_restore());
    if (prefs.autoUpdateCheck) {
      _timer = Timer(const Duration(seconds: 5), () => check(auto: true));
    }
    // "Stop" in the "AIy is working" notification also pauses a running update download (it continues next time).
    Native.listenWorkStop(() {
      if (status == UpdateStatus.downloading) pause(user: false);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _retry?.cancel();
    super.dispose();
  }

  bool get hasUpdate => latest != null && latest!.build > installedBuild;
  bool get required => hasUpdate && latest!.minBuild > installedBuild;
  bool get busy => status == UpdateStatus.checking || status == UpdateStatus.downloading || status == UpdateStatus.installing;

  /// Whether the update is shown on the home screen: not when it was skipped, and not before "remind me later" is over.
  /// An update that is required is always shown.
  bool get visible {
    if (!hasUpdate) return false;
    if (required) return true;
    if (prefs.skippedUpdate == latest!.key) return false;
    return DateTime.now().millisecondsSinceEpoch >= prefs.remindUpdateAt;
  }

  bool get skipped => hasUpdate && prefs.skippedUpdate == latest!.key;

  String get _base => 'https://${Firebase.app().options.projectId}.web.app/update/';

  Future<String> _getText(Uri u) async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await c.getUrl(u);
      final res = await req.close().timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) throw 'HTTP ${res.statusCode}';
      return await res.transform(const Utf8Decoder(allowMalformed: true)).join().timeout(const Duration(seconds: 15));
    } finally {
      c.close(force: true);
    }
  }

  // ------------------------------------------------------------------ files and saved state
  /// Not the cache folder: Android may empty that while the update is still being downloaded.
  Future<Directory> _dir() async {
    final d = Directory('${(await getApplicationDocumentsDirectory()).path}/aiy/updates');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  Future<File> _apk() async => File('${(await _dir()).path}/AIy.apk');

  /// Old downloaded APKs (and parts) are not needed any more.
  Future<void> _cleanup() async {
    try {
      final d = await _dir();
      for (final f in d.listSync()) {
        if (f is File) f.deleteSync();
      }
    } catch (e) {
      AppLog.i('update cleanup: $e');
    }
  }

  Future<void> _clearPending() async {
    await prefs.setUpdatePending('');
    await prefs.setUpdateUserPaused(false);
  }

  /// The finished file is the right size and has the right SHA-256.
  Future<bool> _verified(File f, UpdateInfo info) async {
    try {
      if (!f.existsSync()) return false;
      if (info.size > 0 && f.lengthSync() != info.size) return false;
      if (info.sha256.isEmpty) return true;
      final h = (await sha256.bind(f.openRead()).first).toString().toLowerCase();
      return h == info.sha256.toLowerCase();
    } catch (e) {
      AppLog.i('update verify: $e');
      return false;
    }
  }

  /// After the app was closed: what was found, paused or finished comes back from the phone.
  Future<void> _restore() async {
    final raw = prefs.updatePending;
    if (raw.isEmpty) return;
    try {
      final info = UpdateInfo.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      final b = await Native.buildInfo();
      installedName = b.name;
      installedBuild = b.build;
      if (info.build <= installedBuild) {
        // This version is installed now.
        await _clearPending();
        await _cleanup();
        notifyListeners();
        return;
      }
      latest = info;
      userPaused = prefs.updateUserPaused;
      final f = await _apk();
      if (await _verified(f, info)) {
        status = UpdateStatus.ready;
      } else {
        if (f.existsSync()) f.deleteSync();
        status = userPaused ? UpdateStatus.paused : UpdateStatus.available;
        final part = File('${f.path}.part');
        if (part.existsSync() && info.size > 0) {
          got = part.lengthSync();
          total = info.size;
          progress = (got / info.size).clamp(0.0, 1.0);
        }
        if (!userPaused) unawaited(_background());
      }
      AppLog.i('update: restored ${info.key} as ${status.name}');
      notifyListeners();
    } catch (e) {
      AppLog.i('update restore: $e');
    }
  }

  // ------------------------------------------------------------------ checking
  /// Looks for a newer version. [auto]: the quiet check at start (at most every 6 hours, no error shown).
  Future<void> check({bool auto = false}) async {
    if (busy) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (auto && now - prefs.updateLastCheck < const Duration(hours: 6).inMilliseconds) return;
    final before = status;
    final beforeKey = latest?.key;
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
        if (!auto) {
          // A person who taps "Check for updates" wants to see it: skipping and reminders are over.
          await prefs.setSkippedUpdate('');
          await prefs.setRemindUpdateAt(0);
        }
        if (beforeKey != null && beforeKey != info.key) {
          // A newer version than the one that was being downloaded: start over with the new one.
          await _cleanup();
          userPaused = false;
          await prefs.setUpdateUserPaused(false);
        }
        await prefs.setUpdatePending(jsonEncode(info.toJson()));
        final same = beforeKey == info.key;
        status = same && (before == UpdateStatus.ready || before == UpdateStatus.paused) ? before : UpdateStatus.available;
        if (status == UpdateStatus.available) unawaited(_background());
      } else {
        status = UpdateStatus.upToDate;
        await _clearPending();
        // Just updated to this very version: show what is new, once.
        if (info.build == installedBuild && info.notes.isNotEmpty && prefs.whatsNewSeen != info.key) {
          whatsNew = info;
        }
        unawaited(_cleanup());
      }
    } catch (e) {
      AppLog.i('update check: $e');
      status = before == UpdateStatus.checking ? UpdateStatus.idle : before;
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

  // ------------------------------------------------------------------ the background download
  void _tick(int got, {bool force = false}) {
    this.got = got;
    progress = total > 0 ? (got / total).clamp(0.0, 1.0) : 0;
    final now = DateTime.now();
    final ms = now.millisecondsSinceEpoch;
    _samples.add((ms, got));
    while (_samples.length > 2 && ms - _samples.first.$1 > 6000) {
      _samples.removeAt(0);
    }
    if (_samples.length >= 2) {
      final dt = (_samples.last.$1 - _samples.first.$1) / 1000;
      if (dt > 0.5) speedBps = (_samples.last.$2 - _samples.first.$2) / dt;
    }
    etaSec = (total > 0 && speedBps > 1) ? ((total - got) / speedBps).ceil() : -1;
    if (force || now.difference(_lastNotify).inMilliseconds > 150) {
      _lastNotify = now;
      notifyListeners();
    }
    // The notification that keeps AIy running in the background also shows how far it is.
    if (now.difference(_lastNote).inSeconds >= 3 && latest != null) {
      _lastNote = now;
      unawaited(Native.workShow('Downloading AIy ${latest!.versionName}', '${(progress * 100).round()}%${speedBps > 1 ? ' · ${StorageInfo.fmt(speedBps.round())}/s' : ''}'));
    }
  }

  /// Starts the download by itself when allowed: automatic downloads on, not skipped, not snoozed, not paused.
  Future<void> _background() async {
    final info = latest;
    if (info == null || !hasUpdate || userPaused) return;
    if (!prefs.autoDownloadUpdate && !_mobileOk) return;
    if (!required) {
      if (prefs.skippedUpdate == info.key) return;
      if (DateTime.now().millisecondsSinceEpoch < prefs.remindUpdateAt) return;
    }
    await startDownload(auto: true);
  }

  void _scheduleRetry() {
    _retry?.cancel();
    // While it waits for Wi-Fi or the internet: look again every 45 seconds, quietly.
    _retry = Timer(const Duration(seconds: 45), () {
      if (status == UpdateStatus.available && !userPaused && hasUpdate) unawaited(_background());
    });
  }

  /// Downloads the update. [mobileOk]: the person agreed to use mobile data. [auto]: started by AIy itself.
  Future<void> startDownload({bool mobileOk = false, bool auto = false}) async {
    final info = latest;
    if (info == null || !hasUpdate) return;
    if (status == UpdateStatus.downloading || status == UpdateStatus.installing || status == UpdateStatus.ready) return;
    if (mobileOk) _mobileOk = true;
    final net = await Native.networkKind();
    final ok = net == 'wifi' || (_mobileOk && net != 'none');
    if (!ok) {
      waiting = net == 'none' ? 'offline' : net;
      status = UpdateStatus.available;
      AppLog.i('update: waiting (${waiting})');
      _scheduleRetry();
      notifyListeners();
      return;
    }
    waiting = '';
    _retry?.cancel();
    userPaused = false;
    await prefs.setUpdateUserPaused(false);
    await prefs.setUpdatePending(jsonEncode(info.toJson()));
    status = UpdateStatus.downloading;
    error = null;
    total = info.size;
    speedBps = 0;
    etaSec = -1;
    _samples.clear();
    final file = await _apk();
    final part = File('${file.path}.part');
    got = part.existsSync() ? part.lengthSync() : 0;
    progress = total > 0 ? (got / total).clamp(0.0, 1.0) : 0;
    notifyListeners();
    final token = _cancel = AiCancel();
    unawaited(Native.workShow('Downloading AIy ${info.versionName}', got > 0 ? 'Continuing…' : 'Starting…'));
    try {
      // Finished earlier (for example before the app was closed)?
      if (file.existsSync() && !await _verified(file, info)) file.deleteSync();
      if (!file.existsSync()) {
        // The wizard stores the APK on GitHub Releases (Firebase Hosting's free plan refuses APK files):
        // version.json holds the full https address. A plain file name still means "next to version.json".
        final apkUri = Uri.parse(info.apk.startsWith('http') ? info.apk : '$_base${info.apk}');
        if (apkUri.scheme != 'https') throw 'The update address is not https.';
        // A broken or slow line continues where it stopped (the part stays in "AIy.apk.part").
        await Net.download(apkUri, file, cancel: token, onProgress: _tick);
      }
      _tick(total > 0 ? total : got, force: true);
      if (!await _verified(file, info)) {
        await _cleanup();
        throw 'corrupt';
      }
      status = UpdateStatus.ready;
      progress = 1;
      AppLog.i('update: ${info.key} downloaded and checked');
      await Native.workHide();
      _announceReady(info);
    } on ApiError catch (e) {
      if (e.status == -2) {
        status = UpdateStatus.paused;
        AppLog.i('update: paused at ${(progress * 100).round()}%');
      } else if (e.status == -1) {
        // The line broke: the part stays, and it continues by itself when the connection is back.
        status = UpdateStatus.available;
        waiting = 'offline';
        AppLog.i('update: connection lost at ${(progress * 100).round()}%: ${e.message}');
        _scheduleRetry();
      } else {
        status = UpdateStatus.error;
        error = e.message;
        AppLog.i('update download: ${e.message}');
      }
    } catch (e) {
      AppLog.i('update download: $e');
      status = UpdateStatus.error;
      error = '$e';
    } finally {
      if (status != UpdateStatus.ready) unawaited(Native.workHide());
    }
    notifyListeners();
  }

  /// A notification (the banner inside the app shows on its own): not when the update is skipped or snoozed.
  void _announceReady(UpdateInfo info) {
    if (!visible) return;
    unawaited(Native.notify('AIy ${info.versionName} is ready to install', 'Open AIy and tap Install. Nothing is lost.'));
  }

  /// Pauses the download. [user]: the person tapped Pause (it stays paused until Resume); otherwise it continues
  /// by itself the next time AIy is opened.
  Future<void> pause({bool user = true}) async {
    if (status != UpdateStatus.downloading) return;
    if (user) {
      userPaused = true;
      await prefs.setUpdateUserPaused(true);
    }
    _cancel?.cancel();
  }

  Future<void> resume() async {
    userPaused = false;
    await prefs.setUpdateUserPaused(false);
    if (status == UpdateStatus.paused || status == UpdateStatus.error) status = UpdateStatus.available;
    await startDownload(mobileOk: _mobileOk);
  }

  /// AIy came back on the screen: pick up a waiting or interrupted download, and look for a new version.
  void onResume() {
    if (hasUpdate && !userPaused && (status == UpdateStatus.available || status == UpdateStatus.paused)) {
      if (status == UpdateStatus.paused) status = UpdateStatus.available;
      unawaited(_background());
    }
    if (prefs.autoUpdateCheck) unawaited(check(auto: true));
  }

  // ------------------------------------------------------------------ installing, skipping
  /// Opens the Android installer (the update is downloaded and checked).
  Future<void> install() async {
    final info = latest;
    if (info == null || status != UpdateStatus.ready) return;
    needsPermission = false;
    if (!await Native.canInstallApks()) {
      needsPermission = true;
      notifyListeners();
      await Native.openInstallSettings();
      return;
    }
    status = UpdateStatus.installing;
    notifyListeners();
    try {
      final f = await _apk();
      if (!await _verified(f, info)) {
        // The file was damaged on the phone: get it again.
        await _cleanup();
        status = UpdateStatus.available;
        notifyListeners();
        await startDownload(mobileOk: _mobileOk);
        return;
      }
      await Native.installApk(f.path);
      // Android now shows its installer; when it finishes it restarts the app.
      status = UpdateStatus.ready;
    } catch (e) {
      AppLog.i('update install: $e');
      status = UpdateStatus.error;
      error = '$e';
    }
    notifyListeners();
  }

  /// "Skip this version": no banner and no automatic download for it; a newer version is shown again.
  Future<void> skip() async {
    final info = latest;
    if (info == null || required) return;
    await prefs.setSkippedUpdate(info.key);
    _cancel?.cancel();
    _retry?.cancel();
    await _cleanup();
    status = UpdateStatus.available;
    progress = 0;
    got = 0;
    AppLog.i('update: ${info.key} skipped');
    notifyListeners();
  }

  /// "Remind me tomorrow".
  Future<void> remindLater() async {
    if (required) return;
    await prefs.setRemindUpdateAt(DateTime.now().add(const Duration(hours: 24)).millisecondsSinceEpoch);
    notifyListeners();
  }
}
