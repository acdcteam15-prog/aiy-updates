import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../logic/followups.dart';
import 'ai.dart';
import 'connectivity.dart';
import 'error_center.dart';
import 'native.dart';
import 'net.dart';
import 'prefs.dart';
import 'store.dart';
import 'app_log.dart';

class Conversation {
  final String id;
  String title;
  int updated;

  /// The folder the person put this chat in ('' = none).
  String folder;

  /// Pinned chats stay at the top of the list and are never removed to make room.
  bool pinned;
  final List<ChatMsg> messages;
  Conversation({required this.id, this.title = '', int? updated, this.folder = '', this.pinned = false, List<ChatMsg>? messages})
      : updated = updated ?? DateTime.now().millisecondsSinceEpoch,
        messages = messages ?? [];

  Map<String, dynamic> toJson() => {'id': id, 't': title, 'u': updated, if (folder.isNotEmpty) 'fo': folder, if (pinned) 'pin': true, 'm': [for (final m in messages) m.toJson()]};
  factory Conversation.fromJson(Map<String, dynamic> j) => Conversation(
        id: '${j['id']}',
        title: '${j['t'] ?? ''}',
        folder: '${j['fo'] ?? ''}',
        pinned: j['pin'] == true,
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
      {
        final j = await Store.readJson(f);
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
      AppLog.i('chats load: $e');
    }
    notifyListeners();
    _resumeWaiting();
  }

  Future<void> _save() async {
    try {
      all.sort((a, b) => b.updated.compareTo(a.updated));
      // Too many chats: the oldest unpinned ones (never the open one) make room.
      while (all.length > 80) {
        final i = all.lastIndexWhere((c) => !c.pinned && !identical(c, current));
        if (i < 0) break;
        _deleteImages(all.removeAt(i));
      }
      await Store.writeJson(File('${(await _dir()).path}/chats.json'), [for (final c in all) c.toJson()]);
    } catch (e) {
      AppLog.i('chats save: $e');
      Store.notices.value = [...Store.notices.value, fileErrorText(e, 'your chats')];
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

  /// Pinned first, then newest first (what the side menu shows).
  List<Conversation> get sorted => [...all.where((c) => c.pinned), ...all.where((c) => !c.pinned)];

  Future<void> togglePin(Conversation c) async {
    c.pinned = !c.pinned;
    notifyListeners();
    await _save();
  }

  Future<void> rename(Conversation c, String title) async {
    final n = title.trim();
    if (n.isEmpty) return;
    c.title = n.length > 60 ? n.substring(0, 60) : n;
    notifyListeners();
    await _save();
  }

  /// Deleted but not yet thrown away, so "Undo" can bring it back for a few seconds.
  Conversation? _trash;
  Timer? _trashTimer;

  /// Removes the chat from the list; its pictures are deleted only when Undo is no longer possible.
  /// Returns false (and does nothing) for the chat that is being answered right now.
  bool softDelete(Conversation c) {
    if (busy && identical(current, c)) return false;
    _purgeTrash();
    all.remove(c);
    _trash = c;
    if (identical(current, c)) current = Conversation(id: _newId());
    _trashTimer = Timer(const Duration(seconds: 6), _purgeTrash);
    notifyListeners();
    unawaited(_save());
    return true;
  }

  void undoDelete() {
    final c = _trash;
    if (c == null) return;
    _trashTimer?.cancel();
    _trash = null;
    all.add(c);
    notifyListeners();
    unawaited(_save());
  }

  void _purgeTrash() {
    _trashTimer?.cancel();
    final c = _trash;
    _trash = null;
    if (c != null) _deleteImages(c);
  }

  Future<void> delete(Conversation c) async {
    if (busy && identical(current, c)) return;
    all.remove(c);
    _deleteImages(c);
    if (identical(current, c)) current = Conversation(id: _newId());
    notifyListeners();
    await _save();
  }

  Future<void> deleteAll() async {
    if (busy) stop();
    _purgeTrash();
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
    // A photo that is big, or any photo in Lite mode, is made smaller first: far fewer bytes to send over a slow line.
    if (ext != 'pdf') {
      final lite = prefs.liteMode;
      if (lite || await File(out).length() > 1500 * 1024) {
        final small = await Native.shrinkImage(out, maxSide: lite ? 1024 : 1600, quality: lite ? 62 : 80);
        if (small != null) {
          try {
            File(out).deleteSync();
          } catch (_) {}
          return small;
        }
      }
    }
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

  static String _short(Conversation c) => c.title.isEmpty ? 'new chat' : (c.title.length > 28 ? '${c.title.substring(0, 28)}…' : c.title);

  /// The person cancelled the waiting request: the message becomes an ordinary failed answer.
  void _giveUp(Conversation c) {
    if (c.messages.isEmpty) return;
    final m = c.messages.last;
    if (m.failed && m.note == 'waiting') {
      m.note = '';
      m.text = 'Stopped waiting for the internet. Tap Try again when you are online.';
      notifyListeners();
      _save();
    }
  }

  /// After a restart: chats that were waiting for the internet are put back on the waiting list.
  void _resumeWaiting() {
    for (final c in all) {
      if (c.messages.isEmpty) continue;
      final m = c.messages.last;
      if (m.failed && m.note == 'waiting') {
        Offline.restore(title: 'Chat: ${_short(c)}', run: () => _resendChat(c), onCancel: () => _giveUp(c));
      }
    }
  }

  /// Asks again for a chat whose last answer failed for lack of internet (only when nothing changed meanwhile).
  Future<void> _resendChat(Conversation c) async {
    if (busy || c.messages.isEmpty || !c.messages.last.failed || !all.contains(c)) return;
    c.messages.removeLast();
    if (c.messages.isEmpty) return;
    await _answer(c);
  }

  /// Suggested next questions for the newest answer of chat [followUpsFor] (kept in memory only).
  List<String> followUps = const [];
  String followUpsFor = '';

  Future<void> _answer(Conversation c, {({String pid, String model})? avoid}) async {
    followUps = const [];
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
        followUps: prefs.followUps,
        avoid: avoid,
        cancel: cancel,
        onText: (t) {
          streamText = hideFollowUpTail(t);
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
        final split = splitFollowUps(r.text);
        followUps = r.stopped ? const [] : split.questions;
        followUpsFor = c.id;
        c.messages.add(ChatMsg(role: 'model', text: split.text, provider: r.provider, model: r.model, sources: r.sources, note: r.stopped ? 'You stopped this answer.' : r.note));
      }
    } on ApiError catch (e) {
      if (Offline.hold(e, title: 'Chat: ${_short(c)}', run: () => _resendChat(c), onCancel: () => _giveUp(c))) {
        // The message stays; the answer is asked for again by itself when the internet is back (also after a restart:
        // the note 'waiting' is saved with the chat).
        c.messages.add(ChatMsg(role: 'model', text: 'No internet. AIy will ask again by itself when the connection is back.', failed: true, note: 'waiting'));
      } else {
        c.messages.add(ChatMsg(role: 'model', text: e.message, failed: true));
        ErrorCenter.report(e, where: 'Chat', retry: retry);
      }
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
