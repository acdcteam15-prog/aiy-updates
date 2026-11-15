import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'net.dart';
import 'app_log.dart';

/// A request that could not be sent (or finished) because the internet was gone. It is sent again by itself.
class OfflineJob {
  final int id;
  final String title;
  final Future<void> Function() run;

  /// For paid OpenRouter requests: asks OpenRouter afterwards how much the lost attempt was charged.
  final Future<double> Function()? lostCost;
  final String model;

  /// Called when the person cancels the waiting request (so what was saved for a restart is forgotten too).
  final void Function()? onCancel;

  /// A request brought back after AIy was closed: no "back online" notification for it alone.
  final bool silent;
  OfflineJob(this.id, this.title, this.run, this.lostCost, this.model, {this.onCancel, this.silent = false});
}

/// Knows when the internet is gone and back. Requests that fail because of the connection wait here, and are
/// sent again, one after the other, when the connection returns. Nothing is stored: if AIy is closed, the
/// waiting requests are gone and the message of the failed job offers "Try again".
class ConnectivityService extends ChangeNotifier {
  /// [probe] answers "is the internet reachable?"; [notifier] shows a phone notification; [onLost] writes the
  /// money a lost paid attempt cost into the spending list. All three can be replaced (tests do).
  ConnectivityService({this.onLost, this.notifier, Future<bool> Function()? probe, this.poll = const Duration(seconds: 4)}) : _probe = probe ?? probeInternet;

  final Future<void> Function(String kind, String project, String model, double cost)? onLost;
  final Future<void> Function(String title, String text)? notifier;
  final Future<bool> Function() _probe;
  final Duration poll;

  final List<OfflineJob> jobs = [];
  bool offline = false;
  bool resending = false;

  /// A short message shown after the connection came back (for example about a charged attempt).
  String note = '';

  final Map<String, int> _tries = {};
  Timer? _timer;
  Timer? _noteTimer;
  bool _probing = false;
  int _seq = 0;

  bool get visible => offline || resending || note.isNotEmpty;

  /// True when [e] is a connection problem and the job was put on the waiting list.
  bool hold(ApiError e, {required String title, required Future<void> Function() run, void Function()? onCancel}) {
    if (!e.isConnection) return false;
    // The same job is not sent again and again for ever.
    if ((_tries[title] ?? 0) >= 3) {
      _tries.remove(title);
      return false;
    }
    jobs.removeWhere((j) => j.title == title);
    jobs.add(OfflineJob(++_seq, title, run, e.lostCost, e.model, onCancel: onCancel));
    offline = true;
    note = '';
    notifyListeners();
    _startProbing();
    return true;
  }

  /// Puts a request that was saved before AIy was closed back on the list. It is sent as soon as the internet works.
  void restore({required String title, required Future<void> Function() run, void Function()? onCancel}) {
    if (jobs.any((j) => j.title == title)) return;
    jobs.add(OfflineJob(++_seq, title, run, null, '', onCancel: onCancel, silent: true));
    offline = true;
    notifyListeners();
    _startProbing();
  }

  /// Gives up on everything that waits (the "Stop" of the working notification).
  void cancelAll() {
    for (final j in List<OfflineJob>.of(jobs)) {
      cancel(j);
    }
  }

  void cancel(OfflineJob j) {
    j.onCancel?.call();
    jobs.remove(j);
    _tries.remove(j.title);
    if (jobs.isEmpty && !resending) {
      offline = false;
      _timer?.cancel();
      _timer = null;
    }
    notifyListeners();
  }

  /// Looks at once (used by "Try now" and when AIy comes back to the screen).
  Future<void> nudge() async {
    if (offline) await _tick();
  }

  void _startProbing() {
    _timer?.cancel();
    _timer = Timer.periodic(poll, (_) => _tick());
    _tick();
  }

  Future<void> _tick() async {
    if (_probing || !offline) return;
    _probing = true;
    bool ok;
    try {
      ok = await _probe();
    } catch (_) {
      ok = false;
    }
    _probing = false;
    if (ok && offline) await _back();
  }

  Future<void> _back() async {
    _timer?.cancel();
    _timer = null;
    offline = false;
    if (jobs.isEmpty) {
      notifyListeners();
      return;
    }
    final waiting = List<OfflineJob>.of(jobs);
    jobs.clear();
    resending = true;
    notifyListeners();
    if (waiting.any((j) => !j.silent)) unawaited(notifier?.call('AIy is back online', waiting.length == 1 ? 'Sending again: ${waiting.first.title}' : 'Sending ${waiting.length} requests again.') ?? Future<void>.value());
    var charged = 0.0;
    for (final j in waiting) {
      if (j.lostCost != null) {
        try {
          final c = await j.lostCost!();
          if (c > 0.0001) {
            charged += c;
            await onLost?.call('lost', j.title, j.model, c);
          }
        } catch (e) {
          AppLog.i('connectivity:145: $e');
        }
      }
      _tries[j.title] = (_tries[j.title] ?? 0) + 1;
      try {
        await j.run();
      } catch (e) {
        debugPrint('resend failed: $e');
      }
      // Finished without being put back on the list: it worked (or failed for another reason).
      if (!jobs.any((x) => x.title == j.title)) _tries.remove(j.title);
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    resending = false;
    if (charged > 0) {
      note = 'Back online. The attempt that was lost was charged about \$${charged.toStringAsFixed(2)} (it may include other use of the same key). It is in the spending list.';
      _noteTimer?.cancel();
      _noteTimer = Timer(const Duration(seconds: 10), () {
        note = '';
        notifyListeners();
      });
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _noteTimer?.cancel();
    super.dispose();
  }

  /// Any answer from one of these addresses (even an error page) proves the internet works.
  static Future<bool> probeInternet() async {
    for (final u in const ['https://www.gstatic.com/generate_204', 'https://openrouter.ai']) {
      final c = HttpClient()..connectionTimeout = const Duration(seconds: 4);
      try {
        final r = await (await c.getUrl(Uri.parse(u))).close().timeout(const Duration(seconds: 6));
        await r.drain<void>();
        return true;
      } catch (_) {
        // try the next address
      } finally {
        c.close(force: true);
      }
    }
    return false;
  }
}

/// The one waiting list of the app. The screens' state classes call [hold] when a request fails.
class Offline {
  static ConnectivityService? service;

  /// True when [e] was a connection problem and [run] will be called again when the internet is back.
  static bool hold(Object e, {required String title, required Future<void> Function() run, void Function()? onCancel}) => e is ApiError && (service?.hold(e, title: title, run: run, onCancel: onCancel) ?? false);

  /// Puts a request saved before a restart back on the list.
  /// Removes a waiting job without running it (the caller takes over, e.g. the auto-fix loop pauses).
  static void drop(String title) {
    final svc = service;
    if (svc == null || title.isEmpty) return;
    for (final j in List<OfflineJob>.of(svc.jobs.where((j) => j.title == title))) {
      svc.cancel(j);
    }
  }

  static void restore({required String title, required Future<void> Function() run, void Function()? onCancel}) => service?.restore(title: title, run: run, onCancel: onCancel);
}
