import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/prefs.dart';
import '../widgets/fx.dart';

/// Three short screens that show what AIy does. Skippable; shown once after the first sign-in.
class TourScreen extends StatefulWidget {
  /// True when opened again from Settings (it then just closes at the end).
  final bool replay;
  const TourScreen({super.key, this.replay = false});
  @override
  State<TourScreen> createState() => _TourScreenState();
}

class _TourScreenState extends State<TourScreen> {
  final _pages = PageController();
  int _at = 0;

  static const _items = [
    (Icons.chat_bubble_outline_rounded, 'Ask anything', 'Chat with AIy, send a photo or a file, talk instead of typing, and let it search the internet. Share something from another app and AIy picks it up.'),
    (Icons.code_rounded, 'Change your apps', 'Open a project, say what should change in plain words, and AIy writes the change. You see the price first and nothing is sent before you say yes.'),
    (Icons.construction_rounded, 'Make a new app', 'Describe an idea, answer a few easy questions, and AIy writes the whole app. Then build it and install it on your phone.'),
  ];

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    if (widget.replay) {
      Navigator.pop(context);
      return;
    }
    await context.read<LocalPrefs>().setTourSeen(true);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final last = _at == _items.length - 1;
    return Scaffold(
      body: AuroraBackground(
        child: SafeArea(
          child: Column(children: [
            Align(alignment: Alignment.centerRight, child: Padding(padding: const EdgeInsets.fromLTRB(8, 8, 12, 0), child: TextButton(onPressed: _finish, child: const Text('Skip')))),
            Expanded(
              child: PageView(
                controller: _pages,
                onPageChanged: (i) => setState(() => _at = i),
                children: [
                  for (var i = 0; i < _items.length; i++)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Stack(alignment: Alignment.center, children: [
                          const Orb(size: 170),
                          Icon(_items[i].$1, size: 44, color: Colors.white),
                        ]),
                        const SizedBox(height: 36),
                        Text(_items[i].$2, textAlign: TextAlign.center, style: t.textTheme.headlineMedium),
                        const SizedBox(height: 14),
                        Text(_items[i].$3, textAlign: TextAlign.center, style: t.textTheme.bodyLarge?.copyWith(color: t.colorScheme.onSurfaceVariant, height: 1.4)),
                      ]),
                    ),
                ],
              ),
            ),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              for (var i = 0; i < _items.length; i++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: i == _at ? 22 : 8,
                  height: 8,
                  decoration: BoxDecoration(color: i == _at ? t.colorScheme.primary : t.colorScheme.outlineVariant, borderRadius: BorderRadius.circular(8)),
                ),
            ]),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(minimumSize: const Size(64, 52)),
                  onPressed: last ? _finish : () => _pages.nextPage(duration: const Duration(milliseconds: 320), curve: Curves.easeOutCubic),
                  child: Text(last ? (widget.replay ? 'Done' : 'Get started') : 'Next'),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
