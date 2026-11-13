# AIy: handover for a new chat

Version at handover: **1.4.0** (project zip `AIy-v1_4_0.zip`). Read this whole file first.

## 1. What AIy is (30 seconds)
An Android app for **non-technical people**: one Google sign-in, then three tabs.
- **Chat**: assistant with photos, files (text, PDF via Gemini), voice, live search (Gemini), free-model fallback chain.
- **Code**: open a project zip (up to 100 MB) or a GitHub repo; a free model picks the files; the owner picks any OpenRouter model (cost shown first, capped); the patch is applied and checked on the phone; result as a zip or pushed to GitHub; GitHub Actions builds the APK; auto-fix loop for failed builds.
- **Build**: describe an app, the AI asks N questions (slider 1-30), writes a brief, a chosen model writes a **Flutter** app, which then flows into Publish/Build/Code.

Built "the same way as Dishy": Flutter app + a **Windows wizard** (`setup/Setup-AIy.ps1` + `START-HERE.bat`) that installs tools, creates the Firebase project (free plan, Google sign-in only), patches Android files, builds and signs the APK and publishes updates. **There is no backend**: everything runs on the phone; every user brings their own keys (Gemini, OpenRouter, optional Groq, optional GitHub), stored encrypted in the Android Keystore.

## 2. State at handover: what is verified and what is NOT
Verified in the sandbox: Dart analyzer **0 errors** against the real Flutter 3.50 framework sources with hand-written plugin stubs (the 1.3.1 stubs follow the real google_sign_in 7 / local_auth 3 signatures, read from GitHub); unit tests for all pure logic (patch parser/applier, syntax checker, diff, versioning, workflow YAML validity, build-log parser, app-generation checks, brief screens, redaction, PIN hashing); the wizard script parses and its manifest/Gradle/owner-config patch functions run on a mock project (idempotent).

**NOT verified: nothing has been built into an APK or run on a phone.** The Kotlin in the wizard (`$MainActivityKotlin`) has never been compiled (only brace-balanced). No live call to Gemini, Groq, OpenRouter or GitHub was made. The GitHub Actions workflows never ran. Sign-in with google_sign_in 7, the fingerprint lock, notifications, read-aloud, QR codes, backup/restore are untested on a device. Expect the first real build to show some errors: **ask the owner for `Output\build-error.txt` / `Output\analyze-report.txt` and the on-phone "Test everything" report.**

### Added in 1.4.0 (see CHANGES.md)
Streaming (`Net.sse`, `AiEngine` `onText` / `AiCancel`; Gemini `streamGenerateContent?alt=sse`, OpenAI-style `stream: true`), structured `ApiError` (provider, model, detail, causes), `state/error_center.dart` + `ui/widgets/error_popup.dart` (OpenRouter pop-up, `ErrorCenter.navKey` is the app's navigator key), share-to-AIy (`ShareInbox`, `Native.takeShared` / `onShared`, Kotlin `handleShare` + manifest `aiy-share-filters`), `OrbMode`, `TourScreen`, `prefs.advanced`, chat folders (`Conversation.folder`, `prefs.folders`), `prefs.chatOrModel`, `ui/widgets/timeline.dart`, `AppBuilder.phase/liveText`, `CodeState.explainLive/askLive`.
1.4.0 checks in the sandbox: analyzer run against Flutter **master** sources (not 3.50) WITHOUT plugin stubs (errors that only come from missing plugins were filtered out): no errors in app code; 11 logic tests pass under a home-made runner (incl. an SSE test with a local server); manifest patch run twice on a mock manifest with pwsh (idempotent, verifier true); Kotlin only brace-balanced. **Still nothing built or run on a phone, no live API call.** Known doubts: long-press on answer text vs text selection; real streaming formats; `onNewIntent(intent: Intent)` signature.

## 3. How the owner works (follow this)
- Wants **complete project zips** (like Dishy, Obdy, Filtery, Remoty) named `AIy-v<major>_<minor>_<patch>.zip`, built on his Windows PC with `START-HERE.bat` / `Rebuild-APK.bat`.
- Before any big feature he wants **suggestions first, then pop-up questions** (the `ask_user_input_v0` tool, max 3 per call, usually 6-9 in rounds), then the build.
- English-only UI. Modern look, animations, themes; the look follows the Gemini app (dark AMOLED, glowing bottom, orb).
- Things must be done **inside the app** for non-technical users, with one Google account wherever possible.
- He pastes tool output (pub get, build errors) and expects the fix in a new zip. Keep chat replies short and plain; do not claim anything was tested that was not.

## 4. Decisions already made
- Processing on the phone (no Cloud Functions); Google sign-in required; guided key setup (OpenRouter via OAuth PKCE button, GitHub via device flow if the owner gave a Client ID, Gemini/Groq via clipboard pick-up).
- Themes: dark + light + 6 colour presets (Midnight, Aurora, Sunset, Rose, Forest, Graphite), AMOLED option.
- Fallback chain: Gemini (flash, flash-lite) -> Groq -> OpenRouter `:free`; model names fetched live once a day; a badge shows who answered.
- Paid OpenRouter models: spending cap per request (default $0.25, Settings > Coding), estimate shown before sending, worst case never above the cap.
- Patch format: search/replace blocks (not unified diffs), applied on the phone with exact -> trailing-space -> indentation-insensitive matching; checker = brackets/quotes/JSON/HTML tags (not a compiler); one automatic repair round.
- Build tab: **Flutter only**; slider 1-30; questions one at a time with tappable answers + typing box + "You decide"; chosen model with cost shown first; at the end "ask me each time" (zip or push+build); name and icon style up front; theme/colours chosen before the questions; Projects list for unfinished ideas.
- GitHub build (ported from Remoty): commit with the Git data API, workflow `aiy-build.yml` (Gradle or Flutter) added if the repo has none, **version asked before every build** and written into the project, one fixed debug keystore saved in the repo (`.aiy/debug.keystore`) so builds install over each other, optional GitHub Release + QR code.
- All four "next" groups were built: smarter builds (auto-fix loop with `aiy-check.yml` quick check, screens checklist, starter ideas), reliability (Test everything, log, spending tracker), chat/code upgrades (ask about code, photo of problem described by a vision model, chat extras, undo push), safety (PIN + fingerprint lock, backup/restore, build notification, QR).
- 1.3.1: dependencies updated to the latest majors (see section 7).

## 5. Architecture (short)
Provider-based state (ChangeNotifier). Network: plain `dart:io` HttpClient (`Net`). Native bridge: one MethodChannel `aiy/native` implemented in **Kotlin text inside `setup/Setup-AIy.ps1`** (`$MainActivityKotlin`), written into the Flutter project by the wizard together with Manifest/Gradle patches (all idempotent, each with a `Test-*` verifier; minSdk is 24).
Native methods: buildInfo, canInstallApks, openInstallSettings, installApk, secretGet/secretSet (AES-GCM, Keystore), openUrl, pickZip, pickFile, zipScan, zipRead, zipRebuild, zipCreate, zipBytes, zipExtractFirst, saveToDownloads, speak, stopSpeaking, notify, requestNotifications.
On-phone files under the app documents folder `aiy/`: chats.json, history.json, spend.json, apks.json, log.txt, projects/*.json, builds/*.zip, apks/*.apk, img/.
Flows: Chat -> `AiEngine.chat` (chain). Code -> `CodeState` (open zip, project map, route, patch, heal, zip rebuild) -> `BuildState` (push, check, build, watch, download APK, release, auto-fix loop, undo, resume after app close) . Build tab -> `AppBuilder` (questions, brief, plan, generate, check, zip) -> adopts the result into `CodeState` so Publish/Build/Code work on it.

## 6. File map (`app/lib`)
- `main.dart` start-up, providers, lock overlay, error log. `firebase_options.dart` and `owner_config.dart`: placeholders the wizard overwrites.
- `logic/` (pure, unit-tested): `patcher.dart` (parse/apply blocks, structure check, line diff), `project.dart` (source filter, project map, upload filter), `versioning.dart`, `workflows.dart` (build + check workflow YAML), `buildlog.dart` (errors from logs, incl. `flutter analyze`), `appgen.dart` (Build-tab prompts, plan/question parsing, `checkProject`, `fixPubspec`), `brief.dart`, `starters.dart`, `redact.dart`, `pin.dart`.
- `state/`: `ai.dart` (engine, fallback chain, models, credit, test), `chat_store.dart`, `code_state.dart`, `build_state.dart`, `app_builder.dart`, `github.dart`, `connect.dart` (OpenRouter PKCE, GitHub device flow), `keys.dart`, `prefs.dart`, `native.dart`, `net.dart`, `auth_service.dart`, `lock.dart`, `backup.dart`, `spend.dart`, `app_log.dart`, `updater.dart`.
- `ui/theme.dart`; `ui/widgets/` (`fx.dart` animations, `markdown.dart`, `common.dart`, `icon_maker.dart`, `qr_dialog.dart`); `ui/screens/` (`home_shell`, `chat_view`, `code_view`, `build_view`, `build_screen`, `publish_panel`, `publish_sheet`, `autofix_sheet`, `ask_code_screen`, `diff_screen`, `model_picker`, `history_screen`, `settings_screen`, `connect_screen`, `diagnostics_screen`, `log_screen`, `lock_screen`, `sign_in_screen`, `auth_gate`).
- `test/widget_test.dart` pure-logic tests. `setup/Setup-AIy.ps1` the wizard (2.7k lines, Dishy-derived). `setup/android-res/` icons. `docs/deck-src/` generator of the user-guide deck.

## 7. External facts and gotchas
- OpenRouter OAuth: browser to `openrouter.ai/auth?callback_url=http://localhost:3000/callback&code_challenge=...&code_challenge_method=S256`, local listener on port 3000, then `POST /api/v1/auth/keys {code, code_verifier, code_challenge_method}`. Models: `GET /api/v1/models` (prices per token, `:free`). Key info: `GET /api/v1/key`.
- GitHub device flow needs an OAuth app **with Device Flow enabled**; scope is `repo workflow` (the `workflow` scope is needed to push workflow files). Old tokens without it get a clear message to reconnect.
- Gemini: REST `generateContent`, `tools:[{google_search:{}}]` for live search, `responseMimeType` for JSON, inline PDFs/images. Groq/OpenRouter: OpenAI-compatible chat completions.
- Workflow actions pinned by major (checkout@v5, setup-java@v5, setup-android@v3, setup-gradle@v5, upload-artifact@v5, flutter-action@v2): copied from Remoty's working workflow, not re-verified.
- **1.3.1 dependency changes:** google_sign_in 7 = `GoogleSignIn.instance.initialize(serverClientId)` exactly once, `authenticate()` throws `GoogleSignInException` (also on cancel), `authentication.idToken` only; local_auth 3 = named params `biometricOnly`, `persistAcrossBackgrounding`; firebase_core 5 / firebase_auth 7 = Firebase BoM 35, minSdk 24; flutter_lints 6 = more hints. Android older than 7.0 is no longer supported.
- Flutter projects built on GitHub: the workflow runs `flutter create --platforms android` when there is no `android/`, copies `.aiy/app_name.txt` into the label and `.aiy/icon.png` into the mipmaps. AIy and Dishy themselves need the PC wizard's native patches, so they cannot be built this way.

## 7b. Rebuilding the sandbox checks (the sandbox is gone in a new chat)
The checks used: Dart SDK from conda-forge (micromamba), a sparse `git clone` of flutter/flutter (`packages/flutter/lib`, `engine/src/flutter/lib/ui`, `sky_engine`), Dart deps cloned from GitHub (core packages, vector_math, material-color-utilities, provider, nested, meta), a fake `listen` package, hand-written stubs of every plugin, and a hand-made `package_config.json`; PowerShell 7 tarball for wizard tests; Playwright Chromium for the deck screens; pptxgenjs for decks. Rebuilding takes ~10 minutes: only worth it for large changes. Otherwise rely on the owner's real build output.

## 8. Known risks for the first build
Plugin resolution is untested beyond the owner's `pub get` (it resolved); Kotlin compile errors possible; `local_auth` may need an AppCompat theme for the biometric prompt (Dishy worked without); GitHub Actions workflow details; model names/prices come live; `flutter_lints` 6 hints; free models are slow or busy; the QR code and release page need a public repo for strangers.

## 9. Not built (ideas)
Real release signing and `.aab` (needs GitHub secrets: libsodium); hiding the app in the recent-apps list (FLAG_SECURE); text-to-speech end events; Arabic/RTL; widget tests; Build tab "stages with check-in" (the owner did not pick it); more project types for GitHub builds.

## 10. How to continue in a new chat
1. Attach `AIy-v1_4_0.zip` and this file. Unzip; the project root is `aiy/`.
2. Ask the owner for the output of his first real build (`Output\build-error.txt`, `analyze-report.txt`, `setup.log`) and the "Test everything" report; fix from those.
3. Conventions when changing code: edit under `aiy/`; bump `app/pubspec.yaml` version and `$WizardVersion` in the wizard; add a section to `CHANGES.md`; update `README.md` and the wizard's test checklist (in `Show-FinalScreen`); run the analyzer and the logic tests; deliver `AIy-v<x>_<y>_<z>.zip` and present it.
4. Keep answers short and plain; list what was NOT tested.

## 11. Delivered so far
`AIy-v1_4_0.zip` (project), `AIy-simple-guide.pptx` (made for 1.3: does not show the 1.4 features) (19-slide user guide; its screens are drawn mock-ups, not photos), and a Claude Doc "AIy: a simple guide" (https://claude.ai/artifact/BnanbYR3eeXKVYsZu5wZp6).
