import 'package:flutter/widgets.dart';

import 'ai.dart';
import 'net.dart';

/// What the "OpenRouter had a problem" pop-up needs to know, and what Retry / Switch model should do.
class AiProblem {
  /// The OpenRouter part of the failure.
  final ApiError error;

  /// Everything that happened (when several services were tried, what each of them said).
  final ApiError whole;

  /// Short name of the thing that was being done ("Chat", "Writing the patch").
  final String where;

  /// Does the same thing again.
  final Future<void> Function()? retry;

  /// Does it again with a model the person picks (only where the person chose the model themselves).
  final Future<void> Function(OrModel m)? retryWith;

  /// The cost to show before [retryWith] is used (estimate and the most it can ever cost).
  final ({double cost, double worst}) Function(OrModel m)? costOf;

  /// The OpenRouter model that was used (to mark it in the picker).
  final String modelId;

  /// True when the failure came from OpenRouter (the original pop-up); false for any other failure of a job.
  final bool openRouter;
  const AiProblem({required this.error, required this.whole, this.where = '', this.retry, this.retryWith, this.costOf, this.modelId = '', this.openRouter = true});
}

/// Where OpenRouter errors are shown to the person as a pop-up. The screens set [presenter]; the state classes call [report].
class ErrorCenter {
  static final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
  static Future<void> Function(AiProblem p)? presenter;

  /// Opens a new chat that asks AIy to explain an error (set by the home screen).
  static void Function(String question)? askAi;

  static String _lastKey = '';
  static int _lastAt = 0;

  /// Shows the pop-up when [e] is (or contains) an OpenRouter failure. Returns true when it did.
  static bool report(
    Object e, {
    String where = '',
    Future<void> Function()? retry,
    Future<void> Function(OrModel m)? retryWith,
    ({double cost, double worst}) Function(OrModel m)? costOf,
    String modelId = '',
    bool general = false,
  }) {
    if (presenter == null) return false;
    final part = e is ApiError ? e.openRouterPart : null;
    if (part == null) {
      // Any other failure: a card with Retry / Ask AIy / Copy report, for unexpected errors and service errors.
      // Plain checks ("this zip is empty") stay as text on the screen only.
      if (!general) return false;
      if (e is ApiError && (e.status == null || e.isConnection)) return false;
      final ae = e is ApiError ? e : ApiError('$e');
      final key = 'g|$where|${ae.message}';
      final now = DateTime.now().millisecondsSinceEpoch;
      if (key == _lastKey && now - _lastAt < 4000) return true;
      _lastKey = key;
      _lastAt = now;
      presenter!(AiProblem(error: ae, whole: ae, where: where, retry: retry, retryWith: retryWith, costOf: costOf, modelId: modelId, openRouter: false));
      return true;
    }
    // The same failure reported by two layers in a row opens one pop-up, not two.
    final key = '${part.status}|${part.model}|${part.message}';
    final now = DateTime.now().millisecondsSinceEpoch;
    if (key == _lastKey && now - _lastAt < 4000) return true;
    _lastKey = key;
    _lastAt = now;
    presenter!(AiProblem(error: part, whole: e as ApiError, where: where, retry: retry, retryWith: retryWith, costOf: costOf, modelId: modelId));
    return true;
  }
}
