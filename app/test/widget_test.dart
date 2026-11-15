import 'package:aiy/logic/appgen.dart';
import 'package:aiy/logic/brief.dart';
import 'package:aiy/logic/buildlog.dart';
import 'package:aiy/logic/pin.dart';
import 'package:aiy/logic/redact.dart';
import 'package:aiy/logic/lite.dart';
import 'package:aiy/logic/patcher.dart';
import 'package:aiy/logic/project.dart';
import 'package:aiy/logic/versioning.dart';
import 'package:aiy/logic/workflows.dart';
import 'package:aiy/state/background_work.dart';
import 'package:aiy/state/connectivity.dart';
import 'package:aiy/state/net.dart';
import 'package:aiy/state/slow_line.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('source filter skips bloat folders, media and lock files', () {
    expect(isSource('app/src/main.kt', 1000), true);
    expect(isSource('app/node_modules/x/index.js', 10), false);
    expect(isSource('a/logo.png', 10), false);
    expect(isSource('package-lock.json', 10), false);
  });

  test('search/replace blocks are parsed and applied', () {
    const answer = '### SUMMARY\nChanged the greeting.\n\n### FILE: a.js\n<<<<<<< SEARCH\nlog("hi");\n=======\nlog("hello");\n>>>>>>> REPLACE\n';
    final plan = parsePatch(answer);
    expect(plan.summary, 'Changed the greeting.');
    final r = applyBlocks('function a() {\n  log("hi");\n}\n', plan.edits.single.blocks);
    expect(r.failures, isEmpty);
    expect(r.text, 'function a() {\n  log("hello");\n}\n');
  });

  test('validation catches a new unbalanced bracket', () {
    expect(validateChange('a.js', 'f();', 'f(;'), isNotNull);
    expect(validateChange('a.json', '{}', '{"a": 1}'), isNull);
  });

  test('the version is found, bumped and written into the project', () {
    final g = {'app/build.gradle.kts': 'defaultConfig {\n    versionCode = 7\n    versionName = "1.4"\n}\n'};
    final v = detectVersion((p) => g[p])!;
    expect(v.name, '1.4');
    expect(applyVersion(v, g['app/build.gradle.kts']!, '1.5.0', code: nextCode(v.code, 0)), 'defaultConfig {\n    versionCode = 8\n    versionName = "1.5.0"\n}\n');
    expect(bumpVersion('1.2.3', 'minor'), '1.3.0');
    expect(validVersion('1..2'), false);
  });

  test('project kind, workflow and build errors', () {
    expect(detectKind((p) => p == 'gradlew', (p) => null), ProjectKind.gradle);
    expect(workflowFor(ProjectKind.unknown), null);
    final ps = parseProblems(['e: file:///a/b/Main.kt:42:13 Unresolved reference: foo', 'BUILD FAILED in 2s']);
    expect(ps.first.file, 'Main.kt');
    expect(ps.first.line, 42);
  });

  test('Build tab: names, questions, files and the project check', () {
    expect(snakeName('My Cool App!'), 'my_cool_app');
    expect(parseQuestion('{"question": "Who uses it?", "options": ["Me", "Family"]}')!.options.length, 2);
    const answer = '### NEW FILE: pubspec.yaml\n<<<<<<< CONTENT\nname: x\ndependencies:\n  flutter:\n    sdk: flutter\n>>>>>>> END\n\n### NEW FILE: lib/main.dart\n<<<<<<< CONTENT\nimport \'package:flutter/material.dart\';\nvoid main() => runApp(const SizedBox());\n>>>>>>> END\n';
    final files = parseFiles(answer);
    expect(files.length, 2);
    expect(checkProject(files, 'x'), isEmpty);
    files['lib/main.dart'] = 'import \'models.dart\';\nvoid main() {}\n';
    expect(checkProject(files, 'x').length, 1);
  });

  test('screens checklist, redaction, PIN and analyze errors', () {
    const brief = '# A\n\n## Screens\n- **Home**: list\n- **Stats**: chart\n\n## Data\n- saved\n';
    expect(screensOf(brief).length, 2);
    expect(screensOf(removeScreen(brief, screensOf(brief).first)).length, 1);
    expect(redact('Bearer abcdefghijklmnop and AIzaSyA1234567890abcdefghijk').contains('abcdefghijklmnop'), false);
    final salt = newSalt();
    expect(verifyPin('1234', salt, hashPin('1234', salt)), true);
    expect(verifyPin('4321', salt, hashPin('1234', salt)), false);
    expect(parseProblems(['  error • Undefined name x • lib/a.dart:3:1 • undefined_identifier']).first.line, 3);
  });

  test('a question is read out of JSON that is still arriving', () {
    expect(partialQuestion(''), '');
    expect(partialQuestion('{"ques'), '');
    expect(partialQuestion('{"question": "Who will use'), 'Who will use');
    expect(partialQuestion('{"question": "Say \\"hi\\" to'), 'Say "hi" to');
    expect(partialQuestion('{"question": "Line\\'), 'Line');
    expect(partialQuestion('{"question": "Done?", "options": ["a"'), 'Done?');
  });

  test('writing progress counts the files started and names the newest', () {
    expect(writingProgress('').count, 0);
    const text = '### NEW FILE: pubspec.yaml\nname: x\n### NEW FILE: lib/main.dart\nvoid main() {}\n### NEW FILE: lib/ui/home.dart\nclass';
    final p = writingProgress(text);
    expect(p.count, 3);
    expect(p.current, 'lib/ui/home.dart');
  });

  test('an OpenRouter failure is found inside a failure of several services', () {
    final or = ApiError('x', 429, 'OpenRouter', 'm:free', 'busy');
    final whole = ApiError('all failed', 429, '', '', '', [ApiError('g', 500, 'Gemini', 'g1'), or]);
    expect(whole.fromOpenRouter, true);
    expect(identical(whole.openRouterPart, or), true);
    expect(ApiError('only gemini', 500, 'Gemini', 'g1').fromOpenRouter, false);
    expect(ApiError('plain').openRouterPart == null, true);
  });

  test('server-sent events are read piece by piece, errors and stop are handled', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      if (req.uri.path == '/bad') {
        req.response.statusCode = 429;
        req.response.write('{"error":{"message":"slow down"}}');
        await req.response.close();
        return;
      }
      req.response.headers.contentType = ContentType('text', 'event-stream');
      req.response.write(': keep-alive\n\n');
      req.response.write('data: {"a":1}\n\n');
      await req.response.flush();
      req.response.write('data: {"a":2}\r\n\r\ndata: [DONE]\n\ndata: {"a":3}\n\n');
      await req.response.close();
      expect(body.contains('hello'), true);
    });
    final base = 'http://127.0.0.1:${server.port}';
    final got = <String>[];
    await for (final d in Net.sse(Uri.parse('$base/ok'), json: {'q': 'hello'}, who: 'Test')) {
      got.add(d);
    }
    expect(got, ['{"a":1}', '{"a":2}']);
    ApiError? err;
    try {
      await Net.sse(Uri.parse('$base/bad'), json: {'q': 'hello'}, who: 'OpenRouter', model: 'm').toList();
    } on ApiError catch (e) {
      err = e;
    }
    expect(err != null, true);
    expect(err!.status, 429);
    expect(err.provider, 'OpenRouter');
    expect(err.detail, 'slow down');
    final cancel = AiCancel()..cancel();
    final none = await Net.sse(Uri.parse('$base/ok'), json: {'q': 'hello'}, who: 'Test', cancel: cancel).toList();
    expect(none.length, 0);
    await server.close(force: true);
  });

  test('only connection problems wait for the internet', () {
    expect(ApiError('x', -1).isConnection, true);
    expect(ApiError('x', 429).isConnection, false);
    expect(ApiError('x', -1, '', '', '', [ApiError('a', -1), ApiError('b', 429)]).isConnection, false);
    expect(ApiError('x', -1, '', '', '', [ApiError('a', -1), ApiError('b', -1)]).isConnection, true);
  });

  test('waiting requests are sent again when the internet is back, and not for ever', () async {
    var online = false;
    final sent = <String>[];
    final notes = <String>[];
    final lost = <double>[];
    final c = ConnectivityService(
      probe: () async => online,
      notifier: (t, x) async => notes.add(t),
      onLost: (k, p, m, cost) async => lost.add(cost),
      poll: const Duration(milliseconds: 20),
    );
    final err = ApiError('No internet connection (x).', -1, 'OpenRouter', 'm');
    err.lostCost = () async => 0.05;
    expect(c.hold(err, title: 'A', run: () async => sent.add('A')), true);
    expect(c.hold(ApiError('bad', 429), title: 'B', run: () async {}), false);
    expect(c.offline, true);
    expect(c.jobs.length, 1);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(sent.length, 0);
    online = true;
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(sent, ['A']);
    expect(c.offline, false);
    expect(notes.length, 1);
    expect(lost, [0.05]);
    // a request that keeps failing for lack of internet is sent again 3 times, then given up
    var runs = 0;
    late Future<void> Function() again;
    again = () async {
      runs++;
      c.hold(ApiError('No internet connection (x).', -1), title: 'C', run: again);
    };
    online = false;
    expect(c.hold(ApiError('No internet connection (x).', -1), title: 'C', run: again), true);
    online = true;
    await Future<void>.delayed(const Duration(milliseconds: 3500));
    expect(runs, 3);
    expect(c.jobs.length, 0);
    expect(c.offline, false);
    // a waiting request can be cancelled
    online = false;
    c.hold(ApiError('No internet connection (x).', -1), title: 'D', run: () async => sent.add('D'));
    c.cancel(c.jobs.first);
    expect(c.jobs.length, 0);
    expect(c.offline, false);
    online = true;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(sent, ['A']);
    c.dispose();
  });

  test('the working notification says what is going on', () {
    ({String title, String text})? sum({bool chat = false, String chatText = '', String code = '', String builder = '', bool build = false, int waiting = 0}) => workSummary(
          chatBusy: chat,
          chatText: chatText,
          codeBusy: code,
          asking: false,
          builderBusy: builder,
          buildRunning: build,
          buildStatus: '',
          waitingForInternet: waiting,
          resending: false,
        );
    expect(sum() == null, true);
    expect(sum(chat: true)!.text, 'Thinking about an answer…');
    expect(sum(chat: true, chatText: 'abc')!.text, 'Writing an answer (3 letters so far)…');
    expect(sum(code: 'Writing lib/main.dart…')!.title, 'AIy is working');
    final two = sum(code: 'Writing the patch…', waiting: 2)!;
    expect(two.title, 'AIy is working (2 jobs)');
    expect(two.text, 'Writing the patch…');
    expect(sum(waiting: 1)!.text, 'Waiting for the internet (1 request)');
  });

  test('the notification is shown while work runs, updated slowly, and removed after a pause', () async {
    var text = '';
    final shown = <String>[];
    var hidden = 0;
    final w = BackgroundWork(
      summary: () => text.isEmpty ? null : (title: 'AIy is working', text: text),
      show: (t, x) async => shown.add(x),
      hide: () async => hidden++,
      minGap: const Duration(milliseconds: 100),
      linger: const Duration(milliseconds: 150),
    );
    w.changed();
    expect(shown.length, 0);
    text = 'one';
    w.changed();
    text = 'two';
    w.changed();
    text = 'three';
    w.changed();
    expect(shown, ['one']);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(shown, ['one', 'three']);
    text = '';
    w.changed();
    expect(hidden, 0);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(hidden, 1);
    expect(w.isOn, false);
    w.dispose();
  });

  test('waiting requests saved before a restart come back quietly and can be cancelled', () async {
    var online = false;
    final sent = <String>[];
    final notes = <String>[];
    var cancelled = 0;
    final c = ConnectivityService(probe: () async => online, notifier: (t, x) async => notes.add(t), poll: const Duration(milliseconds: 20));
    c.restore(title: 'Chat: one', run: () async => sent.add('one'), onCancel: () => cancelled++);
    c.restore(title: 'Chat: one', run: () async => sent.add('dup'));
    c.restore(title: 'App: two', run: () async => sent.add('two'), onCancel: () => cancelled++);
    expect(c.jobs.length, 2);
    c.cancel(c.jobs.last);
    expect(cancelled, 1);
    c.cancelAll();
    expect(cancelled, 2);
    expect(c.jobs.length, 0);
    c.restore(title: 'Chat: three', run: () async => sent.add('three'));
    online = true;
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(sent, ['three']);
    expect(notes.length, 0);
    c.dispose();
  });

  test('Lite mode keeps the latest messages and cuts long texts', () {
    expect(shorten('short'), 'short');
    final long = 'a' * 5000;
    final cut = shorten(long);
    expect(cut.length < 2200, true);
    expect(cut.contains('shortened'), true);
    expect(liteIndexes([true, false, true]), [0, 1, 2]);
    final many = [for (var i = 0; i < 20; i++) i.isEven];
    final keep = liteIndexes(many);
    expect(keep.last, 19);
    expect(many[keep.first], true);
    expect(keep.length <= liteKeepMessages, true);
  });

  test('a slow line is noticed after timeouts, offered Lite mode, and forgotten when answers are quick', () {
    final sl = SlowLine();
    expect(sl.slow, false);
    sl.onTimeout();
    expect(sl.slow, false);
    sl.onFirstByte(100);
    sl.onTimeout();
    expect(sl.slow, true);
    expect(sl.factor, 2.0);
    expect(Net.factor, 2.0);
    expect(sl.offer, true);
    sl.hideOffer();
    expect(sl.offer, false);
    sl.onTimeout();
    sl.onTimeout();
    expect(sl.factor, 3.0);
    sl.onFirstByte(5000);
    for (var i = 0; i < 2; i++) {
      sl.onFirstByte(300);
    }
    expect(sl.slow, true);
    sl.onFirstByte(300);
    expect(sl.slow, false);
    expect(sl.factor, 1.0);
    expect(Net.factor, 1.0);
    expect(sl.offerHidden, false);
  });

  test('a download that breaks continues where it stopped', () async {
    final data = List<int>.generate(1000, (i) => i % 251);
    var calls = 0;
    String? ifRange;
    String? rangeHeader;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      calls++;
      final range = req.headers.value('range');
      if (range == null) {
        req.response.statusCode = 200;
        req.response.headers.set('etag', '"v1"');
        req.response.contentLength = data.length;
        // The line breaks after 400 of the 1000 bytes.
        final sock = await req.response.detachSocket();
        sock.add(data.sublist(0, 400));
        await sock.flush();
        sock.destroy();
        return;
      }
      rangeHeader = range;
      ifRange = req.headers.value('if-range');
      final from = int.parse(range.substring(6, range.length - 1));
      req.response.statusCode = 206;
      req.response.headers.set('content-range', 'bytes $from-${data.length - 1}/${data.length}');
      req.response.contentLength = data.length - from;
      req.response.add(data.sublist(from));
      await req.response.close();
    });
    final dir = Directory.systemTemp.createTempSync('aiy_dl');
    final out = File('${dir.path}/file.bin');
    var last = 0;
    await Net.download(Uri.parse('http://127.0.0.1:${server.port}/f'), out, onProgress: (g) => last = g);
    expect(out.readAsBytesSync().length, 1000);
    expect(out.readAsBytesSync().toString(), data.toString());
    expect(calls, 2);
    expect(rangeHeader, 'bytes=400-');
    expect(ifRange, '"v1"');
    expect(last, 1000);
    expect(File('${out.path}.part').existsSync(), false);
    // a leftover part of ANOTHER address is not continued
    File('${out.path}.part').writeAsBytesSync([9, 9, 9]);
    File('${out.path}.part.url').writeAsStringSync('http://other/\n');
    calls = 0;
    rangeHeader = null;
    out.deleteSync();
    await Net.download(Uri.parse('http://127.0.0.1:${server.port}/f'), out);
    expect(rangeHeader == null || rangeHeader == 'bytes=400-', true);
    expect(out.readAsBytesSync().toString(), data.toString());
    await server.close(force: true);
    dir.deleteSync(recursive: true);
  });
}
