import 'package:flutter/foundation.dart';

import 'native.dart';

/// The person's own keys (bring your own key). They are stored encrypted on this phone only
/// and are sent to nobody except the service each key belongs to.
class KeyVault extends ChangeNotifier {
  static const ids = ['gemini', 'openrouter', 'groq', 'github'];
  final Map<String, String> _keys = {};
  bool loaded = false;

  Future<void> load() async {
    for (final id in ids) {
      _keys[id] = await Native.secretGet(id);
    }
    loaded = true;
    notifyListeners();
  }

  String get(String id) => _keys[id] ?? '';
  bool has(String id) => get(id).isNotEmpty;

  /// At least one service that can answer.
  bool get canChat => has('gemini') || has('openrouter') || has('groq');

  Future<void> set(String id, String value) async {
    final v = value.trim();
    await Native.secretSet(id, v);
    _keys[id] = v;
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
    if (t.startsWith('ghp_') || t.startsWith('github_pat_') || t.startsWith('gho_')) return 'github';
    if (t.startsWith('AIza') || t.startsWith('AQ.')) return 'gemini';
    return '';
  }
}
