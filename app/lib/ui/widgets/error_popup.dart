import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../state/ai.dart';
import '../../state/error_center.dart';
import '../../state/keys.dart';
import '../../state/net.dart';
import '../../state/prefs.dart';
import '../../state/report.dart';
import '../screens/model_picker.dart';
import 'common.dart';

bool _open = false;

/// Shows an OpenRouter problem on top of whatever the person is looking at (set as [ErrorCenter.presenter]).
Future<void> showAiProblem(AiProblem p) async {
  if (_open) return;
  final ctx = ErrorCenter.navKey.currentContext;
  if (ctx == null) return;
  _open = true;
  try {
    await showDialog<void>(context: ctx, builder: (_) => _ProblemDialog(p));
  } finally {
    _open = false;
  }
}

/// Plain words for an error: a short title, what happened, and what to try.
({String title, String what, String todo, IconData icon}) explainProblem(ApiError e) {
  final r = _explainProblem(e);
  return (title: r.title, what: _withTries(r.what, e), todo: r.todo, icon: r.icon);
}

/// "AIy already tried 5 times." when it did.
String _withTries(String what, ApiError e) => e.tries > 1 ? '$what AIy already tried ${e.tries} times.' : what;

({String title, String what, String todo, IconData icon}) _explainProblem(ApiError e) {
  final s = e.status;
  final who = e.model.isEmpty ? 'OpenRouter' : 'OpenRouter (${e.model})';
  if (Net.isThinkingOnly(e.message)) {
    return (
      title: 'The model only thought',
      what: '$who used all of its answer space on thinking and wrote nothing.',
      todo: 'Pick a model that does not "think" (tap Try another model), or raise the limit for one request in Settings > Coding.',
      icon: Icons.psychology_alt_outlined,
    );
  }
  if ((s == 403 || s == 404) && Net.unusableText('${e.message} ${e.detail}'.toLowerCase())) {
    return (
      title: 'This model only works in other apps',
      what: '$who is a batch-only or agent-only model, so it cannot answer AIy. It is now hidden from the model list.',
      todo: 'Pick another model (any normal free or paid model works).',
      icon: Icons.block_rounded,
    );
  }
  if (s == 401 || s == 403) {
    return (
      title: 'OpenRouter did not accept the key',
      what: '$who refused the request because the key is wrong, switched off or has no permission.',
      todo: 'Open Settings > Accounts & keys and connect OpenRouter again.',
      icon: Icons.key_off_rounded,
    );
  }
  if (s == 402) {
    return (
      title: 'Not enough OpenRouter credit',
      what: 'The account has no credit left for this model, or the key reached its own limit.',
      todo: 'Add credit on openrouter.ai, or switch to a free model (those cost nothing).',
      icon: Icons.account_balance_wallet_outlined,
    );
  }
  if (s == 404) {
    return (
      title: 'This model is not available',
      what: '$who was not found. Models are retired or renamed from time to time.',
      todo: 'Switch to another model.',
      icon: Icons.search_off_rounded,
    );
  }
  if (s == 408 || (s != null && s < 0)) {
    return (
      title: 'No answer from OpenRouter',
      what: 'The connection failed or the answer took too long.',
      todo: 'Check the internet connection and try again.',
      icon: Icons.wifi_off_rounded,
    );
  }
  if (s == 413) {
    return (
      title: 'The request is too big',
      what: '$who cannot read this much text at once.',
      todo: 'Switch to a model that reads more, or send fewer files.',
      icon: Icons.unfold_more_rounded,
    );
  }
  if (s == 429) {
    return (
      title: 'Too many requests',
      what: 'The limit of $who is used up for now. Free models have small limits.',
      todo: 'Wait a minute and try again, or switch to another model.',
      icon: Icons.hourglass_bottom_rounded,
    );
  }
  if (s != null && s >= 500) {
    return (
      title: 'OpenRouter is busy',
      what: '$who, or the company that runs it, had a problem on its side (error $s).',
      todo: 'Try again in a moment, or switch to another model.',
      icon: Icons.cloud_off_rounded,
    );
  }
  if (s == 400) {
    return (
      title: 'The model refused the request',
      what: '$who could not accept this request. The text may be too long, or the model may not support it.',
      todo: 'Switch to another model.',
      icon: Icons.block_rounded,
    );
  }
  return (
    title: 'OpenRouter had a problem',
    what: e.message,
    todo: 'Try again, or switch to another model.',
    icon: Icons.error_outline_rounded,
  );
}

/// Plain words for a failure that did not come from OpenRouter.
({String title, String what, String todo, IconData icon}) explainGeneral(ApiError e) {
  final r = _explainGeneral(e);
  return (title: r.title, what: _withTries(r.what, e), todo: r.todo, icon: r.icon);
}

({String title, String what, String todo, IconData icon}) _explainGeneral(ApiError e) {
  final s = e.status;
  final who = e.provider.isEmpty ? 'The service' : e.provider;
  if (s == 401 || s == 403) {
    return (title: '$who did not accept the sign-in', what: e.message, todo: 'Connect it again in Settings > Accounts & keys.', icon: Icons.key_off_rounded);
  }
  if (s == 429) {
    return (title: '$who limit reached', what: e.message, todo: 'Wait a minute and try again.', icon: Icons.hourglass_bottom_rounded);
  }
  if (s != null && s >= 500) {
    return (title: '$who is busy', what: e.message, todo: 'Try again in a moment.', icon: Icons.cloud_off_rounded);
  }
  if (s == null) {
    return (title: 'Something went wrong', what: e.message, todo: 'Try again. If it happens again, tap "Ask AIy" for an explanation, or "Copy report" and send it to the developer.', icon: Icons.error_outline_rounded);
  }
  return (title: '$who had a problem', what: e.message, todo: 'Try again, or tap "Ask AIy" for what to do.', icon: Icons.error_outline_rounded);
}

class _ProblemDialog extends StatefulWidget {
  final AiProblem p;
  const _ProblemDialog(this.p);
  @override
  State<_ProblemDialog> createState() => _ProblemDialogState();
}

class _ProblemDialogState extends State<_ProblemDialog> {
  bool _details = false;

  String get _report {
    final e = widget.p.error;
    final sb = StringBuffer(widget.p.openRouter ? 'AIy - OpenRouter problem\n' : 'AIy - problem\n');
    if (widget.p.where.isNotEmpty) sb.writeln('While: ${widget.p.where}');
    sb.writeln('Model: ${e.model.isEmpty ? '(unknown)' : e.model}');
    sb.writeln('Status: ${e.status ?? '(none)'}');
    sb.writeln('Message: ${e.message}');
    if (e.detail.isNotEmpty) sb.writeln('${widget.p.openRouter ? 'OpenRouter' : 'The service'} said: ${e.detail}');
    if (widget.p.whole.causes.length > 1) sb.writeln('\nAll attempts:\n${widget.p.whole.message}');
    return sb.toString().trim();
  }

  Future<void> _copyBundle() async {
    final text = await ReportBundle.build(error: widget.p.whole, where: widget.p.where);
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) snack(context, 'Report copied (keys removed). Paste it where you need it.');
  }

  void _ask() {
    final ask = ErrorCenter.askAi;
    if (ask == null) return;
    Navigator.pop(context);
    ask('AIy showed me this error. Explain in simple words what it means and what I can do about it.\n\n$_report');
  }

  void _retry() {
    Navigator.pop(context);
    widget.p.retry?.call();
  }

  Future<void> _switch() async {
    final p = widget.p;
    if (p.retryWith != null) {
      final m = await Navigator.push<OrModel>(context, MaterialPageRoute(builder: (_) => ModelPicker(selected: p.modelId)));
      if (m == null || !mounted) return;
      // Money is only spent after the person has seen the price of the model they just picked.
      if (!m.free && p.costOf != null) {
        final c = p.costOf!(m);
        final ok = await confirmDialog(context, 'Try again with ${m.name}?', body: 'Estimated cost: ${fmtMoney(c.cost)}. It can never cost more than ${fmtMoney(c.worst)}.', yes: 'Send');
        if (!ok || !mounted) return;
      }
      Navigator.pop(context);
      p.retryWith!(m);
      return;
    }
    // Chat and the other free-service jobs: choose which AI should answer next.
    final changed = await showModalBottomSheet<bool>(context: context, isScrollControlled: true, useSafeArea: true, builder: (_) => const ChooseAiSheet());
    if (changed != true || !mounted) return;
    Navigator.pop(context);
    p.retry?.call();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = t.colorScheme;
    final p = widget.p;
    final w = p.openRouter ? explainProblem(p.error) : explainGeneral(p.error);
    final canRetry = p.retry != null;
    final canSwitch = p.openRouter || p.retryWith != null;
    return AlertDialog(
      icon: Icon(w.icon, color: s.error, size: 30),
      title: Text(w.title, textAlign: TextAlign.center),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(w.what, style: t.textTheme.bodyLarge),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: s.primary.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(14)),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.tips_and_updates_outlined, size: 18, color: s.primary),
                const SizedBox(width: 8),
                Expanded(child: Text(w.todo, style: t.textTheme.bodyMedium)),
              ]),
            ),
            if (p.where.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 10), child: Text('While: ${p.where}', style: t.textTheme.bodySmall?.copyWith(color: s.onSurfaceVariant))),
            const SizedBox(height: 4),
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => setState(() => _details = !_details),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(children: [
                  Icon(_details ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 20, color: s.onSurfaceVariant),
                  const SizedBox(width: 4),
                  Text('Details', style: t.textTheme.labelLarge?.copyWith(color: s.onSurfaceVariant)),
                ]),
              ),
            ),
            if (_details)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: s.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
                child: SelectableText(_report, style: const TextStyle(fontSize: 12.5, height: 1.35)),
              ),
          ]),
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      // One wrapping block: the buttons go on a second line when the screen is narrow, never off the edge.
      actions: [
        Wrap(
          alignment: WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            TextButton(onPressed: _copyBundle, child: const Text('Copy report')),
            if (ErrorCenter.askAi != null) TextButton(onPressed: _ask, child: const Text('Ask AIy')),
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
            if (canSwitch) OutlinedButton(onPressed: _switch, child: Text(p.retryWith != null || p.openRouter ? 'Try another model' : 'Switch model')),
            if (canRetry) FilledButton(onPressed: _retry, child: const Text('Retry')),
          ],
        ),
      ],
    );
  }
}

/// Chooses which AI answers next (used when the failed job had no model of its own, like chat).
class ChooseAiSheet extends StatelessWidget {
  const ChooseAiSheet();
  @override
  Widget build(BuildContext context) {
    final prefs = context.watch<LocalPrefs>();
    final keys = context.watch<KeyVault>();
    final t = Theme.of(context);
    Widget item(String id, String label, String note, {bool show = true}) {
      if (!show) return const SizedBox.shrink();
      final sel = prefs.preferProvider == id && (id != 'openrouter' || prefs.chatOrModel.isEmpty);
      return ListTile(
        leading: Icon(sel ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded, color: sel ? t.colorScheme.primary : null),
        title: Text(label),
        subtitle: Text(note),
        onTap: () async {
          await prefs.setPreferProvider(id);
          if (id != 'openrouter') await prefs.setChatOrModel('');
          if (context.mounted) Navigator.pop(context, true);
        },
      );
    }

    return SafeArea(
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.fromLTRB(24, 16, 24, 4), child: Text('Which AI should answer?', style: t.textTheme.titleLarge)),
          Padding(padding: const EdgeInsets.fromLTRB(24, 0, 24, 8), child: Text('These are free. AIy never spends money in chat.', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant))),
          item('', 'Automatic', 'Free ones first, the next one when a limit is reached'),
          item('gemini', 'Gemini first', 'Also the only one that can read PDFs and search the internet', show: keys.has('gemini')),
          item('groq', 'Groq first', 'Fast answers (no photos)', show: keys.has('groq')),
          item('mistral', 'Mistral first', 'Text only', show: keys.has('mistral')),
          item('cerebras', 'Cerebras first', 'Very fast, short texts only', show: keys.has('cerebras')),
          item('nvidia', 'NVIDIA first', 'Text only', show: keys.has('nvidia')),
          item('cloudflare', 'Cloudflare first', 'Text only', show: keys.has('cloudflare') && keys.has('cloudflare_acct')),
          item('openrouter', 'OpenRouter first', 'Its free router picks a free model for you', show: keys.has('openrouter')),
          if (keys.has('openrouter'))
            ListTile(
              leading: const Icon(Icons.tune_rounded),
              title: const Text('Pick a free OpenRouter model'),
              subtitle: Text(prefs.chatOrModel.isEmpty ? 'Search the whole free list' : 'Now: ${prefs.chatOrModel}'),
              onTap: () async {
                final m = await Navigator.push<OrModel>(context, MaterialPageRoute(builder: (_) => ModelPicker(selected: prefs.chatOrModel, freeOnly: true)));
                if (m == null) return;
                await prefs.setChatOrModel(m.id);
                await prefs.setPreferProvider('openrouter');
                if (context.mounted) Navigator.pop(context, true);
              },
            ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }
}
