import 'dart:io';

import '../logic/redact.dart';
import 'app_log.dart';
import 'connectivity.dart';
import 'native.dart';
import 'net.dart';
import 'store.dart';

/// One text with everything needed to understand a problem: the error, the app and phone, the connection,
/// recent notices and the end of the log. Keys are removed (the log is already redacted; this is redacted again).
class ReportBundle {
  static Future<String> build({Object? error, String where = '', String extra = ''}) async {
    final b = await Native.buildInfo();
    final sb = StringBuffer('=== AIy report ===\n');
    sb.writeln('Time: ${DateTime.now().toIso8601String()}');
    sb.writeln('AIy: ${b.name.isEmpty ? '(unknown)' : '${b.name} (build ${b.build})'}');
    sb.writeln('Phone: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
    final svc = Offline.service;
    sb.writeln('Internet: ${svc == null ? '?' : (svc.offline ? 'offline, ${svc.jobs.length} waiting' : 'online')}; slow-line factor ${Net.factor.toStringAsFixed(1)}');
    if (where.isNotEmpty) sb.writeln('While: $where');
    if (error != null) {
      sb.writeln('\n--- Error');
      if (error is ApiError) {
        sb.writeln('Message: ${error.message}');
        sb.writeln('Service: ${error.provider.isEmpty ? '-' : error.provider}; model: ${error.model.isEmpty ? '-' : error.model}; status: ${error.status ?? '-'}');
        if (error.tries > 1) sb.writeln('Tries before giving up: ${error.tries}');
        if (error.detail.isNotEmpty) sb.writeln('Detail: ${error.detail}');
        if (error.causes.length > 1) {
          sb.writeln('All attempts:');
          for (final c in error.causes) {
            sb.writeln('  - ${c.provider} ${c.model} (${c.status ?? '-'}): ${c.message}');
          }
        }
      } else {
        sb.writeln('$error');
      }
    }
    if (extra.isNotEmpty) sb.writeln('\n--- More\n$extra');
    final notes = Store.notices.value;
    if (notes.isNotEmpty) sb.writeln('\n--- Notices\n${notes.join('\n')}');
    final lines = AppLog.text.split('\n');
    sb.writeln('\n--- Log (last ${lines.length > 80 ? 80 : lines.length} lines)');
    sb.writeln((lines.length > 80 ? lines.sublist(lines.length - 80) : lines).join('\n'));
    return redact(sb.toString());
  }
}
