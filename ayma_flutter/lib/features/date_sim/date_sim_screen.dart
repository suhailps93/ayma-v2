import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../services/api_client.dart';
import '../../services/date_sim_service.dart';
import '../../services/profile_service.dart';
import '../../theme.dart';
import '../../widgets/chat_bubble.dart';
import '../../widgets/out_of_credits.dart';
import '../../widgets/overflow_guards.dart';
import 'date_sim_models.dart';
import 'taste_match_card.dart';

/// AI Date Simulation (hackathon flagship) — watch your AI and theirs feel each
/// other out before you message them. The user sets how many messages the two
/// personas exchange and runs it; the (clearly-labelled "simulated, not sent")
/// transcript then appears live, message by message, as the backend writes it
/// to Firestore, followed by a compatibility read: a 0–100 score and a short
/// "how it went" summary, with a "Message them for real" CTA. A failed run
/// shows an inline error under the partial transcript.
/// Under the read, a [TasteMatchCard] (Qloo taste overlap + date ideas).
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
    this.service,
    this.profiles,
    this.simId,
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
  final DateSimService? service;
  final ProfileService? profiles;

  /// Reopen an existing simulation (already running or finished) and watch it,
  /// instead of starting at the setup form. No new run is started.
  final String? simId;

  @override
  State<DateSimScreen> createState() => _DateSimScreenState();
}

enum _Phase { setup, live }

class _DateSimScreenState extends State<DateSimScreen> {
  late final ApiClient _api = widget.api ?? ApiClient();
  late final DateSimService _service = widget.service ?? DateSimService();
  late final ProfileService _profiles = widget.profiles ?? ProfileService();
  final ScrollController _scroll = ScrollController();

  _Phase _phase = _Phase.setup;
  String? _error;
  int _count = 6;

  /// Whether the CURRENT user's AI Avatar is on. A sim runs both personas on
  /// the user's own credits and needs the user's avatar enabled; when off, the
  /// setup screen shows a one-tap "Turn on AI Avatar" gate instead of the
  /// controls. On until the profile stream says otherwise, so the gate never
  /// flashes for the common (enabled) case.
  bool _avatarEnabled = true;
  StreamSubscription<bool>? _avatarSub;

  /// True while the in-place "Turn on AI Avatar" write is in flight.
  bool _enablingAvatar = false;

  /// A short inline error if enabling the avatar failed; cleared on retry.
  String? _avatarError;

  /// The match's avatar readiness, for the low-context warning before a sim.
  DateSimReadiness? _readiness;

  DateSimDoc? _sim;
  List<DateSimMessage> _messages = const [];
  StreamSubscription<DateSimDoc?>? _simSub;
  StreamSubscription<List<DateSimMessage>>? _msgSub;

  /// The Qloo taste match, fetched once when the simulation completes.
  Future<TasteMatchLoad>? _taste;

  static const _min = 2;
  static const _max = 20;

  /// Approximate credits by message count, fetched from the backend (derived
  /// from the real token pricing). Empty until loaded or if unavailable.
  Map<int, int> _estimate = const {};

  @override
  void initState() {
    super.initState();
    _loadEstimate();
    _avatarSub = _profiles.watchAiAvatar().listen((on) {
      if (mounted) setState(() => _avatarEnabled = on);
    }, onError: (_) {
      // A read failure leaves the gate at its optimistic default (enabled),
      // so the user is never locked out of the screen by a transient error.
    });
    final existing = widget.simId;
    if (existing != null) {
      _phase = _Phase.live;
      _listen(existing);
    }
  }

  @override
  void dispose() {
    _simSub?.cancel();
    _msgSub?.cancel();
    _avatarSub?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadEstimate() async {
    try {
      final e = await _api.dateSimEstimate(otherUid: widget.uid);
      if (mounted) {
        setState(() {
          _estimate = e.credits;
          _readiness = e.readiness;
        });
      }
    } catch (_) {
      // The warning still shows, without a number.
    }
  }

  /// Enable the user's AI Avatar in-place, so the sim gate clears without a
  /// trip to Settings. The profile stream flips [_avatarEnabled] on success;
  /// a write failure shows a short inline error.
  Future<void> _enableAvatar() async {
    if (_enablingAvatar) return;
    setState(() {
      _enablingAvatar = true;
      _avatarError = null;
    });
    try {
      await _profiles.setAiAvatar(true);
    } catch (_) {
      if (mounted) {
        setState(() => _avatarError =
            "Couldn't turn on your AI Avatar. Please try again.");
      }
    } finally {
      if (mounted) setState(() => _enablingAvatar = false);
    }
  }

  static String _newSimId() {
    final r = Random.secure();
    return List.generate(
      16,
      (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  void _stopListening() {
    unawaited(_simSub?.cancel());
    unawaited(_msgSub?.cancel());
    _simSub = null;
    _msgSub = null;
  }

  /// Back to the setup form with [message] (or the out-of-credits sheet).
  Future<void> _abort(String? message, {bool outOfCredits = false}) async {
    _stopListening();
    if (!mounted) return;
    setState(() {
      _phase = _Phase.setup;
      _error = message;
      _sim = null;
      _messages = const [];
    });
    if (outOfCredits) await showOutOfCreditsSheet(context);
  }

  /// Starts listening to the sim's Firestore docs FIRST, then fires the POST
  /// that makes the backend generate into them: the transcript renders as it
  /// arrives and the UI never depends on the POST response.
  Future<void> _run() async {
    final simId = _newSimId();
    _stopListening();
    setState(() {
      _phase = _Phase.live;
      _error = null;
      _sim = null;
      _messages = const [];
      _taste = null;
    });
    _simSub = _service.watchSim(simId).listen(_onSim, onError: _onListenError);
    _msgSub = _service
        .watchMessages(simId)
        .listen(_onMessages, onError: _onListenError);
    try {
      await _api.dateSim(simId, widget.uid, _count);
    } on ApiException catch (e) {
      if (!mounted) return;
      switch (e.statusCode) {
        case 402:
          await _abort(null, outOfCredits: true);
        case 403:
          await _abort(e.message);
        case 404:
          await _abort('There is no profile to simulate a date with.');
        default:
          if (_sim == null) await _abort(_genericError);
      }
    } catch (_) {
      // Transport failure: if the backend already started, the doc stream still
      // reports the real outcome; otherwise nothing is running.
      if (mounted && _sim == null) await _abort(_genericError);
    }
  }

  void _listen(String simId) {
    _simSub = _service.watchSim(simId).listen(_onSim, onError: _onListenError);
    _msgSub = _service
        .watchMessages(simId)
        .listen(_onMessages, onError: _onListenError);
  }

  static const _genericError = "Couldn't run the simulation. Please try again.";

  void _onListenError(Object _) {
    if (mounted && _sim == null) _abort(_genericError);
  }

  void _onSim(DateSimDoc? sim) {
    if (!mounted || sim == null) return;
    final finished =
        sim.status == DateSimStatus.done && _sim?.status != DateSimStatus.done;
    setState(() {
      _sim = sim;
      if (finished) _taste = loadTasteMatch(_api, widget.uid);
    });
    _scrollToEnd();
  }

  void _onMessages(List<DateSimMessage> messages) {
    if (!mounted) return;
    setState(() => _messages = messages);
    _scrollToEnd();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
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
      _sim?.persona.name.isNotEmpty == true ? _sim!.persona.name : widget.name;

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
          _Phase.live => _live(ac),
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
          if (!_avatarEnabled)
            _AvatarGate(
              name: _name,
              busy: _enablingAvatar,
              error: _avatarError,
              onEnable: _enableAvatar,
            )
          else ...[
            _CreditWarning(count: _count, credits: _estimate[_count]),
            if (_readiness?.lowContext ?? false) ...[
              const SizedBox(height: 16),
              _LowContextWarning(readiness: _readiness!, fallbackName: _name),
            ],
            const SizedBox(height: 28),
            Text(
              'Messages to exchange',
              style: AymaType.sans(
                size: 14,
                weight: FontWeight.w600,
                color: ac.fgDim,
              ),
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
        ],
      ),
    );
  }

  // --- live: banner + transcript as it streams + read + CTA -------------- //
  Widget _live(AymaTokens ac) {
    final sim = _sim;
    final status = sim?.status ?? DateSimStatus.running;
    final running = status == DateSimStatus.running;
    final finished = !running;
    final youTurn = _messages.length.isEven;
    final who = youTurn
        ? 'Your AI'
        : (_name.isEmpty ? 'Their AI' : '$_name’s AI');
    return ChromeColumn(
      header: [
        _SimBanner(
          text: (sim?.banner.isNotEmpty ?? false)
              ? sim!.banner
              : 'Simulated — not sent to ${_name.isEmpty ? 'them' : _name}.',
        ),
      ],
      body: ListView(
        key: const Key('dateSimTranscript'),
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        children: [
          for (final m in _messages)
            ChatBubble(
              mine: m.fromYou,
              copyText: m.text,
              flagged: sim?.moderationFlagged ?? false,
              child: Text(
                m.text,
                style: AymaType.message(color: m.fromYou ? ac.onAccent : ac.fg),
              ),
            ),
          if (running)
            _TypingIndicator(
              label: _messages.isEmpty && sim == null
                  ? 'Starting the conversation…'
                  : '$who is typing…',
              alignEnd: youTurn,
            ),
          if (status == DateSimStatus.error) ...[
            const SizedBox(height: 12),
            _InlineError(
              message: (sim?.errorMessage.isNotEmpty ?? false)
                  ? sim!.errorMessage
                  : _genericError,
              partial: _messages.isNotEmpty,
            ),
          ],
          if (status == DateSimStatus.done) ...[
            if (sim!.usageCapped) ...[
              const SizedBox(height: 12),
              const _InlineError(
                message:
                    'You ran out of credits, so the conversation was '
                    'cut short.',
                partial: false,
              ),
            ],
            if (sim.hasVerdict) ...[
              const SizedBox(height: 20),
              _Verdict(
                score: sim.score,
                label: sim.scoreLabel,
                summary: sim.summary,
              ),
            ],
            if (_taste != null) ...[
              const SizedBox(height: 16),
              TasteMatchCard(load: _taste!),
            ],
          ],
        ],
      ),
      footer: [
        if (finished)
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
                _name.isEmpty
                    ? 'Message them for real'
                    : 'Message $_name for real',
              ),
            ),
          ),
      ],
    );
  }
}

/// The `name is typing` row, shown only between turns while the run is live.
class _TypingIndicator extends StatelessWidget {
  const _TypingIndicator({required this.label, required this.alignEnd});

  final String label;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Padding(
      key: const Key('dateSimTyping'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: alignEnd
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2, color: ac.fgDim),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(label, style: AymaType.sans(size: 13, color: ac.fgDim)),
          ),
        ],
      ),
    );
  }
}

/// Inline failure notice shown under the (possibly partial) transcript.
class _InlineError extends StatelessWidget {
  const _InlineError({required this.message, required this.partial});

  final String message;
  final bool partial;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Container(
      key: const Key('dateSimRunError'),
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ac.error.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ac.error.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 20, color: ac.error),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              partial
                  ? '$message The conversation so far is shown above.'
                  : message,
              style: AymaType.sans(size: 13.5, color: ac.fg, height: 1.4),
            ),
          ),
        ],
      ),
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

/// Shown on the setup screen when the user's own AI Avatar is off. A sim needs
/// the user's avatar, so instead of a dead-end "go to Settings" message this
/// enables it in-place with one tap ([onEnable] → `setAiAvatar(true)`); the
/// gate clears as soon as the profile stream reports it on.
class _AvatarGate extends StatelessWidget {
  const _AvatarGate({
    required this.name,
    required this.busy,
    required this.error,
    required this.onEnable,
  });

  final String name;
  final bool busy;
  final String? error;
  final VoidCallback onEnable;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Column(
      key: const Key('dateSimAvatarGate'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: ac.accentFaint,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            name.isEmpty
                ? 'Simulated dates run your AI alongside theirs, so you need '
                      'your AI Avatar turned on.'
                : 'Simulated dates run your AI alongside $name’s, so you need '
                      'your AI Avatar turned on.',
            style: AymaType.sans(size: 14, color: ac.fg, height: 1.4),
          ),
        ),
        const SizedBox(height: 20),
        FilledButton(
          key: const Key('dateSimEnableAvatarButton'),
          onPressed: busy ? null : onEnable,
          style: FilledButton.styleFrom(
            backgroundColor: ac.accent,
            foregroundColor: ac.onAccent,
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          child: busy
              ? SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: ac.onAccent,
                  ),
                )
              : const Text('Turn on AI Avatar'),
        ),
        if (error != null) ...[
          const SizedBox(height: 14),
          Text(
            error!,
            key: const Key('dateSimAvatarGateError'),
            textAlign: TextAlign.center,
            style: AymaType.sans(size: 13.5, color: ac.error),
          ),
        ],
      ],
    );
  }
}

/// A pre-sim warning when the match's AI persona has little to go on, so the
/// user knows a simulated chat won't reflect them well. Informs, never blocks.
class _LowContextWarning extends StatelessWidget {
  const _LowContextWarning({required this.readiness, required this.fallbackName});

  final DateSimReadiness readiness;
  final String fallbackName;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final name = readiness.name.isNotEmpty
        ? readiness.name
        : (fallbackName.isEmpty ? 'This person' : fallbackName);
    final text = readiness.message.isNotEmpty
        ? readiness.message
        : "$name doesn't have much context yet — a simulated chat with their "
              'AI won’t be an accurate reflection of them.';
    return Container(
      key: const Key('dateSimLowContextWarning'),
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ac.accentFaint,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ac.lineSoft, width: 0.5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 20, color: ac.fgDim),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: AymaType.sans(size: 13.5, color: ac.fg, height: 1.4),
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
          onPressed: value > min
              ? () => onChanged((value - _step).clamp(min, max))
              : null,
          icon: const Icon(Icons.remove),
        ),
        Container(
          width: 64,
          alignment: Alignment.center,
          child: Text(
            '$value',
            key: const Key('dateSimCountValue'),
            style: AymaType.sans(
              size: 22,
              weight: FontWeight.w700,
              color: ac.fg,
            ),
          ),
        ),
        IconButton.filledTonal(
          key: const Key('dateSimCountIncrement'),
          onPressed: value < max
              ? () => onChanged((value + _step).clamp(min, max))
              : null,
          icon: const Icon(Icons.add),
        ),
      ],
    );
  }
}

/// The compatibility read shown under the transcript: a prominent 0–100 score
/// with its label, and the "how it went" summary.
class _Verdict extends StatelessWidget {
  const _Verdict({
    required this.score,
    required this.label,
    required this.summary,
  });

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
                  size: 40,
                  weight: FontWeight.w800,
                  color: ac.accent,
                ),
              ),
              const SizedBox(width: 4),
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '/100',
                  style: AymaType.sans(size: 16, color: ac.fgDim),
                ),
              ),
              const Spacer(),
              if (label.isNotEmpty)
                Flexible(
                  child: Text(
                    label,
                    textAlign: TextAlign.end,
                    style: AymaType.sans(
                      size: 15,
                      weight: FontWeight.w600,
                      color: ac.fg,
                    ),
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
