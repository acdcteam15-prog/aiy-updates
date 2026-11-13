import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'firebase_options.dart';
import 'state/ai.dart';
import 'state/app_builder.dart';
import 'state/app_log.dart';
import 'state/build_state.dart';
import 'state/chat_store.dart';
import 'state/code_state.dart';
import 'state/error_center.dart';
import 'state/keys.dart';
import 'state/lock.dart';
import 'state/prefs.dart';
import 'state/share_inbox.dart';
import 'state/spend.dart';
import 'state/updater.dart';
import 'ui/screens/auth_gate.dart';
import 'ui/screens/lock_screen.dart';
import 'ui/theme.dart';
import 'ui/widgets/error_popup.dart';

Future<void> main() async {
  // Any startup problem shows a readable error screen instead of closing the app.
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    await AppLog.init();
    FlutterError.onError = (d) {
      AppLog.i('Flutter error: ${d.exceptionAsString()}');
      FlutterError.presentError(d);
    };
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarContrastEnforced: false,
    ));
    try {
      await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    } catch (e, st) {
      runApp(StartupErrorApp(error: 'Firebase could not start.\n\n$e\n\n$st'));
      return;
    }
    final prefs = await LocalPrefs.load();
    final keys = KeyVault();
    await keys.load();
    final engine = AiEngine(keys, prefs);
    final spend = SpendLog();
    await spend.load();
    final code = CodeState(engine, keys, prefs, spend);
    final builder = AppBuilder(engine, keys, prefs, code, spend);
    final inbox = ShareInbox();
    ErrorCenter.presenter = showAiProblem;
    runApp(MultiProvider(
      providers: [
        ChangeNotifierProvider<LocalPrefs>.value(value: prefs),
        ChangeNotifierProvider<KeyVault>.value(value: keys),
        Provider<AiEngine>.value(value: engine),
        ChangeNotifierProvider<ChatStore>(create: (_) => ChatStore(engine, prefs)),
        ChangeNotifierProvider<CodeState>.value(value: code),
        ChangeNotifierProvider<AppBuilder>.value(value: builder),
        ChangeNotifierProvider<ShareInbox>.value(value: inbox),
        ChangeNotifierProvider<SpendLog>.value(value: spend),
        ChangeNotifierProvider<LockService>(create: (_) => LockService(prefs)),
        ChangeNotifierProvider<BuildState>(lazy: false, create: (_) => BuildState(code, keys, prefs)),
        ChangeNotifierProvider<UpdateService>(lazy: false, create: (_) => UpdateService(prefs)),
      ],
      child: const AiyApp(),
    ));
    // Something shared into AIy from another app (also when AIy was closed): ask the phone once at the start.
    inbox.start();
    // Model names change often: fetch each service's current list in the background (once a day).
    for (final p in const ['gemini', 'groq', 'openrouter']) {
      unawaited(engine.refreshModels(p));
    }
  }, (error, stack) {
    AppLog.i('Uncaught: $error');
    debugPrint('Uncaught: $error\n$stack');
  });
}

/// Shown when the app cannot start (e.g. a Firebase config problem), with the real error.
class StartupErrorApp extends StatelessWidget {
  final String error;
  const StartupErrorApp({super.key, required this.error});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: const Color(0xFF4F6BFF), brightness: Brightness.dark),
      home: Scaffold(
        appBar: AppBar(title: const Text('AIy - startup error')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          const Text('AIy could not start. Please send this text to the person who gave you the app.'),
          const SizedBox(height: 12),
          FilledButton.icon(
            icon: const Icon(Icons.copy_rounded),
            label: const Text('Copy'),
            onPressed: () => Clipboard.setData(ClipboardData(text: error)),
          ),
          const SizedBox(height: 12),
          SelectableText(error, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        ]),
      ),
    );
  }
}

class AiyApp extends StatefulWidget {
  const AiyApp({super.key});
  @override
  State<AiyApp> createState() => _AiyAppState();
}

class _AiyAppState extends State<AiyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    final lock = Provider.of<LockService>(context, listen: false);
    if (s == AppLifecycleState.paused) lock.paused();
    if (s == AppLifecycleState.resumed) lock.resumed();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<LocalPrefs>();
    final locked = context.watch<LockService>().locked;
    final seed = presetAt(p.preset).seed;
    return MaterialApp(
      title: 'AIy',
      navigatorKey: ErrorCenter.navKey,
      debugShowCheckedModeBanner: false,
      theme: buildTheme(seed, Brightness.light, false),
      darkTheme: buildTheme(seed, Brightness.dark, p.amoled),
      themeMode: p.themeMode,
      builder: (c, child) {
        final mq = MediaQuery.of(c);
        return MediaQuery(
          data: mq.copyWith(
            textScaler: TextScaler.linear(mq.textScaler.scale(1) * p.fontScale),
            disableAnimations: mq.disableAnimations || p.reduceMotion,
          ),
          child: Stack(children: [
            child ?? const SizedBox.shrink(),
            if (locked) const Positioned.fill(child: LockScreen()),
          ]),
        );
      },
      home: const AuthGate(),
    );
  }
}
