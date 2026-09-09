import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/app_context.dart';
import '../services/chat_inbox.dart';
import '../services/dm_service.dart';
import '../theme.dart';
import '../widgets/staggered.dart';
import 'main_shell_screen.dart';

/// One DM conversation (§6.6, §6.11 step 9). Text send is wired; photo/voice
/// use the same message pipeline once a file is uploaded (Step 51 ingests them).
/// Icebreaker chips (§6.9) show above the composer while the thread is empty and
/// a compatibility check has produced a `matches` doc for the pair.
class DmThreadScreen extends StatefulWidget {
  const DmThreadScreen({
    super.key,
    required this.threadId,
    this.title = 'Conversation',
    this.dmService,
  });

  static const path = '/dm';

  final String threadId;
  final String title;
  final DmService? dmService;

  @override
  State<DmThreadScreen> createState() => _DmThreadScreenState();
}

class _DmThreadScreenState extends State<DmThreadScreen> {
  late final DmService _dm = widget.dmService ?? DmService();
  final _composer = TextEditingController();
  final _composerFocus = FocusNode();
  bool _sending = false;
  List<String> _icebreakers = const [];

  @override
  void initState() {
    super.initState();
    AppContext.instance.set(
      screen: 'dm',
      subjectUid: _safeOtherUid(),
      subjectName: widget.title == 'Conversation' ? '' : widget.title,
    );
    _loadIcebreakers();
  }

  String _safeOtherUid() {
    try {
      return _dm.otherUidOf(widget.threadId);
    } catch (_) {
      return '';
    }
  }

  @override
  void dispose() {
    _composer.dispose();
    _composerFocus.dispose();
    super.dispose();
  }

  Future<void> _loadIcebreakers() async {
    try {
      final chips = await _dm.icebreakers(widget.threadId);
      if (mounted) setState(() => _icebreakers = chips);
    } catch (_) {
      // Icebreakers are a nicety — never surface a failure here.
    }
  }

  Future<void> _send() async {
    final text = _composer.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    _composer.clear();
    try {
      await _dm.sendText(widget.threadId, text);
      // Keep the conversation-starters around — they're common ground to talk
      // about, not one-shot openers.
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Not sent ($e).')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _askAyma() {
    final name = widget.title == 'Conversation' ? 'them' : widget.title;
    ChatInbox.instance.push(ChatKickoff.talkAbout(
      targetUid: _dm.otherUidOf(widget.threadId),
      label: name,
      conversation: true,
      shareKind: 'conversation',
      refId: widget.threadId,
    ));
    context.go(MainShellScreen.path);
  }

  Future<void> _blockAndReport() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Block & report'),
        content: const Text(
          'They will no longer be able to message you, this thread is hidden, '
          'and they drop out of your matches. This cannot be undone here.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Block')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _dm.block(_dm.otherUidOf(widget.threadId));
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not block ($e).')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final me = _dm.uid;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'block') _blockAndReport();
              if (v == 'ask_ayma') _askAyma();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                  value: 'ask_ayma',
                  child: Text('Share this chat with Ayma')),
              PopupMenuItem(value: 'block', child: Text('Block & report')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<List<DmMessage>>(
              stream: _dm.watchMessages(widget.threadId),
              builder: (context, snap) {
                final msgs = snap.data ?? const <DmMessage>[];
                // A brand-new thread has no doc yet; the stream can be briefly
                // empty or (transiently) error — never hang the screen on it.
                if (msgs.isEmpty) {
                  if (snap.connectionState == ConnectionState.waiting &&
                      !snap.hasError) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  return Center(
                    child: Text('Say something.',
                        style: AymaType.sans(
                            size: 15, soft: true, color: ac.fgMute)),
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  itemCount: msgs.length,
                  itemBuilder: (context, i) => FadeSlideIn(
                    delay: staggerDelay(i),
                    offset: 8,
                    child: _Bubble(
                      message: msgs[i],
                      mine: msgs[i].senderUid == me,
                    ),
                  ),
                );
              },
            ),
          ),
          if (_icebreakers.isNotEmpty)
            _IcebreakerBar(
              chips: _icebreakers,
              onTap: (text) {
                _composer.text = text;
                _composer.selection = TextSelection.collapsed(
                    offset: _composer.text.length);
                _composerFocus.requestFocus();
              },
            ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _composer,
                      focusNode: _composerFocus,
                      minLines: 1,
                      maxLines: 4,
                      decoration:
                          const InputDecoration(hintText: 'Message', isDense: true),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _sending ? null : _send,
                    icon: const Icon(Icons.arrow_upward_rounded),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _IcebreakerBar extends StatelessWidget {
  const _IcebreakerBar({required this.chips, required this.onTap});
  final List<String> chips;
  final void Function(String) onTap;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: ac.lineSoft, width: 0.5)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Things to talk about',
              style: AymaType.sans(size: 12, soft: true, color: ac.fgMute)),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 168),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final c in chips)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: InkWell(
                        onTap: () => onTap(c),
                        borderRadius: BorderRadius.circular(14),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(
                            color: ac.bgCard,
                            borderRadius: BorderRadius.circular(14),
                            border:
                                Border.all(color: ac.lineSoft, width: 0.5),
                          ),
                          child: Text(
                            c,
                            softWrap: true,
                            style: AymaType.sans(size: 13, color: ac.fg),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.mine});
  final DmMessage message;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final label = switch (message.type) {
      'photo' => '📷 Photo',
      'voice' => '🎙 Voice message',
      'shared_profile' => '👤 Shared a profile',
      _ => message.body,
    };
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        decoration: BoxDecoration(
          color: mine ? ac.accentSoft : ac.bgCard,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: ac.lineSoft, width: 0.5),
        ),
        child: Text(label,
            style: AymaType.sans(size: 15, color: ac.fg, height: 1.4)),
      ),
    );
  }
}
