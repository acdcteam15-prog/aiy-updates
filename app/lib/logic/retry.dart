/// How AIy tries again before an error is shown.
///
/// Up to [kMaxTries] tries. The first service gets 3 tries in a row (a busy or slow answer often comes the next time),
/// then the other services follow; with only one service connected, it is tried again after a wait until 5 tries are
/// used. Not retried: a rejected key, missing credit, a model that does not exist or cannot be used here, or a stop.
library;

import '../state/net.dart';

const int kMaxTries = 5;

/// Seconds to wait before try 2, 3, 4 and 5 of the same model.
const List<int> kWaits = [2, 4, 8, 15];

/// Seconds to wait before another round through all services (everything was busy or unreachable).
const List<int> kRoundWaits = [8, 10, 15];

/// Whether trying again can help: temporary trouble (busy, limit, timeout, lost line, empty or thinking-only answer,
/// too big for this model).
bool isRetryable(ApiError e) {
  final s = e.status;
  if (e.message == 'Stopped.' || e.message.startsWith('Paused')) return false;
  if (s == 401 || s == 402 || s == 403 || s == 404) return false;
  if (Net.unusableText('${e.message} ${e.detail}'.toLowerCase())) return false;
  return true;
}

bool isNoInternet(ApiError e) => e.status == -1 && e.message.startsWith('No internet');

class ChainOutcome<T> {
  final T? value;
  final int attempts;
  const ChainOutcome(this.value, this.attempts);
}

/// Goes through [length] services in order and tries again as described above.
/// [call] makes one try with service [index] (it throws an [ApiError] when it fails), [wait] waits for that many
/// seconds and answers false when the person stopped the job, [skip] says a service is out for good (wrong key),
/// [onError] hears every failure. Returns the first answer, or null with the number of tries when all failed.
Future<ChainOutcome<T>> runChain<T>({
  required int length,
  required Future<T> Function(int index) call,
  required Future<bool> Function(int seconds) wait,
  required bool Function(int index) skip,
  required void Function(int index, ApiError e) onError,
  bool Function()? cancelled,
}) async {
  bool stopped() => cancelled?.call() == true;
  var attempts = 0;
  // At least two rounds through the services, and at least five tries in all.
  for (var round = 0; (round < 2 || attempts < kMaxTries) && !stopped(); round++) {
    var anyRetryable = false;
    var noNetThisRound = false;
    for (var idx = 0; idx < length; idx++) {
      if (noNetThisRound) break; // no internet: the other services cannot be reached either
      if (skip(idx)) continue;
      final sameTries = (round == 0 && idx == 0) ? 3 : 1;
      for (var t = 0; t < sameTries; t++) {
        if (stopped()) break;
        attempts++;
        try {
          return ChainOutcome(await call(idx), attempts);
        } on ApiError catch (e) {
          onError(idx, e);
          if (isNoInternet(e)) noNetThisRound = true;
          if (!isRetryable(e)) break; // the same model would fail the same way
          anyRetryable = true;
          if (t < sameTries - 1 && !await wait(kWaits[t])) break;
        }
      }
      if (stopped()) break;
    }
    if (stopped() || !anyRetryable) break;
    if (round >= 1 && attempts >= kMaxTries) break;
    // Everything was busy or unreachable: wait, then go through the services again.
    if (!await wait(kRoundWaits[round.clamp(0, 2)])) break;
  }
  return ChainOutcome<T>(null, attempts);
}
