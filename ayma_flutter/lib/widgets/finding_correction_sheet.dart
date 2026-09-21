import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../screens/usage_screen.dart';
import '../theme.dart';

/// One correction reply from the backend — Ayma's own words, plus whether
/// this particular send hit the shared credit cap.
class CorrectionReply {
  const CorrectionReply({required this.text, this.usageCapped = false});
  final String text;
  final bool usageCapped;
}

/// Sends [message] as a free-text correction and returns Ayma's reply. The
/// caller owns updating its own displayed value from whatever the backend
/// call returned — this sheet only ever renders the conversation.
typedef CorrectionSender = Future<CorrectionReply> Function(String message);

/// The tap-a-claim, "tell Ayma what's wrong in your own words" sheet shared
/// by the Appearance and web-search report screens.
///
/// Visually and interactionally this mirrors Your Story's "Edit with Ayma"
/// sheet (`widgets/ask_ayma_overlay.dart`) closely on purpose — the founder
/// wants the same pattern everywhere a claim can be corrected: a dark scrim,
/// a bottom sheet, the tapped claim shown as a quoted card up top, a short
/// message thread, and a plain composer. It's a narrower widget than that
/// one, though: a finding is a single structured value, not open prose, so
/// this always talks to a single request/reply correction endpoint (one
/// exchange applies or doesn't) rather than the general multi-turn
/// `/chat` + tools pipeline — no voice, no image attachments, no quick
/// suggestion chips for "make public"/"delete" (nothing here to toggle).
Future<void> showFindingCorrectionSheet(
  BuildContext context, {
  required String title,
  required String currentValue,
  required CorrectionSender onSend,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.45),
    builder: (_) => _FindingCorrectionSheet(
      title: title,
      currentValue: currentValue,
      onSend: onSend,
    ),
  );
}

class _Msg {
  const _Msg(this.role, this.text, {this.capped = false});
  final String role; // 'user' | 'ayma'
  final String text;
  final bool capped;
}

class _FindingCorrectionSheet extends StatefulWidget {
  const _FindingCorrectionSheet({
    required this.title,
    required this.currentValue,
    required this.onSend,
  });

  final String title;
  final String currentValue;
  final CorrectionSender onSend;

  @override
  State<_FindingCorrectionSheet> createState() =>
      _FindingCorrectionSheetState();
}

class _FindingCorrectionSheetState extends State<_FindingCorrectionSheet> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  final List<_Msg> _messages = [];
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (_sending || text.isEmpty) return;
    setState(() {
      _sending = true;
      _messages.add(_Msg('user', text));
      _controller.clear();
    });
    _scrollToEnd();
    try {
      final reply = await widget.onSend(text);
      if (!mounted) return;
      setState(() => _messages
          .add(_Msg('ayma', reply.text, capped: reply.usageCapped)));
    } catch (_) {
      if (!mounted) return;
      setState(() => _messages.add(
          const _Msg('ayma', "Sorry, that didn't go through. Try again?")));
    } finally {
      if (mounted) setState(() => _sending = false);
      _scrollToEnd();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final mq = MediaQuery.of(context);
    return AnimatedPadding(
      duration: const Duration(milliseconds: 150),
      padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
      child: FractionallySizedBox(
        heightFactor: mq.viewInsets.bottom > 0 ? 0.86 : 0.55,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: ac.bg,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
            border: Border(
              top: BorderSide(color: ac.lineSoft, width: 0.5),
              left: BorderSide(color: ac.lineSoft, width: 0.5),
              right: BorderSide(color: ac.lineSoft, width: 0.5),
            ),
          ),
          child: Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: ac.lineSoft,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    Icon(Icons.auto_awesome, size: 16, color: ac.accent),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('Correct with Ayma',
                          style: AymaType.serif(size: 19, color: ac.fg)),
                    ),
                    Semantics(
                      button: true,
                      label: 'Close',
                      child: InkWell(
                        borderRadius: BorderRadius.circular(20),
                        onTap: () => Navigator.of(context).pop(),
                        child: Padding(
                          padding: const EdgeInsets.all(6),
                          child: Icon(Icons.close, size: 20, color: ac.fgDim),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Text(
                  "Tell Ayma what's wrong, in your own words.",
                  style: AymaType.sans(size: 13, color: ac.fgMute),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: _ClaimQuote(title: widget.title, value: widget.currentValue),
              ),
              Expanded(
                child: _messages.isEmpty
                    ? const SizedBox.shrink()
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                        itemCount: _messages.length + (_sending ? 1 : 0),
                        itemBuilder: (context, i) {
                          if (i >= _messages.length) {
                            return const _StatusRow();
                          }
                          return _MessageRow(msg: _messages[i]);
                        },
                      ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 12, 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _controller,
                          focusNode: _focus,
                          minLines: 1,
                          maxLines: 4,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => _send(),
                          decoration: const InputDecoration(
                            hintText: 'Say what you mean…',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filled(
                        onPressed: _sending || _controller.text.trim().isEmpty
                            ? null
                            : _send,
                        icon: const Icon(Icons.arrow_upward),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ClaimQuote extends StatelessWidget {
  const _ClaimQuote({required this.title, required this.value});
  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ac.bgElev,
        borderRadius: BorderRadius.circular(12),
        border: Border(left: BorderSide(color: ac.accent, width: 2.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title.toUpperCase(),
              style: AymaType.mono(size: 9, color: ac.fgMute)
                  .copyWith(letterSpacing: 1.4)),
          const SizedBox(height: 6),
          Text(
            value.isEmpty ? '(not yet known)' : value,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: AymaType.serif(size: 15, color: ac.fg).copyWith(height: 1.4),
          ),
        ],
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow();

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 1.6, color: ac.accent),
          ),
          const SizedBox(width: 10),
          Text('Thinking…', style: AymaType.sans(size: 12.5, color: ac.fgMute)),
        ],
      ),
    );
  }
}

class _MessageRow extends StatelessWidget {
  const _MessageRow({required this.msg});
  final _Msg msg;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final isUser = msg.role == 'user';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints:
              BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
          child: Column(
            crossAxisAlignment:
                isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              isUser
                  ? Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: ac.accentSoft,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(msg.text,
                          style: AymaType.sans(size: 14, color: ac.fg)),
                    )
                  : Text(
                      msg.text,
                      style: AymaType.serif(size: 15, color: ac.fg)
                          .copyWith(height: 1.4),
                    ),
              if (msg.capped)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: FilledButton.tonalIcon(
                    onPressed: () => context.push(UsageScreen.path),
                    icon: const Icon(Icons.bolt, size: 18),
                    label: const Text('Reload credits'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
