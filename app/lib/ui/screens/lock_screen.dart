import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/lock.dart';
import '../widgets/fx.dart';

/// Covers the app until the PIN (or the fingerprint) is given.
class LockScreen extends StatefulWidget {
  const LockScreen({super.key});
  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  String _pin = '';
  String _msg = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<LockService>().tryBiometric();
    });
  }

  void _enter() {
    final l = context.read<LockService>();
    if (_pin.length < 4) return;
    if (!l.tryPin(_pin)) {
      setState(() {
        _msg = l.waitSeconds > 0 ? 'Too many tries. Wait ${l.waitSeconds} seconds.' : 'Wrong PIN';
        _pin = '';
      });
    }
  }

  Widget _key(BuildContext context, {String label = '', IconData? icon, VoidCallback? onTap}) {
    final s = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(6),
      child: SizedBox(
        width: 76,
        height: 76,
        child: onTap == null && label.isEmpty && icon == null
            ? const SizedBox()
            : Material(
                color: s.surfaceContainerHigh.withValues(alpha: 0.9),
                shape: const CircleBorder(),
                child: InkWell(customBorder: const CircleBorder(), onTap: onTap, child: Center(child: icon != null ? Icon(icon) : Text(label, style: Theme.of(context).textTheme.headlineSmall))),
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final l = context.watch<LockService>();
    Widget row(List<Widget> k) => Row(mainAxisAlignment: MainAxisAlignment.center, children: k);
    Widget digit(String d) => _key(context, label: d, onTap: () => setState(() {
          if (_pin.length < 8) _pin += d;
          _msg = '';
        }));
    return Scaffold(
      body: AuroraBackground(
        child: SafeArea(
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Orb(size: 72),
            const SizedBox(height: 18),
            Text('AIy is locked', style: t.textTheme.titleLarge),
            const SizedBox(height: 18),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              for (var i = 0; i < (_pin.length < 4 ? 4 : _pin.length); i++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  margin: const EdgeInsets.symmetric(horizontal: 6),
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: i < _pin.length ? t.colorScheme.primary : Colors.transparent, border: Border.all(color: t.colorScheme.primary, width: 1.5)),
                ),
            ]),
            SizedBox(height: 28, child: Center(child: Text(_msg, style: TextStyle(color: t.colorScheme.error)))),
            row([digit('1'), digit('2'), digit('3')]),
            row([digit('4'), digit('5'), digit('6')]),
            row([digit('7'), digit('8'), digit('9')]),
            row([
              l.prefs.useBiometric ? _key(context, icon: Icons.fingerprint_rounded, onTap: l.tryBiometric) : _key(context),
              digit('0'),
              _key(context, icon: Icons.backspace_outlined, onTap: () => setState(() => _pin = _pin.isEmpty ? '' : _pin.substring(0, _pin.length - 1))),
            ]),
            const SizedBox(height: 16),
            SizedBox(width: 220, child: FilledButton(onPressed: _pin.length >= 4 ? _enter : null, child: const Text('Unlock'))),
          ]),
        ),
      ),
    );
  }
}

/// Asks for a new PIN twice. Returns it, or null when cancelled.
Future<String?> askNewPin(BuildContext context) {
  final a = TextEditingController();
  final b = TextEditingController();
  String? err;
  return showDialog<String>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) => AlertDialog(
        title: const Text('Choose a PIN'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: a, autofocus: true, obscureText: true, keyboardType: TextInputType.number, maxLength: 8, decoration: const InputDecoration(labelText: 'PIN (4 to 8 digits)', counterText: '')),
          const SizedBox(height: 10),
          TextField(controller: b, obscureText: true, keyboardType: TextInputType.number, maxLength: 8, decoration: InputDecoration(labelText: 'Repeat the PIN', counterText: '', errorText: err)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(64, 44)),
            onPressed: () {
              if (!RegExp(r'^\d{4,8}$').hasMatch(a.text)) {
                set(() => err = 'Use 4 to 8 digits');
                return;
              }
              if (a.text != b.text) {
                set(() => err = 'The two PINs are different');
                return;
              }
              Navigator.pop(c, a.text);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
}
