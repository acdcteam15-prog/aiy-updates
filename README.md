# AIy

Personal AI assistant and coding helper for Android. Built the same way as Dishy: a Flutter app plus a Windows
wizard that installs everything, sets up Firebase, builds the APK and publishes updates.

## Build it (owner, once)

1. Unzip this folder anywhere on the Windows PC (for example `C:\AIy`).
2. Double-click **START-HERE.bat** and choose **1. Full setup**. It resumes where it stopped if you close it.
   - It installs Git, Node, Java, Flutter, the Android SDK and the Firebase CLI into `C:\AIyBuild`.
   - It creates a Firebase project on the free plan and switches on Google sign-in.
     One manual click is needed in the Firebase console (enable the Google provider); the wizard opens the page and checks it.
   - Optional: it asks for a GitHub OAuth **Client ID** so the app can show a one-tap "Connect GitHub" button
     (github.com/settings/developers > New OAuth App > tick "Enable Device Flow"). Press Enter to skip:
     people can then paste a GitHub token instead.
   - Optional: a public GitHub repository `aiy-updates` + token for in-app updates (same as Dishy).
3. The APK is in `C:\AIyBuild\Output\AIy-latest.apk`. **Copy `Output\keystore-backup` somewhere safe.**

Later versions: replace the `app` folder (and `setup`, when it changed) and double-click **Rebuild-APK.bat**.

| File | What it does |
|---|---|
| START-HERE.bat | Menu: full setup, rebuild, health check, fix Google sign-in, read crash log |
| Rebuild-APK.bat | One-click rebuild + publish the update |
| Publish-Update.bat | Publish the last build again without rebuilding |
| Read-Crash-Log.bat | Read a crash from a phone over USB |
| Sign-In-Firebase.bat | Manual Firebase sign-in when the browser does not open |

## What the people who get the app do

1. Install the APK, tap **Continue with Google**.
2. Follow the setup inside the app. Same Google account everywhere:
   - **Gemini**: tap "Get my free key", create the key, copy it, come back. AIy takes it from the clipboard.
   - **OpenRouter**: tap "Connect", choose "Continue with Google", tap Authorize, switch back to AIy.
   - **Groq** (optional): like Gemini.
   - **GitHub** (optional): tap "Connect", type the short code on GitHub.

Nothing else to install. No server: everything runs on the phone.

## How it works

- **Keys** are encrypted with a key held in the Android Keystore and never leave the phone except to the service they belong to.
- **Chat** tries Gemini (flash, then flash-lite), then Groq, then OpenRouter's free models. Model names are fetched
  from each service once a day, so retired names do not break the app.
  Answers are streamed (server-sent events), so the text appears while it is written; Stop keeps what arrived.
  When a service does not report token counts while streaming, the spending log uses an estimate (about 4 letters per token).
- **OpenRouter errors** open a pop-up (plain explanation, Details, Copy, Retry, Switch model). Switching to a paid model always
  shows its price first. Chat only ever offers free models.
- **Share into AIy.** The wizard adds `SEND` / `SEND_MULTIPLE` filters to MainActivity (text, images, PDF, zip). The shared
  files are copied into the app's cache, then the app asks: Chat, Code or Build.
- **Simple / Advanced** (Settings). Simple hides model names and the "which AI answers" menu. **Chat folders** live in the menu.
- **Code**
  1. The zip is scanned on the phone. `node_modules`, `.git`, `build`, `.gradle`, `dist`, `__pycache__`, media and
     other heavy files are skipped; only the clean source tree is read.
  2. A project map (file tree + import lines) goes to a free model, which answers with the list of files to change.
  3. You pick any OpenRouter model. AIy shows the estimated cost and the most it can cost, and refuses anything over
     your limit per request (Settings > Coding).
  4. Only the chosen files are sent. The model answers with search/replace blocks and a plain-English summary.
  5. The blocks are applied and checked (JSON parse; bracket, quote and comment balance for JS/TS, Python,
     Kotlin/Java, CSS and others; tag balance for HTML). If something is wrong, the exact problems go back to the
     model once.
  6. A complete new zip is written: the original zip with the changed files swapped in. Or open a pull request.
- **Build** (an app from an idea): the idea, the number of questions, name/icon/colours, the questions (one at a time, adaptive),
  the brief, then the code. A free model plans the files; the OpenRouter model you choose writes them as complete files
  (`### NEW FILE:` blocks). AIy then checks the project and sends any problems back once or twice. The result is a Flutter project
  with `.aiy/app_name.txt`, `.aiy/icon.png` and `.aiy/brief.md`; the GitHub workflow turns those into the app name and launcher icon.
  The finished app is also opened as the project of the Code tab, so Publish, Build and later changes all work on it.
  Written apps are plain Flutter (Material 3, shared_preferences/provider/intl/path_provider/uuid at most), offline, with no native setup.
- **Automatic repair.** `Fix and rebuild automatically` loops: model writes a fix (search/replace blocks) -> push to the same branch ->
  `aiy-check.yml` on GitHub -> on a failure the new errors go back to the model, on success the real build starts. Max 3 rounds,
  each limited by the per-request spending limit, stops early when the same first error repeats.
- **Safety.** The PIN is only a salted SHA-256; the keys stay in the Android Keystore vault; the log and the test report remove keys and tokens.
  Backups contain no keys. The app lock does not hide the app in the recent-apps list.
- **History** keeps the newest 20 changes on the phone (and, separately, the apps built on GitHub).
- **Build on GitHub** (Code > Publish)
  1. *Push to GitHub*: the changed files are committed with GitHub's API (a zip can also create a new repository).
  2. *Build the app*: AIy looks at the repository, asks for the **version**, writes it into the project (and raises the build number),
     adds the build workflow if the repository has none, starts it, and follows it step by step.
  3. When it finishes, the APK is downloaded: **Install**, **Save**, **Share**, or publish it as a **GitHub Release**.
  4. If it fails, **Fix it with AI** turns the errors into a repair request.
  Supported: Android (Gradle, e.g. Kotlin/Compose) and Flutter projects. Other repositories work only if they already have a
  workflow that can be started by hand and uploads an artifact with an APK in it.
  A Flutter project that needs the PC wizard's native patches (like AIy and Dishy themselves) will not build on GitHub.
  Builds are debug builds (debug-signed with one fixed key kept in `.aiy/debug.keystore`), which install directly.

## Folders

```
app/lib/main.dart                 start-up
app/lib/state/                    keys, AI engine + fallback, chat store, code pipeline, GitHub, updater
app/lib/logic/                    pure logic: source filter, project map, patch parser, checker, diff
app/lib/ui/                       theme, animated widgets, screens
setup/Setup-AIy.ps1               the wizard (also writes MainActivity.kt: zip, key vault, file picker)
setup/android-res/                launcher icon and splash
```
