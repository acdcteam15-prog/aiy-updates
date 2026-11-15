import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'app_log.dart';
import 'store.dart';

/// A readable failure (shown to the person as is).
class ApiError implements Exception {
  final String message;

  /// HTTP status; -1 = no connection / timeout; null = other.
  final int? status;

  /// Which service failed ("OpenRouter"), which model, and the service's own short reason. Empty when unknown.
  final String provider;
  final String model;
  final String detail;

  /// When several services were tried one after another: what each of them said.
  final List<ApiError> causes;
  ApiError(this.message, [this.status, this.provider = '', this.model = '', this.detail = '', this.causes = const []]);

  /// How many times AIy tried before giving up (0/1 = once). Shown in the error pop-up.
  int tries = 0;

  /// True when the failure was a timeout or a stall (the line may only be slow, not gone).
  bool timeout = false;

  /// Set on a paid OpenRouter request that was lost with the connection: asks OpenRouter later what the attempt cost.
  Future<double> Function()? lostCost;

  /// True when the failure is only the connection (no internet, timeout), for every service that was tried.
  bool get isConnection => status == -1 && (causes.isEmpty || causes.every((c) => c.status == -1));

  /// True when OpenRouter is the service that failed (or one of the services that failed).
  bool get fromOpenRouter => provider == 'OpenRouter' || causes.any((c) => c.provider == 'OpenRouter');

  /// The OpenRouter part of a failure (this error itself, or the newest OpenRouter cause).
  ApiError? get openRouterPart {
    if (provider == 'OpenRouter') return this;
    for (final c in causes.reversed) {
      if (c.provider == 'OpenRouter') return c;
    }
    return null;
  }

  @override
  String toString() => message;
}

/// Lets the person stop an answer that is being written. Closing the connection ends the stream at once.
class AiCancel {
  bool cancelled = false;
  HttpClient? _client;
  void cancel() {
    cancelled = true;
    try {
      _client?.close(force: true);
    } catch (_) {}
  }
}

class Net {
  /// Multiplies every wait (1 = normal). Raised while the line is slow, so a slow answer is not given up on too early.
  static double factor = 1.0;

  /// Called when a request timed out or stalled, and with the milliseconds a request needed to get its first answer.
  /// The slow-line detector listens to both.
  static void Function()? onTimeout;
  static void Function(int ms)? onFirstByte;

  static Duration _t(num sec) => Duration(milliseconds: (sec * 1000 * factor).round());
  static Duration get _connect => Duration(seconds: (20 * factor).round().clamp(20, 60));

  static ApiError _timedOut(String message, [String who = '', String model = '']) {
    onTimeout?.call();
    return ApiError(message, -1, who, model)..timeout = true;
  }

  /// One HTTP call with a JSON (or no) body. Never throws for HTTP error codes: check [status].
  /// [retries]: how often a call that TIMED OUT is tried again (only for calls that are safe to repeat).
  static Future<({int status, String body})> send(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    Object? json,
    int timeoutSec = 90,
    String who = 'The server',
    int retries = 0,
  }) async {
    for (var attempt = 0;; attempt++) {
      try {
        final r = await _sendOnce(method, uri, headers: headers, json: json, timeoutSec: timeoutSec, who: who);
        // Busy or rate-limited: wait (as long as the server asks, up to [maxRetryWait]) and try again.
        if (attempt < retries && retryStatus(r.status)) {
          final wait = retryWait(r.retryAfter, attempt);
          if (wait != null) {
            onRetryWait?.call(who, r.status, wait.inSeconds);
            await Future<void>.delayed(wait);
            continue;
          }
        }
        return (status: r.status, body: r.body);
      } on ApiError catch (e) {
        if (!e.timeout || attempt >= retries) rethrow;
        await Future<void>.delayed(Duration(seconds: 2 << attempt));
      }
    }
  }

  /// Longest wait AIy accepts from a Retry-After header; longer waits fail at once with the server's message.
  static const maxRetryWait = Duration(seconds: 60);

  /// Told when a request waits before trying again (who, HTTP status, seconds). The UI shows it in the log.
  static void Function(String who, int status, int seconds)? onRetryWait;

  static bool retryStatus(int s) => s == 429 || s == 500 || s == 502 || s == 503 || s == 504;

  /// Seconds to wait from a Retry-After header (seconds or an HTTP date); null when the wait is too long.
  static Duration? retryWait(String retryAfter, int attempt, {DateTime? now}) {
    final fallback = Duration(seconds: 2 << attempt);
    final v = retryAfter.trim();
    if (v.isEmpty) return fallback;
    Duration? d;
    final n = int.tryParse(v);
    if (n != null) {
      d = Duration(seconds: n < 0 ? 0 : n);
    } else {
      try {
        d = HttpDate.parse(v).difference((now ?? DateTime.now()).toUtc());
        if (d.isNegative) d = Duration.zero;
      } catch (_) {
        d = fallback;
      }
    }
    if (d > maxRetryWait) return null;
    return d < const Duration(seconds: 1) ? const Duration(seconds: 1) : d;
  }

  static Future<({int status, String body, String retryAfter})> _sendOnce(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    Object? json,
    int timeoutSec = 90,
    String who = 'The server',
  }) async {
    final client = HttpClient()..connectionTimeout = _connect;
    try {
      final req = await client.openUrl(method, uri);
      for (final e in headers.entries) {
        req.headers.set(e.key, e.value);
      }
      if (json != null) {
        final bytes = utf8.encode(jsonEncode(json));
        req.headers.contentType = ContentType.json;
        req.contentLength = bytes.length;
        req.add(bytes);
      }
      final sw = Stopwatch()..start();
      final resp = await req.close().timeout(_t(timeoutSec));
      onFirstByte?.call(sw.elapsedMilliseconds);
      final text = await resp.transform(const Utf8Decoder(allowMalformed: true)).join().timeout(_t(timeoutSec));
      return (status: resp.statusCode, body: text, retryAfter: resp.headers.value('retry-after') ?? '');
    } on SocketException catch (e) {
      throw ApiError('No internet connection (${e.message}).', -1);
    } on TimeoutException {
      throw _timedOut('$who took too long to answer. Try again.', who);
    } on HandshakeException catch (e) {
      throw ApiError('Secure connection to $who failed (${e.message}). Usual causes: the phone\'s date/time is wrong, a Wi-Fi that needs a login page first, or a VPN/proxy that inspects traffic.', -1);
    } on HttpException catch (e) {
      throw ApiError('Connection problem (${e.message}).', -1);
    } finally {
      client.close(force: true);
    }
  }

  /// One POST whose answer arrives in pieces (server-sent events). Yields the payload of every "data:" line.
  /// Throws an [ApiError] for HTTP errors (status, service and model filled in) and for broken connections.
  static Stream<String> sse(
    Uri uri, {
    Map<String, String> headers = const {},
    required Object json,
    String who = 'The server',
    String model = '',
    int startSec = 120,
    int idleSec = 75,
    AiCancel? cancel,
  }) async* {
    final client = HttpClient()..connectionTimeout = _connect;
    cancel?._client = client;
    try {
      final req = await client.openUrl('POST', uri);
      for (final e in headers.entries) {
        req.headers.set(e.key, e.value);
      }
      req.headers.set('Accept', 'text/event-stream');
      final bytes = utf8.encode(jsonEncode(json));
      req.headers.contentType = ContentType.json;
      req.contentLength = bytes.length;
      req.add(bytes);
      final sw = Stopwatch()..start();
      final resp = await req.close().timeout(_t(startSec));
      onFirstByte?.call(sw.elapsedMilliseconds);
      if (resp.statusCode != 200) {
        final text = await resp.transform(const Utf8Decoder(allowMalformed: true)).join().timeout(const Duration(seconds: 30));
        throw fail(who, resp.statusCode, text, model: model);
      }
      final lines = resp.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter());
      await for (final line in lines.timeout(_t(idleSec))) {
        if (cancel?.cancelled == true) return;
        if (!line.startsWith('data:')) continue; // comments (": keep-alive") and event names
        final d = line.substring(5).trim();
        if (d == '[DONE]') return;
        if (d.isNotEmpty) yield d;
      }
    } catch (e) {
      if (cancel?.cancelled == true) return;
      if (e is ApiError) rethrow;
      if (e is SocketException) throw ApiError('No internet connection (${e.message}).', -1, who, model);
      if (e is TimeoutException) throw _timedOut('$who stopped answering. Try again.', who, model);
      if (e is HandshakeException) throw ApiError('Secure connection failed (${e.message}).', -1, who, model);
      if (e is HttpException) throw ApiError('Connection problem (${e.message}).', -1, who, model);
      rethrow;
    } finally {
      cancel?._client = null;
      client.close(force: true);
    }
  }

  /// An [ApiError] for an HTTP error answer, with the service, model and the service's own reason attached.
  static ApiError fail(String who, int status, String body, {String model = ''}) =>
      ApiError(explain(who, status, body), status, who, model, detail(body));

  /// Short reason out of an error body ({"error": {"message": ...}} and similar).
  static String detail(String body) {
    var d = '';
    try {
      final j = jsonDecode(body);
      if (j is Map) {
        final e = j['error'];
        if (e is Map) {
          d = '${e['message'] ?? ''}';
        } else if (e is String) {
          d = '${j['error_description'] ?? e}';
        } else if (j['message'] is String) {
          d = j['message'] as String;
        }
      }
    } catch (_) {}
    if (d.length > 240) d = '${d.substring(0, 240)}…';
    return d;
  }

  /// A thinking model used its whole answer allowance on thinking and wrote nothing.
  static bool isThinkingOnly(String message) => message.contains('on thinking and wrote nothing');

  /// The service says this model is not for normal chat requests (batch-only, agent-only).
  static bool unusableText(String lower) =>
      lower.contains('agentic harness') || lower.contains('cannot be used with the chat/completions') || lower.contains('batchadapter') || lower.contains('only available on');

  static String explain(String who, int status, String body) {
    final d = detail(body);
    switch (status) {
      case 400:
        return '$who refused the request. $d'.trim();
      case 401:
        return 'The $who key was rejected. Check it in Settings. $d'.trim();
      case 403:
        // 403 is not always the key: a model that only works elsewhere, or a service that blocks this country/network.
        final l = d.toLowerCase();
        if (unusableText(l)) return '$who: this model cannot be used by AIy (it only works in other apps). Pick another model. $d'.trim();
        if (l.contains('network') || l.contains('region') || l.contains('country') || l.contains('location') || l.contains('access denied')) {
          return '$who refused this internet connection (not your key): it does not serve this country or network. Try another network or a VPN, or use another service. $d'.trim();
        }
        return 'The $who key was rejected, or it may not use this. Check it in Settings. $d'.trim();
      case 402:
        return '$who says there is not enough credit for this. $d'.trim();
      case 404:
        if (unusableText(d.toLowerCase())) return '$who: this model cannot be used by AIy (it only works in other apps). Pick another model. $d'.trim();
        return '$who: not found. $d'.trim();
      case 413:
        return '$who says the request is too big.';
      case 429:
        return 'The $who limit is used up for now. $d'.trim();
      case 500:
      case 502:
      case 503:
      case 504:
        return '$who is busy right now (error $status). $d'.trim();
      default:
        return '$who error $status. $d'.trim();
    }
  }

  /// One GET; returns the value of a response header ('' when it is missing).
  static Future<String> sendWithHeader(Uri uri, Map<String, String> headers, String header) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final req = await client.getUrl(uri);
      for (final e in headers.entries) {
        req.headers.set(e.key, e.value);
      }
      final resp = await req.close().timeout(const Duration(seconds: 30));
      await resp.drain<void>();
      if (resp.statusCode != 200) throw ApiError(explain('GitHub', resp.statusCode, ''), resp.statusCode);
      return resp.headers.value(header) ?? '';
    } on SocketException catch (e) {
      throw ApiError('No internet connection (${e.message}).', -1);
    } on TimeoutException {
      throw ApiError('GitHub took too long to answer. Try again.', -1);
    } finally {
      client.close(force: true);
    }
  }

  /// Sends a file as the request body (used for release assets).
  static Future<({int status, String body})> upload(Uri uri, File file, {Map<String, String> headers = const {}, String contentType = 'application/octet-stream', int timeoutSec = 600, String who = 'The server'}) async {
    final client = HttpClient()..connectionTimeout = _connect;
    try {
      final req = await client.postUrl(uri);
      for (final e in headers.entries) {
        req.headers.set(e.key, e.value);
      }
      req.headers.set('Content-Type', contentType);
      req.contentLength = await file.length();
      await req.addStream(file.openRead());
      final resp = await req.close().timeout(_t(timeoutSec));
      final text = await resp.transform(const Utf8Decoder(allowMalformed: true)).join();
      return (status: resp.statusCode, body: text);
    } on SocketException catch (e) {
      throw ApiError('No internet connection (${e.message}).', -1);
    } on HttpException catch (e) {
      throw ApiError('Connection problem (${e.message}).', -1);
    } on TimeoutException {
      throw _timedOut('$who took too long to answer. Try again.', who);
    } finally {
      client.close(force: true);
    }
  }

  /// Downloads to a file, following redirects by hand so the [headers] (a token) only go to the first address.
  /// The download is kept in "<file>.part": when the line breaks or stalls, the next try continues where it stopped
  /// (HTTP Range) instead of starting again. Timeouts and broken connections are tried again up to [retries] times.
  /// [cancel] pauses the download: the part stays on the phone and the next [download] of the same address continues
  /// from it. A paused download throws an [ApiError] with status -2 (never retried).
  static Future<void> download(Uri uri, File out, {Map<String, String> headers = const {}, void Function(int got)? onProgress, int retries = 3, AiCancel? cancel}) async {
    final part = File('${out.path}.part');
    final marker = File('${out.path}.part.url');
    for (var attempt = 0;; attempt++) {
      try {
        await _downloadOnce(uri, part, marker, headers, onProgress, cancel);
        if (out.existsSync()) out.deleteSync();
        await part.rename(out.path);
        if (marker.existsSync()) marker.deleteSync();
        return;
      } on ApiError catch (e) {
        if (cancel?.cancelled == true) throw ApiError('Paused.', -2);
        // A timeout or a broken connection keeps the part for the next try. "No internet" does too, but is not retried here.
        final again = e.status == -1 && !e.message.startsWith('No internet');
        if (!again || attempt >= retries) rethrow;
        await Future<void>.delayed(Duration(seconds: 2 << attempt));
      }
    }
  }

  static Future<void> _downloadOnce(Uri uri, File part, File marker, Map<String, String> headers, void Function(int got)? onProgress, [AiCancel? cancel]) async {
    var have = 0;
    var validator = '';
    var total = -1;
    if (part.existsSync() && marker.existsSync()) {
      final m = marker.readAsStringSync().split('\n');
      // Only the same address continues an old part; anything else starts again.
      if (m.first == uri.toString()) {
        have = part.lengthSync();
        validator = m.length > 1 ? m[1] : '';
        total = m.length > 2 ? (int.tryParse(m[2]) ?? -1) : -1;
      }
    }
    if (have == 0) {
      if (part.existsSync()) part.deleteSync();
      if (marker.existsSync()) marker.deleteSync();
    }
    final client = HttpClient()..connectionTimeout = _connect;
    cancel?._client = client;
    try {
      var u = uri;
      var h = headers;
      for (var hop = 0; hop < 6; hop++) {
        if (cancel?.cancelled == true) throw ApiError('Paused.', -2);
        final req = await client.getUrl(u);
        req.followRedirects = false;
        for (final e in h.entries) {
          req.headers.set(e.key, e.value);
        }
        if (have > 0) {
          req.headers.set('Range', 'bytes=$have-');
          if (validator.isNotEmpty) req.headers.set('If-Range', validator);
        }
        final res = await req.close().timeout(_t(60));
        if (res.isRedirect || (res.statusCode >= 301 && res.statusCode <= 308 && res.headers.value('location') != null)) {
          final loc = res.headers.value('location');
          await res.drain<void>();
          if (loc == null) throw ApiError('Download failed (redirect without an address).');
          u = u.resolve(loc);
          h = const {};
          continue;
        }
        // "Range not satisfiable" while resuming: everything had already arrived.
        if (res.statusCode == 416 && have > 0) {
          await res.drain<void>();
          return;
        }
        if (res.statusCode != 200 && res.statusCode != 206) {
          final text = await res.transform(const Utf8Decoder(allowMalformed: true)).join();
          throw ApiError(explain('The download', res.statusCode, text), res.statusCode);
        }
        final resumed = res.statusCode == 206 && have > 0;
        // Without an ETag the server cannot tell us the file changed: compare the full size instead.
        final size = fullSize(res.statusCode, res.headers.value('content-range'), res.contentLength);
        if (resumed && validator.isEmpty && (total < 0 || size < 0 || size != total)) {
          await res.drain<void>();
          AppLog.i('download: cannot prove the part belongs to the same file (size $total -> $size); starting again');
          part.deleteSync();
          marker.deleteSync();
          throw _timedOut('The file changed on the server; downloading it again…');
        }
        if (!resumed) have = 0; // the server sent everything from the start
        marker.writeAsStringSync('${uri.toString()}\n${res.headers.value('etag') ?? res.headers.value('last-modified') ?? ''}\n$size');
        final sink = part.openWrite(mode: resumed ? FileMode.append : FileMode.write);
        var got = have;
        try {
          await for (final chunk in res.timeout(_t(60))) {
            if (cancel?.cancelled == true) throw ApiError('Paused.', -2);
            sink.add(chunk);
            got += chunk.length;
            onProgress?.call(got);
          }
        } finally {
          await sink.flush();
          await sink.close();
        }
        return;
      }
      throw ApiError('Download failed (too many redirects).');
    } on FileSystemException catch (e) {
      // Not a connection problem: never retried as if it were one. The .part file stays, so it can continue after space is freed.
      throw ApiError(fileErrorText(e, 'the download'));
    } on SocketException catch (e) {
      throw ApiError('No internet connection (${e.message}).', -1);
    } on HttpException catch (e) {
      throw ApiError('Connection problem (${e.message}).', -1);
    } on TimeoutException {
      throw _timedOut('The download stopped. Trying again…');
    } finally {
      client.close(force: true);
    }
  }

  /// Full file size from a 200 (Content-Length) or a 206 (Content-Range "bytes a-b/total"); -1 when unknown.
  static int fullSize(int status, String? contentRange, int contentLength) {
    if (status == 206 && contentRange != null) {
      final i = contentRange.lastIndexOf('/');
      return i < 0 ? -1 : (int.tryParse(contentRange.substring(i + 1).trim()) ?? -1);
    }
    return status == 200 ? contentLength : -1;
  }
}
