import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'store.dart';
import 'app_log.dart';

class SpendEntry {
  final int ts;
  final String kind;
  final String project;
  final String model;
  final double cost;
  const SpendEntry(this.ts, this.kind, this.project, this.model, this.cost);
  Map<String, dynamic> toJson() => {'t': ts, 'k': kind, 'p': project, 'm': model, 'c': cost};
  factory SpendEntry.fromJson(Map<String, dynamic> j) => SpendEntry((j['t'] as num?)?.toInt() ?? 0, '${j['k'] ?? ''}', '${j['p'] ?? ''}', '${j['m'] ?? ''}', (j['c'] as num?)?.toDouble() ?? 0);
}

/// What the paid requests really cost (from the token counts the models report), kept on the phone.
class SpendLog extends ChangeNotifier {
  List<SpendEntry> entries = [];

  Future<File> _file() async {
    final d = Directory('${(await getApplicationDocumentsDirectory()).path}/aiy')..createSync(recursive: true);
    return File('${d.path}/spend.json');
  }

  Future<void> load() async {
    try {
      final f = await _file();
      {
        final j = await Store.readJson(f);
        if (j is List) {
          entries = [
            for (final e in j)
              if (e is Map) SpendEntry.fromJson(Map<String, dynamic>.from(e))
          ];
        }
      }
    } catch (e) {
      debugPrint('spend load: $e');
    }
    notifyListeners();
  }

  Future<void> add(String kind, String project, String model, double cost) async {
    if (cost <= 0) return;
    entries = [SpendEntry(DateTime.now().millisecondsSinceEpoch, kind, project, model, cost), ...entries];
    if (entries.length > 500) entries = entries.sublist(0, 500);
    notifyListeners();
    try {
      await Store.writeJson(await _file(), [for (final e in entries) e.toJson()]);
    } catch (e) {
      // The total in Settings would be wrong without this entry: say so instead of hiding it.
      AppLog.i('spend save: $e');
      Store.notices.value = [...Store.notices.value, 'A spending record (\$${cost.toStringAsFixed(4)}) could not be saved: ${fileErrorText(e, 'the spending list')}'];
    }
  }

  double get total => entries.fold(0.0, (s, e) => s + e.cost);

  double get today {
    final n = DateTime.now();
    return entries.where((e) {
      final d = DateTime.fromMillisecondsSinceEpoch(e.ts);
      return d.year == n.year && d.month == n.month && d.day == n.day;
    }).fold(0.0, (s, e) => s + e.cost);
  }

  /// Why a paid request of at most [worst] dollars must not start, or null. Limits of 0 are off.
  String? budgetBlock(double worst, {required double dayCap, required double monthCap}) {
    if (dayCap > 0 && today + worst > dayCap) {
      return 'This could bring today\'s spending to \$${(today + worst).toStringAsFixed(2)}, over your daily limit of \$${dayCap.toStringAsFixed(2)} (spent today: \$${today.toStringAsFixed(2)}). Use a free model, wait until tomorrow, or raise the limit in Settings > Coding.';
    }
    if (monthCap > 0 && thisMonth + worst > monthCap) {
      return 'This could bring this month\'s spending to \$${(thisMonth + worst).toStringAsFixed(2)}, over your monthly limit of \$${monthCap.toStringAsFixed(2)} (spent this month: \$${thisMonth.toStringAsFixed(2)}). Use a free model or raise the limit in Settings > Coding.';
    }
    return null;
  }

  double get thisMonth {
    final n = DateTime.now();
    return entries.where((e) {
      final d = DateTime.fromMillisecondsSinceEpoch(e.ts);
      return d.year == n.year && d.month == n.month;
    }).fold(0.0, (s, e) => s + e.cost);
  }

  /// Project -> money, biggest first.
  List<MapEntry<String, double>> byProject() {
    final m = <String, double>{};
    for (final e in entries) {
      m[e.project] = (m[e.project] ?? 0) + e.cost;
    }
    return m.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  }

  Future<void> clear() async {
    entries = [];
    notifyListeners();
    try {
      await Store.writeJson(await _file(), const []);
    } catch (e) {
      AppLog.i('spend clear: $e');
    }
  }
}
