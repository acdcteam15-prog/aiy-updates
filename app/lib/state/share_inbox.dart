import 'package:flutter/foundation.dart';

import 'native.dart';

/// Things other apps share into AIy. They wait here until the person says where they go (Chat, Code or Build);
/// the chosen tab then picks them up once.
class ShareInbox extends ChangeNotifier {
  /// Waiting for the person to choose.
  SharedItem? pending;

  SharedItem? _chat;
  SharedItem? _code;
  SharedItem? _build;

  bool _started = false;

  void start() {
    if (_started) return;
    _started = true;
    Native.listenShared(check);
    check();
  }

  /// Asks the phone whether something was shared.
  Future<void> check() async {
    final s = await Native.takeShared();
    if (s == null || (s.isEmpty && s.problem.isEmpty)) return;
    pending = s;
    notifyListeners();
  }

  void choose(String where) {
    final p = pending;
    pending = null;
    if (p != null) {
      switch (where) {
        case 'chat':
          _chat = p;
        case 'code':
          _code = p;
        case 'build':
          _build = p;
      }
    }
    notifyListeners();
  }

  void dismiss() {
    pending = null;
    notifyListeners();
  }

  bool get hasForChat => _chat != null;
  bool get hasForCode => _code != null;
  bool get hasForBuild => _build != null;

  SharedItem? takeChat() {
    final x = _chat;
    _chat = null;
    return x;
  }

  SharedItem? takeCode() {
    final x = _code;
    _code = null;
    return x;
  }

  SharedItem? takeBuild() {
    final x = _build;
    _build = null;
    return x;
  }
}
