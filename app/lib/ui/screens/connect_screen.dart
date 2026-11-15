import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../owner_config.dart';
import '../../state/ai.dart';
import '../../state/connect.dart';
import '../../state/keys.dart';
import '../../state/native.dart';
import '../../state/net.dart';
import '../../state/prefs.dart';
import '../widgets/common.dart';
import '../widgets/fx.dart';
import '../../state/app_log.dart';

class _Service {
  final String id;
  final String name;
  final IconData icon;
  final String what;
  final String keyPage;
  final List<String> steps;
  final bool optional;
  const _Service(this.id, this.name, this.icon, this.what, this.keyPage, this.steps, {this.optional = false});
}

const _services = [
  _Service('gemini', 'Google Gemini', Icons.auto_awesome_rounded, 'The main free brain: chat, photos and live internet search.', 'https://aistudio.google.com/apikey', [
    'Tap "Get my free key". A Google page opens: sign in with your Google account.',
    'Tap "Create API key", then tap the copy icon next to the new key.',
    'Come back to AIy. The key is picked up from the clipboard by itself.',
  ]),
  _Service('openrouter', 'OpenRouter', Icons.hub_rounded, 'Hundreds of models for coding, including free ones. Also the backup when Gemini is busy.', 'https://openrouter.ai/keys', [
    'Tap "Connect". OpenRouter opens: choose "Continue with Google".',
    'Tap "Authorize", then switch back to AIy. It is connected. Nothing to copy.',
  ]),
  _Service('groq', 'Groq', Icons.speed_rounded, 'A very fast free backup for chat.', 'https://console.groq.com/keys', [
    'Tap "Get my free key" and sign in with Google.',
    'Tap "Create API Key", give it any name, then copy the key.',
    'Come back to AIy. The key is picked up from the clipboard by itself.',
  ], optional: true),
  _Service('mistral', 'Mistral', Icons.air_rounded, 'A free European backup for chat (about a billion free words a month). The free plan may use what you send to train its models unless you switch that off in its settings.', 'https://console.mistral.ai/api-keys', [
    'Tap \"Get my free key\", create an account and pick the free \"Experiment\" plan (no card).',
    'Create an API key and copy it.',
    'Come back to AIy and tap \"Paste it myself\".',
  ], optional: true),
  _Service('cerebras', 'Cerebras', Icons.bolt_rounded, 'Extremely fast answers. Short texts only on the free plan. Cerebras may give credits instead of a permanent free plan: check on their page.', 'https://cloud.cerebras.ai', [
    'Tap \"Get my free key\" and sign in.',
    'Create an API key and copy it.',
    'Come back to AIy. The key is picked up from the clipboard by itself.',
  ], optional: true),
  _Service('nvidia', 'NVIDIA', Icons.memory_rounded, 'Free access to many open models from NVIDIA\'s catalog.', 'https://build.nvidia.com/settings/api-keys', [
    'Tap \"Get my free key\" and sign in with a free NVIDIA account.',
    'Tap \"Generate API key\" and copy it.',
    'Come back to AIy. The key is picked up from the clipboard by itself.',
  ], optional: true),
  _Service('cloudflare', 'Cloudflare', Icons.cloud_outlined, 'A small free allowance every day. Needs two things: an API token and your account number.', 'https://dash.cloudflare.com/profile/api-tokens', [
    'Tap \"Get my free key\", sign in, tap \"Create token\" and use the \"Workers AI\" template. Copy the token.',
    'Your account number is in the address of the Cloudflare dashboard, or on the right of the Workers AI page.',
    'Come back to AIy and tap \"Paste it myself\": it asks for both.',
  ], optional: true),
  _Service('github', 'GitHub', Icons.code_rounded, 'Lets AIy open your repositories, send the changes back and build the app for you.', 'https://github.com/settings/tokens/new?scopes=repo,workflow&description=AIy', [
    'Tap "Connect". AIy shows a short code.',
    'GitHub opens: sign in (Google works), type the code and tap Authorize.',
  ], optional: true),
];

/// The setup steps (first run) and, later, "Accounts & keys" in Settings.
class ConnectScreen extends StatefulWidget {
  final bool firstRun;
  const ConnectScreen({super.key, this.firstRun = false});
  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> with WidgetsBindingObserver {
  /// Per service: 'testing', 'ok: message' or 'err: message'.
  final Map<String, String> _status = {};
  String _connecting = '';
  OpenRouterConnect? _or;
  String _lastClip = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _or?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from the browser: a copied key is picked up by itself.
    if (state == AppLifecycleState.resumed) Future<void>.delayed(const Duration(milliseconds: 400), _checkClipboard);
  }

  Future<void> _checkClipboard() async {
    if (!mounted) return;
    try {
      final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim() ?? '';
      if (text.isEmpty || text == _lastClip) return;
      final id = KeyVault.detect(text);
      if (id.isEmpty || !mounted) return;
      final keys = context.read<KeyVault>();
      if (keys.get(id) == text) return;
      _lastClip = text;
      await _save(id, text);
      if (mounted) snack(context, '${AiEngine.names[id]} key found in the clipboard and saved.');
    } catch (e) {
      AppLog.i('connect_screen:114: $e');
    }
  }

  Future<void> _save(String id, String key) async {
    final keys = context.read<KeyVault>();
    final engine = context.read<AiEngine>();
    await keys.set(id, key);
    if (key.trim().isEmpty) {
      if (mounted) setState(() => _status.remove(id));
      return;
    }
    if (mounted) setState(() => _status[id] = 'testing');
    try {
      final msg = await engine.test(id);
      if (mounted) setState(() => _status[id] = 'ok: $msg');
    } on ApiError catch (e) {
      if (mounted) setState(() => _status[id] = 'err: ${e.message}');
    } catch (e) {
      if (mounted) setState(() => _status[id] = 'err: $e');
    }
  }

  Future<void> _pasteCloudflare(_Service s) async {
    final keys = context.read<KeyVault>();
    final acct = TextEditingController(text: keys.get('cloudflare_acct'));
    final tok = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Cloudflare'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: acct, decoration: const InputDecoration(labelText: 'Account number', hintText: '32 letters and numbers')),
          const SizedBox(height: 10),
          TextField(controller: tok, obscureText: true, decoration: const InputDecoration(labelText: 'API token')),
          TextButton.icon(icon: const Icon(Icons.content_paste_rounded, size: 18), label: const Text('Paste the token from the clipboard'), onPressed: () async => tok.text = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim() ?? ''),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(style: FilledButton.styleFrom(minimumSize: const Size(64, 44)), onPressed: () => Navigator.pop(c, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok != true) return;
    final a = acct.text.trim();
    final t = tok.text.trim();
    if (a.isEmpty || t.isEmpty) {
      if (mounted) snack(context, 'Both the account number and the token are needed.');
      return;
    }
    await keys.set('cloudflare_acct', a);
    await _save('cloudflare', t);
  }

  Future<void> _paste(_Service s) async {
    if (s.id == 'cloudflare') return _pasteCloudflare(s);
    final ctl = TextEditingController();
    final key = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('${s.name} key'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(controller: ctl, autofocus: true, obscureText: true, textInputAction: TextInputAction.done, onSubmitted: (v) => Navigator.pop(c, v.trim()), decoration: const InputDecoration(hintText: 'Paste the key here')),
          const SizedBox(height: 8),
          TextButton.icon(
            icon: const Icon(Icons.content_paste_rounded, size: 18),
            label: const Text('Paste from clipboard'),
            onPressed: () async => ctl.text = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim() ?? '',
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(style: FilledButton.styleFrom(minimumSize: const Size(64, 44)), onPressed: () => Navigator.pop(c, ctl.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (key != null && key.isNotEmpty) await _save(s.id, key);
  }

  Future<void> _connectOpenRouter() async {
    setState(() => _connecting = 'openrouter');
    final flow = _or = OpenRouterConnect();
    try {
      final key = await flow.run();
      await _save('openrouter', key);
    } on ApiError catch (e) {
      if (mounted && e.message != 'Cancelled.') setState(() => _status['openrouter'] = 'err: ${e.message}');
    } catch (e) {
      if (mounted) setState(() => _status['openrouter'] = 'err: $e');
    } finally {
      _or = null;
      if (mounted) setState(() => _connecting = '');
    }
  }

  Future<void> _connectGitHub() async {
    final flow = GitHubConnect(OwnerConfig.githubClientId);
    setState(() => _connecting = 'github');
    try {
      final d = await flow.begin();
      if (!mounted) return;
      final token = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (c) => _DeviceCodeDialog(flow: flow, userCode: d.userCode, url: d.url, deviceCode: d.deviceCode, interval: d.interval, expires: d.expires),
      );
      flow.cancel();
      if (token != null && token.isNotEmpty) await _save('github', token);
    } on ApiError catch (e) {
      if (mounted) setState(() => _status['github'] = 'err: ${e.message}');
    } finally {
      if (mounted) setState(() => _connecting = '');
    }
  }

  Future<void> _disconnect(_Service s) async {
    if (await confirmDialog(context, 'Disconnect ${s.name}?', body: 'The key is removed from this phone. You can connect again any time.', yes: 'Disconnect')) {
      if (!mounted) return;
      if (s.id == 'cloudflare') await context.read<KeyVault>().set('cloudflare_acct', '');
      await _save(s.id, '');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final keys = context.watch<KeyVault>();
    final user = FirebaseAuth.instance.currentUser;
    final first = (user?.displayName ?? '').split(' ').first;
    final ready = keys.canChat;
    final body = ListView(
      padding: EdgeInsets.fromLTRB(20, widget.firstRun ? 28 : 8, 20, 32),
      children: [
        if (widget.firstRun) ...[
          const Appear(child: Align(alignment: Alignment.centerLeft, child: Orb(size: 56))),
          const SizedBox(height: 18),
          Appear(delay: 80, child: Text(first.isEmpty ? 'Welcome' : 'Welcome, $first', style: t.textTheme.headlineMedium)),
          const SizedBox(height: 8),
          Appear(
            delay: 140,
            child: Text('Let\'s connect your free AI accounts. Use the same Google account for all of them. It takes about three minutes.',
                style: t.textTheme.bodyLarge?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          ),
          const SizedBox(height: 20),
        ],
        for (var i = 0; i < _services.length; i++) ...[
          Appear(delay: widget.firstRun ? 200 + i * 90 : i * 50, child: _card(_services[i], keys)),
          const SizedBox(height: 14),
        ],
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.lock_outline_rounded, size: 18, color: t.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Your keys are stored encrypted on this phone only and go straight to the service they belong to. '
              'Free plans of AI services may use what you send to improve their models, so do not share secrets on a free plan.',
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
          ),
        ]),
        if (widget.firstRun) ...[
          const SizedBox(height: 24),
          FilledButton(
            onPressed: ready ? () => context.read<LocalPrefs>().setOnboarded(true) : null,
            child: Text(ready ? 'Start using AIy' : 'Connect Gemini or OpenRouter to continue'),
          ),
        ],
      ],
    );
    return Scaffold(
      appBar: widget.firstRun ? null : AppBar(title: const Text('Accounts & keys')),
      body: widget.firstRun ? AuroraBackground(strength: 0.6, child: SafeArea(child: body)) : body,
    );
  }

  Widget _card(_Service s, KeyVault keys) {
    final t = Theme.of(context);
    final has = keys.has(s.id);
    final st = _status[s.id] ?? '';
    final busy = _connecting == s.id || st == 'testing';
    final oneTap = s.id == 'openrouter' || (s.id == 'github' && OwnerConfig.githubClientId.isNotEmpty);
    final steps = s.id == 'github' && !oneTap
        ? const ['Tap "Create a token". GitHub opens: sign in (Google works).', 'Keep "repo" and "workflow" ticked, scroll down, tap "Generate token", then copy it.', 'Come back to AIy. The token is picked up from the clipboard by itself.']
        : s.steps;
    return StepCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          CircleAvatar(radius: 20, backgroundColor: t.colorScheme.primary.withValues(alpha: 0.14), child: Icon(s.icon, color: t.colorScheme.primary, size: 20)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(child: Text(s.name, style: t.textTheme.titleMedium)),
                if (s.optional) ...[
                  const SizedBox(width: 8),
                  Text('optional', style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                ],
              ]),
              Text(s.what, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            ]),
          ),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
            child: busy
                ? const SizedBox(key: ValueKey('b'), width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4))
                : has
                    ? Icon(st.startsWith('err') ? Icons.error_rounded : Icons.check_circle_rounded, key: ValueKey('ok$st'), color: st.startsWith('err') ? t.colorScheme.error : const Color(0xFF34C759), size: 26)
                    : const SizedBox(key: ValueKey('n'), width: 26),
          ),
        ]),
        if (!has) ...[
          const SizedBox(height: 12),
          for (var i = 0; i < steps.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(width: 22, child: Text('${i + 1}.', style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.primary, fontWeight: FontWeight.w700))),
                Expanded(child: Text(steps[i], style: t.textTheme.bodyMedium)),
              ]),
            ),
        ],
        if (st.startsWith('ok: ') || st.startsWith('err: ')) ...[
          const SizedBox(height: 8),
          Text(st.substring(st.indexOf(' ') + 1), style: t.textTheme.bodySmall?.copyWith(color: st.startsWith('err') ? t.colorScheme.error : t.colorScheme.onSurfaceVariant)),
        ],
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
          if (!has && oneTap)
            FilledButton.tonal(
              style: FilledButton.styleFrom(minimumSize: const Size(64, 44)),
              onPressed: busy ? null : (s.id == 'openrouter' ? _connectOpenRouter : _connectGitHub),
              child: Text(_connecting == s.id ? 'Waiting for you…' : 'Connect'),
            ),
          if (!has && !oneTap)
            FilledButton.tonal(
              style: FilledButton.styleFrom(minimumSize: const Size(64, 44)),
              onPressed: () => Native.openUrl(s.keyPage),
              child: Text(s.id == 'github' ? 'Create a token' : 'Get my free key'),
            ),
          if (!has) TextButton(onPressed: busy ? null : () => _paste(s), child: Text(oneTap ? 'Paste a key instead' : 'Paste it myself')),
          if (_connecting == 'openrouter' && s.id == 'openrouter') TextButton(onPressed: () => _or?.cancel(), child: const Text('Cancel')),
          if (has) ...[
            TextButton(onPressed: busy ? null : () => _save(s.id, keys.get(s.id)), child: const Text('Test')),
            TextButton(onPressed: busy ? null : () => _paste(s), child: const Text('Replace')),
            TextButton(onPressed: busy ? null : () => _disconnect(s), child: const Text('Disconnect')),
          ],
        ]),
      ]),
    );
  }
}

/// GitHub's device sign-in: show the code, open GitHub, wait.
class _DeviceCodeDialog extends StatefulWidget {
  final GitHubConnect flow;
  final String userCode;
  final String url;
  final String deviceCode;
  final int interval;
  final int expires;
  const _DeviceCodeDialog({required this.flow, required this.userCode, required this.url, required this.deviceCode, required this.interval, required this.expires});
  @override
  State<_DeviceCodeDialog> createState() => _DeviceCodeDialogState();
}

class _DeviceCodeDialogState extends State<_DeviceCodeDialog> {
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.flow.waitForToken(widget.deviceCode, widget.interval, widget.expires).then((token) {
      if (mounted) Navigator.pop(context, token);
    }).catchError((Object e) {
      if (mounted) setState(() => _error = e is ApiError ? e.message : '$e');
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return AlertDialog(
      title: const Text('Connect GitHub'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Type this code on the GitHub page:'),
        const SizedBox(height: 14),
        SelectableText(widget.userCode, style: t.textTheme.headlineMedium?.copyWith(fontFamily: 'monospace', letterSpacing: 3, color: t.colorScheme.primary)),
        const SizedBox(height: 14),
        if (_error != null) Text(_error!, style: TextStyle(color: t.colorScheme.error)) else const Row(mainAxisSize: MainAxisSize.min, children: [ThinkingDots(), SizedBox(width: 10), Text('Waiting for GitHub…')]),
      ]),
      actions: [
        TextButton(
          onPressed: () {
            widget.flow.cancel();
            Navigator.pop(context);
          },
          child: Text(_error == null ? 'Cancel' : 'Close'),
        ),
        if (_error == null)
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(64, 44)),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: widget.userCode));
              Native.openUrl(widget.url);
            },
            child: const Text('Copy code & open GitHub'),
          ),
      ],
    );
  }
}
