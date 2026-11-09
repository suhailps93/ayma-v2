import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import '../env.dart';

/// App-wide connection quality, driven by [ConnectionHeartbeat].
///
/// This is the *transport* signal (can the phone reach the Ayma API?), not
/// the per-screen *data* signal (`FreshnessState` — whether a screen's own
/// data is live, syncing, stale or refused). The two are deliberately
/// separate: the shell banner reads this; the per-screen strips keep reading
/// theirs.
enum ConnectionQuality {
  /// Probes are succeeding within the latency budget.
  ok,

  /// Probes are slow or intermittently failing.
  weak,

  /// Probes are failing outright (or the OS reports no connection).
  offline,
}

/// The classified result of one heartbeat probe.
enum ProbeOutcome {
  /// The probe succeeded within the latency budget.
  good,

  /// The probe succeeded but exceeded the latency budget.
  slow,

  /// The probe failed (timeout, error, non-200) or was skipped because the
  /// OS reports no connection.
  failure,
}

/// Hysteresis classifier: probe outcomes in, [ConnectionQuality] out.
///
/// Pure state machine (no timers, no I/O) so the transition rules are
/// unit-testable on their own:
/// - weak: 2 consecutive slow probes, or 2 consecutive failures.
/// - offline: 3 consecutive failures.
/// - recovery: one good probe clears weak (a fast, successful probe is
///   proof the path works right now); offline steps up through weak on
///   the first good probe and needs a second consecutive good for ok.
///
/// Why failures need a streak while one good probe clears weak at once
/// (founder report, Nov 8 2026 — the weak banner up constantly on a
/// healthy link): a single failed or timed-out probe is as often the
/// SERVER waking up as the phone's connection. Staging runs
/// min-instances=0 (never warm, by founder rule), and server logs from
/// that day show /health requests held 10.6s and 21.3s by cold starts
/// that still returned 200 — while the same session's real data
/// requests ran a 40ms median server latency, all 200s. One missed
/// heartbeat therefore carries no verdict; the old lone-failure ->
/// weak rule turned every server cold start into minutes of "weak
/// connection" banner (on a metered link the recovery probes sit 60s
/// apart). A dead connection still surfaces: the OS connectivity
/// stream records its own failures into this same ladder, and
/// repeated failures walk weak -> offline.
class ConnectionClassifier {
  /// Consecutive same-outcome probes in the classifier ladder (see the
  /// [ConnectionClassifier] doc for how each outcome uses it).
  static const strikesToFlip = 2;

  ConnectionQuality _state = ConnectionQuality.ok;
  int _good = 0;
  int _slow = 0;
  int _fail = 0;

  ConnectionQuality get state => _state;

  void record(ProbeOutcome outcome) {
    switch (outcome) {
      case ProbeOutcome.good:
        _good++;
        _slow = 0;
        _fail = 0;
        if (_state == ConnectionQuality.weak) {
          // One good probe is proof of life: clear weak at once instead
          // of making the user wait out a second probe interval.
          _state = ConnectionQuality.ok;
        } else if (_state == ConnectionQuality.offline) {
          // Offline is a stronger claim, so it still takes two
          // consecutive good probes — the first is only a step up.
          _state = _good >= strikesToFlip
              ? ConnectionQuality.ok
              : ConnectionQuality.weak;
        }
      case ProbeOutcome.slow:
        _slow++;
        _good = 0;
        _fail = 0;
        // A slow probe still reached the server, so from offline it is a
        // step up; from ok it takes two consecutive slows to call it weak.
        if (_state == ConnectionQuality.offline ||
            _slow >= strikesToFlip) {
          _state = ConnectionQuality.weak;
        }
      case ProbeOutcome.failure:
        _fail++;
        _good = 0;
        _slow = 0;
        // A lone failure is not a verdict (see the class doc: server
        // cold starts eat single probes whole). Two in a row is a weak
        // connection; three is offline. Failures never step the state
        // UP, so an offline ladder is not undone by its own rungs.
        if (_fail > strikesToFlip) {
          _state = ConnectionQuality.offline;
        } else if (_fail == strikesToFlip &&
            _state == ConnectionQuality.ok) {
          _state = ConnectionQuality.weak;
        }
    }
  }

  void reset() {
    _state = ConnectionQuality.ok;
    _good = 0;
    _slow = 0;
    _fail = 0;
  }
}

/// A single heartbeat probe: one tiny request, classified by outcome.
typedef ProbeFn = Future<ProbeOutcome> Function();

/// Reads the OS connectivity state (overridable in tests).
typedef CheckConnectivityFn = Future<List<ConnectivityResult>> Function();

/// App-wide connection heartbeat (founder directive Nov 5 2026: the phone
/// client constantly checks the connection; every page shows the banner
/// when it is weak or gone).
///
/// Probes `GET /health` — the cheapest API endpoint: unauthenticated, no DB
/// work, no request payload, ~100-byte response — on a 15s cadence while
/// foregrounded, plus on app resume and on route change. Paused while
/// backgrounded. The resulting [ConnectionQuality] is exposed as a
/// [ValueListenable] the shell banner watches.
///
/// Footprint: one tiny request per interval. When the OS reports a metered
/// connection the interval stretches (see [isMeteredConnection]); when it
/// reports none, the probe is skipped outright (a failure is recorded
/// without touching the radio).
class ConnectionHeartbeat {
  ConnectionHeartbeat({
    ProbeFn? probe,
    CheckConnectivityFn? checkConnectivity,
    Stream<List<ConnectivityResult>>? connectivityChanges,
    this._httpClient,
    this._probeIntervalOverride,
  })  : _probeOverride = probe,
        _checkConnectivityOverride = checkConnectivity,
        _connectivityChangesOverride = connectivityChanges;

  static ConnectionHeartbeat? _instance;

  /// The app-wide singleton, wired to the real network.
  static ConnectionHeartbeat get instance =>
      _instance ??= ConnectionHeartbeat();

  /// Base probe interval while foregrounded on an unmetered connection.
  static const probeInterval = Duration(seconds: 15);

  /// Stretched interval on a metered connection (or no connection — regain
  /// is event-driven via the connectivity stream, so the poll can relax).
  static const meteredProbeInterval = Duration(seconds: 60);

  /// A probe succeeding slower than this counts as [ProbeOutcome.slow].
  static const weakLatencyBudget = Duration(seconds: 4);

  /// A probe taking longer than this counts as [ProbeOutcome.failure].
  static const probeTimeout = Duration(seconds: 10);

  /// Hard bound on the connectivity platform read inside a probe (see
  /// [_readConnectivity]): short, because a hang here must never be
  /// allowed to stall the probe cadence itself.
  static const connectivityReadTimeout = Duration(seconds: 3);

  /// Whether [results] look like a metered connection.
  ///
  /// `connectivity_plus` exposes no metered flag, so cellular-only (and
  /// anything that is neither wifi nor ethernet) is the proxy: when the OS
  /// cannot tell us the link is unmetered, we assume it is metered.
  static bool isMeteredConnection(List<ConnectivityResult> results) {
    if (results.isEmpty) return false;
    return !results.contains(ConnectivityResult.wifi) &&
        !results.contains(ConnectivityResult.ethernet);
  }

  /// The probe interval for [results]: stretched when metered.
  static Duration intervalFor(List<ConnectivityResult> results) =>
      isMeteredConnection(results) ? meteredProbeInterval : probeInterval;

  final ProbeFn? _probeOverride;
  final CheckConnectivityFn? _checkConnectivityOverride;
  final Stream<List<ConnectivityResult>>? _connectivityChangesOverride;
  final http.Client? _httpClient;

  /// The probe's own long-lived client (created lazily, closed on
  /// [stop]). Null when a client was injected for tests.
  http.Client? _probeClient;

  /// Test seam: replaces the 15s/60s probe cadence (the production intervals
  /// are the class constants). Lets a test prove the timer chain re-arms.
  final Duration? _probeIntervalOverride;

  /// The most recent completed probe's outcome and wall-clock duration
  /// (null before the first probe). Observability hook: a device retest can
  /// read these (via logcat's per-probe line) to see exactly what the
  /// classifier saw — this is how the weak banner's absence under a network
  /// throttle gets proven or disproven on-device instead of argued from code.
  ProbeOutcome? get lastProbeOutcome => _lastProbeOutcome;
  ProbeOutcome? _lastProbeOutcome;
  Duration? get lastProbeElapsed => _lastProbeElapsed;
  Duration? _lastProbeElapsed;

  final ConnectionClassifier _classifier = ConnectionClassifier();
  final ValueNotifier<ConnectionQuality> _state =
      ValueNotifier<ConnectionQuality>(ConnectionQuality.ok);

  /// The current quality; the shell banner watches this.
  ValueListenable<ConnectionQuality> get listenable => _state;

  ConnectionQuality get state => _state.value;

  /// Completed probes since construction. Test/observability hook.
  int get probeCount => _probeCount;
  int _probeCount = 0;

  bool get isStarted => _started;
  bool _started = false;
  bool _foreground = true;
  bool _probeInFlight = false;
  Timer? _timer;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  List<ConnectivityResult> _lastResults = const [];

  /// Starts periodic probing (idempotent). Safe to call before sign-in:
  /// the probe is unauthenticated.
  void start() {
    if (_started) return;
    _started = true;
    _watchConnectivity();
    unawaited(probeNow());
    _scheduleNext();
  }

  /// Stops all probing and releases the timer + connectivity subscription.
  /// The last known state is kept, not reset.
  void stop() {
    _started = false;
    _timer?.cancel();
    _timer = null;
    unawaited(_connectivitySub?.cancel());
    _connectivitySub = null;
    _probeClient?.close();
    _probeClient = null;
  }

  /// Foreground/background switch from the app lifecycle: backgrounding
  /// pauses all probing; resuming probes immediately and restarts the
  /// cadence.
  void setForeground(bool foreground) {
    if (_foreground == foreground) return;
    _foreground = foreground;
    if (!_started) return;
    if (foreground) {
      _watchConnectivity();
      unawaited(probeNow());
      _scheduleNext();
    } else {
      _timer?.cancel();
      _timer = null;
      unawaited(_connectivitySub?.cancel());
      _connectivitySub = null;
    }
  }

  /// Runs one probe immediately (route change, app resume). A no-op while
  /// another probe is in flight, so bursts of triggers never overlap or
  /// reorder outcomes. Never throws.
  Future<void> probeNow() async {
    if (_probeInFlight) return;
    _probeInFlight = true;
    final probeStopwatch = Stopwatch()..start();
    try {
      final outcome = await _runProbe();
      _lastProbeOutcome = outcome;
      _lastProbeElapsed = probeStopwatch.elapsed;
      _classifier.record(outcome);
      _state.value = _classifier.state;
      debugPrint(
        '[heartbeat] probe $outcome in ${_lastProbeElapsed!.inMilliseconds}ms '
        '-> ${_state.value} (probe ${probeCount + 1})',
      );
    } catch (_) {
      // Belt and braces: a probe must never take down its trigger.
      _lastProbeOutcome = ProbeOutcome.failure;
      _lastProbeElapsed = probeStopwatch.elapsed;
      _classifier.record(ProbeOutcome.failure);
      _state.value = _classifier.state;
      debugPrint(
        '[heartbeat] probe failure in ${_lastProbeElapsed!.inMilliseconds}ms '
        '-> ${_state.value} (probe ${probeCount + 1})',
      );
    } finally {
      _probeCount++;
      _probeInFlight = false;
    }
  }

  Future<ProbeOutcome> _runProbe() async {
    final override = _probeOverride;
    if (override != null) return override();
    final results = await _readConnectivity();
    _lastResults = results;
    if (!results.any((r) => r != ConnectivityResult.none)) {
      return ProbeOutcome.failure;
    }
    final stopwatch = Stopwatch()..start();
    try {
      // One long-lived client, the way ApiClient holds a single client
      // for all real data calls: the socket stays warm between probes,
      // so the measured time is the path's latency — not a fresh
      // DNS+TLS+TCP setup on every tick, a cost no app request pays
      // on every call.
      final client = _httpClient ?? (_probeClient ??= http.Client());
      final response = await client
          .get(Uri.parse('${Env.apiBaseUrl}/health'))
          .timeout(probeTimeout);
      if (response.statusCode != 200) return ProbeOutcome.failure;
    } catch (_) {
      return ProbeOutcome.failure;
    }
    stopwatch.stop();
    return stopwatch.elapsed > weakLatencyBudget
        ? ProbeOutcome.slow
        : ProbeOutcome.good;
  }

  Future<List<ConnectivityResult>> _readConnectivity() async {
    final override = _checkConnectivityOverride;
    try {
      // Bounded: on some hosts (observed on the Android emulator,
      // 2026-11-05) the platform call never returns, which wedged
      // [probeNow] behind its in-flight flag and silently killed every
      // later probe — no weak verdict could ever be reached. The timeout
      // falls through to the HTTP probe, which classifies honestly.
      final read = override != null
          ? override()
          : Connectivity().checkConnectivity();
      return await read.timeout(connectivityReadTimeout);
    } catch (_) {
      // No plugin on this host (unit tests, exotic platforms), or the
      // platform call outlived its bound: assume a usable link and let
      // the probe itself decide.
      return const [ConnectivityResult.other];
    }
  }

  void _watchConnectivity() {
    _connectivitySub?.cancel();
    try {
      final stream = _connectivityChangesOverride ??
          Connectivity().onConnectivityChanged;
      _connectivitySub = stream.listen(
        (results) {
          _lastResults = results;
          if (!results.any((r) => r != ConnectivityResult.none)) {
            // Fast offline path: still one hysteresis-counted failure, so
            // a single blip cannot flap the banner on its own.
            _classifier.record(ProbeOutcome.failure);
            _state.value = _classifier.state;
          } else {
            unawaited(probeNow());
          }
        },
        onError: (_) {},
      );
    } catch (_) {
      // connectivity_plus unavailable here — the periodic probe still runs.
    }
    // Keep the cadence honest: re-arm the timer against the latest link
    // type so a wifi->cellular handoff stretches without waiting a tick.
    _scheduleNext();
  }

  void _scheduleNext() {
    _timer?.cancel();
    _timer = null;
    if (!_started || !_foreground) return;
    _timer = Timer(_probeIntervalOverride ?? intervalFor(_lastResults),
        () async {
      await probeNow();
      _scheduleNext();
    });
  }
}

/// Probes the heartbeat on every navigation, so the banner reflects the
/// connection on the page the user just opened — not on the last tick.
///
/// Registered on [appRouter]'s observers. A no-op until the heartbeat is
/// started (the shell banner starts it), so hosts that navigate the router
/// without the shell — widget tests — never trigger a real probe.
class HeartbeatRouteObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    _kick();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    _kick();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    _kick();
  }

  void _kick() {
    if (!ConnectionHeartbeat.instance.isStarted) return;
    unawaited(ConnectionHeartbeat.instance.probeNow());
  }
}

/// The shared route observer, mirroring `screenRouteObserver`.
final HeartbeatRouteObserver heartbeatRouteObserver = HeartbeatRouteObserver();
