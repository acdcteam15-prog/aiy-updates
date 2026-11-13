import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'native.dart';
import 'net.dart';

/// "Connect OpenRouter": the person signs in on openrouter.ai (Google works there) and taps Authorize;
/// OpenRouter then hands a fresh key straight to the app. Nothing to copy.
class OpenRouterConnect {
  HttpServer? _server;
  bool _cancelled = false;

  void cancel() {
    _cancelled = true;
    _server?.close(force: true);
  }

  static String _b64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

  /// Opens the browser and waits (up to 5 minutes) for the key.
  Future<String> run() async {
    final rnd = Random.secure();
    final verifier = _b64(List<int>.generate(48, (_) => rnd.nextInt(256)));
    final challenge = _b64(sha256.convert(ascii.encode(verifier)).bytes);
    // The browser comes back to this little listener on the phone itself.
    HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 3000);
    } on SocketException {
      throw ApiError('Could not start the sign-in helper (port 3000 is busy). Close other apps and try again, or paste a key instead.');
    }
    _server = server;
    final auth = Uri.https('openrouter.ai', '/auth', {
      'callback_url': 'http://localhost:3000/callback',
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
    });
    if (!await Native.openUrl(auth.toString())) {
      await server.close(force: true);
      throw ApiError('Could not open the browser.');
    }
    String? code;
    try {
      await for (final req in server.timeout(const Duration(minutes: 5))) {
        code = req.uri.queryParameters['code'];
        req.response.headers.contentType = ContentType.html;
        req.response.write('<!doctype html><meta name="viewport" content="width=device-width, initial-scale=1">'
            '<body style="font-family:system-ui,sans-serif;background:#0b1026;color:#e8ebff;text-align:center;padding:64px 24px">'
            '<h2>${code == null ? 'Something went wrong' : 'Connected'}</h2>'
            '<p>${code == null ? 'No code arrived. Go back to AIy and try again.' : 'You can go back to AIy now.'}</p></body>');
        await req.response.close();
        if (code != null) break;
      }
    } on TimeoutException {
      throw ApiError('The sign-in was not finished in time. Try again.');
    } finally {
      await server.close(force: true);
      _server = null;
    }
    if (_cancelled) throw ApiError('Cancelled.');
    if (code == null) throw ApiError('OpenRouter sent no code. Try again, or paste a key instead.');
    final r = await Net.send('POST', Uri.parse('https://openrouter.ai/api/v1/auth/keys'),
        json: {'code': code, 'code_verifier': verifier, 'code_challenge_method': 'S256'}, timeoutSec: 45, who: 'OpenRouter');
    if (r.status != 200) throw ApiError(Net.explain('OpenRouter', r.status, r.body), r.status);
    final key = '${(jsonDecode(r.body) as Map)['key'] ?? ''}';
    if (key.isEmpty) throw ApiError('OpenRouter sent no key. Try again, or paste a key instead.');
    return key;
  }
}

/// "Connect GitHub" with GitHub's device sign-in: the app shows a short code, the person types it on github.com.
class GitHubConnect {
  final String clientId;
  bool _cancelled = false;
  GitHubConnect(this.clientId);

  void cancel() => _cancelled = true;

  static const _h = {'Accept': 'application/json', 'User-Agent': 'AIy'};

  /// Step 1: the code to show and the page to open.
  Future<({String userCode, String url, String deviceCode, int interval, int expires})> begin() async {
    final r = await Net.send('POST', Uri.parse('https://github.com/login/device/code'), headers: _h, json: {'client_id': clientId, 'scope': 'repo workflow'}, timeoutSec: 30, who: 'GitHub');
    if (r.status != 200) throw ApiError(Net.explain('GitHub', r.status, r.body), r.status);
    final j = jsonDecode(r.body) as Map;
    if (j['device_code'] == null) throw ApiError('GitHub refused the sign-in: ${j['error_description'] ?? j['error'] ?? 'unknown reason'}. The app owner must enable "Device Flow" for the GitHub OAuth app.');
    return (
      userCode: '${j['user_code']}',
      url: '${j['verification_uri'] ?? 'https://github.com/login/device'}',
      deviceCode: '${j['device_code']}',
      interval: (j['interval'] as num?)?.toInt() ?? 5,
      expires: (j['expires_in'] as num?)?.toInt() ?? 900,
    );
  }

  /// Step 2: waits until the person has typed the code on github.com, then returns the token.
  Future<String> waitForToken(String deviceCode, int interval, int expires) async {
    var wait = interval;
    final end = DateTime.now().add(Duration(seconds: expires));
    while (DateTime.now().isBefore(end)) {
      await Future<void>.delayed(Duration(seconds: wait));
      if (_cancelled) throw ApiError('Cancelled.');
      final r = await Net.send('POST', Uri.parse('https://github.com/login/oauth/access_token'),
          headers: _h, json: {'client_id': clientId, 'device_code': deviceCode, 'grant_type': 'urn:ietf:params:oauth:grant-type:device_code'}, timeoutSec: 30, who: 'GitHub');
      if (r.status != 200) continue;
      final j = jsonDecode(r.body) as Map;
      if (j['access_token'] is String) return j['access_token'] as String;
      switch ('${j['error']}') {
        case 'authorization_pending':
          break;
        case 'slow_down':
          wait += 5;
        case 'access_denied':
          throw ApiError('The sign-in was cancelled on GitHub.');
        case 'expired_token':
          throw ApiError('The code expired. Try again.');
        default:
          throw ApiError('GitHub: ${j['error_description'] ?? j['error']}');
      }
    }
    throw ApiError('The code expired. Try again.');
  }
}
