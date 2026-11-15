/// Pure helpers for Programming Mode: reading the model's patch, applying it, checking the result
/// and making a line-by-line diff for the viewer.
library;

import 'dart:convert';

import 'project.dart';

class EditBlock {
  final String search;
  final String replace;
  const EditBlock(this.search, this.replace);
}

class FileEdit {
  final String path;

  /// A whole new file (or a full rewrite): [content] is the complete text.
  final bool whole;
  final String content;
  final List<EditBlock> blocks;
  FileEdit.patch(this.path, this.blocks)
      : whole = false,
        content = '';
  FileEdit.whole(this.path, this.content)
      : whole = true,
        blocks = const [];
}

class PatchPlan {
  final String summary;
  final List<FileEdit> edits;
  const PatchPlan(this.summary, this.edits);
}

/// The exact answer format we ask the coding model for. Search/replace blocks are far more reliable
/// than unified diffs (no line numbers to get wrong) and save the same tokens.
const String kPatchFormat = '''
Answer in EXACTLY this format and nothing else:

### SUMMARY
A short plain-English explanation for a non-programmer: what you changed in each file and why.

### FILE: path/of/an/existing/file
<<<<<<< SEARCH
a few lines copied EXACTLY from the current file (enough to be unique)
=======
the lines that replace them
>>>>>>> REPLACE

### NEW FILE: path/of/a/new/file
<<<<<<< CONTENT
the complete content of the new file
>>>>>>> END

Rules:
- Use the file paths exactly as given.
- Every SEARCH part must match the current file character for character, including indentation. Keep it short: only the lines that change plus 1-3 lines around them.
- Use several SEARCH/REPLACE blocks for several places in one file. Never repeat a whole file unless it is new.
- To delete lines, leave the part between ======= and >>>>>>> REPLACE empty.
- Do not wrap the answer in a code fence. Do not write anything after the last block.
''';

final _headerRx = RegExp(r'^\s*#{1,4}\s*\**\s*(NEW FILE|FILE|SUMMARY)\s*\**\s*:?\s*(.*)$', caseSensitive: false);

String _cleanPath(String p) {
  var s = p.trim();
  s = s.replaceAll(RegExp(r'^[`*"\s]+|[`*"\s]+$'), '');
  while (s.startsWith('./')) {
    s = s.substring(2);
  }
  return s;
}

/// Reads the model's answer. Unknown text between blocks is ignored.
PatchPlan parsePatch(String raw) {
  final lines = raw.replaceAll('\r\n', '\n').split('\n');
  final summary = StringBuffer();
  final edits = <FileEdit>[];
  final blocksByPath = <String, List<EditBlock>>{};
  final order = <String>[];
  var mode = ''; // '', 'summary', 'file', 'new'
  var path = '';
  var part = ''; // '', 'search', 'replace', 'content'
  final a = <String>[], b = <String>[];

  for (final line in lines) {
    final t = line.trim();
    if (part == 'search') {
      if (t == '=======') {
        part = 'replace';
      } else {
        a.add(line);
      }
      continue;
    }
    if (part == 'replace') {
      if (t.startsWith('>>>>>>>')) {
        blocksByPath.putIfAbsent(path, () {
          order.add(path);
          return [];
        }).add(EditBlock(a.join('\n'), b.join('\n')));
        a.clear();
        b.clear();
        part = '';
      } else {
        b.add(line);
      }
      continue;
    }
    if (part == 'content') {
      if (t == '>>>>>>> END' || t == '>>>>>>> CONTENT' || t == '>>>>>>> REPLACE') {
        edits.add(FileEdit.whole(path, '${a.join('\n')}\n'));
        a.clear();
        part = '';
      } else {
        a.add(line);
      }
      continue;
    }
    final h = _headerRx.firstMatch(line);
    if (h != null) {
      final kind = h.group(1)!.toUpperCase();
      if (kind == 'SUMMARY') {
        mode = 'summary';
        final rest = h.group(2)!.trim();
        if (rest.isNotEmpty) summary.writeln(rest);
      } else {
        mode = kind == 'FILE' ? 'file' : 'new';
        path = _cleanPath(h.group(2)!);
      }
      continue;
    }
    if (t.startsWith('<<<<<<<') && path.isNotEmpty && mode != 'summary') {
      part = t.toUpperCase().contains('CONTENT') ? 'content' : 'search';
      continue;
    }
    if (mode == 'summary' && !t.startsWith('```')) summary.writeln(line);
  }
  for (final p in order) {
    edits.add(FileEdit.patch(p, blocksByPath[p]!));
  }
  return PatchPlan(summary.toString().trim(), edits);
}

class ApplyResult {
  final String text;

  /// One message per SEARCH part that could not be found.
  final List<String> failures;
  const ApplyResult(this.text, this.failures);
}

List<String> _trimBlank(List<String> l) {
  var s = 0, e = l.length;
  while (s < e && l[s].trim().isEmpty) {
    s++;
  }
  while (e > s && l[e - 1].trim().isEmpty) {
    e--;
  }
  return l.sublist(s, e);
}

int _findLines(List<String> hay, List<String> needle, String Function(String) norm, int from) {
  if (needle.isEmpty || needle.length > hay.length) return -1;
  final n = [for (final l in needle) norm(l)];
  for (var i = from; i + n.length <= hay.length; i++) {
    var ok = true;
    for (var j = 0; j < n.length; j++) {
      if (norm(hay[i + j]) != n[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return i;
  }
  return -1;
}

/// Applies the blocks in order. A block is first matched exactly, then ignoring trailing spaces,
/// then ignoring indentation (models often get the indentation slightly wrong).
ApplyResult applyBlocks(String original, List<EditBlock> blocks) {
  final crlf = original.contains('\r\n');
  var text = original.replaceAll('\r\n', '\n');
  final failures = <String>[];
  for (final blk in blocks) {
    final search = blk.search.replaceAll('\r\n', '\n');
    final replace = blk.replace.replaceAll('\r\n', '\n');
    if (search.trim().isEmpty) {
      // Nothing to look for: add at the end (used for "append to file").
      text = text.isEmpty ? '$replace\n' : '${text.endsWith('\n') ? text : '$text\n'}$replace\n';
      continue;
    }
    final at = text.indexOf(search);
    if (at >= 0) {
      text = text.replaceRange(at, at + search.length, replace);
      continue;
    }
    final hay = text.split('\n');
    final needle = _trimBlank(search.split('\n'));
    var i = _findLines(hay, needle, (s) => s.trimRight(), 0);
    if (i < 0) i = _findLines(hay, needle, (s) => s.trim(), 0);
    if (i < 0) {
      final first = needle.isEmpty ? '' : needle.first.trim();
      failures.add('SEARCH part not found (it starts with: "${first.length > 80 ? first.substring(0, 80) : first}")');
      continue;
    }
    hay.replaceRange(i, i + needle.length, replace.isEmpty ? const <String>[] : replace.split('\n'));
    text = hay.join('\n');
  }
  return ApplyResult(crlf ? text.replaceAll('\n', '\r\n') : text, failures);
}

// ---------------------------------------------------------------------------------------------- validation
const _cLike = {'js', 'jsx', 'ts', 'tsx', 'mjs', 'cjs', 'kt', 'kts', 'java', 'dart', 'c', 'h', 'cpp', 'hpp', 'cc', 'cs', 'go', 'rs', 'swift', 'php', 'scss', 'less', 'css', 'gradle', 'groovy'};
const _hashLike = {'py', 'rb', 'sh', 'yaml', 'yml', 'toml'};
const _markup = {'html', 'htm', 'vue', 'svelte', 'xml'};

/// A structural problem in [text] (unbalanced brackets, unterminated string, broken JSON), or null.
/// This is a careful bracket-and-quote check, not a compiler.
String? structureError(String path, String text) {
  final ext = extOf(path);
  if (ext == 'json') {
    try {
      jsonDecode(text);
      return null;
    } on FormatException catch (e) {
      return 'Not valid JSON: ${e.message}';
    }
  }
  if (_markup.contains(ext)) {
    for (final tag in const ['script', 'style', 'div', 'template', 'section', 'table', 'ul', 'form']) {
      final open = RegExp('<$tag(\\s[^>]*[^/])?>', caseSensitive: false).allMatches(text).length;
      final close = RegExp('</$tag\\s*>', caseSensitive: false).allMatches(text).length;
      if (open != close) return '<$tag> is opened $open time(s) but closed $close time(s)';
    }
    return null;
  }
  final c = _cLike.contains(ext);
  final h = _hashLike.contains(ext);
  if (!c && !h) return null;
  if (ext == 'yaml' || ext == 'yml' || ext == 'sh' || ext == 'toml' || ext == 'rb') return null; // too free-form for a bracket check
  final lineComment = c && ext != 'css';
  final triple = ext == 'py' || ext == 'kt' || ext == 'kts' || ext == 'java' || ext == 'dart' || ext == 'swift';
  final backtick = const {'js', 'jsx', 'ts', 'tsx', 'mjs', 'cjs', 'go'}.contains(ext);
  final charLiteral = const {'kt', 'kts', 'java', 'c', 'h', 'cpp', 'hpp', 'cc', 'cs', 'go', 'rs', 'swift'}.contains(ext);
  final stack = <(String, int)>[];
  const pairs = {')': '(', ']': '[', '}': '{'};
  var line = 1;
  final n = text.length;
  var i = 0;
  while (i < n) {
    final ch = text[i];
    if (ch == '\n') {
      line++;
      i++;
      continue;
    }
    // comments
    if (h && ch == '#') {
      while (i < n && text[i] != '\n') {
        i++;
      }
      continue;
    }
    if (c && ch == '/' && i + 1 < n) {
      if (text[i + 1] == '/' && lineComment) {
        while (i < n && text[i] != '\n') {
          i++;
        }
        continue;
      }
      if (text[i + 1] == '*') {
        final end = text.indexOf('*/', i + 2);
        if (end < 0) return 'A /* comment starting at line $line is never closed';
        line += '\n'.allMatches(text.substring(i, end)).length;
        i = end + 2;
        continue;
      }
    }
    // strings
    if (ch == '"' || ch == "'" || (ch == '`' && backtick)) {
      final start = line;
      if (triple && i + 2 < n && text[i + 1] == ch && text[i + 2] == ch) {
        final end = text.indexOf(ch * 3, i + 3);
        if (end < 0) return 'A triple-quoted string starting at line $start is never closed';
        line += '\n'.allMatches(text.substring(i, end)).length;
        i = end + 3;
        continue;
      }
      if (ch == "'" && charLiteral) {
        // 'x', '\n' (or a Rust lifetime / Swift-less apostrophe): skip a short literal, else ignore the quote.
        final close = text.indexOf("'", i + 1);
        if (close > i && close - i <= 8 && !text.substring(i, close).contains('\n')) {
          i = close + 1;
        } else {
          i++;
        }
        continue;
      }
      final multi = ch == '`';
      var j = i + 1;
      var closed = false;
      while (j < n) {
        final d = text[j];
        if (d == '\\') {
          j += 2;
          continue;
        }
        if (d == '\n') {
          if (!multi) break;
          line++;
        }
        if (d == ch) {
          closed = true;
          break;
        }
        j++;
      }
      if (!closed) return 'A string starting at line $start is never closed';
      i = j + 1;
      continue;
    }
    if (ch == '(' || ch == '[' || ch == '{') {
      stack.add((ch, line));
    } else if (pairs.containsKey(ch)) {
      if (stack.isEmpty) return "Unexpected '$ch' at line $line (nothing is open)";
      final (open, at) = stack.removeLast();
      if (open != pairs[ch]) return "'$ch' at line $line does not match '$open' opened at line $at";
    }
    i++;
  }
  if (stack.isNotEmpty) {
    final (open, at) = stack.last;
    return "'$open' opened at line $at is never closed";
  }
  return null;
}

/// A problem introduced by the change, or null. When the ORIGINAL file already trips the checker
/// (regular expressions and unusual syntax can fool it), the check is skipped instead of raising a false alarm.
String? validateChange(String path, String? before, String after) {
  final e = structureError(path, after);
  if (e == null) return null;
  if (before != null && extOf(path) != 'json' && structureError(path, before) != null) return null;
  return e;
}

// ---------------------------------------------------------------------------------------------- diff
class DiffLine {
  /// ' ' unchanged, '+' added, '-' removed.
  final String kind;
  final String text;

  /// Line numbers in the old and new file (0 when the line is not in that file).
  final int oldNo;
  final int newNo;
  const DiffLine(this.kind, this.text, this.oldNo, this.newNo);
}

/// Line diff (longest common subsequence on the changed middle part).
List<DiffLine> diffLines(String before, String after) {
  final a = before.replaceAll('\r\n', '\n').split('\n');
  final b = after.replaceAll('\r\n', '\n').split('\n');
  var pre = 0;
  while (pre < a.length && pre < b.length && a[pre] == b[pre]) {
    pre++;
  }
  var suf = 0;
  while (suf < a.length - pre && suf < b.length - pre && a[a.length - 1 - suf] == b[b.length - 1 - suf]) {
    suf++;
  }
  final out = <DiffLine>[];
  for (var i = 0; i < pre; i++) {
    out.add(DiffLine(' ', a[i], i + 1, i + 1));
  }
  final am = a.sublist(pre, a.length - suf), bm = b.sublist(pre, b.length - suf);
  final n = am.length, m = bm.length;
  if (n * m > 4000000) {
    for (var i = 0; i < n; i++) {
      out.add(DiffLine('-', am[i], pre + i + 1, 0));
    }
    for (var j = 0; j < m; j++) {
      out.add(DiffLine('+', bm[j], 0, pre + j + 1));
    }
  } else {
    final w = m + 1;
    final t = List<int>.filled((n + 1) * w, 0);
    for (var i = n - 1; i >= 0; i--) {
      for (var j = m - 1; j >= 0; j--) {
        t[i * w + j] = am[i] == bm[j] ? t[(i + 1) * w + j + 1] + 1 : (t[(i + 1) * w + j] >= t[i * w + j + 1] ? t[(i + 1) * w + j] : t[i * w + j + 1]);
      }
    }
    var i = 0, j = 0;
    while (i < n && j < m) {
      if (am[i] == bm[j]) {
        out.add(DiffLine(' ', am[i], pre + i + 1, pre + j + 1));
        i++;
        j++;
      } else if (t[(i + 1) * w + j] >= t[i * w + j + 1]) {
        out.add(DiffLine('-', am[i], pre + i + 1, 0));
        i++;
      } else {
        out.add(DiffLine('+', bm[j], 0, pre + j + 1));
        j++;
      }
    }
    for (; i < n; i++) {
      out.add(DiffLine('-', am[i], pre + i + 1, 0));
    }
    for (; j < m; j++) {
      out.add(DiffLine('+', bm[j], 0, pre + j + 1));
    }
  }
  for (var k = 0; k < suf; k++) {
    out.add(DiffLine(' ', a[a.length - suf + k], a.length - suf + k + 1, b.length - suf + k + 1));
  }
  return out;
}

({int added, int removed}) diffStats(List<DiffLine> d) => (added: d.where((l) => l.kind == '+').length, removed: d.where((l) => l.kind == '-').length);

// ---------------------------------------------------------------------------------------------- reviewing a change
/// The changed parts of a diff: each is a run of '+'/'-' lines, [start] to [end] (end not included).
List<({int start, int end})> diffHunks(List<DiffLine> d) {
  final out = <({int start, int end})>[];
  var i = 0;
  while (i < d.length) {
    if (d[i].kind == ' ') {
      i++;
      continue;
    }
    final s = i;
    while (i < d.length && d[i].kind != ' ') {
      i++;
    }
    out.add((start: s, end: i));
  }
  return out;
}

/// The file with only the kept changes: in a [rejected] part the old lines stay and the new ones are dropped.
/// [crlf] writes Windows line ends (when the file had them).
String mergeHunks(List<DiffLine> d, Set<int> rejected, {bool crlf = false}) {
  final hunks = diffHunks(d);
  final off = List<bool>.filled(d.length, false);
  for (var h = 0; h < hunks.length; h++) {
    if (!rejected.contains(h)) continue;
    for (var i = hunks[h].start; i < hunks[h].end; i++) {
      off[i] = true;
    }
  }
  final lines = <String>[];
  for (var i = 0; i < d.length; i++) {
    final l = d[i];
    if (l.kind == ' ') {
      lines.add(l.text);
    } else if (l.kind == '+') {
      if (!off[i]) lines.add(l.text);
    } else {
      if (off[i]) lines.add(l.text);
    }
  }
  final t = lines.join('\n');
  return crlf ? t.replaceAll('\n', '\r\n') : t;
}
