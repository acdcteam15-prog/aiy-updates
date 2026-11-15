import 'package:flutter/foundation.dart';

import 'net.dart';

/// Notices a slow line. It is only decided after requests TIMED OUT or STALLED (never by measuring every request):
/// two such events within ten minutes mean "slow". Then every wait is made longer, and the person is offered
/// Lite mode. Three quick answers in a row mean the line is fine again.
class SlowLine extends ChangeNotifier {
  SlowLine({this.window = const Duration(minutes: 10), this.needed = 2, this.goodMs = 2500, this.goodNeeded = 3});

  final Duration window;
  final int needed;
  final int goodMs;
  final int goodNeeded;

  bool slow = false;

  /// How many times longer than normal AIy waits (1, 2 or 3).
  double factor = 1.0;

  /// The person pressed "Keep waiting": the offer stays hidden until the line has been fine again.
  bool offerHidden = false;

  final List<int> _events = [];
  int _good = 0;

  /// The offer of Lite mode should be on screen.
  bool get offer => slow && !offerHidden;

  /// Connects this detector to the network layer.
  void attach() {
    Net.onTimeout = onTimeout;
    Net.onFirstByte = onFirstByte;
  }

  void onTimeout() {
    final now = DateTime.now().millisecondsSinceEpoch;
    _events.removeWhere((t) => now - t > window.inMilliseconds);
    _events.add(now);
    _good = 0;
    if (_events.length >= needed) {
      final f = _events.length >= needed * 2 ? 3.0 : 2.0;
      if (!slow || f != factor) {
        slow = true;
        factor = f;
        Net.factor = f;
        notifyListeners();
      }
    }
  }

  void onFirstByte(int ms) {
    if (ms > goodMs) {
      _good = 0;
      return;
    }
    if (!slow) return;
    _good++;
    if (_good >= goodNeeded) {
      slow = false;
      factor = 1.0;
      Net.factor = 1.0;
      offerHidden = false;
      _events.clear();
      _good = 0;
      notifyListeners();
    }
  }

  /// "Keep waiting" (or Lite mode was chosen): stop showing the offer.
  void hideOffer() {
    offerHidden = true;
    notifyListeners();
  }
}
