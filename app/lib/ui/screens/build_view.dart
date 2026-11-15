import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../../logic/brief.dart';
import '../../logic/starters.dart';
import '../../state/ai.dart';
import '../../state/app_builder.dart';
import '../../state/code_state.dart';
import '../../state/prefs.dart';
import '../../state/share_inbox.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/fx.dart';
import '../widgets/markdown.dart';
import '../widgets/icon_maker.dart';
import '../widgets/timeline.dart';
import 'diff_screen.dart';
import 'model_picker.dart';
import 'publish_panel.dart';
import '../../state/app_log.dart';
import '../widgets/progress_panel.dart';

const _stages = ['describe', 'setup', 'questions', 'brief', 'write', 'done'];
const _stageNames = ['Idea', 'Look', 'Questions', 'Brief', 'Write', 'Done'];

/// How far the project is (0..1) for the small bar in the list.
double _stageProgress(AppProject p) {
  switch (p.stage) {
    case 'describe':
      return 0.1;
    case 'setup':
      return 0.25;
    case 'questions':
      return 0.3 + 0.35 * (p.count == 0 ? 0 : p.qa.where((q) => q.answer.isNotEmpty).length / p.count).clamp(0.0, 1.0);
    case 'brief':
      return 0.7;
    case 'write':
      return 0.85;
    default:
      return 1;
  }
}

String _stageLabel(AppProject p) {
  switch (p.stage) {
    case 'describe':
      return 'Describing the idea';
    case 'setup':
      return 'Choosing the look';
    case 'questions':
      return 'Questions ${p.qa.where((q) => q.answer.isNotEmpty).length} of ${p.count}';
    case 'brief':
      return 'Brief ready to check';
    case 'write':
      return 'Ready to write';
    default:
      return 'Written';
  }
}

/// The Build tab: start from an idea, answer a few questions, get a working Flutter app.
class BuildView extends StatefulWidget {
  final VoidCallback onOpenCode;
  const BuildView({super.key, required this.onOpenCode});
  @override
  State<BuildView> createState() => _BuildViewState();
}

class _BuildViewState extends State<BuildView> {
  final _idea = TextEditingController();
  final _name = TextEditingController();
  final _answer = TextEditingController();
  final _brief = TextEditingController();
  final _stt = SpeechToText();
  String _listening = '';
  String _loaded = '';
  String _answerKey = '';
  String _briefSrc = '';
  final List<String> _removed = [];
  double _count = 6;
  String _icon = 'letter';
  int _preset = 0;
  String _mode = 'dark';
  OrModel? _model;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _restoreModel();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _stt.stop();
    _idea.dispose();
    _name.dispose();
    _answer.dispose();
    _brief.dispose();
    super.dispose();
  }

  Future<void> _restoreModel() async {
    final id = context.read<LocalPrefs>().codeModel;
    if (id.isEmpty) return;
    try {
      final all = await context.read<AiEngine>().orModels();
      final m = all.where((m) => m.id == id).toList();
      if (mounted && m.isNotEmpty) setState(() => _model = m.first);
    } catch (e) {
      AppLog.i('build_view:95: $e');
    }
  }

  void _sync(AppProject p) {
    _loaded = p.id;
    _idea.text = p.idea;
    _name.text = p.name;
    _brief.text = p.brief;
    _briefSrc = p.brief;
    _removed.clear();
    _count = p.count.toDouble();
    _icon = p.icon;
    _preset = p.preset;
    _mode = p.mode;
    _answerKey = '';
  }

  void _later(AppBuilder b) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 700), b.save);
  }

  Future<void> _mic(TextEditingController c, String who) async {
    if (_listening == who) {
      await _stt.stop();
      if (mounted) setState(() => _listening = '');
      return;
    }
    try {
      final ok = await _stt.initialize(
        onError: (e) {
          if (mounted) setState(() => _listening = '');
        },
        onStatus: (s) {
          if ((s == 'done' || s == 'notListening') && mounted) setState(() => _listening = '');
        },
      );
      if (!ok) {
        if (mounted) snack(context, 'Voice typing is not available on this phone.');
        return;
      }
      final base = c.text.trim();
      if (mounted) setState(() => _listening = who);
      await _stt.listen(onResult: (r) {
        if (!mounted) return;
        final v = base.isEmpty ? r.recognizedWords : '$base ${r.recognizedWords}';
        c.value = TextEditingValue(text: v, selection: TextSelection.collapsed(offset: v.length));
        final bld = context.read<AppBuilder>();
        if (who == 'idea') bld.current?.idea = v;
        setState(() {});
      });
    } catch (e) {
      if (mounted) setState(() => _listening = '');
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = context.watch<AppBuilder>();
    final inbox = context.watch<ShareInbox>();
    if (inbox.hasForBuild) {
      // Text shared from another app becomes the description of a new app.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final it = inbox.takeBuild();
        if (it == null || !mounted) return;
        final bb = context.read<AppBuilder>();
        if (bb.isBusy) {
          snack(context, 'AIy is busy with an app. Share it again in a moment.');
          return;
        }
        bb.newProject();
        bb.current?.idea = it.fullText;
        bb.save();
        setState(() => _loaded = '');
      });
    }
    final p = b.current;
    if (p == null) return _list(b);
    if (_loaded != p.id) _sync(p);
    final t = Theme.of(context);
    final showPill = b.isBusy && (p.stage == 'write' || p.stage == 'setup');
    return Stack(children: [
      Column(children: [
        _header(b, p, t),
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 280),
            switchInCurve: Curves.easeOutCubic,
            transitionBuilder: (c, a) => FadeTransition(opacity: a, child: SlideTransition(position: Tween(begin: const Offset(0.03, 0), end: Offset.zero).animate(a), child: c)),
            child: KeyedSubtree(key: ValueKey(p.stage), child: _stage(b, p, t)),
          ),
        ),
      ]),
      Positioned(
        left: 16,
        right: 16,
        bottom: 16 + MediaQuery.of(context).padding.bottom,
        child: IgnorePointer(
          child: AnimatedSlide(
            offset: showPill ? Offset.zero : const Offset(0, 1.6),
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeOutCubic,
            child: AnimatedOpacity(
              opacity: showPill ? 1 : 0,
              duration: const Duration(milliseconds: 220),
              child: Builder(builder: (_) {
                final pr = appProgress(b.phase, b.busy);
                return ProgressPanel(icon: Icons.auto_awesome_outlined, title: b.phase.isEmpty ? 'Working' : 'Writing ${p.title}', steps: pr.steps, at: pr.at, live: b.busy);
              }),
            ),
          ),
        ),
      ),
    ]);
  }

  Widget _stage(AppBuilder b, AppProject p, ThemeData t) {
    switch (p.stage) {
      case 'describe':
        return _describe(b, p, t);
      case 'setup':
        return _setup(b, p, t);
      case 'questions':
        return _questions(b, p, t);
      case 'brief':
        return _briefStage(b, p, t);
      case 'write':
        return _write(b, p, t);
      default:
        return _done(b, p, t);
    }
  }

  // ------------------------------------------------------------------ the list of ideas
  Widget _list(AppBuilder b) {
    final t = Theme.of(context);
    final sub = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 40), children: [
      const SizedBox(height: 12),
      const Appear(child: Center(child: Orb(size: 72))),
      const SizedBox(height: 16),
      Appear(delay: 80, child: Center(child: Text('Build an app\nfrom an idea', textAlign: TextAlign.center, style: t.textTheme.headlineMedium?.copyWith(height: 1.15)))),
      const SizedBox(height: 8),
      Appear(delay: 140, child: Center(child: Text('Explain it, answer a few questions, and get a working app.', textAlign: TextAlign.center, style: sub))),
      const SizedBox(height: 22),
      Appear(
        delay: 200,
        child: Pressable(
          onTap: b.newProject,
          child: Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(28),
              gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [t.colorScheme.primary, Color.lerp(t.colorScheme.primary, t.colorScheme.tertiary, 0.6)!]),
              boxShadow: [BoxShadow(color: t.colorScheme.primary.withValues(alpha: 0.3), blurRadius: 24, offset: const Offset(0, 8))],
            ),
            child: Row(children: [
              CircleAvatar(radius: 24, backgroundColor: t.colorScheme.onPrimary.withValues(alpha: 0.18), child: Icon(Icons.auto_awesome_rounded, color: t.colorScheme.onPrimary)),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Start a new app', style: t.textTheme.titleMedium?.copyWith(color: t.colorScheme.onPrimary)),
                  Text('Describe it in your own words', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onPrimary.withValues(alpha: 0.8))),
                ]),
              ),
              Icon(Icons.arrow_forward_rounded, color: t.colorScheme.onPrimary),
            ]),
          ),
        ),
      ),
      if (b.projects.isNotEmpty) ...[
        Padding(padding: const EdgeInsets.fromLTRB(4, 24, 4, 8), child: Text('Your apps and ideas', style: t.textTheme.titleSmall?.copyWith(color: t.colorScheme.primary))),
        for (var i = 0; i < b.projects.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Appear(
              delay: 260 + i * 50,
              child: Pressable(
                onTap: () => b.open(b.projects[i]),
                child: StepCard(
                  padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
                  child: Row(children: [
                    IconPreview(style: b.projects[i].icon, letter: b.projects[i].title, colors: presetAt(b.projects[i].preset).glow, size: 48),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(b.projects[i].title, style: t.textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                        Text('${_stageLabel(b.projects[i])} · ${fmtDate(b.projects[i].updated)}', style: sub, maxLines: 1, overflow: TextOverflow.ellipsis),
                        const SizedBox(height: 8),
                        TweenAnimationBuilder<double>(
                          tween: Tween(begin: 0, end: _stageProgress(b.projects[i])),
                          duration: Duration(milliseconds: 700 + i * 60),
                          curve: Curves.easeOutCubic,
                          builder: (_, v, _) => ClipRRect(
                            borderRadius: BorderRadius.circular(99),
                            child: LinearProgressIndicator(
                              value: v,
                              minHeight: 4,
                              backgroundColor: t.colorScheme.surfaceContainerHighest,
                              color: v >= 1 ? const Color(0xFF34C759) : t.colorScheme.primary,
                            ),
                          ),
                        ),
                      ]),
                    ),
                    IconButton(
                      tooltip: 'Delete',
                      icon: const Icon(Icons.delete_outline_rounded, size: 20),
                      onPressed: () async {
                        if (await confirmDialog(context, 'Delete "${b.projects[i].title}"?', body: 'The idea and the written app are removed from this phone.', yes: 'Delete')) b.delete(b.projects[i]);
                      },
                    ),
                  ]),
                ),
              ),
            ),
          ),
      ],
    ]);
  }

  // ------------------------------------------------------------------ header with the steps
  Widget _header(AppBuilder b, AppProject p, ThemeData t) {
    final idx = _stages.indexOf(p.stage).clamp(0, 5);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 16, 6),
      child: Column(children: [
        Row(children: [
          IconButton(tooltip: 'Back to my apps', icon: const Icon(Icons.arrow_back_rounded), onPressed: b.isBusy ? null : b.closeProject),
          Expanded(child: Text(p.title, style: t.textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis)),
          Text(_stageNames[idx], style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.primary)),
        ]),
        Padding(
          padding: const EdgeInsets.only(left: 8),
          child: Row(children: [
            for (var i = 0; i < _stages.length; i++)
              Expanded(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  height: 4,
                  margin: const EdgeInsets.only(right: 5),
                  decoration: BoxDecoration(color: i <= idx ? t.colorScheme.primary : t.colorScheme.outlineVariant.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(4)),
                ),
              ),
          ]),
        ),
      ]),
    );
  }

  // ------------------------------------------------------------------ 1. the idea
  Widget _describe(AppBuilder b, AppProject p, ThemeData t) {
    final sub = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final n = _count.round();
    final hint = n <= 3 ? 'Quick start: I will make most choices myself.' : (n <= 10 ? 'A good balance for a first version.' : 'Detailed: a better first version, but it takes longer.');
    final ok = _idea.text.trim().length >= 12;
    return ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 40), children: [
      Appear(
        child: StepCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Explain your app', style: t.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text('Say what it is for, who uses it and what it should do. Simple words are fine, in any language.', style: sub),
            const SizedBox(height: 12),
            TextField(
              controller: _idea,
              minLines: 6,
              maxLines: 14,
              textCapitalization: TextCapitalization.sentences,
              onChanged: (v) {
                p.idea = v;
                _later(b);
                setState(() {});
              },
              decoration: InputDecoration(
                hintText: _listening == 'idea' ? 'Listening…' : 'For example: an app where my family adds what we spent each day and sees a monthly total.',
                suffixIcon: IconButton(tooltip: 'Speak', icon: Icon(_listening == 'idea' ? Icons.stop_circle_outlined : Icons.mic_none_rounded), onPressed: () => _mic(_idea, 'idea')),
              ),
            ),
            if (_idea.text.trim().isEmpty) ...[
              const SizedBox(height: 10),
              Text('Or start from a ready idea', style: sub),
              const SizedBox(height: 6),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final s in kStarters)
                  ActionChip(
                    avatar: const Icon(Icons.bolt_rounded, size: 16),
                    label: Text(s.title),
                    onPressed: () => setState(() {
                      _idea.text = s.idea;
                      p.idea = s.idea;
                      _count = s.count.toDouble();
                    }),
                  ),
              ]),
            ],
          ]),
        ),
      ),
      const SizedBox(height: 14),
      Appear(
        delay: 80,
        child: StepCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text('How many questions should I ask?', style: t.textTheme.titleMedium)),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
                child: Text('$n', key: ValueKey(n), style: t.textTheme.headlineSmall?.copyWith(color: t.colorScheme.primary)),
              ),
            ]),
            Slider(value: _count, min: 1, max: 30, divisions: 29, label: '$n', onChanged: (v) => setState(() => _count = v)),
            Text(hint, style: sub),
            Text('Each question has suggested answers you can tap, or you can type your own.', style: sub),
          ]),
        ),
      ),
      const SizedBox(height: 18),
      FilledButton(
        onPressed: ok ? () => b.toSetup(_idea.text, _count.round()) : null,
        child: Text(ok ? 'Next: choose the look' : 'Describe the app a little more'),
      ),
    ]);
  }

  // ------------------------------------------------------------------ 2. the look
  Widget _setup(AppBuilder b, AppProject p, ThemeData t) {
    final sub = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final colors = presetAt(_preset).glow;
    final name = _name.text.trim();
    return ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 100), children: [
      Appear(
        child: StepCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Name and icon', style: t.textTheme.titleLarge),
            const SizedBox(height: 12),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: TextField(
                  controller: _name,
                  textCapitalization: TextCapitalization.words,
                  maxLength: 30,
                  onChanged: (v) {
                    p.name = v;
                    _later(b);
                    setState(() {});
                  },
                  decoration: const InputDecoration(labelText: 'App name', counterText: ''),
                ),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: OutlinedButton(onPressed: b.isBusy ? null : b.suggestNames, child: const Text('Suggest')),
              ),
            ]),
            if (b.names.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 4, children: [
                for (final n in b.names)
                  ActionChip(
                    label: Text(n),
                    onPressed: () => setState(() {
                      _name.text = n;
                      p.name = n;
                    }),
                  ),
              ]),
            ],
            const SizedBox(height: 14),
            Text('Icon style', style: t.textTheme.titleSmall),
            const SizedBox(height: 8),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              for (final s in kIconStyles)
                Pressable(
                  onTap: () => setState(() => _icon = s.$1),
                  child: Column(children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(borderRadius: BorderRadius.circular(22), border: Border.all(color: _icon == s.$1 ? t.colorScheme.primary : Colors.transparent, width: 2.5)),
                      child: IconPreview(style: s.$1, letter: name.isEmpty ? 'A' : name, colors: colors, size: 64),
                    ),
                    const SizedBox(height: 4),
                    Text(s.$2, style: t.textTheme.labelSmall),
                  ]),
                ),
            ]),
          ]),
        ),
      ),
      const SizedBox(height: 14),
      Appear(
        delay: 80,
        child: StepCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Theme and colours', style: t.textTheme.titleLarge),
            const SizedBox(height: 12),
            Wrap(spacing: 12, runSpacing: 12, children: [
              for (var i = 0; i < kPresets.length; i++)
                Pressable(
                  onTap: () => setState(() => _preset = i),
                  child: Column(children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: SweepGradient(colors: [...kPresets[i].glow, kPresets[i].glow.first]),
                        border: Border.all(color: _preset == i ? t.colorScheme.onSurface : Colors.transparent, width: 3),
                      ),
                      child: _preset == i ? const Icon(Icons.check_rounded, color: Colors.white) : null,
                    ),
                    const SizedBox(height: 4),
                    Text(kPresets[i].name, style: t.textTheme.labelSmall),
                  ]),
                ),
            ]),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<String>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 'system', label: Text('Auto'), icon: Icon(Icons.brightness_auto_rounded, size: 18)),
                  ButtonSegment(value: 'light', label: Text('Light'), icon: Icon(Icons.light_mode_rounded, size: 18)),
                  ButtonSegment(value: 'dark', label: Text('Dark'), icon: Icon(Icons.dark_mode_rounded, size: 18)),
                ],
                selected: {_mode},
                onSelectionChanged: (s) => setState(() => _mode = s.first),
              ),
            ),
            const SizedBox(height: 6),
            Text('The app gets these colours, in both its light and dark look.', style: sub),
          ]),
        ),
      ),
      if (b.error != null) ...[const SizedBox(height: 12), ErrorBox(b.error!, onClose: b.clearError)],
      const SizedBox(height: 18),
      Row(children: [
        Expanded(child: OutlinedButton(onPressed: b.backToDescribe, child: const Text('Back'))),
        const SizedBox(width: 12),
        Expanded(
          flex: 2,
          child: FilledButton(
            onPressed: name.isEmpty || b.isBusy ? null : () => b.startQuestions(name: name, icon: _icon, preset: _preset, mode: _mode),
            child: Text(name.isEmpty ? 'Give the app a name' : (p.qa.isEmpty ? 'Start the questions' : 'Continue')),
          ),
        ),
      ]),
    ]);
  }

  // ------------------------------------------------------------------ 3. the questions
  Widget _questions(AppBuilder b, AppProject p, ThemeData t) {
    final sub = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final q = b.question;
    final key = '${p.id}:${p.pos}:${p.qa.length}';
    if (q != null && _answerKey != key) {
      _answerKey = key;
      _answer.text = q.options.contains(q.answer) ? '' : q.answer;
    }
    final shown = (p.pos + 1).clamp(1, p.count);
    return ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 40), children: [
      Row(children: [
        Text('Question $shown of ${p.count}', style: t.textTheme.labelLarge?.copyWith(color: t.colorScheme.primary)),
        const Spacer(),
        TextButton(onPressed: b.isBusy ? null : b.backToSetup, child: const Text('Change the look')),
      ]),
      const SizedBox(height: 6),
      TweenAnimationBuilder<double>(
        tween: Tween(end: (shown - (q == null ? 1 : 0)) / p.count),
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
        builder: (_, v, __) => LinearProgressIndicator(value: v, minHeight: 6, borderRadius: BorderRadius.circular(8)),
      ),
      const SizedBox(height: 22),
      if (q == null)
        b.error != null
            ? Column(children: [ErrorBox(b.error!, action: 'Try again', onAction: b.retryQuestion, onClose: b.clearError)])
            : Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: b.liveText.isNotEmpty
                    ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(b.liveText, style: t.textTheme.headlineSmall?.copyWith(height: 1.25)), const SizedBox(height: 14), const Orb(size: 28, mode: OrbMode.writing)])
                    : const Center(child: Column(children: [Orb(size: 64, mode: OrbMode.thinking), SizedBox(height: 16), ThinkingDots()])),
              )
      else
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          transitionBuilder: (c, a) => FadeTransition(opacity: a, child: SlideTransition(position: Tween(begin: const Offset(0.05, 0), end: Offset.zero).animate(a), child: c)),
          child: Column(key: ValueKey(key), crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(q.q, style: t.textTheme.headlineSmall?.copyWith(height: 1.25)),
            const SizedBox(height: 18),
            for (var i = 0; i < q.options.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Appear(
                  delay: 60 + i * 60,
                  dy: 10,
                  child: Pressable(
                    onTap: b.isBusy ? null : () => b.answer(q.options[i]),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      decoration: BoxDecoration(
                        color: q.answer == q.options[i] ? t.colorScheme.primary.withValues(alpha: 0.18) : t.colorScheme.surfaceContainerHigh.withValues(alpha: 0.92),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: q.answer == q.options[i] ? t.colorScheme.primary : t.colorScheme.outlineVariant.withValues(alpha: 0.4)),
                      ),
                      child: Text(q.options[i], style: t.textTheme.titleSmall),
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 6),
            TextField(
              controller: _answer,
              minLines: 1,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: _listening == 'answer' ? 'Listening…' : 'Or type your own answer',
                prefixIcon: IconButton(tooltip: 'Speak', icon: Icon(_listening == 'answer' ? Icons.stop_circle_outlined : Icons.mic_none_rounded), onPressed: () => _mic(_answer, 'answer')),
                suffixIcon: IconButton.filled(
                  tooltip: 'Next',
                  onPressed: _answer.text.trim().isEmpty || b.isBusy ? null : () => b.answer(_answer.text),
                  icon: const Icon(Icons.arrow_upward_rounded),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(children: [
              if (p.pos > 0) TextButton.icon(onPressed: b.isBusy ? null : b.back, icon: const Icon(Icons.arrow_back_rounded, size: 18), label: const Text('Back')),
              const Spacer(),
              TextButton(onPressed: b.isBusy ? null : () => b.answer(''), child: const Text('You decide')),
            ]),
            Text('"You decide" lets AIy choose a sensible answer.', style: sub),
          ]),
        ),
    ]);
  }

  // ------------------------------------------------------------------ 4. the brief
  Widget _briefStage(AppBuilder b, AppProject p, ThemeData t) {
    final sub = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    if (_briefSrc != p.brief) {
      _brief.text = p.brief;
      _briefSrc = p.brief;
    }
    if (b.isBusy || (p.brief.isEmpty && b.error == null)) {
      if (b.liveText.isNotEmpty) {
        return ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 40), children: [
          StepCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Writing your app brief…', style: t.textTheme.titleMedium),
            const SizedBox(height: 10),
            MdText(b.liveText),
            const SizedBox(height: 6),
            const Orb(size: 26, mode: OrbMode.writing),
          ])),
        ]);
      }
      return const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [Orb(size: 72, mode: OrbMode.thinking), SizedBox(height: 16), Text('Writing the app brief…')]));
    }
    return ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 40), children: [
      if (b.error != null) ...[ErrorBox(b.error!, action: 'Try again', onAction: b.writeBrief, onClose: b.clearError), const SizedBox(height: 12)],
      Appear(
        child: StepCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Your app brief', style: t.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text('This is what the code will be written from. Read it and change anything you like.', style: sub),
            const SizedBox(height: 12),
            TextField(
              controller: _brief,
              minLines: 10,
              maxLines: 30,
              style: const TextStyle(height: 1.4),
              onChanged: (v) {
                p.brief = v;
                _briefSrc = v;
                _later(b);
              },
            ),
          ]),
        ),
      ),
      ..._screensCard(b, p, t),
      const SizedBox(height: 16),
      Row(children: [
        Expanded(child: OutlinedButton(onPressed: b.backToQuestions, child: const Text('Questions'))),
        const SizedBox(width: 12),
        Expanded(child: OutlinedButton(onPressed: b.writeBrief, child: const Text('Write it again'))),
      ]),
      const SizedBox(height: 12),
      FilledButton(onPressed: p.brief.trim().isEmpty ? null : b.toWrite, child: const Text('Choose the model and write the app')),
    ]);
  }

  /// The screens of the app as a checklist: untick one and it is taken out of the brief before any code is written.
  List<Widget> _screensCard(AppBuilder b, AppProject p, ThemeData t) {
    final screens = screensOf(p.brief);
    if (screens.isEmpty && _removed.isEmpty) return const [];
    final sub = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    void change(String text) {
      p.brief = text;
      _brief.text = text;
      _briefSrc = text;
      b.save();
      setState(() {});
    }

    return [
      const SizedBox(height: 14),
      Appear(
        delay: 80,
        child: StepCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Screens', style: t.textTheme.titleMedium),
            Text('Untick a screen to leave it out of this first version.', style: sub),
            for (final s in screens)
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: true,
                title: Text(screenTitle(s)),
                onChanged: (_) {
                  _removed.add(s);
                  change(removeScreen(p.brief, s));
                },
              ),
            if (_removed.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text('Left out (tap to put back):', style: sub),
              Wrap(spacing: 8, children: [
                for (final r in List.of(_removed))
                  ActionChip(
                    avatar: const Icon(Icons.add_rounded, size: 16),
                    label: Text(screenTitle(r)),
                    onPressed: () {
                      _removed.remove(r);
                      change(restoreScreen(p.brief, r));
                    },
                  ),
              ]),
            ],
          ]),
        ),
      ),
    ];
  }

  // ------------------------------------------------------------------ 5. write the code
  Future<void> _chooseModel() async {
    final m = await Navigator.push<OrModel>(context, MaterialPageRoute(builder: (_) => ModelPicker(selected: _model?.id ?? '')));
    if (m == null || !mounted) return;
    setState(() => _model = m);
    context.read<LocalPrefs>().setCodeModel(m.id);
  }

  /// Plan, write, check, zip: where the writing of the app stands.
  Widget _writeTimeline(AppBuilder b, ThemeData t) {
    const order = ['plan', 'write', 'check', 'zip'];
    final at = order.indexOf(b.phase);
    String st(int i) => i < at ? 'done' : (i == at ? 'active' : 'waiting');
    final writing = b.fileCount == 0 ? '' : 'File ${b.fileCount}${b.fileNow.isEmpty ? '' : ': ${b.fileNow}'}';
    return StepCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Writing your app', style: t.textTheme.titleMedium),
        const SizedBox(height: 12),
        StepTimeline([
          TimelineStep('Plan the files', st(0), note: at == 0 ? 'A free model decides which files are needed' : ''),
          TimelineStep(b.round > 1 ? 'Write and fix the code (pass ${b.round} of 3)' : 'Write the code', st(1), note: at == 1 ? writing : ''),
          TimelineStep('Check the project', st(2), note: at == 2 ? 'Brackets, imports and packages' : ''),
          TimelineStep('Make the zip and the icon', st(3)),
        ]),
      ]),
    );
  }

  Widget _write(AppBuilder b, AppProject p, ThemeData t) {
    final sub = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final est = _model == null ? null : b.estimate(_model!);
    final cap = context.watch<LocalPrefs>().capUsd;
    return ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 100), children: [
      if (b.isBusy && b.phase.isNotEmpty) ...[_writeTimeline(b, t), const SizedBox(height: 12)],
      Appear(
        child: StepCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Who writes the code?', style: t.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text('AIy plans the files with a free model, then the model you choose writes them. A good coding model gives a far better app.', style: sub),
            const SizedBox(height: 12),
            Pressable(
              onTap: b.isBusy ? null : _chooseModel,
              child: Container(
                padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
                decoration: BoxDecoration(color: t.colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(16)),
                child: Row(children: [
                  Expanded(
                    child: _model == null
                        ? Text('Choose a model', style: t.textTheme.titleSmall)
                        : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(_model!.name, style: t.textTheme.titleSmall), Text(_model!.priceLabel, style: sub)]),
                  ),
                  const Icon(Icons.unfold_more_rounded),
                ]),
              ),
            ),
            if (est != null) ...[
              const SizedBox(height: 10),
              Text(est.blocked ?? 'Estimated cost: about ${fmtMoney(est.cost)}. It can never cost more than ${_model!.free ? 'nothing' : fmtMoney(cap)} in total, even with the automatic fix rounds.',
                  style: sub?.copyWith(color: est.blocked != null ? t.colorScheme.error : null)),
            ],
            const SizedBox(height: 12),
            Text('After the code is written AIy checks it (brackets, imports, packages). If something is wrong, it asks the same model to fix it, up to two more times.', style: sub),
          ]),
        ),
      ),
      if (b.error != null) ...[const SizedBox(height: 12), ErrorBox(b.error!, onClose: b.clearError)],
      const SizedBox(height: 16),
      Row(children: [
        Expanded(child: OutlinedButton(onPressed: b.isBusy ? null : b.backToBrief, child: const Text('Brief'))),
        const SizedBox(width: 12),
        Expanded(flex: 2, child: FilledButton.icon(onPressed: _model == null || b.isBusy ? null : () => b.generate(_model!), icon: const Icon(Icons.auto_fix_high_rounded, size: 20), label: const Text('Write the app'))),
      ]),
    ]);
  }

  // ------------------------------------------------------------------ 6. done
  Widget _done(AppBuilder b, AppProject p, ThemeData t) {
    final sub = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final code = context.watch<CodeState>();
    final paths = p.files.keys.toList()..sort();
    return ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 40), children: [
      Appear(
        child: StepCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              IconPreview(style: p.icon, letter: p.name, colors: presetAt(p.preset).glow, size: 56),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${p.title} is written', style: t.textTheme.titleLarge),
                  Text('${paths.length} files · ${p.model} · ${fmtMoney(p.cost)}', style: sub),
                ]),
              ),
            ]),
            if (p.problems.isNotEmpty) ...[
              const SizedBox(height: 12),
              ErrorBox('The check found ${p.problems.length} thing(s) that may stop it from compiling:\n${p.problems.take(5).map((e) => '• $e').join('\n')}\n\nYou can still build it: if the build fails, "Fix it with AI" repairs it.'),
            ],
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: const Size(64, 46)),
                onPressed: widget.onOpenCode,
                icon: const Icon(Icons.code_rounded, size: 18),
                label: const Text('Keep improving in Code'),
              ),
              OutlinedButton.icon(
                onPressed: () async {
                  try {
                    final where = await b.saveZip(p);
                    if (mounted) snack(context, 'Saved to $where');
                  } catch (_) {
                    await SharePlus.instance.share(ShareParams(files: [XFile(p.zip)]));
                  }
                },
                icon: const Icon(Icons.download_rounded, size: 18),
                label: const Text('Save the zip'),
              ),
              OutlinedButton.icon(onPressed: () => SharePlus.instance.share(ShareParams(files: [XFile(p.zip)])), icon: const Icon(Icons.ios_share_rounded, size: 18), label: const Text('Share')),
            ]),
          ]),
        ),
      ),
      const SizedBox(height: 14),
      Appear(
        delay: 80,
        child: StepCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('What to do with it', style: t.textTheme.titleSmall),
            const SizedBox(height: 6),
            Text('A zip you can open on your PC, or push it to a new GitHub repository and let GitHub build the APK for you.', style: sub),
            const SizedBox(height: 12),
            if (code.hasResult && !code.isBusy && code.sourceName == p.title) const PublishPanel() else if (code.error != null) ErrorBox(code.error!, onClose: code.clearError) else Row(children: [const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)), const SizedBox(width: 10), Text('Opening the project…', style: sub)]),
          ]),
        ),
      ),
      const SizedBox(height: 14),
      Appear(
        delay: 140,
        child: StepCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Files', style: t.textTheme.titleSmall),
            const SizedBox(height: 4),
            for (final f in paths)
              InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => DiffScreen(change: FileChange(f, null, p.files[f]!)))),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  child: Row(children: [
                    Icon(Icons.description_outlined, size: 18, color: t.colorScheme.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Expanded(child: Text(f, style: const TextStyle(fontFamily: 'monospace', fontSize: 13))),
                    Text('${'\n'.allMatches(p.files[f]!).length + 1} lines', style: sub),
                  ]),
                ),
              ),
          ]),
        ),
      ),
      const SizedBox(height: 14),
      Center(child: TextButton(onPressed: b.isBusy ? null : b.backToBrief, child: const Text('Change the brief and write it again'))),
    ]);
  }
}
