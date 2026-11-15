import 'package:flutter/foundation.dart';

import 'app_log.dart';
import 'native.dart';

/// The person's own keys (bring your own key). They are stored encrypted on this phone only
/// and are sent to nobody except the service each key belongs to.
class KeyVault extends ChangeNotifier {
  static const ids = ['gemini', 'openrouter', 'groq', 'mistral', 'cerebras', 'nvidia', 'cloudflare', 'cloudflare_acct', 'github'];
  final Map<String, String> _keys = {};
  bool loaded = false;

  /// Keys that are stored but cannot be opened on this phone (copied from another phone). Shown as "connect again".
  final List<String> lost = [];

  /// Keys the vault could not read for another reason.
  final List<String> unreadable = [];

  Future<void> load() async {
    lost.clear();
    unreadable.clear();
    for (final id in ids) {
      try {
        _keys[id] = await Native.secretGet(id);
      } on VaultError catch (e) {
        _keys[id] = '';
        (e.lost ? lost : unreadable).add(id);
        AppLog.i('vault: $id ${e.lost ? 'lost' : 'unreadable'} (${e.detail})');
      }
    }
    if (lost.isNotEmpty) {
      // Clear the copies that can never be opened, so they are not reported again on every start.
      for (final id in lost) {
        try {
          await Native.secretSet(id, '');
        } catch (_) {}
      }
    }
    loaded = true;
    notifyListeners();
  }

  /// One plain sentence for the home screen, or '' when all is well.
  String get problem {
    if (lost.isNotEmpty) {
      return 'Your saved keys (${lost.join(', ')}) could not be opened on this phone, probably because the app data was copied from another phone. Phone vaults never move keys, so please connect them again in Settings > Connect.';
    }
    if (unreadable.isNotEmpty) {
      return 'The phone\'s secure key store could not read: ${unreadable.join(', ')}. Restart the phone; if it stays, connect them again in Settings > Connect.';
    }
    return '';
  }

  void dismissProblem() {
    lost.clear();
    unreadable.clear();
    notifyListeners();
  }

  String get(String id) => _keys[id] ?? '';
  bool has(String id) => get(id).isNotEmpty;

  /// At least one service that can answer.
  bool get canChat => has('gemini') || has('openrouter') || has('groq') || has('mistral') || has('cerebras') || has('nvidia') || (has('cloudflare') && has('cloudflare_acct'));

  Future<void> set(String id, String value) async {
    final v = value.trim();
    await Native.secretSet(id, v);
    _keys[id] = v;
    lost.remove(id);
    unreadable.remove(id);
    notifyListeners();
  }

  Future<void> clearAll() async {
    for (final id in ids) {
      await Native.secretSet(id, '');
      _keys[id] = '';
    }
    notifyListeners();
  }

  /// Which service a pasted key belongs to ('' when it does not look like a key).
  static String detect(String text) {
    final t = text.trim();
    if (t.contains(RegExp(r'\s')) || t.length < 20 || t.length > 200) return '';
    if (t.startsWith('sk-or-')) return 'openrouter';
    if (t.startsWith('gsk_')) return 'groq';
    if (t.startsWith('csk-')) return 'cerebras';
    if (t.startsWith('nvapi-')) return 'nvidia';
    if (t.startsWith('ghp_') || t.startsWith('github_pat_') || t.startsWith('gho_')) return 'github';
    if (t.startsWith('AIza') || t.startsWith('AQ.')) return 'gemini';
    return '';
  }
}
