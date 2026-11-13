import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../state/app_builder.dart';
import '../../state/chat_store.dart';
import '../../state/code_state.dart';
import '../../state/share_inbox.dart';
import '../../state/updater.dart';
import '../widgets/common.dart';
import '../widgets/fx.dart';
import 'build_view.dart';
import 'chat_view.dart';
import 'code_view.dart';
import 'history_screen.dart';
import 'settings_screen.dart';

/// The app's frame: top bar with the Chat / Code switch, the side menu, and the two modes.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  final _scaffold = GlobalKey<ScaffoldState>();
  int _mode = 0; // 0 chat, 1 code, 2 build
  String _search = '';
  String _folder = ''; // '' = all chats
  bool _asking = false;

  /// Something was shared into AIy: ask where it should go.
  Future<void> _askWhere(ShareInbox inbox) async {
    final it = inbox.pending;
    if (it == null) return;
    if (it.isEmpty) {
      inbox.dismiss();
      if (mounted) snack(context, 'Could not read what was shared${it.problem.isEmpty ? '' : ' (${it.problem})'}.');
      return;
    }
    final canCode = it.files.any((f) => f.isZip || f.isImage) || it.fullText.isNotEmpty;
    final canBuild = it.fullText.isNotEmpty;
    final pick = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (b) {
        final t = Theme.of(b);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 16, 8, 12),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text('Shared with AIy', style: t.textTheme.titleLarge)),
              Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 10), child: Text(it.preview, maxLines: 3, overflow: TextOverflow.ellipsis, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant))),
              ListTile(leading: const Icon(Icons.chat_bubble_outline_rounded), title: const Text('Chat'), subtitle: const Text('Ask AIy about it'), onTap: () => Navigator.pop(b, 'chat')),
              ListTile(
                leading: const Icon(Icons.code_rounded),
                title: const Text('Code'),
                subtitle: Text(canCode ? 'A zip opens as a project, a picture shows the problem, text becomes the request' : 'Needs a project zip, a picture or some text'),
                enabled: canCode,
                onTap: () => Navigator.pop(b, 'code'),
              ),
              ListTile(
                leading: const Icon(Icons.construction_rounded),
                title: const Text('Build'),
                subtitle: Text(canBuild ? 'Use the text as the idea for a new app' : 'Needs some text to use as the idea'),
                enabled: canBuild,
                onTap: () => Navigator.pop(b, 'build'),
              ),
              ListTile(leading: const Icon(Icons.close_rounded), title: const Text('Not now'), onTap: () => Navigator.pop(b)),
            ]),
          ),
        );
      },
    );
    if (!mounted) return;
    if (pick == null) {
      inbox.dismiss();
      return;
    }
    inbox.choose(pick);
    setState(() => _mode = pick == 'chat' ? 0 : (pick == 'code' ? 1 : 2));
  }

  Future<String?> _askName(String title, {String initial = '', String ok = 'Save'}) {
    final c = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(title),
        content: TextField(controller: c, autofocus: true, maxLength: 30, textCapitalization: TextCapitalization.sentences, decoration: const InputDecoration(hintText: 'Folder name')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(d, c.text.trim()), child: Text(ok)),
        ],
      ),
    );
  }

  Future<void> _newFolder(ChatStore chat, {Conversation? moveHere}) async {
    final n = await _askName('New folder', ok: 'Create');
    if (n == null || n.isEmpty) return;
    final made = await chat.addFolder(n);
    if (!mounted) return;
    if (!made) {
      snack(context, 'There is already a folder with that name, or the name is not allowed.');
      return;
    }
    if (moveHere != null) await chat.moveTo(moveHere, n);
  }

  Future<void> _moveSheet(ChatStore chat, Conversation c) async {
    final pick = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (b) => SafeArea(
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Padding(padding: EdgeInsets.fromLTRB(24, 16, 24, 8), child: Align(alignment: Alignment.centerLeft, child: Text('Move to a folder', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)))),
            ListTile(leading: Icon(c.folder.isEmpty ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded), title: const Text('No folder'), onTap: () => Navigator.pop(b, '')),
            for (final f in chat.folders) ListTile(leading: Icon(c.folder == f ? Icons.folder_rounded : Icons.folder_outlined), title: Text(f), onTap: () => Navigator.pop(b, f)),
            ListTile(leading: const Icon(Icons.create_new_folder_outlined), title: const Text('New folder…'), onTap: () => Navigator.pop(b, '\u0001new')),
            const SizedBox(height: 8),
          ]),
        ),
      ),
    );
    if (!mounted || pick == null) return;
    if (pick == '\u0001new') {
      await _newFolder(chat, moveHere: c);
    } else {
      await chat.moveTo(c, pick);
    }
  }

  Future<void> _folderMenu(ChatStore chat, String name) async {
    final pick = await showModalBottomSheet<String>(
      context: context,
      builder: (b) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.edit_outlined), title: const Text('Rename the folder'), onTap: () => Navigator.pop(b, 'rename')),
          ListTile(leading: const Icon(Icons.folder_delete_outlined), title: const Text('Delete the folder'), subtitle: const Text('Its chats stay, without a folder'), onTap: () => Navigator.pop(b, 'delete')),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (!mounted || pick == null) return;
    if (pick == 'rename') {
      final n = await _askName('Rename the folder', initial: name);
      if (n != null && n.isNotEmpty) {
        await chat.renameFolder(name, n);
        if (_folder == name && mounted) setState(() => _folder = n);
      }
    } else if (await confirmDialog(context, 'Delete the folder "$name"?', body: 'The chats in it are kept.', yes: 'Delete')) {
      await chat.deleteFolder(name);
      if (_folder == name && mounted) setState(() => _folder = '');
    }
  }

  void _open(Widget screen) => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => screen));

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final chat = context.watch<ChatStore>();
    final code = context.watch<CodeState>();
    final builder = context.watch<AppBuilder>();
    final update = context.watch<UpdateService>();
    final inbox = context.watch<ShareInbox>();
    if (inbox.pending != null && !_asking) {
      _asking = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await _askWhere(inbox);
        _asking = false;
      });
    }
    final user = FirebaseAuth.instance.currentUser;
    final initial = ((user?.displayName ?? user?.email ?? 'A').trim().isEmpty ? 'A' : (user?.displayName ?? user?.email ?? 'A').trim()[0]).toUpperCase();
    final empty = _mode == 0 ? chat.current.messages.isEmpty : (_mode == 1 ? !code.hasSource : builder.current == null);
    return Scaffold(
      key: _scaffold,
      drawer: _drawer(chat, code),
      body: AuroraBackground(
        strength: empty ? 1 : 0.35,
        child: SafeArea(
          bottom: false,
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 6, 12, 6),
              child: Row(children: [
                IconButton(tooltip: 'Menu', icon: const Icon(Icons.menu_rounded), onPressed: () => _scaffold.currentState?.openDrawer()),
                const SizedBox(width: 2),
                _ModeSwitch(mode: _mode, onChanged: (m) => setState(() => _mode = m)),
                const Spacer(),
                if (update.hasUpdate)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: FilledButton.tonal(
                      style: FilledButton.styleFrom(minimumSize: const Size(0, 38), padding: const EdgeInsets.symmetric(horizontal: 14)),
                      onPressed: () => _open(const SettingsScreen()),
                      child: const Text('Update'),
                    ),
                  ),
                if (_mode == 0)
                  IconButton(tooltip: 'New chat', icon: const Icon(Icons.edit_square), onPressed: chat.busy ? null : chat.newChat)
                else if (_mode == 2)
                  IconButton(tooltip: 'New app', icon: const Icon(Icons.add_rounded), onPressed: builder.isBusy ? null : builder.newProject)
                else
                  IconButton(tooltip: 'History', icon: const Icon(Icons.history_rounded), onPressed: () => _open(const HistoryScreen())),
                const SizedBox(width: 4),
                Pressable(
                  onTap: () => _open(const SettingsScreen()),
                  child: CircleAvatar(
                    radius: 18,
                    backgroundColor: t.colorScheme.primary,
                    foregroundImage: user?.photoURL == null ? null : NetworkImage(user!.photoURL!),
                    child: Text(initial, style: TextStyle(color: t.colorScheme.onPrimary, fontWeight: FontWeight.w700)),
                  ),
                ),
              ]),
            ),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 320),
                switchInCurve: Curves.easeOutCubic,
                transitionBuilder: (child, a) => FadeTransition(
                  opacity: a,
                  child: SlideTransition(position: Tween(begin: const Offset(0.04, 0), end: Offset.zero).animate(a), child: child),
                ),
                child: _mode == 0 ? const ChatView(key: ValueKey('chat')) : (_mode == 1 ? const CodeView(key: ValueKey('code')) : BuildView(key: const ValueKey('build'), onOpenCode: () => setState(() => _mode = 1))),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _drawer(ChatStore chat, CodeState code) {
    final t = Theme.of(context);
    final q = _search.trim().toLowerCase();
    final folder = chat.folders.contains(_folder) ? _folder : '';
    final list = chat.all.where((c) {
      if (folder.isNotEmpty && c.folder != folder) return false;
      if (q.isEmpty) return true;
      return c.title.toLowerCase().contains(q) || c.messages.any((m) => m.text.toLowerCase().contains(q));
    }).toList();
    return Drawer(
      child: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 16, 8),
            child: Row(children: [
              const Orb(size: 34),
              const SizedBox(width: 10),
              Text('AIy', style: t.textTheme.titleLarge),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
            child: TextField(
              onChanged: (v) => setState(() => _search = v),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Search chats',
                prefixIcon: const Icon(Icons.search_rounded, size: 20),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(999), borderSide: BorderSide.none),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.edit_square),
            title: const Text('New chat'),
            onTap: () {
              chat.newChat();
              setState(() => _mode = 0);
              Navigator.pop(context);
            },
          ),
          SizedBox(
            height: 46,
            child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 14), children: [
              Padding(padding: const EdgeInsets.only(right: 8, top: 6, bottom: 6), child: ChoiceChip(label: const Text('All'), selected: folder.isEmpty, onSelected: (_) => setState(() => _folder = ''))),
              for (final f in chat.folders)
                Padding(
                  padding: const EdgeInsets.only(right: 8, top: 6, bottom: 6),
                  child: GestureDetector(
                    onLongPress: () => _folderMenu(chat, f),
                    child: ChoiceChip(avatar: const Icon(Icons.folder_outlined, size: 16), label: Text(f), selected: folder == f, onSelected: (_) => setState(() => _folder = f)),
                  ),
                ),
              Padding(padding: const EdgeInsets.only(top: 6, bottom: 6), child: ActionChip(avatar: const Icon(Icons.add_rounded, size: 16), label: const Text('Folder'), onPressed: () => _newFolder(chat))),
            ]),
          ),
          Padding(padding: const EdgeInsets.fromLTRB(20, 6, 20, 4), child: Text(folder.isEmpty ? 'Chats' : folder, style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSurfaceVariant))),
          Expanded(
            child: list.isEmpty
                ? Padding(padding: const EdgeInsets.all(20), child: Text(q.isEmpty ? 'Your chats will appear here.' : 'Nothing found.', style: TextStyle(color: t.colorScheme.onSurfaceVariant)))
                : ListView.builder(
                    padding: EdgeInsets.zero,
                    itemCount: list.length,
                    itemBuilder: (_, i) {
                      final c = list[i];
                      final sel = identical(c, chat.current);
                      return ListTile(
                        dense: true,
                        selected: sel,
                        selectedTileColor: t.colorScheme.primary.withValues(alpha: 0.12),
                        shape: const StadiumBorder(),
                        contentPadding: const EdgeInsets.only(left: 20, right: 4),
                        title: Text(c.title.isEmpty ? 'New chat' : c.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: folder.isEmpty && c.folder.isNotEmpty ? Text(c.folder, maxLines: 1, overflow: TextOverflow.ellipsis) : null,
                        trailing: PopupMenuButton<String>(
                          tooltip: 'More',
                          icon: const Icon(Icons.more_vert_rounded, size: 18),
                          onSelected: (v) async {
                            if (v == 'move') {
                              await _moveSheet(chat, c);
                            } else if (await confirmDialog(context, 'Delete this chat?', yes: 'Delete')) {
                              chat.delete(c);
                            }
                          },
                          itemBuilder: (_) => const [PopupMenuItem(value: 'move', child: Text('Move to a folder')), PopupMenuItem(value: 'delete', child: Text('Delete'))],
                        ),
                        onTap: () {
                          chat.open(c);
                          setState(() => _mode = 0);
                          Navigator.pop(context);
                        },
                      );
                    },
                  ),
          ),
          const Divider(height: 1),
          if (chat.current.messages.isNotEmpty)
            ListTile(
              leading: const Icon(Icons.ios_share_rounded),
              title: const Text('Share this chat'),
              onTap: () {
                Navigator.pop(context);
                SharePlus.instance.share(ShareParams(text: chat.exportText(chat.current), subject: chat.current.title));
              },
            ),
          ListTile(
            leading: const Icon(Icons.history_rounded),
            title: const Text('History'),
            trailing: code.history.isEmpty ? null : Text('${code.history.length}'),
            onTap: () {
              Navigator.pop(context);
              _open(const HistoryScreen());
            },
          ),
          ListTile(
            leading: const Icon(Icons.settings_outlined),
            title: const Text('Settings'),
            onTap: () {
              Navigator.pop(context);
              _open(const SettingsScreen());
            },
          ),
        ]),
      ),
    );
  }
}

/// The Chat | Code | Build pill: the chosen part shows its name, the others only an icon.
class _ModeSwitch extends StatelessWidget {
  final int mode;
  final ValueChanged<int> onChanged;
  const _ModeSwitch({required this.mode, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    const items = [('Chat', Icons.chat_bubble_outline_rounded), ('Code', Icons.code_rounded), ('Build', Icons.construction_rounded)];
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: s.surfaceContainerHigh.withValues(alpha: 0.9), borderRadius: BorderRadius.circular(999)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        for (var i = 0; i < items.length; i++)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onChanged(i),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              height: 38,
              width: mode == i ? 92 : 44,
              decoration: BoxDecoration(color: mode == i ? s.primary : Colors.transparent, borderRadius: BorderRadius.circular(999)),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(items[i].$2, size: 17, color: mode == i ? s.onPrimary : s.onSurfaceVariant),
                if (mode == i)
                  Flexible(
                    child: Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: Text(items[i].$1, maxLines: 1, softWrap: false, overflow: TextOverflow.clip, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: s.onPrimary)),
                    ),
                  ),
              ]),
            ),
          ),
      ]),
    );
  }
}
