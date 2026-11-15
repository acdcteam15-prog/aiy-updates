/// How each AI service has been doing lately. A service that keeps failing (busy, limit reached, timing out)
/// is moved to the end of the fallback order for a while instead of being tried first every time.
/// It is never removed: when everything else fails it is still tried.
library;

class ServiceHealth {
  int streak = 0; // failures in a row
  int ok = 0;
  int failed = 0;
  int coolUntil = 0; // ms since epoch
  double avgMs = 0; // answer time of good answers (moving average)
  String lastError = '';
}

class HealthBook {
  final Map<String, ServiceHealth> _s = {};
  int Function() now;
  HealthBook({int Function()? clock}) : now = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  ServiceHealth of(String pid) => _s.putIfAbsent(pid, ServiceHealth.new);

  bool cooling(String pid) => of(pid).coolUntil > now();

  void success(String pid, int ms) {
    final h = of(pid);
    h.streak = 0;
    h.ok++;
    h.coolUntil = 0;
    h.avgMs = h.avgMs == 0 ? ms.toDouble() : h.avgMs * 0.7 + ms * 0.3;
  }

  /// Only failures that say something about the service count (busy, limit, timeout, server error) -
  /// not a wrong key, not a missing internet connection.
  void failure(String pid, {int? status, bool timeout = false, String message = ''}) {
    final counts = timeout || status == 429 || (status != null && status >= 500);
    final h = of(pid);
    h.lastError = message;
    if (!counts) return;
    h.failed++;
    h.streak++;
    if (h.streak >= 4) {
      h.coolUntil = now() + 10 * 60 * 1000;
    } else if (h.streak >= 2) {
      h.coolUntil = now() + 2 * 60 * 1000;
    }
  }

  /// The same entries with services that are cooling down moved to the end (order kept otherwise).
  List<T> order<T>(List<T> chain, String Function(T) pidOf) =>
      [...chain.where((e) => !cooling(pidOf(e))), ...chain.where((e) => cooling(pidOf(e)))];

  Map<String, ServiceHealth> get all => Map.unmodifiable(_s);
}
