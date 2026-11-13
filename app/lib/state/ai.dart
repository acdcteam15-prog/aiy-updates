import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'app_log.dart';
import 'github.dart';
import 'keys.dart';
import 'net.dart';
import 'prefs.dart';

class Source {
  final String title;
  final String url;
  const Source(this.title, this.url);
  Map<String, dynamic> toJson() => {'t': title, 'u': url};
  factory Source.fromJson(Map<String, dynamic> m) => Source('${m['t'] ?? ''}', '${m['u'] ?? ''}');
}

/// One chat bubble. role: 'user' or 'model'.
class ChatMsg {
  final String role;
  String text;
  final String? imagePath;

  /// A text file the person attached (its content), and its name. A PDF travels as [imagePath] instead.
  final String attach;
  final String attachName;
  String provider;
  String model;
  List<Source> sources;
  String note;
  bool failed;
  final int ts;
  ChatMsg({
    required this.role,
    required this.text,
    this.imagePath,
    this.attach = '',
    this.attachName = '',
    this.provider = '',
    this.model = '',
    this.sources = const [],
    this.note = '',
    this.failed = false,
    int? ts,
  }) : ts = ts ?? DateTime.now().millisecondsSinceEpoch;

  bool get isUser => role == 'user';

  Map<String, dynamic> toJson() => {
        'r': role,
        'x': text,
        if (imagePath != null) 'i': imagePath,
        if (attach.isNotEmpty) 'at': attach,
        if (attachName.isNotEmpty) 'an': attachName,
        if (provider.isNotEmpty) 'p': provider,
        if (model.isNotEmpty) 'm': model,
        if (sources.isNotEmpty) 's': [for (final s in sources) s.toJson()],
        if (note.isNotEmpty) 'n': note,
        if (failed) 'f': true,
        'ts': ts,
      };

  factory ChatMsg.fromJson(Map<String, dynamic> m) => ChatMsg(
        role: '${m['r'] ?? 'user'}',
        text: '${m['x'] ?? ''}',
        imagePath: m['i'] as String?,
        attach: '${m['at'] ?? ''}',
        attachName: '${m['an'] ?? ''}',
        provider: '${m['p'] ?? ''}',
        model: '${m['m'] ?? ''}',
        sources: [
          for (final s in (m['s'] as List? ?? const []))
            if (s is Map) Source.fromJson(Map<String, dynamic>.from(s))
        ],
        note: '${m['n'] ?? ''}',
        failed: m['f'] == true,
        ts: (m['ts'] as num?)?.toInt(),
      );
}

class AiReply {
  final String text;

  /// Display name of the service that answered ("Gemini") and its model.
  final String provider;
  final String model;
  final List<Source> sources;
  String note;
  final int inTokens;
  final int outTokens;

  /// True when the answer stopped because it reached the length limit.
  final bool cut;

  /// True when the person pressed Stop (the text is what had arrived by then).
  final bool stopped;
  AiReply({
    required this.text,
    required this.provider,
    required this.model,
    this.sources = const [],
    this.note = '',
    this.inTokens = 0,
    this.outTokens = 0,
    this.cut = false,
    this.stopped = false,
  });
}

/// Receives the whole answer written so far, again and again while it arrives. An empty text means
/// "a new attempt started" (the previous service failed, so what was shown is dropped).
typedef TextSink = void Function(String text);

/// One model from OpenRouter's list. Prices are US dollars for ONE token.
class OrModel {
  final String id;
  final String name;
  final double promptPrice;
  final double completionPrice;
  final int context;
  const OrModel(this.id, this.name, this.promptPrice, this.completionPrice, this.context);

  bool get free => id.endsWith(':free') || (promptPrice == 0 && completionPrice == 0);

  /// Well-known families for coding work (shown first in the picker).
  bool get coding => RegExp(r'claude|gpt-5|gpt-4\.1|codex|gemini-.*pro|deepseek|qwen.*coder|kimi|grok-code|devstral|codestral|glm', caseSensitive: false).hasMatch(id);

  String get priceLabel {
    if (free) return 'Free';
    String per(double p) {
      final m = p * 1000000;
      return m >= 10 ? m.toStringAsFixed(0) : m.toStringAsFixed(2);
    }

    return '\$${per(promptPrice)} in · \$${per(completionPrice)} out per 1M tokens';
  }
}

/// Talks to Gemini, Groq and OpenRouter with the person's own keys, and falls back from one free
/// service to the next when a limit is reached.
class AiEngine {
  final KeyVault keys;
  final LocalPrefs prefs;
  AiEngine(this.keys, this.prefs);

  static const names = {'gemini': 'Gemini', 'groq': 'Groq', 'openrouter': 'OpenRouter', 'github': 'GitHub'};

  /// Used until the real list has been fetched from each service (names are retired often).
  static const seeds = {
    'gemini': ['gemini-3.8-flash', 'gemini-3.5-flash', 'gemini-3.5-flash-lite', 'gemini-3.1-flash-lite'],
    'groq': ['llama-3.3-70b-versatile', 'openai/gpt-oss-120b', 'qwen/qwen3.6-27b'],
    'openrouter': ['openrouter/free'],
  };

  static const _geminiBase = 'https://generativelanguage.googleapis.com/v1beta';
  static const _groqBase = 'https://api.groq.com/openai/v1';
  static const _orBase = 'https://openrouter.ai/api/v1';

  List<OrModel> _orModels = const [];

  // ------------------------------------------------------------------ model lists
  List<String> modelsFor(String pid) {
    final cached = prefs.models(pid);
    final list = cached.isNotEmpty ? cached : (seeds[pid] ?? const <String>[]);
    if (pid == 'openrouter') return ['openrouter/free', ...list.where((m) => m != 'openrouter/free')];
    return list;
  }

  /// Fetches the current model names of one service (at most once a day unless [force]).
  Future<void> refreshModels(String pid, {bool force = false}) async {
    if (!keys.has(pid) && pid != 'openrouter') return;
    final age = DateTime.now().millisecondsSinceEpoch - prefs.modelsAt(pid);
    if (!force && prefs.models(pid).isNotEmpty && age < const Duration(hours: 24).inMilliseconds) return;
    try {
      if (pid == 'gemini') {
        final r = await Net.send('GET', Uri.parse('$_geminiBase/models?pageSize=200'), headers: {'x-goog-api-key': keys.get('gemini')}, timeoutSec: 30, who: 'Gemini');
        if (r.status != 200) return;
        final all = <String>[];
        for (final m in (jsonDecode(r.body)['models'] as List? ?? const [])) {
          if (m is! Map) continue;
          final methods = m['supportedGenerationMethods'];
          if (methods is List && !methods.contains('generateContent')) continue;
          final id = '${m['name'] ?? ''}'.replaceFirst('models/', '');
          if (!id.startsWith('gemini-') || !id.contains('flash')) continue;
          if (RegExp(r'tts|image|live|audio|embedding|native|exp|computer|robotics|latest|\d{3,4}$').hasMatch(id)) continue;
          all.add(id);
        }
        double ver(String id) => double.tryParse(RegExp(r'gemini-(\d+(?:\.\d+)?)').firstMatch(id)?.group(1) ?? '') ?? 0;
        int cmp(String a, String b) {
          final pa = a.contains('preview') ? 1 : 0, pb = b.contains('preview') ? 1 : 0;
          if (pa != pb) return pa - pb;
          return ver(b).compareTo(ver(a));
        }

        final flash = all.where((m) => !m.contains('lite')).toList()..sort(cmp);
        final lite = all.where((m) => m.contains('lite')).toList()..sort(cmp);
        final picked = <String>[
          if (flash.isNotEmpty) flash[0],
          if (lite.isNotEmpty) lite[0],
          if (flash.length > 1) flash[1],
          if (lite.length > 1) lite[1],
        ];
        if (picked.isNotEmpty) await prefs.setModels('gemini', picked);
      } else if (pid == 'groq') {
        final r = await Net.send('GET', Uri.parse('$_groqBase/models'), headers: {'Authorization': 'Bearer ${keys.get('groq')}'}, timeoutSec: 30, who: 'Groq');
        if (r.status != 200) return;
        final ids = <String>[
          for (final m in (jsonDecode(r.body)['data'] as List? ?? const []))
            if (m is Map) '${m['id'] ?? ''}'
        ].where((id) => id.isNotEmpty && !RegExp(r'whisper|guard|tts|playai|compound|orpheus|safeguard', caseSensitive: false).hasMatch(id)).toList();
        final picked = <String>[
          ...seeds['groq']!.where(ids.contains),
          ...ids.where((id) => !seeds['groq']!.contains(id) && RegExp(r'70b|120b|versatile|qwen|kimi').hasMatch(id)),
        ];
        final out = (picked.isNotEmpty ? picked : ids).take(3).toList();
        if (out.isNotEmpty) await prefs.setModels('groq', out);
      } else if (pid == 'openrouter') {
        final all = await orModels(force: true);
        final free = all.where((m) => m.id.endsWith(':free')).toList()..sort((a, b) => b.context.compareTo(a.context));
        await prefs.setModels('openrouter', [for (final m in free.take(3)) m.id]);
      }
    } catch (_) {
      // Keep the list we have.
    }
  }

  /// Every OpenRouter model with its price (fetched live; no key needed).
  Future<List<OrModel>> orModels({bool force = false}) async {
    if (_orModels.isNotEmpty && !force) return _orModels;
    final r = await Net.send('GET', Uri.parse('$_orBase/models'), timeoutSec: 45, who: 'OpenRouter');
    if (r.status != 200) throw Net.fail('OpenRouter', r.status, r.body);
    final out = <OrModel>[];
    for (final m in (jsonDecode(r.body)['data'] as List? ?? const [])) {
      if (m is! Map) continue;
      final pricing = m['pricing'];
      double price(String k) => pricing is Map ? (double.tryParse('${pricing[k] ?? '0'}') ?? 0) : 0;
      final id = '${m['id'] ?? ''}';
      if (id.isEmpty || price('prompt') < 0) continue;
      out.add(OrModel(id, '${m['name'] ?? id}', price('prompt'), price('completion'), (m['context_length'] as num?)?.toInt() ?? 0));
    }
    _orModels = out;
    return out;
  }

  // ------------------------------------------------------------------ the fallback chain
  List<(String, String)> _chain({required bool vision, String prefer = '', bool onlyGemini = false}) {
    final chosen = prefs.chatOrModel;
    final all = <(String, String)>[
      if (keys.has('gemini'))
        for (final m in modelsFor('gemini').take(4)) ('gemini', m),
      // The Groq text models cannot read photos.
      if (keys.has('groq') && !vision && !onlyGemini)
        for (final m in modelsFor('groq').take(3)) ('groq', m),
      if (keys.has('openrouter') && !onlyGemini)
        for (final m in {if (chosen.isNotEmpty) chosen, ...modelsFor('openrouter').take(4)}) ('openrouter', m),
    ];
    if (prefer.isEmpty) return all;
    return [...all.where((e) => e.$1 == prefer), ...all.where((e) => e.$1 != prefer)];
  }

  /// The services and models that can answer a chat right now, in the order they are tried.
  List<(String, String)> chatChain({bool vision = false}) => _chain(vision: vision, prefer: prefs.preferProvider);

  ApiError _tag(ApiError e, String pid, String model) =>
      (e.provider.isNotEmpty && e.model.isNotEmpty) ? e : ApiError(e.message, e.status, e.provider.isEmpty ? (names[pid] ?? pid) : e.provider, e.model.isEmpty ? model : e.model, e.detail);

  Future<AiReply> _run(
    Future<AiReply> Function(String pid, String model) call, {
    bool vision = false,
    String prefer = '',
    bool onlyGemini = false,
    ({String pid, String model})? avoid,
    TextSink? onText,
    AiCancel? cancel,
  }) async {
    var chain = _chain(vision: vision, prefer: prefer, onlyGemini: onlyGemini);
    if (avoid != null) {
      // "Answer again with another model": leave out the one that answered before (when something else is left).
      final exact = chain.any((e) => e.$1 == avoid.pid && e.$2 == avoid.model);
      final rest = chain.where((e) => !(e.$1 == avoid.pid && (exact ? e.$2 == avoid.model : e.$2 == 'openrouter/free'))).toList();
      if (rest.isNotEmpty) chain = rest;
    }
    if (chain.isEmpty) throw ApiError(onlyGemini ? 'PDF files can only be read by Gemini. Connect Gemini in Settings > Accounts & keys.' : 'No AI service is connected yet. Open Settings > Accounts & keys.');
    final errors = <ApiError>[];
    final dead = <String>{};
    for (final (pid, model) in chain) {
      if (dead.contains(pid)) continue;
      if (cancel?.cancelled == true) break;
      onText?.call('');
      try {
        final r = await call(pid, model);
        await prefs.bumpUsage(pid);
        return r;
      } on ApiError catch (e) {
        errors.add(_tag(e, pid, model));
        // A rejected key will not get better with another model of the same service.
        if (e.status == 401 || e.status == 403) dead.add(pid);
        // A model that no longer exists: get the current list for next time.
        if (e.status == 404) unawaited(refreshModels(pid, force: true));
      }
    }
    if (cancel?.cancelled == true) return AiReply(text: '', provider: '', model: '', stopped: true);
    AppLog.i('AI: ${errors.map((e) => '${e.provider} (${e.model}): ${e.message}').join(' | ')}');
    throw ApiError(
      'No AI service could answer:\n${errors.map((e) => '• ${e.provider} (${e.model}): ${e.message}').join('\n')}',
      errors.isEmpty ? null : errors.last.status,
      '',
      '',
      '',
      errors,
    );
  }

  // ------------------------------------------------------------------ public calls
  static String _today() {
    final n = DateTime.now();
    return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  }

  /// A chat turn: the whole conversation goes in, one answer comes out (written piece by piece into [onText]).
  Future<AiReply> chat(
    List<ChatMsg> history, {
    required bool search,
    String prefer = '',
    String instructions = '',
    ({String pid, String model})? avoid,
    TextSink? onText,
    AiCancel? cancel,
  }) {
    final system = 'You are AIy, a friendly personal assistant. Answer clearly and directly, in the language the person writes in. '
        'Use short Markdown (headings, lists, code blocks) only when it helps. Today is ${_today()}.'
        '${instructions.trim().isEmpty ? '' : '\nThe person\'s standing instructions, always follow them: ${instructions.trim()}'}';
    final vision = history.isNotEmpty && history.last.imagePath != null;
    final pdf = history.isNotEmpty && (history.last.imagePath ?? '').toLowerCase().endsWith('.pdf');
    return _run((pid, model) async {
      if (pid == 'gemini') return _gemini(model, history, system: system, search: search, onText: onText, cancel: cancel);
      final r = await _openAi(pid, model, _openAiMessages(history, system), onText: onText, cancel: cancel);
      if (search) r.note = 'Live search only works with Gemini, so this answer did not use the internet.';
      return r;
    }, vision: vision, prefer: prefer, onlyGemini: pdf, avoid: avoid, onText: onText, cancel: cancel);
  }

  /// A single question for the app's own work (file routing, codebase overview). [json]: ask for JSON only.
  Future<AiReply> ask(String prompt, {String system = '', bool json = false, TextSink? onText}) {
    final history = [ChatMsg(role: 'user', text: prompt)];
    return _run((pid, model) {
      if (pid == 'gemini') return _gemini(model, history, system: system, json: json, temperature: 0.2, onText: onText);
      return _openAi(pid, model, _openAiMessages(history, system), temperature: 0.2, timeoutSec: 120, onText: onText);
    }, prefer: prefs.preferProvider, onText: onText);
  }

  /// One request to the OpenRouter model the person chose (no fallback: they picked it and agreed to its price).
  Future<AiReply> openRouter(String model, String system, String user, {required int maxTokens, TextSink? onText}) async {
    final r = await _openAi(
      'openrouter',
      model,
      [
        {'role': 'system', 'content': system},
        {'role': 'user', 'content': user},
      ],
      temperature: 0.1,
      maxTokens: maxTokens,
      timeoutSec: 420,
      onText: onText,
    );
    await prefs.bumpUsage('openrouter');
    return r;
  }

  /// What OpenRouter says about the key: the money used so far and, when the key has a limit, what is left.
  Future<({double used, double? left})> credit() async {
    final r = await Net.send('GET', Uri.parse('$_orBase/key'), headers: {'Authorization': 'Bearer ${keys.get('openrouter')}'}, timeoutSec: 30, who: 'OpenRouter');
    if (r.status != 200) throw Net.fail('OpenRouter', r.status, r.body);
    final d = (jsonDecode(r.body) as Map)['data'];
    return (used: (d is Map ? (d['usage'] as num?)?.toDouble() : null) ?? 0.0, left: d is Map ? (d['limit_remaining'] as num?)?.toDouble() : null);
  }

  /// Checks that a key works. Throws an [ApiError] with the reason when it does not.
  Future<String> test(String pid) async {
    final key = keys.get(pid);
    if (key.isEmpty) throw ApiError('No key yet.');
    switch (pid) {
      case 'gemini':
        final r = await Net.send('GET', Uri.parse('$_geminiBase/models?pageSize=5'), headers: {'x-goog-api-key': key}, timeoutSec: 30, who: 'Gemini');
        if (r.status != 200) throw Net.fail('Gemini', r.status, r.body);
        unawaited(refreshModels('gemini', force: true));
        return 'Gemini key works.';
      case 'groq':
        final r = await Net.send('GET', Uri.parse('$_groqBase/models'), headers: {'Authorization': 'Bearer $key'}, timeoutSec: 30, who: 'Groq');
        if (r.status != 200) throw Net.fail('Groq', r.status, r.body);
        unawaited(refreshModels('groq', force: true));
        return 'Groq key works.';
      case 'openrouter':
        final r = await Net.send('GET', Uri.parse('$_orBase/key'), headers: {'Authorization': 'Bearer $key'}, timeoutSec: 30, who: 'OpenRouter');
        if (r.status != 200) throw Net.fail('OpenRouter', r.status, r.body);
        unawaited(refreshModels('openrouter', force: true));
        var extra = '';
        try {
          final d = jsonDecode(r.body)['data'];
          if (d is Map && d['limit_remaining'] is num) extra = ' Credit left: \$${(d['limit_remaining'] as num).toStringAsFixed(2)}.';
        } catch (_) {}
        return 'OpenRouter key works.$extra';
      default:
        final r = await Net.send('GET', Uri.parse('https://api.github.com/user'),
            headers: {'Authorization': 'Bearer $key', 'Accept': 'application/vnd.github+json', 'User-Agent': 'AIy'}, timeoutSec: 30, who: 'GitHub');
        if (r.status != 200) throw Net.fail('GitHub', r.status, r.body);
        var scopeNote = '';
        try {
          final sc = await GitHubApi(key).scopes();
          if (sc.isNotEmpty && !sc.split(',').map((e) => e.trim()).contains('workflow')) {
            throw ApiError('Connected as ${jsonDecode(r.body)['login']}, but this sign-in cannot start builds (no "workflow" permission). Disconnect GitHub and connect it again.');
          }
        } on ApiError catch (e) {
          if (e.message.startsWith('Connected as')) rethrow;
        }
        return 'Connected to GitHub as ${jsonDecode(r.body)['login']}.$scopeNote';
    }
  }

  // ------------------------------------------------------------------ Gemini
  static String _mime(String path) {
    final p = path.toLowerCase();
    return p.endsWith('.pdf') ? 'application/pdf' : (p.endsWith('.png') ? 'image/png' : (p.endsWith('.webp') ? 'image/webp' : 'image/jpeg'));
  }

  /// The words of a message: what the person typed plus the text file they attached.
  static String _text(ChatMsg m) {
    final base = m.text.isEmpty ? (m.imagePath != null ? (m.imagePath!.toLowerCase().endsWith('.pdf') ? 'Summarize this document.' : 'Describe this picture.') : (m.attach.isNotEmpty ? 'Explain this file.' : ' ')) : m.text;
    return m.attach.isEmpty ? base : '$base\n\n[Attached file: ${m.attachName}]\n${m.attach}';
  }

  /// Only the newest photo is sent again; older ones would cost the whole upload on every turn.
  static int _lastImage(List<ChatMsg> h) => h.lastIndexWhere((m) => m.imagePath != null && File(m.imagePath!).existsSync());

  /// A rough token count (about 4 letters each) for when a service does not report its usage while streaming.
  static int _guessTokens(int chars) => (chars / 4).ceil();

  Future<AiReply> _gemini(String model, List<ChatMsg> history, {String system = '', bool search = false, bool json = false, double temperature = 0.7, TextSink? onText, AiCancel? cancel}) async {
    final li = _lastImage(history);
    final contents = <Map<String, dynamic>>[];
    for (var i = 0; i < history.length; i++) {
      final m = history[i];
      if (m.failed) continue;
      contents.add({
        'role': m.isUser ? 'user' : 'model',
        'parts': [
          {'text': _text(m)},
          if (i == li)
            {
              'inline_data': {'mime_type': _mime(m.imagePath!), 'data': base64Encode(await File(m.imagePath!).readAsBytes())}
            },
        ],
      });
    }
    Map<String, dynamic> body(bool withSearch) => {
          if (system.isNotEmpty)
            'systemInstruction': {
              'parts': [
                {'text': system}
              ]
            },
          'contents': contents,
          if (withSearch)
            'tools': [
              {'google_search': <String, dynamic>{}}
            ],
          'generationConfig': {'temperature': temperature, if (json) 'responseMimeType': 'application/json'},
        };
    final acc = _GeminiAnswer();
    Future<void> run(bool withSearch) async {
      acc.reset();
      if (onText == null) {
        final r = await Net.send('POST', Uri.parse('$_geminiBase/models/$model:generateContent'), headers: {'x-goog-api-key': keys.get('gemini')}, json: body(withSearch), timeoutSec: 120, who: 'Gemini');
        if (r.status != 200) throw Net.fail('Gemini', r.status, r.body, model: model);
        try {
          acc.feed(jsonDecode(r.body));
        } catch (_) {
          throw ApiError('Gemini sent an answer that could not be read.', null, 'Gemini', model);
        }
        return;
      }
      await for (final d in Net.sse(
        Uri.parse('$_geminiBase/models/$model:streamGenerateContent?alt=sse'),
        headers: {'x-goog-api-key': keys.get('gemini')},
        json: body(withSearch),
        who: 'Gemini',
        model: model,
        cancel: cancel,
      )) {
        dynamic j;
        try {
          j = jsonDecode(d);
        } catch (_) {
          continue;
        }
        acc.feed(j);
        onText(acc.text);
      }
    }

    var note = '';
    try {
      await run(search);
    } on ApiError catch (e) {
      if (search && e.status == 400 && acc.text.isEmpty) {
        // This model (or this free plan) does not offer Google Search: answer without it.
        await run(false);
        note = 'Live search is not available for this model right now, so this answer did not use the internet.';
      } else {
        rethrow;
      }
    }
    final stopped = cancel?.cancelled == true;
    if (acc.text.trim().isEmpty && !stopped) {
      if (!acc.sawCandidate) throw ApiError('Gemini gave no answer (it may have been blocked${acc.blockReason.isEmpty ? '' : ': ${acc.blockReason}'}).', null, 'Gemini', model);
      throw ApiError('Gemini gave an empty answer (${acc.finish.isEmpty ? 'no reason given' : acc.finish}).', null, 'Gemini', model);
    }
    return AiReply(
      text: acc.text.trim(),
      provider: 'Gemini',
      model: model,
      sources: acc.sources,
      note: note,
      inTokens: acc.inTokens,
      outTokens: acc.outTokens > 0 ? acc.outTokens : _guessTokens(acc.text.length),
      cut: acc.finish == 'MAX_TOKENS',
      stopped: stopped,
    );
  }

  // ------------------------------------------------------------------ OpenAI-compatible (Groq, OpenRouter)
  List<Map<String, dynamic>> _openAiMessages(List<ChatMsg> history, String system) {
    final li = _lastImage(history);
    return [
      if (system.isNotEmpty) {'role': 'system', 'content': system},
      for (var i = 0; i < history.length; i++)
        if (!history[i].failed)
          {
            'role': history[i].isUser ? 'user' : 'assistant',
            'content': i == li
                ? [
                    {'type': 'text', 'text': _text(history[i])},
                    {
                      'type': 'image_url',
                      'image_url': {'url': 'data:${_mime(history[i].imagePath!)};base64,${base64Encode(File(history[i].imagePath!).readAsBytesSync())}'}
                    },
                  ]
                : _text(history[i]),
          },
    ];
  }

  static int _messageChars(List<Map<String, dynamic>> messages) {
    var n = 0;
    for (final m in messages) {
      final c = m['content'];
      if (c is String) {
        n += c.length;
      } else if (c is List) {
        for (final p in c) {
          if (p is Map && p['text'] is String) n += (p['text'] as String).length;
        }
      }
    }
    return n;
  }

  Future<AiReply> _openAi(String pid, String model, List<Map<String, dynamic>> messages, {double temperature = 0.7, int? maxTokens, int timeoutSec = 120, TextSink? onText, AiCancel? cancel}) async {
    final who = names[pid] ?? pid;
    final url = Uri.parse('${pid == 'groq' ? _groqBase : _orBase}/chat/completions');
    final headers = {
      'Authorization': 'Bearer ${keys.get(pid)}',
      if (pid == 'openrouter') 'HTTP-Referer': 'https://aiy.app',
      if (pid == 'openrouter') 'X-Title': 'AIy',
    };
    final payload = {'model': model, 'temperature': temperature, if (maxTokens != null) 'max_tokens': maxTokens, 'messages': messages};
    if (onText != null) return _openAiStream(who, model, url, headers, payload, messages, timeoutSec, onText, cancel);
    final r = await Net.send('POST', url, headers: headers, json: payload, timeoutSec: timeoutSec, who: who);
    if (r.status != 200) throw Net.fail(who, r.status, r.body, model: model);
    dynamic j;
    try {
      j = jsonDecode(r.body);
    } catch (_) {
      throw ApiError('$who sent an answer that could not be read.', null, who, model);
    }
    // OpenRouter can report a provider failure inside a 200 answer.
    if (j is Map && j['error'] != null && j['choices'] == null) {
      final code = j['error'] is Map ? (j['error']['code'] as num?)?.toInt() : null;
      throw Net.fail(who, code ?? 500, r.body, model: model);
    }
    final choices = j is Map ? j['choices'] : null;
    if (choices is! List || choices.isEmpty || choices.first is! Map) throw ApiError('$who gave no answer.', null, who, model);
    final first = choices.first as Map;
    final msg = first['message'];
    final c = msg is Map ? msg['content'] : null;
    var text = '';
    if (c is String) {
      text = c;
    } else if (c is List) {
      text = c.map((p) => p is Map && p['text'] is String ? p['text'] as String : '').join();
    }
    if (text.trim().isEmpty) throw ApiError('$who gave an empty answer.', null, who, model);
    final usage = j['usage'];
    return AiReply(
      text: text.trim(),
      provider: who,
      // OpenRouter's free router tells us which model really answered.
      model: j['model'] is String ? j['model'] as String : model,
      inTokens: usage is Map ? (usage['prompt_tokens'] as num?)?.toInt() ?? 0 : 0,
      outTokens: usage is Map ? (usage['completion_tokens'] as num?)?.toInt() ?? 0 : 0,
      cut: first['finish_reason'] == 'length',
    );
  }

  /// The same request, answered piece by piece. Groq and OpenRouter both speak the OpenAI streaming format.
  Future<AiReply> _openAiStream(String who, String model, Uri url, Map<String, String> headers, Map<String, Object?> payload, List<Map<String, dynamic>> messages, int timeoutSec, TextSink onText, AiCancel? cancel) async {
    final sb = StringBuffer();
    String realModel = model;
    var finish = '';
    int? inTok, outTok;
    await for (final d in Net.sse(url, headers: headers, json: {...payload, 'stream': true}, who: who, model: model, startSec: timeoutSec, idleSec: timeoutSec, cancel: cancel)) {
      dynamic j;
      try {
        j = jsonDecode(d);
      } catch (_) {
        continue;
      }
      if (j is! Map) continue;
      // A failure in the middle of the answer arrives as an "error" object.
      if (j['error'] != null) {
        final code = j['error'] is Map ? (j['error']['code'] as num?)?.toInt() : null;
        throw Net.fail(who, code ?? 500, d, model: model);
      }
      if (j['model'] is String) realModel = j['model'] as String;
      final choices = j['choices'];
      if (choices is List && choices.isNotEmpty && choices.first is Map) {
        final ch = choices.first as Map;
        final delta = ch['delta'];
        final c = delta is Map ? delta['content'] : null;
        if (c is String && c.isNotEmpty) {
          sb.write(c);
          onText(sb.toString());
        }
        if (ch['finish_reason'] is String) finish = ch['finish_reason'] as String;
      }
      final u = j['usage'] ?? (j['x_groq'] is Map ? (j['x_groq'] as Map)['usage'] : null);
      if (u is Map) {
        inTok = (u['prompt_tokens'] as num?)?.toInt() ?? inTok;
        outTok = (u['completion_tokens'] as num?)?.toInt() ?? outTok;
      }
    }
    final stopped = cancel?.cancelled == true;
    if (sb.toString().trim().isEmpty && !stopped) {
      if (finish == 'error') throw ApiError('$who stopped before it wrote anything (the model had a problem).', 502, who, model);
      throw ApiError('$who gave an empty answer.', null, who, model);
    }
    final text = sb.toString().trim();
    return AiReply(
      text: text,
      provider: who,
      model: realModel,
      // When the service does not report its usage while streaming, the spending log gets a careful estimate.
      inTokens: inTok ?? _guessTokens(_messageChars(messages)),
      outTokens: outTok ?? _guessTokens(text.length),
      cut: finish == 'length',
      stopped: stopped,
    );
  }
}

/// Collects a Gemini answer: one JSON object (normal call) or many (streaming); both have the same shape.
class _GeminiAnswer {
  final StringBuffer _sb = StringBuffer();
  List<Source> sources = [];
  int inTokens = 0;
  int outTokens = 0;
  String finish = '';
  String blockReason = '';
  bool sawCandidate = false;

  String get text => _sb.toString();

  void reset() {
    _sb.clear();
    sources = [];
    inTokens = outTokens = 0;
    finish = blockReason = '';
    sawCandidate = false;
  }

  void feed(dynamic j) {
    if (j is! Map) return;
    final pf = j['promptFeedback'];
    if (pf is Map && pf['blockReason'] != null) blockReason = '${pf['blockReason']}';
    final cands = j['candidates'];
    if (cands is List && cands.isNotEmpty && cands.first is Map) {
      sawCandidate = true;
      final first = cands.first as Map;
      final content = first['content'];
      final parts = content is Map ? content['parts'] : null;
      if (parts is List) {
        for (final p in parts) {
          if (p is Map && p['text'] is String && p['thought'] != true) _sb.write(p['text']);
        }
      }
      if (first['finishReason'] is String) finish = first['finishReason'] as String;
      final gm = first['groundingMetadata'];
      if (gm is Map && gm['groundingChunks'] is List) {
        for (final c in gm['groundingChunks'] as List) {
          final w = c is Map ? c['web'] : null;
          if (w is Map && w['uri'] is String && sources.length < 8 && !sources.any((s) => s.url == w['uri'])) {
            sources.add(Source('${w['title'] ?? w['uri']}', w['uri'] as String));
          }
        }
      }
    }
    final usage = j['usageMetadata'];
    if (usage is Map) {
      inTokens = (usage['promptTokenCount'] as num?)?.toInt() ?? inTokens;
      outTokens = (usage['candidatesTokenCount'] as num?)?.toInt() ?? outTokens;
    }
  }
}
