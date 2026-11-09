import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import '../env.dart';
import '../features/date_sim/date_sim_models.dart';
import '../widgets/taste_models.dart';
import '../features/practice_date/practice_models.dart';
import '../legal/biometric_consent_text.dart';
import '../models/living_report.dart';
import '../models/report_share.dart';
import '../models/share_link.dart';
import 'biometric_consent.dart';

/// Target budget for interactive API and Firestore waits (PERF_PLAN Phase 1).
const kInteractiveTimeout = Duration(seconds: 8);

/// Default budget for background startup flag-refreshes (PERF_PLAN / Scout NOTE 140).
/// Accommodates cold boot ProviderInstaller, TLS provider patching, and radio init.
const kStartupFlagRefreshTimeout = Duration(seconds: 25);

/// Long timeout for multi-model server-side operations (e.g. photoPublish moderation + face embedding).
const kLongTimeout = Duration(seconds: 55);

/// An HTTP client wrapper enforcing interactive timeout budgets (target ≤8s),
/// bounded retry with backoff for idempotent GETs, and concurrent GET deduplication
/// (PERF_PLAN Phase 1).
class BudgetHttpClient extends http.BaseClient {
  BudgetHttpClient(
    this._inner, {
    this.interactiveTimeout = kInteractiveTimeout,
    this.longTimeout = kLongTimeout,
  });

  final http.Client _inner;
  final Duration interactiveTimeout;
  final Duration longTimeout;

  final Map<String, Future<http.Response>> _inFlightGets = {};

  // Endpoints whose server work legitimately runs well past the 8s interactive
  // budget — model/report/photo builds, external-affinity (taste) resolution,
  // and cold-start-sensitive first calls. The 8s budget aborts them
  // client-side (TimeoutException -> ApiException 408) while the server logs
  // `200 OK`, surfacing as "Couldn't finish…/load…/start…". The bounded GET
  // retry runs inside the same deadline and cannot heal a deterministic >8s
  // latency, so these must take the long (but still bounded) budget. We've hit
  // this 3x (practice-start, /match/ SWEEP451-M1, /appearance/report). The
  // FAST reads of the SAME resources deliberately stay on the interactive
  // budget: GET /appearance/report/{id}, /appearance/history|coverage|
  // eligibility, /deep-dive/mine, /deep-dive-report/{id}, /physical-attributes,
  // /skills/report/* — they are stored reads, not builds.
  //
  // Matched by EXACT path (a build POST that shares its prefix with fast
  // reads, e.g. POST `/appearance/report` vs GET `/appearance/report/{id}`).
  static const _longBudgetExactPaths = <String>{
    '/wiki/photo-publish', // moderation + face embedding
    '/appearance/report', // POST: multi-photo face+body vision build (>8s)
    '/deep-dive', // POST: web research + model synthesis
    '/face-report', // POST: facial-beauty vision model
    '/body-report', // POST: physique vision model
    '/physical-attributes/refresh', // POST: re-run of the vision pass
    '/check-compatibility', // POST: token-intensive pairwise match-score model
    '/media', // POST: unified photo pipeline (moderate→embed→attributes→caption)
    '/media/photos/batch', // POST: analyses up to 9 photos into the Appearance report
    '/verification/selfie', // POST: moderate+embed selfie, seeds the initial Appearance read
    '/taste/pair', // POST: taste cross-domain affinity (same resolution /match/ warm-returns in ~13–15s)
    '/chat', // POST: non-stream model turn (tool use / cold start); fallback for /chat/stream
  };

  // Matched by PREFIX (a whole family of long builds / reads under one root).
  static const _longBudgetPrefixes = <String>[
    '/practice/', // builds the match persona + runs the model; first call after cold start (~18s)
    '/match/', // match-report read resolves taste affinity (~13–15s)
    '/report/match/', // the same match report via the generic report hub
  ];

  static bool _isLongBudgetPath(String path) {
    if (_longBudgetExactPaths.contains(path)) return true;
    // Report tap-to-correct (`/report/{type}/{id}/correct`) regenerates report
    // blocks with the model — a model turn, not a quick read.
    if (path.endsWith('/correct')) return true;
    for (final prefix in _longBudgetPrefixes) {
      if (path.startsWith(prefix)) return true;
    }
    return false;
  }

  Duration _timeoutFor(Uri url, Map<String, String>? headers) {
    final custom = headers?['X-Request-Timeout'];
    if (custom != null) {
      final ms = int.tryParse(custom);
      if (ms != null) return Duration(milliseconds: ms);
    }
    if (_isLongBudgetPath(url.path)) return longTimeout;
    return interactiveTimeout;
  }

  /// Long/streaming runs whose duration is driven by the server, not the
  /// client: they must never hit the interactive budget (mirrors `/chat/stream`,
  /// which bypasses this wrapper via [send]). A date simulation streams its
  /// transcript into Firestore for the whole run — minutes, not seconds — so
  /// the POST (and its `/continue`) is exempt from any client timeout.
  bool _noClientTimeout(Uri url) {
    final p = url.path;
    return p == '/date-sim' ||
        (p.startsWith('/date-sim/') && p.endsWith('/continue'));
  }

  Map<String, String>? _cleanHeaders(Map<String, String>? headers) {
    if (headers == null ||
        !(headers.containsKey('X-Request-Timeout') ||
            headers.containsKey('X-No-Retry'))) {
      return headers;
    }
    final copy = Map<String, String>.from(headers)
      ..remove('X-Request-Timeout')
      ..remove('X-No-Retry');
    return copy;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    return _inner.send(request);
  }

  @override
  Future<http.Response> get(Uri url, {Map<String, String>? headers}) {
    final clean = _cleanHeaders(headers);
    final key = '$url|${clean?['Authorization'] ?? ''}';
    final existing = _inFlightGets[key];
    if (existing != null) return existing;

    final timeout = _timeoutFor(url, headers);
    // The pending-chat-queue flush has its own retry/dedup and must fail fast
    // offline (a backoff here would outlive the flush and skip the online
    // retry, PERF_PLAN GATE-RED). Such callers opt out with `X-No-Retry`.
    final maxAttempts = headers?['X-No-Retry'] == '1' ? 1 : 2;
    final future = _executeGet(url, clean, timeout, maxAttempts);
    _inFlightGets[key] = future;
    future.whenComplete(() => _inFlightGets.remove(key)).ignore();
    return future;
  }

  Future<http.Response> _executeGet(
    Uri url,
    Map<String, String>? headers,
    Duration timeout,
    int maxAttempts, // Bounded retry for idempotent GETs (1 = no retry)
  ) async {
    final deadline = DateTime.now().add(timeout);

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        throw ApiException('Request timed out — please try again.', statusCode: 408);
      }
      try {
        final r = await _inner.get(url, headers: headers).timeout(remaining);
        if (attempt < maxAttempts &&
            (r.statusCode == 502 || r.statusCode == 503 || r.statusCode == 504)) {
          final after = deadline.difference(DateTime.now());
          if (after > const Duration(milliseconds: 400)) {
            await Future.delayed(const Duration(milliseconds: 300));
            continue;
          }
        }
        return r;
      } on TimeoutException {
        if (attempt < maxAttempts) {
          final after = deadline.difference(DateTime.now());
          if (after > const Duration(milliseconds: 400)) {
            await Future.delayed(const Duration(milliseconds: 300));
            continue;
          }
        }
        throw ApiException('Request timed out — please try again.', statusCode: 408);
      } on http.ClientException catch (e) {
        if (attempt < maxAttempts) {
          final after = deadline.difference(DateTime.now());
          if (after > const Duration(milliseconds: 400)) {
            await Future.delayed(const Duration(milliseconds: 300));
            continue;
          }
        }
        throw ApiException('Network error: ${e.message}');
      }
    }
    throw ApiException('Request timed out — please try again.', statusCode: 408);
  }

  @override
  Future<http.Response> post(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
    Encoding? encoding,
  }) async {
    final clean = _cleanHeaders(headers);
    try {
      final send =
          _inner.post(url, headers: clean, body: body, encoding: encoding);
      // Streaming/long runs drive their own duration — no client timeout.
      return _noClientTimeout(url)
          ? await send
          : await send.timeout(_timeoutFor(url, headers));
    } on TimeoutException {
      throw ApiException('Request timed out — please try again.', statusCode: 408);
    } on http.ClientException catch (e) {
      throw ApiException('Network error: ${e.message}');
    }
  }

  @override
  Future<http.Response> put(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
    Encoding? encoding,
  }) async {
    final timeout = _timeoutFor(url, headers);
    final clean = _cleanHeaders(headers);
    try {
      return await _inner
          .put(url, headers: clean, body: body, encoding: encoding)
          .timeout(timeout);
    } on TimeoutException {
      throw ApiException('Request timed out — please try again.', statusCode: 408);
    } on http.ClientException catch (e) {
      throw ApiException('Network error: ${e.message}');
    }
  }

  @override
  Future<http.Response> delete(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
    Encoding? encoding,
  }) async {
    final timeout = _timeoutFor(url, headers);
    final clean = _cleanHeaders(headers);
    try {
      return await _inner
          .delete(url, headers: clean, body: body, encoding: encoding)
          .timeout(timeout);
    } on TimeoutException {
      throw ApiException('Request timed out — please try again.', statusCode: 408);
    } on http.ClientException catch (e) {
      throw ApiException('Network error: ${e.message}');
    }
  }

  @override
  void close() => _inner.close();
}

/// Server caps for the context-carried strings on a chat send, mirroring
/// `functions/bootstrap/main.py` (TurnModel.text and the ChatRequest fields).
/// Context is attached from data the user did not type for this send, so it
/// is clamped at send time instead of ever letting the wire exceed a cap and
/// bounce the whole send with a 422 against any server version (2026-11-07:
/// a 4,642-char self-check summary bubble bricked every later send).
abstract final class ChatContextCaps {
  static const turnText = 4000;
  static const sessionId = 128;
  static const clientMsgId = 64;
  static const viewingProfileUid = 128;
  static const imagePath = 256;
  static const storyPageId = 80;
  static const storyPassage = 8000;
  static const storyTimelineEntryId = 64;
  static const deepDiveReportId = 128;
  static const deepDiveTarget = 2200;
  static const appearanceFindingId = 64;
  static const matchReportId = 128;
  static const sharedKind = 32;
  static const sharedRefId = 128;
  static const sharedSubjectUid = 128;
  static const sharedSubjectName = 200;
  static const sharedRefVersion = 64;
  static const replyImagePath = 256;
  static const sharedCardKind = 32;
  static const sharedCardUid = 128;
  static const sharedCardName = 200;
  static const sharedCardPhoto = 2000;
  static const sharedCardRefId = 128;
  static const photoUrl = 2000;
  static const photoSource = 16;
  static const screen = 32;
  static const screenSubjectUid = 128;
  static const screenSubjectName = 200;
  static const screenNote = 500;
  static const screenRoute = 200;
  static const screenPreviousRoute = 200;
  static const screenPreviousLabel = 200;
  static const screenDetail = 1500;
  static const screenVisible = 3200;
}

/// Clamp one context string to [cap] characters (no-op when already within).
String clampChatContext(String value, int cap) =>
    value.length <= cap ? value : value.substring(0, cap);

/// Clamp every turn text in a recent-turns window to the TurnModel cap.
List<Map<String, String>> clampRecentTurns(
  List<Map<String, String>> recentTurns,
) =>
    [
      for (final turn in recentTurns)
        {
          for (final entry in turn.entries)
            entry.key: entry.key == 'text'
                ? clampChatContext(entry.value, ChatContextCaps.turnText)
                : entry.value,
        },
    ];

/// A snapshot of the user's voice-call state, stamped onto `/chat`,
/// `/chat/stream` and `/bootstrap` payloads as the nested `call_state`
/// object (backend `CallStateModel`) so Ayma's context always knows
/// whether a voice call is live or just ended (founder directive
/// 2026-11-07, ledger 2cy: a call that ended by 30 s of silence was
/// invisible to the text model, which answered a typed "disconnect"
/// with "We aren't on a voice call right now" — as if the call had
/// never happened). Produced by `VoiceSessionController` (its
/// last-ended record); defined here so the wire client and the
/// controller share one type without an import cycle.
class CallStateSnapshot {
  const CallStateSnapshot._(this.status, this.endedSecondsAgo, this.reason);

  /// A voice call is live right now.
  const CallStateSnapshot.active() : this._('active', null, '');

  /// No live call, and none ended recently enough to matter.
  const CallStateSnapshot.none() : this._('none', null, '');

  /// A call ended [secondsAgo] ago for [reason] (a client disconnect
  /// reason: `user_stop`, `text_disconnect`, `client_idle_timeout`,
  /// `agent_idle_timeout`, `dropped`, `out_of_credits`, `error`, ...).
  const CallStateSnapshot.justEnded({
    required int secondsAgo,
    required String reason,
  }) : this._('just_ended', secondsAgo, reason);

  /// `active`, `just_ended`, or `none`.
  final String status;

  /// Seconds since the call ended; set only for `just_ended`.
  final int? endedSecondsAgo;

  /// Why the call ended; set only for `just_ended`.
  final String reason;

  bool get isActive => status == 'active';
  bool get isJustEnded => status == 'just_ended';

  /// The `call_state` payload object, or null when there is nothing to
  /// report — an absent field renders as no call context at all,
  /// exactly like an older client.
  Map<String, dynamic>? get wireJson {
    switch (status) {
      case 'active':
        return {'in_call': true, 'end_reason': ''};
      case 'just_ended':
        return {
          'in_call': false,
          if (endedSecondsAgo != null) 'ended_seconds_ago': endedSecondsAgo,
          'end_reason': reason,
        };
      default:
        return null;
    }
  }
}

/// The clamped wire body shared by `POST /chat` and `POST /chat/stream`.
/// The users own [message] is passed through untouched on purpose: it is
/// their input, not context, and stays strict server-side.
Map<String, dynamic> buildChatRequestBody({
  required String message,
  String sessionId = '',
  String clientMsgId = '',
  String viewingProfileUid = '',
  List<Map<String, String>> recentTurns = const [],
  String imagePath = '',
  String storyPageId = '',
  String storyPassage = '',
  String storyTimelineEntryId = '',
  String deepDiveReportId = '',
  String deepDiveTarget = '',
  String appearanceFindingId = '',
  String matchReportId = '',
  String sharedKind = '',
  String sharedRefId = '',
  String sharedSubjectUid = '',
  String sharedSubjectName = '',
  String sharedRefVersion = '',
  String replyImagePath = '',
  String sharedCardKind = '',
  String sharedCardUid = '',
  String sharedCardName = '',
  String sharedCardPhoto = '',
  String sharedCardRefId = '',
  bool profileEdit = false,
  String photoUrl = '',
  String photoSource = '',
  String screen = '',
  String screenSubjectUid = '',
  String screenSubjectName = '',
  String screenNote = '',
  String screenRoute = '',
  String screenDetail = '',
  String screenVisible = '',
  String screenPreviousRoute = '',
  String screenPreviousLabel = '',
  bool tourContinuation = false,
  bool includeTourContinuation = true,
  CallStateSnapshot callState = const CallStateSnapshot.none(),
}) =>
    {
      'message': message,
      'session_id': clampChatContext(sessionId, ChatContextCaps.sessionId),
      'client_msg_id':
          clampChatContext(clientMsgId, ChatContextCaps.clientMsgId),
      if (includeTourContinuation) 'tour_continuation': tourContinuation,
      'viewing_profile_uid': clampChatContext(
          viewingProfileUid, ChatContextCaps.viewingProfileUid),
      'recent_turns': clampRecentTurns(recentTurns),
      'image_path': clampChatContext(imagePath, ChatContextCaps.imagePath),
      'story_page_id':
          clampChatContext(storyPageId, ChatContextCaps.storyPageId),
      'story_passage':
          clampChatContext(storyPassage, ChatContextCaps.storyPassage),
      'story_timeline_entry_id': clampChatContext(
          storyTimelineEntryId, ChatContextCaps.storyTimelineEntryId),
      'deep_dive_report_id': clampChatContext(
          deepDiveReportId, ChatContextCaps.deepDiveReportId),
      'deep_dive_target':
          clampChatContext(deepDiveTarget, ChatContextCaps.deepDiveTarget),
      'appearance_finding_id': clampChatContext(
          appearanceFindingId, ChatContextCaps.appearanceFindingId),
      'match_report_id':
          clampChatContext(matchReportId, ChatContextCaps.matchReportId),
      // A staged Send-to-Ayma share of a report kind: the REFERENCE only
      // (kind + report id + subject + the opened run's version stamp) —
      // never the report's contents. Ayma pulls the exact report herself
      // server-side (founder 2026-11-09: reference, not content).
      'shared_kind': clampChatContext(sharedKind, ChatContextCaps.sharedKind),
      'shared_ref_id':
          clampChatContext(sharedRefId, ChatContextCaps.sharedRefId),
      'shared_subject_uid':
          clampChatContext(sharedSubjectUid, ChatContextCaps.sharedSubjectUid),
      'shared_subject_name': clampChatContext(
          sharedSubjectName, ChatContextCaps.sharedSubjectName),
      'shared_ref_version':
          clampChatContext(sharedRefVersion, ChatContextCaps.sharedRefVersion),
      // A swipe-reply to a photo message: the REFERENCE to that photo
      // (its storage path) — never the photo itself. The server pulls
      // the exact photo from the reference (founder 2026-11-09).
      'reply_image_path':
          clampChatContext(replyImagePath, ChatContextCaps.replyImagePath),
      // The Send-to-Ayma CARD posted with this send (any kind): its
      // identity only, so the server can persist it on the user turn and
      // the card renders again from history after a restart. Distinct
      // from the shared_* reference above, which binds the report-pull
      // tool and is set for report kinds only.
      'shared_card_kind':
          clampChatContext(sharedCardKind, ChatContextCaps.sharedCardKind),
      'shared_card_uid':
          clampChatContext(sharedCardUid, ChatContextCaps.sharedCardUid),
      'shared_card_name':
          clampChatContext(sharedCardName, ChatContextCaps.sharedCardName),
      'shared_card_photo':
          clampChatContext(sharedCardPhoto, ChatContextCaps.sharedCardPhoto),
      'shared_card_ref_id':
          clampChatContext(sharedCardRefId, ChatContextCaps.sharedCardRefId),
      'profile_edit': profileEdit,
      'photo_url': clampChatContext(photoUrl, ChatContextCaps.photoUrl),
      'photo_source':
          clampChatContext(photoSource, ChatContextCaps.photoSource),
      'screen': clampChatContext(screen, ChatContextCaps.screen),
      'screen_subject_uid':
          clampChatContext(screenSubjectUid, ChatContextCaps.screenSubjectUid),
      'screen_subject_name': clampChatContext(
          screenSubjectName, ChatContextCaps.screenSubjectName),
      'screen_note': clampChatContext(screenNote, ChatContextCaps.screenNote),
      'screen_route':
          clampChatContext(screenRoute, ChatContextCaps.screenRoute),
      'screen_detail':
          clampChatContext(screenDetail, ChatContextCaps.screenDetail),
      'screen_visible':
          clampChatContext(screenVisible, ChatContextCaps.screenVisible),
      'screen_previous_route': clampChatContext(
          screenPreviousRoute, ChatContextCaps.screenPreviousRoute),
      'screen_previous_label': clampChatContext(
          screenPreviousLabel, ChatContextCaps.screenPreviousLabel),
      // Voice-call state (founder directive 2026-11-07, ledger 2cy):
      // the nested `call_state` object, present only when the caller
      // computed a snapshot with something to report, so payloads from
      // call sites that never did stay byte-identical to before.
      if (callState.wireJson != null) 'call_state': callState.wireJson,
    };

/// Thin client for the Ayma Main API. Every call attaches the current Firebase
/// ID token as a Bearer header (§3.4).
class ApiClient {
  ApiClient({
    http.Client? httpClient,
    FirebaseAuth? auth,
    this.chatStreamConnectTimeout = const Duration(seconds: 30),
    this.chatStreamIdleTimeout = const Duration(seconds: 60),
    this.interactiveTimeout = kInteractiveTimeout,
    this.longTimeout = kLongTimeout,
  }) : _http = BudgetHttpClient(
         ConsentAwareHttpClient(httpClient ?? http.Client()),
         interactiveTimeout: interactiveTimeout,
         longTimeout: longTimeout,
       ),
       _auth = auth ?? FirebaseAuth.instance;

  /// How long `/chat/stream` may take to answer the request, and how long it
  /// may then go without a single byte. The server sends a keepalive comment
  /// every 15s, so silence past [chatStreamIdleTimeout] means a dead socket —
  /// it surfaces as a connection-class [ApiException] (never an endless
  /// "Thinking…") and the caller reconciles / offers Retry.
  final Duration chatStreamConnectTimeout;
  final Duration chatStreamIdleTimeout;

  /// Startup deadlines (§11.2). The splash's `/bootstrap` is the first network
  /// the app does, so it gets explicit timeouts: a transient DNS/connectivity
  /// blip must surface as a connection-class [ApiException] the splash can
  /// retry, never an endless spinner. [_bootstrapTokenTimeout] caps the
  /// Firebase ID-token refresh (a silent network call that can otherwise hang
  /// forever); [_bootstrapPostTimeout] caps the POST itself.
  static const _bootstrapTokenTimeout = Duration(seconds: 12);
  static const _bootstrapPostTimeout = Duration(seconds: 15);

  /// Budget for interactive user-facing calls (target ≤8s, PERF_PLAN Phase 1).
  final Duration interactiveTimeout;

  /// Extended budget for known long-running multi-model operations (e.g. photo publish).
  final Duration longTimeout;

  final http.Client _http;
  final FirebaseAuth _auth;

  Future<http.Response> _get(
    Uri uri, {
    Map<String, String>? headers,
    Duration? timeout,
  }) async {
    final h = Map<String, String>.from(headers ?? await _headers());
    if (timeout != null) {
      h['X-Request-Timeout'] = '${timeout.inMilliseconds}';
    }
    return _http.get(uri, headers: h);
  }

  Future<http.Response> _post(
    Uri uri, {
    Map<String, String>? headers,
    Object? body,
    Duration? timeout,
  }) async {
    final h = Map<String, String>.from(headers ?? await _headers());
    if (timeout != null) {
      h['X-Request-Timeout'] = '${timeout.inMilliseconds}';
    }
    return _http.post(uri, headers: h, body: body);
  }

  Future<http.Response> _delete(
    Uri uri, {
    Map<String, String>? headers,
    Object? body,
    Duration? timeout,
  }) async {
    final h = Map<String, String>.from(headers ?? await _headers());
    if (timeout != null) {
      h['X-Request-Timeout'] = '${timeout.inMilliseconds}';
    }
    return _http.delete(uri, headers: h, body: body);
  }

  Future<http.Response> _put(
    Uri uri, {
    Map<String, String>? headers,
    Object? body,
    Duration? timeout,
  }) async {
    final h = Map<String, String>.from(headers ?? await _headers());
    if (timeout != null) {
      h['X-Request-Timeout'] = '${timeout.inMilliseconds}';
    }
    return _http.put(uri, headers: h, body: body);
  }

  Uri _uri(String path) => Uri.parse('${Env.apiBaseUrl}$path');

  /// Fire-and-forget liveness ping that wakes a scaled-to-zero backend ASAP.
  ///
  /// `ayma-api` runs on Cloud Run where min-instances can be 0, so the first
  /// request after an idle period pays a cold-start penalty (~18s+). Firing
  /// `GET /health` the moment the splash mounts starts that warm-up in parallel
  /// with — and usually ahead of — the real `/bootstrap`, so the bootstrap is
  /// far more likely to reach an already-warm instance. `/health` is
  /// unauthenticated server-side (`_CONSENT_EXEMPT_PATHS` + the ID-token
  /// middleware exemption), so this needs no token and runs before the token
  /// refresh. Any error is swallowed: a failed wake-ping changes nothing — the
  /// real bootstrap still runs with its own retry/backoff — so it must never
  /// surface or rethrow.
  Future<void> wakeUp() async {
    try {
      await _http.get(
        _uri('/health'),
        headers: {'X-Request-Timeout': '${_bootstrapPostTimeout.inMilliseconds}'},
      );
    } catch (_) {
      // Intentionally ignored — the ping only ever *helps* the real bootstrap.
    }
  }

  Future<Map<String, String>> _headers() async {
    final token = await _auth.currentUser?.getIdToken();
    if (token == null) {
      throw ApiException('Not signed in.', statusCode: 401);
    }
    return {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    };
  }

  /// `POST /bootstrap` — session bootstrap; returns the derived `session_mode`
  /// and the LiveKit join credentials for this user's voice room (§1.7 step 3,
  /// §1.1).
  Future<BootstrapResult> bootstrap({
    required String sessionId,
    List<Map<String, String>> recentTurns = const [],
    String practiceReturnSessionId = '',
    CallStateSnapshot callState = const CallStateSnapshot.none(),
  }) async {
    final isPracticeReturn = practiceReturnSessionId.isNotEmpty;
    // Refresh the ID token under a deadline. A hang here (flaky DNS reaching
    // Firebase) or a network-level Firebase failure is transient, so it
    // surfaces as a connection-class ApiException (no statusCode) the splash
    // retries — never a stale-token 401 that would wrongly bounce a signed-in
    // user to sign-in.
    final Map<String, String> headers;
    try {
      headers = await _headers().timeout(_bootstrapTokenTimeout);
    } on TimeoutException {
      // A token refresh that never returns is almost always flaky DNS reaching
      // Firebase — a network blip the splash retries. The splash's own overall
      // startup watchdog guarantees this can never spin forever.
      throw ApiException('Network timed out preparing the request.');
    } on FirebaseAuthException catch (e) {
      if (e.code == 'network-request-failed') {
        throw ApiException('Network error: ${e.message ?? e.code}');
      }
      // Any other auth error for a supposedly signed-in user (expired /
      // invalid / revoked token, disabled user) means the restored session is
      // unusable — not a network blip. The splash signs out and routes to
      // sign-in rather than retrying forever.
      throw AuthSessionException('Auth session rejected: ${e.code}');
    } on ApiException {
      // `_headers` own "Not signed in." (null token) — pass it through
      // unchanged so the splash's 401 handling sends them to sign-in.
      rethrow;
    } catch (e) {
      // The Android keystore / decrypt failures that follow an Auto Backup
      // restore onto a wiped keystore ("FirebearStorageCryptoHelper: Exception
      // while decrypting bytes", PlatformException) surface here: the persisted
      // credential can't be read, so the session is broken. Sign out and
      // re-authenticate — never retry, never hang.
      throw AuthSessionException('Auth token unreadable: $e');
    }

    // A practice-return bootstrap makes the server seed the new room with
    // the debrief: it reads the finished practice session and builds the
    // greeting instructions — server work in the same class as the other
    // long-budget builds, deterministically past the 8 s interactive
    // budget. On that budget the client aborted at 8 s with a 408 while
    // the server finished behind it (NOTE 134: the return fired but its
    // token fetch "timed out" twice, identically; a retry cannot heal a
    // deterministic latency — see BudgetHttpClient's long-budget note),
    // so a return takes the long budget, here (the wire client's
    // per-request timeout) and on the outer timeout below.
    if (isPracticeReturn) {
      headers['X-Request-Timeout'] = '${longTimeout.inMilliseconds}';
    }

    final http.Response response;
    try {
      response = await _http
          .post(
            _uri('/bootstrap'),
            headers: headers,
            body: jsonEncode({
              'session_id': sessionId,
              'recent_turns': clampRecentTurns(recentTurns),
              if (practiceReturnSessionId.isNotEmpty)
                'practice_return_session_id': practiceReturnSessionId,
              // Previous voice call, when one just ended (ledger 2cy) —
              // same conditional shape as the practice-return id above.
              if (callState.wireJson != null) 'call_state': callState.wireJson,
            }),
          )
          .timeout(isPracticeReturn ? longTimeout : _bootstrapPostTimeout);
    } on http.ClientException catch (e) {
      throw ApiException('Network error: ${e.message}');
    } on TimeoutException {
      throw ApiException('Network timed out reaching Ayma.');
    }

    if (response.statusCode != 200) {
      throw ApiException(
        'Bootstrap request failed.',
        statusCode: response.statusCode,
        body: response.body,
      );
    }
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;

    if (decoded['age_blocked'] == true) {
      return const BootstrapResult(
        sessionMode: '',
        livekitUrl: '',
        livekitToken: '',
        room: '',
        ageBlocked: true,
      );
    }

    if (decoded['recovery_required'] == true) {
      return const BootstrapResult(
        sessionMode: '',
        livekitUrl: '',
        livekitToken: '',
        room: '',
        recoveryRequired: true,
      );
    }

    // No face-matching consent on record yet (biometric_consent.py): the
    // splash screen records the one ticked at sign-in, or shows the one-time
    // consent screen. Nothing else works until it is recorded.
    if (decoded['biometric_consent_required'] == true) {
      BiometricConsentState.instance.markRequired();
      return BootstrapResult(
        sessionMode: decoded['session_mode'] as String? ?? '',
        livekitUrl: '',
        livekitToken: '',
        room: '',
        biometricConsentRequired: true,
      );
    }

    // Out of credits — voice is an LLM session, so the server returns no
    // LiveKit creds and the client doesn't connect. `session_mode` is still
    // present: being broke must not dump a signed-in user into marketing mode,
    // so we route on it as usual and just surface a "reload credits" notice.
    if (decoded['usage_capped'] == true) {
      return BootstrapResult(
        sessionMode: decoded['session_mode'] as String? ?? '',
        livekitUrl: '',
        livekitToken: '',
        room: '',
        usageCapped: true,
      );
    }

    final livekit = decoded['livekit'] as Map<String, dynamic>?;
    if (livekit == null) {
      throw ApiException('Bootstrap response missing LiveKit credentials.');
    }
    return BootstrapResult(
      sessionMode: decoded['session_mode'] as String? ?? '',
      livekitUrl: livekit['url'] as String? ?? '',
      livekitToken: livekit['token'] as String? ?? '',
      room: livekit['room'] as String? ?? '',
      voiceProvider: livekit['voice_provider'] as String? ?? '',
    );
  }

  /// `POST /welcome/token` — a LiveKit token for the pre-sign-in "welcome"
  /// voice room. Unauthenticated (there is no account yet); Ayma opens the
  /// call with a short greeting.
  Future<({String url, String token})> welcomeToken() async {
    final r = await _http.post(
      _uri('/welcome/token'),
      headers: const {'Content-Type': 'application/json'},
    );
    if (r.statusCode != 200) {
      throw ApiException(
        'welcome token failed.',
        statusCode: r.statusCode,
        body: r.body,
      );
    }
    final lk =
        (jsonDecode(r.body) as Map<String, dynamic>)['livekit']
            as Map<String, dynamic>?;
    return (
      url: lk?['url'] as String? ?? '',
      token: lk?['token'] as String? ?? '',
    );
  }

  /// `POST /auth/email-exists` — whether a Firebase account holds this email.
  /// Unauthenticated by design (the caller isn't signed in yet): this is how
  /// sign-in tells "wrong password" from "unknown email" under Firebase's
  /// email-enumeration protection, which reports both to the client as
  /// `invalid-credential`. Throws [ApiException] on any non-200 — the caller
  /// must treat that as "unknown", never as either answer.
  Future<bool> emailExists(String email) async {
    final r = await _http.post(
      _uri('/auth/email-exists'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'email': email}),
    );
    if (r.statusCode != 200) {
      throw ApiException(
        'email-exists check failed.',
        statusCode: r.statusCode,
        body: r.body,
      );
    }
    return (jsonDecode(r.body) as Map<String, dynamic>)['exists'] == true;
  }

  /// `GET /explore` — the live filtered feed (§6.1), cursor-paginated
  /// (Phase 2 pagination design §3.1). [q] is a natural-language search parsed
  /// once server-side; [filters] are exact dropdown values; [limit] sizes the
  /// page (24 cards = 12 two-column rows); [cursor] continues a feed.
  Future<ExplorePage> explore({
    String q = '',
    Map<String, String> filters = const {},
    int limit = 24,
    String? cursor,
    Duration? timeout,
  }) async {
    final params = <String, String>{
      'limit': '$limit',
      if (q.isNotEmpty) 'q': q,
      if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
      ...filters,
    };
    final uri = _uri('/explore').replace(queryParameters: params);
    final headers = await _headers();
    // The on-open feed load raises this past the 8s interactive budget so the
    // first call can ride through a scale-to-zero cold start instead of 408-ing
    // (ExploreScreen._loadInitial wraps it in a cold-start retry on top).
    if (timeout != null) {
      headers['X-Request-Timeout'] = '${timeout.inMilliseconds}';
    }
    final response = await _http.get(uri, headers: headers);
    if (response.statusCode != 200) {
      throw ApiException(
        'explore failed.',
        statusCode: response.statusCode,
        body: response.body,
      );
    }
    return ExplorePage.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>);
  }

  /// `GET /explore/profile/{uid}` — another user's public profile: photos,
  /// the public wiki narrative, plus the caller-relative score / like state
  /// and the DM thread id.
  Future<PublicProfile> publicProfile(String otherUid) async {
    final r = await _http.get(
      _uri('/explore/profile/$otherUid'),
      headers: await _headers(),
    );
    if (r.statusCode != 200) {
      throw ApiException(
        'profile load failed.',
        statusCode: r.statusCode,
        body: r.body,
      );
    }
    return PublicProfile.fromMap(jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// `POST /deep-dive` — a consented web deep-dive on a named person. Empty
  /// [targetUid] (or your own) researches you; another uid researches them.
  /// Ayma's summary is also appended to the chat transcript server-side.
  /// [force] skips the reuse cache for a re-run on someone you've already
  /// looked up (a self dive always ignores the cache regardless).
  Future<DeepDiveResult> deepDive({
    String targetUid = '',
    String name = '',
    String context = '',
    bool force = false,
  }) async {
    final r = await _http.post(
      _uri('/deep-dive'),
      headers: await _headers(),
      body: jsonEncode({
        'target_uid': targetUid,
        'name': name,
        'context': context,
        'force': force,
      }),
    );
    if (r.statusCode != 200) {
      throw ApiException(
        'deep-dive failed.',
        statusCode: r.statusCode,
        body: r.body,
      );
    }
    final m = jsonDecode(r.body) as Map<String, dynamic>;
    return DeepDiveResult(
      usageCapped: m['usage_capped'] == true,
      queued: m['queued'] == true,
      summary: m['summary'] as String? ?? '',
      reportId: m['report_id'] as String? ?? '',
      isSelf: m['is_self'] == true,
      subjectImage: m['subject_image'] as String? ?? '',
      toolLabel: m['tool_label'] as String? ?? '',
      links: (((m['digest'] as Map?) ?? const {})['links'] as List? ?? const [])
          .map(
            (e) => DeepDiveLink(
              url: (e as Map)['url'] as String? ?? '',
              title: e['title'] as String? ?? '',
              isThem: e['is_them'] as String? ?? 'unclear',
            ),
          )
          .where((l) => l.url.isNotEmpty)
          .toList(),
    );
  }

  /// `GET /deep-dive-report/{id}` — re-open a stored web dive by its id (from a
  /// `[deep_dive:<id>]` chat marker or the "View research" button).
  Future<DeepDiveReport> deepDiveReport(String id) async {
    final r = await _http.get(
      _uri('/deep-dive-report/${Uri.encodeComponent(id)}'),
      headers: await _headers(),
    );
    if (r.statusCode != 200) {
      throw ApiException(
        'deep-dive report failed.',
        statusCode: r.statusCode,
        body: r.body,
      );
    }
    return DeepDiveReport.fromMap(jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// `GET /deep-dive/mine` — the caller's own current self-dive result, if
  /// any (a self dive is a single record, always overwritten by the latest
  /// run — never a history list). `null` when no self-dive has ever run.
  Future<DeepDiveMine?> deepDiveMine() async {
    final r = await _http.get(
      _uri('/deep-dive/mine'),
      headers: await _headers(),
    );
    if (r.statusCode != 200) {
      throw ApiException(
        'deep-dive mine failed.',
        statusCode: r.statusCode,
        body: r.body,
      );
    }
    final m = jsonDecode(r.body) as Map<String, dynamic>;
    if (m['exists'] != true) return null;
    return DeepDiveMine.fromMap(m);
  }

  /// `POST /face-report` — an honest, data-driven facial-beauty report on a
  /// photo. [attachmentPath] (a chat upload under `uploads/{you}/`) wins;
  /// otherwise [targetUid]'s primary profile photo (empty = your own). Ayma's
  /// one-line pointer is also appended to the chat transcript server-side.
  Future<FaceReportResult> faceReport({
    String attachmentPath = '',
    String targetUid = '',
  }) async {
    final r = await _http.post(
      _uri('/face-report'),
      headers: await _headers(),
      body: jsonEncode({
        'attachment_path': attachmentPath,
        'target_uid': targetUid,
      }),
    );
    if (r.statusCode != 200) {
      throw ApiException(
        'face-report failed.',
        statusCode: r.statusCode,
        body: r.body,
      );
    }
    final m = jsonDecode(r.body) as Map<String, dynamic>;
    return FaceReportResult(
      usageCapped: m['usage_capped'] == true,
      reportId: m['report_id'] as String? ?? '',
      report: m['report'] is Map
          ? FaceReport.fromMap((m['report'] as Map).cast<String, dynamic>())
          : null,
    );
  }

  /// `POST /body-report` — an honest, data-driven physique report on a photo.
  /// Same request shape as [faceReport].
  Future<BodyReportResult> bodyReport({
    String attachmentPath = '',
    String targetUid = '',
  }) async {
    final r = await _http.post(
      _uri('/body-report'),
      headers: await _headers(),
      body: jsonEncode({
        'attachment_path': attachmentPath,
        'target_uid': targetUid,
      }),
    );
    if (r.statusCode != 200) {
      throw ApiException(
        'body-report failed.',
        statusCode: r.statusCode,
        body: r.body,
      );
    }
    final m = jsonDecode(r.body) as Map<String, dynamic>;
    return BodyReportResult(
      usageCapped: m['usage_capped'] == true,
      reportId: m['report_id'] as String? ?? '',
      report: m['report'] is Map
          ? BodyReport.fromMap((m['report'] as Map).cast<String, dynamic>())
          : null,
    );
  }

  /// `GET /skills/report/{kind}/{reportId}` — fetch a stored face / body report
  /// referenced by a `[face_report:<id>]` / `[body_report:<id>]` marker in an
  /// Ayma chat turn. [kind] is `face` or `body`. Returns the raw
  /// `{"report": <dict>, "created_at": <iso|null>}` — the caller picks the
  /// parser ([FaceReport.fromMap] / [BodyReport.fromMap]) by [kind].
  Future<SkillReport> skillReport(String kind, String reportId) async {
    final r = await _http.get(
      _uri(
        '/skills/report/${Uri.encodeComponent(kind)}/'
        '${Uri.encodeComponent(reportId)}',
      ),
      headers: await _headers(),
    );
    if (r.statusCode != 200) {
      throw ApiException(
        'skill report failed.',
        statusCode: r.statusCode,
        body: r.body,
      );
    }
    final m = jsonDecode(r.body) as Map<String, dynamic>;
    final report = m['report'];
    return SkillReport(
      report: report is Map ? report.cast<String, dynamic>() : const {},
      createdAt: m['created_at'] as String?,
      imagePath: m['image_path'] as String? ?? '',
    );
  }

  /// `GET /physical-attributes` — the caller's stored structured physical
  /// profile (build, colouring, rough measurements). `null` when it has never
  /// been built.
  Future<PhysicalAttrsResult?> physicalAttributes() async {
    final r = await _http.get(
      _uri('/physical-attributes'),
      headers: await _headers(),
    );
    if (r.statusCode != 200) {
      throw ApiException(
        'physical-attributes failed.',
        statusCode: r.statusCode,
        body: r.body,
      );
    }
    final m = jsonDecode(r.body) as Map<String, dynamic>;
    if (m['record'] == null) return null;
    return PhysicalAttrsResult.fromMap(m);
  }

  /// `POST /physical-attributes/refresh` — force a re-run of the physical
  /// profile read. [extraPaths] are extra chat-uploaded photos (each under
  /// `uploads/{you}/`) folded into the vision pass on top of the profile grid.
  Future<PhysicalAttrsResult> refreshPhysicalAttributes({
    List<String> extraPaths = const [],
  }) async {
    final r = await _http.post(
      _uri('/physical-attributes/refresh'),
      headers: await _headers(),
      body: jsonEncode({'image_paths': extraPaths}),
    );
    if (r.statusCode != 200) {
      throw ApiException(
        'physical-attributes refresh failed.',
        statusCode: r.statusCode,
        body: r.body,
      );
    }
    return PhysicalAttrsResult.fromMap(
      jsonDecode(r.body) as Map<String, dynamic>,
    );
  }

  /// `GET /physical-attributes-report/{id}` — re-open a stored physical-profile
  /// report by id (from a `[physical:<id>]` chat marker or the Skills-screen
  /// history). `current` returns the live record.
  Future<PhysicalReport> physicalReport(String id) async {
    final r = await _http.get(
      _uri(
        '/physical-attributes-report/'
        '${Uri.encodeComponent(id.isEmpty ? 'current' : id)}',
      ),
      headers: await _headers(),
    );
    if (r.statusCode != 200) {
      throw ApiException(
        'physical-attributes report failed.',
        statusCode: r.statusCode,
        body: r.body,
      );
    }
    return PhysicalReport.fromMap(jsonDecode(r.body) as Map<String, dynamic>);
  }

  // --- Appearance: one unified read of the user's photos ----------------

  /// `POST /appearance/report` — build the caller's unified Appearance report
  /// (structured attributes + an honest face and physique read) and persist it.
  /// [imagePaths] are chat uploads (each under `uploads/{you}/`) folded into the
  /// vision passes; [wantFace] / [wantBody] gate those sections (set from
  /// [appearanceCoverage]) — the run is never hard-blocked.
  /// [faceMediaIds] / [bodyMediaIds] — when non-null — name the exact grid
  /// photos the pre-run sheet chose for each axis (server-validated to the
  /// caller's own, eligible photos). `null` means "auto-pick the first
  /// eligible grid photo", the legacy behaviour.
  Future<AppearanceReportResult> runAppearanceReport({
    List<String> imagePaths = const [],
    bool wantFace = true,
    bool wantBody = true,
    List<String>? faceMediaIds,
    List<String>? bodyMediaIds,
  }) async {
    final r = await _http.post(
      _uri('/appearance/report'),
      headers: await _headers(),
      body: jsonEncode({
        'image_paths': imagePaths,
        'want_face': wantFace,
        'want_body': wantBody,
        if (faceMediaIds != null) 'face_media_ids': faceMediaIds,
        if (bodyMediaIds != null) 'body_media_ids': bodyMediaIds,
      }),
    );
    if (r.statusCode != 200) {
      throw ApiException(
        'appearance report failed.',
        statusCode: r.statusCode,
        body: r.body,
      );
    }
    final m = jsonDecode(r.body) as Map<String, dynamic>;
    return AppearanceReportResult(
      usageCapped: m['usage_capped'] == true,
      reportId: m['report_id'] as String? ?? '',
      report: m['report'] is Map
          ? AppearanceReport.fromMap(
              (m['report'] as Map).cast<String, dynamic>(),
            )
          : null,
    );
  }

  /// `POST /appearance/card/hidden` — set which of the caller's analysed
  /// photos are kept OFF the shareable Appearance report card, by stable id
  /// (Storage path). Card-only: it never deletes the photo or its analysis.
  /// The server validates each id is the caller's own and returns the stored
  /// list, which the card builder and the exported share image both honour.
  Future<List<String>> setReportCardHiddenPhotos(List<String> ids) async {
    final r = await _http.post(
      _uri('/appearance/card/hidden'),
      headers: await _headers(),
      body: jsonEncode({'hidden': ids}),
    );
    if (r.statusCode != 200) {
      throw ApiException(
        'saving hidden photos failed.',
        statusCode: r.statusCode,
        body: r.body,
      );
    }
    final m = jsonDecode(r.body) as Map<String, dynamic>;
    return ((m['hidden'] as List?)?.whereType<String>().toList()) ?? const [];
  }

  /// `GET /appearance/report/{id}` — re-open a stored Appearance report by id
  /// (from an `[appearance:<id>]` chat marker or the Skills-screen history).
  /// An empty id (or `current`) returns the latest run.
  Future<AppearanceReport> appearanceReport(String id) async {
    final r = await _http.get(
      _uri(
        '/appearance/report/'
        '${Uri.encodeComponent(id.isEmpty ? 'current' : id)}',
      ),
      headers: await _headers(),
    );
    if (r.statusCode != 200) {
      throw ApiException(
        'appearance report failed.',
        statusCode: r.statusCode,
        body: r.body,
      );
    }
    return AppearanceReport.fromMap(jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// `GET /appearance/history` — the caller's Appearance runs newest-first, with
  /// the pre-merge `face_reports` / `body_reports` / `physical_reports`
  /// collections folded in as read-only `legacy: true` rows.
  Future<List<AppearanceHistoryRow>> appearanceHistory() async {
    final r = await _http.get(
      _uri('/appearance/history'),
      headers: await _headers(),
    );
    if (r.statusCode != 200) {
      throw ApiException(
        'appearance history failed.',
        statusCode: r.statusCode,
        body: r.body,
      );
    }
    final m = jsonDecode(r.body) as Map<String, dynamic>;
    return (m['reports'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => AppearanceHistoryRow.fromMap(e.cast<String, dynamic>()))
        .where((s) => s.id.isNotEmpty)
        .toList();
  }

  /// `GET /appearance/coverage` — `{hasFacePhoto, hasBodyPhoto}` for the caller,
  /// derived from the shot-type tags on their current grid photos. Backs the
  /// Skills-screen coverage line; never hard-blocks a run.
  Future<AppearanceCoverage> appearanceCoverage() async {
    final r = await _http.get(
      _uri('/appearance/coverage'),
      headers: await _headers(),
    );
    if (r.statusCode != 200) {
      throw ApiException(
        'appearance coverage failed.',
        statusCode: r.statusCode,
        body: r.body,
      );
    }
    final m = jsonDecode(r.body) as Map<String, dynamic>;
    return AppearanceCoverage(
      hasFacePhoto: m['has_face_photo'] == true,
      hasBodyPhoto: m['has_body_photo'] == true,
      hasFittedBodyPhoto: m['has_fitted_body_photo'] == true,
    );
  }

  /// `GET /appearance/eligibility` — the caller's current grid photos grouped
  /// by which Appearance axis each is eligible for (face / body), with a
  /// thumbnail URL each. Backs the pre-run Face/Body photo groups; never
  /// hard-blocks a run.
  Future<AppearanceEligibility> appearanceEligibility() async {
    final r = await _http.get(
      _uri('/appearance/eligibility'),
      headers: await _headers(),
    );
    if (r.statusCode != 200) {
      throw ApiException(
        'appearance eligibility failed.',
        statusCode: r.statusCode,
        body: r.body,
      );
    }
    return AppearanceEligibility.fromMap(
      jsonDecode(r.body) as Map<String, dynamic>,
    );
  }

  // --- Profile completeness --------------------------------------------

  /// `GET /completeness` — the profile-completeness score, the user's stated
  /// relationship intent, a per-section breakdown, and the highest-value gaps
  /// to fill next. Ayma captures answers herself in conversation; the client
  /// only shows progress and routes the user into a chat on a topic.
  Future<Completeness> completeness() async =>
      Completeness.fromMap(await _getJson('/completeness'));

  /// `GET /referral` — the caller's referral code + shareable link (minted
  /// lazily server-side on first call).
  Future<({String code, String link})> referral() async {
    final m = await _getJson('/referral');
    return (code: m['code'] as String? ?? '', link: m['link'] as String? ?? '');
  }

  /// `POST /referral/redeem` — best-effort attribution at sign-up. Returns
  /// whether the code was newly applied; a bad/self/repeat code is a silent
  /// `false`, never an error the sign-up flow has to handle.
  Future<bool> redeemReferral(String code) async {
    final m = await _sendJson('POST', '/referral/redeem', {'code': code});
    return m['applied'] == true;
  }

  /// `GET /questionnaire` — the full question tree with per-node coverage
  /// status (`covered` / `partial` / `missing`) for the signed-in user.
  Future<QuestionnaireTree> questionnaireTree() async =>
      QuestionnaireTree.fromMap(await _getJson('/questionnaire'));

  /// `POST /wiki/promote` — pin an AI-only report page ([pageType] one of
  /// `face_analysis`, `body_analysis`, `web_findings`) into the user's public
  /// story. Best-effort; a no-op server-side until the endpoint ships.
  Future<void> promoteWikiPage(String pageType) =>
      _postJsonOk('/wiki/promote', {'page_type': pageType});

  /// `POST /dm/{threadId}/messages` — send a DM message (§6.6). For `image` /
  /// `file` messages [body] is an optional caption and the attachment metadata
  /// (already uploaded under `uploads/{uid}/dm/{threadId}/…`) rides along.
  Future<void> sendDmMessage(
    String threadId, {
    required String type,
    String body = '',
    String attachmentUrl = '',
    String attachmentPath = '',
    String mime = '',
    String fileName = '',
    int size = 0,
    String shareToken = '',
  }) => _postJsonOk('/dm/$threadId/messages', {
    'type': type,
    'body': body,
    if (shareToken.isNotEmpty) 'share_token': shareToken,
    if (attachmentUrl.isNotEmpty) 'attachment_url': attachmentUrl,
    if (attachmentPath.isNotEmpty) 'attachment_path': attachmentPath,
    if (mime.isNotEmpty) 'mime': mime,
    if (fileName.isNotEmpty) 'file_name': fileName,
    if (size > 0) 'size': size,
  });

  /// `POST /dm/assist` — live DM coaching (§6.9): up-to-4 suggestion chips that
  /// refresh as the conversation grows, plus an optional one-line nudge.
  /// [other] is the other participant's uid; [messages] is the recent thread
  /// tail (up to the last 12, oldest-first, each `{from: me|them, text}`) and
  /// may be empty for a brand-new thread (opener mode).
  Future<DmAssist> dmAssist({
    required String other,
    required List<Map<String, String>> messages,
  }) async {
    final decoded = await _sendJson('POST', '/dm/assist', {
      'other': other,
      'messages': messages,
    });
    return DmAssist.fromJson(decoded);
  }

  /// `POST /dm/translate` — cross-language DM translation (§6.12): translate
  /// [text] into [targetLang] (a language code or name), returning the
  /// translation plus the detected source language. [threadId] scopes the call
  /// to a thread the caller is a participant of (pair-only, like every /dm
  /// endpoint); [sourceLang] is an optional hint the model may override with
  /// its own detection. A nicety that never blocks the thread — the backend
  /// returns the original text on any model failure, so callers always get a
  /// usable [DmTranslation].
  Future<DmTranslation> dmTranslate({
    required String threadId,
    required String text,
    required String targetLang,
    String sourceLang = '',
  }) async {
    final decoded = await _sendJson('POST', '/dm/translate', {
      'thread_id': threadId,
      'text': text,
      'target_lang': targetLang,
      if (sourceLang.isNotEmpty) 'source_lang': sourceLang,
    });
    return DmTranslation.fromJson(decoded);
  }

  /// `POST /wiki/reset` — wipe what Ayma has learned (`wiki_pages` /
  /// `raw_turns` / `pending_questions`); account, profile and auth stay (§14.2).
  Future<void> resetWiki() => _postJsonOk('/wiki/reset', const {});

  /// `POST /voice/context` — mirror the screen the user is on, so the voice
  /// agent's `current_screen` tool can answer "what do you think of them?".
  /// Sent only while a voice session is live; an empty body clears it.
  Future<void> setVoiceContext(Map<String, dynamic> ctx) =>
      _postJsonOk('/voice/context', ctx);

  Future<void> clearVoiceContext() =>
      _postJsonOk('/voice/context', const {'screen': ''});

  // --- Your Story editor -------------------------------------------------

  Future<Map<String, dynamic>> _getJson(
    String path, [
    Map<String, String> query = const {},
    Duration? timeout,
  ]) async {
    final uri = _uri(path)
        .replace(queryParameters: query.isEmpty ? null : query);
    final r = await _get(uri, timeout: timeout);
    if (r.statusCode != 200) {
      throw ApiException(
        '$path failed.',
        statusCode: r.statusCode,
        body: r.body,
      );
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _sendJson(
    String method,
    String path,
    Map<String, dynamic> body, {
    Duration? timeout,
  }) async {
    final uri = _uri(path);
    final effectiveTimeout = timeout ?? interactiveTimeout;
    final r = switch (method.toUpperCase()) {
      'POST' => await _post(uri, body: jsonEncode(body), timeout: effectiveTimeout),
      'PUT' => await _put(uri, body: jsonEncode(body), timeout: effectiveTimeout),
      'DELETE' => await _delete(uri, body: jsonEncode(body), timeout: effectiveTimeout),
      _ => await _get(uri, timeout: effectiveTimeout),
    };
    if (r.statusCode != 200) {
      throw ApiException(
        '$path failed.',
        statusCode: r.statusCode,
        body: r.body,
      );
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// `GET /story` — the whole story document (one call): every visible section.
  /// The client renders the Public preview by filtering `visibility == 'public'`
  /// + stripping `{{private}}` spans; each section has its own version history.
  Future<StoryData> storyGet() async {
    final m = await _getJson('/story');
    return StoryData(
      sections: ((m['sections'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => StorySection.fromMap(e.cast<String, dynamic>()))
          .toList(),
    );
  }

  /// `GET /story/ai-notes` — every wiki page the user has, any visibility,
  /// each carrying its own real visibility (public/private/ai_only): a
  /// superset of "Everything" for Your Story's "AI notes" tab. Only the
  /// literal `ai_only` value is remapped to the client's `'ai'` pseudo-
  /// visibility (read-only, no menu); public/private pass through unchanged
  /// so those sections get full normal edit controls, same as elsewhere.
  Future<List<StorySection>> storyAiNotes() async {
    final m = await _getJson('/story/ai-notes');
    return ((m['sections'] as List?) ?? const []).whereType<Map>().map((e) {
      final raw = e.cast<String, dynamic>();
      final section = StorySection.fromMap(raw);
      return raw['visibility'] == 'ai_only'
          ? section.copyWith(visibility: 'ai')
          : section;
    }).toList();
  }

  /// `GET /profile/public-text` — the public profile as one plain text (each
  /// section under a `## Title` heading) for the manual editor.
  Future<ProfileTextDoc> profilePublicText() async {
    final m = await _getJson('/profile/public-text');
    return ProfileTextDoc(
      text: m['text'] as String? ?? '',
      version: m['version'] as String? ?? '',
      maxChars: (m['max_chars'] as num?)?.toInt() ?? 12000,
    );
  }

  /// `PUT /profile/public-text` — save a manual edit. Throws
  /// [ProfileTextRejected] with the server's user-facing reason when the text
  /// is refused (contact info, moderation, too long, changed meanwhile).
  Future<void> profilePublicTextSave({
    required String text,
    required String baseVersion,
  }) async {
    try {
      await _sendJson('PUT', '/profile/public-text', {
        'text': text,
        'base_version': baseVersion,
      });
    } on ApiException catch (e) {
      final code = e.statusCode;
      if (code == 409 || code == 422 || code == 503) {
        var message = "Couldn't save your profile text.";
        try {
          final detail = (jsonDecode(e.body ?? '') as Map)['detail'];
          if (detail is Map && detail['message'] is String) {
            message = detail['message'] as String;
          }
        } on FormatException {
          // Keep the generic message when the error body isn't JSON.
        }
        throw ProfileTextRejected(message, stale: code == 409);
      }
      rethrow;
    }
  }

  /// `PUT /profile/preferences` — save the partner age range and/or distance
  /// preference where matching reads them. Throws [ApiException] (422 with the
  /// reason in the body) for a value the server refuses.
  Future<void> profilePreferencesSave({
    int? partnerAgeMin,
    int? partnerAgeMax,
    String? distancePref,
  }) => _sendJson('PUT', '/profile/preferences', {
    if (partnerAgeMin != null) 'partner_age_min': partnerAgeMin,
    if (partnerAgeMax != null) 'partner_age_max': partnerAgeMax,
    if (distancePref != null && distancePref.isNotEmpty)
      'distance_pref': distancePref,
  });

  /// `GET /profile/proposals` — Ayma's pending updates to the PUBLIC profile,
  /// grouped by section, each an individual change (added or removed sentence)
  /// the user applies or dismisses on its own.
  Future<List<ProfileProposal>> profileProposals() async {
    final m = await _getJson('/profile/proposals');
    return ((m['proposals'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => ProfileProposal.fromMap(e.cast<String, dynamic>()))
        .toList();
  }

  /// Apply one change: show that added sentence on the public profile (or
  /// carry out that removal).
  Future<void> profileChangeApply(String pageId, String changeId) => _sendJson(
    'POST',
    '/profile/proposals/${Uri.encodeComponent(pageId)}'
        '/changes/${Uri.encodeComponent(changeId)}/apply',
    {},
  );

  /// Dismiss one change: keep it off the public profile but in the private
  /// profile and Ayma's notes.
  Future<void> profileChangeDismiss(String pageId, String changeId) =>
      _sendJson(
    'POST',
    '/profile/proposals/${Uri.encodeComponent(pageId)}'
        '/changes/${Uri.encodeComponent(changeId)}/dismiss',
    {},
  );

  /// Apply every remaining change in one section at once.
  Future<void> profileProposalApply(String pageId) => _sendJson(
    'POST',
    '/profile/proposals/${Uri.encodeComponent(pageId)}/apply',
    {},
  );

  /// Dismiss every remaining change in one section at once.
  Future<void> profileProposalDismiss(String pageId) => _sendJson(
    'POST',
    '/profile/proposals/${Uri.encodeComponent(pageId)}/dismiss',
    {},
  );

  /// `PUT /story/section` — persist an edited section body (as a `user_edits`
  /// override), optionally changing its visibility. Commits a version to the
  /// section's history; returns that version id.
  Future<String> storySaveSection({
    required String pageId,
    required String body,
    String? visibility,
  }) async {
    final m = await _sendJson('PUT', '/story/section', {
      'page_id': pageId,
      'body': body,
      if (visibility != null) 'visibility': visibility,
    });
    return m['head_version_id'] as String? ?? '';
  }

  /// `POST /story/section/visibility` — flip a whole section between `public`
  /// and `private`.
  Future<String> storySetVisibility({
    required String pageId,
    required String visibility,
  }) async {
    final m = await _sendJson('POST', '/story/section/visibility', {
      'page_id': pageId,
      'visibility': visibility,
    });
    return m['head_version_id'] as String? ?? '';
  }

  /// `POST /story/section/remove` — take a section out of the editor (Ayma
  /// keeps it; its pre-delete state stays in history for a revert).
  Future<void> storyRemoveSection(String pageId) =>
      _sendJson('POST', '/story/section/remove', {'page_id': pageId});

  /// `GET /story/section/{pageId}/versions` — that section's history, newest
  /// first.
  Future<List<StoryVersion>> storySectionVersions(String pageId) async {
    final r = await _http.get(
      _uri('/story/section/${Uri.encodeComponent(pageId)}/versions'),
      headers: await _headers(),
    );
    if (r.statusCode != 200) {
      throw ApiException(
        '/story section versions failed.',
        statusCode: r.statusCode,
        body: r.body,
      );
    }
    return (jsonDecode(r.body) as List)
        .whereType<Map>()
        .map((e) => StoryVersion.fromMap(e.cast<String, dynamic>()))
        .toList();
  }

  /// `GET /story/section/{pageId}/provenance` — "why Ayma believes this":
  /// conversations that fed the section + last-updated dates. Page-level
  /// only — no fabricated per-sentence confidence.
  Future<SectionProvenance> storyProvenance(String pageId) async {
    final m = await _getJson(
      '/story/section/${Uri.encodeComponent(pageId)}/provenance',
    );
    return SectionProvenance.fromMap(m);
  }

  /// `GET /story/career-timeline` — the structured career/education timeline,
  /// built lazily server-side on first read then cached. `showTimeline` is
  /// only true once Ayma has decent confidence in every entry.
  Future<CareerTimeline> careerTimeline() async {
    final m = await _getJson('/story/career-timeline');
    return CareerTimeline.fromMap(m);
  }

  /// `POST /story/career-timeline/refresh` — force a fresh extraction pass,
  /// e.g. right after the user adds their LinkedIn URL.
  Future<CareerTimeline> refreshCareerTimeline() async {
    final m = await _sendJson('POST', '/story/career-timeline/refresh', {});
    return CareerTimeline.fromMap(m);
  }

  /// `POST /story/linkedin` — save the user's own LinkedIn profile URL (their
  /// consent). Throws [ApiException] (400) if it isn't a linkedin.com link.
  Future<String> setLinkedinUrl(String url) async {
    final m = await _sendJson('POST', '/story/linkedin', {'url': url});
    return m['linkedin_url'] as String? ?? url;
  }

  /// `GET /usage` — lifetime Gemini-token usage + the derived credit balance.
  /// With [period] (`since_credit`, `7d`, `30d` or `all`) the response also
  /// carries [UsageSummary.periodUsage]: credits spent per feature in that
  /// window, aggregated on the server.
  Future<UsageSummary> usage({String? period}) async {
    final uri = period == null
        ? _uri('/usage')
        : _uri('/usage').replace(queryParameters: {'period': period});
    final r = await _http.get(uri, headers: await _headers());
    if (r.statusCode != 200) {
      throw ApiException(
        'usage failed.',
        statusCode: r.statusCode,
        body: r.body,
      );
    }
    return _usageFrom(jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// `POST /credits/topup` — reload the credit balance (free; the server only
  /// allows it for the dev view or while its free-top-up flag is on). Returns
  /// the refreshed usage view; throws [UpgradeRequiredException] on a 402.
  Future<UsageSummary> topUpCredits() async {
    final r = await _http.post(
      _uri('/credits/topup'),
      headers: await _headers(),
    );
    if (r.statusCode == 402) {
      throw UpgradeRequiredException(_upgradeMessage(r.body));
    }
    if (r.statusCode != 200) {
      throw ApiException(
        'top-up failed.',
        statusCode: r.statusCode,
        body: r.body,
      );
    }
    return _usageFrom(jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// `POST /billing/sync` — grant/refresh the monthly plan credits from the
  /// user's current RevenueCat entitlement. This is the sandbox/Test-Store
  /// path (a Test Store purchase never sends the server webhook) and a
  /// production resilience fallback beside the webhook. [productId],
  /// [expiresAtMs] and [isTrial] are the app-reported active entitlement, used
  /// only by the server's dev-view fallback when it has no RevenueCat REST
  /// key; pass nulls when there is no active entitlement. Idempotent
  /// server-side. Returns the refreshed usage view.
  Future<UsageSummary> syncBilling({
    String? productId,
    int? expiresAtMs,
    bool isTrial = false,
  }) async {
    final r = await _http.post(
      _uri('/billing/sync'),
      headers: await _headers(),
      body: jsonEncode({
        'product_id': productId,
        'expires_at_ms': expiresAtMs,
        'is_trial': isTrial,
      }),
    );
    if (r.statusCode != 200) {
      throw ApiException(
        'billing sync failed.',
        statusCode: r.statusCode,
        body: r.body,
      );
    }
    return _usageFrom(jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// `POST /dev/test-upgrade` — DEV/TEST ONLY. Grant the chosen paid tier's
  /// monthly credit pool to the caller WITHOUT a real purchase, exercising the
  /// same server-side grant path a real entitlement uses (so it's a faithful
  /// test of "credits per plan" in a build where RevenueCat is off). The server
  /// gates it on its dev-view allowlist — a non-dev caller gets 403. [plan] is
  /// `plus`, `pro` or `max`. Returns the refreshed usage view.
  Future<UsageSummary> testUpgrade(String plan) async {
    final r = await _http.post(
      _uri('/dev/test-upgrade'),
      headers: await _headers(),
      body: jsonEncode({'plan': plan}),
    );
    if (r.statusCode != 200) {
      throw ApiException(
        'test upgrade failed.',
        statusCode: r.statusCode,
        body: r.body,
      );
    }
    return _usageFrom(jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// `POST /usage/reset-real-money` — zero the Real money tab's "since last
  /// reset" tracker. A marker, not a wipe: the all-time dollar figure and the
  /// per-conversation history keep counting. Returns the refreshed usage view.
  Future<UsageSummary> resetRealMoney() async {
    final r = await _http.post(
      _uri('/usage/reset-real-money'),
      headers: await _headers(),
    );
    if (r.statusCode != 200) {
      throw ApiException(
        'money-tracker reset failed.',
        statusCode: r.statusCode,
        body: r.body,
      );
    }
    return _usageFrom(jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// `POST /dev/verify` — verify the developer password to unlock the
  /// Developer panel's contents. The server checks [password] against its own
  /// secret; throws [ApiException] with status 403 (wrong password), 429
  /// (locked out) or 503 (not configured).
  Future<void> verifyDevPassword(String password) async {
    await _sendJson('POST', '/dev/verify', {'password': password});
  }

  /// `GET /voice/agent-cloud` — which cloud serves this user's voice agent
  /// (`cloudrun` | `livekit`). Dev-only control; `cloudrun` is the default and
  /// all of production.
  Future<String> voiceAgentCloud() async {
    final m = await _getJson('/voice/agent-cloud');
    return (m['current'] as String?) ?? 'cloudrun';
  }

  /// `POST /voice/agent-cloud` — persist which cloud serves the next voice
  /// call. Returns the saved value.
  Future<String> setVoiceAgentCloud(String cloud) async {
    final m = await _sendJson('POST', '/voice/agent-cloud', {'cloud': cloud});
    return (m['current'] as String?) ?? cloud;
  }

  static String _upgradeMessage(String body) {
    try {
      final d = (jsonDecode(body) as Map)['detail'];
      final m = d is Map ? d['message'] : null;
      if (m is String && m.isNotEmpty) return m;
    } catch (_) {
      // Fall through to the generic copy.
    }
    return 'Upgrade your plan to keep going.';
  }

  UsageSummary _usageFrom(Map<String, dynamic> m) => UsageSummary.fromMap(m);

  /// `POST /check-compatibility` — the on-demand pairwise match-score check
  /// (§5.3). Token-intensive: the client shows its credit cost on the button.
  Future<MatchScoreResult> checkCompatibility(
    String otherUid, {
    bool force = false,
  }) async {
    final r = await _http.post(
      _uri('/check-compatibility'),
      headers: await _headers(),
      body: jsonEncode({'other_uid': otherUid, 'force': force}),
    );
    if (r.statusCode != 200) {
      throw ApiException(
        'compatibility check failed.',
        statusCode: r.statusCode,
        body: r.body,
      );
    }
    final m = jsonDecode(r.body) as Map<String, dynamic>;
    return MatchScoreResult(
      ok: m['ok'] == true,
      usageCapped: m['usage_capped'] == true,
      queued: m['queued'] == true,
      score: (m['score'] as num?)?.toDouble(),
      matchId: m['match_id'] as String?,
    );
  }

  /// `GET /match/{id}` — the stored, shareable match report (score, what lines
  /// up / what doesn't, the note written to you, both photos). 404 → null.
  Future<MatchReport?> matchReport(String matchId) async {
    final r = await _http.get(
      _uri('/match/${Uri.encodeComponent(matchId)}'),
      headers: await _headers(),
    );
    if (r.statusCode == 404) return null;
    if (r.statusCode != 200) {
      throw ApiException(
        'match report failed.',
        statusCode: r.statusCode,
        body: r.body,
      );
    }
    return MatchReport.fromMap(jsonDecode(r.body) as Map<String, dynamic>);
  }

  // --- Practice Date (hackathon deliverable B) ----------------------------- //

  /// `POST /practice/start` — open a practice simulator against [otherUid]'s
  /// viewer-visible profile. 404 → null (no simulatable profile).
  Future<PracticeStart?> practiceStart(String otherUid) async {
    final r = await _http.post(
      _uri('/practice/start'),
      headers: await _headers(),
      body: jsonEncode({'other_uid': otherUid}),
    );
    if (r.statusCode == 404) return null;
    if (r.statusCode != 200) {
      throw ApiException('Could not start practice.',
          statusCode: r.statusCode, body: r.body);
    }
    return PracticeStart.fromMap(jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// `POST /practice/chat` — one practice turn: the simulated match's reply and
  /// an optional live coach nudge. HTTP 402 surfaces as `usageCapped`.
  Future<PracticeTurn> practiceChat(String sessionId, String message) async {
    final r = await _http.post(
      _uri('/practice/chat'),
      headers: await _headers(),
      body: jsonEncode({'session_id': sessionId, 'message': message}),
    );
    if (r.statusCode == 402) return const PracticeTurn(usageCapped: true);
    if (r.statusCode != 200) {
      throw ApiException('Practice reply failed.',
          statusCode: r.statusCode, body: r.body);
    }
    return PracticeTurn.fromMap(jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// `POST /practice/voice/start` — open a practice VOICE session against
  /// [otherUid]'s viewer-visible profile (hackathon B). Returns the practice
  /// session id, persona, banner and LiveKit credentials for the existing voice
  /// pipeline. 404 → null (no simulatable profile); a body with
  /// `usage_capped:true` surfaces as [PracticeVoiceSession.usageCapped].
  Future<PracticeVoiceSession?> practiceVoiceStart(String otherUid) async {
    final r = await _http.post(
      _uri('/practice/voice/start'),
      headers: await _headers(),
      body: jsonEncode({'other_uid': otherUid}),
    );
    if (r.statusCode == 404) return null;
    if (r.statusCode != 200) {
      throw ApiException('Could not start voice practice.',
          statusCode: r.statusCode, body: r.body);
    }
    return PracticeVoiceSession.fromMap(
        jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// `POST /practice/debrief` — end the session and return the coaching
  /// debrief (what worked / suggested next lines / what to avoid).
  Future<PracticeDebrief> practiceDebrief(String sessionId) async {
    final r = await _http.post(
      _uri('/practice/debrief'),
      headers: await _headers(),
      body: jsonEncode({'session_id': sessionId}),
    );
    if (r.statusCode != 200) {
      throw ApiException('Debrief failed.',
          statusCode: r.statusCode, body: r.body);
    }
    return PracticeDebrief.fromMap(jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// `POST /date-sim` — run an AI date simulation against [otherUid] under the
  /// client-chosen [simId]. The transcript streams into Firestore as it is
  /// generated (read it with `DateSimService`), so the response body is not
  /// used; this future completes when the run ends. Throws [ApiException]:
  /// 402 out of credits, 403 AI-Avatar opt-out (message from the server),
  /// 404 no simulatable profile.
  Future<void> dateSim(String simId, String otherUid, int maxMessages) async {
    final r = await _http.post(
      _uri('/date-sim'),
      headers: await _headers(),
      body: jsonEncode({
        'other_uid': otherUid,
        'max_messages': maxMessages,
        'sim_id': simId,
      }),
    );
    if (r.statusCode == 200) return;
    throw ApiException(
      r.statusCode == 403
          ? _dateSimOptOutMessage(r.body)
          : 'Date simulation failed.',
      statusCode: r.statusCode,
      body: r.body,
    );
  }

  /// `POST /date-sim/{simId}/continue` — continue an existing simulation with
  /// [moreMessages] more turns, resuming from where it left off (never a
  /// restart) and re-scoring over the full transcript. The new turns stream
  /// into the same Firestore doc the client is already watching, so the body is
  /// not used; this future completes when the continuation ends. Throws
  /// [ApiException]: 402 out of credits, 403 AI-Avatar opt-out, 404 no sim.
  Future<void> dateSimContinue(String simId, int moreMessages) async {
    final r = await _http.post(
      _uri('/date-sim/$simId/continue'),
      headers: await _headers(),
      body: jsonEncode({'more_messages': moreMessages}),
    );
    if (r.statusCode == 200) return;
    throw ApiException(
      r.statusCode == 403
          ? _dateSimOptOutMessage(r.body)
          : 'Continuing the simulation failed.',
      statusCode: r.statusCode,
      body: r.body,
    );
  }

  /// `POST /date-sim/{simId}/stop` — STOP an in-flight simulation. The backend
  /// flags the run; the server-side generator halts between turns and keeps
  /// what's already produced — WITHOUT scoring it and WITHOUT sending the
  /// completion notification — then flips the Firestore doc to `done` (the
  /// client is already watching it). Returns the server's outcome:
  /// `'stopping'` when the flag was set on a live run, `'already_finished'`
  /// when the run had already ended (its score, if any, was already final, so
  /// the caller must not pretend the stop worked). Throws [ApiException] on
  /// failure (404 no such sim).
  Future<String> dateSimStop(String simId) async {
    final r = await _http.post(
      _uri('/date-sim/$simId/stop'),
      headers: await _headers(),
    );
    if (r.statusCode == 200) {
      try {
        final status = (jsonDecode(r.body) as Map<String, dynamic>)['status'];
        if (status is String && status.isNotEmpty) return status;
      } catch (_) {
        // An unreadable body still means the stop was accepted.
      }
      return 'stopping';
    }
    throw ApiException(
      'Stopping the simulation failed.',
      statusCode: r.statusCode,
      body: r.body,
    );
  }

  /// `DELETE /date-sim/pair/{otherUid}` — RESET the pair: discard every stored
  /// simulation (transcript + report) between the user and [otherUid] so a new
  /// sim starts from scratch. Throws [ApiException] on failure.
  Future<void> dateSimReset(String otherUid) async {
    final r = await _http.delete(
      _uri('/date-sim/pair/$otherUid'),
      headers: await _headers(),
    );
    if (r.statusCode == 200) return;
    throw ApiException(
      'Resetting the simulation failed.',
      statusCode: r.statusCode,
      body: r.body,
    );
  }

  /// The AI-Avatar opt-out message from a 403 `/date-sim` body
  /// (`{"detail": {"code", "message"}}`).
  static String _dateSimOptOutMessage(String body) {
    try {
      final detail = (jsonDecode(body) as Map<String, dynamic>)['detail'];
      final message = detail is Map ? detail['message'] : null;
      if (message is String && message.isNotEmpty) return message;
    } catch (_) {}
    return 'Date simulation isn’t available for this profile.';
  }

  /// `POST /taste/pair` — the taste overlap between the user and
  /// [otherUid], shown on the date-sim result. Throws [NoTasteException] when
  /// either person has no public Taste page (404 `no_taste`), else
  /// [ApiException] on any other failure.
  Future<TasteMatch> tastePair(String otherUid) async {
    final r = await _http.post(
      _uri('/taste/pair'),
      headers: await _headers(),
      body: jsonEncode({'other_uid': otherUid}),
    );
    if (r.statusCode == 404) {
      final detail = _errorDetail(r.body);
      if (detail?['code'] == 'no_taste') {
        final message = detail?['message'];
        throw NoTasteException(message is String && message.isNotEmpty
            ? message
            : 'Add a public "Taste" page (e.g. "Music: ...") to see your '
                'taste match.');
      }
    }
    if (r.statusCode != 200) {
      throw ApiException('Taste match failed.',
          statusCode: r.statusCode, body: r.body);
    }
    return TasteMatch.fromMap(jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// The `detail` object of a FastAPI error body, or null when absent.
  static Map<String, dynamic>? _errorDetail(String body) {
    try {
      final detail = (jsonDecode(body) as Map<String, dynamic>)['detail'];
      return detail is Map<String, dynamic> ? detail : null;
    } catch (_) {
      return null;
    }
  }

  /// `GET /date-sim/estimate` — approximate credits per message count (both
  /// agents are billed to the user). When [otherUid] is given, also carries the
  /// match's avatar `readiness` block so the setup screen can warn when the
  /// match has little context. Empty credits when unavailable.
  Future<DateSimEstimate> dateSimEstimate({String? otherUid}) async {
    final uri = (otherUid != null && otherUid.isNotEmpty)
        ? _uri('/date-sim/estimate')
            .replace(queryParameters: {'other_uid': otherUid})
        : _uri('/date-sim/estimate');
    final r = await _http.get(uri, headers: await _headers());
    if (r.statusCode != 200) return const DateSimEstimate();
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    final raw =
        (body['credits_by_messages'] as Map<String, dynamic>?) ?? const {};
    final readiness = body['readiness'] as Map<String, dynamic>?;
    return DateSimEstimate(
      credits: {
        for (final e in raw.entries) int.parse(e.key): (e.value as num).toInt(),
      },
      readiness:
          readiness == null ? null : DateSimReadiness.fromMap(readiness),
    );
  }

  /// `POST /profiles/mini` — name + resolved photo URL for a batch of users
  /// (message-list rows, match cards). `{uid: MiniProfile}`. Chunked at the
  /// server's 100-uid cap so long conversation lists never 422 (Phase 2
  /// pagination design §2.2).
  Future<Map<String, MiniProfile>> miniProfiles(List<String> uids) async {
    if (uids.isEmpty) return const {};
    final out = <String, MiniProfile>{};
    for (var i = 0; i < uids.length; i += 100) {
      final end = i + 100 > uids.length ? uids.length : i + 100;
      out.addAll(await _miniProfilesChunk(uids.sublist(i, end)));
    }
    return out;
  }

  Future<Map<String, MiniProfile>> _miniProfilesChunk(
      List<String> uids) async {
    final r = await _http.post(
      _uri('/profiles/mini'),
      headers: await _headers(),
      body: jsonEncode({'uids': uids}),
    );
    if (r.statusCode != 200) {
      throw ApiException(
        'mini profiles failed.',
        statusCode: r.statusCode,
        body: r.body,
      );
    }
    final m =
        (jsonDecode(r.body) as Map<String, dynamic>)['profiles']
            as Map<String, dynamic>? ??
        const {};
    return m.map((k, v) {
      final e = (v as Map).cast<String, dynamic>();
      return MapEntry(
        k,
        MiniProfile(
          name: e['name'] as String? ?? '',
          photo: e['photo'] as String? ?? '',
          online: e['online'] == true,
        ),
      );
    });
  }

  /// `GET /wiki/ai-view` — the compiled wiki context Ayma reads about the
  /// caller, verbatim, plus every photo Ayma holds of them (debug).
  Future<AiNotes> aiNotes() async {
    final r = await _http.get(_uri('/wiki/ai-view'), headers: await _headers());
    if (r.statusCode != 200) {
      throw ApiException(
        'ai notes failed.',
        statusCode: r.statusCode,
        body: r.body,
      );
    }
    final m = jsonDecode(r.body) as Map<String, dynamic>;
    return AiNotes(
      text: m['text'] as String? ?? '',
      photos: (m['photos'] as List? ?? const [])
          .whereType<Map>()
          .map(
            (e) => AiNotePhoto(
              id: e['id'] as String? ?? '',
              url: e['url'] as String? ?? '',
              source: e['source'] as String? ?? '',
              context: e['context'] as String? ?? '',
              isUser: e['is_user'] as String? ?? '',
              sourcePage: e['source_page'] as String? ?? '',
              deleted: e['deleted'] as bool? ?? false,
            ),
          )
          .where((p) => p.url.isNotEmpty)
          .toList(),
    );
  }

  /// `POST /wiki/photo-hide` — the gallery's "Delete": takes the photo out of
  /// view (and off the public grid, if it was a profile photo). Ayma keeps
  /// the underlying record. Enforces the interactive timeout budget (≤8s).
  Future<void> photoHide(String url, {required String source}) async {
    final r = await _post(
      _uri('/wiki/photo-hide'),
      body: jsonEncode({'url': url, 'source': source}),
      timeout: interactiveTimeout,
    );
    if (r.statusCode != 200) {
      throw ApiException(
        'Could not remove that photo.',
        statusCode: r.statusCode,
        body: r.body,
      );
    }
  }

  /// `POST /wiki/photo-publish` — "Make public": promotes a chat or web photo
  /// onto the public profile grid, through the same moderation every profile
  /// upload goes through. Throws with the reason if it doesn't clear
  /// moderation. This runs moderation + a face-embed + captioning pass
  /// server-side (several sequential model calls), so it's given the extended
  /// [longTimeout] budget.
  Future<void> photoPublish(String url, {required String source}) async {
    final r = await _post(
      _uri('/wiki/photo-publish'),
      body: jsonEncode({'url': url, 'source': source}),
      timeout: longTimeout,
    );
    if (r.statusCode != 200) {
      throw ApiException(
        'Could not publish that photo.',
        statusCode: r.statusCode,
        body: r.body,
      );
    }
    final m = jsonDecode(r.body) as Map<String, dynamic>;
    if (m['published'] != true) {
      throw ApiException(
        (m['reason'] as String?) ?? "That photo didn't clear moderation.",
      );
    }
  }

  /// `GET /voice/presets` — the selectable Gemini Live voice presets plus the
  /// user's current choice (§13.3).
  Future<VoicePresets> voicePresets() async {
    final r = await _http.get(
      _uri('/voice/presets'),
      headers: await _headers(),
    );
    if (r.statusCode != 200) {
      throw ApiException(
        'voice presets failed.',
        statusCode: r.statusCode,
        body: r.body,
      );
    }
    final m = jsonDecode(r.body) as Map<String, dynamic>;
    return VoicePresets(
      presets: ((m['presets'] as List?) ?? [])
          .map(
            (e) => VoicePreset(
              name: (e as Map)['name'] as String? ?? '',
              description: e['description'] as String? ?? '',
            ),
          )
          .toList(),
      current: m['current'] as String? ?? '',
      defaultName: m['default'] as String? ?? '',
      currentLanguage: m['current_language'] as String? ?? '',
      languageExamples: ((m['language_examples'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList(),
    );
  }

  /// `GET /voice/preview/{name}` — a download URL for a short spoken sample in
  /// that voice preset ("Hi, I'm Ayma…"), so the picker can play it before the
  /// user commits (§13.3). Cached server-side after the first request.
  Future<String> voicePreviewUrl(String voiceName) async {
    final r = await _http.get(
      _uri('/voice/preview/${Uri.encodeComponent(voiceName)}'),
      headers: await _headers(),
    );
    if (r.statusCode != 200) {
      throw ApiException(
        'voice preview failed.',
        statusCode: r.statusCode,
        body: r.body,
      );
    }
    return (jsonDecode(r.body) as Map<String, dynamic>)['url'] as String? ?? '';
  }

  /// `GET /voice/engines` — the selectable voice STACK (§13.9): modes, realtime
  /// models, and cascade brains/STT/TTS (sourced live from LiveKit Inference,
  /// config fallback otherwise), plus the user's current selection.
  Future<VoiceCatalog> voiceEngines({Duration? timeout}) async {
    // The models page raises [timeout] past the 8s interactive budget so the
    // initial load and the on-brain-switch re-fetch can ride through a
    // scale-to-zero cold start instead of 408-ing (VoiceEngineControl._load
    // wraps it in a cold-start retry on top).
    final m = await _getJson('/voice/engines', const {}, timeout);
    return VoiceCatalog.fromMap(m);
  }

  /// `POST /voice/preference` — persist the user's voice stack (§13.9). Takes
  /// effect on the next voice call.
  Future<void> saveVoicePreference(VoiceSelection sel) =>
      _postJsonOk('/voice/preference', sel.toMap());

  /// `POST /voice/async` — submit one async voice message (Chunk A). The clip
  /// must already be uploaded to `uploads/{uid}/…` ([storagePath]); the cloud
  /// transcribes + thinks + speaks the reply and the client watches the job
  /// doc for it. Idempotent per [jobId]: a retry of a finished job is
  /// answered from the stored outcome, a retry of a running one joins it.
  Future<VoiceAsyncSubmit> submitVoiceMessage({
    required String jobId,
    required String storagePath,
    String sessionId = '',
    List<Map<String, String>> recentTurns = const [],
  }) async {
    final r = await _post(
      _uri('/voice/async'),
      body: jsonEncode({
        'job_id': jobId,
        'storage_path': storagePath,
        'session_id': sessionId,
        'recent_turns': clampRecentTurns(recentTurns),
      }),
    );
    if (r.statusCode != 200) {
      throw ApiException(
        'Voice message submit failed.',
        statusCode: r.statusCode,
        body: r.body,
      );
    }
    return VoiceAsyncSubmit.fromMap(jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// `GET /brain/preference` — the unified **Brain** catalog + the user's
  /// current choice (§13.10): the ONE LLM that drives every text surface, with
  /// web/vision always on Gemini.
  Future<BrainCatalog> brainPreference({Duration? timeout}) async {
    // The models page raises [timeout] past the 8s interactive budget so the
    // initial brain load can ride through a scale-to-zero cold start instead of
    // 408-ing (BrainSelectorControl._load wraps it in a cold-start retry).
    final m = await _getJson('/brain/preference', const {}, timeout);
    return BrainCatalog.fromMap(m);
  }

  /// `POST /brain/preference` — persist the user's unified Brain (§13.10). Takes
  /// effect on the next text turn.
  Future<void> saveBrainPreference(String brain) =>
      _postJsonOk('/brain/preference', {'brain': brain});

  /// `GET /image-model/preference` — the image-generation model catalog + the
  /// user's current choice. Image generation is the ONE founder-authorized
  /// direct-provider path; only configured providers are listed (Gemini-direct
  /// is the default). [timeout] is raised on the models page so the load rides
  /// through a scale-to-zero cold start.
  Future<ImageModelCatalog> imageModelPreference({Duration? timeout}) async {
    final m = await _getJson('/image-model/preference', const {}, timeout);
    return ImageModelCatalog.fromMap(m);
  }

  /// `POST /image-model/preference` — persist the user's image-generation
  /// model. Takes effect on the next image generation.
  Future<void> saveImageModelPreference(String imageModel) =>
      _postJsonOk('/image-model/preference', {'image_model': imageModel});

  /// `POST /models/preference` — the Models screen's ONE save (founder,
  /// 2026-11-06): persist the single Brain AND the whole voice stack in one
  /// action. [reconnect] is true when a voice call is active (the button
  /// said "Save and reconnect"): the server marks the one-shot reconnect
  /// announcement, and the caller then reconnects the live session so the
  /// new stack serves this call.
  Future<void> saveModelsPreference({
    required String brain,
    required VoiceSelection selection,
    String imageModel = '',
    bool reconnect = false,
  }) =>
      _postJsonOk('/models/preference', {
        'brain': brain,
        // Optional: omitted ('') leaves the saved image model untouched.
        'image_model': imageModel,
        'mode': selection.mode,
        'realtime_model_id': selection.realtimeModelId,
        'stt_id': selection.sttId,
        'tts_id': selection.ttsId,
        'voice_id': selection.voiceId,
        'language_code': selection.languageCode,
        'accent': selection.accent,
        'reconnect': reconnect,
      });

  /// `GET /media/photos` — the current profile-photo grid (§8.3). Returns the
  /// list of `{media_id, order}` maps, order ascending.
  Future<List<Map<String, dynamic>>> listPhotos() async {
    final r = await _http.get(_uri('/media/photos'), headers: await _headers());
    if (r.statusCode != 200) {
      throw ApiException(
        'list photos failed.',
        statusCode: r.statusCode,
        body: r.body,
      );
    }
    return ((jsonDecode(r.body) as Map<String, dynamic>)['photos'] as List? ??
            [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();
  }

  /// `POST /media/photos/batch` — add several already-processed photos to the
  /// grid in ONE call: the photo-add flow to use whenever more than one photo
  /// is picked in a single user action (onboarding's photo step, "add more
  /// photos"), instead of looping [addPhoto] once per photo. The whole added
  /// set is analysed together as one update to the caller's single persistent
  /// Appearance report, instead of N separate per-photo runs (§ appearance
  /// batching). [mediaIds] must be non-empty (server caps at 9 per call).
  Future<PhotoBatchResult> addPhotosBatch(List<String> mediaIds) async {
    final r = await _http.post(
      _uri('/media/photos/batch'),
      headers: await _headers(),
      body: jsonEncode({'media_ids': mediaIds}),
    );
    if (r.statusCode != 200) {
      throw ApiException(
        'batch photo add failed.',
        statusCode: r.statusCode,
        body: r.body,
      );
    }
    final m = jsonDecode(r.body) as Map<String, dynamic>;
    return PhotoBatchResult(
      photos: ((m['photos'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList(),
      added: ((m['added'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList(),
      failed: ((m['failed'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList(),
    );
  }

  /// `POST /media/photos/{id}/remove` — remove from the PUBLIC profile. The
  /// photo moves to the hidden list: it leaves every public view but stays in
  /// Ayma's analysis pool, and its `user_media` doc, Storage file and
  /// embedding are untouched (§8.3). Reversible by re-adding.
  Future<void> removePhoto(String mediaId) =>
      _postJsonOk('/media/photos/$mediaId/remove', const {});

  /// `POST /media/photos/{id}/primary` — make this photo the primary (hero)
  /// public photo (§8.3).
  Future<void> setPrimaryPhoto(String mediaId) =>
      _postJsonOk('/media/photos/$mediaId/primary', const {});

  /// `POST /media/photos/{id}/delete` — delete EVERYWHERE: drop it from the
  /// public grid and the hidden list, then erase the `user_media` doc and its
  /// Storage blob so the analysis goes too (§8.3). Not reversible.
  Future<void> deletePhotoPermanent(String mediaId) =>
      _postJsonOk('/media/photos/$mediaId/delete', const {});

  /// `PUT /media/photos/order` — `mediaIds[0]` becomes the primary photo.
  Future<void> reorderPhotos(List<String> mediaIds) async {
    final r = await _http.put(
      _uri('/media/photos/order'),
      headers: await _headers(),
      body: jsonEncode({'media_ids': mediaIds}),
    );
    if (r.statusCode != 200) {
      throw ApiException(
        'reorder photos failed.',
        statusCode: r.statusCode,
        body: r.body,
      );
    }
  }

  /// `GET /instagram/auth-url` — the URL the client opens to authorise
  /// Instagram access (§8.1).
  Future<String> instagramAuthUrl() async {
    final r = await _http.get(
      _uri('/instagram/auth-url'),
      headers: await _headers(),
    );
    if (r.statusCode != 200) {
      throw ApiException(
        'instagram auth-url failed.',
        statusCode: r.statusCode,
        body: r.body,
      );
    }
    return (jsonDecode(r.body) as Map<String, dynamic>)['url'] as String? ?? '';
  }

  /// `POST /instagram/connect` — exchange the OAuth `code`, import recent
  /// photos + captions (§8.2). Returns the number imported.
  Future<int> instagramConnect(String code) async {
    final r = await _http.post(
      _uri('/instagram/connect'),
      headers: await _headers(),
      body: jsonEncode({'code': code}),
    );
    if (r.statusCode != 200) {
      throw ApiException(
        'instagram connect failed.',
        statusCode: r.statusCode,
        body: r.body,
      );
    }
    return (jsonDecode(r.body) as Map<String, dynamic>)['imported'] as int? ??
        0;
  }

  /// `POST /instagram/disconnect` — forget the token; imported photos stay.
  Future<void> instagramDisconnect() =>
      _postJsonOk('/instagram/disconnect', {});

  /// `GET /instagram/signin-auth-url` — "Sign in with Instagram" (new): the
  /// URL to authorise, reachable before any Firebase auth exists — no
  /// `Authorization` header, unlike every other call in this client.
  Future<String> instagramSigninAuthUrl() async {
    final r = await _http.get(_uri('/instagram/signin-auth-url'));
    if (r.statusCode != 200) {
      throw ApiException(
        'instagram signin-auth-url failed.',
        statusCode: r.statusCode,
        body: r.body,
      );
    }
    return (jsonDecode(r.body) as Map<String, dynamic>)['url'] as String? ?? '';
  }

  /// `POST /instagram/signin` — exchange the OAuth `code` for a Firebase
  /// custom token (`FirebaseAuth.instance.signInWithCustomToken`). Also no
  /// `Authorization` header — there is no signed-in user yet.
  Future<InstagramSigninResult> instagramSignin(String code) async {
    final r = await _http.post(
      _uri('/instagram/signin'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'code': code}),
    );
    if (r.statusCode != 200) {
      throw ApiException(
        'instagram signin failed.',
        statusCode: r.statusCode,
        body: r.body,
      );
    }
    final m = jsonDecode(r.body) as Map<String, dynamic>;
    return InstagramSigninResult(
      customToken: m['customToken'] as String? ?? '',
      isNewUser: m['isNewUser'] as bool? ?? false,
    );
  }

  /// `GET /google/auth-url` — the URL the client opens to authorise Google
  /// account import (Gmail + Calendar, read-only).
  Future<String> googleAuthUrl() async {
    final r = await _http.get(
      _uri('/google/auth-url'),
      headers: await _headers(),
    );
    if (r.statusCode != 200) {
      throw ApiException(
        'google auth-url failed.',
        statusCode: r.statusCode,
        body: r.body,
      );
    }
    return (jsonDecode(r.body) as Map<String, dynamic>)['url'] as String? ?? '';
  }

  /// `POST /google/connect` — exchange the OAuth `code`. The actual
  /// Gmail/Calendar sync runs afterwards in the background; this just
  /// confirms the account linked. Returns the connected Google email.
  Future<String> googleConnect(String code) async {
    final r = await _http.post(
      _uri('/google/connect'),
      headers: await _headers(),
      body: jsonEncode({'code': code}),
    );
    if (r.statusCode != 200) {
      throw ApiException(
        'google connect failed.',
        statusCode: r.statusCode,
        body: r.body,
      );
    }
    return (jsonDecode(r.body) as Map<String, dynamic>)['email'] as String? ??
        '';
  }

  /// `POST /google/disconnect` — revoke the token with Google and forget it.
  Future<void> googleDisconnect() => _postJsonOk('/google/disconnect', {});

  /// `GET /google/status` — whether a Google account is currently connected.
  Future<GoogleAccountStatus> googleStatus() async {
    final r = await _http.get(
      _uri('/google/status'),
      headers: await _headers(),
    );
    if (r.statusCode != 200) {
      throw ApiException(
        'google status failed.',
        statusCode: r.statusCode,
        body: r.body,
      );
    }
    final m = jsonDecode(r.body) as Map<String, dynamic>;
    return GoogleAccountStatus(
      connected: m['connected'] as bool? ?? false,
      email: m['email'] as String? ?? '',
    );
  }

  /// `POST /feedback` — one-tap / typed feedback about Ayma's conduct in the
  /// conversation (§15). `quote` is the Ayma message being thumbed-down.
  Future<void> submitFeedback({
    String category = 'thumbs_down',
    String quote = '',
    String note = '',
    String sessionId = '',
  }) => _postJsonOk('/feedback', {
    'category': category,
    'quote': quote,
    'note': note,
    'session_id': sessionId,
  });

  /// `POST /feedback/submit` — file a reviewed product-feedback card into the
  /// unified `feedback` collection (§15). Used by the in-chat feedback catcher
  /// (`source: 'chat_card'`) and the Settings "Send feedback" form
  /// (`source: 'settings_form'`). `screenshotPaths` are storage paths already
  /// uploaded under `uploads/{uid}/`. Nothing is filed until the user confirms.
  Future<void> submitFeedbackCard({
    required String kind,
    required String title,
    required String body,
    List<String> screenshotPaths = const [],
    String screen = '',
    String appVersion = '',
    String platform = '',
    String source = 'chat_card',
  }) => _postJsonOk('/feedback/submit', {
    'kind': kind,
    'title': title,
    'body': body,
    'screenshot_paths': screenshotPaths,
    'screen': screen,
    'app_version': appVersion,
    'platform': platform,
    'source': source,
  });

  /// `GET /admin/feedback` — the product-feedback triage list for the in-app
  /// Developer → Feedback view (§15). Dev-allowlist gated server-side.
  Future<List<FeedbackRow>> adminListFeedback({int limit = 100}) async {
    final m = await _getJson('/admin/feedback', {'limit': '$limit'});
    return [
      for (final r in (m['feedback'] as List? ?? const []))
        FeedbackRow.fromMap(r as Map<String, dynamic>),
    ];
  }

  /// `POST /admin/feedback/{id}` — set a feedback row's triage status
  /// (`new` / `triaged` / `done`).
  Future<void> adminSetFeedbackStatus(String id, String status) =>
      _postJsonOk('/admin/feedback/$id', {'status': status});

  /// `GET /admin/feedback/media` — a viewable URL for a feedback screenshot's
  /// Storage path (dev-allowlist gated).
  Future<String> adminFeedbackMediaUrl(String path) async {
    final m = await _getJson('/admin/feedback/media', {'path': path});
    return (m['url'] as String?) ?? '';
  }

  /// `POST /notifications/token` — register/refresh this device's FCM token
  /// (§7.2, §7.9 step 2).
  Future<void> registerFcmToken(String token) =>
      _postJsonOk('/notifications/token', {'token': token});

  /// `POST /notifications/token/remove` — drop a device token (sign-out /
  /// rotation).
  Future<void> removeFcmToken(String token) =>
      _postJsonOk('/notifications/token/remove', {'token': token});

  /// `POST /explore/like` — returns true if it created a mutual match (§6.5).
  Future<bool> likeProfile(String otherUid) async {
    final r = await _http.post(
      _uri('/explore/like'),
      headers: await _headers(),
      body: jsonEncode({'other_uid': otherUid}),
    );
    if (r.statusCode != 200) {
      throw ApiException(
        'like failed.',
        statusCode: r.statusCode,
        body: r.body,
      );
    }
    return (jsonDecode(r.body) as Map<String, dynamic>)['mutual'] == true;
  }

  /// `POST /explore/unlike` — undo a like (§6.5); idempotent. Drops the pair
  /// out of each other's matches when the like had made them mutual.
  Future<void> unlikeProfile(String otherUid) =>
      _postJsonOk('/explore/unlike', {'other_uid': otherUid});

  Future<void> _postJsonOk(String path, Map<String, dynamic> body, {Duration? timeout}) async {
    final r = await _post(
      _uri(path),
      body: jsonEncode(body),
      timeout: timeout,
    );
    if (r.statusCode != 200) {
      throw ApiException(
        '$path failed.',
        statusCode: r.statusCode,
        body: r.body,
      );
    }
  }

  /// `POST /match/{id}/respond` — accept or reject a scored match (§5.7).
  Future<void> respondToMatch(String matchId, {required bool accept}) async {
    final response = await _http.post(
      _uri('/match/$matchId/respond'),
      headers: await _headers(),
      body: jsonEncode({'response': accept ? 'accept' : 'reject'}),
    );
    if (response.statusCode != 200) {
      throw ApiException(
        'match respond failed.',
        statusCode: response.statusCode,
        body: response.body,
      );
    }
  }

  /// `POST /block` — block a user; they drop out of all future match sourcing
  /// (§5.1, §5.10 step 11).
  Future<void> block(String blockedUid) async {
    final response = await _http.post(
      _uri('/block'),
      headers: await _headers(),
      body: jsonEncode({'blocked_uid': blockedUid}),
    );
    if (response.statusCode != 200) {
      throw ApiException(
        'block failed.',
        statusCode: response.statusCode,
        body: response.body,
      );
    }
  }

  /// `POST /account/delete` — soft-delete into the 30-day recovery window
  /// (§3.6). The Firebase Auth session is untouched.
  Future<void> deleteAccount() => _postOk('/account/delete');

  /// `POST /account/recover` — restore a soft-deleted account (§3.6).
  Future<void> recoverAccount() => _postOk('/account/recover');

  /// `POST /age-gate/declare` — tells the server the birthdate just entered
  /// (`YYYY-MM-DD`). The server judges it; under 18 closes the account.
  Future<void> declareBirthdate(String isoDate) async {
    final response = await _http.post(
      _uri('/age-gate/declare'),
      headers: await _headers(),
      body: jsonEncode({'birthdate': isoDate}),
    );
    if (response.statusCode != 200) {
      throw ApiException(
        '/age-gate/declare failed.',
        statusCode: response.statusCode,
        body: response.body,
      );
    }
  }

  Future<void> _postOk(String path) async {
    final response = await _http.post(_uri(path), headers: await _headers());
    if (response.statusCode != 200) {
      throw ApiException(
        '$path failed.',
        statusCode: response.statusCode,
        body: response.body,
      );
    }
  }

  /// `POST /chat` — sends a text turn plus the recent-turns window (§1.5),
  /// returns Ayma's reply and any turn-cap signal (§3.3). A non-empty
  /// [sessionId] also persists the running window to `raw_turns` (§1.7 step 8).
  Future<ChatResult> chat(
    String message, {
    String sessionId = '',
    String viewingProfileUid = '',
    List<Map<String, String>> recentTurns = const [],
    String imagePath = '',
    String storyPageId = '',
    String storyPassage = '',
    String storyTimelineEntryId = '',
    String deepDiveReportId = '',
    String deepDiveTarget = '',
    String appearanceFindingId = '',
    String matchReportId = '',
    String sharedKind = '',
    String sharedRefId = '',
    String sharedSubjectUid = '',
    String sharedSubjectName = '',
    String sharedRefVersion = '',
    String replyImagePath = '',
    String sharedCardKind = '',
    String sharedCardUid = '',
    String sharedCardName = '',
    String sharedCardPhoto = '',
    String sharedCardRefId = '',
    bool profileEdit = false,
    String photoUrl = '',
    String photoSource = '',
    String screen = '',
    String screenSubjectUid = '',
    String screenSubjectName = '',
    String screenNote = '',
    String screenRoute = '',
    String screenDetail = '',
    String screenVisible = '',
    String screenPreviousRoute = '',
    String screenPreviousLabel = '',
    String clientMsgId = '',
    bool tourContinuation = false,
    CallStateSnapshot callState = const CallStateSnapshot.none(),
  }) async {
    final http.Response response;
    try {
      response = await _http.post(
        _uri('/chat'),
        headers: await _headers(),
        body: jsonEncode(buildChatRequestBody(
          message: message,
          sessionId: sessionId,
          clientMsgId: clientMsgId,
          tourContinuation: tourContinuation,
          callState: callState,
          viewingProfileUid: viewingProfileUid,
          recentTurns: recentTurns,
          imagePath: imagePath,
          storyPageId: storyPageId,
          storyPassage: storyPassage,
          storyTimelineEntryId: storyTimelineEntryId,
          deepDiveReportId: deepDiveReportId,
          deepDiveTarget: deepDiveTarget,
          appearanceFindingId: appearanceFindingId,
          matchReportId: matchReportId,
          sharedKind: sharedKind,
          sharedRefId: sharedRefId,
          sharedSubjectUid: sharedSubjectUid,
          sharedSubjectName: sharedSubjectName,
          sharedRefVersion: sharedRefVersion,
          replyImagePath: replyImagePath,
          sharedCardKind: sharedCardKind,
          sharedCardUid: sharedCardUid,
          sharedCardName: sharedCardName,
          sharedCardPhoto: sharedCardPhoto,
          sharedCardRefId: sharedCardRefId,
          profileEdit: profileEdit,
          photoUrl: photoUrl,
          photoSource: photoSource,
          screen: screen,
          screenSubjectUid: screenSubjectUid,
          screenSubjectName: screenSubjectName,
          screenNote: screenNote,
          screenRoute: screenRoute,
          screenDetail: screenDetail,
          screenVisible: screenVisible,
          screenPreviousRoute: screenPreviousRoute,
          screenPreviousLabel: screenPreviousLabel,
        )),
      );
    } on http.ClientException catch (e) {
      throw ApiException('Network error: ${e.message}');
    }

    if (response.statusCode != 200) {
      throw ApiException(
        'Chat request failed.',
        statusCode: response.statusCode,
        body: response.body,
      );
    }
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    return ChatResult.fromMap(decoded);
  }

  /// `POST /chat/stream` — the same turn as [chat] but as Server-Sent Events:
  /// [ChatStatus] items while a tool runs (so the UI can show *"Searching the
  /// web…"* live), then one [ChatReplyEvent] carrying the final [ChatResult].
  /// Throws [ApiException] on a transport / non-200 failure — the caller can
  /// fall back to [chat].
  Stream<ChatEvent> chatStream(
    String message, {
    String sessionId = '',
    String viewingProfileUid = '',
    List<Map<String, String>> recentTurns = const [],
    String imagePath = '',
    String storyPageId = '',
    String storyPassage = '',
    String storyTimelineEntryId = '',
    String deepDiveReportId = '',
    String deepDiveTarget = '',
    String appearanceFindingId = '',
    String matchReportId = '',
    String sharedKind = '',
    String sharedRefId = '',
    String sharedSubjectUid = '',
    String sharedSubjectName = '',
    String sharedRefVersion = '',
    String replyImagePath = '',
    String sharedCardKind = '',
    String sharedCardUid = '',
    String sharedCardName = '',
    String sharedCardPhoto = '',
    String sharedCardRefId = '',
    bool profileEdit = false,
    String photoUrl = '',
    String photoSource = '',
    String screen = '',
    String screenSubjectUid = '',
    String screenSubjectName = '',
    String screenNote = '',
    String screenRoute = '',
    String screenDetail = '',
    String screenVisible = '',
    String screenPreviousRoute = '',
    String screenPreviousLabel = '',
    String clientMsgId = '',
    CallStateSnapshot callState = const CallStateSnapshot.none(),
  }) async* {
    final req = http.Request('POST', _uri('/chat/stream'))
      ..headers.addAll(await _headers())
      ..body = jsonEncode(buildChatRequestBody(
        message: message,
        sessionId: sessionId,
        clientMsgId: clientMsgId,
        callState: callState,
        viewingProfileUid: viewingProfileUid,
        recentTurns: recentTurns,
        imagePath: imagePath,
        storyPageId: storyPageId,
        storyPassage: storyPassage,
        storyTimelineEntryId: storyTimelineEntryId,
        deepDiveReportId: deepDiveReportId,
        deepDiveTarget: deepDiveTarget,
        appearanceFindingId: appearanceFindingId,
        matchReportId: matchReportId,
        sharedKind: sharedKind,
        sharedRefId: sharedRefId,
        sharedSubjectUid: sharedSubjectUid,
        sharedSubjectName: sharedSubjectName,
        sharedRefVersion: sharedRefVersion,
        replyImagePath: replyImagePath,
        sharedCardKind: sharedCardKind,
        sharedCardUid: sharedCardUid,
        sharedCardName: sharedCardName,
        sharedCardPhoto: sharedCardPhoto,
        sharedCardRefId: sharedCardRefId,
        profileEdit: profileEdit,
        photoUrl: photoUrl,
        photoSource: photoSource,
        screen: screen,
        screenSubjectUid: screenSubjectUid,
        screenSubjectName: screenSubjectName,
        screenNote: screenNote,
        screenRoute: screenRoute,
        screenDetail: screenDetail,
        screenVisible: screenVisible,
        screenPreviousRoute: screenPreviousRoute,
        screenPreviousLabel: screenPreviousLabel,
        includeTourContinuation: false,
      ));

    final http.StreamedResponse res;
    try {
      res = await _http.send(req).timeout(chatStreamConnectTimeout);
    } on http.ClientException catch (e) {
      throw ApiException('Network error: ${e.message}');
    } on TimeoutException {
      throw ApiException('Network error: chat request timed out');
    }
    if (res.statusCode != 200) {
      final body = await res.stream.bytesToString();
      throw ApiException(
        'Chat stream failed.',
        statusCode: res.statusCode,
        body: body,
      );
    }

    var buffer = '';
    // The chunk loop is wrapped so a MID-STREAM transport death (the OS
    // killing the socket when the app is backgrounded — distinct from the
    // send-time failure caught above, and from a server-sent `error` event)
    // surfaces as the same connection-class ApiException ('Network error: …',
    // no statusCode) the caller's reconciliation logic looks for.
    final chunks = StreamIterator(res.stream.transform(utf8.decoder));
    while (true) {
      final String chunk;
      try {
        if (!await chunks.moveNext().timeout(chatStreamIdleTimeout)) break;
        chunk = chunks.current;
      } on http.ClientException catch (e) {
        throw ApiException('Network error: ${e.message}');
      } on TimeoutException {
        unawaited(chunks.cancel());
        throw ApiException('Network error: chat stream stalled');
      }
      buffer += chunk;
      while (true) {
        final nl = buffer.indexOf('\n\n');
        if (nl < 0) break;
        final frame = buffer.substring(0, nl);
        buffer = buffer.substring(nl + 2);
        for (final line in frame.split('\n')) {
          if (!line.startsWith('data: ')) continue;
          final Map<String, dynamic> m;
          try {
            m = jsonDecode(line.substring(6)) as Map<String, dynamic>;
          } catch (_) {
            continue;
          }
          switch (m['type']) {
            case 'status':
              yield ChatStatus(m['label'] as String? ?? 'Working…');
            case 'reply':
              yield ChatReplyEvent(ChatResult.fromMap(m));
            case 'error':
              throw ApiException(
                (m['detail'] as String?) ?? 'Chat stream error.',
                statusCode: 502,
              );
          }
        }
      }
    }
  }

  /// `GET /chat/history` — a page of the durable Ayma-tab transcript (§2.2),
  /// oldest-first, plus the ISO cursor for the next older page (null at the
  /// start of history).
  Future<({List<ChatMessage> messages, String? nextBefore})> chatHistory({
    String? before,
    int limit = 40,
    bool noRetry = false,
    Duration? timeout,
  }) async {
    final uri = _uri('/chat/history').replace(
      queryParameters: {
        'limit': '$limit',
        if (before != null && before.isNotEmpty) 'before': before,
      },
    );
    final headers = await _headers();
    // The offline queue flush opts out of the GET retry-backoff so it fails
    // fast and the online flush isn't skipped (PERF_PLAN GATE-RED).
    if (noRetry) headers['X-No-Retry'] = '1';
    // The on-open load raises this past the 8s interactive budget so the first
    // call can ride through a scale-to-zero cold start instead of 408-ing
    // (ChatScreen._loadHistory wraps it in a cold-start retry on top).
    if (timeout != null) {
      headers['X-Request-Timeout'] = '${timeout.inMilliseconds}';
    }
    final r = await _http.get(uri, headers: headers);
    if (r.statusCode != 200) {
      throw ApiException(
        'chat history failed.',
        statusCode: r.statusCode,
        body: r.body,
      );
    }
    final decoded = jsonDecode(r.body) as Map<String, dynamic>;
    return (
      messages: ((decoded['messages'] as List?) ?? [])
          .map((m) => ChatMessage.fromMap(m as Map<String, dynamic>))
          .toList(),
      nextBefore: decoded['next_before'] as String?,
    );
  }

  /// `POST /media` — run the unified photo pipeline (moderation → embed →
  /// attributes → caption, §8.5) on an uploaded photo. Call after the file is
  /// in `uploads/{uid}/…`.
  Future<MediaResult> registerMedia(
    String storagePath, {
    String context = 'profile',
    String captionContext = '',
  }) async {
    final response = await _http.post(
      _uri('/media'),
      headers: await _headers(),
      body: jsonEncode({
        'storage_path': storagePath,
        'context': context,
        'caption_context': captionContext,
      }),
    );
    if (response.statusCode != 200) {
      throw ApiException(
        'Media registration failed.',
        statusCode: response.statusCode,
        body: response.body,
      );
    }
    final m = jsonDecode(response.body) as Map<String, dynamic>;
    return MediaResult(
      mediaId: m['media_id'] as String? ?? '',
      published: m['published'] as bool? ?? true,
      moderationStatus: m['moderation_status'] as String? ?? 'approved',
      reason: m['reason'] as String? ?? '',
    );
  }

  /// `POST /verification/selfie` — moderate + embed an already-uploaded
  /// verification selfie (`verification/{uid}/…`) and store it as the
  /// account's face-match reference (§ face verification). Also seeds the
  /// initial Appearance read. A moderation rejection behaves like any other
  /// upload (`verified: false`), not an error.
  Future<VerificationResult> verifySelfie(String storagePath) async {
    final response = await _http.post(
      _uri('/verification/selfie'),
      headers: await _headers(),
      body: jsonEncode({'storage_path': storagePath}),
    );
    if (response.statusCode != 200) {
      throw ApiException(
        'Verification failed.',
        statusCode: response.statusCode,
        body: response.body,
      );
    }
    final m = jsonDecode(response.body) as Map<String, dynamic>;
    return VerificationResult(
      verified: m['verified'] as bool? ?? false,
      moderationStatus: m['moderation_status'] as String? ?? '',
      reason: m['reason'] as String? ?? '',
    );
  }

  /// `GET /verification/status` — whether the caller already has a stored
  /// verification selfie. Backs the "Verify your face" action / unverified
  /// badge in Settings.
  Future<bool> verificationStatus() async {
    final response = await _http.get(
      _uri('/verification/status'),
      headers: await _headers(),
    );
    if (response.statusCode != 200) {
      throw ApiException(
        'Verification status failed.',
        statusCode: response.statusCode,
        body: response.body,
      );
    }
    final m = jsonDecode(response.body) as Map<String, dynamic>;
    return m['verified'] as bool? ?? false;
  }

  /// `GET /biometric-consent` — whether the caller has given the current
  /// face-matching consent, and when.
  Future<BiometricConsentStatus> biometricConsentStatus() async {
    final r = await _http.get(
      _uri('/biometric-consent'),
      headers: await _headers(),
    );
    if (r.statusCode != 200) {
      throw ApiException(
        'Consent status failed.',
        statusCode: r.statusCode,
        body: r.body,
      );
    }
    return BiometricConsentStatus.fromMap(
      jsonDecode(r.body) as Map<String, dynamic>,
    );
  }

  /// `POST /biometric-consent` — records the explicit "I agree" for the
  /// current consent text ([kBiometricConsentVersion]); [region] is the
  /// device country code or ''. Clears the app-wide consent-required state.
  Future<void> acceptBiometricConsent({String region = ''}) async {
    await _postJsonOk('/biometric-consent', {
      'agreed': true,
      'consent_version': kBiometricConsentVersion,
      'region': region,
    });
    BiometricConsentState.instance.clear();
  }

  /// `POST /biometric-consent/withdraw` — deletes the caller's face data and
  /// then their account. The caller signs out afterwards.
  Future<void> withdrawBiometricConsent() =>
      _postOk('/biometric-consent/withdraw');

  /// `POST /onboarding/complete` — call once, right when preboarding actually
  /// finishes (§ web search about me — reliable trigger). Idempotent — safe
  /// to call more than once; schedules the caller's one-time automatic self
  /// web-search dive and reverse-image photo scan as background jobs, each
  /// gated by its own one-time flag. Fire-and-forget from the caller's side:
  /// never blocks navigation, and a failure here isn't shown to the user.
  Future<void> completeOnboarding() =>
      _postJsonOk('/onboarding/complete', const {});

  // --- Web photo search: reverse-image candidates ------------------------

  /// `POST /web-search/photos/rescan` — (re)run reverse-image search against
  /// one or more of the caller's own already-uploaded photos; empty
  /// [storagePaths] re-scans the current primary profile photo. Always a
  /// background job server-side — returns immediately. Call this after a
  /// post-onboarding photo batch add so the newly added photos get searched
  /// too, not just the original onboarding set.
  Future<void> rescanWebSearchPhotos({List<String> storagePaths = const []}) =>
      _postJsonOk('/web-search/photos/rescan', {'storage_paths': storagePaths});

  // --- Generic Living Report (§ generic reports) --------------------------
  //
  // One block-shaped read + one tap-to-correct across every report type —
  // Appearance, deep-dive/web-search, and Story in each of its three view
  // modes ("story_private" / "story_public" / "story_ai_notes"). See
  // `report_hub.py` server-side. [reportId] means something different per
  // type: the caller's own uid for every type except "deep_dive" (a real,
  // previously-run deep-dive report id) — see `LivingReportView`'s doc.

  /// `GET /report/{report_type}/{report_id}`.
  Future<LivingReport> getReport(String reportType, String reportId) async {
    final r = await _http.get(
      _uri(
        '/report/${Uri.encodeComponent(reportType)}/${Uri.encodeComponent(reportId)}',
      ),
      headers: await _headers(),
    );
    if (r.statusCode != 200) {
      throw ApiException(
        'report failed.',
        statusCode: r.statusCode,
        body: r.body,
      );
    }
    return LivingReport.fromMap(jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// `POST /share` — snapshot one of the caller's reports behind a public
  /// link (idempotent per report).
  Future<ReportShare> createShare(String reportType, String reportId) async =>
      ReportShare.fromMap(
        await _sendJson('POST', '/share', {
          'report_type': reportType,
          'report_id': reportId,
        }),
      );

  /// `POST /share-link` — snapshot a shareable page (a profile; the
  /// reusable share kit's public kinds) behind a public `/p/` link
  /// (idempotent per target). Ayma-only kinds are refused server-side.
  Future<LinkShare> createLinkShare(String kind, String targetId) async =>
      LinkShare.fromMap(
        await _sendJson('POST', '/share-link', {
          'kind': kind,
          'target_id': targetId,
        }),
      );

  /// `GET /p/{token}/data` — the public, unauthenticated target identity
  /// behind a page-share link, for the deep-link route.
  Future<PageShareTarget> pageShareTarget(String token) async {
    final r = await _http.get(_uri('/p/${Uri.encodeComponent(token)}/data'));
    if (r.statusCode != 200) {
      throw ApiException(
        'page share failed.',
        statusCode: r.statusCode,
        body: r.body,
      );
    }
    return PageShareTarget.fromMap(
        jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// `GET /s/{token}/data` — the public, unauthenticated snapshot behind a
  /// share link, in the same shape as [getReport].
  Future<LivingReport> sharedReport(String token) async {
    final r = await _http.get(_uri('/s/${Uri.encodeComponent(token)}/data'));
    if (r.statusCode != 200) {
      throw ApiException(
        'shared report failed.',
        statusCode: r.statusCode,
        body: r.body,
      );
    }
    return LivingReport.fromMap(jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// `POST /report/{report_type}/{report_id}/correct` — one tap-to-correct
  /// turn: [blockIds] + [scope] name what's in play (see
  /// `AskAymaContext.reportCorrectBody`), [message] is either free text or
  /// one of the fixed quick-action phrases (`report_hub.QUICK_*`) — the
  /// server tells them apart deterministically, never this client.
  Future<ReportCorrectResult> correctReport(
    String reportType,
    String reportId, {
    required List<String> blockIds,
    required String scope,
    required String message,
  }) async {
    final r = await _http.post(
      _uri(
        '/report/${Uri.encodeComponent(reportType)}/${Uri.encodeComponent(reportId)}/correct',
      ),
      headers: await _headers(),
      body: jsonEncode({
        'block_ids': blockIds,
        'scope': scope,
        'message': message,
      }),
    );
    if (r.statusCode != 200) {
      throw ApiException(
        'report correct failed.',
        statusCode: r.statusCode,
        body: r.body,
      );
    }
    return ReportCorrectResult.fromMap(
      jsonDecode(r.body) as Map<String, dynamic>,
    );
  }

  /// `POST /post-turn` — persist the session's raw turn window on session end
  /// (§1.7 step 8). Best-effort: failures are swallowed by the caller.
  Future<void> postTurn(
    String sessionId,
    List<Map<String, String>> recentTurns,
  ) async {
    if (sessionId.isEmpty || recentTurns.isEmpty) return;
    final response = await _http.post(
      _uri('/post-turn'),
      headers: await _headers(),
      body: jsonEncode({
        'session_id': sessionId,
        'recent_turns': clampRecentTurns(recentTurns),
      }),
    );
    if (response.statusCode != 200) {
      throw ApiException(
        'post-turn failed.',
        statusCode: response.statusCode,
        body: response.body,
      );
    }
  }
}

/// Result of `POST /bootstrap` — the bits the client needs to open a voice
/// session. `session_mode` is consumed by later steps (screen gating, §3.3).
class BootstrapResult {
  const BootstrapResult({
    required this.sessionMode,
    required this.livekitUrl,
    required this.livekitToken,
    required this.room,
    this.recoveryRequired = false,
    this.usageCapped = false,
    this.ageBlocked = false,
    this.biometricConsentRequired = false,
    this.voiceProvider = '',
  });

  final String sessionMode;
  final String livekitUrl;
  final String livekitToken;
  final String room;

  /// The configured voice backend (`inference` / `google`), used only to tag
  /// crash reports for a failed voice start. Empty when not sent.
  final String voiceProvider;

  /// The account is soft-deleted — the client shows the recovery screen (§3.6).
  final bool recoveryRequired;

  /// The account is closed because the person is under 18 — the client shows
  /// the hard-stop screen and nothing else.
  final bool ageBlocked;

  /// Out of credits — the voice session can't start (§15). The chat screen
  /// surfaces "reload credits".
  final bool usageCapped;

  /// The account has not given the face-matching consent yet — the client
  /// records the one ticked at sign-in, or shows the consent screen.
  final bool biometricConsentRequired;
}

/// `GET /biometric-consent`.
class BiometricConsentStatus {
  const BiometricConsentStatus({
    required this.consented,
    this.consentVersion = '',
    this.consentedAt,
    this.region = '',
  });

  factory BiometricConsentStatus.fromMap(Map<String, dynamic> m) =>
      BiometricConsentStatus(
        consented: m['consented'] == true,
        consentVersion: m['consent_version'] as String? ?? '',
        consentedAt: DateTime.tryParse(m['consented_at'] as String? ?? ''),
        region: m['region'] as String? ?? '',
      );

  final bool consented;
  final String consentVersion;
  final DateTime? consentedAt;
  final String region;
}

/// One Explore feed card (§6.4).
/// One page of the Explore feed (Phase 2 pagination design §3.1):
/// the cards plus the opaque cursor for the next page. Tolerates the legacy
/// `{cards}` shape (no cursor fields) during backend rollout.
class ExplorePage {
  const ExplorePage({
    this.cards = const [],
    this.nextCursor,
    this.hasMore = false,
  });

  final List<ExploreCard> cards;
  final String? nextCursor;
  final bool hasMore;

  factory ExplorePage.fromJson(Map<String, dynamic> m) {
    final cards = ((m['cards'] as List?) ?? [])
        .map((c) => ExploreCard.fromMap(c as Map<String, dynamic>))
        .toList();
    final rawCursor = m['next_cursor'] as String?;
    final nextCursor =
        (rawCursor == null || rawCursor.isEmpty) ? null : rawCursor;
    return ExplorePage(
      cards: cards,
      nextCursor: nextCursor,
      hasMore: m['has_more'] == true || nextCursor != null,
    );
  }
}

class ExploreCard {
  const ExploreCard({
    required this.uid,
    required this.name,
    required this.age,
    required this.location,
    this.photoPath,
    this.photoUrl = '',
    this.photoUrlThumb = '',
    this.score,
    this.liked = false,
    this.mutual = false,
    this.likedMe = false,
    this.isSelf = false,
    this.paused = false,
  });

  final String uid;
  final String name;
  final int? age;
  final String location;
  final String? photoPath;

  /// Ready token URL for the primary photo (resolved server-side — the client
  /// can't read another user's Storage path itself).
  final String photoUrl;

  /// Grid-sized (`thumb_400`) variant of [photoUrl], minted server-side.
  /// Empty when the server sent none (old responses) — renderers must use
  /// [gridPhotoUrl], which falls back to [photoUrl].
  final String photoUrlThumb;

  /// The URL the Explore grid renders: the thumb variant when present, else
  /// the original. The server already falls back to the original when the
  /// variant object is missing; this covers responses without the field.
  String get gridPhotoUrl => photoUrlThumb.isNotEmpty ? photoUrlThumb : photoUrl;
  final double? score;

  /// You liked them / it's a mutual like — for the Explore filter chips.
  final bool liked;
  final bool mutual;

  /// They liked you (a received like, whether or not you liked them
  /// back) — for the Explore "Liked me" filter chip.
  final bool likedMe;

  /// The caller's own card — Explore now includes it (no Like/Pass).
  final bool isSelf;

  /// Your own card while "Pause matching" is on — only you can see it.
  final bool paused;

  factory ExploreCard.fromMap(Map<String, dynamic> m) => ExploreCard(
    uid: m['uid'] as String? ?? '',
    name: m['name'] as String? ?? '',
    age: (m['age'] as num?)?.toInt(),
    location: m['location'] as String? ?? '',
    photoPath: m['photo_path'] as String?,
    photoUrl: m['photo_url'] as String? ?? '',
    photoUrlThumb: m['photo_url_thumb'] as String? ?? '',
    score: (m['score'] as num?)?.toDouble(),
    liked: m['liked'] == true,
    mutual: m['mutual'] == true,
    likedMe: m['liked_me'] == true,
    isSelf: m['self'] == true,
    paused: m['paused'] == true,
  );

  /// Wire-form map (the exact inverse of [fromMap]) for the Explore feed's
  /// last-known cache (offline-first): page 1 persists locally so a cold
  /// start paints instantly and refreshes behind.
  Map<String, dynamic> toMap() => {
    'uid': uid,
    'name': name,
    'age': age,
    'location': location,
    'photo_path': photoPath,
    'photo_url': photoUrl,
    'photo_url_thumb': photoUrlThumb,
    'score': score,
    'liked': liked,
    'mutual': mutual,
    'liked_me': likedMe,
    'self': isSelf,
    'paused': paused,
  };
}

/// One section of another user's public profile — a wiki page rendered as
/// `user_edits ?? ai_body`.
class ProfileSection {
  const ProfileSection({
    required this.pageType,
    required this.title,
    required this.body,
  });

  final String pageType;
  final String title;
  final String body;

  factory ProfileSection.fromMap(Map<String, dynamic> m) => ProfileSection(
    pageType: m['page_type'] as String? ?? 'misc',
    title: m['title'] as String? ?? '',
    body: m['body'] as String? ?? '',
  );
}

/// One field of the owner's structured physical-attributes record
/// (`GET /physical-attributes`, or the `physical_attributes` block on the
/// owner's own `/explore/profile/{uid}`). [source] is `stated` (from the
/// user's own answers), `photo` (read from their pictures) or `none`.
class PhysicalAttribute {
  const PhysicalAttribute({
    required this.field,
    required this.value,
    required this.source,
    this.confidence = '',
  });

  final String field;
  final String value;
  final String source;

  /// `high` | `medium` | `low` | `none` — drives the confidence dot in the
  /// report view. Empty when the caller doesn't surface it.
  final String confidence;

  bool get isStated => source == 'stated';
  bool get isFromPhotos => source == 'photo';

  static PhysicalAttribute? fromEntry(String field, Object? raw) {
    if (raw is! Map) return null;
    final v = raw['value'];
    if (v == null) return null;
    final text = v is num ? v.toString() : v.toString().trim();
    if (text.isEmpty || text.toLowerCase() == 'unknown') return null;
    return PhysicalAttribute(
      field: field,
      value: text,
      source: (raw['source'] as String?) ?? 'none',
      confidence: (raw['confidence'] as String?) ?? '',
    );
  }

  /// Parse the `fields` map into a list, known values only, in a stable order.
  static List<PhysicalAttribute> listFrom(Map<String, dynamic>? fields) {
    if (fields == null) return const [];
    const order = [
      'race_ethnicity',
      'skin_tone',
      'eye_color',
      'hair_color',
      'hair_length',
      'hair_type',
      'height_estimate_cm',
      'weight_estimate_kg',
      'build',
      'facial_hair',
      'glasses',
      'visible_tattoos',
      'visible_piercings',
      'distinguishing_features',
    ];
    final out = <PhysicalAttribute>[];
    for (final f in order) {
      final a = PhysicalAttribute.fromEntry(f, fields[f]);
      if (a != null) out.add(a);
    }
    return out;
  }
}

/// Another user's public profile (`GET /explore/profile/{uid}`).
class PublicProfile {
  const PublicProfile({
    required this.uid,
    required this.name,
    required this.age,
    required this.location,
    required this.photos,
    required this.sections,
    required this.isSelf,
    required this.blocked,
    required this.liked,
    required this.score,
    required this.threadId,
    this.hasChatted = false,
    this.deepDiveId = '',
    this.physicalAttributes = const [],
    this.isOnline = false,
    this.photosThumb = const [],
    this.photosMedium = const [],
  });

  final String uid;
  final String name;
  final int? age;
  final String location;

  /// True only when this person touched the API within the last 5 minutes
  /// (`last_active_at`, stamped on every authed request — see
  /// `public_profile.py`'s `_is_online`, the same signal/window
  /// `/profiles/mini` uses). Drives the profile header's "Active now"
  /// status dot — never hardcoded true.
  final bool isOnline;

  /// Ready-to-render download URLs, primary first.
  final List<String> photos;

  /// Server-minted `thumb_400` / `medium_1080` variants, aligned 1:1 with
  /// [photos] (the server already falls back per entry to the original when a
  /// variant object is missing). Empty when the server sent none — renderers
  /// must use [thumbPhotos] / [detailPhotos], which fall back to [photos].
  final List<String> photosThumb;
  final List<String> photosMedium;

  /// Carousel-ready URLs: the medium variant per photo, else the original.
  /// Index-aligned with [photos]; defensive against short/missing arrays.
  List<String> get detailPhotos => _withFallback(photosMedium);

  /// Filmstrip-ready URLs: the thumb variant per photo, else the original.
  /// Index-aligned with [photos]; defensive against short/missing arrays.
  List<String> get thumbPhotos => _withFallback(photosThumb);

  List<String> _withFallback(List<String> variants) => List<String>.generate(
        photos.length,
        (i) => i < variants.length && variants[i].isNotEmpty
            ? variants[i]
            : photos[i],
        growable: false,
      );
  final List<ProfileSection> sections;
  final bool isSelf;
  final bool blocked;
  final bool liked;
  final double? score;

  /// Sorted-pair id shared by `matches` and `dm_threads`; null when self.
  /// This is a bare deterministic id present for ANY non-self pair — it says
  /// nothing about whether they've actually chatted. Use [hasChatted] for
  /// that.
  final String? threadId;

  /// True only once a real DM message has been sent either way. Drives the
  /// Chat button's "already chatted" highlight — never [threadId], which is
  /// always non-null for a non-self profile regardless of chat history.
  final bool hasChatted;

  /// Id of a stored web dive on this person the caller can re-open — empty
  /// when they've never run one. Drives "View research" vs. "Deep dive".
  final String deepDiveId;

  /// The owner's structured physical attributes, each with a source tag.
  /// Only populated on the owner's own view; empty otherwise.
  final List<PhysicalAttribute> physicalAttributes;

  factory PublicProfile.fromMap(Map<String, dynamic> m) => PublicProfile(
    uid: m['uid'] as String? ?? '',
    name: m['name'] as String? ?? '',
    age: (m['age'] as num?)?.toInt(),
    location: m['location'] as String? ?? '',
    photos: ((m['photos'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList(),
    photosThumb: ((m['photos_thumb'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList(),
    photosMedium: ((m['photos_medium'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList(),
    sections: ((m['pages'] as List?) ?? const [])
        .map((e) => ProfileSection.fromMap(e as Map<String, dynamic>))
        .toList(),
    isSelf: m['self'] == true,
    blocked: m['blocked'] == true,
    liked: m['liked'] == true,
    score: (m['score'] as num?)?.toDouble(),
    threadId: m['thread_id'] as String?,
    hasChatted: m['has_chatted'] == true,
    deepDiveId: m['deep_dive_id'] as String? ?? '',
    physicalAttributes: PhysicalAttribute.listFrom(
      (m['physical_attributes'] as Map<String, dynamic>?)?['fields']
          as Map<String, dynamic>?,
    ),
    isOnline: m['online'] == true,
  );
}

/// A `/chat` turn's outcome. [capped] means the turn was refused by the
/// marketing/interview cap and [reply] is Ayma's nudge; [fallbackForm] means
/// the client should switch to the plain manual profile form (§3.3).
/// The answer to `POST /voice/async`: the job id plus either the accepted
/// status (the client watches the job doc from here) or the full terminal
/// payload when this exact job already finished.
class VoiceAsyncSubmit {
  const VoiceAsyncSubmit({
    required this.jobId,
    required this.status,
    this.joined = false,
    this.transcript = '',
    this.replyText = '',
    this.replyAudioUrl = '',
    this.tools = const [],
    this.imageUrl = '',
  });

  factory VoiceAsyncSubmit.fromMap(Map<String, dynamic> m) => VoiceAsyncSubmit(
    jobId: m['job_id'] as String? ?? '',
    status: m['status'] as String? ?? '',
    joined: m['joined'] == true,
    transcript: m['transcript'] as String? ?? '',
    replyText: m['reply_text'] as String? ?? '',
    replyAudioUrl: m['reply_audio_url'] as String? ?? '',
    tools: ((m['tools'] as List?) ?? const [])
        .map((e) => e.toString())
        .where((s) => s.isNotEmpty)
        .toList(),
    imageUrl: m['image_url'] as String? ?? '',
  );

  final String jobId;
  final String status;
  final bool joined;
  final String transcript;
  final String replyText;
  final String replyAudioUrl;
  final List<String> tools;
  final String imageUrl;
}

class ChatResult {
  const ChatResult({
    required this.reply,
    this.capped = false,
    this.fallbackForm = false,
    this.imageRejected = false,
    this.usageCapped = false,
    this.toolsUsed = const [],
    this.imageUrl = '',
    this.feedbackCard,
    this.feedbackBubble,
  });

  factory ChatResult.fromMap(Map<String, dynamic> m) => ChatResult(
    // `/chat` sends `reply`; a `/chat/stream` reply event sends `text`.
    reply: (m['reply'] ?? m['text']) as String? ?? '',
    capped: m['capped'] == true,
    fallbackForm: m['fallback_form'] == true,
    imageRejected: m['image_rejected'] == true,
    usageCapped: m['usage_capped'] == true,
    toolsUsed: ((m['tools_used'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList(),
    imageUrl: m['image_url'] as String? ?? '',
    feedbackCard: m['feedback_card'] is Map
        ? FeedbackCard.fromMap(
            (m['feedback_card'] as Map).cast<String, dynamic>())
        : null,
    feedbackBubble: m['feedback_bubble'] is Map
        ? FeedbackBubble.fromMap(
            (m['feedback_bubble'] as Map).cast<String, dynamic>())
        : null,
  );

  final String reply;
  final bool capped;
  final bool fallbackForm;

  /// The attached image failed the content check — nothing was stored.
  final bool imageRejected;

  /// Out of credits — Ayma paused for now.
  final bool usageCapped;

  /// User-facing labels for the tools Ayma used on this turn ("Searched the
  /// web", …). Empty when she just answered.
  final List<String> toolsUsed;

  /// A download URL for a photo Ayma generated this turn (the `edit_photo`
  /// tool, "Chat about it" photo flow) — empty for a plain text reply.
  final String imageUrl;

  /// A feedback card Ayma drafted this turn (the `submit_feedback` tool) for
  /// the user to review, edit and send — null for a normal turn. Nothing is
  /// filed until the user taps Send on the card.
  final FeedbackCard? feedbackCard;

  /// A feedback-bubble offer for this turn (server rule in
  /// `feedback_bubble.py`: explicit "capture feedback" or Ayma's own
  /// `record_feedback` fired) — the chat renders the in-chat bubble
  /// card asking the user for their feedback. Null for a normal turn.
  final FeedbackBubble? feedbackBubble;
}

/// The server's feedback-bubble offer payload (`feedback_bubble` on a
/// chat reply). The client-side trigger/gate types live in
/// `feedback_bubble.dart`; this is only the wire shape.
class FeedbackBubble {
  const FeedbackBubble({required this.trigger, this.prefill = ''});

  factory FeedbackBubble.fromMap(Map<String, dynamic> m) => FeedbackBubble(
        trigger: (m['trigger'] as String?) ?? '',
        prefill: (m['prefill'] as String?) ?? '',
      );

  /// `'explicit'` or `'frustration'`.
  final String trigger;
  final String prefill;
}

/// A product-feedback card Ayma drafted mid-chat (the `submit_feedback` tool).
/// It is NOT yet filed — the user reviews/edits it and sends it themselves
/// (`POST /feedback/submit`). See [FeedbackDraftCard].
class FeedbackCard {
  const FeedbackCard({
    required this.kind,
    required this.title,
    required this.body,
  });

  factory FeedbackCard.fromMap(Map<String, dynamic> m) => FeedbackCard(
        kind: (m['kind'] as String?) ?? 'feature',
        title: (m['title'] as String?) ?? '',
        body: (m['body'] as String?) ?? '',
      );

  /// `'feature'` or `'bug'`.
  final String kind;
  final String title;
  final String body;
}

/// One triaged product-feedback row for the Developer → Feedback admin view
/// (`GET /admin/feedback`). [screenshotPaths] are `uploads/{uid}/…` Storage
/// paths the client resolves to view.
class FeedbackRow {
  const FeedbackRow({
    required this.id,
    required this.uid,
    required this.source,
    required this.kind,
    required this.title,
    required this.body,
    required this.screenshotPaths,
    required this.screen,
    required this.appVersion,
    required this.platform,
    required this.status,
    required this.createdAt,
  });

  factory FeedbackRow.fromMap(Map<String, dynamic> m) => FeedbackRow(
        id: (m['id'] as String?) ?? '',
        uid: (m['uid'] as String?) ?? '',
        source: (m['source'] as String?) ?? '',
        kind: (m['kind'] as String?) ?? '',
        title: (m['title'] as String?) ?? '',
        body: (m['body'] as String?) ?? '',
        screenshotPaths: [
          for (final p in (m['screenshot_paths'] as List? ?? const []))
            p.toString(),
        ],
        screen: (m['screen'] as String?) ?? '',
        appVersion: (m['app_version'] as String?) ?? '',
        platform: (m['platform'] as String?) ?? '',
        status: (m['status'] as String?) ?? 'new',
        createdAt: DateTime.tryParse((m['created_at'] as String?) ?? ''),
      );

  final String id;
  final String uid;
  final String source;
  final String kind;
  final String title;
  final String body;
  final List<String> screenshotPaths;
  final String screen;
  final String appVersion;
  final String platform;
  final String status;
  final DateTime? createdAt;
}

/// One frame of [ApiClient.chatStream].
sealed class ChatEvent {
  const ChatEvent();
}

/// A live "…ing" label while a tool runs ("Searching the web…").
class ChatStatus extends ChatEvent {
  const ChatStatus(this.label);
  final String label;
}

/// The finished turn.
class ChatReplyEvent extends ChatEvent {
  const ChatReplyEvent(this.result);
  final ChatResult result;
}

/// One persisted message from `GET /chat/history` (§2.2). [imagePath] is a
/// `uploads/{uid}/…` path the client resolves to a download URL itself;
/// [imageUrl] is the server-resolved durable URL for an image the client
/// CAN'T resolve — an Ayma-generated `ayma_generated/{uid}/…` image, whose
/// path Storage rules hide from the client SDK (founder bug 2026-09-27: a
/// generated image vanished from the transcript on reload).
class ChatMessage {
  const ChatMessage({
    required this.role,
    required this.text,
    this.imagePath = '',
    this.imageUrl = '',
    this.audioPath = '',
    this.audioUrl = '',
    this.tools = const [],
    this.subjectImage = '',
    this.createdAt,
    this.clientMsgId = '',
    this.sharedCardKind = '',
    this.sharedCardUid = '',
    this.sharedCardName = '',
    this.sharedCardPhoto = '',
    this.sharedCardRefId = '',
  });

  final String role; // 'user' | 'ayma'
  final String text;
  final String imagePath;

  /// Durable download URL for this turn's image, already resolved server-side
  /// (empty when the client should resolve [imagePath] itself, or no image).
  final String imageUrl;

  /// Async voice-message audio (Chunk A): the user's recorded clip as an
  /// `uploads/{uid}/…` [audioPath] the client SDK resolves itself, and
  /// Ayma's spoken reply as a durable server-resolved [audioUrl] (its
  /// `ayma_generated/{uid}/…` path is not client-resolvable). Both empty on
  /// a text turn.
  final String audioPath;
  final String audioUrl;

  /// User-facing labels for what Ayma did on this turn ("Searched the web",
  /// "Researched Jane Doe online") — the kicker above the reply.
  final List<String> tools;

  /// Resolved photo URL for the person a skill was run on (Explore deep-dive),
  /// shown as a small avatar next to the kicker. Empty when not applicable.
  final String subjectImage;

  /// When this turn happened — null for an undated row. Lets the chat screen
  /// jump to a point in history (e.g. from a Your Story provenance source).
  final DateTime? createdAt;

  /// The client-generated id of the user send this row belongs to (stamped on
  /// both the user turn and its reply) — lets a client whose connection died
  /// mid-send find the finished turn by exact id. Empty for older rows.
  final String clientMsgId;

  /// The Send-to-Ayma card posted with this user turn (empty unless the
  /// row carried one): kind + subject uid/name + card photo + tap target
  /// (a report / match / DM-thread id). The chat rebuilds the tappable
  /// card from these on a history load — identity only, never the shared
  /// page's contents.
  final String sharedCardKind;
  final String sharedCardUid;
  final String sharedCardName;
  final String sharedCardPhoto;
  final String sharedCardRefId;

  factory ChatMessage.fromMap(Map<String, dynamic> m) => ChatMessage(
    role: m['role'] as String? ?? 'ayma',
    text: m['text'] as String? ?? '',
    imagePath: m['image_path'] as String? ?? '',
    imageUrl: m['image_url'] as String? ?? '',
    audioPath: m['audio_path'] as String? ?? '',
    audioUrl: m['audio_url'] as String? ?? '',
    tools: ((m['tools'] as List?) ?? const [])
        .map((e) => e.toString())
        .where((s) => s.isNotEmpty)
        .toList(),
    subjectImage: m['subject_image'] as String? ?? '',
    createdAt: DateTime.tryParse(m['created_at'] as String? ?? ''),
    clientMsgId: m['client_msg_id'] as String? ?? '',
    sharedCardKind: m['shared_card_kind'] as String? ?? '',
    sharedCardUid: m['shared_card_uid'] as String? ?? '',
    sharedCardName: m['shared_card_name'] as String? ?? '',
    sharedCardPhoto: m['shared_card_photo'] as String? ?? '',
    sharedCardRefId: m['shared_card_ref_id'] as String? ?? '',
  );

  /// Wire-form map (the exact inverse of [fromMap]) for the chat's
  /// last-known history cache (offline-first).
  Map<String, dynamic> toMap() => {
    'role': role,
    'text': text,
    'image_path': imagePath,
    'image_url': imageUrl,
    'audio_path': audioPath,
    'audio_url': audioUrl,
    'tools': tools,
    'subject_image': subjectImage,
    'created_at': createdAt?.toIso8601String(),
    'client_msg_id': clientMsgId,
    'shared_card_kind': sharedCardKind,
    'shared_card_uid': sharedCardUid,
    'shared_card_name': sharedCardName,
    'shared_card_photo': sharedCardPhoto,
    'shared_card_ref_id': sharedCardRefId,
  };
}

/// Result of `POST /media` (§8.4/§8.5). [published] is false when moderation
/// [reason] held the photo out of the grid / Explore / DM.
class MediaResult {
  const MediaResult({
    required this.mediaId,
    required this.published,
    required this.moderationStatus,
    required this.reason,
  });

  final String mediaId;
  final bool published;
  final String moderationStatus;
  final String reason;
}

/// Result of `POST /media/photos/batch` — [added] / [failed] are media ids
/// from the request; [photos] is the caller's full grid after the add.
class PhotoBatchResult {
  const PhotoBatchResult({
    required this.photos,
    required this.added,
    required this.failed,
  });

  final List<Map<String, dynamic>> photos;
  final List<String> added;
  final List<String> failed;
}

/// `GET /google/status` result — never carries the token itself.
class GoogleAccountStatus {
  const GoogleAccountStatus({required this.connected, required this.email});

  final bool connected;
  final String email;
}

/// Result of `POST /instagram/signin` — a Firebase custom token to sign in
/// with, plus whether this created a brand-new Ayma account (so the caller
/// can route into onboarding vs. straight into the app the same way any
/// other fresh sign-in does).
class InstagramSigninResult {
  const InstagramSigninResult({
    required this.customToken,
    required this.isNewUser,
  });

  final String customToken;
  final bool isNewUser;
}

/// Result of `POST /verification/selfie` (§ face verification). [verified] is
/// false when moderation rejected the selfie — same as any other upload.
class VerificationResult {
  const VerificationResult({
    required this.verified,
    required this.moderationStatus,
    required this.reason,
  });

  final bool verified;
  final String moderationStatus;
  final String reason;
}

/// `GET /usage` result — token accounting plus the user-facing credit balance
/// (a display layer over tokens).
class UsageSummary {
  const UsageSummary({
    required this.total,
    required this.features,
    this.creditGrant = 0,
    this.creditsAdded = 0,
    this.creditsUsed = 0,
    this.creditsRemaining = 0,
    this.tokensPerCredit = 1000,
    this.costUsd = 0,
    this.realMoneyUsd = 0,
    this.realMoneyAllTimeUsd = 0,
    this.realMoneyResetAt,
    this.spendGroups = const [],
    this.periodUsage,
    this.isDev = false,
    this.plan = 'free',
    this.periodEnd,
    this.isTrial = false,
  });

  /// True while the paid plan is a store free trial; [periodEnd] is then the
  /// trial end.
  final bool isTrial;

  /// The account's plan from `GET /usage`: `free`, `plus`, `pro` or `max`.
  final String plan;

  /// End of the current paid period (renewal or expiry); null on the free plan.
  final DateTime? periodEnd;

  /// Whether the server's dev-view allowlist includes this account — the only
  /// accounts that get the Dev view (dollar figures + free reload). Dollar
  /// fields are only ever sent when this is true.
  final bool isDev;

  final int total;

  /// Tokens per feature: `chat`, `voice`, `matching`, `wiki`, `explore`,
  /// `reengage`, …
  final Map<String, int> features;

  /// Credits: the plan grant, credits added by top-ups, credits spent, and
  /// what remains (`grant + added − used`).
  final int creditGrant;
  final int creditsAdded;
  final int creditsUsed;
  final int creditsRemaining;

  /// How many tokens one credit is worth (for converting feature buckets).
  final int tokensPerCredit;

  /// Real infrastructure $ cost of the Gemini calls this account has driven
  /// — separate from [creditsRemaining]/[creditsTotal] (a display allowance,
  /// not money). Only counts usage recorded since the input/output token
  /// split shipped (2026-09-16); starts at 0 and only ever grows.
  final double costUsd;

  /// Real dollars spent since the user last hit Reset on the "Real money"
  /// tab — or, never reset, since per-conversation tracking began
  /// (2026-09-26; starts at exactly $0.00 for everyone, never a
  /// retro-estimate of lifetime spend — that lifetime figure is [costUsd]).
  /// The tab's big header figure.
  final double realMoneyUsd;

  /// Real dollars since tracking began, ignoring resets — the tab's smaller
  /// "all time" figure. Equal to [realMoneyUsd] until the first reset.
  final double realMoneyAllTimeUsd;

  /// When the user last reset the money tracker; null if never.
  final DateTime? realMoneyResetAt;

  /// Recent conversations/background groups with their real dollar cost,
  /// newest first (server-capped) — the "Real money" tab's list.
  final List<SpendGroup> spendGroups;

  /// Credits spent per feature over the period asked for with
  /// `usage(period:)`; null when no period was requested.
  final PeriodUsage? periodUsage;

  /// Lifetime credits this account has been granted (free grant + top-ups).
  /// Informational only — the balance the user sees is [creditsRemaining].
  int get creditsTotal => creditGrant + creditsAdded;

  /// Credits attributable to one feature bucket (tokens ÷ ratio, rounded up).
  int creditsForFeature(int tokens) => tokensPerCredit <= 0
      ? 0
      : (tokens + tokensPerCredit - 1) ~/ tokensPerCredit;

  /// Parse a `GET /usage` payload. Also the read side of the Plan page's
  /// last-known cache (offline-first) — [toMap] is its exact inverse.
  factory UsageSummary.fromMap(Map<String, dynamic> m) {
    final credits = (m['credits'] as Map?) ?? const {};
    final grant = (credits['grant'] as num?)?.toInt() ?? 0;
    final added = (credits['added'] as num?)?.toInt() ?? 0;
    final used = (credits['used'] as num?)?.toInt() ?? 0;
    return UsageSummary(
      total: (m['total'] as num?)?.toInt() ?? 0,
      features: ((m['features'] as Map?) ?? {}).map(
        (k, v) => MapEntry(k.toString(), (v as num).toInt()),
      ),
      creditGrant: grant,
      creditsAdded: added,
      creditsUsed: used,
      creditsRemaining:
          (credits['remaining'] as num?)?.toInt() ??
          (grant + added - used).clamp(0, grant + added),
      tokensPerCredit: (m['tokens_per_credit'] as num?)?.toInt() ?? 1000,
      isDev: m['is_dev'] == true,
      plan: (m['plan'] as String?) ?? 'free',
      periodEnd: DateTime.tryParse(m['period_end'] as String? ?? ''),
      isTrial: m['is_trial'] == true,
      costUsd: (m['cost_usd'] as num?)?.toDouble() ?? 0,
      // Since-reset first; the legacy key (which the server keeps equal to
      // since-reset) covers responses that predate the all-time/reset split.
      realMoneyUsd:
          (m['real_money_since_reset_usd'] as num?)?.toDouble() ??
          (m['real_money_usd'] as num?)?.toDouble() ??
          0,
      realMoneyAllTimeUsd:
          (m['real_money_all_time_usd'] as num?)?.toDouble() ??
          (m['real_money_usd'] as num?)?.toDouble() ??
          0,
      realMoneyResetAt: DateTime.tryParse(
        m['real_money_reset_at'] as String? ?? '',
      ),
      spendGroups: ((m['spend_groups'] as List?) ?? const [])
          .whereType<Map>()
          .map(SpendGroup.fromMap)
          .toList(),
      periodUsage: m['period_usage'] is Map
          ? PeriodUsage.fromMap(m['period_usage'] as Map)
          : null,
    );
  }

  /// Wire-form map (the exact inverse of [UsageSummary.fromMap]) for the
  /// Plan page's last-known cache.
  Map<String, dynamic> toMap() => {
    'total': total,
    'features': features,
    'credits': {
      'grant': creditGrant,
      'added': creditsAdded,
      'used': creditsUsed,
      'remaining': creditsRemaining,
    },
    'tokens_per_credit': tokensPerCredit,
    'is_dev': isDev,
    'plan': plan,
    'period_end': periodEnd?.toIso8601String(),
    'is_trial': isTrial,
    'cost_usd': costUsd,
    'real_money_since_reset_usd': realMoneyUsd,
    'real_money_all_time_usd': realMoneyAllTimeUsd,
    'real_money_reset_at': realMoneyResetAt?.toIso8601String(),
    'spend_groups': spendGroups.map((g) => g.toMap()).toList(),
    'period_usage': periodUsage?.toMap(),
  };
}

/// Credits spent per feature over one period, from `GET /usage?period=…`.
/// Credits only; [totalCredits] is the server-side sum of [features].
class PeriodUsage {
  const PeriodUsage({
    required this.period,
    required this.since,
    required this.features,
    required this.totalCredits,
  });

  factory PeriodUsage.fromMap(Map m) {
    final rows = [
      for (final r in (m['features'] as List?) ?? const [])
        if (r is Map)
          PeriodFeature(
            label: (r['label'] as String?) ?? 'Other',
            credits: (r['credits'] as num?)?.toInt() ?? 0,
          ),
    ];
    return PeriodUsage(
      period: (m['period'] as String?) ?? 'all',
      since: DateTime.tryParse(m['since'] as String? ?? ''),
      features: rows,
      totalCredits:
          (m['total_credits'] as num?)?.toInt() ??
          rows.fold<int>(0, (a, r) => a + r.credits),
    );
  }

  /// `since_credit`, `7d`, `30d` or `all`.
  final String period;

  /// When the period effectively starts; null when it has no lower bound.
  final DateTime? since;

  /// Highest spend first, with the user-facing label from the server.
  final List<PeriodFeature> features;
  final int totalCredits;

  /// Wire-form map (the inverse of [PeriodUsage.fromMap]) for the Plan
  /// page's last-known cache (offline-first).
  Map<String, dynamic> toMap() => {
    'period': period,
    'since': since?.toIso8601String(),
    'features': [
      for (final f in features) {'label': f.label, 'credits': f.credits},
    ],
    'total_credits': totalCredits,
  };
}

class PeriodFeature {
  const PeriodFeature({required this.label, required this.credits});

  final String label;
  final int credits;
}

/// One row on the Credits screen's "Real money" tab: a conversation (one
/// voice call / one chat session) or a background group (work with no
/// triggering conversation, grouped per calendar day), with its real dollar
/// cost and a feature → dollars breakdown. From `GET /usage`'s
/// `spend_groups`.
class SpendGroup {
  const SpendGroup({
    required this.id,
    required this.kind,
    this.sessionId = '',
    this.day = '',
    this.lastTs,
    this.events = 0,
    this.costUsd = 0,
    this.features = const {},
  });

  final String id;

  /// `voice` | `chat` | `background`.
  final String kind;
  final String sessionId;

  /// UTC calendar day of the group (`YYYY-MM-DD`).
  final String day;

  /// Newest recorded call in the group.
  final DateTime? lastTs;

  /// Recorded calls in the group (for voice: Live turns).
  final int events;
  final double costUsd;

  /// Feature → dollars within this group, e.g. `{chat: 0.012, wiki: 0.003}`.
  final Map<String, double> features;

  static SpendGroup fromMap(Map m) => SpendGroup(
    id: m['id'] as String? ?? '',
    kind: m['kind'] as String? ?? 'background',
    sessionId: m['session_id'] as String? ?? '',
    day: m['day'] as String? ?? '',
    lastTs: DateTime.tryParse(m['last_ts'] as String? ?? ''),
    events: (m['events'] as num?)?.toInt() ?? 0,
    costUsd: (m['cost_usd'] as num?)?.toDouble() ?? 0,
    features: ((m['features'] as Map?) ?? {}).map(
      (k, v) => MapEntry(k.toString(), (v as num).toDouble()),
    ),
  );

  /// Wire-form map (the inverse of [fromMap]) for the Plan page's
  /// last-known cache (offline-first).
  Map<String, dynamic> toMap() => {
    'id': id,
    'kind': kind,
    'session_id': sessionId,
    'day': day,
    'last_ts': lastTs?.toIso8601String(),
    'events': events,
    'cost_usd': costUsd,
    'features': features,
  };
}

/// `POST /check-compatibility` result.
class MatchScoreResult {
  const MatchScoreResult({
    required this.ok,
    required this.usageCapped,
    this.queued = false,
    this.score,
    this.matchId,
  });

  final bool ok;
  final bool usageCapped;

  /// Scoring is running server-side; poll `GET /match/{id}` or wait for the
  /// push. [score] is null in this case.
  final bool queued;
  final double? score;
  final String? matchId;
}

/// Live DM coaching for a thread (§6.9), from `POST /dm/assist`: suggestion
/// chips plus an optional one-line nudge, and a protective [safety] read on the
/// other person (§6.9.1). [mode] is `opener` for a brand-new thread or `coach`
/// once the conversation is underway; the UI treats both the same way. An empty
/// result (no chips, null tip, `none` safety) is the silent-degrade case.
class DmAssist {
  const DmAssist({
    this.mode = 'opener',
    this.chips = const [],
    this.tip,
    this.safety = DmSafety.none,
  });

  final String mode; // opener | coach
  final List<String> chips; // up to 4
  final String? tip; // short nudge above the composer, or null
  final DmSafety safety; // protective heads-up about the other person

  static const empty = DmAssist();

  factory DmAssist.fromJson(Map<String, dynamic> m) {
    final rawTip = (m['tip'] as String?)?.trim();
    return DmAssist(
      mode: (m['mode'] as String?)?.trim().isNotEmpty == true
          ? m['mode'] as String
          : 'opener',
      chips: ((m['chips'] as List?) ?? const [])
          .map((e) => e.toString().trim())
          .where((s) => s.isNotEmpty)
          .take(4)
          .toList(),
      tip: (rawTip == null || rawTip.isEmpty) ? null : rawTip,
      safety: DmSafety.fromJson(m['safety']),
    );
  }
}

/// A calm, protective read on how the *other* person is behaving in a DM
/// thread (§6.9.1). Advisory only — it never blocks sending. [level] is
/// `none` (nothing concerning — stay silent), `caution` (a gentle heads-up), or
/// `warning` (a clear concern). [reason] is a short supportive sentence written
/// to the user; [flags] are short pattern tags. The UI surfaces a safety note
/// only when [shouldSurface] (level is caution or warning). Parsing fails quiet:
/// anything missing or malformed, or a non-`none` level without a reason,
/// becomes a silent `none` so the app never shows an empty or invented alarm.
class DmSafety {
  const DmSafety({this.level = 'none', this.reason = '', this.flags = const []});

  final String level; // none | caution | warning
  final String reason; // short supportive heads-up, or '' when none
  final List<String> flags; // short pattern tags

  static const none = DmSafety();

  /// Show the safety note only for a genuine concern (>= caution) that carries
  /// something to say.
  bool get shouldSurface => level != 'none' && reason.isNotEmpty;

  factory DmSafety.fromJson(Object? raw) {
    if (raw is! Map) return none;
    final level = (raw['level'] as String?)?.trim().toLowerCase() ?? 'none';
    if (level != 'caution' && level != 'warning') return none;
    final reason = (raw['reason'] as String?)?.trim() ?? '';
    if (reason.isEmpty) return none;
    return DmSafety(
      level: level,
      reason: reason,
      flags: ((raw['flags'] as List?) ?? const [])
          .map((e) => e.toString().trim())
          .where((s) => s.isNotEmpty)
          .take(6)
          .toList(),
    );
  }
}

/// One cross-language DM translation, from `POST /dm/translate` (§6.12).
/// [translated] is the text rendered in the requested target language (or the
/// original, unchanged, when the backend could not translate — translation
/// never blocks the thread). [detectedSourceLang] is the language the original
/// was written in, as detected by the model; empty when unknown. When
/// [detectedSourceLang] equals the target (or [translated] equals the
/// original) the message was already in the reader's language and needs no
/// translation.
class DmTranslation {
  const DmTranslation({required this.translated, this.detectedSourceLang = ''});

  final String translated;
  final String detectedSourceLang;

  factory DmTranslation.fromJson(Map<String, dynamic> m) => DmTranslation(
        translated: (m['translated'] as String?)?.trim() ?? '',
        detectedSourceLang: (m['detected_source_lang'] as String?)?.trim() ?? '',
      );
}

/// Name + resolved photo URL for a user, from `POST /profiles/mini`.
class MiniProfile {
  const MiniProfile({
    required this.name,
    required this.photo,
    this.online = false,
  });
  final String name;
  final String photo;

  /// Touched the app in the last 5 minutes.
  final bool online;
}

/// One rubric dimension of a match score (§5.4).
class MatchDimension {
  const MatchDimension({
    required this.key,
    required this.label,
    required this.score, // 0..100
    required this.weight, // 0..1
    required this.rationale,
    required this.evidence,
    required this.confidence, // low | medium | high
    this.source = 'llm', // structured | llm | mixed
    this.coveredNodes = const [],
  });

  final String key;
  final String label;
  final double score;
  final double weight;
  final String rationale;
  final List<String> evidence;
  final String confidence;

  /// How this dimension's number was produced: `structured` = measured from
  /// the questionnaire answers, `llm` = estimated from the written profiles.
  final String source;

  /// The questionnaire node ids that fed a `structured` dimension.
  final List<String> coveredNodes;

  bool get isMeasured => source == 'structured';

  factory MatchDimension.fromMap(Map<String, dynamic> m) => MatchDimension(
    key: m['key'] as String? ?? '',
    label: m['label'] as String? ?? '',
    score: (m['score'] as num?)?.toDouble() ?? 0,
    weight: (m['weight'] as num?)?.toDouble() ?? 0,
    rationale: m['rationale'] as String? ?? '',
    evidence: (m['evidence'] as List? ?? const [])
        .map((e) => e.toString())
        .where((s) => s.isNotEmpty)
        .toList(),
    confidence: m['confidence'] as String? ?? 'low',
    source: m['source'] as String? ?? 'llm',
    coveredNodes: (m['covered_nodes'] as List? ?? const [])
        .map((e) => e.toString())
        .toList(),
  );
}

/// A hard dealbreaker the deterministic pass detected between the two people.
class MatchGateFailure {
  const MatchGateFailure({required this.label, required this.reason});

  final String label;
  final String reason;

  factory MatchGateFailure.fromMap(Map<String, dynamic> m) => MatchGateFailure(
    label: m['label'] as String? ?? '',
    reason: m['reason'] as String? ?? '',
  );
}

/// `GET /match/{id}` — the shareable match report for one pair.
class MatchReport {
  const MatchReport({
    required this.matchId,
    required this.score,
    required this.dimensions,
    required this.shared,
    required this.tensions,
    required this.missing,
    required this.explanation,
    required this.otherUid,
    required this.otherName,
    required this.otherPhoto,
    required this.myPhoto,
    this.mutual = false,
    this.scoreConfidence,
    this.confidenceNote = '',
    this.gateFailures = const [],
    this.method = '',
    this.taste,
  });

  final String matchId;
  final double? score;
  final List<MatchDimension> dimensions;
  final List<String> shared;
  final List<String> tensions;

  /// Topics the wikis didn't cover well enough to score confidently —
  /// what to fill in on the profiles to sharpen the number.
  final List<String> missing;
  final String explanation;
  final String otherUid;
  final String otherName;
  final String otherPhoto;
  final String myPhoto;

  /// A genuine MUTUAL match — both people liked each other
  /// (`matches/{id}.status == "mutual_interest"`). When false, this screen is
  /// only a compatibility preview and reads "Compatibility", not "Match".
  final bool mutual;

  /// 0..1 — how much to trust the number. High when both profiles are
  /// detailed and the dealbreaker gates had their data.
  final double? scoreConfidence;
  final String confidenceNote;

  /// Hard dealbreakers detected deterministically. Non-empty ⇒ the score is
  /// capped low.
  final List<MatchGateFailure> gateFailures;

  /// One-line note on how the score was built (structured vs. LLM).
  final String method;

  /// "Taste match" section between the two people (taste
  /// taste overlap + date ideas), or a no-Taste-page empty state. Null when
  /// the backend omitted the section (unexpected failure / unavailable).
  final TasteMatchLoad? taste;

  /// `high` / `medium` / `low`, from [scoreConfidence]. Empty when unknown.
  String get confidenceBand {
    final c = scoreConfidence;
    if (c == null) return '';
    if (c >= 0.66) return 'high';
    if (c >= 0.4) return 'medium';
    return 'low';
  }

  factory MatchReport.fromMap(Map<String, dynamic> m) {
    final other = (m['other'] as Map?) ?? const {};
    final me = (m['me'] as Map?) ?? const {};
    List<String> list(Object? v) => (v as List? ?? const [])
        .map((e) => e.toString())
        .where((s) => s.isNotEmpty)
        .toList();
    return MatchReport(
      matchId: m['match_id'] as String? ?? '',
      score: (m['score'] as num?)?.toDouble(),
      dimensions: (m['dimensions'] as List? ?? const [])
          .map(
            (e) => MatchDimension.fromMap((e as Map).cast<String, dynamic>()),
          )
          .toList(),
      shared: list(m['shared']),
      tensions: list(m['tensions']),
      missing: list(m['missing']),
      explanation: m['explanation'] as String? ?? '',
      otherUid: other['uid'] as String? ?? '',
      otherName: other['name'] as String? ?? '',
      otherPhoto: other['photo'] as String? ?? '',
      myPhoto: me['photo'] as String? ?? '',
      mutual: m['mutual'] == true,
      scoreConfidence: (m['score_confidence'] as num?)?.toDouble(),
      confidenceNote: m['confidence_note'] as String? ?? '',
      gateFailures: (m['gate_failures'] as List? ?? const [])
          .map(
            (e) => MatchGateFailure.fromMap((e as Map).cast<String, dynamic>()),
          )
          .toList(),
      method: m['method'] as String? ?? '',
      taste: TasteMatchLoad.fromReportValue(m['taste']),
    );
  }
}

class VoicePreset {
  const VoicePreset({required this.name, required this.description});
  final String name;
  final String description;
}

class DeepDiveLink {
  const DeepDiveLink({
    required this.url,
    required this.title,
    required this.isThem,
  });
  final String url;
  final String title;
  final String isThem; // likely | maybe | unclear
}

class DeepDiveResult {
  const DeepDiveResult({
    required this.usageCapped,
    required this.summary,
    required this.isSelf,
    required this.links,
    this.queued = false,
    this.reportId = '',
    this.subjectImage = '',
    this.toolLabel = '',
  });
  final bool usageCapped;

  /// The dive is running server-side and will land in chat history + a push
  /// when done — [summary] is empty. A cached dive comes back inline instead.
  final bool queued;
  final String summary;

  /// Id of the saved dive — reopenable via [ApiClient.deepDiveReport] and used
  /// as the `[deep_dive:<id>]` chat marker. Empty when the dive found nothing.
  final String reportId;
  final bool isSelf;
  final List<DeepDiveLink> links;

  /// Photo URL of the person this dive was about (empty for a self-dive).
  final String subjectImage;

  /// Kicker label to show on the resulting Ayma turn ("Researched X online").
  final String toolLabel;
}

/// `GET /deep-dive-report/{id}` — a stored web dive rendered on its own screen.
class DeepDiveFact {
  const DeepDiveFact({
    required this.id,
    required this.claim,
    required this.category,
    required this.sourceUrl,
    required this.confidence,
  });
  final String id;
  final String claim;
  final String category;
  final String sourceUrl;
  final String confidence; // high | medium | low

  factory DeepDiveFact.fromMap(Map m) => DeepDiveFact(
    id: m['id'] as String? ?? '',
    claim: m['claim'] as String? ?? '',
    category: m['category'] as String? ?? '',
    sourceUrl: m['source_url'] as String? ?? '',
    confidence: m['confidence'] as String? ?? '',
  );
}

/// A face-verified photo of the subject found on the open web.
class DeepDiveWebImage {
  const DeepDiveWebImage({
    required this.url,
    required this.sourcePage,
    required this.similarity,
    required this.verified,
  });
  final String url;
  final String sourcePage;
  final double? similarity;
  final bool verified;

  factory DeepDiveWebImage.fromMap(Map m) => DeepDiveWebImage(
    url: m['url'] as String? ?? '',
    sourcePage: m['source_page'] as String? ?? '',
    similarity: (m['similarity'] as num?)?.toDouble(),
    verified: m['verified'] == true,
  );
}

/// A social-media profile the dive tied to the subject by name and/or a
/// profile-photo face match. `confidence` is `high` (face-verified) or
/// `medium` (strong name match on independent sources).
class DeepDiveSocial {
  const DeepDiveSocial({
    required this.platform,
    required this.handle,
    required this.url,
    required this.displayName,
    required this.confidence,
    required this.verifiedBy,
  });

  final String
  platform; // instagram | x | linkedin | facebook | tiktok | github | youtube
  final String handle;
  final String url;
  final String displayName;
  final String confidence; // high | medium
  final List<String> verifiedBy; // face | name | link

  factory DeepDiveSocial.fromMap(Map m) => DeepDiveSocial(
    platform: (m['platform'] as String? ?? '').trim(),
    handle: (m['handle'] as String? ?? '').trim(),
    url: (m['url'] as String? ?? '').trim(),
    displayName: (m['display_name'] as String? ?? '').trim(),
    confidence: (m['confidence'] as String? ?? '').trim(),
    verifiedBy: (m['verified_by'] as List? ?? const [])
        .map((e) => '$e')
        .where((s) => s.isNotEmpty)
        .toList(),
  );
}

class DeepDiveReport {
  const DeepDiveReport({
    required this.name,
    required this.summary,
    required this.confidence,
    required this.caveats,
    required this.isSelf,
    required this.otherUid,
    required this.subjectImage,
    required this.facts,
    required this.links,
    required this.webImages,
    this.socialHandles = const [],
    this.runStatus = '',
  });

  final String name;
  final String summary;
  final String confidence;
  final String caveats;
  final bool isSelf;

  /// The uid of the person this dive is about (empty when it's a self-dive) —
  /// lets "Ask Ayma" hand her the pair context.
  final String otherUid;
  final String subjectImage;

  /// The caller's latest queued re-search on this report: `running`, `done`,
  /// `failed`, or empty when none. The server already turns a run stuck
  /// `running` past its timeout into `failed`.
  final String runStatus;
  final List<DeepDiveFact> facts;
  final List<DeepDiveLink> links;

  /// Photos of the subject found + face-matched online. `verified` ones are
  /// confident matches; unverified means the face check couldn't run.
  final List<DeepDiveWebImage> webImages;

  /// Social-media profiles the dive is confident belong to the subject.
  /// Empty when nothing cleared the confidence bar.
  final List<DeepDiveSocial> socialHandles;

  factory DeepDiveReport.fromMap(Map<String, dynamic> m) {
    final digest = (m['digest'] as Map?) ?? const {};
    return DeepDiveReport(
      name: (m['name'] as String?)?.trim().isNotEmpty == true
          ? m['name'] as String
          : (digest['name'] as String? ?? ''),
      summary: digest['summary'] as String? ?? '',
      confidence: digest['confidence'] as String? ?? '',
      caveats: digest['caveats'] as String? ?? '',
      isSelf: m['is_self'] == true,
      otherUid: m['target_uid'] as String? ?? '',
      subjectImage: m['subject_image'] as String? ?? '',
      runStatus: m['run_status'] as String? ?? '',
      facts: (digest['facts'] as List? ?? const [])
          .whereType<Map>()
          .map(DeepDiveFact.fromMap)
          .where((f) => f.claim.isNotEmpty)
          .toList(),
      links: (digest['links'] as List? ?? const [])
          .whereType<Map>()
          .map(
            (e) => DeepDiveLink(
              url: e['url'] as String? ?? '',
              title: e['title'] as String? ?? '',
              isThem: e['is_them'] as String? ?? 'unclear',
            ),
          )
          .where((l) => l.url.isNotEmpty)
          .toList(),
      webImages: (digest['web_images'] as List? ?? const [])
          .whereType<Map>()
          .map(DeepDiveWebImage.fromMap)
          .where((im) => im.url.isNotEmpty)
          .toList(),
      socialHandles: (digest['social_handles'] as List? ?? const [])
          .whereType<Map>()
          .map(DeepDiveSocial.fromMap)
          .where((s) => s.url.isNotEmpty)
          .toList(),
    );
  }
}

/// `GET /deep-dive/mine` — the caller's own current self-dive, a single
/// record (never a history list; a fresh self-dive always overwrites it).
class DeepDiveMine {
  const DeepDiveMine({
    required this.reportId,
    required this.summary,
    required this.confidence,
    this.createdAt,
  });

  final String reportId;
  final String summary;
  final String confidence;
  final String? createdAt;

  factory DeepDiveMine.fromMap(Map<String, dynamic> m) => DeepDiveMine(
    reportId: m['report_id'] as String? ?? '',
    summary: m['summary'] as String? ?? '',
    confidence: m['confidence'] as String? ?? '',
    createdAt: m['created_at'] as String?,
  );
}

// --- Face / body reports ---------------------------------------------------

double _asDouble(Object? v) {
  if (v is num) return v.toDouble();
  return double.tryParse('$v') ?? 0.0;
}

List<String> _asStringList(Object? v) => (v as List? ?? const [])
    .map((e) => '$e')
    .where((s) => s.isNotEmpty)
    .toList();

class FaceFeature {
  const FaceFeature({
    required this.name,
    required this.score,
    required this.note,
  });
  final String name;
  final double score;
  final String note;

  factory FaceFeature.fromMap(Map<String, dynamic> m) => FaceFeature(
    name: m['name'] as String? ?? '',
    score: _asDouble(m['score']),
    note: m['note'] as String? ?? '',
  );
}

class FaceRecommendation {
  const FaceRecommendation({required this.category, required this.text});
  final String category;
  final String text;

  factory FaceRecommendation.fromMap(Map<String, dynamic> m) =>
      FaceRecommendation(
        category: m['category'] as String? ?? '',
        text: m['text'] as String? ?? '',
      );
}

class FaceReport {
  const FaceReport({
    required this.usable,
    required this.overallScore,
    required this.verdict,
    required this.verdictNote,
    required this.features,
    required this.quickFacts,
    required this.strengths,
    required this.improvements,
    required this.recommendations,
    this.sourcePhotos = const [],
  });

  final bool usable;
  final double overallScore;
  final String verdict;
  final String verdictNote;
  final List<FaceFeature> features;
  final Map<String, String> quickFacts;
  final List<String> strengths;
  final List<String> improvements;
  final List<FaceRecommendation> recommendations;

  /// Storage path(s) of the photo(s) this report was run on — always at most
  /// one for a face report. Empty for a report stored before this field
  /// existed; callers must degrade gracefully (no photo shown), not crash.
  final List<String> sourcePhotos;

  factory FaceReport.fromMap(Map<String, dynamic> m) => FaceReport(
    usable: m['usable'] != false,
    overallScore: _asDouble(m['overall_score']),
    verdict: m['verdict'] as String? ?? '',
    verdictNote: m['verdict_note'] as String? ?? '',
    features: (m['features'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => FaceFeature.fromMap(e.cast<String, dynamic>()))
        .where((f) => f.name.isNotEmpty)
        .toList(),
    quickFacts: ((m['quick_facts'] as Map?) ?? const {}).map(
      (k, v) => MapEntry('$k', '$v'),
    )..removeWhere((_, v) => v.isEmpty),
    strengths: _asStringList(m['strengths']),
    improvements: _asStringList(m['improvements']),
    recommendations: (m['recommendations'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => FaceRecommendation.fromMap(e.cast<String, dynamic>()))
        .where((r) => r.text.isNotEmpty)
        .toList(),
    sourcePhotos: _asStringList(m['source_photos']),
  );
}

class FaceReportResult {
  const FaceReportResult({
    required this.usageCapped,
    required this.report,
    required this.reportId,
  });
  final bool usageCapped;
  final FaceReport? report;
  final String reportId;
}

class BodyFeature {
  const BodyFeature({
    required this.name,
    required this.score,
    required this.note,
  });
  final String name;
  final double score;
  final String note;

  factory BodyFeature.fromMap(Map<String, dynamic> m) => BodyFeature(
    name: m['name'] as String? ?? '',
    score: _asDouble(m['score']),
    note: m['note'] as String? ?? '',
  );
}

class BodyRecommendation {
  const BodyRecommendation({required this.category, required this.text});
  final String category;
  final String text;

  factory BodyRecommendation.fromMap(Map<String, dynamic> m) =>
      BodyRecommendation(
        category: m['category'] as String? ?? '',
        text: m['text'] as String? ?? '',
      );
}

class BodyReport {
  const BodyReport({
    required this.usable,
    required this.overallScore,
    required this.verdict,
    required this.verdictNote,
    required this.features,
    required this.quickFacts,
    required this.strengths,
    required this.improvements,
    required this.recommendations,
    this.sourcePhotos = const [],
  });

  final bool usable;
  final double overallScore;
  final String verdict;
  final String verdictNote;
  final List<BodyFeature> features;
  final Map<String, String> quickFacts;
  final List<String> strengths;
  final List<String> improvements;
  final List<BodyRecommendation> recommendations;

  /// Storage path(s) of the photo(s) this report was run on — always at most
  /// one for a body report. Empty for a report stored before this field
  /// existed; callers must degrade gracefully (no photo shown), not crash.
  final List<String> sourcePhotos;

  factory BodyReport.fromMap(Map<String, dynamic> m) => BodyReport(
    usable: m['usable'] != false,
    overallScore: _asDouble(m['overall_score']),
    verdict: m['verdict'] as String? ?? '',
    verdictNote: m['verdict_note'] as String? ?? '',
    features: (m['features'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => BodyFeature.fromMap(e.cast<String, dynamic>()))
        .where((f) => f.name.isNotEmpty)
        .toList(),
    quickFacts: ((m['quick_facts'] as Map?) ?? const {}).map(
      (k, v) => MapEntry('$k', '$v'),
    )..removeWhere((_, v) => v.isEmpty),
    strengths: _asStringList(m['strengths']),
    improvements: _asStringList(m['improvements']),
    recommendations: (m['recommendations'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => BodyRecommendation.fromMap(e.cast<String, dynamic>()))
        .where((r) => r.text.isNotEmpty)
        .toList(),
    sourcePhotos: _asStringList(m['source_photos']),
  );
}

class BodyReportResult {
  const BodyReportResult({
    required this.usageCapped,
    required this.report,
    required this.reportId,
  });
  final bool usageCapped;
  final BodyReport? report;
  final String reportId;
}

/// `GET /skills/report/{kind}/{id}` result — the stored report dict plus when
/// it was produced. Parse [report] with [FaceReport.fromMap] or
/// [BodyReport.fromMap] depending on the marker kind.
class SkillReport {
  const SkillReport({
    required this.report,
    required this.createdAt,
    this.imagePath = '',
  });
  final Map<String, dynamic> report;
  final String? createdAt;

  /// Storage path of the analysed photo, embedded in the report card.
  final String imagePath;
}

/// Result of `GET /physical-attributes` and `POST /physical-attributes/refresh`.
class PhysicalAttrsResult {
  const PhysicalAttrsResult({
    this.usageCapped = false,
    this.summary = '',
    this.attributes = const [],
    this.photoCount = 0,
    this.updatedAt,
    this.id = '',
  });

  /// True when the caller is out of credits — the refresh didn't run.
  final bool usageCapped;

  /// A short human line ("Physical profile — hair: black (from photos); …").
  final String summary;

  /// Known, source-tagged fields in a stable display order.
  final List<PhysicalAttribute> attributes;
  final int photoCount;
  final String? updatedAt;

  /// Stable id of the re-openable report — a `physical_reports` doc id after an
  /// explicit run, else `current`. Empty only when the record was never built.
  final String id;

  factory PhysicalAttrsResult.fromMap(Map<String, dynamic> m) {
    final record = m['record'] as Map<String, dynamic>?;
    return PhysicalAttrsResult(
      usageCapped: m['usage_capped'] == true,
      summary: m['summary'] as String? ?? '',
      attributes: PhysicalAttribute.listFrom(
        (m['fields'] as Map<String, dynamic>?) ??
            (record?['fields'] as Map<String, dynamic>?),
      ),
      photoCount:
          (m['photo_count'] as num?)?.toInt() ??
          (record?['photo_count'] as num?)?.toInt() ??
          0,
      updatedAt: record?['updated_at'] as String?,
      id: m['id'] as String? ?? '',
    );
  }
}

/// A stored physical-attributes report (`GET /physical-attributes-report/{id}`),
/// re-opened from a `[physical:<id>]` chat marker or the Skills-screen history.
class PhysicalReport {
  const PhysicalReport({
    required this.id,
    this.summary = '',
    this.photoCount = 0,
    this.attributes = const [],
    this.createdAt,
  });

  final String id;
  final String summary;
  final int photoCount;

  /// Known, source-tagged attributes in a stable display order.
  final List<PhysicalAttribute> attributes;
  final String? createdAt;

  List<PhysicalAttribute> get stated =>
      attributes.where((a) => a.isStated).toList();
  List<PhysicalAttribute> get fromPhotos =>
      attributes.where((a) => !a.isStated).toList();

  factory PhysicalReport.fromMap(Map<String, dynamic> m) => PhysicalReport(
    id: m['id'] as String? ?? '',
    summary: m['summary'] as String? ?? '',
    photoCount: (m['photo_count'] as num?)?.toInt() ?? 0,
    attributes: PhysicalAttribute.listFrom(
      m['fields'] as Map<String, dynamic>?,
    ),
    createdAt: m['created_at'] as String?,
  );
}

/// `{hasFacePhoto, hasBodyPhoto, hasFittedBodyPhoto}` from
/// `GET /appearance/coverage` — whether the user's current grid has a usable
/// face shot, a usable body shot (upper body or more — full-length isn't
/// required), and (of any usable body shot) one that isn't tagged as
/// loose/baggy clothing.
class AppearanceCoverage {
  const AppearanceCoverage({
    this.hasFacePhoto = false,
    this.hasBodyPhoto = false,
    this.hasFittedBodyPhoto = false,
  });

  final bool hasFacePhoto;
  final bool hasBodyPhoto;
  final bool hasFittedBodyPhoto;
}

/// One grid photo eligible for an Appearance axis — its `user_media` id, a
/// directly-loadable thumbnail URL, and the per-photo people/shot signals the
/// pre-run sheet uses to decide its pre-check. Returned by
/// `GET /appearance/eligibility`.
class EligiblePhoto {
  const EligiblePhoto({
    required this.mediaId,
    required this.url,
    this.personCount = 0,
    this.multiPerson = false,
    this.showsFace = false,
    this.showsBody = false,
    this.autoSelect = true,
  });

  final String mediaId;
  final String url;

  /// Coarse people count from the server: 1 = solo shot of the user, 2 = a
  /// group (two or more people), 0 = unknown / untagged.
  final int personCount;

  /// True when the photo has more than one person — such a photo is never
  /// pre-checked (analysis needs solo shots of the user).
  final bool multiPerson;

  final bool showsFace;
  final bool showsBody;

  /// Whether the sheet should PRE-CHECK this photo for its axis. Server-driven
  /// (`person_count == 1` and the photo actually shows that axis). Photos the
  /// user adds in-sheet default to `true`. The user can still toggle any photo.
  final bool autoSelect;

  factory EligiblePhoto.fromMap(Map<String, dynamic> m) => EligiblePhoto(
        mediaId: m['media_id'] as String? ?? '',
        url: m['url'] as String? ?? '',
        personCount: (m['person_count'] as num?)?.toInt() ?? 0,
        multiPerson: m['multi_person'] == true,
        showsFace: m['shows_face'] == true,
        showsBody: m['shows_body'] == true,
        // Default true so a payload without the field (older server) keeps the
        // old "all pre-checked" behaviour; the server now sends it explicitly.
        autoSelect: m['auto_select'] as bool? ?? true,
      );
}

/// `GET /appearance/eligibility` — the caller's current grid photos grouped by
/// which Appearance axis each is eligible for, so the pre-run sheet can show
/// the Face and Body photo groups as thumbnails and let the user pick or skip
/// per axis. A photo can appear in both groups (a full body with a clear face)
/// or neither (a group shot).
class AppearanceEligibility {
  const AppearanceEligibility({
    this.face = const [],
    this.body = const [],
    this.hasFacePhoto = false,
    this.hasBodyPhoto = false,
  });

  final List<EligiblePhoto> face;
  final List<EligiblePhoto> body;
  final bool hasFacePhoto;
  final bool hasBodyPhoto;

  static List<EligiblePhoto> _group(dynamic v) => (v as List? ?? const [])
      .whereType<Map>()
      .map((e) => EligiblePhoto.fromMap(e.cast<String, dynamic>()))
      .where((p) => p.url.isNotEmpty && p.mediaId.isNotEmpty)
      .toList();

  factory AppearanceEligibility.fromMap(Map<String, dynamic> m) =>
      AppearanceEligibility(
        face: _group(m['face']),
        body: _group(m['body']),
        hasFacePhoto: m['has_face_photo'] == true,
        hasBodyPhoto: m['has_body_photo'] == true,
      );
}

/// The unified Appearance report (`GET /appearance/report/{id}`,
/// `POST /appearance/report`): structured attributes plus an honest face and
/// physique read. A face / body section is `null` with a non-empty status
/// (`needs_face_photo` / `needs_body_photo`) when coverage was missing.
class AppearanceReport {
  const AppearanceReport({
    required this.id,
    this.createdAt,
    this.attributes = const [],
    this.attributesSummary = '',
    this.attributesStatus = '',
    this.attributesSourcePhotos = const [],
    this.face,
    this.faceStatus = '',
    this.body,
    this.bodyStatus = '',
    this.photoCount = 0,
    this.scoreValue,
    this.scoreBasis = '',
    this.findingHistory = const {},
    this.faceCategoryStatus = '',
    this.bodyCategoryStatus = '',
  });

  final String id;
  final String? createdAt;

  /// Known, source-tagged physical attributes in a stable display order.
  final List<PhysicalAttribute> attributes;
  final String attributesSummary;

  /// `` when produced, else `needs_photo`.
  final String attributesStatus;

  /// Storage paths of every photo that fed the attributes read. Empty for a
  /// report stored before this field existed.
  final List<String> attributesSourcePhotos;

  final FaceReport? face;

  /// `` when produced, else `needs_face_photo`.
  final String faceStatus;

  final BodyReport? body;

  /// `` when produced, else `needs_body_photo`.
  final String bodyStatus;

  final int photoCount;

  /// The headline 0-10 score, averaged across whichever of face/body are
  /// available. `null` when neither is — see [scoreBasis] for why.
  final double? scoreValue;

  /// A one-line explanation of what [scoreValue] is derived from (or, when
  /// null, what's missing to compute one).
  final String scoreBasis;

  /// Per-finding correction history, keyed by finding id (a physical-attribute
  /// field name, or `face` / `body`) — newest last, capped server-side.
  /// Additive; empty for a report with no corrections yet.
  final Map<String, List<Map<String, dynamic>>> findingHistory;

  List<PhysicalAttribute> get statedAttributes =>
      attributes.where((a) => a.isStated).toList();
  List<PhysicalAttribute> get photoAttributes =>
      attributes.where((a) => !a.isStated).toList();

  /// Per-axis run outcome from the last run: `ran` | `skipped` |
  /// `no_eligible_photo` (empty for a report stored before this field existed).
  /// A `skipped` or `no_eligible_photo` axis is "not available" — the report
  /// shows an add-photo prompt for it, never a bogus 0-score section.
  final String faceCategoryStatus;
  final String bodyCategoryStatus;

  bool get faceSkipped => faceCategoryStatus == 'skipped';
  bool get bodySkipped => bodyCategoryStatus == 'skipped';

  /// How many times [findingId] has been corrected, if any.
  int correctionCountFor(String findingId) =>
      findingHistory[findingId]?.length ?? 0;

  factory AppearanceReport.fromMap(Map<String, dynamic> m) {
    final attrs =
        (m['attributes'] as Map?)?.cast<String, dynamic>() ?? const {};
    final face = (m['face'] as Map?)?.cast<String, dynamic>() ?? const {};
    final body = (m['body'] as Map?)?.cast<String, dynamic>() ?? const {};
    final faceStatus = face['status'] as String? ?? '';
    final bodyStatus = body['status'] as String? ?? '';
    final score = (m['score'] as Map?)?.cast<String, dynamic>() ?? const {};
    final history =
        (m['finding_history'] as Map?)?.cast<String, dynamic>() ?? const {};
    final cat =
        (m['category_status'] as Map?)?.cast<String, dynamic>() ?? const {};
    return AppearanceReport(
      id: m['id'] as String? ?? '',
      createdAt: m['created_at'] as String?,
      attributes: PhysicalAttribute.listFrom(
        (attrs['record'] as Map?)?.cast<String, dynamic>(),
      ),
      attributesSummary: attrs['summary'] as String? ?? '',
      attributesStatus: attrs['status'] as String? ?? '',
      attributesSourcePhotos: _asStringList(attrs['source_photos']),
      face: faceStatus.isEmpty && face.isNotEmpty
          ? FaceReport.fromMap(face)
          : null,
      faceStatus: faceStatus,
      body: bodyStatus.isEmpty && body.isNotEmpty
          ? BodyReport.fromMap(body)
          : null,
      bodyStatus: bodyStatus,
      photoCount: (m['photo_count'] as num?)?.toInt() ?? 0,
      scoreValue: (score['value'] as num?)?.toDouble(),
      scoreBasis: score['basis'] as String? ?? '',
      findingHistory: history.map(
        (k, v) => MapEntry(
          k,
          (v as List? ?? const [])
              .whereType<Map>()
              .map((e) => e.cast<String, dynamic>())
              .toList(),
        ),
      ),
      faceCategoryStatus: cat['face'] as String? ?? '',
      bodyCategoryStatus: cat['body'] as String? ?? '',
    );
  }
}

/// Result of `POST /appearance/report`.
class AppearanceReportResult {
  const AppearanceReportResult({
    required this.usageCapped,
    required this.reportId,
    required this.report,
  });
  final bool usageCapped;
  final String reportId;
  final AppearanceReport? report;
}

/// One row of `GET /appearance/history` — a past Appearance run, or a
/// pre-merge per-skill report surfaced read-only ([legacy] true).
class AppearanceHistoryRow {
  const AppearanceHistoryRow({
    required this.id,
    this.createdAt,
    this.hasFace = false,
    this.hasBody = false,
    this.summary = '',
    this.legacy = false,
    this.kind = 'appearance',
  });

  final String id;
  final String? createdAt;
  final bool hasFace;
  final bool hasBody;
  final String summary;
  final bool legacy;

  /// `appearance` | `face` | `body` | `physical`.
  final String kind;

  factory AppearanceHistoryRow.fromMap(Map<String, dynamic> m) =>
      AppearanceHistoryRow(
        id: m['id'] as String? ?? '',
        createdAt: m['created_at'] as String?,
        hasFace: m['has_face'] == true,
        hasBody: m['has_body'] == true,
        summary: m['summary'] as String? ?? '',
        legacy: m['legacy'] == true,
        kind: m['kind'] as String? ?? 'appearance',
      );
}

/// The 1–5 (or arbitrary min/max) scale a `kind == 'scale'` [QuestionNode]
/// asks on. [minLabel] / [maxLabel] are the human anchors for each end.
class QuestionScale {
  const QuestionScale({
    this.min = 1,
    this.max = 5,
    this.minLabel = '',
    this.maxLabel = '',
  });

  final int min;
  final int max;
  final String minLabel;
  final String maxLabel;

  factory QuestionScale.fromMap(Map<String, dynamic> m) => QuestionScale(
    min: (m['min'] as num?)?.toInt() ?? 1,
    max: (m['max'] as num?)?.toInt() ?? 5,
    minLabel: (m['min_label'] ?? m['minLabel']) as String? ?? '',
    maxLabel: (m['max_label'] ?? m['maxLabel']) as String? ?? '',
  );
}

/// One node of the profile questionnaire tree — a single thing Ayma tries to
/// learn about the user. Appears both in `GET /questionnaire` (`nodes`) and in
/// the `next` list of `GET /completeness`. There is no "submit an answer" API:
/// Ayma captures the answer in conversation via a skill, so the client's job is
/// to show [status] and route the user into a chat on this topic.
class QuestionNode {
  const QuestionNode({
    required this.id,
    this.pageType = 'misc',
    this.branch = 'all',
    this.label = '',
    this.kind = 'text',
    this.options = const [],
    this.scale,
    this.weight = 0,
    this.hardFilter = false,
    this.datingRelevant = false,
    this.aymaPrompt = '',
    this.tier = 'core',
    this.status = 'missing',
    this.value,
    this.source,
    this.unlocked = true,
  });

  final String id;
  final String pageType;

  /// `all`, or an intent gate (`casual` / `long_term` / `nikah`).
  final String branch;
  final String label;

  /// `enum` | `scale` | `text` | `bool` | … — how the value is shaped.
  final String kind;

  /// Choices for `kind == 'enum'`.
  final List<String> options;

  /// The range for `kind == 'scale'` (null otherwise).
  final QuestionScale? scale;

  final int weight;
  final bool hardFilter;
  final bool datingRelevant;

  /// A one-line hint of what Ayma should actually draw out here.
  final String aymaPrompt;

  /// `core` (a section's first, essential questions) | `deep` (finer detail
  /// that only opens once the section's core is covered). Older backends omit
  /// this — default `core` so everything still renders.
  final String tier;

  /// `covered` | `partial` | `missing`.
  final String status;

  /// The known value, when [status] isn't `missing`.
  final String? value;

  /// Where a known value came from: `profile` | `stated` | `inferred` | `wiki`.
  final String? source;

  /// Whether this node is currently reachable in the progressive-disclosure
  /// flow — its section is unlocked and either it's `core` or the section's
  /// core is done. Older backends omit this — default `true`.
  final bool unlocked;

  bool get isCore => tier != 'deep';
  bool get isCovered => status == 'covered';
  bool get isPartial => status == 'partial';
  bool get isMissing => !isCovered && !isPartial;

  factory QuestionNode.fromMap(Map<String, dynamic> m) => QuestionNode(
    id: m['id'] as String? ?? '',
    pageType: m['page_type'] as String? ?? 'misc',
    branch: m['branch'] as String? ?? 'all',
    label: m['label'] as String? ?? '',
    kind: m['kind'] as String? ?? 'text',
    options: ((m['options'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList(),
    scale: m['scale'] is Map
        ? QuestionScale.fromMap((m['scale'] as Map).cast<String, dynamic>())
        : null,
    weight: (m['weight'] as num?)?.toInt() ?? 0,
    hardFilter: m['hard_filter'] == true,
    datingRelevant: m['dating_relevant'] == true,
    aymaPrompt: m['ayma_prompt'] as String? ?? '',
    tier: m['tier'] as String? ?? 'core',
    status: m['status'] as String? ?? 'missing',
    value: m['value']?.toString(),
    source: m['source'] as String?,
    unlocked: m['unlocked'] is bool ? m['unlocked'] as bool : true,
  );
}

/// One section of the profile-completeness breakdown (`GET /completeness`).
class CompletenessSection {
  const CompletenessSection({
    required this.pageType,
    this.label = '',
    this.pct = 0,
    this.answered = 0,
    this.total = 0,
    this.unlocked = true,
    this.coreTotal = 0,
    this.coreAnswered = 0,
    this.priority = 0,
  });

  final String pageType;
  final String label;
  final int pct;
  final int answered;
  final int total;

  /// Whether the section is open in the progressive-disclosure flow. Older
  /// backends omit this — default `true` so every section renders.
  final bool unlocked;

  /// The section's `core` (essential) node counts. `deep` nodes only surface
  /// once `coreAnswered >= coreTotal`.
  final int coreTotal;
  final int coreAnswered;

  /// Highest node weight in the section — its ordering rank.
  final int priority;

  /// The section's essential questions are all covered, so its deeper detail
  /// is now in play.
  bool get coreComplete => coreTotal <= 0 || coreAnswered >= coreTotal;

  factory CompletenessSection.fromMap(Map<String, dynamic> m) =>
      CompletenessSection(
        pageType: m['page_type'] as String? ?? 'misc',
        label: m['label'] as String? ?? '',
        pct: (m['pct'] as num?)?.toInt() ?? 0,
        answered: (m['answered'] as num?)?.toInt() ?? 0,
        total: (m['total'] as num?)?.toInt() ?? 0,
        unlocked: m['unlocked'] is bool ? m['unlocked'] as bool : true,
        coreTotal: (m['core_total'] as num?)?.toInt() ?? 0,
        coreAnswered: (m['core_answered'] as num?)?.toInt() ?? 0,
        priority: (m['priority'] as num?)?.toInt() ?? 0,
      );
}

/// `GET /completeness` — how filled-in the user's profile is (0–100), their
/// stated relationship intent, a per-section breakdown, and the highest-value
/// gaps ([next]) to fill. Ayma fills these in conversation.
class Completeness {
  const Completeness({
    this.score = 0,
    this.visibleScore = 0,
    this.complete = false,
    this.intent = 'long_term',
    this.intentSet = false,
    this.sections = const [],
    this.next = const [],
    this.updatedAt,
  });

  final int score;

  /// Progress over just the currently-unlocked nodes (0–100). Falls back to
  /// [score] when an older backend doesn't send it.
  final int visibleScore;

  /// `casual` | `long_term` | `nikah`.
  final String intent;

  /// False when the user hasn't picked one yet ("Not sure yet").
  final bool intentSet;

  final List<CompletenessSection> sections;

  /// The next few highest-value questions to cover.
  final List<QuestionNode> next;

  /// Every node in today's question tree is fully answered — there's nothing
  /// left to ask right now. Independent of [score], which tops out below 100
  /// even here: there's always more Ayma could learn than the fixed question
  /// set covers.
  final bool complete;

  final String? updatedAt;

  /// True once nothing is left in today's question set. Prefers the
  /// server's explicit [complete] flag; falls back to a literal 100 score
  /// for a stale cached response from before that flag existed.
  bool get isComplete => complete || score >= 100;

  factory Completeness.fromMap(Map<String, dynamic> m) => Completeness(
    score: (m['score'] as num?)?.toInt() ?? 0,
    visibleScore:
        (m['visible_score'] as num?)?.toInt() ??
        (m['score'] as num?)?.toInt() ??
        0,
    complete: m['complete'] == true,
    intent: m['intent'] as String? ?? 'long_term',
    intentSet: m['intent_set'] == true,
    sections: ((m['sections'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => CompletenessSection.fromMap(e.cast<String, dynamic>()))
        .toList(),
    next: ((m['next'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => QuestionNode.fromMap(e.cast<String, dynamic>()))
        .where((n) => n.id.isNotEmpty)
        .toList(),
    updatedAt: m['updated_at'] as String?,
  );
}

/// `GET /questionnaire` — the full question tree with per-node coverage status
/// for the signed-in user.
class QuestionnaireTree {
  const QuestionnaireTree({
    this.intent = 'long_term',
    this.intentSet = false,
    this.score = 0,
    this.visibleScore = 0,
    this.nodes = const [],
  });

  final String intent;
  final bool intentSet;
  final int score;

  /// Progress over just the currently-unlocked nodes (0–100). Falls back to
  /// [score] on an older backend.
  final int visibleScore;
  final List<QuestionNode> nodes;

  /// The nodes grouped by `page_type`, in first-seen order.
  Map<String, List<QuestionNode>> get byPageType {
    final out = <String, List<QuestionNode>>{};
    for (final n in nodes) {
      (out[n.pageType] ??= <QuestionNode>[]).add(n);
    }
    return out;
  }

  factory QuestionnaireTree.fromMap(Map<String, dynamic> m) =>
      QuestionnaireTree(
        intent: m['intent'] as String? ?? 'long_term',
        intentSet: m['intent_set'] == true,
        score: (m['score'] as num?)?.toInt() ?? 0,
        visibleScore:
            (m['visible_score'] as num?)?.toInt() ??
            (m['score'] as num?)?.toInt() ??
            0,
        nodes: ((m['nodes'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => QuestionNode.fromMap(e.cast<String, dynamic>()))
            .where((n) => n.id.isNotEmpty)
            .toList(),
      );
}

/// One photo Ayma holds of the user, from `GET /wiki/ai-view`.
class AiNotePhoto {
  const AiNotePhoto({
    required this.url,
    required this.source,
    this.id = '',
    this.context = '',
    this.isUser = '',
    this.sourcePage = '',
    this.deleted = false,
  });

  /// Stable id (a hash of the URL) — used to address this exact photo for
  /// notes / hide / publish without the caller needing its own id scheme.
  final String id;

  final String url;

  /// `profile` (a grid photo), `chat` (sent in the Ayma chat), or `web`
  /// (found on the open web during a "search me" deep dive).
  final String source;

  /// What Ayma knows this photo is (a caption, or something recorded from a
  /// "Chat about it" correction) — read-only; the only way to add or correct
  /// it is by chatting with Ayma about the photo, not a text box.
  final String context;

  /// `''` (not checked yet), `'yes'` or `'no'` — Ayma's own face-match
  /// verdict against her reference photos of the user, not a manual toggle.
  final String isUser;

  /// For a `web` photo: the page it was found on.
  final String sourcePage;

  /// The user deleted this photo — it stays known to Ayma (AI notes tab
  /// only) rather than disappearing outright.
  final bool deleted;

  bool get isProfile => source == 'profile';

  AiNotePhoto copyWith({String? context, String? isUser}) => AiNotePhoto(
    id: id,
    url: url,
    source: source,
    context: context ?? this.context,
    isUser: isUser ?? this.isUser,
    sourcePage: sourcePage,
    deleted: deleted,
  );
}

/// The AI-notes debug view: the compiled wiki text plus every photo Ayma has.
class AiNotes {
  const AiNotes({required this.text, this.photos = const []});

  final String text;
  final List<AiNotePhoto> photos;
}

class VoicePresets {
  const VoicePresets({
    required this.presets,
    required this.current,
    required this.defaultName,
    this.currentLanguage = '',
    this.languageExamples = const [],
  });
  final List<VoicePreset> presets;
  final String current;
  final String defaultName;

  /// Ayma's current default accent/language — free text ("Malayalam mixed
  /// with English", "a soft Southern US accent"), set here or learned from
  /// conversation. Empty = plain English. (§13.3)
  final String currentLanguage;

  /// Example strings for the settings text-field placeholder.
  final List<String> languageExamples;

  /// The effective voice selection: the user's choice, or the default.
  String get effective => current.isNotEmpty ? current : defaultName;
}

// --- Voice ENGINE catalog (§13.9) ---------------------------------------
// The developer "Voice engine" control + the user-facing "Ayma's voice"
// screen read this from `GET /voice/engines`. Parsers tolerate missing fields.

/// One selectable voice (a realtime model's or a TTS provider's).
class CatalogVoice {
  const CatalogVoice({
    required this.id,
    required this.label,
    this.description = '',
    this.gender = '',
  });
  final String id;
  final String label;
  final String description;
  final String gender;

  factory CatalogVoice.fromMap(Map m) => CatalogVoice(
        id: m['id'] as String? ?? '',
        label: (m['label'] as String?)?.isNotEmpty == true
            ? m['label'] as String
            : (m['id'] as String? ?? ''),
        description: m['description'] as String? ?? '',
        gender: m['gender'] as String? ?? '',
      );
}

/// A language/accent option (empty code = plain English default).
class CatalogLanguage {
  const CatalogLanguage({required this.code, required this.label});
  final String code;
  final String label;
  factory CatalogLanguage.fromMap(Map m) => CatalogLanguage(
        code: m['code'] as String? ?? '',
        label: m['label'] as String? ?? (m['code'] as String? ?? ''),
      );
}

/// A realtime model (Gemini Live, OpenAI Realtime, …) with its own voices.
class RealtimeModel {
  const RealtimeModel({
    required this.id,
    required this.label,
    this.provider = '',
    this.available = true,
    this.requiresSecret = '',
    this.supportsAccent = false,
    this.voices = const [],
    this.languages = const [],
  });
  final String id;
  final String label;
  final String provider;
  final bool available;
  final String requiresSecret;

  /// Whether this model honours a free-text accent (§13.9).
  final bool supportsAccent;
  final List<CatalogVoice> voices;
  final List<CatalogLanguage> languages;

  factory RealtimeModel.fromMap(Map m) => RealtimeModel(
        id: m['id'] as String? ?? '',
        label: m['label'] as String? ?? (m['id'] as String? ?? ''),
        provider: m['provider'] as String? ?? '',
        available: m['available'] as bool? ?? true,
        requiresSecret: m['requires_secret'] as String? ?? '',
        supportsAccent: m['supports_accent'] as bool? ?? false,
        voices: ((m['voices'] as List?) ?? const [])
            .map((e) => CatalogVoice.fromMap(e as Map))
            .toList(),
        languages: ((m['languages'] as List?) ?? const [])
            .map((e) => CatalogLanguage.fromMap(e as Map))
            .toList(),
      );
}

/// A cascade component (brain/STT/TTS). TTS carries its voices + languages.
class VoiceComponent {
  const VoiceComponent({
    required this.id,
    required this.label,
    this.provider = '',
    this.available = true,
    this.requiresSecret = '',
    this.supportsAccent = false,
    this.voices = const [],
    this.languages = const [],
  });
  final String id;
  final String label;
  final String provider;
  final bool available;
  final String requiresSecret;

  /// Whether this component's provider honours a free-text accent (TTS only;
  /// §13.9). Fixed-voice cascade TTS providers report false.
  final bool supportsAccent;
  final List<CatalogVoice> voices;
  final List<CatalogLanguage> languages;

  factory VoiceComponent.fromMap(Map m) => VoiceComponent(
        id: m['id'] as String? ?? '',
        label: m['label'] as String? ?? (m['id'] as String? ?? ''),
        provider: m['provider'] as String? ?? '',
        available: m['available'] as bool? ?? true,
        requiresSecret: m['requires_secret'] as String? ?? '',
        supportsAccent: m['supports_accent'] as bool? ?? false,
        voices: ((m['voices'] as List?) ?? const [])
            .map((e) => CatalogVoice.fromMap(e as Map))
            .toList(),
        languages: ((m['languages'] as List?) ?? const [])
            .map((e) => CatalogLanguage.fromMap(e as Map))
            .toList(),
      );
}

/// The user's current/selected voice stack.
class VoiceSelection {
  const VoiceSelection({
    required this.mode,
    this.realtimeModelId = '',
    this.brainId = '',
    this.sttId = '',
    this.ttsId = '',
    this.voiceId = '',
    this.languageCode = '',
    this.accent = '',
    this.voiceFellBack = false,
    this.savedVoiceId = '',
  });
  final String mode; // 'realtime' | 'cascade'
  final String realtimeModelId;
  final String brainId;
  final String sttId;
  final String ttsId;
  final String voiceId;
  final String languageCode;

  /// Dedicated free-text ACCENT (§13.9) — HOW Ayma sounds, separate from the
  /// language selector. Honoured only by accent-capable voice models.
  final String accent;

  /// Server-reported (only meaningful on a catalog's `current`): the saved
  /// voice was not supported by the active model, so [voiceId] is the
  /// model's supported default instead. [savedVoiceId] is what was saved.
  /// Never sent back — [toMap] keeps the documented POST body shape.
  final bool voiceFellBack;
  final String savedVoiceId;

  factory VoiceSelection.fromMap(Map m) => VoiceSelection(
        mode: m['mode'] as String? ?? 'realtime',
        realtimeModelId: m['realtime_model_id'] as String? ?? '',
        brainId: m['brain_id'] as String? ?? '',
        sttId: m['stt_id'] as String? ?? '',
        ttsId: m['tts_id'] as String? ?? '',
        voiceId: m['voice_id'] as String? ?? '',
        languageCode: m['language_code'] as String? ?? '',
        accent: m['accent'] as String? ?? '',
        voiceFellBack: m['voice_fell_back'] as bool? ?? false,
        savedVoiceId: m['saved_voice_id'] as String? ?? '',
      );

  Map<String, dynamic> toMap() => {
        'mode': mode,
        'realtime_model_id': realtimeModelId,
        'brain_id': brainId,
        'stt_id': sttId,
        'tts_id': ttsId,
        'voice_id': voiceId,
        'language_code': languageCode,
        'accent': accent,
      };

  VoiceSelection copyWith({
    String? mode,
    String? realtimeModelId,
    String? brainId,
    String? sttId,
    String? ttsId,
    String? voiceId,
    String? languageCode,
    String? accent,
  }) =>
      VoiceSelection(
        mode: mode ?? this.mode,
        realtimeModelId: realtimeModelId ?? this.realtimeModelId,
        brainId: brainId ?? this.brainId,
        sttId: sttId ?? this.sttId,
        ttsId: ttsId ?? this.ttsId,
        voiceId: voiceId ?? this.voiceId,
        languageCode: languageCode ?? this.languageCode,
        accent: accent ?? this.accent,
        voiceFellBack: voiceFellBack,
        savedVoiceId: savedVoiceId,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VoiceSelection &&
          runtimeType == other.runtimeType &&
          mode == other.mode &&
          realtimeModelId == other.realtimeModelId &&
          brainId == other.brainId &&
          sttId == other.sttId &&
          ttsId == other.ttsId &&
          voiceId == other.voiceId &&
          languageCode == other.languageCode &&
          accent == other.accent;

  @override
  int get hashCode => Object.hash(
        mode,
        realtimeModelId,
        brainId,
        sttId,
        ttsId,
        voiceId,
        languageCode,
        accent,
      );
}

/// The full `/voice/engines` catalog.
class VoiceCatalog {
  const VoiceCatalog({
    this.modes = const ['realtime', 'cascade'],
    this.source = '',
    this.realtimeModels = const [],
    this.brains = const [],
    this.stt = const [],
    this.tts = const [],
    required this.current,
    required this.defaultSelection,
  });
  final List<String> modes;
  final String source; // 'livekit' | 'fallback'
  final List<RealtimeModel> realtimeModels;
  final List<VoiceComponent> brains;
  final List<VoiceComponent> stt;
  final List<VoiceComponent> tts;
  final VoiceSelection current;
  final VoiceSelection defaultSelection;

  factory VoiceCatalog.fromMap(Map<String, dynamic> m) => VoiceCatalog(
        modes: ((m['modes'] as List?) ?? const ['realtime', 'cascade'])
            .map((e) => e.toString())
            .toList(),
        source: m['source'] as String? ?? '',
        realtimeModels: ((m['realtime_models'] as List?) ?? const [])
            .map((e) => RealtimeModel.fromMap(e as Map))
            .toList(),
        brains: ((m['brains'] as List?) ?? const [])
            .map((e) => VoiceComponent.fromMap(e as Map))
            .toList(),
        stt: ((m['stt'] as List?) ?? const [])
            .map((e) => VoiceComponent.fromMap(e as Map))
            .toList(),
        tts: ((m['tts'] as List?) ?? const [])
            .map((e) => VoiceComponent.fromMap(e as Map))
            .toList(),
        current: VoiceSelection.fromMap(
            (m['current'] as Map?) ?? const {'mode': 'realtime'}),
        defaultSelection: VoiceSelection.fromMap(
            (m['default'] as Map?) ?? const {'mode': 'realtime'}),
      );

  RealtimeModel? realtimeById(String id) {
    for (final r in realtimeModels) {
      if (r.id == id) return r;
    }
    return null;
  }

  VoiceComponent? ttsById(String id) {
    for (final t in tts) {
      if (t.id == id) return t;
    }
    return null;
  }
}

// --- Unified Brain (§13.10) ---------------------------------------------

/// One selectable **Brain** (an LLM vendor) from `GET /brain/preference`.
class BrainOption {
  const BrainOption({
    required this.id,
    required this.label,
    this.description = '',
    this.available = true,
    this.capabilities = const [],
  });

  final String id; // 'gemini' | 'meta'
  final String label;
  final String description;
  final bool available;
  final List<String> capabilities; // 'text','json','vision','web','tools'

  factory BrainOption.fromMap(Map m) => BrainOption(
        id: m['id'] as String? ?? '',
        label: m['label'] as String? ?? '',
        description: m['description'] as String? ?? '',
        available: m['available'] as bool? ?? true,
        capabilities: ((m['capabilities'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
      );
}

/// The `/brain/preference` payload: the Brain list, the saved choice (empty when
/// unset), and the default the UI pre-selects when nothing is saved.
class BrainCatalog {
  const BrainCatalog({
    this.brains = const [],
    this.current = '',
    this.defaultBrain = '',
  });

  final List<BrainOption> brains;
  final String current; // '' when unset
  final String defaultBrain;

  /// The id the dropdown should show: the saved choice if any, else the default,
  /// else the first available brain (never null when the list is non-empty).
  String get effectiveId {
    if (current.isNotEmpty && brains.any((b) => b.id == current)) {
      return current;
    }
    if (defaultBrain.isNotEmpty && brains.any((b) => b.id == defaultBrain)) {
      return defaultBrain;
    }
    return brains.isNotEmpty ? brains.first.id : '';
  }

  factory BrainCatalog.fromMap(Map<String, dynamic> m) => BrainCatalog(
        brains: ((m['brains'] as List?) ?? const [])
            .map((e) => BrainOption.fromMap(e as Map))
            .toList(),
        current: m['current'] as String? ?? '',
        defaultBrain: m['default'] as String? ?? '',
      );
}

// --- Image model (§image-gen restore) -----------------------------------

/// One selectable image-generation model from `GET /image-model/preference`.
/// Image generation is the ONE founder-authorized direct-provider path; only
/// configured providers are returned (no key → not listed), so [available] is
/// always true for the entries that come back.
class ImageModelOption {
  const ImageModelOption({
    required this.id,
    required this.label,
    this.description = '',
    this.model = '',
    this.available = true,
  });

  final String id; // 'gemini-direct' | 'xai-direct' | …
  final String label;
  final String description;
  final String model; // the underlying model id
  final bool available;

  factory ImageModelOption.fromMap(Map m) => ImageModelOption(
        id: m['id'] as String? ?? '',
        label: m['label'] as String? ?? '',
        description: m['description'] as String? ?? '',
        model: m['model'] as String? ?? '',
        available: m['available'] as bool? ?? true,
      );
}

/// The `/image-model/preference` payload: the configured image-model list, the
/// saved choice (empty when unset), and the default (`gemini-direct`) the UI
/// pre-selects when nothing is saved.
class ImageModelCatalog {
  const ImageModelCatalog({
    this.models = const [],
    this.current = '',
    this.defaultModel = '',
  });

  final List<ImageModelOption> models;
  final String current; // '' when unset
  final String defaultModel;

  /// The id the dropdown should show: the saved choice if any, else the
  /// default, else the first available model (never null when non-empty).
  String get effectiveId {
    if (current.isNotEmpty && models.any((m) => m.id == current)) {
      return current;
    }
    if (defaultModel.isNotEmpty && models.any((m) => m.id == defaultModel)) {
      return defaultModel;
    }
    return models.isNotEmpty ? models.first.id : '';
  }

  factory ImageModelCatalog.fromMap(Map<String, dynamic> m) => ImageModelCatalog(
        models: ((m['models'] as List?) ?? const [])
            .map((e) => ImageModelOption.fromMap(e as Map))
            .toList(),
        current: m['current'] as String? ?? '',
        defaultModel: m['default'] as String? ?? '',
      );
}

// --- Your Story editor models -------------------------------------------

/// One section of the Your Story document. On a `GET /story` read the flags are
/// meaningful; inside a version snapshot they default to false.
class StorySection {
  const StorySection({
    required this.pageId,
    required this.pageType,
    required this.title,
    required this.body,
    required this.visibility,
    this.userEdited = false,
    this.isSkill = false,
    this.hasPrivateSpans = false,
    this.aiUpdatedSinceUser = false,
    this.reportId,
    this.editBody,
    this.userHidden = false,
  });

  final String pageId;
  final String pageType;
  final String title;

  /// The section body, markdown. May contain `{{private}}…{{/private}}` spans.
  final String body;

  /// Complete body for editing; includes retained passages hidden in Story.
  final String? editBody;
  String get editableBody => editBody ?? body;
  final bool userHidden;

  /// `private` | `public` (never `ai_only` in the editor).
  final String visibility;

  /// The user has overridden Ayma's compiled body for this section.
  final bool userEdited;

  /// A skill-generated section (Facial analysis, Web findings, …) — shown
  /// under the "From Ayma's skills" divider.
  final bool isSkill;

  /// The body contains at least one `{{private}}` span.
  final bool hasPrivateSpans;

  /// Ayma's compiled body moved on after the user's last edit.
  final bool aiUpdatedSinceUser;

  /// The id of the dedicated report screen's report for this section, when
  /// one exists — only ever set for `face-analysis` / `body-analysis` /
  /// `physical-profile` (all the same unified Appearance report id, opened at
  /// `/appearance/{id}`) and `web-findings` (opened at `/deep-dive/{id}`).
  /// `null` when no report has been run yet, or for any other page.
  final String? reportId;

  factory StorySection.fromMap(Map<String, dynamic> m) => StorySection(
    pageId: m['page_id'] as String? ?? '',
    pageType: m['page_type'] as String? ?? 'misc',
    title: m['title'] as String? ?? '',
    body: m['body'] as String? ?? '',
    editBody: m['edit_body'] as String?,
    userHidden: m['user_hidden'] == true,
    visibility: m['visibility'] as String? ?? 'private',
    userEdited: m['user_edited'] == true,
    isSkill: m['is_skill'] == true,
    hasPrivateSpans: m['has_private_spans'] == true,
    aiUpdatedSinceUser: m['ai_updated_since_user'] == true,
    reportId: m['report_id'] as String?,
  );

  StorySection copyWith({String? body, String? visibility}) => StorySection(
    pageId: pageId,
    pageType: pageType,
    title: title,
    body: body ?? this.body,
    editBody: body ?? editBody,
    userHidden: userHidden,
    visibility: visibility ?? this.visibility,
    userEdited: userEdited,
    isSkill: isSkill,
    hasPrivateSpans: hasPrivateSpans,
    aiUpdatedSinceUser: aiUpdatedSinceUser,
    reportId: reportId,
  );
}

/// `GET /profile/public-text` result.
class ProfileTextDoc {
  const ProfileTextDoc({
    required this.text,
    required this.version,
    required this.maxChars,
  });

  final String text;
  final String version;
  final int maxChars;
}

/// A manual profile-text save the server refused; [message] is user-facing.
class ProfileTextRejected implements Exception {
  ProfileTextRejected(this.message, {this.stale = false});

  final String message;

  /// The profile changed since the editor loaded (HTTP 409).
  final bool stale;

  @override
  String toString() => 'ProfileTextRejected($message)';
}

/// One piece of a proposal's sentence diff: [op] is `same` | `add` | `remove`.
/// One reviewable change to the public profile: an added (`op == 'add'`) or
/// removed (`op == 'remove'`) sentence, with its own stable [id] so it can be
/// applied or dismissed on its own.
class ProfileChange {
  const ProfileChange({required this.id, required this.op, required this.text});

  factory ProfileChange.fromMap(Map<String, dynamic> m) => ProfileChange(
    id: m['id'] as String? ?? '',
    op: m['op'] as String? ?? 'add',
    text: m['text'] as String? ?? '',
  );

  final String id;
  final String op;
  final String text;
}

/// Ayma's pending updates to one public-profile section — a group header over
/// its individual [changes].
class ProfileProposal {
  const ProfileProposal({
    required this.pageId,
    required this.title,
    required this.changes,
  });

  factory ProfileProposal.fromMap(Map<String, dynamic> m) => ProfileProposal(
    pageId: m['page_id'] as String? ?? '',
    title: m['title'] as String? ?? '',
    changes: ((m['changes'] as List?) ?? const [])
        .whereType<Map>()
        .map((d) => ProfileChange.fromMap(d.cast<String, dynamic>()))
        .toList(),
  );

  final String pageId;
  final String title;
  final List<ProfileChange> changes;
}

/// `GET /story` result.
class StoryData {
  const StoryData({required this.sections});
  final List<StorySection> sections;
}

/// One row of a section's version history
/// (`GET /story/section/{id}/versions`), newest first.
class StoryVersion {
  const StoryVersion({
    required this.id,
    required this.author,
    required this.note,
    required this.visibility,
    required this.createdAtMs,
  });

  final String id;

  /// `user` | `ayma`.
  final String author;
  final String note;
  final String visibility;
  final int createdAtMs;

  factory StoryVersion.fromMap(Map<String, dynamic> m) => StoryVersion(
    id: m['id'] as String? ?? '',
    author: m['author'] as String? ?? 'user',
    note: m['note'] as String? ?? '',
    visibility: m['visibility'] as String? ?? 'private',
    createdAtMs: (m['created_at_ms'] as num?)?.toInt() ?? 0,
  );
}

/// One resolved conversation source in [SectionProvenance.sources] — an ISO
/// date only; never a raw excerpt of the conversation itself.
class ProvenanceSource {
  const ProvenanceSource({required this.date, this.sessionId = ''});
  final String date;

  /// The `raw_turns/{sessionId}` doc this source resolved from — lets the
  /// client jump back into that conversation in chat. Empty for an
  /// old-format cache entry or when the source id no longer resolves; the
  /// row then renders as a plain, non-tappable line (never a crash).
  final String sessionId;

  factory ProvenanceSource.fromMap(Map<String, dynamic> m) => ProvenanceSource(
    date: m['date'] as String? ?? '',
    sessionId: m['session_id'] as String? ?? '',
  );
}

/// `GET /story/section/{id}/provenance` — "why Ayma believes this". Page-level
/// only: conversations that fed the section + last-updated dates. No
/// fabricated per-sentence confidence.
class SectionProvenance {
  const SectionProvenance({
    required this.pageId,
    required this.conversationCount,
    this.updatedAt,
    this.userUpdatedAt,
    this.sources = const [],
  });

  final String pageId;
  final int conversationCount;
  final String? updatedAt;
  final String? userUpdatedAt;
  final List<ProvenanceSource> sources;

  factory SectionProvenance.fromMap(Map<String, dynamic> m) =>
      SectionProvenance(
        pageId: m['page_id'] as String? ?? '',
        conversationCount: (m['conversation_count'] as num?)?.toInt() ?? 0,
        updatedAt: m['updated_at'] as String?,
        userUpdatedAt: m['user_updated_at'] as String?,
        sources: ((m['sources'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => ProvenanceSource.fromMap(e.cast<String, dynamic>()))
            .toList(),
      );
}

/// One job or degree in the structured career timeline.
class TimelineEntry {
  const TimelineEntry({
    required this.id,
    required this.kind,
    required this.org,
    this.titleOrDegree = '',
    this.start = '',
    this.end = '',
    this.confidence = 'low',
  });

  final String id;

  /// `work` | `education`.
  final String kind;
  final String org;
  final String titleOrDegree;
  final String start;
  final String end;

  /// `high` | `medium` | `low` — this one entry's own confidence.
  final String confidence;

  /// "2020 – Present" / "2020 – 2022" / "2020" (open-ended when [end] is empty
  /// but [start] isn't).
  String get dateRange {
    if (start.isEmpty && end.isEmpty) return '';
    if (start.isNotEmpty && end.isNotEmpty) return '$start – $end';
    return start.isNotEmpty ? start : end;
  }

  factory TimelineEntry.fromMap(Map<String, dynamic> m) => TimelineEntry(
    id: m['id'] as String? ?? '',
    kind: m['kind'] as String? ?? 'work',
    org: m['org'] as String? ?? '',
    titleOrDegree: m['title_or_degree'] as String? ?? '',
    start: m['start'] as String? ?? '',
    end: m['end'] as String? ?? '',
    confidence: m['confidence'] as String? ?? 'low',
  );
}

/// `GET /story/career-timeline` / `POST /story/career-timeline/refresh` — the
/// structured career/education timeline. [showTimeline] is the confidence
/// gate the client must respect: only render the visual timeline when it's
/// true, otherwise fall back to the section's flowing prose.
class CareerTimeline {
  const CareerTimeline({
    this.entries = const [],
    this.overallConfidence = 'none',
    this.showTimeline = false,
    this.linkedinUrl = '',
    this.usageCapped = false,
  });

  final List<TimelineEntry> entries;
  final String overallConfidence;
  final bool showTimeline;
  final String linkedinUrl;
  final bool usageCapped;

  factory CareerTimeline.fromMap(Map<String, dynamic> m) => CareerTimeline(
    entries: ((m['entries'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => TimelineEntry.fromMap(e.cast<String, dynamic>()))
        .toList(),
    overallConfidence: m['overall_confidence'] as String? ?? 'none',
    showTimeline: m['show_timeline'] == true,
    linkedinUrl: m['linkedin_url'] as String? ?? '',
    usageCapped: m['usage_capped'] == true,
  );
}

/// `POST /credits/topup` answered 402: free reloads are off, upgrade instead.
class UpgradeRequiredException implements Exception {
  UpgradeRequiredException(this.message);

  final String message;

  @override
  String toString() => 'UpgradeRequiredException($message)';
}

/// Thrown by [ApiClient.bootstrap] when the signed-in user's credential cannot
/// be turned into an ID token for a reason that is NOT a transient network
/// failure: an Android keystore / decrypt failure after an Auto Backup restore
/// ("FirebearStorageCryptoHelper"), or a rejected / disabled / revoked user.
/// The persisted session is unusable, so the splash signs the user out and
/// routes to sign-in instead of retrying (§11.2). Distinct from [ApiException]
/// precisely so a genuine network failure (which IS an [ApiException]) still
/// retries and never discards a signed-in session.
class AuthSessionException implements Exception {
  AuthSessionException(this.message);

  final String message;

  @override
  String toString() => 'AuthSessionException($message)';
}

class ApiException implements Exception {
  ApiException(this.message, {this.statusCode, this.body});

  final String message;
  final int? statusCode;
  final String? body;

  @override
  String toString() =>
      'ApiException($message${statusCode != null ? ', status $statusCode' : ''})';
}
