import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../../state/ai.dart';
import '../../state/app_log.dart';
import '../../state/keys.dart';
import '../../state/native.dart';
import '../../state/net.dart';
import '../widgets/common.dart';
import '../widgets/fx.dart';

class _Check {
  final String name;
  String state = 'wait'; // wait, run, ok, warn, fail
  String msg = '';
  _Check(this.name);
}

/// "Test everything": checks each part AIy depends on and says in plain words what is wrong.
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key});
  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  final List<_Check> _checks = [];
  bool _running = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _step(_Check c, Future<(String, String)> Function() f) async {
    setState(() => c.state = 'run');
    try {
      final r = await f();
      c.state = r.$1;
      c.msg = r.$2;
    } on ApiError catch (e) {
      c.state = 'fail';
      c.msg = e.message;
    } catch (e) {
      c.state = 'fail';
      c.msg = '$e';
    }
    AppLog.i('test ${c.name}: ${c.state} ${c.msg}');
    if (mounted) setState(() {});
  }

  Future<void> _run() async {
    if (_running) return;
    final keys = context.read<KeyVault>();
    final engine = context.read<AiEngine>();
    Future<(String, String)> service(String id, String name, {bool optional = false}) async {
      if (!keys.has(id)) return (optional ? 'warn' : 'fail', optional ? 'Not connected (optional)' : 'Not connected: open Settings > Accounts & keys');
      return ('ok', await engine.test(id));
    }

    final plan = <(String, Future<(String, String)> Function())>[
      ('This version of AIy', () async {
        final b = await Native.buildInfo();
        return b.name.isEmpty ? ('warn', 'Could not read the version') : ('ok', 'AIy ${b.name} (build ${b.build})');
      }),
      ('Internet', () async {
        final r = await Net.send('GET', Uri.parse('https://api.github.com/zen'), headers: {'User-Agent': 'AIy'}, timeoutSec: 20, who: 'GitHub');
        return r.status == 200 ? ('ok', 'Connected') : ('warn', 'Reached GitHub, which answered ${r.status}');
      }),
      ('Key vault (encrypted keys)', () async {
        final v = 'ok-${DateTime.now().millisecondsSinceEpoch}';
        await Native.secretSet('diag_test', v);
        final back = await Native.secretGet('diag_test');
        await Native.secretSet('diag_test', '');
        return back == v ? ('ok', 'Keys can be stored and read back') : ('fail', 'The key vault did not give back what was stored');
      }),
      ('Storage', () async {
        final f = File('${(await getApplicationDocumentsDirectory()).path}/aiy-diag.txt');
        await f.writeAsString('hello');
        final ok = await f.readAsString() == 'hello';
        f.deleteSync();
        return ok ? ('ok', 'Files can be saved') : ('fail', 'A test file could not be read back');
      }),
      ('Zip engine (Code and Build tabs)', () async {
        final dir = (await getTemporaryDirectory()).path;
        final a = '$dir/diag-a.zip', b = '$dir/diag-b.zip';
        await Native.zipCreate(a, {'t/one.txt': 'hello', 't/two.dart': 'void main() {}'}, {'t/pic.bin': Uint8List.fromList([1, 2, 3, 0, 255])});
        final scan = await Native.zipScan(a);
        if (scan.length != 3) throw 'A new zip has ${scan.length} files instead of 3';
        final read = await Native.zipRead(a, ['t/one.txt']);
        if (read['t/one.txt'] != 'hello') throw 'Reading a text file from a zip failed';
        final bytes = await Native.zipBytes(a, 't/pic.bin');
        if (bytes.length != 5 || bytes[4] != 255) throw 'Reading a binary file from a zip failed';
        await Native.zipRebuild(a, b, {'t/one.txt': 'changed', 't/new.txt': 'x'});
        final read2 = await Native.zipRead(b, ['t/one.txt', 't/new.txt']);
        for (final p in [a, b]) {
          try {
            File(p).deleteSync();
          } catch (_) {}
        }
        if (read2['t/one.txt'] != 'changed' || read2['t/new.txt'] != 'x') throw 'Rebuilding a zip with changed files failed';
        return ('ok', 'A test zip was created, read and rebuilt');
      }),
      ('Gemini', () => service('gemini', 'Gemini')),
      ('OpenRouter', () => service('openrouter', 'OpenRouter')),
      ('Groq', () => service('groq', 'Groq', optional: true)),
      ('GitHub', () => service('github', 'GitHub', optional: true)),
      ('Model lists', () async {
        final parts = <String>[];
        for (final id in const ['gemini', 'groq', 'openrouter']) {
          if (!keys.has(id)) continue;
          await engine.refreshModels(id, force: true);
          parts.add('${AiEngine.names[id]}: ${engine.modelsFor(id).take(2).join(', ')}');
        }
        return parts.isEmpty ? ('warn', 'No service is connected') : ('ok', parts.join('\n'));
      }),
      ('Installing apps', () async => await Native.canInstallApks() ? ('ok', 'AIy may install apps (updates, built apps)') : ('warn', 'Android will ask for permission the first time you install an app')),
    ];
    setState(() {
      _running = true;
      _checks
        ..clear()
        ..addAll([for (final p in plan) _Check(p.$1)]);
    });
    for (var i = 0; i < plan.length; i++) {
      if (!mounted) return;
      await _step(_checks[i], plan[i].$2);
    }
    if (mounted) setState(() => _running = false);
  }

  String _report() {
    final sb = StringBuffer('AIy test report ${DateTime.now()}\n\n');
    for (final c in _checks) {
      sb.writeln('[${c.state.toUpperCase()}] ${c.name}${c.msg.isEmpty ? '' : ': ${c.msg.replaceAll('\n', ' / ')}'}');
    }
    final log = AppLog.text.split('\n');
    sb.writeln('\nLog (last 40 lines):\n${log.skip(log.length > 40 ? log.length - 40 : 0).join('\n')}');
    return sb.toString();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final bad = _checks.where((c) => c.state == 'fail').length;
    final warn = _checks.where((c) => c.state == 'warn').length;
    const green = Color(0xFF34C759);
    return Scaffold(
      appBar: AppBar(title: const Text('Test everything')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 40), children: [
        StepCard(
          child: Row(children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: _running
                  ? const Orb(key: ValueKey('o'), size: 40, busy: true)
                  : Icon(bad > 0 ? Icons.error_rounded : (warn > 0 ? Icons.warning_amber_rounded : Icons.check_circle_rounded), key: ValueKey('r$bad$warn'), size: 40, color: bad > 0 ? t.colorScheme.error : (warn > 0 ? Colors.amber : green)),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(_running ? 'Testing…' : (bad > 0 ? '$bad problem(s) found' : (warn > 0 ? 'Works, with $warn note(s)' : 'Everything works')), style: t.textTheme.titleMedium),
            ),
          ]),
        ),
        const SizedBox(height: 12),
        for (final c in _checks)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Appear(
              dy: 8,
              child: StepCard(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(
                    width: 26,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 250),
                      child: switch (c.state) {
                        'ok' => const Icon(Icons.check_circle_rounded, key: ValueKey('ok'), color: green, size: 22),
                        'warn' => const Icon(Icons.info_rounded, key: ValueKey('w'), color: Colors.amber, size: 22),
                        'fail' => Icon(Icons.error_rounded, key: const ValueKey('f'), color: t.colorScheme.error, size: 22),
                        'run' => const SizedBox(key: ValueKey('r'), width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                        _ => Icon(Icons.circle_outlined, key: const ValueKey('n'), size: 18, color: t.colorScheme.onSurfaceVariant),
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(c.name, style: t.textTheme.titleSmall),
                      if (c.msg.isNotEmpty) Text(c.msg, style: t.textTheme.bodySmall?.copyWith(color: c.state == 'fail' ? t.colorScheme.error : t.colorScheme.onSurfaceVariant)),
                    ]),
                  ),
                ]),
              ),
            ),
          ),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: OutlinedButton(onPressed: _running ? null : _run, child: const Text('Run again'))),
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(64, 48)),
              onPressed: _checks.isEmpty
                  ? null
                  : () {
                      Clipboard.setData(ClipboardData(text: _report()));
                      snack(context, 'Report copied. Paste it in a message.');
                    },
              child: const Text('Copy the report'),
            ),
          ),
        ]),
        Padding(padding: const EdgeInsets.only(top: 8), child: Text('The report has no keys in it.', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant))),
      ]),
    );
  }
}
