/// The build workflow AIy adds to a repository that has none that can be started by hand.
library;

enum ProjectKind { gradle, flutter, unknown }

const String kWorkflowName = 'aiy-build.yml';

/// Files whose change starts AIy's workflows (a push that touches them). A push trigger works on ANY branch,
/// while "workflow_dispatch" only works once the workflow file is on the repository's default branch:
/// that was why building after pushing to a new branch failed with "not found" / "no workflow_dispatch trigger".
const String kBuildTrigger = '.aiy/build-request.txt';
const String kCheckTrigger = '.aiy/check-request.txt';

/// Written into AIy's own workflow files. An AIy workflow without the current mark is replaced on the next build.
const String kWorkflowMark = '# aiy-workflow v7';

bool isAiyWorkflow(String? text) => text != null && (text.contains('name: AIy build') || text.contains('name: AIy quick check'));
bool isCurrentAiyWorkflow(String? text) => text != null && text.contains(kWorkflowMark);
const String kKeystorePath = '.aiy/debug.keystore';

/// [exists] tells whether the repository has that file.
ProjectKind detectKind(bool Function(String path) exists, String? Function(String path) read) {
  final y = read('pubspec.yaml');
  if (y != null && y.contains('flutter')) return ProjectKind.flutter;
  if (exists('settings.gradle.kts') || exists('settings.gradle') || exists('gradlew') || exists('app/build.gradle.kts') || exists('app/build.gradle')) return ProjectKind.gradle;
  return ProjectKind.unknown;
}

// Debug builds are signed with ONE key that is created on the first build and saved in the repository
// (.aiy/debug.keystore). Without it every build would be signed with a new random key and Android would
// refuse to install a new build over the old one.
const String _signing = r'''      - name: Use one fixed signing key
        # A helper step: it must NEVER stop the build. Without it Gradle makes its own debug key (the app builds, it just
        # may not install over an older build).
        continue-on-error: true
        run: |
          mkdir -p ~/.android
          if [ -f .aiy/debug.keystore ]; then
            cp .aiy/debug.keystore ~/.android/debug.keystore
          else
            keytool -genkeypair -keystore ~/.android/debug.keystore -storepass android -keypass android -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=Android Debug,O=Android,C=US"
            mkdir -p .aiy
            cp ~/.android/debug.keystore .aiy/debug.keystore
            # "add -f": many Android projects ignore *.keystore / *.jks, and a plain "git add" then fails.
            if ! ( git config user.name "AIy" && git config user.email "aiy@users.noreply.github.com" && git add -f .aiy/debug.keystore && git commit -q -m "AIy: fixed signing key so builds can update each other" && git push origin "HEAD:${GITHUB_REF_NAME}" ); then
              echo "::warning::The signing key could not be saved in the repository, so the next build may not install over this one."
            fi
          fi
''';


const String _head = r'''name: AIy build
# aiy-workflow v7
on:
  workflow_dispatch:
  push:
    paths:
      - '.aiy/build-request.txt'

concurrency:
  group: aiy-build-${{ github.ref }}
  cancel-in-progress: true

permissions:
  contents: write

jobs:
  build:
    runs-on: ubuntu-latest
    timeout-minutes: 60
    steps:
      - uses: actions/checkout@v5
      - uses: actions/setup-java@v5
        with:
          distribution: temurin
          java-version: '17'
''';

const String _gradle = r'''      - uses: android-actions/setup-android@v3
        continue-on-error: true
      - uses: gradle/actions/setup-gradle@v5
''';

const String _gradleBuild = r'''      - name: Build the debug APK
        env:
          BUILD_NUMBER: ${{ github.run_number }}
        run: |
          if [ -f ./gradlew ]; then chmod +x ./gradlew; ./gradlew --no-daemon assembleDebug --stacktrace; else gradle --no-daemon assembleDebug --stacktrace; fi
      - uses: actions/upload-artifact@v5
        with:
          name: apk
          path: '**/build/outputs/apk/debug/*.apk'
          if-no-files-found: error
          retention-days: 14
''';

const String _flutter = r'''      - uses: subosito/flutter-action@v2
        with:
          channel: stable
          cache: true
      # caches Gradle downloads and build outputs between builds (1-2 minutes saved after the first build)
      - uses: gradle/actions/setup-gradle@v5
        continue-on-error: true
''';

const String _androidHook = r'''      - name: Prepare the Android build
        continue-on-error: true
        run: |
          mkdir -p ~/.gradle/init.d
          cat > ~/.gradle/init.d/aiy-sdk.gradle <<'GRADLE'
          // aiy-sdk-hook: Flutter plugins that ship an old compileSdk fail "checkDebugAarMetadata". Raise them to 36.
          allprojects { p ->
              if (p.name == 'app') return
              def raise = {
                  def android = p.extensions.findByName('android')
                  if (android == null) return
                  try {
                      int cur = 0
                      if (android.hasProperty('compileSdk') && android.compileSdk != null) {
                          cur = android.compileSdk as int
                      } else if (android.hasProperty('compileSdkVersion') && android.compileSdkVersion != null) {
                          def m = (android.compileSdkVersion.toString() =~ /(\d+)/)
                          if (m.find()) cur = m.group(1) as int
                      }
                      if (cur < 36) {
                          if (android.hasProperty('compileSdk')) { android.compileSdk = 36 } else { android.compileSdkVersion(36) }
                          p.logger.lifecycle("aiy-sdk-hook: ${p.name} compileSdk ${cur} -> 36")
                      }
                  } catch (Throwable t) {
                      p.logger.warn("aiy-sdk-hook: ${p.name}: ${t.message}")
                  }
              }
              if (p.state.executed) { raise() } else { p.afterEvaluate { raise() } }
          }
          GRADLE
''';

const String _flutterBuild = r'''      - name: Build the debug APK
        run: |
          NAME=$(grep -m1 '^name:' pubspec.yaml | sed 's/^name:[[:space:]]*//' | tr -d '\r"')
          if [ ! -d android ]; then
            flutter create --platforms android --org com.example --project-name "$NAME" .
          elif [ ! -f android/app/build.gradle ] && [ ! -f android/app/build.gradle.kts ]; then
            # An android/ folder exists but is incomplete (for example only icons): add what is missing, keep what is there.
            TMPD=$(mktemp -d)
            flutter create --platforms android --org com.example --project-name "$NAME" "$TMPD/p"
            cp -rn "$TMPD/p/android/." android/
          fi
          if [ -f .aiy/app_name.txt ]; then
            LABEL=$(head -1 .aiy/app_name.txt | tr -d '\r' | sed 's/[&|\\]/ /g')
            sed -i "s|android:label=\"[^\"]*\"|android:label=\"$LABEL\"|" android/app/src/main/AndroidManifest.xml
          fi
          if [ -f .aiy/icon.png ]; then
            for d in android/app/src/main/res/mipmap-*; do cp .aiy/icon.png "$d/ic_launcher.png"; done
          fi
          flutter pub get
          flutter build apk --debug
      - uses: actions/upload-artifact@v5
        with:
          name: apk
          path: build/app/outputs/flutter-apk/*.apk
          if-no-files-found: error
          retention-days: 14
''';

String? workflowFor(ProjectKind k) {
  switch (k) {
    case ProjectKind.gradle:
      return _head + _gradle + _signing + _gradleBuild;
    case ProjectKind.flutter:
      return _head + _flutter + _signing + _androidHook + _flutterBuild;
    case ProjectKind.unknown:
      return null;
  }
}

// ---------------------------------------------------------------------------------------------- the quick check
// Compiles / analyzes the code without building the APK: 1-2 minutes instead of 5, and no artifact.
const String kCheckWorkflowName = 'aiy-check.yml';

const String _checkHead = r"""name: AIy quick check
# aiy-workflow v7
on:
  workflow_dispatch:
  push:
    paths:
      - '.aiy/check-request.txt'

concurrency:
  group: aiy-check-${{ github.ref }}
  cancel-in-progress: true

permissions:
  contents: read

jobs:
  check:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@v5
""";

const String _checkFlutter = r"""      - uses: subosito/flutter-action@v2
        with:
          channel: stable
          cache: true
      - name: Check the code
        run: |
          flutter pub get
          flutter analyze --no-fatal-infos --no-fatal-warnings
""";

const String _checkGradle = r"""      - uses: actions/setup-java@v5
        with:
          distribution: temurin
          java-version: '17'
      - uses: android-actions/setup-android@v3
        continue-on-error: true
      - uses: gradle/actions/setup-gradle@v5
      - name: Compile the code
        run: |
          if [ -f ./gradlew ]; then chmod +x ./gradlew; G=./gradlew; else G=gradle; fi
          $G --no-daemon compileDebugKotlin --stacktrace || $G --no-daemon compileDebugJavaWithJavac --stacktrace
""";

String? checkWorkflowFor(ProjectKind k) {
  switch (k) {
    case ProjectKind.gradle:
      return _checkHead + _checkGradle;
    case ProjectKind.flutter:
      return _checkHead + _checkFlutter;
    case ProjectKind.unknown:
      return null;
  }
}


/// A workflow (often the project's own) with an Android SDK setup step that can stop the build although GitHub's
/// computers already have the SDK. Returns the text with `continue-on-error: true` added to that step, or null
/// when there is nothing to change.
String? relaxSetupAndroid(String yaml) {
  final lines = yaml.split('\n');
  final out = <String>[];
  var changed = false;
  for (var i = 0; i < lines.length; i++) {
    final l = lines[i];
    out.add(l);
    final m = RegExp(r'^(\s*)(-\s+)?uses:\s*android-actions/setup-android@').firstMatch(l);
    if (m == null) continue;
    // the keys of this step are indented like "uses" (after the dash)
    final indent = m.group(1)!.length + (m.group(2)?.length ?? 0);
    var has = false;
    for (var k = i - 1; k >= 0; k--) {
      final p = lines[k];
      if (p.trim().isEmpty) continue;
      final ind = p.length - p.trimLeft().length;
      if (p.trimLeft().startsWith('- ') && ind < indent) {
        if (p.contains('continue-on-error')) has = true;
        break;
      }
      if (ind == indent && p.trimLeft().startsWith('continue-on-error')) has = true;
      if (ind < indent) break;
    }
    for (var k = i + 1; k < lines.length; k++) {
      final p = lines[k];
      if (p.trim().isEmpty) continue;
      final ind = p.length - p.trimLeft().length;
      if (ind < indent || (ind == indent - 2 && p.trimLeft().startsWith('- ')) || p.trimLeft().startsWith('- ') && ind <= indent - 2) break;
      if (ind == indent && p.trimLeft().startsWith('continue-on-error')) has = true;
      if (ind < indent) break;
    }
    if (!has) {
      out.add('${' ' * indent}continue-on-error: true');
      changed = true;
    }
  }
  return changed ? out.join('\n') : null;
}
