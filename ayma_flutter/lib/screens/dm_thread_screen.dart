import 'package:flutter/material.dart';

import '../services/dm_service.dart';
import '../theme.dart';

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
  bool _sending = false;
  List<String> _icebreakers = const [];

  @override
  void initState() {
    super.initState();
    _loadIcebreakers();
  }

  @override
  void dispose() {
    _composer.dispose();
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
      if (mounted) setState(() => _icebreakers = const []);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Not sent ($e).')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
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
            },
            itemBuilder: (_) => const [
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
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final msgs = snap.data!;
                if (msgs.isEmpty) {
                  return Center(
                    child: Text('Say something.',
                        style: AymaType.sans(
                            size: 15, soft: true, color: ac.fgMute)),
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  itemCount: msgs.length,
                  itemBuilder: (context, i) => _Bubble(
                    message: msgs[i],
                    mine: msgs[i].senderUid == me,
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
                setState(() => _icebreakers = const []);
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
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Icebreakers',
              style: AymaType.sans(size: 12, soft: true, color: ac.fgMute)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final c in chips)
                ActionChip(
                  label: Text(c),
                  onPressed: () => onTap(c),
                ),
            ],
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
