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

  // ---- first-run setup
  bool get onboarded => _sp.getBool('onboarded') ?? false;
  Future<void> setOnboarded(bool v) => _set(_sp.setBool('onboarded', v));

  // ---- first-run tour (3 short screens, skippable) and the Simple / Advanced switch
  bool get tourSeen => _sp.getBool('tourSeen') ?? false;
  Future<void> setTourSeen(bool v) => _set(_sp.setBool('tourSeen', v));

  /// Simple (default): model names, "which AI answers" and cost details of free chat stay out of sight.
  bool get advanced => _sp.getBool('advanced') ?? false;
  Future<void> setAdvanced(bool v) => _set(_sp.setBool('advanced', v));

  // ---- chat
  bool get liveSearch => _sp.getBool('liveSearch') ?? false;
  Future<void> setLiveSearch(bool v) => _set(_sp.setBool('liveSearch', v));

  // ---- coding: last chosen OpenRouter model and the spending cap for one request (US dollars)
  String get codeModel => _sp.getString('codeModel') ?? '';
  Future<void> setCodeModel(String v) => _set(_sp.setString('codeModel', v));
  double get capUsd => _sp.getDouble('capUsd') ?? 0.25;
  Future<void> setCapUsd(double v) => _set(_sp.setDouble('capUsd', v));

  // ---- chat extras
  String get customInstructions => _sp.getString('customInstructions') ?? '';
  Future<void> setCustomInstructions(String v) => _set(_sp.setString('customInstructions', v));
  String get preferProvider => _sp.getString('preferProvider') ?? '';
  Future<void> setPreferProvider(String v) => _set(_sp.setString('preferProvider', v));

  /// An OpenRouter model the person picked for chat (tried first among the OpenRouter models). Empty = automatic.
  String get chatOrModel => _sp.getString('chatOrModel') ?? '';
  Future<void> setChatOrModel(String v) => _set(_sp.setString('chatOrModel', v));

  /// Chat folders the person made (a folder can be empty, so the names are kept here; each chat remembers its folder).
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
        'themeMode': themeMode.index, 'preset': preset, 'amoled': amoled, 'reduceMotion': reduceMotion, 'fontScale': fontScale, 'capUsd': capUsd,
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
  bool get autoUpdateCheck => _sp.getBool('autoUpdateCheck') ?? true;
  int get updateLastCheck => _sp.getInt('updateLastCheck') ?? 0;
  String get whatsNewSeen => _sp.getString('whatsNewSeen') ?? '';
  Future<void> setAutoUpdateCheck(bool v) => _set(_sp.setBool('autoUpdateCheck', v));
  Future<void> setUpdateLastCheck(int ms) => _sp.setInt('updateLastCheck', ms);
  Future<void> setWhatsNewSeen(String v) => _sp.setString('whatsNewSeen', v);
}
