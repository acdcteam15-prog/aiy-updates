import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';

import '../logic/pin.dart';
import 'prefs.dart';

/// The app lock: a PIN (stored only as a salted hash) and, when the phone has one, the fingerprint.
class LockService extends ChangeNotifier {
  final LocalPrefs prefs;
  bool locked;
  int fails = 0;
  DateTime? _pausedAt;
  DateTime _until = DateTime.fromMillisecondsSinceEpoch(0);

  LockService(this.prefs) : locked = prefs.lockEnabled;

  bool get enabled => prefs.lockEnabled;
  int get waitSeconds => _until.isAfter(DateTime.now()) ? _until.difference(DateTime.now()).inSeconds + 1 : 0;

  void paused() => _pausedAt = DateTime.now();

  void resumed() {
    if (!prefs.lockEnabled || locked) return;
    final p = _pausedAt;
    if (p != null && DateTime.now().difference(p).inSeconds >= prefs.lockDelaySec) {
      locked = true;
      notifyListeners();
    }
  }

  bool tryPin(String pin) {
    if (waitSeconds > 0) return false;
    if (verifyPin(pin, prefs.pinSalt, prefs.pinHash)) {
      locked = false;
      fails = 0;
      notifyListeners();
      return true;
    }
    fails++;
    if (fails >= 5) {
      _until = DateTime.now().add(Duration(seconds: 15 * (fails - 4)));
    }
    notifyListeners();
    return false;
  }

  Future<bool> biometricAvailable() async {
    try {
      final a = LocalAuthentication();
      return await a.isDeviceSupported() && await a.canCheckBiometrics;
    } catch (_) {
      return false;
    }
  }

  Future<bool> tryBiometric() async {
    if (!prefs.useBiometric) return false;
    try {
      final ok = await LocalAuthentication().authenticate(localizedReason: 'Unlock AIy', biometricOnly: true, persistAcrossBackgrounding: true);
      if (ok) {
        locked = false;
        fails = 0;
        notifyListeners();
      }
      return ok;
    } catch (_) {
      return false;
    }
  }

  Future<void> enable(String pin) async {
    final salt = newSalt();
    await prefs.setLock(on: true, hash: hashPin(pin, salt), salt: salt);
    locked = false;
    notifyListeners();
  }

  Future<void> disable() async {
    await prefs.setLock(on: false);
    await prefs.setUseBiometric(false);
    locked = false;
    notifyListeners();
  }
}
