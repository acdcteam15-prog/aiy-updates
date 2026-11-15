import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'app_log.dart';
import 'native.dart';
import 'store.dart';

/// A paid job (a Code-tab patch or writing an app with a paid model) that was waiting for the internet.
/// It is written to the phone so that, if AIy is closed while it waits, AIy can ASK on the next start
/// (showing the price again) instead of silently forgetting it or silently spending money.
class PaidJob {
  final String id; // 'code' or 'app:<projectId>' - one per place, a newer one replaces the older
  final String kind; // 'code' | 'app'
  final String title;
  final String modelId;
  final String modelName;
  final double cost;
  final double worst;
  final int created;
  final Map<String, dynamic> data;
  PaidJob({required this.id, required this.kind, required this.title, required this.modelId, required this.modelName, required this.cost, required this.worst, required this.data, int? created})
      : created = created ?? DateTime.now().millisecondsSinceEpoch;

  Map<String, dynamic> toJson() => {'id': id, 'kind': kind, 'title': title, 'modelId': modelId, 'modelName': modelName, 'cost': cost, 'worst': worst, 'created': created, 'data': data};

  static PaidJob? fromJson(Map<String, dynamic> j) {
    try {
      return PaidJob(
        id: '${j['id']}',
        kind: '${j['kind']}',
        title: '${j['title'] ?? ''}',
        modelId: '${j['modelId'] ?? ''}',
        modelName: '${j['modelName'] ?? ''}',
        cost: (j['cost'] as num?)?.toDouble() ?? 0,
        worst: (j['worst'] as num?)?.toDouble() ?? 0,
        created: (j['created'] as num?)?.toInt(),
        data: Map<String, dynamic>.from((j['data'] as Map?) ?? const {}),
      );
    } catch (e) {
      AppLog.i('paid job skipped: $e');
      return null;
    }
  }

  String get price => worst > cost + 0.0001 ? 'about \$${cost.toStringAsFixed(3)} (at most \$${worst.toStringAsFixed(3)})' : 'about \$${cost.toStringAsFixed(3)}';
}

class PaidJobs extends ChangeNotifier {
  static final PaidJobs instance = PaidJobs();

  /// Jobs that are being held in THIS run of the app (they resume by themselves when the internet is back).
  final Map<String, PaidJob> _live = {};

  /// Jobs found on start-up: left from an earlier run. These are only continued when the person says so.
  List<PaidJob> leftOver = [];

  Future<File> _file() async => File('${(await getApplicationDocumentsDirectory()).path}/aiy/paid_jobs.json');

  Future<void> load() async {
    try {
      final j = await Store.readJson(await _file());
      leftOver = [
        if (j is List)
          for (final x in j)
            if (x is Map) ?PaidJob.fromJson(Map<String, dynamic>.from(x))
      ];
      // Older than 3 days: the project or the prices have likely changed. Drop quietly (logged).
      final old = DateTime.now().subtract(const Duration(days: 3)).millisecondsSinceEpoch;
      for (final x in leftOver.where((x) => x.created < old)) {
        AppLog.i('paid job dropped (older than 3 days): ${x.title}');
      }
      leftOver.removeWhere((x) => x.created < old);
    } catch (e) {
      AppLog.i('paid jobs load: $e');
    }
    notifyListeners();
  }

  Future<void> _save() async {
    try {
      await Store.writeJson(await _file(), [for (final j in {..._live.values, ...leftOver}) j.toJson()]);
    } catch (e) {
      AppLog.i('paid jobs save: $e');
    }
  }

  Future<void> hold(PaidJob j) async {
    _live[j.id] = j;
    leftOver.removeWhere((x) => x.id == j.id);
    notifyListeners();
    await _save();
  }

  /// The connection is back for a paid job that was waiting in this run of the app: it is not sent again by itself,
  /// the person is asked (the card shows the price). Free jobs resume without asking.
  Future<void> askNow(String id) async {
    final j = _live.remove(id);
    if (j == null) return;
    leftOver = [j, ...leftOver.where((x) => x.id != id)];
    notifyListeners();
    await _save();
    unawaited(Native.notify('AIy is back online', 'Tap to continue: ${j.title}'));
  }

  /// The job started again or was cancelled: it no longer needs remembering.
  Future<void> done(String id) async {
    final had = _live.remove(id) != null;
    final before = leftOver.length;
    leftOver.removeWhere((x) => x.id == id);
    if (had || before != leftOver.length) {
      notifyListeners();
      await _save();
    }
  }
}
