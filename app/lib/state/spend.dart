import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

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
      if (f.existsSync()) {
        final j = jsonDecode(await f.readAsString());
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
      await (await _file()).writeAsString(jsonEncode([for (final e in entries) e.toJson()]));
    } catch (_) {}
  }

  double get total => entries.fold(0.0, (s, e) => s + e.cost);

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
      await (await _file()).writeAsString('[]');
    } catch (_) {}
  }
}
