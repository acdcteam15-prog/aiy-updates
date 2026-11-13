import 'package:aiy/logic/appgen.dart';
import 'package:aiy/logic/brief.dart';
import 'package:aiy/logic/buildlog.dart';
import 'package:aiy/logic/pin.dart';
import 'package:aiy/logic/redact.dart';
import 'package:aiy/logic/patcher.dart';
import 'package:aiy/logic/project.dart';
import 'package:aiy/logic/versioning.dart';
import 'package:aiy/logic/workflows.dart';
import 'package:aiy/state/net.dart';
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
}
