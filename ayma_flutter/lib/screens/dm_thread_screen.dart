import 'package:flutter/material.dart';

import '../services/dm_service.dart';
import '../theme.dart';

/// One DM conversation (§6.6, §6.11 step 9). Text send is wired; photo/voice
/// use the same message pipeline once a file is uploaded (Step 51 ingests them).
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

  @override
  void dispose() {
    _composer.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _composer.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    _composer.clear();
    try {
      await _dm.sendText(widget.threadId, text);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Not sent ($e).')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final me = _dm.uid;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
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
