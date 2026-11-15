import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart' show ImagePicker, ImageSource;
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../../logic/patcher.dart';
import '../../state/ai.dart';
import '../../state/build_state.dart';
import '../../state/code_state.dart';
import '../../state/github.dart';
import '../../state/keys.dart';
import '../../state/native.dart';
import '../../state/net.dart';
import '../../state/prefs.dart';
import '../../state/share_inbox.dart';
import '../widgets/common.dart';
import '../widgets/fx.dart';
import '../widgets/markdown.dart';
import 'connect_screen.dart';
import 'ask_code_screen.dart';
import 'build_screen.dart';
import 'diff_screen.dart';
import 'publish_panel.dart';
import 'model_picker.dart';
import '../widgets/progress_panel.dart';

/// Programming Mode: project -> request -> files -> model and cost -> patch -> new zip or pull request.
class CodeView extends StatefulWidget {
  const CodeView({super.key});
  @override
  State<CodeView> createState() => _CodeViewState();
}

class _CodeViewState extends State<CodeView> {
  final _req = TextEditingController();
  final _stt = SpeechToText();
  bool _listening = false;
  bool _showExplain = true;
  OrModel? _model;
  bool _loadingModel = false;

  bool _takingShared = false;

  @override
  void initState() {
    super.initState();
    _req.text = context.read<CodeState>().request;
    _restoreModel();
  }

  /// What another app shared into AIy, sent to Code: a zip opens as the project, a picture becomes the
  /// "photo of the problem", and text goes into the request box.
  Future<void> _takeShared(SharedItem it) async {
    final code = context.read<CodeState>();
    final zips = it.files.where((f) => f.isZip).toList();
    if (zips.isNotEmpty) {
      await code.openShared(zips.first);
      if (mounted && it.fullText.isNotEmpty) _req.text = it.fullText;
      return;
    }
    final pics = it.files.where((f) => f.isImage).toList();
    if (pics.isNotEmpty && code.hasSource) await code.attachShot(pics.first.path);
    if (it.fullText.isNotEmpty && mounted) {
      final cur = _req.text.trim();
      _req.text = cur.isEmpty ? it.fullText : '$cur\n${it.fullText}';
      code.request = _req.text;
    }
    if (mounted && pics.isNotEmpty && !code.hasSource) snack(context, 'Open a project first, then share the picture again.');
  }

  @override
  void dispose() {
    _stt.stop();
    _req.dispose();
    super.dispose();
  }

  /// The model chosen last time, with today's price.
  Future<void> _restoreModel() async {
    final id = context.read<LocalPrefs>().codeModel;
    if (id.isEmpty) return;
    _loadingModel = true;
    try {
      final all = await context.read<AiEngine>().orModels();
      final m = all.where((m) => m.id == id).toList();
      if (mounted && m.isNotEmpty) setState(() => _model = m.first);
    } catch (_) {
    } finally {
      if (mounted) setState(() => _loadingModel = false);
    }
  }

  Future<void> _chooseModel() async {
    final m = await Navigator.push<OrModel>(context, MaterialPageRoute(builder: (_) => ModelPicker(selected: _model?.id ?? '')));
    if (m == null || !mounted) return;
    setState(() => _model = m);
    context.read<LocalPrefs>().setCodeModel(m.id);
  }

  Future<void> _mic() async {
    if (_listening) {
      await _stt.stop();
      if (mounted) setState(() => _listening = false);
      return;
    }
    try {
      final ok = await _stt.initialize(
        onError: (e) {
          if (mounted) setState(() => _listening = false);
        },
        onStatus: (s) {
          if ((s == 'done' || s == 'notListening') && mounted) setState(() => _listening = false);
        },
      );
      if (!ok) {
        if (mounted) snack(context, 'Voice typing is not available on this phone.');
        return;
      }
      final base = _req.text.trim();
      if (mounted) setState(() => _listening = true);
      await _stt.listen(onResult: (r) {
        if (!mounted) return;
        final v = base.isEmpty ? r.recognizedWords : '$base ${r.recognizedWords}';
        _req.value = TextEditingValue(text: v, selection: TextSelection.collapsed(offset: v.length));
      });
    } catch (e) {
      if (mounted) setState(() => _listening = false);
    }
  }

  Future<void> _github(CodeState code) async {
    final keys = context.read<KeyVault>();
    if (!keys.has('github')) {
      if (await confirmDialog(context, 'Connect GitHub first', body: 'To open a repository, connect your GitHub account in Accounts & keys.', yes: 'Open')) {
        if (mounted) Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const ConnectScreen()));
      }
      return;
    }
    final pick = await showModalBottomSheet<(String, String)>(context: context, isScrollControlled: true, useSafeArea: true, builder: (_) => _RepoSheet(token: keys.get('github')));
    if (pick != null) await code.loadGitHub(pick.$1, pick.$2);
  }

  Future<void> _addFile(CodeState code) async {
    final path = await showModalBottomSheet<String>(context: context, isScrollControlled: true, useSafeArea: true, builder: (_) => _FileSheet(paths: code.texts.keys.where((p) => !code.targets.contains(p)).toList()..sort()));
    if (path != null) code.addTarget(path);
  }

  Future<void> _patch(CodeState code) async {
    final m = _model;
    if (m == null) return;
    final est = code.estimate(m);
    final cap = context.read<LocalPrefs>().capUsd;
    final ok = await showModalBottomSheet<bool>(
      context: context,
      builder: (c) {
        final t = Theme.of(c);
        Widget row(String a, String b) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(children: [Expanded(child: Text(a, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant))), Text(b, style: t.textTheme.titleSmall)]),
            );
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Before we send', style: t.textTheme.titleLarge),
              const SizedBox(height: 12),
              row('Model', m.name),
              row('Files sent', '${code.targets.where((p) => !code.isNewFile(p)).length} (only these, not the whole project)'),
              row('Size', 'about ${est.inTokens} tokens'),
              row('Estimated cost', m.free ? 'Free' : fmtMoney(est.cost)),
              if (!m.free) row('It can never cost more than', fmtMoney(est.worstCase)),
              if (!m.free) row('Your limit per request', '\$${cap.toStringAsFixed(2)}'),
              const SizedBox(height: 6),
              Text(
                est.blocked ?? 'If the result has an error, AIy sends ONE automatic fix request to the same model (same limit).${m.free ? ' Free models can be slow or busy; if it fails, try another one.' : ''}',
                style: t.textTheme.bodySmall?.copyWith(color: est.blocked != null ? t.colorScheme.error : t.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              Row(children: [
                Expanded(child: OutlinedButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel'))),
                const SizedBox(width: 12),
                Expanded(child: FilledButton(style: FilledButton.styleFrom(minimumSize: const Size(64, 48)), onPressed: est.blocked != null ? null : () => Navigator.pop(c, true), child: const Text('Send'))),
              ]),
            ]),
          ),
        );
      },
    );
    if (ok == true) await code.patch(m);
  }

  Future<void> _save(CodeState code) async {
    final name = code.zipNameFor(code.sourceName, code.history.isEmpty ? '0' : code.history.first.id);
    try {
      final where = await code.saveToDownloads(code.outZip, name);
      if (mounted) snack(context, 'Saved to $where');
    } catch (e) {
      // Older Android: hand the file to the share sheet instead.
      await SharePlus.instance.share(ShareParams(files: [XFile(code.outZip)], text: name));
    }
  }

  @override
  Widget build(BuildContext context) {
    final inbox = context.watch<ShareInbox>();
    if (inbox.hasForCode && !_takingShared) {
      _takingShared = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _takingShared = false;
        final it = inbox.takeCode();
        if (it != null && mounted) _takeShared(it);
      });
    }
    final code = context.watch<CodeState>();
    final build = context.watch<BuildState>();
    final t = Theme.of(context);
    final bottom = MediaQuery.of(context).padding.bottom;
    return Stack(children: [
      ListView(
        padding: EdgeInsets.fromLTRB(16, 8, 16, 96 + bottom),
        children: [
          if (code.error != null) ...[Appear(dy: 8, child: ErrorBox(code.error!, onClose: code.clearError)), const SizedBox(height: 12)],
          if (build.running || build.phase == 'done' || build.phase == 'failed') ...[Appear(dy: 8, child: _buildBanner(build, t)), const SizedBox(height: 12)],
          if (!code.hasSource) _start(code, t) else ..._steps(code, build, t),
        ],
      ),
      // What AIy is doing right now.
      Positioned(
        left: 16,
        right: 16,
        bottom: 16 + bottom,
        child: IgnorePointer(
          ignoring: !code.isBusy,
          child: AnimatedSlide(
            offset: code.isBusy ? Offset.zero : const Offset(0, 1.6),
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeOutCubic,
            child: AnimatedOpacity(
              opacity: code.isBusy ? 1 : 0,
              duration: const Duration(milliseconds: 220),
              child: Builder(builder: (_) {
                final pr = codeProgress(code.busy);
                return ProgressPanel(icon: Icons.code_rounded, title: 'Code', steps: pr.steps, at: pr.at, live: code.busy);
              }),
            ),
          ),
        ),
      ),
    ]);
  }

  Widget _start(CodeState code, ThemeData t) {
    Widget big(IconData icon, String title, String sub, VoidCallback onTap, int delay) => Appear(
          delay: delay,
          child: Pressable(
            onTap: code.isBusy ? null : onTap,
            child: StepCard(
              child: Row(children: [
                CircleAvatar(radius: 24, backgroundColor: t.colorScheme.primary.withValues(alpha: 0.14), child: Icon(icon, color: t.colorScheme.primary)),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, style: t.textTheme.titleMedium),
                    Text(sub, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                  ]),
                ),
                const Icon(Icons.chevron_right_rounded),
              ]),
            ),
          ),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 24),
      const Appear(child: Center(child: Orb(size: 76))),
      const SizedBox(height: 18),
      Appear(delay: 80, child: Center(child: Text('Change a project\nby describing it', textAlign: TextAlign.center, style: t.textTheme.headlineMedium?.copyWith(height: 1.15)))),
      const SizedBox(height: 10),
      Appear(
        delay: 140,
        child: Center(
          child: Text('Give AIy a project. Say what should change. Get the project back with the change made.',
              textAlign: TextAlign.center, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        ),
      ),
      const SizedBox(height: 28),
      big(Icons.folder_zip_outlined, 'Upload a project zip', 'Up to 100 MB. Heavy folders are skipped automatically.', code.pickZip, 200),
      const SizedBox(height: 12),
      big(Icons.code_rounded, 'Open a GitHub repository', 'Pick a repository and a branch.', () => _github(code), 280),
      // Quick way back into the last projects AIy changed.
      if (code.history.any((h) => File(h.zip).existsSync())) ...[
        Padding(padding: const EdgeInsets.fromLTRB(4, 26, 4, 8), child: Text('Continue where you left off', style: t.textTheme.titleSmall?.copyWith(color: t.colorScheme.primary))),
        for (final (i, h) in code.history.where((h) => File(h.zip).existsSync()).take(3).indexed)
          Appear(
            delay: 340 + i * 60,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Pressable(
                onTap: code.isBusy ? null : () => code.openBuild(h),
                child: StepCard(
                  padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
                  child: Row(children: [
                    Icon(h.repo.isEmpty ? Icons.folder_zip_outlined : Icons.code_rounded, size: 20, color: t.colorScheme.onSurfaceVariant),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(h.source, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.titleSmall),
                        Text('${h.request.split('\n').first} · ${fmtDate(h.date)}', maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                      ]),
                    ),
                    const Icon(Icons.chevron_right_rounded),
                  ]),
                ),
              ),
            ),
          ),
      ],
    ]);
  }

  List<Widget> _steps(CodeState code, BuildState build, ThemeData t) {
    final sub = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    Widget title(String n, String text) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(children: [
            CircleAvatar(radius: 12, backgroundColor: t.colorScheme.primary, child: Text(n, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: t.colorScheme.onPrimary))),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: t.textTheme.titleMedium)),
          ]),
        );
    final est = _model == null || code.targets.isEmpty ? null : code.estimate(_model!);
    return [
      // ---- the project
      Appear(
        child: StepCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(code.repo.isEmpty ? Icons.folder_zip_outlined : Icons.code_rounded, color: t.colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(child: Text(code.sourceName, style: t.textTheme.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis)),
              IconButton(
                tooltip: 'Close project',
                icon: const Icon(Icons.close_rounded),
                onPressed: code.isBusy
                    ? null
                    : () {
                        _req.clear();
                        code.closeProject();
                      },
              ),
            ]),
            Text('${code.allCount} files, ${fmtBytes(code.allBytes)} in the project', style: sub),
            Text('${code.texts.length} source files, ${fmtBytes(code.srcBytes)} read by AIy (the rest stays untouched in the zip)', style: sub),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(onPressed: code.isBusy ? null : code.explain, icon: const Icon(Icons.auto_awesome_rounded, size: 18), label: Text(code.explanation.isEmpty ? 'Explain this codebase' : 'Explain again')),
              OutlinedButton.icon(onPressed: code.isBusy ? null : () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const AskCodeScreen())), icon: const Icon(Icons.chat_bubble_outline_rounded, size: 18), label: const Text('Ask about it')),
            ]),
            if (code.explanation.isNotEmpty || code.explainLive.isNotEmpty) ...[
              const SizedBox(height: 6),
              InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => setState(() => _showExplain = !_showExplain),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(children: [
                    Expanded(child: Text('How this project works', style: t.textTheme.titleSmall)),
                    AnimatedRotation(turns: _showExplain ? 0.5 : 0, duration: const Duration(milliseconds: 220), child: const Icon(Icons.expand_more_rounded)),
                  ]),
                ),
              ),
              if (_showExplain) ...[SelectionArea(child: MdText(code.explainLive.isNotEmpty ? code.explainLive : code.explanation)), if (code.explainLive.isEmpty) ModelBadge(code.explainBadge)],
            ],
          ]),
        ),
      ),
      const SizedBox(height: 14),
      // ---- the request
      Appear(
        delay: 80,
        child: StepCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            title('1', 'What should change?'),
            TextField(
              controller: _req,
              minLines: 3,
              maxLines: 8,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                hintText: _listening ? 'Listening…' : 'For example: add a dark mode switch to the settings page',
                suffixIcon: IconButton(tooltip: 'Speak', icon: Icon(_listening ? Icons.stop_circle_outlined : Icons.mic_none_rounded), onPressed: _mic),
              ),
            ),
            _shotRow(code, t),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonal(
                onPressed: code.isBusy
                    ? null
                    : () {
                        if (_req.text.trim().isEmpty) {
                          snack(context, 'Describe the change first.');
                          return;
                        }
                        FocusScope.of(context).unfocus();
                        code.route(_req.text);
                      },
                child: Text(code.targets.isEmpty ? 'Find the files' : 'Find the files again'),
              ),
            ),
            Padding(padding: const EdgeInsets.only(top: 6), child: Text('Free: AIy reads the project map and picks the files that need to change.', style: sub)),
          ]),
        ),
      ),
      if (code.targets.isNotEmpty) ...[
        const SizedBox(height: 14),
        // ---- files + model
        Appear(
          child: StepCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              title('2', 'Files to change'),
              for (final p in code.targets)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Row(children: [
                    Icon(code.isNewFile(p) ? Icons.note_add_outlined : Icons.description_outlined, size: 18, color: t.colorScheme.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Expanded(child: Text(p, style: const TextStyle(fontFamily: 'monospace', fontSize: 13))),
                    if (code.isNewFile(p)) Padding(padding: const EdgeInsets.only(right: 4), child: Text('new', style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.primary))),
                    IconButton(tooltip: 'Leave this file out', visualDensity: VisualDensity.compact, icon: const Icon(Icons.close_rounded, size: 16), onPressed: code.isBusy ? null : () => code.removeTarget(p)),
                  ]),
                ),
              Row(children: [
                TextButton.icon(onPressed: code.isBusy ? null : () => _addFile(code), icon: const Icon(Icons.add_rounded, size: 18), label: const Text('Add a file')),
                const Spacer(),
                if (code.routeBadge.isNotEmpty) Flexible(child: ModelBadge(code.routeBadge)),
              ]),
              const Divider(height: 24),
              title('3', 'Who writes the change?'),
              Pressable(
                onTap: code.isBusy ? null : _chooseModel,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
                  decoration: BoxDecoration(color: t.colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(16)),
                  child: Row(children: [
                    Expanded(
                      child: _model == null
                          ? Text(_loadingModel ? 'Loading…' : 'Choose a model', style: t.textTheme.titleSmall)
                          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(_model!.name, style: t.textTheme.titleSmall),
                              Text(_model!.priceLabel, style: sub),
                            ]),
                    ),
                    const Icon(Icons.unfold_more_rounded),
                  ]),
                ),
              ),
              if (est != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(est.blocked ?? 'About ${est.inTokens} tokens to send. Estimated cost: ${fmtMoney(est.cost)}.', style: sub?.copyWith(color: est.blocked != null ? t.colorScheme.error : null)),
                ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: code.isBusy || _model == null ? null : () => _patch(code),
                  icon: const Icon(Icons.auto_fix_high_rounded, size: 20),
                  label: const Text('Write the change'),
                ),
              ),
            ]),
          ),
        ),
      ],
      if (code.hasResult) ...[
        const SizedBox(height: 14),
        // ---- result
        Appear(
          child: StepCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(code.warnings == 0 ? Icons.check_circle_rounded : Icons.warning_amber_rounded, color: code.warnings == 0 ? const Color(0xFF34C759) : t.colorScheme.error),
                const SizedBox(width: 10),
                Expanded(child: Text(code.warnings == 0 ? 'Done' : 'Done, with ${code.warnings} file(s) to check', style: t.textTheme.titleMedium)),
              ]),
              const SizedBox(height: 4),
              Text('${code.usedModel} · ${fmtMoney(code.spent)}${code.healed ? ' · one automatic fix round' : ''}', style: sub),
              const SizedBox(height: 12),
              SelectionArea(child: MdText(code.summary)),
              if (code.warnings > 0)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: ErrorBox('Some edits could not be applied cleanly, or a file may have a syntax problem. Open the marked files below to see what happened. You can run the change again with another model.'),
                ),
              Text('Changed files', style: t.textTheme.titleSmall),
              const SizedBox(height: 4),
              for (final c in code.changes) _changeRow(c, t),
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: [
                FilledButton.icon(style: FilledButton.styleFrom(minimumSize: const Size(64, 46)), onPressed: () => _save(code), icon: const Icon(Icons.download_rounded, size: 18), label: const Text('Save the new zip')),
                OutlinedButton.icon(onPressed: () => SharePlus.instance.share(ShareParams(files: [XFile(code.outZip)])), icon: const Icon(Icons.ios_share_rounded, size: 18), label: const Text('Share')),
                if (code.history.isNotEmpty)
                  TextButton(
                    onPressed: code.isBusy
                        ? null
                        : () {
                            _req.clear();
                            code.openBuild(code.history.first);
                          },
                    child: const Text('Make another change on top of this'),
                  ),
              ]),
              Padding(padding: const EdgeInsets.only(top: 8), child: Text('The new zip is the complete project: your original folders plus the changed files. It is also kept in Build history.', style: sub)),
              const Divider(height: 28),
              const PublishPanel(),
            ]),
          ),
        ),
      ],
    ];
  }

  Widget _buildBanner(BuildState b, ThemeData t) {
    final done = b.phase == 'done';
    return StepCard(
      color: t.colorScheme.primary.withValues(alpha: 0.14),
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const BuildScreen())),
        child: Row(children: [
          if (b.running) const Orb(size: 30, busy: true) else Icon(done ? Icons.check_circle_rounded : Icons.error_rounded, color: done ? const Color(0xFF34C759) : t.colorScheme.error),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(b.running ? 'Building version ${b.version}' : (done ? 'Version ${b.version} is ready' : 'The build failed'), style: t.textTheme.titleSmall),
              if (b.status.isNotEmpty) Text(b.status, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            ]),
          ),
          if (!b.running && !done) IconButton(tooltip: 'Dismiss', icon: const Icon(Icons.close_rounded, size: 18), onPressed: b.dismiss),
          const Icon(Icons.chevron_right_rounded),
        ]),
      ),
    );
  }

  Future<void> _pickShot(CodeState code, ImageSource src) async {
    try {
      final f = await ImagePicker().pickImage(source: src, maxWidth: 1400, maxHeight: 1400, imageQuality: 80);
      if (f != null) await code.attachShot(f.path);
    } catch (e) {
      if (mounted) snack(context, 'Could not get the photo ($e)');
    }
  }

  /// A photo of the problem: described once by a vision model, then sent along as words to any model.
  Widget _shotRow(CodeState code, ThemeData t) {
    final sub = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    if (code.shotPath.isEmpty) {
      return Align(
        alignment: Alignment.centerLeft,
        child: PopupMenuButton<ImageSource>(
          tooltip: 'Add a photo of the problem',
          onSelected: (s) => _pickShot(code, s),
          itemBuilder: (_) => const [PopupMenuItem(value: ImageSource.gallery, child: Text('Choose a screenshot')), PopupMenuItem(value: ImageSource.camera, child: Text('Take a photo'))],
          child: Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.add_photo_alternate_outlined, size: 20, color: t.colorScheme.primary), const SizedBox(width: 8), Text('Add a photo of the problem', style: TextStyle(color: t.colorScheme.primary, fontWeight: FontWeight.w600))])),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.file(File(code.shotPath), width: 56, height: 56, fit: BoxFit.cover)),
        const SizedBox(width: 12),
        Expanded(
          child: code.shotBusy
              ? Row(children: [const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)), const SizedBox(width: 8), Text('Looking at the photo…', style: sub)])
              : Text(code.shotNote.isEmpty ? 'The photo could not be read.' : 'The AI looked at it and wrote down what it sees. That goes with your request:\n${code.shotNote.length > 220 ? '${code.shotNote.substring(0, 220)}…' : code.shotNote}', style: sub),
        ),
        IconButton(tooltip: 'Remove the photo', visualDensity: VisualDensity.compact, icon: const Icon(Icons.close_rounded, size: 18), onPressed: code.removeShot),
      ]),
    );
  }

  Widget _changeRow(FileChange c, ThemeData t) {
    final d = diffStats(diffLines(c.before ?? '', c.after));
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => DiffScreen(change: c))),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          Icon(c.ok ? (c.isNew ? Icons.note_add_outlined : Icons.description_outlined) : Icons.warning_amber_rounded, size: 18, color: c.ok ? t.colorScheme.onSurfaceVariant : t.colorScheme.error),
          const SizedBox(width: 8),
          Expanded(child: Text(c.path, style: const TextStyle(fontFamily: 'monospace', fontSize: 13))),
          Text('+${d.added}', style: const TextStyle(color: Color(0xFF34C759), fontWeight: FontWeight.w700, fontSize: 13)),
          const SizedBox(width: 6),
          Text('−${d.removed}', style: TextStyle(color: t.colorScheme.error, fontWeight: FontWeight.w700, fontSize: 13)),
          const Icon(Icons.chevron_right_rounded, size: 20),
        ]),
      ),
    );
  }
}

/// Pick a repository, then one of its branches.
class _RepoSheet extends StatefulWidget {
  final String token;
  const _RepoSheet({required this.token});
  @override
  State<_RepoSheet> createState() => _RepoSheetState();
}

class _RepoSheetState extends State<_RepoSheet> {
  late final GitHubApi _api = GitHubApi(widget.token);
  List<GhRepo>? _repos;
  GhRepo? _repo;
  List<String>? _branches;
  String? _error;
  String _q = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await _api.repos();
      if (mounted) setState(() => _repos = r);
    } catch (e) {
      if (mounted) setState(() => _error = e is ApiError ? e.message : '$e');
    }
  }

  Future<void> _pickRepo(GhRepo r) async {
    setState(() {
      _repo = r;
      _branches = null;
    });
    try {
      final b = await _api.branches(r.full);
      b.sort((x, y) => x == r.defaultBranch ? -1 : (y == r.defaultBranch ? 1 : x.compareTo(y)));
      if (mounted) setState(() => _branches = b);
    } catch (e) {
      if (mounted) setState(() => _error = e is ApiError ? e.message : '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    Widget body;
    if (_error != null) {
      body = Padding(padding: const EdgeInsets.all(20), child: ErrorBox(_error!));
    } else if (_repo != null) {
      final b = _branches;
      body = b == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(children: [
              for (final name in b)
                ListTile(
                  leading: const Icon(Icons.alt_route_rounded),
                  title: Text(name),
                  subtitle: name == _repo!.defaultBranch ? const Text('main branch') : null,
                  onTap: () => Navigator.pop(context, (_repo!.full, name)),
                ),
            ]);
    } else {
      final all = _repos;
      final list = all?.where((r) => r.full.toLowerCase().contains(_q.toLowerCase())).toList();
      body = list == null
          ? const Center(child: CircularProgressIndicator())
          : list.isEmpty
              ? const Center(child: Text('No repositories found.'))
              : ListView.builder(
                  itemCount: list.length,
                  itemBuilder: (_, i) => ListTile(
                    leading: Icon(list[i].private ? Icons.lock_outline_rounded : Icons.public_rounded),
                    title: Text(list[i].full),
                    onTap: () => _pickRepo(list[i]),
                  ),
                );
    }
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.8,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
          child: Row(children: [
            if (_repo != null) IconButton(icon: const Icon(Icons.arrow_back_rounded), onPressed: () => setState(() => _repo = null)),
            Expanded(child: Text(_repo == null ? 'Choose a repository' : 'Choose a branch of ${_repo!.full}', style: t.textTheme.titleMedium)),
          ]),
        ),
        if (_repo == null && _error == null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(onChanged: (v) => setState(() => _q = v), decoration: const InputDecoration(isDense: true, hintText: 'Search', prefixIcon: Icon(Icons.search_rounded, size: 20))),
          ),
        Expanded(child: body),
      ]),
    );
  }
}

/// Search the project's source files to add one to the change by hand.
class _FileSheet extends StatefulWidget {
  final List<String> paths;
  const _FileSheet({required this.paths});
  @override
  State<_FileSheet> createState() => _FileSheetState();
}

class _FileSheetState extends State<_FileSheet> {
  String _q = '';
  @override
  Widget build(BuildContext context) {
    final list = _q.isEmpty ? widget.paths : widget.paths.where((p) => p.toLowerCase().contains(_q.toLowerCase())).toList();
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.8,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(autofocus: true, onChanged: (v) => setState(() => _q = v), decoration: const InputDecoration(isDense: true, hintText: 'Search files', prefixIcon: Icon(Icons.search_rounded, size: 20))),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: list.length,
            itemBuilder: (_, i) => ListTile(dense: true, title: Text(list[i], style: const TextStyle(fontFamily: 'monospace', fontSize: 13)), onTap: () => Navigator.pop(context, list[i])),
          ),
        ),
      ]),
    );
  }
}
