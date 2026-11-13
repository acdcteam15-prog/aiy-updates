import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
  /// One HTTP call with a JSON (or no) body. Never throws for HTTP error codes: check [status].
  static Future<({int status, String body})> send(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    Object? json,
    int timeoutSec = 90,
    String who = 'The server',
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
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
      final resp = await req.close().timeout(Duration(seconds: timeoutSec));
      final text = await resp.transform(utf8.decoder).join().timeout(Duration(seconds: timeoutSec));
      return (status: resp.statusCode, body: text);
    } on SocketException catch (e) {
      throw ApiError('No internet connection (${e.message}).', -1);
    } on TimeoutException {
      throw ApiError('$who took too long to answer. Try again.', -1);
    } on HandshakeException catch (e) {
      throw ApiError('Secure connection failed (${e.message}).', -1);
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
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
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
      final resp = await req.close().timeout(Duration(seconds: startSec));
      if (resp.statusCode != 200) {
        final text = await resp.transform(utf8.decoder).join().timeout(const Duration(seconds: 30));
        throw fail(who, resp.statusCode, text, model: model);
      }
      final lines = resp.transform(utf8.decoder).transform(const LineSplitter());
      await for (final line in lines.timeout(Duration(seconds: idleSec))) {
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
      if (e is TimeoutException) throw ApiError('$who stopped answering. Try again.', -1, who, model);
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

  static String explain(String who, int status, String body) {
    final d = detail(body);
    switch (status) {
      case 400:
        return '$who refused the request. $d'.trim();
      case 401:
      case 403:
        return 'The $who key was rejected. Check it in Settings. $d'.trim();
      case 402:
        return '$who says there is not enough credit for this. $d'.trim();
      case 404:
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
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final req = await client.postUrl(uri);
      for (final e in headers.entries) {
        req.headers.set(e.key, e.value);
      }
      req.headers.set('Content-Type', contentType);
      req.contentLength = await file.length();
      await req.addStream(file.openRead());
      final resp = await req.close().timeout(Duration(seconds: timeoutSec));
      final text = await resp.transform(utf8.decoder).join();
      return (status: resp.statusCode, body: text);
    } on SocketException catch (e) {
      throw ApiError('No internet connection (${e.message}).', -1);
    } on TimeoutException {
      throw ApiError('$who took too long to answer. Try again.', -1);
    } finally {
      client.close(force: true);
    }
  }

  /// Downloads to a file, following redirects by hand so the [headers] (a token) only go to the first address.
  static Future<void> download(Uri uri, File out, {Map<String, String> headers = const {}, void Function(int got)? onProgress}) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      var u = uri;
      var h = headers;
      for (var hop = 0; hop < 6; hop++) {
        final req = await client.getUrl(u);
        req.followRedirects = false;
        for (final e in h.entries) {
          req.headers.set(e.key, e.value);
        }
        final res = await req.close().timeout(const Duration(seconds: 60));
        if (res.isRedirect || (res.statusCode >= 301 && res.statusCode <= 308 && res.headers.value('location') != null)) {
          final loc = res.headers.value('location');
          await res.drain<void>();
          if (loc == null) throw ApiError('Download failed (redirect without an address).');
          u = u.resolve(loc);
          h = const {};
          continue;
        }
        if (res.statusCode != 200) {
          final text = await res.transform(utf8.decoder).join();
          throw ApiError(explain('The download', res.statusCode, text), res.statusCode);
        }
        final sink = out.openWrite();
        var got = 0;
        try {
          await for (final chunk in res.timeout(const Duration(seconds: 60))) {
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
    } on SocketException catch (e) {
      throw ApiError('No internet connection (${e.message}).', -1);
    } on TimeoutException {
      throw ApiError('The download took too long. Try again.', -1);
    } finally {
      client.close(force: true);
    }
  }
}
