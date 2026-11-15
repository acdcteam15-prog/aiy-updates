import '../../logic/buildlog.dart';
import '../../state/build_state.dart';
import 'job_stepper.dart';

/// The big steps of a GitHub build or quick check, for the job pages and the Build screen.
class BuildView {
  final List<JobStep> steps;
  final JobError? error;
  final double? percent; // 0..1, null when unknown
  final String state; // running | failed | done | idle
  const BuildView(this.steps, this.error, this.percent, this.state);
}

int _stageOf(String phase) => switch (phase) {
      'pushing' || 'preparing' => 0,
      'queued' => 1,
      'building' || 'fixing' => 2,
      'downloading' => 3,
      _ => -1,
    };

String _dur(int ms) {
  final s = (ms / 1000).round();
  if (s < 60) return '$s s';
  return '${s ~/ 60} min ${s % 60} s';
}

BuildView buildView(BuildState b) {
  final check = b.checkOnly;
  final titles = ['Prepare', 'Start on GitHub', check ? 'Check the code' : 'Build the app', if (!check) 'Download the APK', check ? 'No errors found' : 'Ready to install'];
  final last = titles.length - 1;
  final failed = b.phase == 'failed';
  final done = b.phase == 'done';
  final running = b.running;
  var at = done ? titles.length : _stageOf(failed ? b.failedPhase : b.phase);
  if (failed && at < 0) at = b.problems.isNotEmpty ? 2 : 1;
  if (at > last) at = done ? titles.length : last;
  final now = DateTime.now().millisecondsSinceEpoch;
  int? startOf(int i) {
    for (final e in b.phaseAt.entries) {
      if (_stageOf(e.key) == i) return e.value;
    }
    return null;
  }

  String live = '';
  if (running && at == 2) {
    final bad = b.steps.where((s) => s.state == 'failed').map((s) => s.name).firstOrNull;
    final cur = b.steps.where((s) => s.state == 'running').map((s) => s.name).firstOrNull;
    final started = b.steps.any((s) => s.state != 'waiting');
    live = bad != null ? 'Failed: $bad · GitHub is ending the run' : (cur ?? (started ? 'Between steps…' : 'Waiting for a GitHub computer'));
  } else if (running) {
    live = b.status;
  }
  final steps = <JobStep>[];
  for (var i = 0; i < titles.length; i++) {
    String state;
    if (done || i < at) {
      state = 'done';
    } else if (i == at) {
      state = failed ? 'failed' : (running ? 'running' : 'waiting');
    } else {
      state = failed ? 'skipped' : 'waiting';
    }
    var note = '';
    final st = startOf(i);
    if (state == 'done' && st != null) {
      final nx = startOf(i + 1) ?? (done ? b.phaseAt['done'] : null);
      if (nx != null && nx >= st) note = _dur(nx - st);
    } else if (state == 'running' && st != null) {
      note = '${_dur(now - st)} so far';
    }
    if (i == 2 && state == 'running' && b.steps.isNotEmpty) note = '${b.steps.where((s) => s.state == 'done').length} of ${b.steps.length} GitHub steps · $note';
    if (i == last && done && b.apk != null) note = b.apk!.path.split('/').last;
    steps.add(JobStep(titles[i], state, note: note, live: state == 'running' ? live : ''));
  }
  JobError? err;
  final setup = b.setupStepFailed;
  final env = b.environmentProblem;
  if (failed && setup.isEmpty && env.isNotEmpty) {
    err = JobError(
      what: 'Not a mistake in your code: $env.',
      where: b.problems.isNotEmpty ? b.problems.first.title : '',
      todo: 'Tap "Update and build again": AIy updates its build so plugins use a new enough Android version. Fix with AI is off here because it cannot see this problem and would only cost money.',
    );
  } else if (failed && setup.isNotEmpty) {
    err = JobError(
      what: 'GitHub\'s build setup failed, not your code.',
      where: setup,
      todo: 'Tap "Update and build again": AIy updates its build workflow so this step can no longer stop the build. Fixing the code with AI would not help here.',
    );
  } else if (failed) {
    final p = b.problems.isNotEmpty ? b.problems.first : null;
    String loc(Problem e) => e.file.isEmpty ? '' : '${e.file}${e.line > 0 ? ':${e.line}' : ''} · ';
    final where = p == null
        ? ''
        : [for (final e in b.problems.take(8)) '${loc(e)}${e.detail.isNotEmpty ? e.detail : e.title}'].join('\n\n') +
            (b.problems.length > 8 ? '\n\n…and ${b.problems.length - 8} more (see the log)' : '');
    err = JobError(
      what: p != null ? '${p.title}${b.problems.length > 1 ? ' (${b.problems.length} errors, all listed below)' : ''}' : (b.error ?? (check ? 'The check found errors.' : 'The build failed.')),
      where: where,
      todo: b.lastWasConnection
          ? 'The internet went away. Check the connection, then try again.'
          : (p != null ? 'Let AI write a fix (you see the price first), or open the file and correct it.' : 'Open the run on GitHub to read the full log, or tap Ask AIy for an explanation.'),
    );
  }
  double? pct;
  if (done) {
    pct = 1;
  } else if (running && at >= 0) {
    final inside = at == 2 && b.progress > 0 ? b.progress : 0.0;
    pct = ((at + inside) / titles.length).clamp(0.0, 1.0);
  }
  return BuildView(steps, err, pct, failed ? 'failed' : (done ? 'done' : (running ? 'running' : 'idle')));
}
