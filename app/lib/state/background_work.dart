import 'dart:async';

/// What the "AIy is working" notification should say: null when nothing is going on.
/// Pure on purpose (the notification is written from this, and it is easy to test).
({String title, String text})? workSummary({
  required bool chatBusy,
  required String chatText,
  required String codeBusy,
  required bool asking,
  required String builderBusy,
  required bool buildRunning,
  required String buildStatus,
  required int waitingForInternet,
  required bool resending,
}) {
  final lines = <String>[];
  if (chatBusy) lines.add(chatText.isEmpty ? 'Thinking about an answer…' : 'Writing an answer (${chatText.length} letters so far)…');
  if (codeBusy.isNotEmpty) lines.add(codeBusy);
  if (asking) lines.add('Answering a question about the project…');
  if (builderBusy.isNotEmpty) lines.add(builderBusy);
  if (buildRunning) lines.add(buildStatus.isEmpty ? 'Building the app on GitHub…' : 'Building: $buildStatus');
  if (resending) lines.add('Sending the waiting requests again…');
  if (waitingForInternet > 0) lines.add(waitingForInternet == 1 ? 'Waiting for the internet (1 request)' : 'Waiting for the internet ($waitingForInternet requests)');
  if (lines.isEmpty) return null;
  final first = lines.first.length > 110 ? '${lines.first.substring(0, 110)}…' : lines.first;
  return (title: lines.length > 1 ? 'AIy is working (${lines.length} jobs)' : 'AIy is working', text: first);
}

/// Keeps AIy alive while it works: shows the notification (an Android "foreground service") whenever a job runs or
/// waits, updates it with what is going on, and removes it a few seconds after everything is done.
class BackgroundWork {
  BackgroundWork({required this.summary, required this.show, required this.hide, this.minGap = const Duration(milliseconds: 1500), this.linger = const Duration(seconds: 4)});

  /// Reads the current state of the app and returns [workSummary].
  final ({String title, String text})? Function() summary;
  final Future<void> Function(String title, String text) show;
  final Future<void> Function() hide;
  final Duration minGap;
  final Duration linger;

  bool _on = false;
  String _last = '';
  int _lastAt = 0;
  Timer? _later;
  Timer? _off;

  bool get isOn => _on;

  /// Call whenever something in the app changed (the notifiers of the screens call it).
  void changed() {
    final s = summary();
    if (s == null) {
      _later?.cancel();
      _off ??= Timer(linger, _turnOff);
      return;
    }
    _off?.cancel();
    _off = null;
    final key = '${s.title}|${s.text}';
    if (_on && key == _last) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final gap = minGap.inMilliseconds;
    if (!_on || now - _lastAt >= gap) {
      _push(s, key, now);
    } else {
      // At most one update every second or two, with the newest words.
      _later ??= Timer(Duration(milliseconds: gap - (now - _lastAt)), () {
        _later = null;
        final n = summary();
        if (n != null) _push(n, '${n.title}|${n.text}', DateTime.now().millisecondsSinceEpoch);
      });
    }
  }

  void _push(({String title, String text}) s, String key, int now) {
    _on = true;
    _last = key;
    _lastAt = now;
    unawaited(show(s.title, s.text));
  }

  void _turnOff() {
    _off = null;
    if (summary() != null) return;
    _on = false;
    _last = '';
    unawaited(hide());
  }

  void dispose() {
    _later?.cancel();
    _off?.cancel();
  }
}
