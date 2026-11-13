import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../firebase_options.dart';

/// A sign-in failure with the REAL code and a plain meaning.
class AuthFailure implements Exception {
  final String code;
  final String meaning;
  final String raw;
  AuthFailure(this.code, this.meaning, [this.raw = '']);
  @override
  String toString() => '$code: $meaning';
}

class AuthService {
  static final _auth = FirebaseAuth.instance;

  static bool _ready = false;

  /// google_sign_in 7 must be initialised exactly once, and awaited, before anything else.
  static Future<void> _init() async {
    if (_ready) return;
    const web = DefaultFirebaseOptions.googleWebClientId;
    await GoogleSignIn.instance.initialize(serverClientId: web.isEmpty ? null : web);
    _ready = true;
  }

  static Future<void> signInGoogle() => _wrap(() async {
        await _init();
        // v7: authenticate() throws GoogleSignInException (also when the person cancels) instead of returning null.
        final acc = await GoogleSignIn.instance.authenticate();
        final idToken = acc.authentication.idToken;
        if (idToken == null) {
          throw AuthFailure('no-id-token',
              'Google returned no ID token. The Google provider or the web client ID is not set up - tell the app owner (START-HERE option 6 fixes it).');
        }
        await _auth.signInWithCredential(GoogleAuthProvider.credential(idToken: idToken));
      });

  static Future<void> signOut() async {
    try {
      await _init();
      await GoogleSignIn.instance.signOut();
    } catch (_) {}
    await _auth.signOut();
  }

  static Future<T> _wrap<T>(Future<T> Function() f) async {
    try {
      return await f();
    } on AuthFailure {
      rethrow;
    } on FirebaseAuthException catch (e) {
      throw AuthFailure(e.code, _firebaseMeaning(e.code), e.message ?? '');
    } on GoogleSignInException catch (e) {
      throw _googleException(e);
    } on PlatformException catch (e) {
      throw _googleFailure(e);
    } catch (e) {
      throw AuthFailure('unknown', 'Unexpected error.', '$e');
    }
  }

  static String _firebaseMeaning(String code) {
    switch (code) {
      case 'invalid-credential':
      case 'wrong-password':
      case 'INVALID_LOGIN_CREDENTIALS':
        return 'Email or password is wrong.';
      case 'user-not-found':
        return 'No account with this email.';
      case 'email-already-in-use':
        return 'An account with this email already exists - sign in instead.';
      case 'weak-password':
        return 'Password is too weak (use at least 6 characters).';
      case 'invalid-email':
        return 'The email address is not valid.';
      case 'network-request-failed':
        return 'No internet connection, or Google services are blocked on this network.';
      case 'too-many-requests':
        return 'Too many attempts. Wait a few minutes and try again.';
      case 'operation-not-allowed':
        return 'This sign-in method is not enabled in Firebase. Tell the app owner (START-HERE option 3, Health check).';
      case 'user-disabled':
        return 'This account was disabled in the Firebase console.';
      case 'account-exists-with-different-credential':
        return 'This email already uses another sign-in method (email/password). Sign in with that.';
      case 'app-not-authorized':
      case 'invalid-api-key':
        return 'The app is not authorized for this Firebase project (wrong config or SHA-1). Tell the app owner (START-HERE option 6 fixes it).';
      default:
        return 'Firebase error.';
    }
  }

  /// google_sign_in 7 reports structured codes instead of `ApiException: n`.
  static AuthFailure _googleException(GoogleSignInException e) {
    final raw = '${e.code.name} ${e.description ?? ''} ${e.details ?? ''}';
    switch (e.code) {
      case GoogleSignInExceptionCode.canceled:
        return AuthFailure('cancelled', 'Sign-in was cancelled.', raw);
      case GoogleSignInExceptionCode.interrupted:
        return AuthFailure('google-interrupted', 'Sign-in was interrupted. Try again.', raw);
      case GoogleSignInExceptionCode.uiUnavailable:
        return AuthFailure('google-ui-unavailable', 'Google could not show its sign-in window. Keep AIy in front and try again.', raw);
      case GoogleSignInExceptionCode.clientConfigurationError:
      case GoogleSignInExceptionCode.providerConfigurationError:
        return AuthFailure('google-config',
            'DEVELOPER_ERROR - this app\'s SHA-1 fingerprint, package name or web client ID is not registered in Firebase, or the Google provider is off. Also check that a Google account is added on this phone. Tell the app owner (START-HERE option 6 fixes it).', raw);
      default:
        if (raw.toLowerCase().contains('network')) {
          return AuthFailure('google-network_error', 'NETWORK_ERROR - no internet, or Google services are blocked on this network.', raw);
        }
        return AuthFailure('google-${e.code.name}', 'Google Sign-In failed.', raw);
    }
  }

  /// Older plugin versions reported `ApiException: n` inside the message.
  static AuthFailure _googleFailure(PlatformException e) {
    final text = '${e.code} ${e.message ?? ''} ${e.details ?? ''}';
    final m = RegExp(r'ApiException:\s*(\d+)').firstMatch(text);
    final n = m?.group(1);
    const meanings = {
      '10': 'DEVELOPER_ERROR - this app\'s SHA-1 fingerprint or package name is not registered in Firebase, or the Google provider is off. Tell the app owner (START-HERE option 6 fixes it).',
      '12500': 'SIGN_IN_FAILED - Google provider is not fully configured (support email missing?). Tell the app owner (START-HERE option 6 fixes it).',
      '12501': 'Sign-in was cancelled.',
      '16': 'Sign-in was cancelled.',
      '7': 'NETWORK_ERROR - no internet, or Google services are blocked on this network.',
      '8': 'INTERNAL_ERROR - Google Play services problem. Update Play services and retry.',
      '4': 'SIGN_IN_REQUIRED - pick an account and try again.',
    };
    if (n != null) {
      return AuthFailure('google-$n', meanings[n] ?? 'Google Sign-In error $n.', text);
    }
    if (e.code == 'network_error') {
      return AuthFailure('google-network_error', meanings['7']!, text);
    }
    return AuthFailure('google-${e.code}', 'Google Sign-In failed.', text);
  }
}
