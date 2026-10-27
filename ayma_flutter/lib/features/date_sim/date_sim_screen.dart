import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../services/api_client.dart';
import '../../theme.dart';
import '../../widgets/chat_bubble.dart';
import '../../widgets/out_of_credits.dart';
import '../../widgets/overflow_guards.dart';
import 'date_sim_models.dart';

/// AI Date Simulation (hackathon flagship) — watch your AI and theirs feel each
/// other out before you message them. The user sets how many messages the two
/// personas exchange, runs it, then sees the (clearly-labelled "simulated, not
/// sent") transcript plus a compatibility read: a 0–100 score and a short
/// "how it went" summary, with a "Message them for real" CTA.
///
/// Reuses the shared [ChatBubble] so the simulated chat reads like a real one,
/// and the app theme tokens (light + dark). Metered/credit-aware: an
/// out-of-credits response opens the standard out-of-credits sheet.
class DateSimScreen extends StatefulWidget {
  const DateSimScreen({
    super.key,
    required this.uid,
    this.name = '',
    this.threadId,
    this.api,
  });

  static const path = '/date-sim/:uid';

  /// The match whose persona the user simulates a date with.
  final String uid;

  /// Their name (for the header/CTA before the result arrives).
  final String name;

  /// The deterministic DM pair id, passed from the profile, so "Message them
  /// for real" can open the real thread. Null → the CTA just returns.
  final String? threadId;

  final ApiClient? api;

  @override
  State<DateSimScreen> createState() => _DateSimScreenState();
}

enum _Phase { setup, running, done }

class _DateSimScreenState extends State<DateSimScreen> {
  late final ApiClient _api = widget.api ?? ApiClient();

  _Phase _phase = _Phase.setup;
  String? _error;
  int _count = 6;
  DateSimResult? _result;

  static const _min = 2;
  static const _max = 20;

  /// Approximate credits by message count, fetched from the backend (derived
  /// from the real token pricing). Empty until loaded or if unavailable.
  Map<int, int> _estimate = const {};

  @override
  void initState() {
    super.initState();
    _loadEstimate();
  }

  Future<void> _loadEstimate() async {
    try {
      final e = await _api.dateSimEstimate();
      if (mounted) setState(() => _estimate = e);
    } catch (_) {
      // The warning still shows, without a number.
    }
  }

  Future<void> _run() async {
    setState(() {
      _phase = _Phase.running;
      _error = null;
    });
    try {
      final res = await _api.dateSim(widget.uid, _count);
      if (!mounted) return;
      if (res == null) {
        setState(() {
          _phase = _Phase.setup;
          _error = 'There is no profile to simulate a date with.';
        });
        return;
      }
      if (res.usageCapped && res.messages.isEmpty) {
        setState(() => _phase = _Phase.setup);
        await showOutOfCreditsSheet(context);
        return;
      }
      setState(() {
        _result = res;
        _phase = _Phase.done;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _phase = _Phase.setup;
          _error = e is ApiException && e.statusCode == 403
              ? e.message
              : "Couldn't run the simulation. Please try again.";
        });
      }
    }
  }

  void _messageForReal() {
    final tid = widget.threadId;
    if (tid != null && tid.isNotEmpty) {
      context.push('/dm/$tid');
    } else {
      context.pop();
    }
  }

  String get _name =>
      _result?.persona.name.isNotEmpty == true ? _result!.persona.name : widget.name;

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
          _name.isEmpty ? 'Simulate a date' : 'You & $_name',
          style: AymaType.sans(size: 17, weight: FontWeight.w600, color: ac.fg),
        ),
      ),
      body: SafeArea(
        top: false,
        child: switch (_phase) {
          _Phase.setup => _setup(ac),
          _Phase.running => _running(ac),
          _Phase.done => _done(ac),
        },
      ),
    );
  }

  // --- setup: choose the message count, then run -------------------------- //
  Widget _setup(AymaTokens ac) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(Icons.auto_awesome_outlined, size: 40, color: ac.accent),
          const SizedBox(height: 16),
          Text(
            _name.isEmpty
                ? 'Watch your AI and theirs feel each other out before you message.'
                : 'Watch your AI and $_name’s feel each other out before you '
                    'message them.',
            textAlign: TextAlign.center,
            style: AymaType.sans(size: 16, color: ac.fg, height: 1.4),
          ),
          const SizedBox(height: 8),
          Text(
            "It's a simulation — nothing is sent to them.",
            key: const Key('dateSimSetupNote'),
            textAlign: TextAlign.center,
            style: AymaType.sans(size: 13, color: ac.fgDim),
          ),
          const SizedBox(height: 20),
          _CreditWarning(count: _count, credits: _estimate[_count]),
          const SizedBox(height: 28),
          Text(
            'Messages to exchange',
            style: AymaType.sans(
                size: 14, weight: FontWeight.w600, color: ac.fgDim),
          ),
          const SizedBox(height: 12),
          _CountStepper(
            value: _count,
            min: _min,
            max: _max,
            onChanged: (v) => setState(() => _count = v),
          ),
          if (_error != null) ...[
            const SizedBox(height: 20),
            Text(
              _error!,
              key: const Key('dateSimError'),
              textAlign: TextAlign.center,
              style: AymaType.sans(size: 14, color: ac.error),
            ),
          ],
          const SizedBox(height: 28),
          FilledButton(
            key: const Key('dateSimRunButton'),
            onPressed: _run,
            style: FilledButton.styleFrom(
              backgroundColor: ac.accent,
              foregroundColor: ac.onAccent,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            child: const Text('Simulate a conversation'),
          ),
        ],
      ),
    );
  }

  Widget _running(AymaTokens ac) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 18),
          Text(
            _name.isEmpty
                ? 'Your AIs are talking…'
                : 'You and $_name’s AI are talking…',
            style: AymaType.sans(size: 15, color: ac.fgDim),
          ),
        ],
      ),
    );
  }

  // --- done: banner + transcript + compatibility read + CTA --------------- //
  Widget _done(AymaTokens ac) {
    final res = _result!;
    return ChromeColumn(
      header: [
        _SimBanner(
          text: res.banner.isNotEmpty
              ? res.banner
              : 'Simulated — not sent to '
                  '${_name.isEmpty ? 'them' : _name}.',
        ),
      ],
      body: ListView(
        key: const Key('dateSimTranscript'),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        children: [
          for (final m in res.messages)
            ChatBubble(
              mine: m.fromYou,
              copyText: m.text,
              flagged: res.moderationFlagged,
              child: Text(
                m.text,
                style: AymaType.message(color: m.fromYou ? ac.onAccent : ac.fg),
              ),
            ),
          const SizedBox(height: 20),
          _Verdict(score: res.score, label: res.scoreLabel, summary: res.summary),
        ],
      ),
      footer: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton.icon(
            key: const Key('dateSimMessageForRealButton'),
            onPressed: _messageForReal,
            style: FilledButton.styleFrom(
              backgroundColor: ac.accent,
              foregroundColor: ac.onAccent,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            icon: const Icon(Icons.send_rounded, size: 18),
            label: Text(
              _name.isEmpty ? 'Message them for real' : 'Message $_name for real',
            ),
          ),
        ),
      ],
    );
  }
}

/// The message-count control: − value + , clamped to [min]..[max].
/// Prominent pre-run cost warning: both personas run on the user's credits.
class _CreditWarning extends StatelessWidget {
  const _CreditWarning({required this.count, this.credits});

  final int count;

  /// Approximate credits for [count] messages; null while unknown.
  final int? credits;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Container(
      key: const Key('dateSimCreditWarning'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ac.error.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ac.error.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, size: 22, color: ac.error),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              credits == null
                  ? 'This uses a lot of credits. A simulated date runs $count '
                      'AI messages plus a final compatibility read, and both '
                      'agents are billed to you.'
                  : 'This uses a lot of credits. A simulated date of $count AI '
                      'messages will use roughly $credits credits (approx.), '
                      'including a final compatibility read. Both agents are '
                      'billed to you.',
              style: AymaType.sans(size: 13, color: ac.fg, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

class _CountStepper extends StatelessWidget {
  const _CountStepper({
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  static const _step = 2;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton.filledTonal(
          key: const Key('dateSimCountDecrement'),
          onPressed:
              value > min ? () => onChanged((value - _step).clamp(min, max)) : null,
          icon: const Icon(Icons.remove),
        ),
        Container(
          width: 64,
          alignment: Alignment.center,
          child: Text(
            '$value',
            key: const Key('dateSimCountValue'),
            style: AymaType.sans(size: 22, weight: FontWeight.w700, color: ac.fg),
          ),
        ),
        IconButton.filledTonal(
          key: const Key('dateSimCountIncrement'),
          onPressed:
              value < max ? () => onChanged((value + _step).clamp(min, max)) : null,
          icon: const Icon(Icons.add),
        ),
      ],
    );
  }
}

/// The compatibility read shown under the transcript: a prominent 0–100 score
/// with its label, and the "how it went" summary.
class _Verdict extends StatelessWidget {
  const _Verdict({required this.score, required this.label, required this.summary});

  final int score;
  final String label;
  final String summary;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Container(
      key: const Key('dateSimScore'),
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: ac.accentSoft,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: ac.lineSoft, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '$score',
                style: AymaType.sans(
                    size: 40, weight: FontWeight.w800, color: ac.accent),
              ),
              const SizedBox(width: 4),
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text('/100',
                    style: AymaType.sans(size: 16, color: ac.fgDim)),
              ),
              const Spacer(),
              if (label.isNotEmpty)
                Flexible(
                  child: Text(
                    label,
                    textAlign: TextAlign.end,
                    style: AymaType.sans(
                        size: 15, weight: FontWeight.w600, color: ac.fg),
                  ),
                ),
            ],
          ),
          if (summary.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              summary,
              key: const Key('dateSimSummary'),
              style: AymaType.sans(size: 14.5, color: ac.fg, height: 1.45),
            ),
          ],
        ],
      ),
    );
  }
}

/// The persistent "this is a simulation, not sent to them" header.
class _SimBanner extends StatelessWidget {
  const _SimBanner({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Container(
      key: const Key('dateSimBanner'),
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
