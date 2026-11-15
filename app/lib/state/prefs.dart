import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Per-device settings (nothing secret here: the keys live in the key vault).
class LocalPrefs extends ChangeNotifier {
  final SharedPreferences _sp;
  LocalPrefs._(this._sp);

  static Future<LocalPrefs> load() async => LocalPrefs._(await SharedPreferences.getInstance());

  Future<void> _set(Future<bool> f) async {
    await f;
    notifyListeners();
  }

  // ---- look
  ThemeMode get themeMode => ThemeMode.values[(_sp.getInt('themeMode') ?? 2).clamp(0, 2)];
  int get preset => _sp.getInt('preset') ?? 0;
  bool get amoled => _sp.getBool('amoled') ?? true;
  bool get reduceMotion => _sp.getBool('reduceMotion') ?? false;
  double get fontScale => _sp.getDouble('fontScale') ?? 1.0;
  Future<void> setThemeMode(ThemeMode m) => _set(_sp.setInt('themeMode', m.index));
  Future<void> setPreset(int i) => _set(_sp.setInt('preset', i));
  Future<void> setAmoled(bool v) => _set(_sp.setBool('amoled', v));
  Future<void> setReduceMotion(bool v) => _set(_sp.setBool('reduceMotion', v));
  Future<void> setFontScale(double v) => _set(_sp.setDouble('fontScale', v));

  // ---- model picker: starred models and the last ones chosen
  List<String> get favModels => _sp.getStringList('favModels') ?? const [];
  List<String> get recentModels => _sp.getStringList('recentModels') ?? const [];
  Future<void> toggleFavModel(String id) {
    final l = [...favModels];
    l.contains(id) ? l.remove(id) : l.insert(0, id);
    return _set(_sp.setStringList('favModels', l));
  }

  Future<void> addRecentModel(String id) => _set(_sp.setStringList('recentModels', [id, ...recentModels.where((x) => x != id)].take(5).toList()));

  // ---- unsent text per chat (kept across restarts)
  Map<String, String> get drafts {
    try {
      final j = jsonDecode(_sp.getString('drafts') ?? '{}');
      return j is Map ? {for (final e in j.entries) '${e.key}': '${e.value}'} : {};
    } catch (_) {
      return {};
    }
  }

  /// Saved without notifying (typing must not repaint every screen); at most 30 chats keep a draft.
  Future<void> saveDrafts(Map<String, String> d) {
    final keep = Map.fromEntries(d.entries.where((e) => e.value.trim().isNotEmpty).toList().reversed.take(30).toList().reversed);
    return _sp.setString('drafts', jsonEncode(keep));
  }

  // ---- first-run setup
  bool get onboarded => _sp.getBool('onboarded') ?? false;
  Future<void> setOnboarded(bool v) => _set(_sp.setBool('onboarded', v));

  // ---- first-run tour (3 short screens, skippable) and the Simple / Advanced switch
  bool get tourSeen => _sp.getBool('tourSeen') ?? false;
  Future<void> setTourSeen(bool v) => _set(_sp.setBool('tourSeen', v));

  /// Simple (default): model names, "which AI answers" and cost details of free chat stay out of sight.
  bool get advanced => _sp.getBool('advanced') ?? false;
  Future<void> setAdvanced(bool v) => _set(_sp.setBool('advanced', v));

  /// Lite mode for a slow connection: less data is sent (smaller photos, shorter history, no live search, shorter answers).
  bool get liteMode => _sp.getBool('liteMode') ?? false;
  Future<void> setLiteMode(bool v) => _set(_sp.setBool('liteMode', v));

  // ---- chat
  bool get liveSearch => _sp.getBool('liveSearch') ?? false;
  Future<void> setLiveSearch(bool v) => _set(_sp.setBool('liveSearch', v));

  // ---- coding: last chosen OpenRouter model and the spending cap for one request (US dollars)
  String get codeModel => _sp.getString('codeModel') ?? '';
  Future<void> setCodeModel(String v) => _set(_sp.setString('codeModel', v));
  double get capUsd => _sp.getDouble('capUsd') ?? 0.25;
  Future<void> setCapUsd(double v) => _set(_sp.setDouble('capUsd', v));

  /// Most money for paid requests per day / per month (0 = no limit).
  double get dayCapUsd => _sp.getDouble('dayCapUsd') ?? 0;
  Future<void> setDayCapUsd(double v) => _set(_sp.setDouble('dayCapUsd', v));
  double get monthCapUsd => _sp.getDouble('monthCapUsd') ?? 0;
  Future<void> setMonthCapUsd(double v) => _set(_sp.setDouble('monthCapUsd', v));

  // ---- chat extras
  /// Short follow-up questions under each answer.
  bool get followUps => _sp.getBool('followUps') ?? true;
  Future<void> setFollowUps(bool v) => _set(_sp.setBool('followUps', v));

  String get customInstructions => _sp.getString('customInstructions') ?? '';
  Future<void> setCustomInstructions(String v) => _set(_sp.setString('customInstructions', v));
  String get preferProvider => _sp.getString('preferProvider') ?? '';
  Future<void> setPreferProvider(String v) => _set(_sp.setString('preferProvider', v));

  /// An OpenRouter model the person picked for chat (tried first among the OpenRouter models). Empty = automatic.
  String get chatOrModel => _sp.getString('chatOrModel') ?? '';
  Future<void> setChatOrModel(String v) => _set(_sp.setString('chatOrModel', v));

  /// Chat folders the person made (a folder can be empty, so the names are kept here; each chat remembers its folder).
  /// Models that answered "this model cannot be used here" (batch-only, agent-only...). Hidden from every list.
  List<String> get unusableModels => _sp.getStringList('unusableModels') ?? const [];
  Future<void> addUnusableModel(String id) async {
    if (id.isEmpty || unusableModels.contains(id)) return;
    await _set(_sp.setStringList('unusableModels', [...unusableModels, id]));
  }

  List<String> get folders => _sp.getStringList('folders') ?? const [];
  Future<void> setFolders(List<String> v) => _set(_sp.setStringList('folders', v));

  // ---- app lock (the PIN itself is never stored)
  bool get lockEnabled => _sp.getBool('lockEnabled') ?? false;
  String get pinHash => _sp.getString('pinHash') ?? '';
  String get pinSalt => _sp.getString('pinSalt') ?? '';
  int get lockDelaySec => _sp.getInt('lockDelaySec') ?? 30;
  bool get useBiometric => _sp.getBool('useBiometric') ?? false;
  Future<void> setLock({required bool on, String hash = '', String salt = ''}) async {
    await _sp.setString('pinHash', hash);
    await _sp.setString('pinSalt', salt);
    await _set(_sp.setBool('lockEnabled', on));
  }

  Future<void> setLockDelay(int s) => _set(_sp.setInt('lockDelaySec', s));
  Future<void> setUseBiometric(bool v) => _set(_sp.setBool('useBiometric', v));
  bool get askedNotifications => _sp.getBool('askedNotifications') ?? false;
  Future<void> setAskedNotifications(bool v) => _sp.setBool('askedNotifications', v);

  // ---- backup: the settings that are worth carrying to another phone (never keys or the PIN)
  Map<String, dynamic> exportSettings() => {
        'themeMode': themeMode.index, 'preset': preset, 'amoled': amoled, 'reduceMotion': reduceMotion, 'fontScale': fontScale, 'capUsd': capUsd, 'dayCapUsd': dayCapUsd, 'monthCapUsd': monthCapUsd,
        'liveSearch': liveSearch, 'customInstructions': customInstructions, 'publishRelease': publishRelease, 'preferProvider': preferProvider, 'advanced': advanced, 'folders': folders,
      };

  Future<void> importSettings(Map<String, dynamic> j) async {
    if (j['themeMode'] is int) await _sp.setInt('themeMode', (j['themeMode'] as int).clamp(0, 2));
    if (j['preset'] is int) await _sp.setInt('preset', j['preset'] as int);
    if (j['amoled'] is bool) await _sp.setBool('amoled', j['amoled'] as bool);
    if (j['reduceMotion'] is bool) await _sp.setBool('reduceMotion', j['reduceMotion'] as bool);
    if (j['fontScale'] is num) await _sp.setDouble('fontScale', (j['fontScale'] as num).toDouble().clamp(0.85, 1.4));
    if (j['capUsd'] is num) await _sp.setDouble('capUsd', (j['capUsd'] as num).toDouble().clamp(0.05, 3.0));
    if (j['liveSearch'] is bool) await _sp.setBool('liveSearch', j['liveSearch'] as bool);
    if (j['customInstructions'] is String) await _sp.setString('customInstructions', j['customInstructions'] as String);
    if (j['publishRelease'] is bool) await _sp.setBool('publishRelease', j['publishRelease'] as bool);
    if (j['preferProvider'] is String) await _sp.setString('preferProvider', j['preferProvider'] as String);
    if (j['advanced'] is bool) await _sp.setBool('advanced', j['advanced'] as bool);
    if (j['folders'] is List) await _sp.setStringList('folders', [for (final f in j['folders'] as List) '$f']);
    notifyListeners();
  }

  // ---- GitHub builds: the build that is running (so it can be picked up again after the app was closed)
  String get activeBuild => _sp.getString('activeBuild') ?? '';
  Future<void> setActiveBuild(String v) async {
    if (v.isEmpty) {
      await _sp.remove('activeBuild');
    } else {
      await _sp.setString('activeBuild', v);
    }
  }

  bool get publishRelease => _sp.getBool('publishRelease') ?? false;
  Future<void> setPublishRelease(bool v) => _set(_sp.setBool('publishRelease', v));
  int lastCode(String repo) => _sp.getInt('vc_$repo') ?? 0;
  Future<void> setLastCode(String repo, int v) => _sp.setInt('vc_$repo', v);

  // ---- model lists fetched from the providers (refreshed once a day)
  List<String> models(String provider) => _sp.getStringList('models_$provider') ?? const [];
  int modelsAt(String provider) => _sp.getInt('modelsAt_$provider') ?? 0;
  Future<void> setModels(String provider, List<String> v) async {
    await _sp.setStringList('models_$provider', v);
    await _sp.setInt('modelsAt_$provider', DateTime.now().millisecondsSinceEpoch);
  }

  // ---- how many requests each provider answered today (a guide to the free limits)
  static String _day() {
    final n = DateTime.now();
    return '${n.year}-${n.month}-${n.day}';
  }

  int usage(String provider) => _sp.getString('usageDay') == _day() ? (_sp.getInt('usage_$provider') ?? 0) : 0;
  Future<void> bumpUsage(String provider) async {
    if (_sp.getString('usageDay') != _day()) {
      await _sp.setString('usageDay', _day());
      for (final k in _sp.getKeys().where((k) => k.startsWith('usage_')).toList()) {
        await _sp.remove(k);
      }
    }
    await _sp.setInt('usage_$provider', (_sp.getInt('usage_$provider') ?? 0) + 1);
    notifyListeners();
  }

  // ---- app updates
  /// Download a found update by itself in the background, on Wi-Fi only.
  bool get autoDownloadUpdate => _sp.getBool('autoDownloadUpdate') ?? true;
  Future<void> setAutoDownloadUpdate(bool v) => _set(_sp.setBool('autoDownloadUpdate', v));

  /// The update being downloaded or waiting to be installed (UpdateInfo as JSON), so it survives closing the app.
  String get updatePending => _sp.getString('updatePending') ?? '';
  Future<void> setUpdatePending(String v) => _sp.setString('updatePending', v);
  bool get updateUserPaused => _sp.getBool('updateUserPaused') ?? false;
  Future<void> setUpdateUserPaused(bool v) => _sp.setBool('updateUserPaused', v);

  /// "Skip this version" (the version key) and "Remind me later" (when to show it again, ms since epoch).
  String get skippedUpdate => _sp.getString('skippedUpdate') ?? '';
  Future<void> setSkippedUpdate(String v) => _sp.setString('skippedUpdate', v);
  int get remindUpdateAt => _sp.getInt('remindUpdateAt') ?? 0;
  Future<void> setRemindUpdateAt(int v) => _sp.setInt('remindUpdateAt', v);

  bool get autoUpdateCheck => _sp.getBool('autoUpdateCheck') ?? true;
  int get updateLastCheck => _sp.getInt('updateLastCheck') ?? 0;
  String get whatsNewSeen => _sp.getString('whatsNewSeen') ?? '';
  Future<void> setAutoUpdateCheck(bool v) => _set(_sp.setBool('autoUpdateCheck', v));
  Future<void> setUpdateLastCheck(int ms) => _sp.setInt('updateLastCheck', ms);
  Future<void> setWhatsNewSeen(String v) => _sp.setString('whatsNewSeen', v);
}
