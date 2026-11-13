import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/keys.dart';
import '../../state/prefs.dart';
import '../widgets/fx.dart';
import 'connect_screen.dart';
import 'home_shell.dart';
import 'sign_in_screen.dart';
import 'tour_screen.dart';

/// Signed out -> sign-in. Signed in but nothing connected yet -> the setup steps. Otherwise the app.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (c, snap) {
        Widget child;
        if (snap.connectionState == ConnectionState.waiting) {
          child = const Scaffold(key: ValueKey('splash'), body: Center(child: Orb(size: 88)));
        } else if (snap.data == null) {
          child = const SignInScreen(key: ValueKey('signin'));
        } else {
          final prefs = c.watch<LocalPrefs>();
          final keys = c.watch<KeyVault>();
          // The tour is for people who are new: anyone who already finished the setup has seen enough.
          if (!prefs.tourSeen && !prefs.onboarded) {
            child = const TourScreen(key: ValueKey('tour'));
          } else {
            child = (!prefs.onboarded || !keys.canChat) ? const ConnectScreen(key: ValueKey('setup'), firstRun: true) : const HomeShell(key: ValueKey('home'));
          }
        }
        return AnimatedSwitcher(duration: const Duration(milliseconds: 450), switchInCurve: Curves.easeOutCubic, child: child);
      },
    );
  }
}
