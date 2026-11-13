# AIy - changes

## 1.4.0 - answers as they are written, sharing into AIy, error pop-ups, a clearer look
- **Answers appear word by word** in Chat, Ask about this project, Explain this codebase, the app brief and the Build-tab questions. A square **Stop** button ends a chat answer; what arrived stays.
- **Progress while code is written:** the patch shows how many lines have arrived, and the Build tab shows which file is being written.
- **OpenRouter problems open a pop-up** wherever you are: what happened in plain words, what to try, Details and Copy, **Retry** and **Switch model**. Where you chose the model yourself (Code, Build) the picker opens and the price is shown before anything is sent; in Chat you choose which AI answers (free models only).
- **Share into AIy:** AIy is in Android's Share menu for text, photos, PDFs and zips. It asks each time: **Chat** (attach it), **Code** (a zip opens as the project, a picture becomes the photo of the problem, text becomes the request) or **Build** (text becomes the idea of a new app).
- **The orb shows what AIy is doing:** idle, listening (rings), thinking (fast spin), writing, reading aloud (swelling).
- **Welcome tour:** three short screens after the first sign-in, with Skip. Again from Settings > Help.
- **Simple or Advanced** (Settings): Simple is the default and hides the "which AI answered" badge, the "which AI answers" menu in chat and the list of models in use. Prices are still always shown before money is spent.
- **Chat folders:** make folders in the menu, move chats into them, rename or delete a folder (its chats stay). The search box works inside the chosen folder.
- **Answer actions:** long-press an answer, or tap the three dots under it: Copy, **Answer again with another model**, and in Advanced mode "Choose which AI answers" (also a free OpenRouter model of your choice).
- **Step lists** with ticks while an app is written (plan, write, check, zip) and on the GitHub build screen (send, build, download, install).
- The wizard adds the share entries to the Android manifest and the share code to MainActivity. **Run Rebuild-APK.bat** so they are applied.
- Not built: haptics, sounds and a separate large-text switch (not wanted; the text-size slider in Settings stays).

## 1.3.1 - dependencies brought up to date
- `firebase_core` 3 -> 5.1, `firebase_auth` 5 -> 7.0, `google_sign_in` 6 -> 7.2, `local_auth` 2 -> 3.0, `flutter_lints` 4 -> 6. The other packages were already current; the transitive ones follow by themselves.
- **Code changes for the new APIs:** Google sign-in now initialises once and uses `authenticate()` (it throws, also on cancel; only an ID token is returned, which is all Firebase needs) with structured error codes; the fingerprint lock uses the new named parameters of `local_auth` 3.
- **The wizard now sets minSdk 24** (Firebase BoM 35 and `local_auth` 3 need Android 7.0 or newer). Rebuild re-applies it to projects built before.
- `flutter_lints` 6 adds new checks, so `analyze-report.txt` may list more hints than before. They do not stop the build.

## 1.3.0 - smarter builds, reliability, chat and code upgrades, safety
**Smarter builds**
- **Fix and rebuild automatically:** after a failed build or check, the model you choose writes a fix, AIy pushes it, checks it on GitHub, and repeats up to 1-3 times; when the check passes, the real build starts. Every fix is limited by your spending limit, the cost is shown first, and it stops if the same error comes back twice.
- **Quick check:** compiles / analyzes the code on GitHub in about 2 minutes without building the APK (Flutter: `flutter analyze`; Android: Kotlin compile). Workflow `.github/workflows/aiy-check.yml` is added when needed.
- **Screens checklist** in the app brief: untick a screen to leave it out of the first version, tap to put it back.
- **Ready ideas** (habit tracker, expense log, quiz, shopping list, notes, countdown): one tap fills the description and the number of questions.

**Reliability and cost**
- **Settings > Help > Test everything:** checks the version, internet, key vault, storage, the zip engine (creates, reads and rebuilds a test zip), every key, GitHub's permissions, the model lists and installing apps. Copy the report (no keys in it).
- **Log:** the last few hundred things AIy did, keys removed; copy, share or clear.
- **Spending:** real cost of the paid requests (from the token counts), this month and in total, per app; OpenRouter's usage and credit for the key.

**Chat and Code**
- **Ask about this project** (Code tab): plain-English questions; AIy reads the map and the files it needs. Nothing is changed.
- **Photo of the problem:** a vision model describes the screenshot once; the description goes with the request to any model.
- **Chat:** choose which AI answers first, standing instructions, edit a message and ask again (long-press), answer again, read aloud with the phone's voice, attach a text/code file or a PDF (PDF: Gemini), share a chat.
- **Undo the push:** puts the branch back to how it was, until the next build or push.

**Safety and polish**
- **App lock:** PIN (stored only as a salted hash) and optional fingerprint; lock after 0 / 30 s / 1 / 5 minutes; a wrong-PIN delay.
- **Backup and restore** of chats, app ideas, history, spending and settings in one file. Keys are never in it.
- **Notification** when a build or check finishes while AIy is in the background (Android 13+ asks once).
- **QR code** for a release page, on the finished build and in History > Apps.

## 1.2.0 - the Build tab (an app from an idea)
- New **Build** tab beside Chat and Code. Tap **+** (or "Start a new app").
  1. **Explain your app** in your own words (voice typing works), and set **how many questions** AIy should ask with a 1-30 slider.
  2. **Name, icon and colours:** pick the app name (or tap Suggest), one of four icon styles with a live preview, one of six colour themes, and Auto / Light / Dark. The built app gets all of it, including the launcher icon and the name under it.
  3. **Questions, one at a time**, each with tappable suggested answers, a box to type or speak your own, **You decide**, and Back. The AI chooses each next question from your idea and your earlier answers.
  4. **The app brief:** a plain-English summary (screens, data, look). Edit it, or have it written again.
  5. **Write the app:** you pick the OpenRouter model and see the cost first. A free model plans the files, your model writes them, then AIy checks the project (brackets and quotes, missing files, imports that point nowhere, packages not in pubspec.yaml) and asks the model to fix problems, up to two more times. The total can never go above your limit per request (Settings > Coding).
  6. **Done:** file list with viewer, Save the zip, Share, **Keep improving in Code**, or **Publish** (push to a new GitHub repository, then Build the app with the version question, as before). You decide each time.
- **Your apps and ideas:** every unfinished idea and every written app is kept on the phone. Come back later and continue where you stopped.
- Flutter apps only. The build workflow now names the app and installs the icon you chose.
- The top bar shows the chosen tab with its name and the other two as icons, so three tabs fit on a small phone.

## 1.1.0 - Push to GitHub and build the app there
- **Publish** (Code tab, after a change): push the changed files to a repository, then **Build the app**.
  - A project that came from a zip can go to an existing repository or to a NEW one (the whole project is uploaded, heavy folders skipped, pictures and the Gradle wrapper included).
  - Commit straight into a branch, or onto a new branch and open a pull request. The build runs on the branch you pushed.
- **Version question before every build**: the version is written into the project (version.properties, build.gradle(.kts), pubspec.yaml or package.json, whichever the project uses), so the built app shows it. The build number goes up each time, so every build installs over the last one. Quick choices: same, small fix, new feature, big change.
- The build runs as a GitHub Actions workflow (added automatically as `.github/workflows/aiy-build.yml` for Android Gradle and Flutter projects, or an existing workflow that can be started by hand is used). It is free for public repositories and within GitHub's free minutes for private ones.
- **One fixed signing key** is created on the first build and saved in the repository (`.aiy/debug.keystore`), so a new build installs over the old one without uninstalling. In a public repository that key is public: fine for your own apps, not for Play Store releases.
- Live build screen with the steps, **Cancel**, **Install**, **Save to Downloads**, **Share**, and optionally a **GitHub Release** (a download page you can share).
- A build keeps running if you close AIy; AIy picks it up again when you open it.
- **Failed build**: the real errors are picked out of the log. **Fix it with AI** sends them, with the files they point to, to the model you choose (cost shown first, same limit), then push and build again.
- **History > Apps**: the newest 3 apps of each repository stay on the phone, ready to install again.
- Connecting GitHub now asks for the "workflow" permission too (needed to start builds). If GitHub was connected before, disconnect and connect it again; the test button says so.

## 1.0.0
First version.
- Chat with automatic free fallback: Gemini, then Groq, then OpenRouter's free models. A badge shows who answered.
- Photos, voice typing and live internet search (Gemini).
- Code: upload a project zip or open a GitHub repository, explain the codebase, describe a change, pick any OpenRouter model, see the cost first, get a checked patch, a colour diff, a complete new zip or a pull request.
- Build history with one-tap restore.
- Keys stay encrypted on the phone. One Google account for everything.
