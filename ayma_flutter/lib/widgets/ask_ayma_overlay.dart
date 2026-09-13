import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/api_client.dart';
import '../services/chat_service.dart';
import '../services/ids.dart';
import '../theme.dart';
import 'chat_composer.dart';
import 'out_of_credits.dart';

/// What one Ask Ayma turn is scoped to — either a highlighted passage inside
/// a section, or one entry of the structured career timeline. Carries exactly
/// what `skills/story_edit.py`'s tools need: `pageId`/`selectedText` map to
/// `story_page_id`/`story_passage`; `timelineEntryId` maps to the newer
/// `story_timeline_entry_id` field, which scopes `edit_career_timeline_entry`
/// / `delete_career_timeline_entry` instead.
class AskAymaContext {
  const AskAymaContext({
    required this.pageId,
    this.selectedText = '',
    this.sectionTitle = '',
    this.timelineEntryId = '',
    this.timelineEntryLabel = '',
  });

  final String pageId;
  final String selectedText;
  final String sectionTitle;
  final String timelineEntryId;
  final String timelineEntryLabel;

  bool get isTimelineEntry => timelineEntryId.isNotEmpty;
}

/// Opens the Ask Ayma overlay: a dark scrim, a bottom sheet sliding up over
/// the document (Android back / tap-outside dismiss it, same as any modal
/// sheet), carrying the exact context above into the real `/chat` (or
/// `/chat/stream`) pipeline — the same one ordinary passage edits already use.
///
/// [onExchange] fires after every reply Ayma gives while the sheet is open
/// (not just once at the end) so the caller can quietly re-fetch the section
/// and flash the sentence that changed while the user is still mid-conversation,
/// without leaving the document. Returns once the sheet is dismissed.
Future<void> showAskAymaOverlay(
  BuildContext context, {
  required ApiClient api,
  required AskAymaContext ctx,
  VoidCallback? onExchange,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.45),
    builder: (_) => _AskAymaSheet(api: api, ctx: ctx, onExchange: onExchange),
  );
}

class _Msg {
  const _Msg(this.role, this.text);
  final String role; // 'user' | 'ayma'
  final String text;
}

const _quickSuggestions = [
  'Make this more concise',
  'Add more details',
  'Mark as private',
  'Rewrite in my tone',
  'Delete',
];

class _AskAymaSheet extends StatefulWidget {
  const _AskAymaSheet({required this.api, required this.ctx, this.onExchange});

  final ApiClient api;
  final AskAymaContext ctx;
  final VoidCallback? onExchange;

  @override
  State<_AskAymaSheet> createState() => _AskAymaSheetState();
}

class _AskAymaSheetState extends State<_AskAymaSheet> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  final _picker = ImagePicker();
  final _chatService = ChatService();
  final String _sessionId = newSessionId();
  static final ValueNotifier<double> _zero = ValueNotifier<double>(0);

  final List<_Msg> _messages = [];
  bool _sending = false;
  String? _statusLabel;
  File? _pendingImage;

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

  Future<void> _attach() async {
    try {
      final x = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
      if (x == null || !mounted) return;
      setState(() => _pendingImage = File(x.path));
    } catch (_) {
      // Picker cancelled/unavailable — nothing to attach, no error surface.
    }
  }

  Future<void> _send([String? preset]) async {
    final text = (preset ?? _controller.text).trim();
    final image = _pendingImage;
    if (_sending || (text.isEmpty && image == null)) return;

    final window = [for (final m in _messages) {'role': m.role, 'text': m.text}];
    setState(() {
      _sending = true;
      _messages.add(_Msg('user', text.isEmpty ? '(shared a photo)' : text));
      _controller.clear();
      _pendingImage = null;
      _statusLabel = 'Thinking…';
    });
    _scrollToEnd();

    var imagePath = '';
    if (image != null) {
      try {
        final up = await _chatService.uploadChatImage(image);
        imagePath = up.storagePath;
      } catch (_) {
        // Upload failed — still send the text, just without the photo.
      }
    }

    try {
      ChatResult? result;
      try {
        await for (final ev in widget.api.chatStream(
          text.isEmpty ? '(shared a photo)' : text,
          sessionId: _sessionId,
          recentTurns: window,
          imagePath: imagePath,
          storyPageId: widget.ctx.pageId,
          storyPassage: widget.ctx.isTimelineEntry ? '' : widget.ctx.selectedText,
          storyTimelineEntryId: widget.ctx.timelineEntryId,
        )) {
          if (!mounted) return;
          if (ev is ChatStatus) {
            setState(() => _statusLabel = ev.label);
          } else if (ev is ChatReplyEvent) {
            result = ev.result;
          }
        }
      } on ApiException {
        result = await widget.api.chat(
          text.isEmpty ? '(shared a photo)' : text,
          sessionId: _sessionId,
          recentTurns: window,
          imagePath: imagePath,
          storyPageId: widget.ctx.pageId,
          storyPassage: widget.ctx.isTimelineEntry ? '' : widget.ctx.selectedText,
          storyTimelineEntryId: widget.ctx.timelineEntryId,
        );
      }
      if (!mounted) return;
      final r = result;
      if (r == null) {
        setState(() => _messages.add(
            const _Msg('ayma', "Sorry, that didn't go through. Try again?")));
      } else {
        setState(() => _messages.add(_Msg('ayma', r.reply)));
        if (r.usageCapped) {
          showOutOfCreditsSnack(context);
        } else {
          // Let the document catch up in place — while the sheet is still
          // open, not just once it closes.
          widget.onExchange?.call();
        }
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _messages.add(
          const _Msg('ayma', "Sorry, that didn't go through. Try again?")));
    } finally {
      if (mounted) setState(() { _sending = false; _statusLabel = null; });
      _scrollToEnd();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final mq = MediaQuery.of(context);
    final selected = widget.ctx.isTimelineEntry
        ? widget.ctx.timelineEntryLabel
        : widget.ctx.selectedText;

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
                      child: Text('Edit with Ayma',
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
                  "Tell Ayma what you'd like to change, add, or refine.",
                  style: AymaType.sans(size: 13, color: ac.fgMute),
                ),
              ),
              if (selected.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: _SelectedQuote(text: selected),
                ),
              Expanded(
                child: _messages.isEmpty && _statusLabel == null
                    ? Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: _QuickChips(
                            onPick: (s) {
                              _controller.text = s;
                              _send(s);
                            },
                          ),
                        ),
                      )
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                        itemCount: _messages.length + (_statusLabel != null ? 1 : 0),
                        itemBuilder: (context, i) {
                          if (i >= _messages.length) {
                            return _StatusRow(label: _statusLabel!);
                          }
                          return _MessageRow(msg: _messages[i]);
                        },
                      ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
                  child: ChatComposer(
                    mode: ComposerMode.text,
                    controller: _controller,
                    focusNode: _focus,
                    canSend: !_sending &&
                        (_controller.text.trim().isNotEmpty || _pendingImage != null),
                    onSend: _send,
                    onAttach: _attach,
                    onMicPressed: () {
                      ScaffoldMessenger.of(context)
                        ..clearSnackBars()
                        ..showSnackBar(const SnackBar(
                            content: Text('Open the Ayma tab to talk by voice.')));
                    },
                    onStopPressed: () {},
                    onMuteTap: () {},
                    muted: false,
                    userAmplitude: _zero,
                    aiAmplitude: _zero,
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

class _SelectedQuote extends StatelessWidget {
  const _SelectedQuote({required this.text});
  final String text;

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
          Text('SELECTED TEXT',
              style: AymaType.mono(size: 9, color: ac.fgMute)
                  .copyWith(letterSpacing: 1.4)),
          const SizedBox(height: 6),
          Text(
            '"$text"',
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: AymaType.serif(size: 14, italic: true, color: ac.fg)
                .copyWith(height: 1.4),
          ),
        ],
      ),
    );
  }
}

class _QuickChips extends StatelessWidget {
  const _QuickChips({required this.onPick});
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final s in _quickSuggestions)
          InkWell(
            onTap: () => onPick(s),
            borderRadius: BorderRadius.circular(20),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              decoration: BoxDecoration(
                color: ac.bgElev,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: ac.lineSoft, width: 0.5),
              ),
              child: Text(s, style: AymaType.sans(size: 12.5, color: ac.fgDim)),
            ),
          ),
      ],
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 12, height: 12,
            child: CircularProgressIndicator(
                strokeWidth: 1.6, color: ac.accent),
          ),
          const SizedBox(width: 10),
          Text(label, style: AymaType.sans(size: 12.5, color: ac.fgMute)),
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
          constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.78),
          child: isUser
              ? Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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
        ),
      ),
    );
  }
}
