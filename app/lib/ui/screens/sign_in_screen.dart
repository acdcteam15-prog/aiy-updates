import 'package:flutter/material.dart';

import '../../state/auth_service.dart';
import '../widgets/common.dart';
import '../widgets/fx.dart';

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});
  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  bool _busy = false;
  AuthFailure? _error;

  Future<void> _google() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AuthService.signInGoogle();
    } on AuthFailure catch (e) {
      if (mounted && e.code != 'cancelled' && e.code != 'google-12501') setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      body: AuroraBackground(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(children: [
              const Spacer(flex: 3),
              const Appear(child: Orb(size: 112)),
              const SizedBox(height: 28),
              Appear(delay: 120, child: Text('AIy', style: t.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w600))),
              const SizedBox(height: 8),
              Appear(
                delay: 220,
                child: Text('Your personal AI assistant\nand coding helper', textAlign: TextAlign.center, style: t.textTheme.titleMedium?.copyWith(color: t.colorScheme.onSurfaceVariant, fontWeight: FontWeight.w400)),
              ),
              const Spacer(flex: 4),
              if (_error != null) ...[
                ErrorBox('${_error!.meaning}\n(code: ${_error!.code})', onClose: () => setState(() => _error = null)),
                const SizedBox(height: 16),
              ],
              Appear(
                delay: 340,
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _google,
                    icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.login_rounded),
                    label: const Text('Continue with Google'),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text('One Google account is all you need.', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
              const SizedBox(height: 28),
            ]),
          ),
        ),
      ),
    );
  }
}
