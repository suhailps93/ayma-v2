import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../services/api_client.dart';
import '../../services/date_sim_service.dart';
import '../../services/profile_service.dart';
import '../../theme.dart';
import '../../widgets/ayma_wing_loader.dart';
import '../../widgets/chat_bubble.dart';
import '../../widgets/out_of_credits.dart';
import '../../widgets/overflow_guards.dart';
import 'date_sim_models.dart';
import '../../widgets/taste_match_card.dart';
import '../../widgets/taste_models.dart';

/// AI Date Simulation (hackathon flagship) — watch your AI and theirs feel each
/// other out before you message them. The user sets how many messages the two
/// personas exchange and runs it; the (clearly-labelled "simulated, not sent")
/// transcript then appears live, message by message, as the backend writes it
/// to Firestore, followed by a compatibility read: a 0–100 score and a short
/// "how it went" summary, with a Done action that returns to the origin
/// profile. A failed run shows an inline error under the partial transcript.
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
    this.api,
    this.service,
    this.profiles,
    this.simId,
    this.openedFromNotification = false,
  });

  static const path = '/date-sim/:uid';

  /// The match whose persona the user simulates a date with.
  final String uid;

  /// Their name (for the header before the result arrives).
  final String name;

  final ApiClient? api;
  final DateSimService? service;
  final ProfileService? profiles;

  /// Reopen an existing simulation (already running or finished) and watch it,
  /// instead of starting at the setup form. No new run is started.
  final String? simId;

  /// True when this screen was opened from a notification — a warm bell-tap
  /// push off the Notifications list or a cold FCM/deep-link open pushed over
  /// the boot shell. Done then navigates to the origin profile instead of
  /// popping (a pop would land on the list/shell beneath, Scout 2289).
  final bool openedFromNotification;

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

  /// True once the watched sim doc is CONFIRMED absent: the doc stream
  /// emitted (so this is not merely slow) and the doc does not exist — e.g. a
  /// Start-over wipe deleted it while its completion notification still
  /// dangles. Set only when reopening an existing sim (or a live doc
  /// vanishes); a fresh run starts doc-less until the backend's first write.
  bool _simMissing = false;
  List<DateSimMessage> _messages = const [];
  StreamSubscription<DateSimDoc?>? _simSub;
  StreamSubscription<List<DateSimMessage>>? _msgSub;

  /// The id of the simulation currently being watched, so "Keep the
  /// conversation going" can continue the SAME sim. Set when a run starts or
  /// when reopening an existing sim.
  String? _simId;

  /// True while a "continue" POST is in flight (shows a spinner on the button
  /// until the doc flips back to `running` and the live view takes over).
  bool _continuing = false;

  /// True while a "stop" request is in flight (the Stop button shows
  /// "Stopping…" until the request resolves and we either leave the sim view
  /// or report why we stayed).
  bool _stopping = false;

  /// True while a "reset" (discard this pair's sim) request is in flight.
  bool _resetting = false;

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
      _simId = existing;
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
      _simMissing = false;
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
      _simId = simId;
      _error = null;
      _sim = null;
      _simMissing = false;
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
    if (!mounted) return;
    if (sim == null) {
      // The stream emitted, so the doc is confirmed absent — not merely slow.
      // Fresh runs start doc-less until the backend's first write (keep the
      // "Starting…" row); a reopen that finds nothing is deleted data.
      if (widget.simId != null || _sim != null) {
        setState(() {
          _sim = null;
          _simMissing = true;
        });
      }
      return;
    }
    final finished =
        sim.status == DateSimStatus.done && _sim?.status != DateSimStatus.done;
    setState(() {
      _sim = sim;
      _simMissing = false;
      // A user-stopped run produces no result to present: no score is written
      // (see the backend finalize) and no taste card is loaded under it.
      if (finished && !sim.stopped) _taste = loadTasteMatch(_api, widget.uid);
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

  /// DONE on the finished result: exit the sim back to the origin profile —
  /// the person this sim was with. When the sim was started from their
  /// profile it sits beneath us, so pop back to it; when it was opened from
  /// a notification (warm bell tap or cold FCM/deep-link open — always
  /// pushed over the Notifications list or the boot shell, so `canPop()` is
  /// true but the screen beneath is NOT the profile), navigate to that
  /// person's profile instead. Never back into the sim.
  void _done() {
    if (widget.openedFromNotification) {
      context.go('/profile/user/${widget.uid}');
    } else if (context.canPop()) {
      context.pop();
    } else {
      context.go('/profile/user/${widget.uid}');
    }
  }

  /// Ask the user HOW MANY more messages to run, then continue by that amount.
  /// The chooser (a small bottom sheet of +3/+5/+10, with the rough credit cost)
  /// returns the chosen count; cancelling it does nothing.
  Future<void> _chooseAndContinue() async {
    if (_continuing) return;
    final more = await showSimContinueChooser(context, estimate: _estimate);
    if (more != null) await _continue(more);
  }

  /// Continue the SAME simulation with [more] more turns, picking up where it
  /// left off (not a restart). The backend appends to the same Firestore doc
  /// and re-scores over the full transcript; the live view updates from the
  /// streams — the doc flips back to `running` (typing indicator returns), then
  /// `done` with the refreshed score/coaching. Out of credits opens the sheet.
  Future<void> _continue(int more) async {
    final simId = _simId;
    if (simId == null || _continuing) return;
    setState(() {
      _continuing = true;
      _error = null;
    });
    try {
      await _api.dateSimContinue(simId, more);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.statusCode == 402) {
        await showOutOfCreditsSheet(context);
      } else {
        setState(() => _error = _continueError);
      }
    } catch (_) {
      // Transport failure: the sim doc stream still reports the real outcome.
    } finally {
      if (mounted) setState(() => _continuing = false);
    }
  }

  static const _continueError =
      "Couldn't continue the conversation. Please try again.";

  /// STOP the in-flight run. The tap is acknowledged at once (the button
  /// shows "Stopping…"); the backend halts generation between turns, keeps
  /// what's done, and for a stopped run writes NO score and sends NO
  /// completion notification. As soon as the stop lands we LEAVE the sim
  /// view — sitting on it while the backend winds down (the in-flight turn
  /// plus the finalize write) is what made Stop feel stuck. If the server
  /// says the run had ALREADY finished, we stay and say so honestly: its
  /// score was already final, and the finished view presents it.
  Future<void> _stop() async {
    final simId = _simId;
    if (simId == null || _stopping) return;
    setState(() {
      _stopping = true;
      _error = null;
    });
    try {
      final outcome = await _api.dateSimStop(simId);
      if (!mounted) return;
      if (outcome == 'already_finished') {
        setState(() => _error = 'That simulation had already finished — '
            'here is its result.');
        return;
      }
      _leaveSimView();
    } on ApiException {
      if (mounted) setState(() => _error = _stopError);
    } catch (_) {
      // Transport failure: the stop did not land and the run keeps going.
      // Say so and stay — the stream reports the real outcome.
      if (mounted) setState(() => _error = _stopError);
    } finally {
      if (mounted) setState(() => _stopping = false);
    }
  }

  /// Leave the sim view after a stop: back to wherever the user came from,
  /// or to the main shell when the sim was opened cold (deep link) with
  /// nothing beneath it to pop to.
  void _leaveSimView() {
    _stopListening();
    if (!mounted) return;
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/');
    }
  }

  static const _stopError =
      "Couldn't stop the conversation. Please try again.";

  /// RESET: discard this pair's simulation(s) and return to the setup form so a
  /// brand-new sim can be run from scratch. Confirmed first (it can't be undone).
  Future<void> _reset() async {
    if (_resetting) return;
    final ok = await showSimResetConfirm(context, name: _name);
    if (ok != true || !mounted) return;
    setState(() {
      _resetting = true;
      _error = null;
    });
    try {
      await _api.dateSimReset(widget.uid);
      if (!mounted) return;
      _stopListening();
      setState(() {
        _phase = _Phase.setup;
        _sim = null;
        _simMissing = false;
        _messages = const [];
        _taste = null;
        _simId = null;
      });
    } on ApiException {
      if (mounted) setState(() => _error = _resetError);
    } catch (_) {
      if (mounted) setState(() => _error = _resetError);
    } finally {
      if (mounted) setState(() => _resetting = false);
    }
  }

  static const _resetError =
      "Couldn't start over. Please try again.";

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
    if (_simMissing) return _missing(ac);
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
            if (sim.stopped && !sim.usageCapped) ...[
              const SizedBox(height: 12),
              const _InlineError(
                key: Key('dateSimStoppedNote'),
                message:
                    'You stopped the conversation early, so it was not '
                    'scored. The transcript above is what was said.',
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
        // While the run is live: a STOP control to halt it mid-conversation.
        if (running)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_error != null) ...[
                  Text(
                    _error!,
                    key: const Key('dateSimStopError'),
                    textAlign: TextAlign.center,
                    style: AymaType.sans(size: 13, color: ac.error),
                  ),
                  const SizedBox(height: 10),
                ],
                OutlinedButton.icon(
                  key: const Key('dateSimStopButton'),
                  onPressed: _stopping ? null : _stop,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: ac.error,
                    side: BorderSide(color: ac.error),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  // dateSimStop in flight — button slot, wings only.
                  icon: _stopping
                      ? AymaWingLoader(
                          size: 16,
                          showLabel: false,
                          color: ac.error,
                        )
                      : const Icon(Icons.stop_circle_outlined, size: 18),
                  label: Text(_stopping ? 'Stopping…' : 'Stop'),
                ),
              ],
            ),
          ),
        if (finished)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_error != null) ...[
                  Text(
                    _error!,
                    key: const Key('dateSimContinueError'),
                    textAlign: TextAlign.center,
                    style: AymaType.sans(size: 13, color: ac.error),
                  ),
                  const SizedBox(height: 10),
                ],
                // "Keep the conversation going" — asks HOW MANY more messages,
                // then continues the same sim by that amount (only when it
                // finished cleanly, i.e. there's a transcript to continue).
                if (status == DateSimStatus.done) ...[
                  OutlinedButton.icon(
                    key: const Key('dateSimContinueButton'),
                    onPressed: _continuing ? null : _chooseAndContinue,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: ac.accent,
                      side: BorderSide(color: ac.accent),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    // dateSimContinue in flight — button slot, wings only.
                    icon: _continuing
                        ? const AymaWingLoader(size: 16, showLabel: false)
                        : const Icon(Icons.forum_outlined, size: 18),
                    label: Text(
                      _continuing
                          ? 'Continuing…'
                          : 'Keep the conversation going',
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                FilledButton.icon(
                  key: const Key('dateSimDoneButton'),
                  onPressed: _done,
                  style: FilledButton.styleFrom(
                    backgroundColor: ac.accent,
                    foregroundColor: ac.onAccent,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  icon: const Icon(Icons.check_rounded, size: 18),
                  label: const Text('Done'),
                ),
                const SizedBox(height: 10),
                // RESET — discard this pair's sim and start a fresh one.
                TextButton.icon(
                  key: const Key('dateSimResetButton'),
                  onPressed: _resetting ? null : _reset,
                  style: TextButton.styleFrom(foregroundColor: ac.fgDim),
                  // dateSimReset in flight — button slot, wings only.
                  icon: _resetting
                      ? AymaWingLoader(
                          size: 16,
                          showLabel: false,
                          color: ac.fgDim,
                        )
                      : const Icon(Icons.refresh_rounded, size: 18),
                  label: Text(_resetting ? 'Starting over…' : 'Start over'),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// Honest empty-state for a deleted sim: the watched doc is confirmed
  /// absent (a Start-over wipe deletes sims but leaves their completion
  /// notifications dangling), so say so instead of spinning forever. Shown
  /// only after the doc stream confirms the absence — never while loading.
  /// Done behaves exactly like the result screen's: back to the origin
  /// profile, never back into the sim.
  Widget _missing(AymaTokens ac) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 80, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(Icons.history_rounded, size: 40, color: ac.fgDim),
          const SizedBox(height: 16),
          Text(
            'This sim is no longer available',
            key: const Key('dateSimMissingMessage'),
            textAlign: TextAlign.center,
            style: AymaType.sans(size: 16, color: ac.fg, height: 1.4),
          ),
          const SizedBox(height: 28),
          FilledButton.icon(
            key: const Key('dateSimDoneButton'),
            onPressed: _done,
            style: FilledButton.styleFrom(
              backgroundColor: ac.accent,
              foregroundColor: ac.onAccent,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            icon: const Icon(Icons.check_rounded, size: 18),
            label: const Text('Done'),
          ),
        ],
      ),
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
          AymaWingLoader(size: 14, showLabel: false, color: ac.fgDim),
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
  const _InlineError({
    super.key,
    required this.message,
    required this.partial,
  });

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
          // Avatar-enable write in flight — button slot, wings only.
          child: busy
              ? AymaWingLoader(
                  size: 18,
                  showLabel: false,
                  color: ac.onAccent,
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

/// Asks HOW MANY more messages to run when continuing a simulation — a small
/// bottom sheet of +3 / +5 / +10 (with each option's rough credit cost from
/// [estimate]). Returns the chosen count, or null if dismissed. Public so the
/// layout matrix can pump it.
Future<int?> showSimContinueChooser(
  BuildContext context, {
  Map<int, int> estimate = const {},
}) {
  const options = [3, 5, 10];
  return showModalBottomSheet<int>(
    context: context,
    backgroundColor: context.ac.bg,
    showDragHandle: true,
    builder: (ctx) {
      final ac = ctx.ac;
      return SafeArea(
        child: SingleChildScrollView(
          key: const Key('dateSimContinueChooser'),
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Keep the conversation going',
                style: AymaType.sans(
                  size: 17,
                  weight: FontWeight.w700,
                  color: ac.fg,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'How many more messages should they exchange?',
                style: AymaType.sans(size: 13.5, color: ac.fgDim, height: 1.3),
              ),
              const SizedBox(height: 16),
              for (final n in options) ...[
                OutlinedButton(
                  key: Key('dateSimContinueOption_$n'),
                  onPressed: () => Navigator.of(ctx).pop(n),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: ac.accent,
                    side: BorderSide(color: ac.accent),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  // Label over cost (not side-by-side) so both wrap safely at
                  // large text scale on a narrow sheet.
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('+$n messages', textAlign: TextAlign.center),
                      if (estimate[n] != null)
                        Text(
                          '≈ ${estimate[n]} credits',
                          textAlign: TextAlign.center,
                          style: AymaType.sans(size: 12.5, color: ac.fgDim),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
              ],
            ],
          ),
        ),
      );
    },
  );
}

/// Confirms a RESET (discard this pair's simulation) before it happens — it
/// can't be undone. Returns true when the user confirms. Public so the layout
/// matrix can pump it.
Future<bool?> showSimResetConfirm(BuildContext context, {String name = ''}) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) {
      final ac = ctx.ac;
      return AlertDialog(
        key: const Key('dateSimResetDialog'),
        scrollable: true,
        backgroundColor: ac.bgCard,
        title: Text(
          'Start over?',
          style: AymaType.sans(size: 17, weight: FontWeight.w700, color: ac.fg),
        ),
        content: Text(
          name.isEmpty
              ? 'This discards the simulated conversation and its result, and '
                    "lets you run a fresh one. This can't be undone."
              : 'This discards your simulated conversation with $name and its '
                    "result, and lets you run a fresh one. This can't be undone.",
          style: AymaType.sans(size: 14, color: ac.fg, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            style: TextButton.styleFrom(foregroundColor: ac.fgDim),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('dateSimResetConfirmButton'),
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: ac.error,
              foregroundColor: ac.onAccent,
            ),
            child: const Text('Start over'),
          ),
        ],
      );
    },
  );
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
