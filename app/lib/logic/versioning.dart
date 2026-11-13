/// Finding, bumping and writing the app version in a project, so the version the person types is the one
/// the built app shows.
library;

enum VersionKind { props, gradle, pubspec, packageJson }

class VersionInfo {
  final VersionKind kind;
  final String path;
  final String name;

  /// The build number (versionCode) when the file has a plain number for it.
  final int? code;
  const VersionInfo(this.kind, this.path, this.name, this.code);

  /// The files the person's change may touch to carry the version.
  static const files = ['version.properties', 'app/build.gradle.kts', 'app/build.gradle', 'pubspec.yaml', 'package.json'];
}

final _gName = RegExp(r'''versionName\s*=?\s*["']([^"'$\n]+)["']''');
final _gCode = RegExp(r'versionCode\s*=?\s*(\d+)');
final _yaml = RegExp(r'^version:\s*([0-9][^\s+]*)(?:\+(\d+))?', multiLine: true);
final _json = RegExp(r'"version"\s*:\s*"([^"]+)"');
final _props = RegExp(r'^versionName\s*=\s*(\S+)', multiLine: true);

/// [read] returns the text of a project file, or null when there is none.
VersionInfo? detectVersion(String? Function(String path) read) {
  final p = read('version.properties');
  if (p != null) {
    final m = _props.firstMatch(p);
    if (m != null) return VersionInfo(VersionKind.props, 'version.properties', m.group(1)!, null);
  }
  for (final path in const ['app/build.gradle.kts', 'app/build.gradle']) {
    final t = read(path);
    if (t == null) continue;
    final m = _gName.firstMatch(t);
    if (m != null) {
      final c = _gCode.firstMatch(t);
      return VersionInfo(VersionKind.gradle, path, m.group(1)!, c == null ? null : int.parse(c.group(1)!));
    }
  }
  final y = read('pubspec.yaml');
  if (y != null) {
    final m = _yaml.firstMatch(y);
    if (m != null) return VersionInfo(VersionKind.pubspec, 'pubspec.yaml', m.group(1)!, m.group(2) == null ? null : int.parse(m.group(2)!));
  }
  final j = read('package.json');
  if (j != null) {
    final m = _json.firstMatch(j);
    if (m != null) return VersionInfo(VersionKind.packageJson, 'package.json', m.group(1)!, null);
  }
  return null;
}

/// The file text with the new version written in. [code] raises the build number where the file holds one.
String applyVersion(VersionInfo v, String text, String name, {int? code}) {
  switch (v.kind) {
    case VersionKind.props:
      return text.replaceFirstMapped(RegExp(r'^versionName\s*=\s*\S+', multiLine: true), (_) => 'versionName=$name');
    case VersionKind.gradle:
      var t = text.replaceFirstMapped(_gName, (m) => m.group(0)!.replaceFirst(m.group(1)!, name));
      if (code != null) t = t.replaceFirstMapped(_gCode, (m) => m.group(0)!.replaceFirst(m.group(1)!, '$code'));
      return t;
    case VersionKind.pubspec:
      final c = code ?? v.code;
      return text.replaceFirstMapped(RegExp(r'^version:.*$', multiLine: true), (_) => c == null ? 'version: $name' : 'version: $name+$c');
    case VersionKind.packageJson:
      return text.replaceFirstMapped(_json, (m) => m.group(0)!.replaceFirst('"${m.group(1)}"', '"$name"'));
  }
}

/// The next build number: always above the current one and above the last one AIy used for this project.
int nextCode(int? current, int lastUsed) => (current ?? 0) > lastUsed ? (current ?? 0) + 1 : lastUsed + 1;

bool validVersion(String s) => RegExp(r'^\d+(\.\d+){0,3}([-+][0-9A-Za-z.\-]+)?$').hasMatch(s.trim());

/// part: 'patch', 'minor' or 'major'. "1.2" -> patch "1.2.1". Anything after the numbers is dropped.
String bumpVersion(String v, String part) {
  final m = RegExp(r'^(\d+)(?:\.(\d+))?(?:\.(\d+))?').firstMatch(v.trim());
  if (m == null) return v;
  var a = int.parse(m.group(1)!), b = int.tryParse(m.group(2) ?? '') ?? 0, c = int.tryParse(m.group(3) ?? '') ?? 0;
  switch (part) {
    case 'major':
      a++;
      b = 0;
      c = 0;
    case 'minor':
      b++;
      c = 0;
    default:
      c++;
  }
  return '$a.$b.$c';
}
