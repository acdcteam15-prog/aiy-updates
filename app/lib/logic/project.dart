/// Pure helpers for Programming Mode: which files count as source code, and the "project map"
/// (folder tree + the import lines of each file) that the free models read to choose files.
library;

const _ignoredDirs = {
  'node_modules', '.git', 'build', '.gradle', 'dist', '__pycache__', '.dart_tool', '.idea', '.vscode', 'Pods', '.next', '.nuxt',
  'target', 'out', 'venv', '.venv', 'vendor', 'obj', 'coverage', '.cache', 'DerivedData', '.pub-cache', '.svn', '.hg', 'bower_components',
  '.expo', '.angular', '.terraform', '.pytest_cache', '.mypy_cache', '__MACOSX', '.kotlin', '.cxx',
};

const _binaryExt = {
  'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'ico', 'svg', 'heic', 'psd', 'ai', 'mp3', 'mp4', 'mov', 'avi', 'mkv', 'wav', 'ogg', 'webm', 'flac', 'm4a',
  'zip', 'tar', 'gz', 'tgz', '7z', 'rar', 'jar', 'aar', 'apk', 'aab', 'ipa', 'dex', 'class', 'so', 'dll', 'exe', 'dylib', 'a', 'o', 'bin', 'dat',
  'db', 'sqlite', 'sqlite3', 'ttf', 'otf', 'woff', 'woff2', 'eot', 'pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'keystore', 'jks', 'p12',
  'pyc', 'pyo', 'lock', 'map', 'iml', 'DS_Store', 'log', 'snap', 'wasm', 'onnx', 'tflite', 'pt', 'h5', 'pkl', 'parquet', 'csv',
};

const _bloatNames = {'package-lock.json', 'yarn.lock', 'pnpm-lock.yaml', 'pubspec.lock', 'Podfile.lock', 'composer.lock', 'Cargo.lock', 'gradlew', 'gradlew.bat', '.DS_Store', 'Thumbs.db'};

/// Bigger text files are almost never hand-written source (generated code, data dumps).
const int kMaxSourceBytes = 300 * 1024;

String extOf(String path) {
  final name = path.split('/').last;
  final i = name.lastIndexOf('.');
  return i <= 0 ? '' : name.substring(i + 1).toLowerCase();
}

bool inIgnoredDir(String path) {
  final parts = path.split('/');
  for (var i = 0; i < parts.length - 1; i++) {
    if (_ignoredDirs.contains(parts[i])) return true;
  }
  return false;
}

/// Everything that belongs in a repository: source AND pictures, the Gradle wrapper jar and so on,
/// but not heavy generated folders. Used when a whole project is uploaded to a new repository.
bool shouldUpload(String path, int size) {
  if (path.isEmpty || path.endsWith('/') || size > 90 * 1024 * 1024) return false;
  if (inIgnoredDir(path)) return false;
  final name = path.split('/').last;
  return !const {'local.properties', '.DS_Store', 'Thumbs.db'}.contains(name);
}

/// Scripts must stay executable on GitHub.
bool isExecutable(String path) {
  final n = path.split('/').last;
  return n == 'gradlew' || n.endsWith('.sh');
}

/// Is this file part of the clean source tree (kept for the AI), or bloat (kept only in the zip)?
bool isSource(String path, int size) {
  if (size > kMaxSourceBytes) return false;
  final parts = path.split('/');
  final name = parts.last;
  if (name.isEmpty) return false;
  for (var i = 0; i < parts.length - 1; i++) {
    if (_ignoredDirs.contains(parts[i])) return false;
  }
  if (_bloatNames.contains(name)) return false;
  if (name.endsWith('.min.js') || name.endsWith('.min.css') || name.endsWith('.g.dart') || name.endsWith('.freezed.dart')) return false;
  final ext = extOf(path);
  if (_binaryExt.contains(ext) || _binaryExt.contains(name.replaceFirst('.', ''))) return false;
  return true;
}

/// The single top folder every file sits in ("my-app/" or GitHub's "owner-repo-abc123/"), or ''.
String commonRoot(Iterable<String> paths) {
  String? root;
  for (final p in paths) {
    final i = p.indexOf('/');
    if (i <= 0) return '';
    final r = p.substring(0, i + 1);
    if (root == null) {
      root = r;
    } else if (root != r) {
      return '';
    }
  }
  return root ?? '';
}

final _importRx = RegExp(
    r'''^\s*(import\s|from\s+\S+\s+import\s|export\s.*\sfrom\s|#include\s|using\s+[\w.]+\s*;|part\s+['"]|require_once|require\s|include\s+['"]|use\s+[\w\\:]+|@import\s|<script[^>]*\ssrc=|<link[^>]*\shref=)|\brequire\(\s*['"]''');

/// The dependency lines of one file (imports, requires, includes), shortened.
List<String> importLines(String text, {int max = 30}) {
  final out = <String>[];
  for (final raw in text.split('\n')) {
    if (raw.length > 400) continue;
    if (!_importRx.hasMatch(raw)) continue;
    var l = raw.trim();
    if (l.length > 140) l = '${l.substring(0, 140)}…';
    out.add(l);
    if (out.length >= max) break;
  }
  return out;
}

/// Rough token count (good enough for a cost estimate before the request).
int estimateTokens(String text) => (text.length / 3.6).ceil();

/// The project map: every source file with its line count and import lines. Kept under [maxChars]
/// by dropping import lines first (the tree itself always stays).
String buildProjectMap(List<String> paths, Map<String, String> texts, {int maxChars = 140000}) {
  final sorted = [...paths]..sort();
  String render(bool withImports) {
    final sb = StringBuffer();
    for (final p in sorted) {
      final t = texts[p];
      sb.writeln(t == null ? p : '$p (${'\n'.allMatches(t).length + 1} lines)');
      if (withImports && t != null) {
        for (final l in importLines(t)) {
          sb.writeln('    $l');
        }
      }
    }
    return sb.toString();
  }

  var map = render(true);
  if (map.length > maxChars) map = render(false);
  if (map.length > maxChars) map = '${map.substring(0, maxChars)}\n… (list cut: the project has more files)';
  return map;
}

/// The file paths out of a routing answer. Accepts a JSON array, or {"files": [...]}, with or without a code fence.
List<String> parseFileList(String answer) {
  var t = answer.trim();
  final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(t);
  if (fence != null) t = fence.group(1)!.trim();
  final a = t.indexOf('['), b = t.lastIndexOf(']');
  if (a < 0 || b <= a) return const [];
  final body = t.substring(a + 1, b);
  final out = <String>[];
  for (final m in RegExp(r'"((?:[^"\\]|\\.)+)"').allMatches(body)) {
    final p = m.group(1)!.replaceAll(r'\\', '/').replaceAll(r'\/', '/').trim();
    if (p.isNotEmpty && !p.contains('\n') && !out.contains(p)) out.add(p);
  }
  return out;
}
