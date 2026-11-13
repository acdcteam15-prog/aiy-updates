import 'tour_screen.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../state/ai.dart';
import '../../state/auth_service.dart';
import '../../state/chat_store.dart';
import '../../state/keys.dart';
import '../../state/prefs.dart';
import '../../state/updater.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/fx.dart';
import '../widgets/markdown.dart';
import '../../state/app_builder.dart';
import '../../state/backup.dart';
import '../../state/code_state.dart';
import '../../state/lock.dart';
import '../../state/native.dart';
import '../../state/net.dart';
import '../../state/spend.dart';
import 'connect_screen.dart';
import 'diagnostics_screen.dart';
import 'lock_screen.dart';
import 'log_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final p = context.watch<LocalPrefs>();
    final keys = context.watch<KeyVault>();
    final engine = Provider.of<AiEngine>(context, listen: false);
    final user = FirebaseAuth.instance.currentUser;
    final sub = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    Widget head(String s) => Padding(padding: const EdgeInsets.fromLTRB(6, 22, 6, 8), child: Text(s, style: t.textTheme.titleSmall?.copyWith(color: t.colorScheme.primary)));
    final connected = KeyVault.ids.where(keys.has).length;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 40), children: [
        // ---- account
        StepCard(
          padding: const EdgeInsets.all(6),
          child: Column(children: [
            ListTile(
              leading: CircleAvatar(
                backgroundColor: t.colorScheme.primary,
                foregroundImage: user?.photoURL == null ? null : NetworkImage(user!.photoURL!),
                child: Icon(Icons.person_rounded, color: t.colorScheme.onPrimary),
              ),
              title: Text(user?.displayName ?? 'Signed in'),
              subtitle: Text(user?.email ?? ''),
            ),
            ListTile(
              leading: const Icon(Icons.key_rounded),
              title: const Text('Accounts & keys'),
              subtitle: Text('$connected of ${KeyVault.ids.length} connected'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const ConnectScreen())),
            ),
          ]),
        ),

        // ---- look
        head('Look'),
        StepCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<ThemeMode>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: ThemeMode.system, label: Text('Auto'), icon: Icon(Icons.brightness_auto_rounded, size: 18)),
                  ButtonSegment(value: ThemeMode.light, label: Text('Light'), icon: Icon(Icons.light_mode_rounded, size: 18)),
                  ButtonSegment(value: ThemeMode.dark, label: Text('Dark'), icon: Icon(Icons.dark_mode_rounded, size: 18)),
                ],
                selected: {p.themeMode},
                onSelectionChanged: (s) => p.setThemeMode(s.first),
              ),
            ),
            const SizedBox(height: 16),
            Text('Colour', style: t.textTheme.titleSmall),
            const SizedBox(height: 10),
            Wrap(spacing: 12, runSpacing: 12, children: [
              for (var i = 0; i < kPresets.length; i++)
                Pressable(
                  onTap: () => p.setPreset(i),
                  child: Column(children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: SweepGradient(colors: [...kPresets[i].glow, kPresets[i].glow.first]),
                        border: Border.all(color: p.preset == i ? t.colorScheme.onSurface : Colors.transparent, width: 3),
                      ),
                      child: p.preset == i ? const Icon(Icons.check_rounded, color: Colors.white) : null,
                    ),
                    const SizedBox(height: 4),
                    Text(kPresets[i].name, style: t.textTheme.labelSmall),
                  ]),
                ),
            ]),
            const SizedBox(height: 8),
            SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Pure black in dark mode'), value: p.amoled, onChanged: p.setAmoled),
            SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Fewer animations'), value: p.reduceMotion, onChanged: p.setReduceMotion),
            Row(children: [
              const Text('Text size'),
              Expanded(child: Slider(value: p.fontScale, min: 0.85, max: 1.4, divisions: 11, label: '${(p.fontScale * 100).round()}%', onChanged: p.setFontScale)),
            ]),
          ]),
        ),

        head('Simple or Advanced'),
        StepCard(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
          child: SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Advanced mode'),
            subtitle: const Text('Shows which AI answered, the "which AI" menu in chat and the list of models in use. Prices are always shown before any money is spent.'),
            value: p.advanced,
            onChanged: p.setAdvanced,
          ),
        ),

        // ---- chat + coding
        head('Chat'),
        StepCard(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
          child: SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Live internet search'),
            subtitle: const Text('Answers can use Google Search. Works when Gemini answers.'),
            value: p.liveSearch,
            onChanged: p.setLiveSearch,
          ),
        ),
        head('Standing instructions'),
        const _Instructions(),
        head('Coding'),
        StepCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text('Spending limit for one request', style: t.textTheme.titleSmall)),
              Text('\$${p.capUsd.toStringAsFixed(2)}', style: t.textTheme.titleMedium?.copyWith(color: t.colorScheme.primary)),
            ]),
            Slider(value: p.capUsd.clamp(0.05, 3.0), min: 0.05, max: 3.0, divisions: 59, onChanged: (v) => p.setCapUsd((v * 20).round() / 20)),
            Text(
              'A paid OpenRouter model can never cost more than this for one request: AIy refuses bigger requests and limits the length of the answer. '
              'Free models always cost nothing. Paid models need credit in your OpenRouter account.',
              style: sub,
            ),
          ]),
        ),

        // ---- usage
        head('Used today'),
        StepCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final id in const ['gemini', 'groq', 'openrouter'])
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  Expanded(child: Text(AiEngine.names[id]!)),
                  Text(keys.has(id) ? '${p.usage(id)} request(s)' : 'not connected', style: sub),
                ]),
              ),
            const SizedBox(height: 6),
            Text('When a free daily limit is reached, AIy moves to the next model and service by itself: Gemini, then Groq, then OpenRouter\'s free models.', style: sub),
            const SizedBox(height: 6),
            if (p.advanced) Text('Models in use: ${[for (final id in const ['gemini', 'groq', 'openrouter']) if (keys.has(id)) engine.modelsFor(id).take(2).join(', ')].join(' · ')}', style: sub),
          ]),
        ),

        head('Spending'),
        const _SpendCard(),
        head('Security and backup'),
        const _SecurityCard(),
        head('Help'),
        StepCard(
          padding: const EdgeInsets.all(6),
          child: Column(children: [
            ListTile(leading: const Icon(Icons.health_and_safety_outlined), title: const Text('Test everything'), subtitle: const Text('Checks your keys, GitHub and the phone parts, and says what is wrong'), trailing: const Icon(Icons.chevron_right_rounded), onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const DiagnosticsScreen()))),
            ListTile(leading: const Icon(Icons.slideshow_rounded), title: const Text('Show the welcome tour again'), trailing: const Icon(Icons.chevron_right_rounded), onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const TourScreen(replay: true)))),
            ListTile(leading: const Icon(Icons.receipt_long_outlined), title: const Text('Log'), subtitle: const Text('The last things AIy did, with keys removed'), trailing: const Icon(Icons.chevron_right_rounded), onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const LogScreen()))),
          ]),
        ),

        // ---- updates
        head('About'),
        const _UpdateCard(),

        // ---- data
        head('Data on this phone'),
        StepCard(
          padding: const EdgeInsets.all(6),
          child: Column(children: [
            ListTile(
              leading: const Icon(Icons.delete_sweep_outlined),
              title: const Text('Delete all chats'),
              onTap: () async {
                if (await confirmDialog(context, 'Delete all chats?', body: 'This cannot be undone.', yes: 'Delete')) {
                  await context.read<ChatStore>().deleteAll();
                  if (context.mounted) snack(context, 'All chats deleted.');
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.logout_rounded),
              title: const Text('Sign out'),
              subtitle: const Text('Your keys stay on this phone.'),
              onTap: () async {
                if (await confirmDialog(context, 'Sign out?', yes: 'Sign out')) {
                  if (context.mounted) Navigator.popUntil(context, (r) => r.isFirst);
                  await AuthService.signOut();
                }
              },
            ),
            ListTile(
              leading: Icon(Icons.key_off_rounded, color: t.colorScheme.error),
              title: Text('Sign out and remove all keys', style: TextStyle(color: t.colorScheme.error)),
              onTap: () async {
                if (await confirmDialog(context, 'Remove all keys and sign out?', body: 'Use this before giving the phone to someone else.', yes: 'Remove')) {
                  if (context.mounted) Navigator.popUntil(context, (r) => r.isFirst);
                  await keys.clearAll();
                  await p.setOnboarded(false);
                  await AuthService.signOut();
                }
              },
            ),
          ]),
        ),
      ]),
    );
  }
}

/// Version, "Check for updates" and the in-app update (downloaded, checked, then handed to Android).
class _UpdateCard extends StatefulWidget {
  const _UpdateCard();
  @override
  State<_UpdateCard> createState() => _UpdateCardState();
}

class _UpdateCardState extends State<_UpdateCard> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final u = context.read<UpdateService>();
      if (u.installedBuild == 0 && !u.busy) u.check();
    });
  }

  @override
  Widget build(BuildContext context) {
    final u = context.watch<UpdateService>();
    final p = context.watch<LocalPrefs>();
    final t = Theme.of(context);
    final sub = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final latest = u.latest;
    String state;
    switch (u.status) {
      case UpdateStatus.checking:
        state = 'Checking…';
      case UpdateStatus.downloading:
        state = 'Downloading… ${(u.progress * 100).round()}%';
      case UpdateStatus.installing:
        state = 'Opening the installer…';
      case UpdateStatus.error:
        state = u.error == 'corrupt' ? 'The download was damaged. Try again.' : 'Could not check for updates (${u.error}).';
      default:
        state = u.hasUpdate ? 'Version ${latest!.versionName} is available.' : 'You have the newest version.';
    }
    return StepCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Orb(size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('AIy ${u.installedName}', style: t.textTheme.titleMedium),
              Text(state, style: sub),
            ]),
          ),
        ]),
        if (u.status == UpdateStatus.downloading) Padding(padding: const EdgeInsets.only(top: 12), child: LinearProgressIndicator(value: u.progress == 0 ? null : u.progress, borderRadius: BorderRadius.circular(8))),
        if (u.needsPermission)
          Padding(padding: const EdgeInsets.only(top: 10), child: Text('Android needs your permission once: switch on "Allow from this source" for AIy, come back, and tap Update again.', style: sub?.copyWith(color: t.colorScheme.error))),
        if (u.hasUpdate && latest!.notes.isNotEmpty) ...[const SizedBox(height: 10), MdText(latest.notes)],
        const SizedBox(height: 10),
        Row(children: [
          if (u.hasUpdate)
            FilledButton(style: FilledButton.styleFrom(minimumSize: const Size(64, 44)), onPressed: u.busy ? null : u.downloadAndInstall, child: const Text('Update'))
          else
            OutlinedButton(onPressed: u.busy ? null : () => u.check(), child: const Text('Check for updates')),
        ]),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Check automatically'), value: p.autoUpdateCheck, onChanged: p.setAutoUpdateCheck),
      ]),
    );
  }
}


/// Text AIy always follows in chat ("answer short", "I am a beginner"...).
class _Instructions extends StatefulWidget {
  const _Instructions();
  @override
  State<_Instructions> createState() => _InstructionsState();
}

class _InstructionsState extends State<_Instructions> {
  late final TextEditingController _c = TextEditingController(text: context.read<LocalPrefs>().customInstructions);
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return StepCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        TextField(
          controller: _c,
          minLines: 2,
          maxLines: 5,
          maxLength: 600,
          onChanged: (v) => context.read<LocalPrefs>().setCustomInstructions(v),
          decoration: const InputDecoration(hintText: 'For example: answer in short sentences. I am a beginner. Reply in Arabic.'),
        ),
        Text('Used in every chat. Not used for the Code and Build tabs.', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
      ]),
    );
  }
}

/// What the paid requests really cost, and what OpenRouter says about the key.
class _SpendCard extends StatefulWidget {
  const _SpendCard();
  @override
  State<_SpendCard> createState() => _SpendCardState();
}

class _SpendCardState extends State<_SpendCard> {
  String _credit = '';
  bool _busy = false;

  Future<void> _check() async {
    setState(() {
      _busy = true;
      _credit = '';
    });
    try {
      final c = await Provider.of<AiEngine>(context, listen: false).credit();
      _credit = c.left != null
          ? 'OpenRouter credit left on this key: \$${c.left!.toStringAsFixed(2)} (used so far: \$${c.used.toStringAsFixed(2)}).'
          : 'OpenRouter says this key has used \$${c.used.toStringAsFixed(2)} so far. It has no limit of its own: your balance is on your OpenRouter credits page.';
    } catch (e) {
      _credit = e is ApiError ? e.message : '$e';
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = context.watch<SpendLog>();
    final keys = context.watch<KeyVault>();
    final sub = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final per = s.byProject().take(4).toList();
    return StepCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(fmtMoney(s.thisMonth), style: t.textTheme.headlineSmall?.copyWith(color: t.colorScheme.primary)), Text('this month', style: sub)])),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(fmtMoney(s.total), style: t.textTheme.headlineSmall), Text('since the start', style: sub)])),
        ]),
        if (per.isNotEmpty) ...[
          const SizedBox(height: 12),
          for (final e in per) Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Row(children: [Expanded(child: Text(e.key, maxLines: 1, overflow: TextOverflow.ellipsis)), Text(fmtMoney(e.value), style: t.textTheme.titleSmall)])),
        ] else ...[
          const SizedBox(height: 8),
          Text('Nothing spent yet. Free models cost nothing and are not counted.', style: sub),
        ],
        const SizedBox(height: 10),
        if (_credit.isNotEmpty) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(_credit, style: sub)),
        Wrap(spacing: 8, children: [
          if (keys.has('openrouter')) OutlinedButton(onPressed: _busy ? null : _check, child: Text(_busy ? 'Checking…' : 'Check my OpenRouter credit')),
          OutlinedButton(onPressed: () => Native.openUrl('https://openrouter.ai/settings/credits'), child: const Text('Add credit')),
          if (s.entries.isNotEmpty)
            TextButton(
              onPressed: () async {
                if (await confirmDialog(context, 'Clear the spending history?', body: 'Only this list is cleared. Nothing changes on OpenRouter.', yes: 'Clear')) s.clear();
              },
              child: const Text('Clear'),
            ),
        ]),
        Padding(padding: const EdgeInsets.only(top: 6), child: Text('Amounts are worked out from the token counts the models report, so they can differ a little from your OpenRouter bill.', style: sub)),
      ]),
    );
  }
}

/// App lock (PIN, fingerprint) and the backup file.
class _SecurityCard extends StatefulWidget {
  const _SecurityCard();
  @override
  State<_SecurityCard> createState() => _SecurityCardState();
}

class _SecurityCardState extends State<_SecurityCard> {
  bool _bio = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    Provider.of<LockService>(context, listen: false).biometricAvailable().then((v) {
      if (mounted) setState(() => _bio = v);
    });
  }

  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      final path = await BackupService.export(Provider.of<LocalPrefs>(context, listen: false));
      try {
        final where = await Native.saveToDownloads(path, path.split('/').last);
        if (mounted) snack(context, 'Saved to $where');
      } catch (_) {
        await SharePlus.instance.share(ShareParams(files: [XFile(path)]));
      }
    } catch (e) {
      if (mounted) snack(context, 'Backup failed: ${e is ApiError ? e.message : e}');
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _restore() async {
    final prefs = Provider.of<LocalPrefs>(context, listen: false);
    final chat = Provider.of<ChatStore>(context, listen: false);
    final code = Provider.of<CodeState>(context, listen: false);
    final builder = Provider.of<AppBuilder>(context, listen: false);
    final spend = Provider.of<SpendLog>(context, listen: false);
    try {
      final f = await Native.pickZip();
      if (f == null || !mounted) return;
      if (!await confirmDialog(context, 'Restore this backup?', body: 'Chats, app ideas, history and settings in the backup replace the ones with the same name on this phone. Your keys are not touched.', yes: 'Restore')) return;
      setState(() => _busy = true);
      final n = await BackupService.restore(f.path, prefs);
      await chat.reload();
      await code.reload();
      await builder.reload();
      await spend.load();
      if (mounted) snack(context, 'Restored $n file(s).');
    } catch (e) {
      if (mounted) snack(context, 'Restore failed: ${e is ApiError ? e.message : e}');
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final p = context.watch<LocalPrefs>();
    final lock = Provider.of<LockService>(context, listen: false);
    final sub = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    return StepCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('App lock'),
          subtitle: const Text('Ask for a PIN when AIy is opened again'),
          value: p.lockEnabled,
          onChanged: (v) async {
            if (v) {
              final pin = await askNewPin(context);
              if (pin != null) await lock.enable(pin);
            } else {
              if (await confirmDialog(context, 'Switch the app lock off?', yes: 'Switch off')) await lock.disable();
            }
          },
        ),
        if (p.lockEnabled) ...[
          if (_bio) SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Use the fingerprint too'), value: p.useBiometric, onChanged: p.setUseBiometric),
          Row(children: [
            const Expanded(child: Text('Lock after')),
            DropdownButton<int>(
              value: const [0, 30, 60, 300].contains(p.lockDelaySec) ? p.lockDelaySec : 30,
              items: const [DropdownMenuItem(value: 0, child: Text('at once')), DropdownMenuItem(value: 30, child: Text('30 seconds')), DropdownMenuItem(value: 60, child: Text('1 minute')), DropdownMenuItem(value: 300, child: Text('5 minutes'))],
              onChanged: (v) => p.setLockDelay(v ?? 30),
            ),
          ]),
          TextButton(
            onPressed: () async {
              final pin = await askNewPin(context);
              if (pin != null) await lock.enable(pin);
            },
            child: const Text('Change the PIN'),
          ),
        ],
        const Divider(height: 24),
        Text('Backup', style: t.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text('One file with your chats, app ideas, history and settings. Keys are never in it: connect your accounts again on a new phone.', style: sub),
        const SizedBox(height: 8),
        Wrap(spacing: 8, children: [
          OutlinedButton.icon(onPressed: _busy ? null : _export, icon: const Icon(Icons.upload_rounded, size: 18), label: const Text('Save a backup')),
          OutlinedButton.icon(onPressed: _busy ? null : _restore, icon: const Icon(Icons.download_rounded, size: 18), label: const Text('Restore')),
        ]),
      ]),
    );
  }
}
