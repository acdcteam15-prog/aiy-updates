import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../state/app_builder.dart';
import '../../state/build_state.dart';
import '../../state/chat_store.dart';
import '../../state/code_state.dart';
import '../../state/connectivity.dart';
import '../../state/error_center.dart';
import '../../state/native.dart';
import '../../state/paid_jobs.dart';
import '../../state/report.dart';
import '../widgets/build_steps.dart';
import '../widgets/common.dart';
import '../widgets/job_stepper.dart';
import 'build_screen.dart';
import 'update_screen.dart';
import '../../state/storage.dart';
import '../../state/updater.dart';

/// One page of the "Running and waiting" screen.
class _Page {
  final String key;
  final IconData icon;
  final String title;
  final String sub;
  final String state; // running | failed | done | waiting
  final double? percent;
  final List<JobStep> steps;
  final JobError? error;
  final List<_Act> actions;
  const _Page({required this.key, required this.icon, required this.title, required this.sub, required this.state, this.percent, required this.steps, this.error, this.actions = const []});
}

class _Act {
  final String label;
  final VoidCallback onTap;
  final bool primary;
  final bool danger;
  const _Act(this.label, this.onTap, {this.primary = false, this.danger = false});
}

/// Everything AIy is doing or waiting to do: one job per page, swipe between them.
/// Each page shows the job's steps; when a job stops, the step where it stopped says what happened and what to do.
class JobsScreen extends StatefulWidget {
  const JobsScreen({super.key});
  @override
  State<JobsScreen> createState() => _JobsScreenState();
}

class _JobsScreenState extends State<JobsScreen> {
  final _pc = PageController();
  int _at = 0;

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  void _askAi(String text) {
    final ask = ErrorCenter.askAi;
    if (ask == null) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
    ask('AIy showed me this problem. Explain in simple words what it means and what I can do about it.\n\n$text');
  }

  Future<void> _copy(Object? error, String where) async {
    final r = await ReportBundle.build(error: error, where: where);
    await Clipboard.setData(ClipboardData(text: r));
    if (mounted) snack(context, 'Report copied (keys removed)');
  }

  void _openBuild() => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const BuildScreen()));

  List<_Page> _pages(BuildContext context) {
    final chat = context.watch<ChatStore>();
    final code = context.watch<CodeState>();
    final app = context.watch<AppBuilder>();
    final b = context.watch<BuildState>();
    final net = context.watch<ConnectivityService>();
    final paid = context.watch<PaidJobs>();
    final up = context.watch<UpdateService>();
    final out = <_Page>[];

    // the AIy update download (also running while the app is in the background)
    if (up.latest != null && up.hasUpdate && (up.status == UpdateStatus.downloading || up.status == UpdateStatus.paused)) {
      final running = up.status == UpdateStatus.downloading;
      out.add(_Page(
        key: 'update',
        icon: Icons.system_update_rounded,
        title: 'Updating AIy',
        sub: 'Version ${up.latest!.versionName}${up.total > 0 ? ' · ${StorageInfo.fmt(up.total)}' : ''}',
        state: running ? 'running' : 'waiting',
        percent: up.total > 0 ? up.progress : null,
        steps: [
          const JobStep('Update found', 'done'),
          JobStep('Download', running ? 'running' : 'waiting', note: '${StorageInfo.fmt(up.got)} of ${StorageInfo.fmt(up.total)}${running && up.speedBps > 1 ? ' · ${StorageInfo.fmt(up.speedBps.round())}/s' : ''}${running && up.etaSec >= 0 ? ' · about ${fmtSeconds(up.etaSec)} left' : ''}', live: running ? 'It keeps going when you leave AIy' : ''),
          const JobStep('Check the file', 'waiting'),
          const JobStep('Ready to install', 'waiting'),
        ],
        actions: [
          if (running) _Act('Pause', () => up.pause()) else _Act('Resume', up.resume, primary: true),
          _Act('Open', () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const UpdateScreen()))),
        ],
      ));
    }

    // the GitHub build or check: running, stopped with an error, or finished
    if (b.running || b.phase == 'failed' || (b.phase == 'done' && b.repo.isNotEmpty)) {
      final v = buildView(b);
      final what = b.checkOnly ? 'Quick check on GitHub' : 'Build on GitHub';
      final idx = v.steps.indexWhere((s) => s.state == 'failed');
      final sub = switch (v.state) {
        'failed' => 'Stopped at step ${idx + 1} of ${v.steps.length}',
        'done' => b.checkOnly ? 'The code compiles' : 'Your app is ready',
        _ => '${b.repo} · ${b.branch}${b.version.isEmpty ? '' : ' · version ${b.version}'}',
      };
      out.add(_Page(
        key: 'build',
        icon: Icons.rocket_launch_outlined,
        title: what,
        sub: sub,
        state: v.state == 'idle' ? 'waiting' : v.state,
        percent: v.percent,
        steps: v.steps,
        error: v.error,
        actions: switch (v.state) {
          'running' => [
              if (b.runUrl.isNotEmpty) _Act('Open on GitHub', () => Native.openUrl(b.runUrl)),
              _Act('Cancel build', () => b.cancel(), danger: true),
            ],
          'failed' => [
              _Act('Ask AIy', () => _askAi('${v.error?.what ?? ''}\n${v.error?.where ?? ''}\n${b.log.length > 3000 ? b.log.substring(b.log.length - 3000) : b.log}')),
              _Act('Copy report', () => _copy(b.error ?? v.error?.what, what)),
              if (b.aiCannotFix) _Act('Update and build again', () => b.rebuildAfterSetup(), primary: true) else if (b.paused != null) _Act('Continue auto-fix', () => b.continueFix(), primary: true) else _Act(b.problems.isNotEmpty ? 'Fix it with AI…' : 'Open the build', _openBuild, primary: true),
            ],
          _ => [
              if (b.apk != null && !b.checkOnly) _Act('Install', () async {
                final m = await b.install(b.apk!.path);
                if (m != null && context.mounted) snack(context, m);
              }, primary: true),
              _Act('Open the build', _openBuild),
            ],
        },
      ));
    }
    if (chat.busy) {
      out.add(_Page(key: 'chat', icon: Icons.chat_bubble_outline_rounded, title: 'Chat answer', sub: 'Writing an answer', state: 'running', steps: const [JobStep('Send the question', 'done'), JobStep('Write the answer', 'running', live: 'The answer is arriving…')], actions: [_Act('Stop', chat.stop, danger: true)]));
    }
    if (code.isBusy) {
      out.add(_Page(key: 'code', icon: Icons.code_rounded, title: 'Code', sub: code.sourceName, state: 'running', steps: [const JobStep('Read the files', 'done'), JobStep('Write the change', 'running', live: code.busy), const JobStep('Check the result', 'waiting')]));
    }
    if (app.isBusy) {
      out.add(_Page(key: 'app', icon: Icons.auto_awesome_outlined, title: 'Writing an app', sub: app.current?.title ?? '', state: 'running', steps: [JobStep('Write the app', 'running', live: app.busy), const JobStep('Check the files', 'waiting')]));
    }
    for (final j in net.jobs) {
      out.add(_Page(
        key: 'net${j.id}',
        icon: Icons.wifi_off_rounded,
        title: 'Waiting for the internet',
        sub: j.title,
        state: 'waiting',
        steps: [JobStep('Wait for the internet', 'running', live: 'Sent again by itself when the connection is back'), JobStep(j.title, 'waiting')],
        actions: [_Act('Cancel', () => net.cancel(j), danger: true)],
      ));
    }
    for (final j in paid.leftOver) {
      out.add(_Page(
        key: 'paid${j.id}',
        icon: Icons.payments_outlined,
        title: 'Paid job waiting for your OK',
        sub: '${j.modelName}: ${j.price}',
        state: 'waiting',
        steps: [const JobStep('Waiting for your answer', 'running', live: 'Nothing is sent without your tap'), JobStep(j.title, 'waiting')],
        actions: [
          _Act('Discard', () => PaidJobs.instance.done(j.id), danger: true),
          _Act('Continue', () {
            Navigator.of(context).popUntil((r) => r.isFirst);
            if (j.kind == 'code') {
              context.read<CodeState>().resumePaid(j);
            } else {
              context.read<AppBuilder>().resumePaid(j);
            }
          }, primary: true),
        ],
      ));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final pages = _pages(context);
    if (_at >= pages.length && pages.isNotEmpty) _at = pages.length - 1;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Running and waiting'),
        actions: [if (pages.length > 1) Padding(padding: const EdgeInsets.only(right: 16), child: Center(child: Text('${_at + 1} of ${pages.length}', style: t.textTheme.bodyMedium)))],
      ),
      body: pages.isEmpty
          ? Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.check_circle_outline_rounded, size: 56, color: t.colorScheme.onSurfaceVariant),
                const SizedBox(height: 12),
                Text('Nothing is running or waiting.', style: t.textTheme.bodyLarge),
              ]),
            )
          : Column(children: [
              if (pages.length > 1) _Dots(count: pages.length, at: _at, states: [for (final p in pages) p.state]),
              Expanded(
                child: PageView.builder(
                  controller: _pc,
                  itemCount: pages.length,
                  onPageChanged: (i) => setState(() => _at = i),
                  itemBuilder: (_, i) => _JobPage(key: ValueKey(pages[i].key), p: pages[i], hint: pages.length > 1 && i < pages.length - 1),
                ),
              ),
            ]),
    );
  }
}

class _Dots extends StatelessWidget {
  final int count;
  final int at;
  final List<String> states;
  const _Dots({required this.count, required this.at, required this.states});

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
      child: Row(children: [
        for (var i = 0; i < count; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
            margin: const EdgeInsets.only(right: 6),
            width: i == at ? 22 : 6,
            height: 6,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(3),
              color: i == at ? (states[i] == 'failed' ? JobColors.error : (states[i] == 'done' ? JobColors.done : s.primary)) : s.outlineVariant,
            ),
          ),
      ]),
    );
  }
}

class _JobPage extends StatelessWidget {
  final _Page p;
  final bool hint;
  const _JobPage({super.key, required this.p, required this.hint});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = t.colorScheme;
    final tint = switch (p.state) {
      'failed' => JobColors.error,
      'done' => JobColors.done,
      _ => s.primary,
    };
    final header = Row(children: [
      Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(color: tint.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(14)),
        child: Icon(p.state == 'failed' ? Icons.warning_amber_rounded : p.icon, color: tint),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(p.title, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          if (p.sub.isNotEmpty) Text(p.sub, maxLines: 2, overflow: TextOverflow.ellipsis, style: t.textTheme.bodySmall?.copyWith(color: p.state == 'failed' ? JobColors.errorSoft : s.onSurfaceVariant)),
        ]),
      ),
      if (p.percent != null && p.state == 'running')
        TweenAnimationBuilder<double>(
          tween: Tween(end: p.percent!),
          duration: const Duration(milliseconds: 500),
          builder: (_, v, __) => Text('${(v * 100).round()}%', style: t.textTheme.titleLarge?.copyWith(color: s.primary, fontWeight: FontWeight.w700)),
        ),
    ]);
    return Column(children: [
      Expanded(
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), children: [
          if (p.state == 'done') const Center(child: DoneBadge(size: 84)),
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 450),
            curve: Curves.easeOutCubic,
            builder: (_, v, c) => Opacity(opacity: v, child: Transform.translate(offset: Offset(0, 12 * (1 - v)), child: c)),
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(color: s.surfaceContainer, borderRadius: BorderRadius.circular(28), border: Border.all(color: s.outlineVariant.withValues(alpha: 0.5))),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                header,
                if (p.state == 'running') ...[const SizedBox(height: 16), ShineBar(value: p.percent)],
                const SizedBox(height: 18),
                JobStepper(steps: p.steps, error: p.error),
              ]),
            ),
          ),
        ]),
      ),
      if (hint)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.chevron_right_rounded, size: 18, color: s.onSurfaceVariant),
            Text('Swipe for the next job', style: t.textTheme.bodySmall?.copyWith(color: s.onSurfaceVariant)),
          ]),
        ),
      if (p.actions.isNotEmpty)
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Wrap(spacing: 10, runSpacing: 10, alignment: WrapAlignment.end, children: [
              for (final a in p.actions)
                a.primary
                    ? FilledButton(onPressed: a.onTap, style: FilledButton.styleFrom(minimumSize: const Size(64, 52), backgroundColor: p.state == 'done' ? JobColors.done : null, foregroundColor: p.state == 'done' ? const Color(0xFF0B0D14) : null), child: Text(a.label))
                    : OutlinedButton(
                        onPressed: a.onTap,
                        style: OutlinedButton.styleFrom(minimumSize: const Size(64, 52), foregroundColor: a.danger ? JobColors.errorSoft : null),
                        child: Text(a.label),
                      ),
            ]),
          ),
        ),
    ]);
  }
}
