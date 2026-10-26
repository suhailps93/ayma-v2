import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../services/api_client.dart';
import '../../theme.dart';
import '../../widgets/out_of_credits.dart';
import 'practice_models.dart';
import 'practice_voice_screen.dart';

/// Practice Date (hackathon deliverable B) — a clearly-labelled SIMULATOR where
/// Ayma plays a persona built from the match's viewer-visible profile, so the
/// user can rehearse talking to them. A persistent banner keeps it honest (this
/// is a simulation, not the real person), a live coach nudge surfaces
/// non-intrusively after each message, and ending the session opens the
/// debrief.
///
/// Reuses the app's theme tokens (`context.ac`, both light + dark) and the chat
/// message/bubble styling. Voice practice reuses the existing LiveKit pipeline
/// (seeded with the same persona prompt) — see docs/PRACTICE_DATE.md.
class PracticeScreen extends StatefulWidget {
  const PracticeScreen({super.key, required this.uid, this.name = '', this.api});

  static const path = '/practice/:uid';

  /// The match being practised with.
  final String uid;

  /// Their name (passed from the profile for an instant header; the authoritative
  /// persona still comes from `/practice/start`).
  final String name;

  final ApiClient? api;

  @override
  State<PracticeScreen> createState() => _PracticeScreenState();
}

class _PracticeMessage {
  _PracticeMessage(this.fromUser, this.text);
  final bool fromUser;
  final String text;
}

class _PracticeScreenState extends State<PracticeScreen> {
  late final ApiClient _api = widget.api ?? ApiClient();
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();

  bool _loading = true;
  String? _error;
  PracticeStart? _start;
  final List<_PracticeMessage> _messages = [];
  String _coachHint = '';
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _begin();
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _begin() async {
    try {
      final start = await _api.practiceStart(widget.uid);
      if (!mounted) return;
      if (start == null) {
        setState(() {
          _loading = false;
          _error = 'There is no profile to practice with.';
        });
        return;
      }
      setState(() {
        _start = start;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = "Couldn't start practice. Please try again.";
        });
      }
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    final start = _start;
    if (text.isEmpty || _sending || start == null) return;
    setState(() {
      _messages.add(_PracticeMessage(true, text));
      _coachHint = '';
      _sending = true;
      _input.clear();
    });
    _scrollToEnd();
    try {
      final turn = await _api.practiceChat(start.sessionId, text);
      if (!mounted) return;
      if (turn.usageCapped) {
        setState(() => _sending = false);
        await showOutOfCreditsSheet(context);
        return;
      }
      setState(() {
        if (turn.reply.isNotEmpty) {
          _messages.add(_PracticeMessage(false, turn.reply));
        }
        _coachHint = turn.coachHint;
        _sending = false;
      });
      _scrollToEnd();
    } catch (_) {
      if (mounted) {
        setState(() => _sending = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't get a reply. Try again.")),
        );
      }
    }
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _end() {
    final start = _start;
    if (start == null) {
      context.pop();
      return;
    }
    context.push(
      '/practice/${widget.uid}/debrief',
      extra: {'session_id': start.sessionId, 'name': start.persona.name},
    );
  }

  /// Rehearse by VOICE instead of text: open the voice simulator (the existing
  /// LiveKit pipeline seeded with the same persona prompt). It pops the practice
  /// session id when the call ends, and we open the debrief for it.
  Future<void> _startVoice() async {
    final sid = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => PracticeVoiceScreen(
          uid: widget.uid,
          name: _personaName,
          api: widget.api,
        ),
      ),
    );
    if (!mounted || sid == null || sid.isEmpty) return;
    context.push(
      '/practice/${widget.uid}/debrief',
      extra: {'session_id': sid, 'name': _personaName},
    );
  }

  String get _personaName =>
      _start?.persona.name.isNotEmpty == true ? _start!.persona.name : widget.name;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      backgroundColor: ac.bg,
      appBar: AppBar(
        backgroundColor: ac.bg,
        foregroundColor: ac.fg,
        elevation: 0,
        title: Text(
          _personaName.isEmpty ? 'Practice' : 'Practice with $_personaName',
          style: AymaType.sans(size: 17, weight: FontWeight.w600, color: ac.fg),
        ),
        actions: [
          if (_start != null && _error == null)
            IconButton(
              key: const Key('practiceVoiceButton'),
              tooltip: 'Practice by voice',
              onPressed: _startVoice,
              icon: Icon(Icons.graphic_eq_rounded, color: ac.accent),
            ),
          if (_start != null && _messages.isNotEmpty)
            TextButton(
              key: const Key('practiceEndButton'),
              onPressed: _end,
              child: Text('End',
                  style: AymaType.sans(
                      size: 15, weight: FontWeight.w600, color: ac.accent)),
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Flexible(
              child: SingleChildScrollView(
                child: _SimulationBanner(
                  text: _start?.banner ??
                      (_personaName.isEmpty
                          ? "Practice mode — you're talking to a simulation, not a real person."
                          : "Practice mode — you're talking to a simulated version of "
                              "$_personaName, not the real person."),
                ),
              ),
            ),
            Expanded(flex: 4, child: _body(ac)),
            if (_coachHint.isNotEmpty) _CoachHint(text: _coachHint),
            if (_start != null && _error == null) _composer(ac),
          ],
        ),
      ),
    );
  }

  Widget _body(AymaTokens ac) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _error!,
            key: const Key('practiceError'),
            textAlign: TextAlign.center,
            style: AymaType.sans(size: 15, color: ac.fgDim),
          ),
        ),
      );
    }
    if (_messages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            _personaName.isEmpty
                ? 'Say hi to break the ice.'
                : 'Say hi to $_personaName to break the ice. Ayma will coach you as you go.',
            textAlign: TextAlign.center,
            style: AymaType.sans(size: 16, color: ac.fgDim, height: 1.4),
          ),
        ),
      );
    }
    return ListView.builder(
      key: const Key('practiceMessages'),
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      itemCount: _messages.length,
      itemBuilder: (context, i) => _Bubble(message: _messages[i]),
    );
  }

  Widget _composer(AymaTokens ac) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: BoxDecoration(
        color: ac.bg,
        border: Border(top: BorderSide(color: ac.lineSoft)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              key: const Key('practiceInput'),
              controller: _input,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _send(),
              style: AymaType.message(color: ac.fg),
              decoration: InputDecoration(
                hintText: 'Type a message…',
                hintStyle: AymaType.message(color: ac.fgMute),
                filled: true,
                fillColor: ac.bgCard,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            key: const Key('practiceSendButton'),
            onPressed: _sending ? null : _send,
            icon: _sending
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(Icons.send_rounded, color: ac.accent),
            tooltip: 'Send',
          ),
        ],
      ),
    );
  }
}

/// The persistent, always-visible "this is a simulation" header.
class _SimulationBanner extends StatelessWidget {
  const _SimulationBanner({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Container(
      key: const Key('practiceBanner'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: ac.accentFaint,
      child: Row(
        children: [
          Icon(Icons.theater_comedy_outlined, size: 18, color: ac.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: AymaType.sans(size: 12.5, color: ac.fg, height: 1.3),
            ),
          ),
        ],
      ),
    );
  }
}

/// A non-intrusive live coach nudge, shown just above the composer.
class _CoachHint extends StatelessWidget {
  const _CoachHint({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Container(
      key: const Key('practiceCoachHint'),
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: ac.accentSoft,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lightbulb_outline, size: 16, color: ac.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: AymaType.sans(size: 13, color: ac.fg, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message});
  final _PracticeMessage message;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final fromUser = message.fromUser;
    return Align(
      alignment: fromUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.78,
        ),
        decoration: BoxDecoration(
          color: fromUser ? ac.accent : ac.bgCard,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Text(
          message.text,
          style: AymaType.message(color: fromUser ? ac.onAccent : ac.fg),
        ),
      ),
    );
  }
}
