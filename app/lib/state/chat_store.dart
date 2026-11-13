import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'ai.dart';
import 'error_center.dart';
import 'net.dart';
import 'prefs.dart';

class Conversation {
  final String id;
  String title;
  int updated;

  /// The folder the person put this chat in ('' = none).
  String folder;
  final List<ChatMsg> messages;
  Conversation({required this.id, this.title = '', int? updated, this.folder = '', List<ChatMsg>? messages})
      : updated = updated ?? DateTime.now().millisecondsSinceEpoch,
        messages = messages ?? [];

  Map<String, dynamic> toJson() => {'id': id, 't': title, 'u': updated, if (folder.isNotEmpty) 'fo': folder, 'm': [for (final m in messages) m.toJson()]};
  factory Conversation.fromJson(Map<String, dynamic> j) => Conversation(
        id: '${j['id']}',
        title: '${j['t'] ?? ''}',
        folder: '${j['fo'] ?? ''}',
        updated: (j['u'] as num?)?.toInt(),
        messages: [
          for (final m in (j['m'] as List? ?? const []))
            if (m is Map) ChatMsg.fromJson(Map<String, dynamic>.from(m))
        ],
      );
}

/// Normal Mode: the conversations (kept on this phone only) and sending a message.
class ChatStore extends ChangeNotifier {
  final AiEngine engine;
  final LocalPrefs prefs;
  ChatStore(this.engine, this.prefs) {
    _load();
  }

  final List<Conversation> all = [];
  Conversation current = Conversation(id: _newId());
  bool busy = false;

  /// The answer as far as it has arrived (empty until the first words come).
  String streamText = '';
  AiCancel? _cancel;

  /// The answer that just arrived (it is revealed with a typing animation once).
  int revealTs = 0;

  /// Stops the answer that is being written; what has arrived so far is kept.
  void stop() => _cancel?.cancel();

  // ------------------------------------------------------------------ folders
  /// Every folder: the ones the person made (even when empty) and any a chat still points to.
  List<String> get folders {
    final out = <String>[...prefs.folders];
    for (final c in all) {
      if (c.folder.isNotEmpty && !out.contains(c.folder)) out.add(c.folder);
    }
    return out;
  }

  Future<bool> addFolder(String name) async {
    final n = name.trim();
    if (n.isEmpty || n.length > 30 || folders.any((f) => f.toLowerCase() == n.toLowerCase())) return false;
    await prefs.setFolders([...prefs.folders, n]);
    notifyListeners();
    return true;
  }

  Future<void> renameFolder(String old, String name) async {
    final n = name.trim();
    if (n.isEmpty || n.length > 30 || n == old || folders.any((f) => f.toLowerCase() == n.toLowerCase())) return;
    await prefs.setFolders([for (final f in prefs.folders) f == old ? n : f]);
    for (final c in all) {
      if (c.folder == old) c.folder = n;
    }
    notifyListeners();
    await _save();
  }

  /// Removes the folder; its chats stay, without a folder.
  Future<void> deleteFolder(String name) async {
    await prefs.setFolders([for (final f in prefs.folders) if (f != name) f]);
    for (final c in all) {
      if (c.folder == name) c.folder = '';
    }
    notifyListeners();
    await _save();
  }

  Future<void> moveTo(Conversation c, String folder) async {
    c.folder = folder;
    notifyListeners();
    await _save();
  }

  static String _newId() => DateTime.now().microsecondsSinceEpoch.toRadixString(36);

  Future<Directory> _dir() async {
    final d = Directory('${(await getApplicationDocumentsDirectory()).path}/aiy');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  Future<void> _load() async {
    try {
      final f = File('${(await _dir()).path}/chats.json');
      if (f.existsSync()) {
        final j = jsonDecode(await f.readAsString());
        if (j is List) {
          all
            ..clear()
            ..addAll([
              for (final c in j)
                if (c is Map) Conversation.fromJson(Map<String, dynamic>.from(c))
            ]);
        }
      }
    } catch (e) {
      debugPrint('chats load: $e');
    }
    notifyListeners();
  }

  Future<void> _save() async {
    try {
      all.sort((a, b) => b.updated.compareTo(a.updated));
      while (all.length > 80) {
        _deleteImages(all.removeLast());
      }
      await File('${(await _dir()).path}/chats.json').writeAsString(jsonEncode([for (final c in all) c.toJson()]));
    } catch (e) {
      debugPrint('chats save: $e');
    }
  }

  void _deleteImages(Conversation c) {
    for (final m in c.messages) {
      final p = m.imagePath;
      if (p != null) {
        try {
          File(p).deleteSync();
        } catch (_) {}
      }
    }
  }

  void newChat() {
    if (busy) return;
    current = Conversation(id: _newId());
    notifyListeners();
  }

  void open(Conversation c) {
    if (busy) return;
    current = c;
    revealTs = 0;
    notifyListeners();
  }

  Future<void> delete(Conversation c) async {
    all.remove(c);
    _deleteImages(c);
    if (identical(current, c)) current = Conversation(id: _newId());
    notifyListeners();
    await _save();
  }

  Future<void> deleteAll() async {
    for (final c in all) {
      _deleteImages(c);
    }
    all.clear();
    current = Conversation(id: _newId());
    notifyListeners();
    await _save();
  }

  /// Copies a picked photo into the app's own folder so the chat can show it later.
  Future<String> keepImage(String pickedPath) async {
    final d = Directory('${(await _dir()).path}/img');
    if (!d.existsSync()) d.createSync(recursive: true);
    final low = pickedPath.toLowerCase();
    final ext = low.endsWith('.pdf') ? 'pdf' : (low.endsWith('.png') ? 'png' : (low.endsWith('.webp') ? 'webp' : 'jpg'));
    final out = '${d.path}/${_newId()}.$ext';
    await File(pickedPath).copy(out);
    return out;
  }

  Future<void> send(String text, {String? imagePath, String attach = '', String attachName = ''}) async {
    final t = text.trim();
    if (busy || (t.isEmpty && imagePath == null && attach.isEmpty)) return;
    final c = current;
    c.messages.add(ChatMsg(role: 'user', text: t, imagePath: imagePath, attach: attach, attachName: attachName));
    if (c.title.isEmpty) c.title = t.isEmpty ? (attachName.isNotEmpty ? attachName : 'Photo') : (t.length > 48 ? '${t.substring(0, 48)}…' : t);
    if (!all.contains(c)) all.insert(0, c);
    await _answer(c);
  }

  Future<void> reload() async {
    all.clear();
    await _load();
  }

  /// Takes the conversation back to just before message [index] and returns that message's text, to be changed and sent again.
  Future<String> editFrom(int index) async {
    final c = current;
    if (busy || index < 0 || index >= c.messages.length) return '';
    final t = c.messages[index].text;
    c.messages.removeRange(index, c.messages.length);
    notifyListeners();
    await _save();
    return t;
  }

  String exportText(Conversation c) {
    final sb = StringBuffer('${c.title.isEmpty ? 'AIy chat' : c.title}\n${'=' * 24}\n\n');
    for (final m in c.messages) {
      if (m.failed) continue;
      sb.writeln(m.isUser ? 'You:' : 'AIy${m.provider.isEmpty ? '' : ' (${m.provider})'}:');
      if (m.attachName.isNotEmpty) sb.writeln('[file: ${m.attachName}]');
      if (m.imagePath != null && m.attachName.isEmpty) sb.writeln('[picture]');
      sb.writeln('${m.text}\n');
    }
    return sb.toString().trimRight();
  }

  /// Asks again after a failed answer.
  Future<void> retry() async {
    final c = current;
    if (busy || c.messages.isEmpty) return;
    if (!c.messages.last.isUser) c.messages.removeLast();
    if (c.messages.isEmpty) return;
    await _answer(c);
  }

  /// Answers the last question again, leaving out the model that answered before (when another one is connected).
  Future<void> retryAnother() async {
    final c = current;
    if (busy || c.messages.isEmpty) return;
    ({String pid, String model})? avoid;
    if (!c.messages.last.isUser) {
      final m = c.messages.removeLast();
      final pid = AiEngine.names.entries.where((e) => e.value == m.provider).map((e) => e.key).firstOrNull;
      if (pid != null && m.model.isNotEmpty) avoid = (pid: pid, model: m.model);
    }
    if (c.messages.isEmpty) return;
    await _answer(c, avoid: avoid);
  }

  Future<void> _answer(Conversation c, {({String pid, String model})? avoid}) async {
    busy = true;
    streamText = '';
    final cancel = _cancel = AiCancel();
    c.updated = DateTime.now().millisecondsSinceEpoch;
    notifyListeners();
    var lastPaint = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      final r = await engine.chat(
        List.of(c.messages),
        search: prefs.liveSearch,
        prefer: prefs.preferProvider,
        instructions: prefs.customInstructions,
        avoid: avoid,
        cancel: cancel,
        onText: (t) {
          streamText = t;
          final now = DateTime.now();
          // Repainting the whole answer for every word would make the phone stutter.
          if (t.isEmpty || now.difference(lastPaint).inMilliseconds >= 70) {
            lastPaint = now;
            notifyListeners();
          }
        },
      );
      if (r.stopped && r.text.isEmpty) {
        c.messages.add(ChatMsg(role: 'model', text: 'Stopped before an answer arrived.', failed: true));
      } else {
        c.messages.add(ChatMsg(role: 'model', text: r.text, provider: r.provider, model: r.model, sources: r.sources, note: r.stopped ? 'You stopped this answer.' : r.note));
      }
    } on ApiError catch (e) {
      c.messages.add(ChatMsg(role: 'model', text: e.message, failed: true));
      ErrorCenter.report(e, where: 'Chat', retry: retry);
    } catch (e) {
      c.messages.add(ChatMsg(role: 'model', text: 'Something went wrong: $e', failed: true));
    }
    _cancel = null;
    streamText = '';
    busy = false;
    c.updated = DateTime.now().millisecondsSinceEpoch;
    notifyListeners();
    await _save();
  }
}
