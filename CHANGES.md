# AIy - changes

## 1.23.0 - free model first
- **"Try a free model first"** (on by default) in Fix and rebuild automatically, when a paid model is chosen. AIy picks the best free model by itself (a known coding family, then the biggest context, at least 32k). It gets one free try. If it fails, gives no usable fix, its edits do not match your code, its fix changes nothing, or the check still fails, AIy notes why ("Free try with X: ... Switched to Y.") and the paid model takes over for the chosen number of tries.
- The free try costs nothing. The paid rounds keep the per-request limit from Settings, and the sheet still shows the most they can cost.
- "Same errors twice" is counted per model, so the free model failing does not stop the paid one.
- If the connection drops during the free try, Continue goes on with the paid model.
- The model that actually fixed the error is the one remembered for next time.

## 1.22.0 - smarter, cheaper build repairs
- **All errors listed:** the failed step shows every error with its file and line (up to 8), not "(and 1 more)".
- **Cleaner log for the model:** a repair sends the log lines around each error (6 before, 3 after), with download and setup noise removed, instead of the last 45 lines (`errorWindows` in `logic/fixcontext.dart`).
- **Cost per round:** auto-fix shows "spent so far" while it works. When it finishes, the build notes show the total ("Fixed by X for $0.03 in total").
- **Remembers which model fixed what:** when a fix works, AIy saves the model for that kind of error (missing name, type, syntax, import, null-safety) in `aiy/fix_models.json`. The next "Fix and rebuild" picks that model and says why.
- **Faster Flutter builds:** the build and check workflows cache Gradle (`gradle/actions/setup-gradle`). The workflow mark is now **v6**, so every repository gets the new workflow on its next build by itself.
- **"Saving on GitHub"** says how many files it is saving and that big projects can take a minute or two.
- Already in place and checked: when the model's edits do not match the file, or leave broken brackets or syntax, the patcher asks the model once more with the real file.

## 1.21.2 - auto-fix sees the whole picture
- **Fixed: the same build error came back on every fix, with every model.** A repair round only sent the file the error pointed at (e.g. `camera_screen.dart`), never the file that defines the missing name (e.g. `FilterService`). The model could not see the class, so it guessed. New `logic/fixcontext.dart` now sends, within a 60k-character budget (max 24 files): the files the errors point at, the files that define every name in the errors, their imports (relative and `package:`), recently changed files, then nearby source files. The model may also edit any of them, so it can add the missing method where it belongs.
- **Fix memory:** round 2+ tells the model what the earlier rounds changed and that it did not work, so it stops repeating the same wrong fix.
- **Retry rule:** "same error" now compares the full set of errors (file + message), not only the first one. Changing or shrinking errors count as progress.
- **Fixed: auto-fix rebuilt unchanged code.** When every edit from the model pointed at lines that are not in the file, AIy still pushed and checked again. Nothing had changed, so the build failed with the same errors and that round's money was wasted. AIy now stops before pushing, and also stops when GitHub reports that the push changed nothing.
- **Fixed: stale "Details" during a fix push.** While pushing, the Details card still showed the old run ("2 of 3 GitHub steps done · 1 failed"). Steps are now cleared when a push starts.
- Not compiled here (no Dart SDK in this environment): **run Rebuild-APK.bat** and watch for analyzer errors.

## 1.21.1 - in-app update install fixed
- **Fixed:** "The update could not be downloaded: Failed to find configured root that contains .../app_flutter/aiy/updates/AIy.apk". The download worked, but Android was only allowed to hand files from `cache/updates/` to the installer. MainActivity now copies the APK there before installing, and the file-provider list also allows AIy's own updates folder.
- Phones on 1.21.0 or older still have the broken installer: **install 1.21.1 once with Rebuild-APK.bat**; in-app updates work from then on.

## 1.21.0 - visual polish
- **Your messages** have a soft two-colour gradient with a thin outline.
- **Loading the model list** shows shimmering placeholder cards instead of a spinner (`Shimmer` / `SkeletonList` in `ui/widgets/fx.dart`, ready to reuse).
- **Empty chat list / no search results** in the side menu show an icon and fade in.

## 1.20.0 - reading projects in the Code tab
- **Fixed: zips made on Windows with non-English file names** ("Send to compressed folder") could not be opened at all. AIy now opens them with the old Windows code page when UTF-8 fails.
- **Fixed: zips that store paths as `folder\file`** (some Windows tools) were read as loose files at the top, so the project folder and the map were wrong. Paths now always use `/`, also in the zip AIy gives back (no more doubled files).
- **Fixed: files that start with the invisible UTF-8 "BOM"** (common from Visual Studio / Notepad) had a hidden character at the start of their first line, so changes to the first lines could fail to apply. AIy removes it while reading and puts it back when writing the changed file.
- **Explain the project** now also finds `README`, `README.txt` and `README.rst`, not only `README.md`.
- Editor backup files (`file~`, `.swp`, `.orig`, `.bak`) are no longer read as source.
- The zip changes are in MainActivity (written by the wizard): **run Rebuild-APK.bat.** Tested: `tests/project-test.dart.txt` (8 checks). The Kotlin was not compiled here.

## 1.19.0 - tidier settings, drafts that survive, less dead code
- **Settings:** every section has a small coloured icon, and the page slides in section by section.
- **Drafts survive closing AIy:** unsent text per chat is saved a moment after you stop typing (at most 30 chats keep a draft).
- **Removed (never used anywhere):** `AiEngine.chatChain`, `AiEngine.retryable`, `Updater.downloadAndInstall`, `AppBuilder.setBrief`, and the old `docs/deck-src` slide generator (the guide deck itself was not in the project). Every Dart file is still used.

## 1.18.0 - quicker starts and clearer progress
- **Code tab: "Continue where you left off"** - the last 3 changed projects (whose zip is still on the phone) are listed under the two start buttons; tap one to open it again.
- **Build tab:** every app in "Your apps and ideas" has a small progress bar that fills to its stage (green when written), and "Start a new app" is a bold gradient card.
- **Dialogs:** the keyboard's Done key now saves in the folder / rename dialogs and the "paste a key" dialog (before, only the button did).
- Checked again: the 1.15-1.17 features (pin, rename, undo, follow-ups, drafts) against the code paths that send, retry, edit and delete; no problems found.

## 1.17.0 - follow-up questions, drafts and dates in chat
- **Follow-up questions:** under each new answer AIy shows 2-3 short "next questions" you can tap to ask. They are part of the same answer (no extra request, no extra cost). Switch: Settings > Chat > "Suggest follow-up questions". Off in Lite mode, and not shown for a stopped or failed answer.
  - How it works: the model ends with `[[follow-ups: a | b | c]]`; `logic/followups.dart` removes the tag (also while the answer is still arriving), so it is never shown or sent back. Tested: `tests/followups-test.dart.txt`.
- **Drafts per chat:** text you typed but did not send stays with its chat when you open another chat and come back.
- **Dates in chat:** small "Today", "Yesterday" or "12 Nov" labels between messages from different days.

## 1.16.0 - a new model picker
- **Model cards:** each model shows its maker, the price (or "Free"), how much it can read and a "Coding" tag; the chosen one is outlined.
- **Star models** you like: starred models come first everywhere and have their own "Starred" filter.
- **Recent:** the last 5 models you picked are shown at the top.
- **Filter by maker** (OpenAI, Anthropic, Google, DeepSeek, Qwen…) and **sort** (free and cheapest, reads the most, by name).
- In free-only places (chat fallback) the Starred filter works too, but still only shows free models.
- "Good for coding" now also knows newer families (Qwen3, Grok 4, MiniMax, MiMo).

## 1.15.0 - pin, rename, undo and small fixes
- **Pin chats:** side menu > ⋮ > Pin to top. Pinned chats sit under "Pinned" and are never removed when the 80-chat limit is reached.
- **Rename chats** from the same menu.
- **Undo delete:** deleting a chat shows "Chat deleted · Undo" for 5 seconds; its pictures are only removed after that.
- **Fixed:** the live-search button said "Live search off" when it had just been switched on (and the other way round).
- **Fixed:** deleting the chat that was still being answered lost the answer; AIy now asks you to wait or tap Stop. "Delete all chats" stops a running answer first.
- **Fixed:** the 80-chat limit could remove the chat that was open.
- **Fixed:** the Publish sheet crashed on a GitHub repository with no branches yet.
- **Look:** the greeting changes with the time of day ("Good evening, Bader"); the send button spins into the stop button and back.

## 1.14.0 - build fix and a cleaner, livelier look
- **Fixed (would stop the APK build):** a missing `;` after the Android hook text in `logic/workflows.dart` (added in 1.13.1). Dart could not compile the app.
- **Chat / Code / Build switch:** one glowing pill now slides behind the chosen tab, the icon grows a little and the name fades in.
- **Chat home:** the suggestions are soft rounded cards with a coloured icon and an arrow.
- **Long chats:** a round "newest message" button pops up when you scroll up; tap it to jump down.
- **Side menu:** chats are grouped under Today, Yesterday, Previous 7 days, Previous 30 days and Older, and slide in one after another. The menu has rounded corners.
- **Banners** (offline, slow line, health, update, paid jobs) now grow and shrink smoothly instead of making the page jump.
- **Theme polish:** rounder text boxes with a coloured outline when typing, rounded list rows, softer dividers, switches with a tick, rounded tooltips and buttons, snack bars above the bottom edge.
- Removed two unused imports (analyzer warnings).

## 1.13.1 - plugin build failures ("checkDebugAarMetadata") and no more wasted paid fixes
- **The cause:** a Flutter plugin (here `file_picker`) was built against an older Android version than its own libraries need, so GitHub stopped at `:file_picker:checkDebugAarMetadata`. The mistake is not in your files, so no model could ever fix it from them: four paid "Fix with AI" runs could only guess.
- **The real fix:** AIy's Flutter build workflow (now `v5`, replaced automatically on the next build) has a new step "Prepare the Android build". It installs a small Gradle hook that raises every plugin to Android 36 when it is lower (never the app itself). The step cannot stop the build if it fails.
- **No money spent on this kind of failure:** the build page detects plugin/Android-version problems (and a Java/Gradle mismatch, or clashing dependencies), says so in plain words, switches "Fix it with AI" off, and offers **Update and build again**. Auto-fix refuses too ("AIy did not spend any money").
- Detection lives in `environmentFailure()` in `logic/buildlog.dart`; the UI uses `BuildState.aiCannotFix`.
- Not changed: your own `build.yml` (AIy never rewrites a workflow you wrote, other than relaxing the SDK step).

## 1.13.0 - five tries before any error, and a pop-up that fits
- **AIy tries up to 5 times before an error is shown.** The first model is tried 3 times in a row (waits of 2 s and 4 s), then other models follow. In Code and Build, tries 4 and 5 use other **free** models (never a paid one, so the price you agreed to stays the maximum). With only one service connected it is tried again after waits of 8 s and 10 s. Chat goes through every connected service at least twice. The busy text shows "Try 3 of 5…" while it happens, and Stop ends it at once.
- **What is retried:** everything temporary: busy (429/5xx), timeouts, a lost line, empty answers, thinking-only answers, "too big for this model". **Not retried** (it could not change anything): a rejected key, no credit, a model that does not exist or cannot be used here.
- **Thinking models** that wrote nothing get less room to think on each new try (a quarter of the allowance, then 1,024 tokens, then "low").
- **No internet:** after the 5 tries, the job waits. When the connection is back, **free jobs continue by themselves**. **Paid jobs ask first**: a notification and a card with the model and the price (Continue / Discard), also for jobs that waited while AIy stayed open.
- **Fixed: the wrong title.** A thinking model that wrote nothing was shown as "The request is too big". It now says "The model only thought", with what to do, and the pop-up says "AIy already tried 5 times." The report has a "Tries before giving up" line.
- **Fixed: the cut-off Retry button.** The pop-up's buttons now wrap onto a second line instead of running off the screen.
- The retry rules are in `logic/retry.dart` (tested: `tests/retry-rules-test.dart.txt`).

## 1.12.0 - updates download in the background and resume
- **The AIy update downloads by itself in the background, on Wi-Fi only.** When AIy finds a new version it starts downloading without asking (switch in Settings > Update: "Download updates in the background"). A notification keeps AIy running while you use other apps and shows the percentage and speed.
- **It resumes.** If you leave AIy, it keeps going. If AIy is closed, the next start continues from the part already on the phone. If the line breaks, or you were on mobile data, it waits and continues by itself when Wi-Fi or the internet is back (it looks every 45 seconds and when you open AIy). The file is checked (size and SHA-256) before it is offered, and a damaged file is thrown away and downloaded again.
- **Ready:** a notification ("AIy X is ready to install") **and** a banner on the home screen with an **Install** button.
- **Update screen** (tap the banner, or Settings > Update): what is new in the version (shown before you install), size, speed and time left, **Pause / Resume** (a pause stays, also after a restart), **Remind me tomorrow**, **Skip this version** (not for a required update). If you are on mobile data it says so and offers "Download now (uses mobile data)".
- **What's new after updating:** the notes of the version you just installed now show once (they were collected before but never displayed).
- The update also shows as a page in Settings > Running and waiting, and as "Downloaded AIy updates" in Settings > Storage. The notification's Stop button pauses it (it continues next time).
- The wizard changed: a "connection type" call in MainActivity and the ACCESS_NETWORK_STATE permission (to tell Wi-Fi from mobile data). **Run Rebuild-APK.bat.**
- Downloads are now pausable in general (`Net.download` with a cancel token).

## 1.11.1 - builds that stopped at "Use one fixed signing key"
- **Cause:** AIy's build workflow saves a signing key into your repository with `git add`. Many Android projects ignore `*.keystore` / `*.jks` in `.gitignore`, and then `git add` refuses, the step fails, and the whole build stops before any code is built. It only happens in projects with such ignore rules, which is why it stopped for one phone and not for another.
- **Fixed:** the step uses `git add -f`, and it is now a helper that can never stop the build (`continue-on-error`): if the key cannot be saved, the build still goes on with Gradle's own debug key (the app builds; it may only not install over an older build) and a warning is shown. Same safety for the Android SDK setup step. Workflow mark is now "v4": repositories get the new workflow on the next build.
- **One tap out of a stop like this:** when a build stops in a setup step (not your code), the failed page shows **Update and build again**. It updates the workflow and builds again with the same version, notes and release choice, and nothing is spent on a model. "Fix it with AI" is hidden in that case.
- `tests/test-signing-step.sh` runs the step against four kinds of repository (plain, ignored keystore, protected branch, second build).

## 1.11.0 - apps are written in parts
- **Build tab: the app is always written in parts.** After the plan, AIy writes 2-4 files per request (2 for small models, up to 4 for models that read a lot). Every part has its own full allowance, so "thinking" models also have room to write. A part that comes back empty is tried once more on its own.
- **Linking:** every part is sent the files already written (their first lines: names, classes, functions) and the full file list, so the parts fit together. Then the whole project is checked, and up to two fix passes repair what does not fit (imports, missing classes, missing files).
- **Nothing is lost:** finished parts are kept on the phone. If writing stops (internet, limit, model), tap write again: only the missing files are written.
- If the free services cannot make the plan, the chosen model makes it.
- **Thinking limit:** OpenRouter models may use at most a quarter of the allowance for thinking (models that do not think ignore it; one that refuses is asked again without it).
- **Projects with their own build workflow** (like Filtery's build.yml): when its "setup-android" step would fail on GitHub, "Build the app" asks once whether AIy may add `continue-on-error: true` to that step. Nothing else in the file changes.

## 1.10.2 - models that cannot answer, and wrong "key rejected" messages
- **Fixed: "This model is not available" with paid and free models.** OpenRouter lists ":batch" models (e.g. GPT-5 Nano (batch), Claude Haiku (batch)) that only work for batch jobs, and some free models only work in agent apps (e.g. inkling). They are now left out of the model list, and any model that answers "cannot be used here" is hidden for good, with a clear message instead of "not found" or "key rejected". In chat, such a model no longer stops the other OpenRouter models from being tried.
- **Fixed: "The Groq key was rejected" when the key is fine.** Groq answers "Access denied. Please check your network settings" when it does not serve the country or network; AIy now says so (try another network or VPN, or use another service) instead of blaming the key.
- **Empty answers:** an empty answer from an OpenRouter model is tried once more by itself; a thinking model that used its whole allowance on thinking now says so.

## 1.10.1 - "Build the app" did nothing
- **Fixed: tapping "Build the app" stopped silently** after "Checking the project on GitHub…". The Code list rebuilt the Publish panel while GitHub was checked, and the panel then quietly dropped the rest (the version question never opened). The flow now no longer depends on the panel, and every stop is explained (a message, plus lines in Settings > Log starting with "build:").
- "Build the app" while another build or check is still running, or before a push, now says so instead of doing nothing.
- **Fixed: builds failing in GitHub's setup.** Your earlier build stopped at `android-actions/setup-android` (GitHub's computers already have the Android SDK). AIy's workflows (now "v3") let that step fail without stopping the build; repositories get the new workflow on the next build.
- When a build stops in a setup step (not in your code), AIy says so and no longer offers to pay a model to "fix" code that is fine (that was the "the failure is in your GitHub Actions workflow" answer in your log).

## 1.10.0 - one look everywhere
- **Code tab:** the small pill while AIy works is now a progress card like the job pages: steps (get the project, read, map; or read, write the change, check and repair, build the zip), the step running now with its live text and time, a shine bar and a percentage.
- **Build tab (writing an app):** the same card: plan the files, write the code, check the project, make the zip and icon.
- **Chat:** while AIy thinks, a small step card next to the orb instead of the dots.
- **Settings, Connect and every other screen:** cards and buttons use the job-page style (28 px corners, soft border, taller rounded buttons). Colours follow the theme picked in Settings; only green (done) and orange (error) are fixed.
- **Fixed:** steps GitHub skipped after a failure were shown with a green tick, and the build still said "Waiting for a GitHub computer". Skipped steps now show "(not run)", and the live line says which step failed while GitHub ends the run.
- The raw GitHub step list is folded under **Details** on the Build screen; it opens by itself when something failed.

## 1.9.0 - new job pages
- **Running and waiting** (Settings) is now one job per page: swipe between jobs, the dots on top show where you are (orange = stopped with an error, green = finished).
- Each page shows the job's steps from top to bottom. The step running now has a pulsing ring, a turning arc, a "Now" label, a live line ("what GitHub is doing", with a blinking cursor) and its time so far; the progress bar has a moving shine and a percentage.
- **Clear stop point:** when a build or check fails, the step where it stopped turns orange and shakes once, and right under it a card says *what happened*, *where* (file and line), and *what you can do*. Later steps are dashed and marked "not reached". Buttons: Fix it with AI (or Continue auto-fix), Ask AIy, Copy report.
- **Finished:** a big tick pops in and draws itself; every step shows how long it took; Install.
- The Build screen uses the same steps, error card and progress bar.
- Animations stop when the phone's "remove animations" setting is on. No wizard changes; run Rebuild-APK.bat as usual.

## 1.8.0 - control and overview
- **Turn off single changes before pushing.** In Code > a changed file, each changed part has a **Keep** switch. Turning one off puts the old lines back; the file check, the zip and the next push follow. Turned-off parts stay visible (faded), so they can be turned on again. (New files: all or nothing.)
- **Daily and monthly spending limits** (Settings > Coding, off by default), next to the one-request limit. A paid request that could go over them is refused before it starts, with what was spent so far.
- **Running and waiting** (Settings): chat answer, Code and Build tab work, the GitHub build, an auto-fix pause, everything waiting for the internet, and paid jobs from before a restart, each with Stop / Cancel / Discard.
- **Storage** (Settings): what AIy keeps (APKs, change zips, app ideas, chats, kept copies, temporary files), the phone's free space, and cleanup for APKs, kept copies and temporary files.
- **AI services health:** a service that fails twice in a row (busy, limit, too slow) is tried last for 2 minutes, after 4 failures for 10 minutes; it is still used when the others fail. A wrong key or no internet does not count. Settings > AI services health shows the counts and answer times.
- **Start-up check:** a banner when less than 300 MB is free; leftovers of cut-off saves are removed.
- The wizard changed (a new "free space" call in MainActivity). **Run Rebuild-APK.bat.**

## 1.7.1 - building on GitHub after pushing, and device hardening
- **Fixed: "Build the app" after pushing to GitHub.** GitHub only lets a workflow be started by hand ("workflow_dispatch") once the workflow file is on the repository's **default branch**. AIy added its workflow on the branch it pushed to, so builds and quick checks on any other branch could fail with "not found" or "no workflow_dispatch trigger", and right after adding the workflow GitHub often did not know it yet. Now AIy's workflows also start when a commit changes `.aiy/build-request.txt` (or `.aiy/check-request.txt`): AIy writes that file in the same commit as the version, so the build starts on **any branch**, and AIy finds the run by that exact commit. Hand-starting is only a second try. AIy's older workflow files are replaced automatically on the next build.
- Clear messages when the build cannot start: GitHub Actions switched off for the repository (with where to turn it on), a protected branch, a sign-in without the "workflow" permission, or GitHub taking longer than 4 minutes.
- A failed build that was cancelled by a newer one, or by you, is no longer mixed up with the newest run: AIy follows the run of its own commit.
- **Background notification:** if Android refuses the background service (Android 12+ started from the background, or Android 15's daily time limit) AIy now stops the service quietly instead of risking a crash; the work goes on while AIy is open.
- Three places that used the screen after waiting (could crash if you left the screen) are fixed.

## 1.7.0 - errors you can act on, and jobs that survive
- **Busy or rate-limited services are tried again.** When GitHub answers "too many requests" (429) or "busy" (500-504), AIy waits as long as GitHub asks (up to 60 seconds) and tries again, for calls that are safe to repeat. A longer wait fails at once with GitHub's message. GitHub's rate-limit message no longer tells you to reconnect. Chat keeps moving to the next service as before.
- **Safer continued downloads.** A GitHub project is downloaded by its exact commit, so a download that continues later cannot mix two versions of a branch. Without an ETag, the full file size must match, otherwise the download starts again.
- **Paid jobs ask before they continue.** A paid Code change or "write the app" job that was waiting for the internet is remembered on the phone. When AIy is opened again, a card shows the job, the model and the price, with **Continue** and **Discard**. Nothing is sent without your tap. Cards older than 3 days are dropped.
- **Auto-fix pauses on a lost connection.** It shows **Continue auto-fix (N rounds left)** and **Stop auto-fix**. If the fix was already written, Continue only pushes and checks it (the fix is not paid for twice).
- **A new error card** for unexpected and service errors in the Code and Build tabs (before, only OpenRouter had one): **Retry**, **Try another model**, **Ask AIy** (opens a new chat that explains the error) and **Copy report**.
- **Report bundle:** app version, phone, connection, the error with every attempt, notices and the last 80 log lines, with keys removed. Available on the error card and on the Log screen (clipboard icon).
- No wizard or native changes. Run Rebuild-APK.bat as usual.

## 1.6.1 - nothing is lost when something goes wrong
- **Safe saving.** Chats, history, app ideas, spending and the APK list are saved to a temporary file first and only then put in place; the previous version is kept as `.bak`. A crash, a killed app or a dead battery in the middle of a save can no longer leave a half-written file.
- **A damaged file is never thrown away.** Before, a chats file that could not be read was replaced by an empty one at the next save (all chats gone). Now the damaged file is kept as `name.broken-<date>`, the last good copy is loaded, and a banner says what happened.
- **Keys copied from another phone.** The phone's vault key never leaves a phone, so keys copied to a new phone cannot be opened. Before, they silently looked "not connected"; now a banner names them with a **Connect** button. The wizard also turns off Android's own backup of AIy's data (AIy has its own backup without keys).
- **Restore is all-or-nothing.** Every file in the backup is checked first; a damaged backup changes nothing. The current files are moved to a `pre-restore-<date>` folder, and the app does not save while restoring (it could overwrite the restored files with what it had in memory).
- **Clearer errors:** "phone storage is full" and "permission denied" in plain words (also during downloads, which keep their part), a secure-connection failure names the usual causes (wrong date/time, Wi-Fi login page, VPN), and a broken character in an answer or a build log no longer breaks the request.
- **No more silent failures:** 12 places that ignored errors now write them to the log (Settings > Log); a spending record that cannot be saved is reported, so the total is not quietly wrong.
- The wizard changes MainActivity (vault) and the manifest (`allowBackup="false"`). **Run Rebuild-APK.bat.**
- Not done here: Android 12+ phone-to-phone transfer can still copy app data despite `allowBackup="false"`; that case is covered by the banner above.

## 1.6.0 - better on a slow internet connection
- **Waits longer on a slow line.** When requests time out or stall twice within ten minutes, AIy decides the line is slow and waits 2 to 3 times longer for answers (it goes back to normal after three quick answers). It is decided only after a timeout or stall, never by measuring every request.
- **Stall retry.** A request that stalls or times out is tried once more with the same model before AIy moves to the next service (on a slow line the next one would be just as slow).
- **A banner offers Lite mode** when the line is slow: "Turn on Lite mode" or "Keep waiting". The choice is yours.
- **Lite mode** (also Settings > Slow connection): photos are made smaller (1024 pixels, JPEG) before they are sent, only the latest 8 messages go with a question, long texts and attached files are cut short, live search is off and answers are asked to be shorter. The chat box says "Ask AIy (Lite mode)". Big photos (over 1.5 MB) are made smaller even without Lite mode.
- **Downloads continue where they stopped** (project zip from GitHub, the built APK, build logs, and the in-app update): a broken or stalled download keeps its part and the next try asks for the rest; a changed file starts again. Timeouts are tried again up to 3 times.
- **GitHub work survives a bad line:** reading calls are tried again after a timeout; a push does not send files again that already arrived; an APK upload for a release is tried again up to 3 times and counts as done if GitHub says it already has it.
- The wizard adds one small photo-shrinking function to MainActivity. **Run Rebuild-APK.bat.**
- Not done: an upload cannot continue in the middle of a file (GitHub does not allow it for release files), so a failed APK upload starts that file again.

## 1.5.0 - more free AI, and AIy keeps working in the background
- **Four more free services** (all optional, Settings > Accounts & keys): **Mistral**, **Cerebras**, **NVIDIA** and **Cloudflare** (Cloudflare needs an account number and a token; AIy asks for both). When Gemini or Groq reach their daily limit, AIy goes on with these, then OpenRouter's free models. They answer text only (no photos or PDFs). Each key is tested with one tiny question; their model names are read from the service once a day.
- Notes: Mistral's free plan may use prompts for training unless you switch that off on their site. Cerebras's free plan reads only short texts (longer ones go to the next service) and may be credits instead of a permanent free plan.
- **"AIy is working" notification** (an Android foreground service). It shows while a chat answer, a Code or Build job, a GitHub build or a wait for the internet is going on, with what is happening now (for example the file being written), and a **Stop** button. It disappears a few seconds after the work ends. Stop ends the answers that are arriving and forgets the waiting requests; it does not cancel a GitHub build.
- **Restart-proof waiting:** a chat answer, a Build-tab question or an app brief that was waiting for the internet is asked for again by itself after AIy is opened again (the chat message and the app idea remember it). Writing a whole app and Code-tab jobs are NOT resumed after a restart (the price is shown first; the Code project is not kept).
- The wizard adds the service, three permissions (foreground service, data-sync type, wake lock) and a manifest entry. **Run Rebuild-APK.bat.**
- Limits: swiping AIy away from the recent apps or a strict battery saver (some Xiaomi, Samsung phones) can still end it. Android 15 lets this kind of service run about 6 hours a day.

## 1.4.1 - no internet? AIy waits and sends again
- **A request that fails because the internet is gone is not lost.** It waits on a list and is sent again by itself, one after the other, when the connection returns. This covers everything that uses AI: chat answers, questions about a project, explaining a project, finding files, writing a patch, the Build-tab questions, names, brief and the whole app, and reading a photo.
- **A banner at the top** says "No internet connection" and how many requests wait. Open the list to **Cancel** one, or tap **Try now**. While they are sent again it says so.
- **A notification** arrives when the connection is back (while Android keeps AIy running).
- **Paid OpenRouter requests:** before a paid request AIy notes what the key has used. If the connection was lost during it, AIy asks OpenRouter afterwards and writes the cost of the lost attempt into Settings > Spending as "lost" (it can include other use of the same key), then sends the request again.
- A request that keeps failing is sent again at most 3 times, then the normal error is shown.
- When there is no internet at all, AIy no longer tries the other services one by one (that used to take a long time).
- Limits: the waiting list is kept in memory only, so closing AIy forgets it (the failed message still offers "Try again"). OpenRouter cannot hand back an answer that was lost in flight, so the request is sent again.

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
