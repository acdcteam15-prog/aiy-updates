import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart' show SharePlus, ShareParams;
import 'package:speech_to_text/speech_to_text.dart';

import '../../state/ai.dart';
import '../../state/chat_store.dart';
import '../../state/native.dart';
import '../../state/net.dart';
import '../../state/prefs.dart';
import '../../state/share_inbox.dart';
import '../widgets/common.dart';
import '../widgets/error_popup.dart';
import '../widgets/fx.dart';
import '../widgets/markdown.dart';

const _suggestions = [
  (Icons.lightbulb_outline_rounded, 'Explain something simply', 'Explain how the internet works in simple words.'),
  (Icons.edit_outlined, 'Help me write a message', 'Help me write a polite message asking to move a meeting to tomorrow.'),
  (Icons.public_rounded, 'What is new today?', 'What are the most important news stories today?'),
  (Icons.photo_camera_outlined, 'Ask about a photo', ''),
];

/// Normal Mode: the conversation and the "Ask AIy" bar.
class ChatView extends StatefulWidget {
  const ChatView({super.key});
  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final _text = TextEditingController();
  final _scroll = ScrollController();
  final _stt = SpeechToText();
  bool _listening = false;
  String? _image;
  String _fileText = '';
  String _fileName = '';
  int _seen = 0;
  String _conv = '';
  int _streamLen = 0;
  bool _takingShared = false;

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _stt.stop();
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _toEnd({bool jump = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final end = _scroll.position.maxScrollExtent;
      if (jump) {
        _scroll.jumpTo(end);
      } else {
        _scroll.animateTo(end, duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic);
      }
    });
  }

  /// While an answer is being written the list follows it, unless the person scrolled up to read.
  void _followStream() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final pos = _scroll.position;
      if (pos.maxScrollExtent - pos.pixels < 200) _scroll.jumpTo(pos.maxScrollExtent);
    });
  }

  /// Something another app shared into AIy, sent to Chat: text goes into the box, a photo, PDF or text file is attached.
  Future<void> _takeShared(SharedItem it) async {
    final store = context.read<ChatStore>();
    try {
      if (it.problem.isNotEmpty && it.isEmpty) {
        snack(context, 'Could not read what was shared (${it.problem})');
        return;
      }
      final text = it.fullText;
      if (it.files.isNotEmpty) {
        final f = it.files.first;
        if (it.files.length > 1) snack(context, 'AIy can use one file at a time here. It took ${f.name}.');
        if (f.size > 8 * 1024 * 1024) {
          snack(context, 'This file is too big (the limit is 8 MB).');
        } else if (f.isPdf || f.isImage) {
          final kept = await store.keepImage(f.path);
          if (mounted) {
            setState(() {
              _image = kept;
              _fileName = f.isPdf ? f.name : '';
              _fileText = '';
            });
          }
        } else {
          final bytes = await File(f.path).readAsBytes();
          if (bytes.length > 200 * 1024 || bytes.contains(0)) {
            if (mounted) snack(context, 'AIy can read text files up to 200 KB, photos and PDFs. ${f.name} is not one of those.');
          } else if (mounted) {
            setState(() {
              _fileText = String.fromCharCodes(const Utf8Decoder(allowMalformed: true).convert(bytes).runes);
              _fileName = f.name;
              _image = null;
            });
          }
        }
      }
      if (text.isNotEmpty && mounted) {
        final cur = _text.text.trim();
        final v = cur.isEmpty ? text : '$cur\n$text';
        _text.value = TextEditingValue(text: v, selection: TextSelection.collapsed(offset: v.length));
      }
    } catch (e) {
      if (mounted) snack(context, 'Could not use what was shared ($e)');
    }
  }

  /// What a long press (or the "more" button) on an answer offers.
  Future<void> _answerMenu(ChatMsg m, bool last) async {
    final store = context.read<ChatStore>();
    final advanced = context.read<LocalPrefs>().advanced;
    final pick = await showModalBottomSheet<String>(
      context: context,
      builder: (b) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.copy_rounded), title: const Text('Copy'), onTap: () => Navigator.pop(b, 'copy')),
          ListTile(
            leading: const Icon(Icons.autorenew_rounded),
            title: const Text('Answer again with another model'),
            subtitle: Text(last ? 'The next connected AI answers instead of ${m.provider.isEmpty ? 'this one' : m.provider}' : 'Only the newest answer can be asked again'),
            enabled: last && !store.busy,
            onTap: () => Navigator.pop(b, 'another'),
          ),
          if (advanced)
            ListTile(
              leading: const Icon(Icons.tune_rounded),
              title: const Text('Choose which AI answers'),
              subtitle: const Text('Pick a service, or a free OpenRouter model'),
              onTap: () => Navigator.pop(b, 'choose'),
            ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (!mounted || pick == null) return;
    if (pick == 'copy') {
      Clipboard.setData(ClipboardData(text: m.text));
      snack(context, 'Copied');
    } else if (pick == 'another') {
      await store.retryAnother();
    } else if (pick == 'choose') {
      final changed = await showModalBottomSheet<bool>(context: context, isScrollControlled: true, useSafeArea: true, builder: (_) => const ChooseAiSheet());
      if (changed == true && last && mounted) await store.retry();
    }
  }

  Future<void> _send([String? preset]) async {
    final store = context.read<ChatStore>();
    final text = preset ?? _text.text;
    if (store.busy || (text.trim().isEmpty && _image == null && _fileText.isEmpty)) return;
    final img = _image;
    final ft = _fileText, fn = _fileName;
    if (_listening) await _stt.stop();
    setState(() {
      _image = null;
      _fileText = '';
      _fileName = '';
      _listening = false;
    });
    _text.clear();
    FocusScope.of(context).unfocus();
    await store.send(text, imagePath: img, attach: ft, attachName: fn);
  }

  Future<void> _pick(ImageSource src) async {
    final store = context.read<ChatStore>();
    try {
      final f = await ImagePicker().pickImage(source: src, maxWidth: 1600, maxHeight: 1600, imageQuality: 82);
      if (f == null) return;
      final kept = await store.keepImage(f.path);
      if (mounted) setState(() => _image = kept);
    } catch (e) {
      if (mounted) snack(context, 'Could not get the photo ($e)');
    }
  }

  Future<void> _pickFile() async {
    final store = context.read<ChatStore>();
    try {
      final f = await Native.pickFile();
      if (f == null) return;
      if (f.size > 8 * 1024 * 1024) {
        if (mounted) snack(context, 'This file is too big (the limit is 8 MB).');
        return;
      }
      if (f.name.toLowerCase().endsWith('.pdf')) {
        final kept = await store.keepImage(f.path);
        if (mounted) {
          setState(() {
            _image = kept;
            _fileName = f.name;
            _fileText = '';
          });
        }
        return;
      }
      final bytes = await File(f.path).readAsBytes();
      if (bytes.length > 200 * 1024 || bytes.contains(0)) {
        if (mounted) snack(context, 'AIy can read text files up to 200 KB (and PDFs). This one is not one of those.');
        return;
      }
      if (mounted) {
        setState(() {
          _fileText = String.fromCharCodes(const Utf8Decoder(allowMalformed: true).convert(bytes).runes);
          _fileName = f.name;
          _image = null;
        });
      }
    } on ApiError catch (e) {
      if (mounted) snack(context, e.message);
    } catch (e) {
      if (mounted) snack(context, 'Could not open the file ($e)');
    }
  }

  void _attach() {
    showModalBottomSheet<void>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: const Text('Take a photo'),
            onTap: () {
              Navigator.pop(c);
              _pick(ImageSource.camera);
            },
          ),
          ListTile(
            leading: const Icon(Icons.attach_file_rounded),
            title: const Text('Attach a file'),
            subtitle: const Text('A text or code file, or a PDF (read by Gemini)'),
            onTap: () {
              Navigator.pop(c);
              _pickFile();
            },
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Choose from gallery'),
            onTap: () {
              Navigator.pop(c);
              _pick(ImageSource.gallery);
            },
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  Future<void> _mic() async {
    if (_listening) {
      await _stt.stop();
      if (mounted) setState(() => _listening = false);
      return;
    }
    try {
      final ok = await _stt.initialize(
        onError: (e) {
          if (mounted) setState(() => _listening = false);
        },
        onStatus: (s) {
          if ((s == 'done' || s == 'notListening') && mounted) setState(() => _listening = false);
        },
      );
      if (!ok) {
        if (mounted) snack(context, 'Voice typing is not available on this phone.');
        return;
      }
      final base = _text.text.trim();
      if (mounted) setState(() => _listening = true);
      await _stt.listen(onResult: (r) {
        if (!mounted) return;
        final v = base.isEmpty ? r.recognizedWords : '$base ${r.recognizedWords}';
        _text.value = TextEditingValue(text: v, selection: TextSelection.collapsed(offset: v.length));
      });
    } catch (e) {
      if (mounted) {
        setState(() => _listening = false);
        snack(context, 'Voice typing is not available ($e)');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ChatStore>();
    final inbox = context.watch<ShareInbox>();
    final msgs = store.current.messages;
    final count = msgs.length + (store.busy ? 1 : 0);
    if (inbox.hasForChat && !_takingShared) {
      _takingShared = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _takingShared = false;
        final it = inbox.takeChat();
        if (it != null && mounted) _takeShared(it);
      });
    }
    if (store.busy && store.streamText.length != _streamLen) {
      _streamLen = store.streamText.length;
      _followStream();
    } else if (!store.busy) {
      _streamLen = 0;
    }
    if (count != _seen || store.current.id != _conv) {
      _toEnd(jump: _seen == 0 || store.current.id != _conv);
      _seen = count;
      _conv = store.current.id;
    }
    return Column(children: [
      Expanded(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: msgs.isEmpty
              ? _Welcome(key: const ValueKey('welcome'), listening: _listening, onPick: (s) => s.isEmpty ? _attach() : _send(s))
              : SelectionArea(
                  key: ValueKey(store.current.id),
                  child: ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    itemCount: count,
                    itemBuilder: (_, i) {
                      if (i >= msgs.length) {
                        // Before the first words: the orb thinks. Then the answer appears as it is written.
                        if (store.streamText.isEmpty) {
                          return const Padding(
                            padding: EdgeInsets.symmetric(vertical: 10),
                            child: Row(children: [Orb(size: 30, mode: OrbMode.thinking), SizedBox(width: 12), ThinkingDots()]),
                          );
                        }
                        return Padding(
                          padding: const EdgeInsets.only(top: 6, bottom: 14),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            MdText(store.streamText),
                            const Padding(padding: EdgeInsets.only(top: 2), child: Orb(size: 26, mode: OrbMode.writing)),
                          ]),
                        );
                      }
                      final m = msgs[i];
                      final bubble = m.isUser
                          ? _UserBubble(m, () async {
                              final t = await store.editFrom(i);
                              if (mounted) setState(() => _text.text = t);
                            })
                          : _Answer(m, reveal: m.ts == store.revealTs, last: i == msgs.length - 1, advanced: context.watch<LocalPrefs>().advanced, onTick: () => _toEnd(jump: true), onRetry: store.retry, onMore: () => _answerMenu(m, i == msgs.length - 1));
                      // Only the newest bubbles slide in; older ones must not animate again while scrolling.
                      return i >= msgs.length - 2 ? Appear(key: ValueKey(m.ts), dy: 10, child: bubble) : KeyedSubtree(key: ValueKey(m.ts), child: bubble);
                    },
                  ),
                ),
        ),
      ),
      _statusPill(),
      _composer(store),
    ]);
  }

  /// A small line above the box while AIy listens or reads aloud (thinking and writing show in the conversation itself).
  Widget _statusPill() {
    final s = Theme.of(context).colorScheme;
    return ValueListenableBuilder<bool>(
      valueListenable: Native.speaking,
      builder: (_, speaking, __) {
        final mode = _listening ? OrbMode.listening : (speaking ? OrbMode.speaking : null);
        return AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          child: mode == null
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(8, 4, 16, 4),
                    decoration: BoxDecoration(color: s.surfaceContainerHigh, borderRadius: BorderRadius.circular(999)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Orb(size: 30, mode: mode),
                      const SizedBox(width: 8),
                      Text(mode == OrbMode.listening ? 'Listening…' : 'Reading aloud…', style: Theme.of(context).textTheme.labelLarge),
                      if (mode == OrbMode.speaking) ...[
                        const SizedBox(width: 6),
                        InkWell(onTap: Native.stopSpeaking, child: Icon(Icons.stop_circle_outlined, size: 20, color: s.primary)),
                      ],
                    ]),
                  ),
                ),
        );
      },
    );
  }

  Widget _composer(ChatStore store) {
    final t = Theme.of(context);
    final s = t.colorScheme;
    final prefs = context.watch<LocalPrefs>();
    final canSend = !store.busy && (_text.text.trim().isNotEmpty || _image != null || _fileText.isNotEmpty);
    final advanced = prefs.advanced;
    final bottom = MediaQuery.of(context).padding.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(12, 4, 12, 10 + bottom),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        decoration: BoxDecoration(
          color: s.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: _listening ? s.primary : s.outlineVariant.withValues(alpha: 0.4), width: _listening ? 1.6 : 1),
          boxShadow: [BoxShadow(color: s.primary.withValues(alpha: _listening ? 0.35 : 0.12), blurRadius: _listening ? 28 : 18, spreadRadius: -4)],
        ),
        padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (_fileName.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 2),
              child: Align(
                alignment: Alignment.centerLeft,
                child: InputChip(
                  avatar: const Icon(Icons.description_outlined, size: 18),
                  label: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 220), child: Text(_fileName, maxLines: 1, overflow: TextOverflow.ellipsis)),
                  onDeleted: () => setState(() {
                    _fileName = '';
                    _fileText = '';
                    _image = null;
                  }),
                ),
              ),
            ),
          if (_image != null && _fileName.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 2),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Stack(clipBehavior: Clip.none, children: [
                  ClipRRect(borderRadius: BorderRadius.circular(14), child: Image.file(File(_image!), width: 76, height: 76, fit: BoxFit.cover)),
                  Positioned(
                    right: -8,
                    top: -8,
                    child: GestureDetector(
                      onTap: () => setState(() => _image = null),
                      child: CircleAvatar(radius: 12, backgroundColor: s.inverseSurface, child: Icon(Icons.close_rounded, size: 14, color: s.onInverseSurface)),
                    ),
                  ),
                ]),
              ),
            ),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            IconButton(tooltip: 'Add a photo', icon: const Icon(Icons.add_rounded), onPressed: _attach),
            Expanded(
              child: TextField(
                controller: _text,
                minLines: 1,
                maxLines: 6,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: _listening ? 'Listening…' : 'Ask AIy',
                  filled: false,
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
            if (advanced)
            PopupMenuButton<String>(
              tooltip: 'Which AI answers',
              icon: Icon(Icons.tune_rounded, color: prefs.preferProvider.isEmpty ? s.onSurfaceVariant : s.primary),
              onSelected: prefs.setPreferProvider,
              itemBuilder: (_) => [
                for (final e in const [('', 'Automatic (free ones first)'), ('gemini', 'Gemini first'), ('groq', 'Groq first'), ('openrouter', 'OpenRouter first')])
                  CheckedPopupMenuItem(value: e.$1, checked: prefs.preferProvider == e.$1, child: Text(e.$2)),
              ],
            ),
            IconButton(
              tooltip: prefs.liveSearch ? 'Live internet search is on' : 'Live internet search is off',
              icon: Icon(Icons.public_rounded, color: prefs.liveSearch ? s.primary : s.onSurfaceVariant),
              onPressed: () {
                prefs.setLiveSearch(!prefs.liveSearch);
                snack(context, prefs.liveSearch ? 'Live search off' : 'Live search on: answers can use Google Search (Gemini).');
              },
            ),
            IconButton(tooltip: 'Speak', icon: Icon(_listening ? Icons.stop_circle_outlined : Icons.mic_none_rounded, color: _listening ? s.primary : null), onPressed: _mic),
            Padding(
              padding: const EdgeInsets.only(bottom: 4, right: 2),
              child: AnimatedScale(
                scale: canSend || store.busy ? 1 : 0.85,
                duration: const Duration(milliseconds: 180),
                child: store.busy
                    ? IconButton.filled(tooltip: 'Stop', onPressed: store.stop, icon: const Icon(Icons.stop_rounded))
                    : IconButton.filled(
                        tooltip: 'Send',
                        onPressed: canSend ? _send : null,
                        icon: const Icon(Icons.arrow_upward_rounded),
                      ),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}

class _Welcome extends StatelessWidget {
  final ValueChanged<String> onPick;
  final bool listening;
  const _Welcome({super.key, required this.onPick, this.listening = false});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final name = (FirebaseAuth.instance.currentUser?.displayName ?? '').split(' ').first;
    return LayoutBuilder(
      builder: (_, box) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: box.maxHeight),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              const SizedBox(height: 12),
              Column(children: [
                Appear(child: Orb(size: 84, mode: listening ? OrbMode.listening : OrbMode.idle)),
                const SizedBox(height: 22),
                Appear(
                  delay: 100,
                  child: Text(name.isEmpty ? 'How can I help today?' : 'Hi $name,\nhow can I help?', textAlign: TextAlign.center, style: t.textTheme.headlineLarge?.copyWith(height: 1.15)),
                ),
              ]),
              Padding(
                padding: const EdgeInsets.only(top: 24, bottom: 12),
                child: Column(children: [
                  for (var i = 0; i < _suggestions.length; i++)
                    Appear(
                      delay: 220 + i * 80,
                      child: Pressable(
                        onTap: () => onPick(_suggestions[i].$3),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 11),
                          child: Row(children: [
                            Icon(_suggestions[i].$1, size: 22, color: t.colorScheme.onSurfaceVariant),
                            const SizedBox(width: 18),
                            Expanded(child: Text(_suggestions[i].$2, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w400))),
                          ]),
                        ),
                      ),
                    ),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _UserBubble extends StatelessWidget {
  final ChatMsg m;
  final VoidCallback onEdit;
  const _UserBubble(this.m, this.onEdit);
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final img = m.imagePath;
    final isPdf = (img ?? '').toLowerCase().endsWith('.pdf');
    return Align(
      alignment: Alignment.centerRight,
      child: GestureDetector(
        onLongPress: () async {
          final c = Provider.of<ChatStore>(context, listen: false);
          if (c.busy) return;
          final go = await showModalBottomSheet<bool>(
            context: context,
            builder: (b) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [ListTile(leading: const Icon(Icons.edit_outlined), title: const Text('Edit and ask again'), subtitle: const Text('This message and the answers after it are removed'), onTap: () => Navigator.pop(b, true)), ListTile(leading: const Icon(Icons.copy_rounded), title: const Text('Copy'), onTap: () {
              Clipboard.setData(ClipboardData(text: m.text));
              Navigator.pop(b, false);
            })])),
          );
          if (go == true) onEdit();
        },
        child: Container(
        margin: const EdgeInsets.only(left: 48, top: 8, bottom: 8),
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: t.colorScheme.primary.withValues(alpha: 0.18),
          borderRadius: const BorderRadius.only(topLeft: Radius.circular(22), topRight: Radius.circular(22), bottomLeft: Radius.circular(22), bottomRight: Radius.circular(6)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
          if (m.attachName.isNotEmpty || isPdf) Padding(padding: const EdgeInsets.fromLTRB(8, 6, 8, 2), child: Row(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.description_outlined, size: 18), const SizedBox(width: 6), Flexible(child: Text(m.attachName.isEmpty ? 'document.pdf' : m.attachName, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.labelLarge))])),
          if (img != null && !isPdf && File(img).existsSync()) ClipRRect(borderRadius: BorderRadius.circular(16), child: Image.file(File(img), width: 220, fit: BoxFit.cover)),
          if (m.text.isNotEmpty) Padding(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7), child: Text(m.text, style: t.textTheme.bodyLarge)),
        ]),
      ),
      ),
    );
  }
}

class _Answer extends StatelessWidget {
  final ChatMsg m;
  final bool reveal;
  final bool last;
  final VoidCallback onTick;
  final VoidCallback onRetry;
  final VoidCallback onMore;
  final bool advanced;
  const _Answer(this.m, {required this.reveal, required this.last, required this.advanced, required this.onTick, required this.onRetry, required this.onMore});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    if (m.failed) {
      return Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: ErrorBox(m.text, action: last ? 'Try again' : null, onAction: onRetry));
    }
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onLongPress: onMore,
      child: Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        reveal ? TypeReveal(m.text, onTick: last ? onTick : null) : MdText(m.text),
        if (m.note.isNotEmpty)
          Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(m.note, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant, fontStyle: FontStyle.italic))),
        if (m.sources.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Wrap(spacing: 6, runSpacing: 6, children: [
              for (final s in m.sources)
                ActionChip(
                  avatar: const Icon(Icons.link_rounded, size: 16),
                  label: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 180), child: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
                  onPressed: () => Native.openUrl(s.url),
                ),
            ]),
          ),
        Row(children: [
          if (m.provider.isNotEmpty && advanced) Flexible(child: ModelBadge('${m.provider} · ${m.model}')),
          const SizedBox(width: 4),
          IconButton(
            tooltip: 'Copy',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.copy_rounded, size: 17),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: m.text));
              snack(context, 'Copied');
            },
          ),
          if (last)
            IconButton(
              tooltip: 'Answer again',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              onPressed: onRetry,
            ),
          _SpeakButton(m.text),
          IconButton(
            tooltip: 'Share',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.ios_share_rounded, size: 17),
            onPressed: () => SharePlus.instance.share(ShareParams(text: m.text)),
          ),
          IconButton(tooltip: 'More', visualDensity: VisualDensity.compact, icon: const Icon(Icons.more_horiz_rounded, size: 19), onPressed: onMore),
        ]),
      ]),
    ),
    );
  }
}


/// Reads an answer aloud with the phone's voice; tap again to stop.
class _SpeakButton extends StatefulWidget {
  final String text;
  const _SpeakButton(this.text);
  @override
  State<_SpeakButton> createState() => _SpeakButtonState();
}

class _SpeakButtonState extends State<_SpeakButton> {
  bool _on = false;
  Timer? _t;

  @override
  void dispose() {
    _t?.cancel();
    if (_on) {
      Native.stopSpeaking();
      Native.speaking.value = false;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: _on ? 'Stop reading' : 'Read aloud',
        visualDensity: VisualDensity.compact,
        icon: Icon(_on ? Icons.stop_circle_outlined : Icons.volume_up_outlined, size: 18),
        onPressed: () {
          if (_on) {
            Native.stopSpeaking();
            Native.speaking.value = false;
            _t?.cancel();
            setState(() => _on = false);
          } else {
            Native.speak(widget.text.replaceAll(RegExp(r'[*`#>]+'), ' '));
            Native.speaking.value = true;
            setState(() => _on = true);
            _t = Timer(Duration(seconds: (widget.text.length / 12).clamp(2, 600).round()), () {
              Native.speaking.value = false;
              if (mounted) setState(() => _on = false);
            });
          }
        },
      );
}
