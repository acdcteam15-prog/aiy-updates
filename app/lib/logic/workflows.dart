/// The build workflow AIy adds to a repository that has none that can be started by hand.
library;

enum ProjectKind { gradle, flutter, unknown }

const String kWorkflowName = 'aiy-build.yml';
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
        run: |
          mkdir -p ~/.android
          if [ -f .aiy/debug.keystore ]; then
            cp .aiy/debug.keystore ~/.android/debug.keystore
          else
            keytool -genkeypair -keystore ~/.android/debug.keystore -storepass android -keypass android -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=Android Debug,O=Android,C=US"
            mkdir -p .aiy
            cp ~/.android/debug.keystore .aiy/debug.keystore
            git config user.name "AIy"
            git config user.email "aiy@users.noreply.github.com"
            git add .aiy/debug.keystore
            git commit -m "AIy: fixed signing key so builds can update each other"
            if ! git push origin "HEAD:${GITHUB_REF_NAME}"; then
              echo "::warning::The signing key could not be saved in the repository, so the next build may not install over this one."
            fi
          fi
''';

const String _head = r'''name: AIy build
on:
  workflow_dispatch:

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
''';

const String _flutterBuild = r'''      - name: Build the debug APK
        run: |
          if [ ! -d android ]; then
            NAME=$(grep -m1 '^name:' pubspec.yaml | sed 's/^name:[[:space:]]*//' | tr -d '\r"')
            flutter create --platforms android --org com.example --project-name "$NAME" .
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
      return _head + _flutter + _signing + _flutterBuild;
    case ProjectKind.unknown:
      return null;
  }
}

// ---------------------------------------------------------------------------------------------- the quick check
// Compiles / analyzes the code without building the APK: 1-2 minutes instead of 5, and no artifact.
const String kCheckWorkflowName = 'aiy-check.yml';

const String _checkHead = r"""name: AIy quick check
on:
  workflow_dispatch:

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
