import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../services/api_client.dart';
import '../services/app_context.dart';
import '../services/navigation_history.dart';
import '../services/async_voice_controller.dart';
import '../services/voice_clip_registry.dart';
import '../services/async_voice_player.dart';
import '../services/async_voice_queue.dart';
import '../services/call_permissions.dart';
import '../services/chat_inbox.dart';
import '../services/chat_service.dart';
import '../services/connection_heartbeat.dart';
import '../services/credits_balance.dart';
import '../services/ids.dart';
import '../services/pending_chat_queue.dart';
import '../services/profile_service.dart';
import '../services/report_cache.dart';
import '../services/tour_anchors.dart';
import '../services/feedback_bubble.dart';
import '../services/transcript_store.dart';
import '../services/thumbs_down_store.dart';
import '../services/voice_entry_gate.dart';
import '../services/voice_session_controller.dart';
import '../services/voice_transport.dart';
import '../theme.dart';
import '../util/cold_start_retry.dart';
import '../widgets/ask_ayma_context.dart';
import '../widgets/ayma_chat_modal.dart';
import '../widgets/ayma_wing_loader.dart';
import '../widgets/voice_clip_row.dart';
import '../widgets/ayma_photo.dart';
import '../widgets/ayma_primitives.dart';
import '../widgets/ayma_toast.dart';
import '../widgets/body_report_view.dart';
import '../widgets/face_report_view.dart';
import '../widgets/feedback_bubble_card.dart';
import '../widgets/feedback_draft_card.dart';
import '../widgets/image_viewer.dart';
import '../widgets/copy_on_long_press.dart';
import '../widgets/collapsible_message_text.dart';
import '../widgets/message_timestamp.dart';
import '../widgets/ayma_quiet_chip.dart';
import '../widgets/chat_composer.dart';
import '../widgets/out_of_credits.dart';
import '../widgets/overflow_guards.dart';
import 'preboarding_flow_screen.dart';
import 'voice_call_screen.dart';

/// Ayma chat screen. One [TranscriptStore] backs the view; typed turns and
/// relayed voice-transcript segments flow into it through the same path, so a
/// voice turn renders exactly like a typed one (§1.6, Steps 8–16).
///
/// Visually it follows the design's Talk screen (§14.1): a living orb with a
/// mono state caption, then the transcript as labelled lines — Ayma in serif
/// italic, you in sans — with older turns dimmed.
class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    this.apiClient,
    this.voiceController,
    this.transcriptStore,
    this.chatService,
    this.imagePicker,
    this.viewingProfileUid = '',
    this.marketing = false,
    this.profileService,
    this.photoUrl = '',
    this.photoSource = '',
    this.targetTimestamp = '',
    this.pageContext,
    this.scrollController,
    this.askAymaContext,
    this.onExchange,
    this.onGoToMainChat,
    this.voiceApiClient,
    this.voiceTransportFactory,
    this.pendingQueue,
    this.asyncVoiceQueue,
    this.asyncVoiceController,
    this.asyncVoicePlayer,
    this.composerAnchorKey,
    this.auth,
  });

  static const path = '/chat';

  /// Feature-tour anchor for the message composer (the "say hi to Ayma" box).
  /// Only the main shell's embedded chat passes it, so the coach-mark engine
  /// can spotlight the real text box without colliding with the popup/marketing
  /// chat instances.
  final Key? composerAnchorKey;

  final ApiClient? apiClient;
  final VoiceSessionController? voiceController;
  final TranscriptStore? transcriptStore;
  final ChatService? chatService;
  final ImagePicker? imagePicker;
  final FirebaseAuth? auth;

  /// The screen the user was on when this chat was opened (the global
  /// floating Ayma launcher's page-context threading) — a snapshot of
  /// [AppContext.instance] taken at open time, not a live mirror. Folded
  /// into every `/chat` turn alongside [viewingProfileUid], which already
  /// covers the `screen == 'profile'` case in full; null everywhere else
  /// (the Ayma tab, the marketing route, the Story sheets) that already has
  /// its own, more specific context params.
  final ScreenContext? pageContext;

  /// Set ONLY for the nav-bar orb's page-context popup: where its
  /// header's expand button goes. The popup's sheet never grows to full
  /// screen in place (founder order, 2026-11-07 — the grown sheet was a
  /// stale-looking duplicate of this conversation, its history list
  /// mounted at the oldest turn), so the button instead runs this
  /// callback: the host closes the sheet and navigates to the real main
  /// chat screen, where this same live conversation already rests at
  /// its tail. Null everywhere else — a ChatScreen hosted in an
  /// expandable sheet (a scoped Ask-Ayma turn) keeps the in-place
  /// expand/collapse button, and a sheet-less one (the main tab) shows
  /// no button at all.
  final VoidCallback? onGoToMainChat;

  /// External scroll controller for the transcript list — set by the global
  /// floating sheet so its `DraggableScrollableSheet` can turn a drag over
  /// the transcript into a resize/dismiss once scrolled to the top, the same
  /// controller-linking pattern `body_report_view.dart`'s own stored-report
  /// sheet already uses. Owns (and disposes) its own controller when null,
  /// same as every other override here.
  final ScrollController? scrollController;

  /// Pre-signup `marketing` mode (§3.3): show a "Get started" action that
  /// records the onboarding transition and moves to preboarding.
  final bool marketing;
  final ProfileService? profileService;

  /// When the chat was opened from a specific profile / match card, Ayma gets
  /// that pair's private read into her context (§5.6).
  final String viewingProfileUid;

  /// When the chat is opened from "Chat about it" on one photo in Your Story:
  /// that photo's URL and where it came from. Ayma gets the photo-note tool,
  /// scoped to it. Empty otherwise.
  final String photoUrl;
  final String photoSource;

  /// When the chat is opened to revisit a point in history (e.g. "Why Ayma
  /// believes this" -> a source conversation in Your Story): an ISO8601
  /// timestamp near that conversation. On load, history pages back as far as
  /// needed to include it, then the chat scrolls to and briefly highlights the
  /// first message at/after it. Empty otherwise (normal open, scrolls to the
  /// bottom as always).
  final String targetTimestamp;

  /// Non-null turns this into a scoped "Ask Ayma" correction turn — the one
  /// mechanism `showAskAymaOverlay` (`ask_ayma_overlay.dart`) now opens, and
  /// what a future Living Report caller should use too (see
  /// `AskAymaContext`'s own doc for the forward-compat fields). ONE chat
  /// (§ D13): this is the main chat conversation, not a silo — the sheet is
  /// built against the shared [AymaSession] store and the exchange lands in
  /// it (and, for the report path, in server history too). The partial sheet
  /// does not LIST that history (founder rule, Nov 2026 — context card,
  /// chips and composer only); expanding to full screen reveals the whole
  /// conversation. No server history is (re)loaded here — the shared
  /// store already carries it, and scroll-up older paging stands down (no
  /// cursor of its own). Changes this screen in several ways, all gated on
  /// this being non-null: the header becomes the compact "Ask Ayma" title +
  /// quoted-passage card instead of the full tab header; [askAymaContext]'s
  /// fields ride along on every turn alongside the message (see [_send]);
  /// [quickSuggestionsFor]'s chips show as the body while partial (history
  /// hidden) or with a truly empty transcript, and pinned above the composer
  /// otherwise, so the scoped affordance never vanishes mid-conversation;
  /// voice is push-to-talk (tap the mic, speak, the finalized transcript is
  /// sent through the exact same [_send] text path, then the session tears
  /// down before any spoken reply — [_pttVoice]) rather than the
  /// full-duplex live call [_voice] otherwise gives you, because the LiveKit
  /// voice agent doesn't bind these correction tools; and this screen never
  /// touches [AppContext] or [ChatInbox] (a scoped correction turn has no
  /// business changing what the rest of the app thinks the current screen
  /// or kickoff is).
  final AskAymaContext? askAymaContext;

  /// Only meaningful alongside [askAymaContext]: fires after every reply
  /// Ayma gives while this screen is open (not just once at the end) so the
  /// caller can quietly re-fetch whatever report/section is being corrected
  /// and reflect the change while the user is still mid-conversation.
  final VoidCallback? onExchange;

  /// Test seams for [askAymaContext]'s push-to-talk voice controller
  /// ([_pttVoice]) only — production always leaves these null so it builds
  /// its own default real [ApiClient] / `LiveKitVoiceTransport`. Ignored
  /// (and unused) when [askAymaContext] is null; the normal full-duplex
  /// [_voice] is overridden via [voiceController] instead.
  final ApiClient? voiceApiClient;
  final VoiceTransport Function()? voiceTransportFactory;

  /// Messages sent while out of credits, held until they can go. Defaults to
  /// the app-wide [PendingChatQueue.instance]; only the plain Ayma conversation
  /// uses it (see `_canQueue`).
  final PendingChatQueue? pendingQueue;

  /// Async voice-message seams (Chunk A). Default to the app-wide queue, a
  /// controller on that queue, and a shared just_audio clip player; only the
  /// plain Ayma conversation uses them (see `_canQueue`).
  final AsyncVoiceQueue? asyncVoiceQueue;
  final AsyncVoiceController? asyncVoiceController;
  final AsyncVoicePlayer? asyncVoicePlayer;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final String _sessionId = newSessionId();
  late final ApiClient _api = widget.apiClient ?? ApiClient();
  late final PendingChatQueue _queue =
      widget.pendingQueue ?? PendingChatQueue.instance;
  late final AsyncVoiceQueue _voiceQueue =
      widget.asyncVoiceQueue ?? AsyncVoiceQueue.instance;
  late final AsyncVoiceController _voiceMessage =
      widget.asyncVoiceController ?? AsyncVoiceController(queue: _voiceQueue);

  late final AsyncVoicePlayer _clipPlayer =
      widget.asyncVoicePlayer ?? JustAudioVoicePlayer();

  /// Which transcript clip is playing (`VoiceClipRow` keys), if any — one
  /// clip app-wide at a time.
  final ValueNotifier<String?> _nowPlaying = ValueNotifier<String?>(null);

  /// Publish this chat's playable voice clips to [VoiceClipRegistry], so
  /// Ayma's `play_voice_clip` command can play one on request (ACTION
  /// PARITY pilot, founder 2026-11-06). Rebuilt on every store change;
  /// the handles close over this screen's own player / now-playing
  /// notifier, so Ayma-driven playback is the exact playback a tap on
  /// the clip's play button performs. The clip key matches the one
  /// `_TranscriptLine._clipRow` builds for the same turn.
  void _syncVoiceClips() {
    final turns = _store.turns;
    final clips = <VoiceClipHandle>[];
    for (var i = 0; i < turns.length; i++) {
      final turn = turns[i];
      final url = turn.audioUrl;
      final file = turn.audioFile;
      final hasUrl = url != null && url.isNotEmpty;
      if (!hasUrl && file == null) continue;
      final key =
          '${turn.role.name}:${turn.text.hashCode}:${url ?? file?.path}';
      final mine = turn.role == TurnRole.user;
      final snippet = turn.text.trim();
      final label = mine
          ? 'your voice message'
          : "Ayma's voice message";
      clips.add(VoiceClipHandle(
        key: key,
        owner: mine ? 'user' : 'ayma',
        label: snippet.isEmpty
            ? label
            : '$label ("${snippet.length > 60 ? '${snippet.substring(0, 60)}…' : snippet}")',
        order: i,
        start: () async {
          _nowPlaying.value = key;
          try {
            if (hasUrl) {
              await _clipPlayer.playUrl(url);
            } else {
              await _clipPlayer.playFile(file!.path);
            }
          } catch (_) {
            if (_nowPlaying.value == key) _nowPlaying.value = null;
            rethrow;
          }
        },
        isPlaying: () =>
            _nowPlaying.value == key && _clipPlayer.playing.value,
        stop: () async {
          if (_nowPlaying.value == key) _nowPlaying.value = null;
          await _clipPlayer.stop();
        },
      ));
    }
    VoiceClipRegistry.instance.sync(this, clips);
  }

  /// Whether an out-of-credits send is queued rather than left as a refusal.
  /// Only the plain Ayma conversation: a scoped Ask-Ayma correction, the
  /// pre-signup marketing chat and a photo's "Chat about it" carry context a
  /// queued plain message could not reproduce.
  bool get _canQueue =>
      widget.askAymaContext == null &&
      !widget.marketing &&
      widget.photoUrl.isEmpty;
  late final TranscriptStore _store =
      widget.transcriptStore ?? TranscriptStore();
  late final ChatService _chat = widget.chatService ?? ChatService();
  late final ImagePicker _picker = widget.imagePicker ?? ImagePicker();
  late final VoiceSessionController _voice =
      widget.voiceController ??
      VoiceSessionController(
        transcriptStore: _store,
        sessionId: _sessionId,
        userIdleTimeout: VoiceSessionController.defaultUserIdleTimeout,
      );
  final _composerController = TextEditingController();
  final _composerFocus = FocusNode();
  late final ScrollController _scrollController =
      widget.scrollController ?? ScrollController();
  bool _canSend = false;
  bool _sending = false;

  /// In-chat feedback bubble (founder spec, 2026-11-06): the current
  /// offer (null = no bubble in the stream), its once-per-session gate,
  /// and the conversational fill mirrored into the card. See
  /// `feedback_bubble.dart` for the triggers and caps.
  final FeedbackBubbleGate _bubbleGate = FeedbackBubbleGate();
  FeedbackBubbleRequest? _bubble;
  bool _bubbleDone = false;
  String _bubbleFillText = '';
  int _bubbleFillRevision = 0;
  final Set<TranscriptTurn> _bubbleScanned = {};

  /// Auto-screenshot for the bubble: [_appShotKey] bounds the live
  /// transcript area; when a bubble is offered, one frame of it is
  /// captured BEFORE the card renders (so the shot shows the app as it
  /// looked when the feedback was triggered, not the card itself),
  /// uploaded under `uploads/{uid}/feedback_…`, and handed to the card
  /// as a removable thumbnail. Best-effort: any failure just flags
  /// [_bubbleShotFailed] and the submission goes without it.
  final GlobalKey _appShotKey = GlobalKey();
  File? _bubbleShotFile;
  String? _bubbleShotPath;
  bool _bubbleShotFailed = false;
  bool _bubblePresenting = false;

  /// The page the user was on when this chat was opened/switched to — seeded
  /// from [ChatScreen.pageContext] (a fresh embed, e.g. the global launcher's
  /// sheet) and updatable afterwards via a `page_context` [ChatKickoff] (the
  /// Ayma tab, built once and kept alive, can't get a new constructor value
  /// per tap — see [_applyPageContext]). Null/empty-screen means "nothing to
  /// show"; folded into every `/chat` turn alongside [_viewingUid], and shown
  /// as a dismissible chip above the composer. Always null alongside
  /// [ChatScreen.askAymaContext] (mutually exclusive entry points — see that
  /// field's doc), so it needs no gating of its own below.
  ScreenContext? _pageContext;

  /// Whether this chat is the page-context popup expanded to full screen
  /// (kept current by [didChangeDependencies]).
  bool _sheetExpanded = false;

  /// [_pageContext] as it applies right now: set aside while [_sheetExpanded]
  /// (founder rule: full screen drops the context; the popup keeps it), back
  /// once the popup collapses.
  ScreenContext? get _activePageContext =>
      _sheetExpanded ? null : _pageContext;

  // --- Ask-Ayma push-to-talk voice (see [ChatScreen.askAymaContext]'s doc)
  // — a second, independent voice pipeline from [_voice]/[_store] above,
  // constructed only when this screen is a scoped correction turn. Its own
  // ephemeral [TranscriptStore] never feeds the visible transcript: a live
  // utterance is only shown once it finalizes and is handed to [_send], the
  // exact same way typed text is — never streamed in turn-by-turn like a
  // full-duplex call's turns are.
  late final TranscriptStore? _pttStore = widget.askAymaContext != null
      ? TranscriptStore()
      : null;
  late final VoiceSessionController? _pttVoice = widget.askAymaContext != null
      ? VoiceSessionController(
          transcriptStore: _pttStore!,
          sessionId: newSessionId(),
          apiClient: widget.voiceApiClient,
          transportFactory: widget.voiceTransportFactory,
        )
      : null;
  bool _pttListening = false;

  /// Set (via [didChangeAppLifecycleState]) if the app leaves the foreground
  /// at any point while a `/chat/stream` request from [_send] is in flight.
  /// Root cause of "backgrounding while Ayma is thinking shows a network
  /// error": the OS suspends/throttles the app's socket once backgrounded
  /// (confirmed — there's no foreground-service / background-execution
  /// entitlement for a plain chat send, unlike a live voice call; see
  /// `CallBackgroundService`'s doc comment for why *that* needs one), so the
  /// stream read that resumes on foreground can come back as a dead-socket
  /// error even though the server already finished and persisted the reply.
  /// [_send]'s failure handling checks this before giving up: if it's set,
  /// the reply may simply be sitting in `/chat/history` already — worth a
  /// couple of quick polls (like [_awaitBackgroundReply] already does for a
  /// queued background skill) before showing a hard "couldn't reach Ayma"
  /// error the user has to manually retry.
  bool _backgroundedDuringSend = false;

  /// Turns loaded from server history on open — not re-posted on dispose.
  int _seededCount = 0;
  bool _loadingHistory = true;

  /// True once the initial history load's first attempt has failed and a
  /// cold-start backoff retry is pending/in flight: the loader swaps its line
  /// to "Reconnecting…" instead of holding the original line indefinitely
  /// (loader retest, Nov 2026, Leg 4). Reset on every new load.
  bool _historyRetrying = false;

  /// The `/chat/history` cursor for the next older page, or null once the
  /// start of history is reached (or the initial load hasn't resolved yet).
  /// Set from the normal (non-target) load's own `next_before`, or — on a
  /// [ChatScreen.targetTimestamp] jump — whatever's left after that load's
  /// own paging loop, so scrolling further up still works either way.
  String? _nextBefore;
  bool _loadingOlder = false;

  /// True for the span between [_store.prependOlder] and the scroll-offset
  /// fix-up that follows it — [_scrollToBottom] (a listener on every store
  /// change, [_store.addListener]) would otherwise fire on that same
  /// notification and yank the view back down to the bottom right after an
  /// older page loads.
  bool _pendingOlderScroll = false;

  /// True for as long as the user's finger is actually down on the message
  /// list — set on a real (`dragDetails != null`) [ScrollStartNotification],
  /// cleared on the matching [ScrollEndNotification]. [_scrollToBottom] fires
  /// on every store change, and a live voice call streams those constantly;
  /// without this guard, `animateTo` mid-drag would call `beginActivity` on
  /// this exact `ScrollPosition`, disposing the drag's `ScrollDragController`
  /// and firing its `onDragCanceled` callback — silently cancelling whatever
  /// gesture is in flight. When this list is embedded in the floating
  /// launcher's `DraggableScrollableSheet` (same controller, by design — see
  /// [ChatScreen.scrollController]), that cancelled gesture *is* the user's
  /// drag-to-expand: the sheet would look stuck exactly whenever a call is
  /// live, which is exactly when a founder testing voice would notice it.
  bool _userScrolling = false;

  /// The `maxScrollExtent` [_scrollToBottom] last aimed for (`infinity` until
  /// the first one actually runs). Root cause of "opened chat / sent a
  /// message doesn't land at the very bottom": a turn's content can keep
  /// growing *after* that one-shot `animateTo` already measured
  /// `maxScrollExtent` — an Ayma line's serif/mono text re-lays-out once its
  /// web font (Instrument Serif / JetBrains Mono, fetched over the network
  /// the first time `google_fonts` needs them — see `theme.dart`) finishes
  /// downloading, and a network photo (a history image, or an inline
  /// markdown image in a reply) resizes from its loading placeholder once it
  /// decodes — both strictly after the frame `_scrollToBottom` measured,
  /// with nothing to re-correct the scroll afterward. [_handleListMetrics]
  /// (and, for the same reason, [_handleListScrollNotification]'s own
  /// `ScrollEndNotification` branch) re-chases the bottom using this as the
  /// "was the view actually sitting at the bottom" baseline, so it only fires
  /// for that case — never while the user is scrolled up reading history, and
  /// never fighting the older-history / target-jump fix-ups (both already
  /// guard [_scrollToBottom] itself, which this reuses).
  double _bottomBaseline = double.infinity;

  /// Non-null when the last history load *failed* (auth, non-200, transport,
  /// bad shape). Kept distinct from "no history" so the user gets a retry
  /// affordance instead of a misleading "say hello" — one swallowed cold-start
  /// error would otherwise leave the transcript blank for the whole session
  /// (the Ayma tab is built once and kept alive, so `initState` never re-runs).
  String? _historyError;

  /// True from init until the initial history load has resolved a
  /// [ChatScreen.targetTimestamp] jump (or found there's nothing to jump to).
  /// While true, [_scrollToBottom] stands down so it doesn't fight the
  /// one-time jump-to-target scroll.
  late bool _pendingTargetScroll = widget.targetTimestamp.isNotEmpty;

  /// The loaded turn to scroll to and briefly highlight — set once, right
  /// after [_loadHistory] resolves a target timestamp; identity-compared
  /// against `_store.turns` so it still works after trimming reindexes.
  TranscriptTurn? _highlightedTurn;
  final Map<TranscriptTurn, GlobalKey> _turnKeys = {};

  /// Clears [_highlightedTurn] 3s after it's set — cancelled on dispose so it
  /// never fires (or leaks) after the screen is gone.
  Timer? _highlightClearTimer;

  File? _pendingImage;

  /// An earlier message the user swiped on to reply to — rendered as a quoted
  /// preview above the composer and sent with that quoted context.
  TranscriptTurn? _replyingToTurn;

  void _onSwipeReply(TranscriptTurn turn) {
    setState(() => _replyingToTurn = turn);
    _composerFocus.requestFocus();
  }

  void _clearReply() => setState(() => _replyingToTurn = null);

  /// A report/person attached to the chat as an un-sent draft (from an "Ask
  /// Ayma" button that opens the chat rather than auto-sending). Rendered as a
  /// chip above the composer; posted as a shared card on the next [_send].
  _SharedDraft? _pendingShared;

  /// Set when a "talk about them" kickoff (from a profile / DM) brought a person
  /// into this chat — every turn after it carries that pair as Ayma's context.
  String _viewingOverride = '';
  String get _viewingUid =>
      _viewingOverride.isNotEmpty ? _viewingOverride : widget.viewingProfileUid;

  /// Set by an "Edit with Ayma" kickoff on the user's own profile — unlocks
  /// Ayma's public-profile section-edit tools for the rest of the session.
  bool _profileEdit = false;

  /// Set by a "Here's my match report with X" kickoff (the Match report's
  /// own "Ask Ayma" button, `_runTalkAbout` below) — carries `match_report_id`
  /// for the rest of the session so Ayma stays briefed that any disputed
  /// fact behind the score should be fixed via her profile/questionnaire
  /// tools, then followed by a Recalculate (`_match_edit_context` in
  /// `main.py`). The scoped modal (`AskAymaContext.matchReportId`, from a tap
  /// on a Match report block) carries its own copy per turn instead — see
  /// [_send]'s `askAyma?.matchReportId ?? _matchReportId`.
  String _matchReportId = '';

  /// The shared-report reference set when the user posts a staged
  /// Send-to-Ayma card for a REPORT kind (`deep_dive` / `appearance`):
  /// kind + report id + subject (+ the opened run's version stamp for
  /// Appearance). Every turn after it carries the reference — never the
  /// report's contents — and Ayma pulls the exact report herself via her
  /// `open_shared_report` tool (founder 2026-11-09: reference, not
  /// content). Posting a card of any other kind clears it: the reference
  /// always names the most recently shared report. Profile / match /
  /// story shares never set it — their context already resolves
  /// server-side (viewing briefing / match id / standing story context).
  String _sharedKind = '';
  String _sharedRefId = '';
  String _sharedSubjectUid = '';
  String _sharedSubjectName = '';
  String _sharedRefVersion = '';

  String _currentUid() {
    try {
      return (widget.auth ?? FirebaseAuth.instance).currentUser?.uid ?? '';
    } catch (_) {
      return '';
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sheetExpanded =
        AymaChatSheetController.maybeOf(context)?.isExpanded ?? false;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pageContext = widget.pageContext;
    _composerController.addListener(() {
      final canSend = _composerController.text.trim().isNotEmpty;
      if (canSend != _canSend) setState(() => _canSend = canSend);
    });
    _store.addListener(_scrollToBottom);
    _store.addListener(_onStoreCapped);
    _store.addListener(_scanTurnsForBubble);
    _store.addListener(_syncVoiceClips);
    _syncVoiceClips();
    _scrollController.addListener(_maybeLoadOlderHistory);
    if (widget.askAymaContext == null) {
      // So Ayma's `current_screen` tool can answer "what page am I on?"
      // during a voice call. The tab shell also sets this, but a standalone
      // ChatScreen (pre-signup marketing route, "Chat about it" photo sheet)
      // has no shell above it. Skipped for a scoped Ask-Ayma correction turn
      // — see [ChatScreen.askAymaContext]'s doc for why.
      AppContext.instance.set(screen: 'ayma');
      final uid = _currentUid();
      unawaited(ThumbsDownStore.instance.load(uid).then((_) {
        if (mounted) setState(() {});
      }));
      _loadHistory();
      // Send-on-reconnect: a send waiting out a dead connection retries the
      // moment the heartbeat sees the link recover — not only on the next
      // app resume (the pre-existing trigger in [didChangeAppLifecycleState]).
      ConnectionHeartbeat.instance.listenable
          .addListener(_onConnectionRecovered);
      _voice.addListener(_onVoiceDropsChanged);
      ChatInbox.instance.pending.addListener(_consumeKickoff);
      ChatInbox.instance.resultsLanded.addListener(_onResultsLanded);
      WidgetsBinding.instance.addPostFrameCallback((_) => _consumeKickoff());
      if (_canQueue) {
        unawaited(_queue.activate());
        unawaited(_voiceQueue.activate());
        _voiceMessage.addListener(_onVoiceMessageChanged);
      }
    } else {
      _loadingHistory = false;
      _pttVoice!.addListener(_onPttVoiceChanged);
      _pttStore!.addListener(_onPttTranscriptChanged);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Only meaningful while a send is actually in flight — see
    // [_backgroundedDuringSend]'s doc. `resumed` itself doesn't clear it: the
    // socket may already be dead by the time the app comes back, which is
    // exactly the case [_send]'s failure handling needs to know about.
    if (_sending && state != AppLifecycleState.resumed) {
      _backgroundedDuringSend = true;
    }
    // Coming back to the foreground with a send still un-reconciled (its
    // connection died while the app was away): reconcile now — the server
    // very likely finished the turn while we were gone.
    if (state == AppLifecycleState.resumed && _reconcile != null) {
      _reconcilePendingSend();
    }
    // A grant or purchase may have landed while the app was away: let any
    // message waiting for credits go.
    if (state == AppLifecycleState.resumed && _canQueue) {
      unawaited(_queue.syncBalanceAndFlush());
    }
    // A match or web search may have finished while the app was away; its
    // result card is already in server history.
    if (state == AppLifecycleState.resumed && widget.askAymaContext == null) {
      unawaited(_pullBackgroundResults(attempts: 1));
    }
  }

  /// Reentrancy guard for [_pullBackgroundResults].
  bool _pullingResults = false;

  void _onResultsLanded() => unawaited(_pullBackgroundResults(attempts: 3));

  /// Pull in report-card turns the server wrote into this conversation on its
  /// own after a background skill finished — a match score or a web search
  /// started from a profile, from the match report, or by Ayma tapping the
  /// button for the user in a call. Without this they only showed up after
  /// the chat was reopened (founder bug 2026-10-26: the match result never
  /// appeared in the chat at all). Only final Ayma turns carrying a report
  /// marker that are newer than everything on screen are added, so this can
  /// never duplicate or reorder a normal reply. After a "job landed" signal
  /// the server writes the card a moment after the report itself, so a miss
  /// is retried briefly ([attempts]); an app resume checks once.
  Future<void> _pullBackgroundResults({required int attempts}) async {
    if (_pullingResults || _loadingHistory) return;
    _pullingResults = true;
    try {
      for (var attempt = 0; attempt < attempts && mounted; attempt++) {
        if (attempt > 0) await Future<void>.delayed(const Duration(seconds: 2));
        if (!mounted) return;
        final page = await _api.chatHistory(limit: 6);
        if (!mounted) return;
        final onScreen = _store.turns;
        final known = {
          for (final t in onScreen)
            if (t.role == TurnRole.ayma) t.text.trim(),
        };
        DateTime? newest;
        for (final t in onScreen) {
          final at = t.createdAt;
          if (at != null && (newest == null || at.isAfter(newest))) newest = at;
        }
        var added = false;
        for (final m in page.messages) {
          if (m.role != 'ayma' ||
              known.contains(m.text.trim()) ||
              !_reportMarker.hasMatch(m.text)) {
            continue;
          }
          final at = m.createdAt;
          if (newest != null && at != null && !at.isAfter(newest)) continue;
          _store.addTurn(
            TurnRole.ayma,
            m.text,
            TurnSource.text,
            tools: m.tools,
            subjectImage: m.subjectImage.isEmpty ? null : m.subjectImage,
            createdAt: at,
          );
          added = true;
        }
        if (added) return;
      }
    } catch (e) {
      // Best-effort: the card is in server history either way and shows on
      // the next history load.
      debugPrint('background result pull failed: $e');
    } finally {
      _pullingResults = false;
    }
  }

  void _consumeKickoff() {
    final k = ChatInbox.instance.take();
    if (k != null && mounted) _runKickoff(k);
  }

  /// A background skill fired from a button elsewhere in the app (Skills tab).
  /// Show a working turn, run it, drop the result in.
  Future<void> _runKickoff(ChatKickoff k) async {
    // Not gated behind `if (_sending) return` below — a page-context update
    // is a pure UI/context change, never a background skill run, so it
    // should never get stuck behind whatever else the chat is doing.
    if (k.kind == 'page_context') {
      _applyPageContext(k);
      return;
    }
    if (_sending) return;
    if (k.kind == 'deep_dive') {
      await _runDeepDive(k);
    } else if (k.kind == 'appearance') {
      await _runAppearance(k);
    } else if (k.kind == 'face_report' || k.kind == 'body_report') {
      await _runPhotoReport(k);
    } else if (k.kind == 'physical_attributes') {
      await _runPhysical(k);
    } else if (k.kind == 'talk_about') {
      await _runTalkAbout(k);
    } else if (k.kind == 'draft_about') {
      _startDraftAbout(k);
    } else if (k.kind == 'discuss_topic') {
      await _runDiscussTopic(k);
    } else if (k.kind == 'guided_tour') {
      await _runGuidedTour(k);
    } else if (k.kind == 'draft_text') {
      _composerController.text = k.draftBody;
      _composerController.selection =
          TextSelection.collapsed(offset: k.draftBody.length);
      _composerFocus.requestFocus();
    }
  }

  /// A guided-tour kickoff (Settings → "How to use Ayma"): seed the ask
  /// as a user turn and send it — the backend's deterministic tour routing
  /// starts the live guided tour; Ayma drives it from there.
  Future<void> _runGuidedTour(ChatKickoff k) async {
    if (_sending) return;
    const seed = 'Walk me through the app';
    _store.addTurn(TurnRole.user, seed, TurnSource.text);
    await _send(retry: seed, skipUserTurn: true);
  }

  /// A "draft about this" kickoff (e.g. "Ask Ayma" on a Web-research report
  /// or "Send to Ayma" on any shared target): attach the target as an un-sent
  /// card staged above an empty, focused composer. Nothing is added to the
  /// transcript and nothing is sent — [_send] posts the card when the user
  /// taps send (with or without typed text).
  void _startDraftAbout(ChatKickoff k) {
    final isSelf = k.editSelf ||
        (k.targetUid.isNotEmpty && k.targetUid == _currentUid());
    if (k.targetUid.isNotEmpty) _viewingOverride = k.targetUid;
    if (isSelf) _profileEdit = true;
    if (k.shareKind == 'match' && k.refId.isNotEmpty) {
      _matchReportId = k.refId;
    }
    setState(() {
      _pageContext = null;
      _pendingShared = _SharedDraft(
        kind: k.shareKind.isEmpty ? 'deep_dive' : k.shareKind,
        uid: k.targetUid,
        name: k.label.isNotEmpty ? k.label : 'them',
        photo: k.photoUrl,
        refId: k.refId,
        refVersion: k.refVersion,
        editSelf: isSelf,
      );
    });
    _composerFocus.requestFocus();
  }

  /// A `page_context` kickoff — the Ayma tab was just switched to from
  /// another tab (see `MainShellScreen._selectTab`). Updates the chip and
  /// what [_send] folds into `/chat`; never touches the transcript.
  void _applyPageContext(ChatKickoff k) {
    if (!mounted) return;
    if (_pendingShared != null) return;
    setState(() => _pageContext = k.screenContext);
  }

  /// The chip's own close button — stops showing/sending this page's context
  /// for the rest of the session (until another kickoff/embed sets a new one).
  void _clearPageContext() => setState(() => _pageContext = null);

  /// Routed in from the "Complete your profile" screen to talk through one
  /// questionnaire topic (a profile-completeness gap). Seed a short user turn
  /// and send it — Ayma's questionnaire skill picks the topic up from there.
  Future<void> _runDiscussTopic(ChatKickoff k) async {
    if (_sending) return;
    final label = k.label.trim();
    final seed = label.isEmpty
        ? "Let's work on filling in my profile — what's the most useful thing "
              'to cover?'
        : "Let's talk about $label.";
    _store.addTurn(TurnRole.user, seed, TurnSource.text);
    await _send(retry: seed, skipUserTurn: true);
  }

  /// Rebuild the structured physical-attributes record (Skills tab). Runs the
  /// vision pass here in the background — the Skills screen has already
  /// navigated away — over the whole profile grid plus any extra photos added
  /// on the Skills screen; resolves to a tappable report card.
  Future<void> _runPhysical(ChatKickoff k) async {
    setState(() => _sending = true);
    _store.addPending(
      'Building your physical profile — this can take a moment, you can keep '
      'chatting.',
    );
    try {
      final r = await _api.refreshPhysicalAttributes(
        extraPaths: k.attachmentPaths,
      );
      if (!mounted) return;
      if (r.usageCapped) {
        _store.resolvePending(kAymaOutOfCreditsMessage, capped: true);
      } else if (r.attributes.isEmpty && r.id.isEmpty) {
        _store.resolvePending(
          "I couldn't read any physical attributes yet — add a clear photo "
          'and try again from the Skills screen.',
        );
      } else {
        final n = r.attributes.length;
        final m = r.photoCount;
        _store.resolvePending(
          'Physical profile updated — $n attribute${n == 1 ? '' : 's'}'
          '${m > 0 ? ' from $m photo${m == 1 ? '' : 's'}' : ''}. '
          'It feeds your matching and Explore search.',
          tools: const ['Read your physical attributes'],
          reportKind: r.id.isEmpty ? '' : 'physical',
          reportId: r.id,
        );
      }
    } catch (_) {
      if (mounted) {
        _store.resolvePending(
          "Couldn't refresh your physical profile — try again shortly.",
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// The unified "Appearance" read fired from the Skills tab (or the
  /// missing-photo stub on the report screen). Runs the vision passes here in
  /// the background over the whole profile grid plus any added photos, gated by
  /// [ChatKickoff.wantFace] / [ChatKickoff.wantBody]; resolves to one tappable
  /// "Appearance report" card.
  Future<void> _runAppearance(ChatKickoff k) async {
    setState(() => _sending = true);
    _store.addPending(
      'Reading your photos — structured attributes plus an honest face and '
      'physique read. This can take a moment, you can keep chatting.',
    );
    try {
      final r = await _api.runAppearanceReport(
        imagePaths: k.attachmentPaths,
        wantFace: k.wantFace,
        wantBody: k.wantBody,
        faceMediaIds: k.faceMediaIds,
        bodyMediaIds: k.bodyMediaIds,
      );
      if (!mounted) return;
      if (r.usageCapped) {
        _store.resolvePending(kAymaOutOfCreditsMessage, capped: true);
      } else if (r.report == null || r.reportId.isEmpty) {
        _store.resolvePending(
          "I couldn't read your photos — add a clear photo and try again from "
          'the Skills screen.',
        );
      } else {
        final rep = r.report!;
        final parts = <String>[
          if (rep.attributesStatus.isEmpty) 'your structured attributes',
          if (rep.face != null) 'a face read',
          if (rep.body != null) 'a physique read',
        ];
        final gaps = <String>[
          if (rep.faceStatus.isNotEmpty) 'a clear face photo',
          if (rep.bodyStatus.isNotEmpty) 'a body photo',
        ];
        _store.resolvePending(
          'Appearance report ready — ${parts.isEmpty ? 'a full read' : parts.join(', ')}. '
          '${gaps.isEmpty ? 'It feeds your matching and Explore search.' : 'Add ${gaps.join(' and ')} to fill it out.'}',
          tools: const ['Read your photos'],
          reportKind: 'appearance',
          reportId: r.reportId,
        );
      }
    } catch (_) {
      if (mounted) {
        _store.resolvePending(
          "Couldn't finish your Appearance report — try again shortly.",
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// A person / conversation / match report shared into the chat from elsewhere
  /// in the app. Show a card for it, pin the person as Ayma's context for the
  /// rest of the session, and open with a seed instruction.
  Future<void> _runTalkAbout(ChatKickoff k) async {
    if (k.targetUid.isEmpty || _sending) return;
    _viewingOverride = k.targetUid;
    if (k.editSelf) _profileEdit = true;
    if (k.shareKind == 'match' && k.refId.isNotEmpty) {
      _matchReportId = k.refId;
    }
    final who = k.label.isNotEmpty ? k.label : 'them';
    final seed = k.editSelf
        ? "Let's go through my public profile together — tell me what's there "
              "and what you'd change."
        : switch (k.shareKind) {
            'story' =>
              "Here's my story — the portrait you've written about me. "
                  "Let's go through it together: what's in it, and what "
                  "should change?",
            'appearance' =>
              "Here's my appearance report. Walk me through it — what "
                  "stands out, and what should I do with it?",
            'conversation' =>
              "Here's my conversation with $who. Pull it up and tell me what "
                  "you make of it — and what I should do next.",
            'match' =>
              "Here's my match report with $who. Walk me through it — what "
                  "stands out, and is this worth pursuing?",
            _ => "Let's talk about $who. What's your read on them for me?",
          };
    _store.addSharedTurn(
      kind: k.shareKind.isEmpty ? 'profile' : k.shareKind,
      uid: k.targetUid,
      name: who,
      photo: k.photoUrl,
      refId: k.refId,
      text: seed,
    );
    await _send(retry: seed, skipUserTurn: true);
  }

  Future<void> _runDeepDive(ChatKickoff k) async {
    final who = k.label.isNotEmpty
        ? k.label
        : (k.targetUid.isEmpty ? 'you' : 'them');
    _store.addPending('Searching the web for $who — this can take a moment…');
    setState(() => _sending = true);
    try {
      final r = await _api.deepDive(targetUid: k.targetUid);
      if (!mounted) return;
      final label = r.toolLabel.isNotEmpty
          ? r.toolLabel
          : 'Researched $who online';
      if (r.usageCapped) {
        _store.resolvePending(kAymaOutOfCreditsMessage, capped: true);
      } else if (r.queued) {
        // Running server-side — finishes even if you leave the app. Show that,
        // then poll history so it drops in live if you stay.
        _store.updatePendingText(
          "Looking $who up on the web — you can leave the app, "
          "I'll ping you when it's ready.",
        );
        await _awaitBackgroundReply(
          fallbackTools: [label],
          fallbackSubjectImage: r.subjectImage.isEmpty ? null : r.subjectImage,
        );
      } else {
        _store.resolvePending(
          r.summary,
          tools: [label],
          subjectImage: r.subjectImage.isEmpty ? null : r.subjectImage,
          reportKind: r.reportId.isEmpty ? '' : 'deep_dive',
          reportId: r.reportId,
        );
      }
    } catch (_) {
      if (mounted) {
        _store.resolvePending(
          "Couldn't finish that search — try again shortly.",
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// Poll `/chat/history` for the Ayma turn a queued background skill will
  /// write, and swap the pending placeholder for it. The push notification
  /// covers the app-closed case; this just makes it land live if you stay.
  Future<void> _awaitBackgroundReply({
    required List<String> fallbackTools,
    String? fallbackSubjectImage,
  }) async {
    final knownAyma = _store.turns
        .where((t) => t.role == TurnRole.ayma && t.isFinal)
        .map((t) => t.text)
        .toSet();
    for (var i = 0; i < 30 && mounted; i++) {
      await Future<void>.delayed(const Duration(seconds: 5));
      if (!mounted) return;
      try {
        final page = await _api.chatHistory(limit: 4);
        final fresh = page.messages.lastWhere(
          (m) => m.role == 'ayma' && !knownAyma.contains(m.text),
          orElse: () => const ChatMessage(role: '', text: ''),
        );
        if (fresh.text.isNotEmpty) {
          _store.resolvePending(
            fresh.text,
            tools: fresh.tools.isNotEmpty ? fresh.tools : fallbackTools,
            subjectImage: fresh.subjectImage.isNotEmpty
                ? fresh.subjectImage
                : fallbackSubjectImage,
          );
          return;
        }
      } catch (_) {
        /* keep polling */
      }
    }
    if (mounted) {
      _store.resolvePending(
        "That's taking a little longer than usual — I'll drop it in here and "
        "notify you the moment it's ready.",
      );
    }
  }

  /// The send whose connection died before an answer arrived, held for
  /// reconciliation instead of being declared failed (the founder bug: a
  /// slow turn — image generation, 10–30s — survives the app being
  /// backgrounded server-side, completes and is billed, yet the returning
  /// user saw "Something went wrong. [Retry]"). Non-null while the pending
  /// "Thinking…" turn is in its waiting state; cleared once the turn is
  /// adopted from the server, genuinely fails, or a new send supersedes it.
  _PendingSendReconcile? _reconcile;

  /// Reentrancy guard for [_reconcilePendingSend] — the failure path and an
  /// app-resume can both trigger it.
  bool _reconciling = false;

  /// True when a send failure should be reconciled against the server rather
  /// than declared failed: the failure is connection-class (socket died,
  /// stream cut mid-read, timeout after the send began — an [ApiException]
  /// with no HTTP status), or the app left the foreground mid-send (the OS
  /// kills the socket; whatever error that surfaces as, the server may well
  /// have finished the turn). A genuine 4xx/5xx *response* with the app in
  /// the foreground the whole time is a real failure and stays one.
  /// User-facing copy for a send failure that was NOT reconciled: when the
  /// failure carries an HTTP status, the server answered and rejected the
  /// send, so say so — never blame a connection that was not broken
  /// (2026-11-07: a 422 rejection showed "Check your connection."). The
  /// connection wording is kept only for failures with no server response
  /// at all. (The client-fabricated 408 timeout is connection-class, not a
  /// server answer.)
  String _sendFailureMessage(Object error) {
    if (error is ApiException &&
        error.statusCode != null &&
        !error.message.startsWith('Request timed out')) {
      return 'Ayma hit a problem with that message — try again.';
    }
    return "Couldn't reach Ayma. Check your connection.";
  }

  bool _shouldReconcile(Object error) {
    if (_backgroundedDuringSend) return true;
    if (error is SocketException || error is TimeoutException) return true;
    if (error is ApiException) {
      return error.statusCode == null &&
          error.message.startsWith('Network error');
    }
    return false;
  }

  /// Park the failed send for reconciliation: the pending turn stays (in a
  /// "reconnecting" state instead of flashing an error), and reconciliation
  /// starts now — and again on every app resume while it stays unresolved.
  /// When the connection heartbeat reports the link healthy again, a send
  /// parked in the waiting state ([_reconcile]) retries immediately instead
  /// of sitting until the next app resume.
  void _onConnectionRecovered() {
    if (!mounted) return;
    if (ConnectionHeartbeat.instance.state != ConnectionQuality.ok) return;
    if (_reconcile != null) unawaited(_reconcilePendingSend());
  }

  /// Whether the two-drops switch offer (chunk D) has already been shown
  /// for the current voice session; re-arms when the session ends.
  bool _asyncSwitchOffered = false;

  /// Chunk D degrade: once ONE live session has dropped and started
  /// re-establishing twice, the connection has shown it cannot hold a call
  /// — offer the one-tap switch of this conversation to a voice message
  /// (stop the call, open the recorder). Offered once per session.
  void _onVoiceDropsChanged() {
    if (!mounted) return;
    if (!_voice.isActive) {
      _asyncSwitchOffered = false;
      return;
    }
    if (_asyncSwitchOffered || _voice.reconnectCount < 2) return;
    _asyncSwitchOffered = true;
    // Voice-note recording lives only in human-to-human DMs (founder,
    // 2026-11-06): a dropping call offers no recording fallback here.
    AymaToast.show(
      context,
      'This connection keeps dropping.',
      kind: AymaToastKind.error,
    );
  }

  void _beginReconcile(_PendingSendReconcile rec) {
    _reconcile = rec;
    _store.updatePendingText('Reconnecting…');
    unawaited(_reconcilePendingSend());
  }

  /// Reconcile a connection-dropped send against the server instead of
  /// trusting the dead socket's error:
  ///
  /// 1. Check `/chat/history` a few times for this send's finished turn —
  ///    matched by [ _PendingSendReconcile.msgId] (`client_msg_id`, exact),
  ///    with the pre-send known-replies set as the fallback for a server
  ///    that predates ids. Found → adopt the server's turn, done.
  /// 2. Not landed: re-ask over plain `/chat` with the SAME `client_msg_id`.
  ///    The server is idempotent on it — a finished turn is answered from
  ///    the persisted reply, a still-running one is joined, and only a turn
  ///    it genuinely never received is run (which is exactly a retry). This
  ///    is what lets a 10–30s image turn ride out the disconnect: the re-ask
  ///    simply waits on the original run.
  /// 3. Still cut off → stay in the waiting state (the next app resume
  ///    retries). A real server-side failure → drop the pending turn and
  ///    show the usual Retry — which reuses the same id, so even a
  ///    misjudged retry can never double-send a turn that DID land.
  Future<void> _reconcilePendingSend() async {
    final rec = _reconcile;
    if (rec == null || _reconciling) return;
    _reconciling = true;
    try {
      for (var i = 0; i < 3 && mounted; i++) {
        if (i > 0) {
          await Future<void>.delayed(const Duration(seconds: 2));
        }
        if (!mounted || !identical(_reconcile, rec)) return;
        try {
          final page = await _api.chatHistory(limit: 10);
          final landed = page.messages.lastWhere(
            (m) =>
                m.role == 'ayma' &&
                (m.clientMsgId.isNotEmpty
                    ? m.clientMsgId == rec.msgId
                    : !rec.knownAyma.contains(m.text)),
            orElse: () => const ChatMessage(role: '', text: ''),
          );
          if (landed.role.isNotEmpty) {
            if (!mounted || !identical(_reconcile, rec)) return;
            _reconcile = null;
            _store.resolvePending(
              landed.text,
              tools: landed.tools,
              imageUrl: landed.imageUrl.isEmpty ? null : landed.imageUrl,
              subjectImage:
                  landed.subjectImage.isEmpty ? null : landed.subjectImage,
            );
            widget.onExchange?.call();
            return;
          }
        } catch (_) {
          /* still cut off — keep trying briefly */
        }
      }
      if (!mounted || !identical(_reconcile, rec)) return;
      final result = await rec.resend();
      if (!mounted || !identical(_reconcile, rec)) return;
      _reconcile = null;
      _store.resolvePending(
        result.reply,
        tools: result.toolsUsed,
        capped: result.usageCapped,
        imageUrl: result.imageUrl,
        feedbackKind: result.feedbackCard?.kind ?? '',
        feedbackTitle: result.feedbackCard?.title ?? '',
        feedbackBody: result.feedbackCard?.body ?? '',
      );
      _offerServerBubble(result.feedbackBubble);
      if (result.usageCapped) {
        if (_canQueue && rec.queueable) {
          _holdForCredits(
            message: rec.message,
            msgId: rec.msgId,
            imagePath: rec.imagePath,
          );
        }
      } else {
        widget.onExchange?.call();
      }
    } catch (e) {
      if (!mounted || !identical(_reconcile, rec)) return;
      if (_shouldReconcile(e)) {
        // Still no connection: keep waiting — the next resume tries again.
        _store.updatePendingText('Waiting for a connection…');
      } else {
        // The server answered and it's a genuine failure — now (and only
        // now) surface the error. Retry reuses the same client id, so it
        // can never double-send a turn that did land.
        _reconcile = null;
        _store.dropPending();
        if (mounted) {
          AymaToast.show(
            context,
            'Something went wrong sending that message.',
            kind: AymaToastKind.error,
            action: AymaToastAction(
              label: 'Retry',
              onPressed: () =>
                  _send(retry: rec.message, clientMsgId: rec.msgId),
            ),
          );
        }
      }
    } finally {
      _reconciling = false;
    }
  }

  /// Face / body report fired from the Skills tab. The Skills screen normally
  /// resolves the photo source itself and the kickoff carries the choice
  /// (`photoSource` set, plus `attachmentPath` when a photo was uploaded), so
  /// this runs straight away. The in-chat chooser below is the fallback for a
  /// kickoff that arrives without a choice — e.g. Ayma calling the tool herself.
  Future<void> _runPhotoReport(ChatKickoff k) async {
    final face = k.kind == 'face_report';
    final subject = face ? 'face' : 'full-body';

    var attachmentPath = k.attachmentPath;
    if (attachmentPath.isEmpty && k.photoSource.isEmpty) {
      final choice = await showModalBottomSheet<String>(
        context: context,
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Which $subject photo should I read?',
                    style: AymaType.sans(size: 14, color: context.ac.fgDim),
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.account_circle_outlined),
                title: const Text('Use my profile photo'),
                onTap: () => Navigator.pop(ctx, 'profile'),
              ),
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('Upload a photo'),
                onTap: () => Navigator.pop(ctx, 'pick'),
              ),
            ],
          ),
        ),
      );
      if (choice == null || !mounted) return;
      if (choice == 'pick') {
        final XFile? picked;
        try {
          picked = await _picker.pickImage(
            source: ImageSource.gallery,
            maxWidth: 1600,
            imageQuality: 88,
          );
        } catch (_) {
          _store.addTurn(
            TurnRole.ayma,
            "Couldn't open that image.",
            TurnSource.text,
          );
          return;
        }
        if (picked == null || !mounted) return;
        setState(() => _sending = true);
        try {
          final up = await _chat.uploadChatImage(File(picked.path));
          attachmentPath = up.storagePath;
        } catch (_) {
          if (mounted) {
            setState(() => _sending = false);
            _store.addTurn(
              TurnRole.ayma,
              "Couldn't upload that photo.",
              TurnSource.text,
            );
          }
          return;
        }
      }
    }

    if (!mounted) return;
    setState(() => _sending = true);
    _store.addPending(
      face ? 'Reading your face photo…' : 'Reading your photo…',
    );
    try {
      final reportId = face
          ? await _runFace(attachmentPath)
          : await _runBody(attachmentPath);
      if (!mounted) return;
      if (reportId == _kCapped) {
        _store.resolvePending(kAymaOutOfCreditsMessage, capped: true);
      } else if (reportId == _kNoPhoto) {
        _store.resolvePending(
          'Add a profile photo first — open Photos on your profile, or send '
          "me a $subject shot right here and I'll read that.",
        );
      } else if (reportId == _kUnusable) {
        _store.resolvePending(
          face
              ? "I can't get a clean read on that one — send a clearer, "
                    'front-facing shot with your whole face in frame.'
              : "I can't get a clean read on that one — send a clearer shot "
                    'with your upper body or more visible, in neutral '
                    'lighting.',
        );
      } else if (reportId.isEmpty) {
        _store.resolvePending(
          "Couldn't finish that report — try again shortly.",
        );
      } else {
        _store.resolvePending(
          'Here’s your honest read — full breakdown below.',
          tools: const ['Analysed the photo'],
          reportKind: face ? 'face' : 'body',
          reportId: reportId,
        );
      }
    } catch (_) {
      if (mounted) {
        _store.resolvePending(
          "Couldn't finish that report — try again shortly.",
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  static const _kCapped = 'capped';
  static const _kNoPhoto = 'nophoto';
  static const _kUnusable = 'unusable';

  Future<String> _runFace(String attachmentPath) async {
    try {
      final r = await _api.faceReport(attachmentPath: attachmentPath);
      if (r.usageCapped) return _kCapped;
      if (r.report == null || !r.report!.usable) return _kUnusable;
      return r.reportId;
    } on ApiException catch (e) {
      if (e.statusCode == 400) return _kNoPhoto;
      rethrow;
    }
  }

  Future<String> _runBody(String attachmentPath) async {
    try {
      final r = await _api.bodyReport(attachmentPath: attachmentPath);
      if (r.usageCapped) return _kCapped;
      if (r.report == null || !r.report!.usable) return _kUnusable;
      return r.reportId;
    } on ApiException catch (e) {
      if (e.statusCode == 400) return _kNoPhoto;
      rethrow;
    }
  }

  Future<void> _loadHistory() async {
    try {
      final target = widget.targetTimestamp.isEmpty
          ? null
          : DateTime.tryParse(widget.targetTimestamp);

      // Offline-first: on a plain open, paint the last-known conversation
      // from the on-device cache while the fetch below runs; the fetch
      // re-seeds with the server's page when it lands. A history-jump
      // target keeps the exact server-driven behavior.
      if (target == null && _store.isEmpty) {
        await _restoreCachedHistory();
      }

      // Ride through a scale-to-zero cold start: the first page uses a
      // cold-start-tolerant timeout and auto-retries with exponential backoff
      // over a generous budget, staying on the loading spinner the whole time.
      // Only a sustained failure (budget spent) falls through to the catch and
      // the manual "Couldn't load — Retry" state — never the first timeout.
      var page = await withColdStartRetry(
        () => _api.chatHistory(limit: 40, timeout: kColdStartCallTimeout),
        onRetry: () {
          if (mounted) setState(() => _historyRetrying = true);
        },
      );
      var messages = page.messages;
      // Refresh the last-known cache with the freshest page, so the next
      // cold start paints this conversation instantly.
      _persistHistoryPage(page.messages);
      // A target may sit further back than the most recent page — keep
      // paging older until it's covered or history runs out. This is a
      // one-time, user-initiated jump (tap a provenance source), so there's
      // no tight page budget — just a generous safety cap against a runaway
      // loop on pathologically long history.
      if (target != null) {
        var before = page.nextBefore;
        var guard = 0;
        while (before != null &&
            guard < 50 &&
            (messages.isEmpty ||
                (messages.first.createdAt?.isAfter(target) ?? false))) {
          final older = await _api.chatHistory(before: before, limit: 40);
          if (older.messages.isEmpty) break;
          messages = [...older.messages, ...messages];
          before = older.nextBefore;
          guard++;
        }
        _nextBefore = before;
      } else {
        _nextBefore = page.nextBefore;
      }


      final turns = await _historyTurns(messages);
      if (!mounted) return;

      // The first loaded turn at/after the target, found in the *full*
      // fetched window before any trimming. Finding this against the
      // post-trim store instead (as a previous version of this method did)
      // meant any target older than the store's rolling window (100 turns)
      // silently fell off the front on every load — collapsing every old
      // provenance source onto whichever turn happened to survive the trim,
      // i.e. always the same message regardless of which source was tapped.
      TranscriptTurn? anchor;
      if (target != null) {
        for (final t in turns) {
          if (t.createdAt != null && !t.createdAt!.isBefore(target)) {
            anchor = t;
            break;
          }
        }
      }

      // Seed a window guaranteed to keep the anchor. `TranscriptStore.seed`
      // trims to its most-recent-N tail, which would otherwise discard an
      // anchor that's further back than that — so when the fetched history
      // is longer than the store's cap, seed a window that starts at (with a
      // little leading context) the anchor instead of at the very start.
      var windowed = turns;
      final cap = _store.maxTurns;
      if (turns.length > cap) {
        final anchorIdx = anchor == null ? -1 : turns.indexOf(anchor);
        final start = anchorIdx < 0
            ? turns.length - cap
            : (anchorIdx - 10).clamp(0, turns.length - cap);
        windowed = turns.sublist(start, start + cap);
      }

      final uid = _currentUid();
      await ThumbsDownStore.instance.load(uid);
      _store.seed(windowed);
      // Counts any live voice turns `seed` kept after the history too: the
      // voice agent persists those itself when the call ends, so this
      // screen's dispose must not post them again.
      _seededCount = _store.turns.length;
      _historyError = null;
      if (target != null) {
        _scrollToTarget(anchor);
      } else {
        _pendingTargetScroll = false;
      }
    } catch (e) {
      // A load failure must not render the same as an empty history — record it
      // so the view can offer a retry (see `_historyError`). When the
      // last-known cache already painted the conversation, a failed refresh
      // leaves it on screen instead (the connection banner explains why it
      // may be stale); the error state is only for a truly empty screen.
      debugPrint('chat history load failed: $e');
      if (mounted && _store.isEmpty) {
        _historyError = "Couldn't load your conversation history.";
      }
      _pendingTargetScroll = false;
    } finally {
      if (mounted) setState(() => _loadingHistory = false);
    }
  }

  /// Map server history rows to transcript turns, resolving each row's
  /// image the same way for a fresh load and a cached restore.
  Future<List<TranscriptTurn>> _historyTurns(List<ChatMessage> messages) async {
    final turns = <TranscriptTurn>[];
    for (final m in messages) {
      // A server-resolved image_url (Ayma-generated image) wins; only a
      // client-readable uploads/{uid} path is resolved here.
      final url = await resolveHistoryImage(
        imageUrl: m.imageUrl,
        imagePath: m.imagePath,
        resolvePath: (p) => FirebaseStorage.instance.ref(p).getDownloadURL(),
      );
      // Same pair for a voice turn: Ayma's reply URL is server-resolved,
      // the user's clip path resolves here (best-effort — a dropped clip
      // still renders its transcript).
      final audio = await resolveHistoryImage(
        imageUrl: m.audioUrl,
        imagePath: m.audioPath,
        resolvePath: (p) => FirebaseStorage.instance.ref(p).getDownloadURL(),
      );
      String text = m.text;
      String replySubject = '';
      String replySnippet = '';
      String replyKind = '';
      final replyMatch = RegExp(r'^\[Replying to ([^:]+): "(.*?)"\]\n(.*)$', dotAll: true).firstMatch(text);
      if (replyMatch != null) {
        replySubject = replyMatch.group(1)!;
        replySnippet = replyMatch.group(2)!;
        final lowerSubject = replySubject.toLowerCase();
        replyKind = (lowerSubject == 'ayma' || lowerSubject == 'you') ? 'message' : 'page';
        text = replyMatch.group(3)!;
      }
      turns.add(
        TranscriptTurn(
          role: m.role == 'ayma' ? TurnRole.ayma : TurnRole.user,
          text: text,
          source: audio == null ? TurnSource.text : TurnSource.voice,
          imageUrl: url,
          audioUrl: audio,
          tools: m.tools,
          subjectImage: m.subjectImage.isEmpty ? null : m.subjectImage,
          createdAt: m.createdAt,
          replySubject: replySubject,
          replySnippet: replySnippet,
          replyKind: replyKind,
        ),
      );
    }
    return turns;
  }

  /// Paint the last-known conversation from the on-device cache
  /// (offline-first) while the history fetch is in flight. Only fills an
  /// empty store, so a live session already on screen is never disturbed.
  /// Best-effort: any storage/parse problem leaves the normal load alone.
  Future<void> _restoreCachedHistory() async {
    final uid = _currentUid();
    if (uid.isEmpty) return;
    try {
      final raw = await ReportCache.instance
          .readReport(uid, 'last_known', 'chat_history');
      if (raw == null || !mounted || !_store.isEmpty) return;
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final messages = ((decoded['messages'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(ChatMessage.fromMap)
          .toList();
      if (messages.isEmpty) return;
      final turns = await _historyTurns(messages);
      if (!mounted || !_store.isEmpty) return;
      _store.seed(turns);
      // Cache-restored turns are history, not this session's sends — the
      // dispose-time raw-turn post must skip them exactly like a server seed.
      _seededCount = _store.turns.length;
    } catch (_) {
      // A corrupt / unreadable cache entry just means a normal load.
    }
  }

  /// Persist the freshest history page as the last-known conversation, so
  /// the next cold start paints instantly even with no connection.
  void _persistHistoryPage(List<ChatMessage> messages) {
    final uid = _currentUid();
    if (uid.isEmpty) return;
    unawaited(ReportCache.instance.writeReport(
      uid,
      'last_known',
      'chat_history',
      jsonEncode({'messages': [for (final m in messages) m.toMap()]}),
    ));
  }

  /// Scroll listener: once the user nears the top of the loaded window, page
  /// in the next older batch from `/chat/history` — the same
  /// `before`/`next_before` cursor mechanism [_loadHistory] already uses for
  /// a provenance-jump, just triggered by scrolling instead of a one-time
  /// target search. Stands down during a pending target-jump scroll (its
  /// animation can pass through low offsets transiently) and while a fetch
  /// is already in flight.
  void _maybeLoadOlderHistory() {
    if (_pendingTargetScroll || _loadingOlder || _nextBefore == null) return;
    if (!_scrollController.hasClients) return;
    if (_scrollController.position.pixels <= 200) {
      _loadOlderHistory();
    }
  }

  Future<void> _loadOlderHistory() async {
    final before = _nextBefore;
    if (before == null || _loadingOlder) return;
    setState(() => _loadingOlder = true);
    // Anchor: whichever turn currently sits at the front of the loaded
    // window. Its on-screen Y position — not `ScrollPosition.maxScrollExtent`
    // — is what lets the view hold steady once older turns splice in ahead
    // of it: for a variable-height list, `maxScrollExtent` is only an
    // estimate until every item's been laid out, so a delta computed from it
    // drifts; the anchor's real painted position doesn't.
    final anchorTurn = _store.turns.isNotEmpty ? _store.turns.first : null;
    double? anchorYBefore;
    if (anchorTurn != null) {
      final box =
          _turnKeys[anchorTurn]?.currentContext?.findRenderObject()
              as RenderBox?;
      if (box != null && box.attached) {
        anchorYBefore = box.localToGlobal(Offset.zero).dy;
      }
    }
    try {
      final older = await _api.chatHistory(before: before, limit: 40);
      if (!mounted) return;
      if (older.messages.isEmpty) {
        _nextBefore = null;
        return;
      }
      final olderTurns = <TranscriptTurn>[];
      for (final m in older.messages) {
        final url = await resolveHistoryImage(
          imageUrl: m.imageUrl,
          imagePath: m.imagePath,
          resolvePath: (p) => FirebaseStorage.instance.ref(p).getDownloadURL(),
        );
        final audio = await resolveHistoryImage(
          imageUrl: m.audioUrl,
          imagePath: m.audioPath,
          resolvePath: (p) => FirebaseStorage.instance.ref(p).getDownloadURL(),
        );
        olderTurns.add(
          TranscriptTurn(
            role: m.role == 'ayma' ? TurnRole.ayma : TurnRole.user,
            text: m.text,
            source: audio == null ? TurnSource.text : TurnSource.voice,
            imageUrl: url,
            audioUrl: audio,
            tools: m.tools,
            subjectImage: m.subjectImage.isEmpty ? null : m.subjectImage,
            createdAt: m.createdAt,
          ),
        );
      }
      if (!mounted) return;
      _nextBefore = older.nextBefore;
      _seededCount += olderTurns.length;
      _pendingOlderScroll = true;
      _store.prependOlder(olderTurns);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _pendingOlderScroll = false;
        if (!mounted || !_scrollController.hasClients) return;
        if (anchorTurn == null || anchorYBefore == null) return;
        final box =
            _turnKeys[anchorTurn]?.currentContext?.findRenderObject()
                as RenderBox?;
        if (box == null || !box.attached) return;
        final anchorYAfter = box.localToGlobal(Offset.zero).dy;
        final delta = anchorYAfter - anchorYBefore;
        if (delta != 0) {
          _scrollController.jumpTo(_scrollController.position.pixels + delta);
        }
      });
    } catch (e) {
      // A failed older-page fetch just means the user can't scroll back
      // further right now — leave `_nextBefore` as-is so the next scroll
      // tick retries rather than silently giving up on history.
      debugPrint('older chat history load failed: $e');
    } finally {
      if (mounted) setState(() => _loadingOlder = false);
    }
  }

  void _retryHistory() {
    if (_loadingHistory) return;
    setState(() {
      _loadingHistory = true;
      _historyError = null;
      _historyRetrying = false;
    });
    _loadHistory();
  }

  @override
  void dispose() {
    _store.removeListener(_syncVoiceClips);
    VoiceClipRegistry.instance.clear(this);
    _store.removeListener(_onStoreCapped);
    WidgetsBinding.instance.removeObserver(this);
    _highlightClearTimer?.cancel();
    if (widget.askAymaContext == null) {
      // Session-end raw_turns persistence (§1.7 step 8). Fire-and-forget —
      // the screen is going away; the request rides the app's remaining
      // lifetime. Only turns added this session (voice + text) — the seeded
      // history is already persisted server-side. Skipped for a scoped
      // Ask-Ayma turn: every one of its turns is already persisted by the
      // `/chat`/`/chat/stream` calls themselves (see [_send]) — there's no
      // separate live-voice raw transcript to catch up here, since
      // [_pttVoice]'s own store never feeds [_store] (see that field's doc).
      final fresh = _store.wireTurns(skip: _seededCount);
      if (fresh.isNotEmpty) {
        try {
          _api.postTurn(_sessionId, fresh).catchError((_) {});
        } catch (_) {
          /* teardown must not throw */
        }
      }
      ChatInbox.instance.pending.removeListener(_consumeKickoff);
      ChatInbox.instance.resultsLanded.removeListener(_onResultsLanded);
      ConnectionHeartbeat.instance.listenable
          .removeListener(_onConnectionRecovered);
      _voice.removeListener(_onVoiceDropsChanged);
    }
    // This screen always owns [_pttVoice] (unlike [_voice], which is handed
    // down from the shared shell/orb sheet and must outlive this screen) —
    // dispose it unconditionally, null-safely (it's only ever non-null in
    // Ask-Ayma mode). It tears down its LiveKit room/subscriptions and clears
    // `VoiceSessionController.active` if it was the active one, whether or
    // not a capture was actually in progress.
    _pttVoice?.removeListener(_onPttVoiceChanged);
    _pttStore?.removeListener(_onPttTranscriptChanged);
    _pttVoice?.dispose();
    _pttStore?.dispose();
    // The async voice controller is only ever touched in the plain
    // conversation (see initState's `_canQueue` gate) — the guard below
    // keeps dispose from constructing it from scratch just to tear it
    // down, the same `late final` hazard the [_voice] guard documents.
    if (_canQueue) {
      _voiceMessage.removeListener(_onVoiceMessageChanged);
      if (widget.asyncVoiceController == null) _voiceMessage.dispose();
    }
    if (widget.asyncVoicePlayer == null) _clipPlayer.dispose();
    _nowPlaying.dispose();
    _store.removeListener(_scrollToBottom);
    _composerController.dispose();
    _composerFocus.dispose();
    if (widget.scrollController == null) _scrollController.dispose();
    // Guarded on `askAymaContext == null` too, not just `voiceController ==
    // null` — [_voice] is never touched at all in Ask-Ayma mode (that mode
    // uses [_pttVoice] instead), and reading a `late final` field here for
    // the first time would construct it from scratch just to immediately
    // dispose it.
    if (widget.askAymaContext == null && widget.voiceController == null) {
      _voice.dispose();
    }
    if (widget.transcriptStore == null) _store.dispose();
    super.dispose();
  }

  Future<void> _toggleVoice() async {
    if (_voice.isActive) {
      await _voice.stop();
    } else {
      // Founder revision (2026-09-26, superseding the 2026-09-25 "voice-only
      // mode" auto-push): the mic ONLY starts the session inline — the
      // composer morphs into the live call bar in place, and the full-screen
      // orb view ([VoiceCallScreen]) is never pushed from here. Going
      // full-screen is now always an explicit, separate gesture: the
      // expand button in the chat header while a call is live (see the
      // header's `action` in [build]), or tapping the inline call bar
      // ([_Composer.onExpandTap]).
      // Degrade glue (chunk D): the heartbeat's word decides whether a live
      // call is even attempted. Offline -> no attempt (a connect is doomed
      // and would only burn the retry): a clear note plus the voice-message
      // offer — the same fallback a failed start gets below. Weak -> the
      // forgiving relay route from the first attempt.
      final decision =
          voiceEntryDecision(ConnectionHeartbeat.instance.state);
      if (decision == VoiceEntryDecision.denyOffline) {
        AymaToast.show(
          context,
          "You're offline — a live call needs a connection.",
          kind: AymaToastKind.error,
        );
        return;
      }
      await _voice.start(
          forceRelayFirst: decision == VoiceEntryDecision.allowRelayFirst);
      if (!mounted) return;
      if (_voice.phase == VoiceSessionPhase.error &&
          _voice.errorMessage != null) {
        if (_voice.cappedError) {
          // Same reusable "out of credits" affordance as everywhere else
          // (chat's skills-triggered jobs, the profile screen) — a real
          // Reload action, not just a mention of the word in plain text.
          showOutOfCreditsSheet(context);
        } else {
          // The call couldn't connect — offer the async fallback instead
          // of a dead end: a voice message sends whenever the connection
          // allows, and Ayma answers out loud in this same thread.
          final message = _voice.errorMessage!;
          // Voice-note recording lives only in human-to-human DMs (founder,
          // 2026-11-06): a failed call offers no recording fallback here.
          AymaToast.show(
            context,
            message,
            kind: AymaToastKind.error,
          );
        }
      }
    }
  }

  /// Surface a recording failure (mic denied, couldn't start) once, as a
  /// toast — the controller already stayed idle, so there is no stuck UI.
  void _onVoiceMessageChanged() {
    final error = _voiceMessage.takeError();
    if (error != null && mounted) {
      AymaToast.show(context, error, kind: AymaToastKind.error);
    }
  }

  int _seenCappedEvents = 0;

  /// Opens the upgrade sheet once per capped chat reply.
  void _onStoreCapped() {
    if (_store.cappedEvents == _seenCappedEvents) return;
    _seenCappedEvents = _store.cappedEvents;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) showOutOfCreditsSheet(context);
    });
  }

  /// Opens the full-screen voice view over whatever's on screen now — only
  /// ever for a call that's already going (the header's expand button while
  /// a session is live, or tapping the composer's inline call bar — see
  /// [_Composer]'s `onExpandTap`); starting a call ([_toggleVoice]) no
  /// longer pushes it. Purely presentational: never touches the session
  /// itself, so it's always safe to call regardless of [_voice]'s phase.
  /// Only reachable from the main full-duplex [_voice] path — the separate
  /// Ask-Ayma push-to-talk mode below ([_pttVoice]) has no full-screen
  /// presentation of its own (a single-utterance capture that ends itself
  /// the moment it finalizes has nothing worth going full-screen for).
  Future<void> _openVoiceScreen() async {
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => VoiceCallScreen(voice: _voice),
      ),
    );
  }

  // --- Ask-Ayma push-to-talk voice (see [ChatScreen.askAymaContext]'s doc
  // and [_pttVoice]'s field doc) -------------------------------------------

  void _onPttVoiceChanged() {
    if (!mounted) return;
    if (_pttListening && _pttVoice!.phase == VoiceSessionPhase.error) {
      final msg = _pttVoice.errorMessage ?? "Couldn't start voice.";
      final capped = _pttVoice.cappedError;
      setState(() => _pttListening = false);
      if (capped) {
        showOutOfCreditsSheet(context);
      } else {
        AymaToast.show(context, msg, kind: AymaToastKind.error);
      }
      return;
    }
    setState(() {});
  }

  /// Fires on every push-to-talk voice-store change while a capture is live
  /// — looks for the moment the user's utterance finalizes (Gemini Live's
  /// own turn-detection, not a manual stop) and routes it into [_send]
  /// exactly like typed text: set it as the composer's text and send, so
  /// every bit of [_send]'s normal handling (optimistic turn, context
  /// fields, streaming, error recovery) applies unchanged.
  void _onPttTranscriptChanged() {
    if (!_pttListening) return;
    final turns = _pttStore!.turns;
    if (turns.isEmpty) return;
    final last = turns.last;
    if (last.role != TurnRole.user || !last.isFinal) return;
    final text = last.text;
    setState(() => _pttListening = false);
    unawaited(_pttVoice!.stop());
    if (text.trim().isNotEmpty) {
      _composerController.text = text;
      _send();
    }
  }

  /// Mic tapped from the idle composer — starts a push-to-talk capture,
  /// unless the main Ayma tab (or another Ask-Ayma turn) already has a live
  /// voice call going, in which case this declines rather than opening a
  /// second parallel LiveKit connection.
  Future<void> _onPttMicPressed() async {
    if (_sending || _pttListening) return;
    final other = VoiceSessionController.active;
    if (other != null && other != _pttVoice && other.isActive) {
      AymaToast.show(
        context,
        "You're already on a voice call with Ayma — finish that "
        'first, then try again here.',
        kind: AymaToastKind.warning,
      );
      return;
    }
    setState(() => _pttListening = true);
    await _pttVoice!.start();
  }

  /// The composer's "End voice" button tapped mid-capture — a deliberate
  /// cancel, same as ending a call in the main chat screen: nothing is sent.
  void _onPttVoiceStopPressed() {
    if (!_pttListening) return;
    setState(() => _pttListening = false);
    unawaited(_pttVoice!.stop());
  }

  /// Ask-Ayma mode's composer — [ChatComposer] driven directly off
  /// [_pttListening]/[_pttVoice] rather than [_Composer]'s full-duplex
  /// [_voice] wiring (kept entirely separate so neither path has to know
  /// about the other's voice model).
  Widget _buildAskAymaComposer(BuildContext context) {
    final voiceActive = _pttListening;
    final composerMode = !voiceActive
        ? ComposerMode.text
        : (_pttVoice!.phase != VoiceSessionPhase.live
              ? ComposerMode.connecting
              : (_pttVoice.agentSpeaking
                    ? ComposerMode.aiSpeaking
                    : ComposerMode.listening));
    String? voiceStatus;
    if (voiceActive) {
      voiceStatus = switch (_pttVoice!.phase) {
        // ice-relay-retry (second connect attempt, TURN relay forced).
        VoiceSessionPhase.connecting =>
          _pttVoice.relayRetrying ? 'Reconnecting…' : 'Connecting…',
        VoiceSessionPhase.waking => 'Waking Ayma…',
        _ =>
          _pttVoice.micYielded
              ? 'Mic yielded'
              : (_pttVoice.muted
                    ? 'Muted'
                    : (_pttVoice.reconnecting
                          ? 'Reconnecting…'
                          : (_pttVoice.agentSpeaking
                                ? 'Ayma is speaking…'
                                // A cascade TTS error is recovering the voice — say
                                // so honestly instead of a silent "Listening…".
                                : (_pttVoice.voiceTrouble
                                      ? 'Reconnecting the voice…'
                                      : (_pttVoice.activeToolLabel ?? 'Listening…'))))),
      };
    }
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
        child: ChatComposer(
          mode: composerMode,
          controller: _composerController,
          focusNode: _composerFocus,
          canSend: !_sending &&
              (_canSend || _pendingImage != null || _pendingShared != null),
          onSend: _send,
          onAttach: _attachImage,
          onMicPressed: _onPttMicPressed,
          onStopPressed: _onPttVoiceStopPressed,
          onMuteTap: () => _pttVoice.toggleMute(),
          muted: _pttVoice!.muted || _pttVoice.micYielded,
          userAmplitude: _pttVoice.micLevel,
          aiAmplitude: _pttVoice.aymaLevel,
          statusLabel: voiceStatus,
        ),
      ),
    );
  }

  void _scrollToBottom() {
    // the one-time target jump owns this frame
    if (_pendingTargetScroll) return;
    // the older-page scroll fix-up owns this frame
    if (_pendingOlderScroll) return;
    // the user's own drag owns this gesture — see field doc
    if (_userScrolling) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      // a drag may have started since this was scheduled
      if (_userScrolling) return;
      final target = _scrollController.position.maxScrollExtent;
      // A live voice reply streams in as many segments a few tens of ms apart
      // (§1.7 step 12 — [TranscriptStore.applyVoiceSegment] grows the tail
      // turn in place and notifies on each one, firing this on every one),
      // which is faster than the 200ms animate-to-bottom below can land: each
      // segment restarts the animation a frame in, so it never completes and
      // the view crawls, falling further and further behind the growing
      // transcript (founder: voice-mode streamed text doesn't follow to the
      // bottom). While the tail is still a streaming (non-final voice) turn,
      // jump straight to the bottom so the view keeps up; a finalized turn or
      // a typed reply (one store write, seconds after the last) still animates
      // smoothly — the text path is untouched.
      final tail = _store.turns.isNotEmpty ? _store.turns.last : null;
      final streaming =
          tail != null && tail.source == TurnSource.voice && !tail.isFinal;
      if (streaming) {
        // Follow only while the view is already sitting at the bottom it last
        // chased ([_bottomBaseline], same test [_handleListMetrics] uses) — a
        // user who scrolled up to read history mid-call is never yanked down.
        // `infinity` is the pre-first-scroll bootstrap (chat just opened, view
        // at 0 with nothing above): treat that as "at the bottom" so the very
        // first segment of a reply still follows.
        final atBottom = _bottomBaseline == double.infinity ||
            _scrollController.position.pixels >= _bottomBaseline - 24;
        if (!atBottom) return;
        _bottomBaseline = target;
        _scrollController.jumpTo(target);
      } else {
        _bottomBaseline = target;
        _scrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  /// Fires whenever the transcript's layout metrics change for *any* reason
  /// — new turns, an older page splicing in, or (see [_bottomBaseline]'s doc
  /// for the actual root cause this covers) a web font or a network image
  /// finishing *after* [_scrollToBottom] already measured `maxScrollExtent`.
  /// Only re-chases the bottom when the view was sitting at the baseline
  /// [_scrollToBottom] last aimed for — so it's a no-op while the user is
  /// scrolled up reading older turns, and it inherits every one of
  /// [_scrollToBottom]'s own guards (target jump / older-page fix-up / an
  /// active drag) for the cases already covered there.
  bool _handleListMetrics(ScrollMetricsNotification n) {
    if (_scrollController.hasClients &&
        _scrollController.position.pixels >= _bottomBaseline - 24) {
      _scrollToBottom();
    }
    return false;
  }

  /// Tracks [_userScrolling] from real touch drags on the message list — see
  /// that field's doc for why. `dragDetails == null` on both notifications
  /// covers every *programmatic* scroll this screen itself performs
  /// ([_scrollToBottom], the target-turn jump, the older-history fix-up, the
  /// `DraggableScrollableSheet`'s own snap animation on release) — none of
  /// those are a finger on the glass, so none of them should count.
  ///
  /// The `ScrollEndNotification` branch also re-chases the bottom itself,
  /// gated the same way [_handleListMetrics] already is (only when the view
  /// was still sitting at the baseline [_scrollToBottom] last aimed for) —
  /// root cause of "scroll-to-latest doesn't happen all the time" when this
  /// screen is embedded in `showAymaChatModal`'s popup: a message arriving
  /// *while a drag is in flight* has [_scrollToBottom] bail out immediately
  /// (`_userScrolling` guard above), and previously nothing afterward was
  /// guaranteed to retry it — it only got lucky if some *other*, unrelated
  /// layout change happened to fire a `ScrollMetricsNotification` later (e.g.
  /// the popup's `DraggableScrollableSheet` animating to its nearest snap
  /// size on release, which — being embedded in that modal — resizes this
  /// list's own viewport across several frames and incidentally re-triggers
  /// [_handleListMetrics]). On the plain full-screen tab there's no such
  /// sheet, but a drag rarely straddles a new message there either, so the
  /// gap went unnoticed; inside the popup, though, dragging the transcript
  /// itself is *how you resize the sheet* (see `ayma_chat_modal.dart`'s
  /// `_bridgeChatDrag`) — a drag most users start right after sending a
  /// message, i.e. exactly when a reply is likely to land — so the same gap
  /// shows up far more often there. Explicitly retrying here on every drag's
  /// end, rather than depending on an incidental later notification, closes
  /// it regardless of which surface this is embedded in.
  bool _handleListScrollNotification(ScrollNotification n) {
    if (n is ScrollStartNotification && n.dragDetails != null) {
      _userScrolling = true;
    } else if (n is ScrollEndNotification && n.dragDetails != null) {
      _userScrolling = false;
      if (_scrollController.hasClients &&
          _scrollController.position.pixels >= _bottomBaseline - 24) {
        _scrollToBottom();
      }
    }
    return false;
  }

  /// Scroll to and briefly highlight [turn] (the first message at/after
  /// [ChatScreen.targetTimestamp]) once its `GlobalKey` has a laid-out
  /// context. `null` means no matching turn was loaded (fully degrades to a
  /// normal bottom-scrolled open).
  void _scrollToTarget(TranscriptTurn? turn) {
    _pendingTargetScroll = false;
    if (turn == null) {
      _scrollToBottom();
      return;
    }
    setState(() => _highlightedTurn = turn);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _turnKeys[turn]?.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
          alignment: 0.2,
        );
      }
    });
    _highlightClearTimer?.cancel();
    _highlightClearTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _highlightedTurn == turn) {
        setState(() => _highlightedTurn = null);
      }
    });
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final picked = await _picker.pickImage(
        source: source,
        maxWidth: 1600,
        imageQuality: 85,
      );
      if (picked == null || !mounted) return;
      setState(() => _pendingImage = File(picked.path));
    } catch (_) {
      if (mounted) {
        AymaToast.show(context, "Couldn't open that image.",
            kind: AymaToastKind.error);
      }
    }
  }

  void _attachImage() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from library'),
              onTap: () {
                Navigator.pop(ctx);
                _pickImage(ImageSource.gallery);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a photo'),
              onTap: () {
                Navigator.pop(ctx);
                _pickImage(ImageSource.camera);
              },
            ),
          ],
        ),
      ),
    );
  }

  String _sharedWireFallback() {
    if (_store.turns.isNotEmpty) {
      final t = _store.turns.last;
      if (t.role == TurnRole.user && t.sharedKind.isNotEmpty) {
        return '[shared ${t.sharedKind.replaceAll('_', ' ')}]';
      }
    }
    return '(shared)';
  }

  Future<void> _send({
    String? retry,
    bool skipUserTurn = false,
    String? clientMsgId,
  }) async {
    // A draft attachment (an "Ask Ayma" report chip or shared-card stage) is
    // posted as a shared card when the user hits send. If they typed their own
    // text, card and text arrive together; if empty, the card alone is sent.
    if (retry == null && _pendingShared != null && !_sending) {
      final draftText = _composerController.text.trim();
      final ps = _pendingShared!;
      if (ps.uid.isNotEmpty) _viewingOverride = ps.uid;
      if (ps.editSelf) _profileEdit = true;
      if (ps.kind == 'match' && ps.refId.isNotEmpty) {
        _matchReportId = ps.refId;
      }
      // A posted report card leaves its REFERENCE on the session (the
      // recursive send below — and every later turn — carries it; Ayma
      // pulls the report herself). Any other card kind clears a previous
      // reference: it always names the most recently shared report.
      if (ps.kind == 'deep_dive' || ps.kind == 'appearance') {
        _sharedKind = ps.kind;
        _sharedRefId = ps.refId;
        _sharedSubjectUid = ps.uid;
        _sharedSubjectName = ps.name;
        _sharedRefVersion = ps.refVersion;
      } else {
        _sharedKind = '';
        _sharedRefId = '';
        _sharedSubjectUid = '';
        _sharedSubjectName = '';
        _sharedRefVersion = '';
      }
      _store.addSharedTurn(
        kind: ps.kind,
        uid: ps.uid,
        name: ps.name,
        photo: ps.photo,
        refId: ps.refId,
        text: draftText,
      );
      setState(() {
        _pendingShared = null;
        _composerController.clear();
      });
      return _send(retry: draftText, skipUserTurn: true);
    }

    final message = retry ?? _composerController.text.trim();
    final image = retry == null ? _pendingImage : null;
    if ((message.isEmpty && image == null && !skipUserTurn) || _sending) return;

    // Messages are already waiting for credits: this one joins the line (they
    // go out in the order they were written) instead of jumping it.
    if (retry == null && image == null && _canQueue && !_queue.isEmpty) {
      setState(_composerController.clear);
      unawaited(_queue.enqueue(
        QueuedChatMessage(clientMsgId: newClientMsgId(), message: message),
      ));
      unawaited(_queue.flushIfFunded());
      return;
    }

    // One id per user send, stable across retries of that same send — the
    // server dedups on it, so a retry can never double-run a turn that
    // already landed (see [_PendingSendReconcile]).
    final msgId = clientMsgId ?? newClientMsgId();
    // A different, brand-new send supersedes any send still waiting on
    // reconciliation: its waiting bubble can't stay the trailing pending
    // turn once a new one exists, so let it go. If that turn did land
    // server-side it still shows on the next history load.
    if (_reconcile != null && _reconcile!.msgId != msgId) {
      _reconcile = null;
      _store.dropPending();
    }

    final ownVoice = widget.askAymaContext != null ? _pttVoice : _voice;
    final screenCtx = (ownVoice?.isActive ?? false) ? null : _activePageContext;
    final replying = _replyingToTurn;

    String replySubject = '';
    String replySnippet = '';
    String replyKind = '';

    if (replying != null) {
      replySubject = replying.role == TurnRole.user ? 'You' : 'Ayma';
      replySnippet = replying.text;
      replyKind = 'message';
    } else if (screenCtx != null) {
      replySubject = screenCtx.label;
      replySnippet = screenCtx.note.isNotEmpty
          ? screenCtx.note
          : (screenCtx.detail.isNotEmpty ? screenCtx.detail : '');
      replyKind = 'page';
    }

    final window = _store.wireTurns();
    setState(() {
      _sending = true;
      if (retry == null) {
        _composerController.clear();
        _pendingImage = null;
        if (replying != null) {
          _replyingToTurn = null;
        }
        if (screenCtx != null) {
          _pageContext = null;
        }
      }
    });

    // Show the turn right away — a local file renders instantly, so the
    // bubble never waits on the Storage upload below to appear. `null` when
    // there's no image, or the caller already put the turn in (shared card /
    // retry — see below).
    TranscriptTurn? optimisticTurn;
    if (skipUserTurn) {
      // The caller already put this turn in the transcript (a shared
      // profile/conversation/match card). It's the tail of `window` and carries
      // the same text as `message` (or placeholder if empty); drop it here so
      // it isn't sent twice, but it stays in the store for context on later turns.
      if (window.isNotEmpty &&
          window.last['role'] == 'user' &&
          (window.last['text'] == message ||
              (message.isEmpty &&
                  (window.last['text']?.startsWith('[shared ') ?? false)))) {
        window.removeLast();
      }
    } else if (retry == null) {
      optimisticTurn = _store.addTurn(
        TurnRole.user,
        message,
        TurnSource.text,
        imageFile: image,
        replySubject: replySubject,
        replySnippet: replySnippet,
        replyKind: replyKind,
      );
    } else if (window.isNotEmpty &&
        window.last['role'] == 'user' &&
        window.last['text'] == message) {
      // Retrying: the failed turn is already the tail of the window — drop it
      // so it isn't sent twice (once as history, once as `message`).
      window.removeLast();
    }

    String imagePath = '';
    try {
      if (image != null) {
        final up = await _chat.uploadChatImage(image);
        imagePath = up.storagePath;
        if (optimisticTurn != null) {
          _store.updateTurnImage(optimisticTurn, up.downloadUrl);
        }
        // Best-effort, fire-and-forget: run the shared photo pipeline
        // (moderation -> embed -> attributes -> caption, §8.5) on the chat
        // attachment, same as a profile/DM photo already gets. The image
        // still shows inline immediately either way; a pipeline failure
        // must never block or delay sending the chat message itself.
        // `message` (whatever was typed alongside the photo, may be empty)
        // rides along as `captionContext` so the gallery note can fold in
        // what the user actually said, not just a blind read of the photo.
        unawaited(
          _api
              .registerMedia(
                imagePath,
                context: 'chat',
                captionContext: message,
              )
              .catchError(
                (_) => const MediaResult(
                  mediaId: '',
                  published: false,
                  moderationStatus: 'approved',
                  reason: '',
                ),
              ),
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() => _sending = false);
        if (optimisticTurn != null) _store.removeTurn(optimisticTurn);
        AymaToast.show(context, "Couldn't upload that image.",
            kind: AymaToastKind.error);
      }
      return;
    }

    final wireMessage = (replyKind == 'message' &&
            replySubject.isNotEmpty &&
            replySnippet.isNotEmpty)
        ? '[Replying to $replySubject: "$replySnippet"]\n$message'
        : (message.isEmpty
            ? (image != null ? '(shared a photo)' : _sharedWireFallback())
            : message);
    _store.addPending('Thinking…');
    _backgroundedDuringSend = false;
    final knownAymaBeforeSend = _store.turns
        .where((t) => t.role == TurnRole.ayma && t.isFinal)
        .map((t) => t.text)
        .toSet();
    // A scoped Ask-Ayma correction turn threads its context via these
    // fields instead of [widget.storyPageId]/etc. (removed — see
    // [ChatScreen.askAymaContext]'s doc); null everywhere else.
    final askAyma = widget.askAymaContext;

    // A generic Living Report turn (§ generic reports,
    // `AskAymaOrigin.report`) never goes through `/chat` at all — it goes
    // straight to `POST /report/{report_type}/{report_id}/correct`, the ONE
    // endpoint that already knows how to tell a fixed quick-action phrase
    // apart from free text and route either to the right producer (see
    // `report_hub.correct`'s own docstring). `reportType` is only ever
    // non-empty for that origin (every other origin's [AskAymaContext]
    // leaves it at its default `''`), so branching on it here — rather than
    // on `askAyma.origin` — also naturally does nothing for every existing
    // caller.
    if (askAyma != null && askAyma.reportType.isNotEmpty) {
      try {
        final res = await _api.correctReport(
          askAyma.reportType,
          askAyma.reportId,
          blockIds: askAyma.blockIds,
          scope: askAyma.scope,
          message: message,
        );
        if (!mounted) return;
        _store.resolvePending(res.combinedReply, capped: res.usageCapped);
        if (!res.usageCapped) widget.onExchange?.call();
      } on ApiException catch (e) {
        if (!mounted) return;
        // A connection-class death (timeout / dropped socket — far likelier
        // when a live voice call is contending for the network) is NOT a
        // failure: `report_hub.correct` commits the delete/correction
        // server-side and only the RESPONSE was lost. Flashing "Couldn't
        // reach Ayma" then falsely reports a success as a failure — the
        // founder's exact voice-mode bug (2026-11-03: a web-research item
        // delete during a call toasted a connection error though the item was
        // gone). Reconcile instead: reload the report so the UI reflects what
        // actually committed, and show no error (mirrors the `/chat` branch's
        // `_shouldReconcile`). A genuine server rejection (a real status code)
        // still surfaces its honest error below.
        if (_shouldReconcile(e)) {
          _store.dropPending();
          widget.onExchange?.call();
        } else {
          _store.dropPending();
          AymaToast.show(
            context,
            _sendFailureMessage(e),
            kind: AymaToastKind.error,
            action: AymaToastAction(
              label: 'Retry',
              onPressed: () =>
                  _send(retry: wireMessage, skipUserTurn: skipUserTurn),
            ),
          );
        }
      } catch (e) {
        if (!mounted) return;
        // Same reconcile for a raw connection-class error (SocketException /
        // TimeoutException that didn't come wrapped) — the server may well
        // have committed, so don't flash a false failure.
        if (_shouldReconcile(e)) {
          _store.dropPending();
          widget.onExchange?.call();
        } else {
          _store.dropPending();
          AymaToast.show(
            context,
            'Something went wrong sending that message.',
            kind: AymaToastKind.error,
            action: AymaToastAction(
              label: 'Retry',
              onPressed: () =>
                  _send(retry: wireMessage, skipUserTurn: skipUserTurn),
            ),
          );
        }
      } finally {
        if (mounted) {
          setState(() => _sending = false);
          _composerFocus.requestFocus();
        }
      }
      return;
    }

    final storyPageId = askAyma?.pageId ?? '';
    final storyPassage = askAyma != null && !askAyma.isTimelineEntry
        ? askAyma.selectedText
        : '';
    final storyTimelineEntryId = askAyma?.timelineEntryId ?? '';
    final deepDiveReportId = askAyma?.deepDiveReportId ?? '';
    final deepDiveTarget = askAyma?.deepDiveTarget ?? '';
    final appearanceFindingId = askAyma?.appearanceFindingId ?? '';
    // The scoped modal's own copy (a tap on a Match report block) takes
    // priority; otherwise fall back to the persistent one set by the Match
    // report's "Ask Ayma" toolbar button (`_runTalkAbout` above).
    final matchReportId = (askAyma?.matchReportId.isNotEmpty ?? false)
        ? askAyma!.matchReportId
        : _matchReportId;
    // Voice-call state for this turn (founder directive 2026-11-07,
    // ledger 2cy): Ayma's text context must know whether a voice call is
    // live or just ended — without it she answered a typed "disconnect"
    // after a silence-ended call with "We aren't on a voice call right
    // now", as if the call never happened. A typed disconnect during a
    // LIVE call ends it here, deterministically (the same teardown as
    // the stop button), and this turn is then stamped just-ended so she
    // acknowledges the call she was just on instead of denying it. The
    // message still goes to the model either way — informed, it
    // confirms the end (live case) or acknowledges the call already
    // ended (just-ended case). [_voice] is read only in plain mode: in
    // Ask-Ayma mode it must never be constructed (see dispose), and the
    // mode's own capture controller is [_pttVoice].
    var callState = (ownVoice?.isActive ?? false)
        ? const CallStateSnapshot.active()
        : VoiceSessionController.chatCallState();
    final liveCall = (ownVoice?.isActive ?? false)
        ? ownVoice
        : (VoiceSessionController.active?.isActive ?? false)
            ? VoiceSessionController.active
            : null;
    if (liveCall != null &&
        VoiceSessionController.isDisconnectRequest(message)) {
      unawaited(liveCall.stop());
      callState = const CallStateSnapshot.justEnded(
        secondsAgo: 0,
        reason: 'text_disconnect',
      );
    }
    // The plain-`/chat` form of this send. Used as the in-band fallback when
    // the stream transport is unavailable, and by [_reconcilePendingSend] as
    // the idempotent re-ask after a dropped connection — same `client_msg_id`
    // both times, so the server never runs (or bills) the turn twice.
    Future<ChatResult> resend() => _api.chat(
          wireMessage,
          sessionId: _sessionId,
          viewingProfileUid: _viewingUid,
          recentTurns: window,
          imagePath: imagePath,
          storyPageId: storyPageId,
          storyPassage: storyPassage,
          storyTimelineEntryId: storyTimelineEntryId,
          deepDiveReportId: deepDiveReportId,
          deepDiveTarget: deepDiveTarget,
          appearanceFindingId: appearanceFindingId,
          matchReportId: matchReportId,
          sharedKind: _sharedKind,
          sharedRefId: _sharedRefId,
          sharedSubjectUid: _sharedSubjectUid,
          sharedSubjectName: _sharedSubjectName,
          sharedRefVersion: _sharedRefVersion,
          profileEdit: _profileEdit,
          photoUrl: widget.photoUrl,
          photoSource: widget.photoSource,
          screen: screenCtx?.screen ?? '',
          screenSubjectUid: screenCtx?.subjectUid ?? '',
          screenSubjectName: screenCtx?.subjectName ?? '',
          screenNote: screenCtx?.note ?? '',
          screenRoute: screenCtx?.route ?? '',
          screenPreviousRoute: screenCtx != null
              ? (NavigationHistory.instance.previous?.path ?? '')
              : '',
          screenPreviousLabel: screenCtx != null
              ? (NavigationHistory.instance.previous?.label ?? '')
              : '',
          clientMsgId: msgId,
          callState: callState,
        );

    try {
      ChatResult? result;
      try {
        await for (final ev in _api.chatStream(
          wireMessage,
          sessionId: _sessionId,
          viewingProfileUid: _viewingUid,
          recentTurns: window,
          imagePath: imagePath,
          storyPageId: storyPageId,
          storyPassage: storyPassage,
          storyTimelineEntryId: storyTimelineEntryId,
          deepDiveReportId: deepDiveReportId,
          deepDiveTarget: deepDiveTarget,
          appearanceFindingId: appearanceFindingId,
          matchReportId: matchReportId,
          sharedKind: _sharedKind,
          sharedRefId: _sharedRefId,
          sharedSubjectUid: _sharedSubjectUid,
          sharedSubjectName: _sharedSubjectName,
          sharedRefVersion: _sharedRefVersion,
          profileEdit: _profileEdit,
          photoUrl: widget.photoUrl,
          photoSource: widget.photoSource,
          screen: screenCtx?.screen ?? '',
          screenSubjectUid: screenCtx?.subjectUid ?? '',
          screenSubjectName: screenCtx?.subjectName ?? '',
          screenNote: screenCtx?.note ?? '',
          screenRoute: screenCtx?.route ?? '',
          screenPreviousRoute: screenCtx != null
              ? (NavigationHistory.instance.previous?.path ?? '')
              : '',
          screenPreviousLabel: screenCtx != null
              ? (NavigationHistory.instance.previous?.label ?? '')
              : '',
          clientMsgId: msgId,
          callState: callState,
        )) {
          if (!mounted) return;
          if (ev is ChatStatus) {
            _store.updatePendingText(ev.label);
          } else if (ev is ChatReplyEvent) {
            result = ev.result;
          }
        }
      } on ApiException {
        // Stream unavailable (proxy, old build) — fall back to the plain
        // call. Same client id, so even a stream that died AFTER the server
        // started the turn is joined/deduped, never re-run.
        result = await resend();
      }
      if (!mounted) return;
      if (result == null) {
        _store.dropPending();
        throw const _NoReply();
      }
      _store.resolvePending(
        result.reply,
        tools: result.toolsUsed,
        capped: result.usageCapped,
        imageUrl: result.imageUrl,
        feedbackKind: result.feedbackCard?.kind ?? '',
        feedbackTitle: result.feedbackCard?.title ?? '',
        feedbackBody: result.feedbackCard?.body ?? '',
      );
      _offerServerBubble(result.feedbackBubble);
      if (result.usageCapped && _canQueue && !skipUserTurn) {
        _holdForCredits(
          message: message,
          msgId: msgId,
          imagePath: imagePath,
        );
      }
      if (!result.usageCapped) {
        // Let the caller (an Ask-Ayma correction origin) catch up in place
        // — while the screen is still open, not just once it closes. A
        // no-op for every other caller, which never sets this.
        widget.onExchange?.call();
      }
      if (result.imageRejected) {
        AymaToast.show(context, 'That image was blocked by our check.',
            kind: AymaToastKind.warning);
      }
      if (result.fallbackForm) {
        AymaToast.show(
          context,
          'Let’s finish the basics on a quick form.',
          action: AymaToastAction(
            label: 'Open',
            onPressed: () => context.go('/settings/profile'),
          ),
        );
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      // A connection-class death (or any failure after the app left the
      // foreground mid-send) is NOT a failure yet — the server keeps
      // working after the socket dies, so reconcile against history / the
      // idempotent re-ask instead of flashing an error (founder bug: a slow
      // image turn + app exit showed "[Retry]" for a turn that completed
      // and billed server-side).
      if (_shouldReconcile(e)) {
        _beginReconcile(_PendingSendReconcile(
          msgId: msgId,
          message: message,
          knownAyma: knownAymaBeforeSend,
          resend: resend,
          imagePath: imagePath,
          queueable: !skipUserTurn,
        ));
        return;
      }
      _store.dropPending();
      AymaToast.show(
        context,
        _sendFailureMessage(e),
        kind: AymaToastKind.error,
        action: AymaToastAction(
          label: 'Retry',
          onPressed: () => _send(retry: message, clientMsgId: msgId),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      if (_shouldReconcile(e)) {
        _beginReconcile(_PendingSendReconcile(
          msgId: msgId,
          message: message,
          knownAyma: knownAymaBeforeSend,
          resend: resend,
          imagePath: imagePath,
          queueable: !skipUserTurn,
        ));
        return;
      }
      _store.dropPending();
      AymaToast.show(
        context,
        'Something went wrong sending that message.',
        kind: AymaToastKind.error,
        action: AymaToastAction(
          label: 'Retry',
          onPressed: () => _send(retry: message, clientMsgId: msgId),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _sending = false);
        _composerFocus.requestFocus();
      }
    }
  }

  /// Out of credits: Ayma's "reload" card stays, and the message moves out of
  /// the transcript into the persisted [PendingChatQueue], to go out on its own
  /// (same [msgId], so never twice) the moment credits are back.
  void _holdForCredits({
    required String message,
    required String msgId,
    String imagePath = '',
  }) {
    TranscriptTurn? sent;
    for (final t in _store.turns.reversed) {
      if (t.role == TurnRole.user && t.text == message) {
        sent = t;
        break;
      }
    }
    if (sent != null) _store.removeTurn(sent);
    unawaited(_queue.enqueue(QueuedChatMessage(
      clientMsgId: msgId,
      message: message,
      imagePath: imagePath,
      imageUrl: sent?.imageUrl ?? '',
    )));
  }

  late final ProfileService _profiles =
      widget.profileService ?? ProfileService();


  /// Feedback bubble: scan newly finalized LIVE user turns (typed,
  /// voice-call segments, voice notes — all land in this one store with
  /// no `createdAt`; history turns carry one and are never scanned, so
  /// an old "capture feedback" cannot re-fire on reopen). While a
  /// bubble is up, a new user turn's words are mirrored into the card
  /// (the "just tell Ayma" path) instead of triggering anything new.
  void _scanTurnsForBubble() {
    if (!mounted) return;
    for (final t in _store.turns) {
      if (t.role != TurnRole.user || !t.isFinal || t.createdAt != null) {
        continue;
      }
      if (!_bubbleScanned.add(t)) continue;
      final text = t.text.trim();
      if (text.isEmpty) continue;
      if (_bubble != null && !_bubbleDone) {
        if (!isExplicitFeedbackRequest(text)) {
          setState(() {
            _bubbleFillText = text;
            _bubbleFillRevision++;
          });
        }
        continue;
      }
      if (_bubble != null) continue;
      final req = evaluateUserTurnForBubble(text, _bubbleGate);
      if (req != null) unawaited(_presentBubble(req));
    }
  }

  /// A server-signalled bubble offer (the reply's `feedback_bubble` —
  /// e.g. Ayma's own `record_feedback` fired this turn). Claimed
  /// through the same gate, so it can never double-offer a trigger the
  /// client already showed.
  void _offerServerBubble(FeedbackBubble? payload) {
    if (payload == null || _bubble != null) return;
    final req = requestFromServerPayload(
      {'trigger': payload.trigger, 'prefill': payload.prefill},
      _bubbleGate,
    );
    if (req == null || !mounted) return;
    unawaited(_presentBubble(req));
  }

  /// Capture the app as it currently looks, then show the bubble with
  /// the shot attached. Capture runs while the card is NOT yet in the
  /// tree. Any failure leaves the bubble fully usable without a shot.
  Future<void> _presentBubble(FeedbackBubbleRequest req) async {
    if (_bubblePresenting || _bubble != null) return;
    _bubblePresenting = true;
    File? shotFile;
    String? shotPath;
    var shotFailed = false;
    try {
      final ctx = _appShotKey.currentContext;
      final boundary = ctx?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) throw StateError('no shot boundary');
      final image = await boundary.toImage(pixelRatio: 2.0);
      try {
        final data =
            await image.toByteData(format: ui.ImageByteFormat.png);
        if (data == null) throw StateError('png encode failed');
        final dir = await getTemporaryDirectory();
        shotFile = File(
            '${dir.path}/feedback_shot_${DateTime.now().millisecondsSinceEpoch}.png');
        await shotFile.writeAsBytes(data.buffer.asUint8List());
        final up = await _chat.uploadImage(shotFile, prefix: 'feedback');
        shotPath = up.storagePath;
      } finally {
        image.dispose();
      }
    } catch (_) {
      shotFile = null;
      shotPath = null;
      shotFailed = true;
    }
    _bubblePresenting = false;
    if (!mounted || _bubble != null) return;
    setState(() {
      _bubble = req;
      _bubbleDone = false;
      _bubbleFillText = '';
      _bubbleFillRevision = 0;
      _bubbleShotFile = shotFile;
      _bubbleShotPath = shotPath;
      _bubbleShotFailed = shotFailed;
    });
  }

  Future<void> _getStarted() async {
    try {
      await _profiles.markOnboardingStarted();
    } catch (_) {
      // Non-fatal — the server also derives `interview` from other signals.
    }
    if (mounted) context.go(PreboardingFlowScreen.path);
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final askAyma = widget.askAymaContext;
    final photo = widget.photoUrl.isNotEmpty;
    // The fixed parts of this column (header, call notice, photo context,
    // composer with its pinned-context chip) are each capped at a share of
    // the available height and scroll inside that cap, so they can never
    // add up to more than the column: in a split-screen or freeform
    // window, the docked popup at its smallest snap, the keyboard up, or
    // text at 200% they used to overflow it (founder, Pixel Fold:
    // "BOTTOM OVERFLOWED BY 42 PIXELS"). At normal sizes every cap is
    // larger than its content, so nothing scrolls and nothing changes.
    // The Ask-Ayma header below gets the largest safe share (half the
    // sheet): its context card shows the highlighted item's FULL text with
    // no truncation ever (§ D12 — a Projects quote cut mid-sentence), so at
    // normal sizes the whole card fits and nothing scrolls; only a
    // pathological quote in a tiny window scrolls the header region rather
    // than overflowing the column (header 0.5 + composer 0.5 can never
    // exceed the sheet, which the layout matrix proves). The card itself
    // never truncates and holds no scroll of its own.
    return LayoutBuilder(
      builder: (context, constraints) {
        // The column's own height: the Scaffold's, minus the top inset its
        // SafeArea takes and the keyboard inset the Scaffold resizes for.
        final h = math.max(
          0.0,
          constraints.maxHeight -
              MediaQuery.paddingOf(context).top -
              MediaQuery.viewInsetsOf(context).bottom,
        );
        // Short (popup at its lowest snap, split-screen, landscape
        // phone): the 34pt "Ayma" title drops to a compact header.
        final short = h < 400;
        // Founder rule (Nov 2026): a partial sheet never lists conversation
        // history — the scoped correction/ask sheets and the plain
        // page-context popup alike show only their context (card/chip),
        // quick chips and the composer. Full screen (a scoped sheet
        // expanded, or the Ayma tab, which has no sheet at all) shows the
        // whole conversation. The plain popup is never expanded at all
        // (founder order, 2026-11-07), so for it this gate is permanent:
        // its history list — the stale-looking duplicate page — no
        // longer exists. Partial and full are literally the same
        // ChatScreen — nothing re-mounts — so this is one presentation gate
        // on the host sheet's live expanded state (rebuilt via this
        // `maybeOf` dependency, same as [_sheetExpanded]); `_send` and
        // persistence are untouched, so turns sent from the sheet still land
        // in the shared store and appear on expand.
        final hostSheet = AymaChatSheetController.maybeOf(context);
        final partialSheet = hostSheet != null && !hostSheet.isExpanded;
        return Scaffold(
          body: SafeArea(
            bottom: false,
            child: Column(
              children: [
                if (askAyma != null)
                  _capped(h * 0.5, _AskAymaHeader(ctx: askAyma))
                else if (!photo)
                  // Rebuilt off [_voice] so the full-screen entry point appears
                  // the moment a call starts and vanishes the moment it ends —
                  // this branch only exists when `askAyma == null`, so touching
                  // [_voice] here never constructs the unused controller in
                  // Ask-Ayma mode.
                  ListenableBuilder(
                    listenable: _voice,
                    builder: (context, _) {
                      // While a voice session is live (or connecting), the
                      // header's trailing slot becomes the one way to expand
                      // into the full-screen orb view besides the inline call
                      // bar — the mic itself no longer auto-opens it (founder
                      // ask, 2026-09-26). Hidden entirely with no session; the
                      // marketing "Get started" keeps the slot otherwise.
                      final Widget? voiceAction = _voice.isActive
                          ? IconButton(
                              key: const Key('chatVoiceFullscreenButton'),
                              icon: Icon(
                                // A waveform, not an expand arrow: expand reads
                                // as "make the chat bigger"; this button enters
                                // the full-screen VOICE view (founder call).
                                Icons.graphic_eq_rounded,
                                size: 22,
                                color: ac.fgDim,
                              ),
                              tooltip: 'Full-screen voice',
                              onPressed: _openVoiceScreen,
                            )
                          : (widget.marketing
                                ? TextButton(
                                    onPressed: _getStarted,
                                    child: const Text('Get started'),
                                  )
                                : null);
                      // Hosted in a sheet, this slot is the full-screen
                      // affordance. In the page-context popup the sheet
                      // never grows in place (founder order, 2026-11-07):
                      // the button leaves the sheet entirely for the real
                      // main chat via [ChatScreen.onGoToMainChat]. In an
                      // expandable sheet (a scoped Ask-Ayma turn) it grows
                      // that same sheet to full screen in place and
                      // collapse shrinks it back — there the arrow
                      // genuinely means "make the chat bigger", unlike the
                      // voice case above. Sits beside the voice button
                      // (its own slot, no overlap) when a call is live.
                      final sheet = AymaChatSheetController.maybeOf(context);
                      final Widget? expandAction = sheet == null
                          ? null
                          : widget.onGoToMainChat != null
                          ? IconButton(
                              key: const Key('chatExpandFullscreenButton'),
                              icon: Icon(
                                Icons.open_in_full_rounded,
                                size: 20,
                                color: ac.fgDim,
                              ),
                              tooltip: 'Open full chat',
                              onPressed: widget.onGoToMainChat,
                            )
                          : sheet.isExpanded
                          ? IconButton(
                              key: const Key('chatCollapseFullscreenButton'),
                              icon: Icon(
                                Icons.close_fullscreen_rounded,
                                size: 20,
                                color: ac.fgDim,
                              ),
                              tooltip: 'Collapse',
                              onPressed: sheet.collapse,
                            )
                          : IconButton(
                              key: const Key('chatExpandFullscreenButton'),
                              icon: Icon(
                                Icons.open_in_full_rounded,
                                size: 20,
                                color: ac.fgDim,
                              ),
                              tooltip: 'Expand to full screen',
                              onPressed: sheet.expand,
                            );
                      // iOS keyboards have no dismiss key and the main tab has no
                      // back affordance: while the keyboard is up, a back arrow
                      // puts it away (tester feedback).
                      return _capped(
                        h * 0.25,
                        _KeyboardAwareHeader(
                        builder: (keyboardOpen) => AymaScreenHeader(
                        title: 'Ayma',
                        titleSize: short ? 24 : 34,
                        leading: keyboardOpen
                            ? IconButton(
                                key: const Key('chatDismissKeyboardButton'),
                                tooltip: 'Hide keyboard',
                                icon: Icon(Icons.arrow_back_ios_new_rounded,
                                    size: 20, color: ac.fg),
                                onPressed: () =>
                                    FocusManager.instance.primaryFocus?.unfocus(),
                              )
                            : null,
                        padding: short
                            ? const EdgeInsets.fromLTRB(20, 8, 20, 4)
                            : const EdgeInsets.fromLTRB(20, 24, 20, 12),
                        action: expandAction == null
                            ? voiceAction
                            : (voiceAction == null
                                  ? expandAction
                                  : Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [voiceAction, expandAction],
                                    )),
                      ),
                        ),
                      );
                    },
                  ),
                // Live call state (Listening / Muted / Connecting…) lives only in
                // the composer bar now — no second copy under the header. The one
                // thing the composer can't show is a hard error (it falls back to
                // the plain text composer), so that still surfaces here. Skipped
                // in Ask-Ayma mode: that mode's push-to-talk errors surface via a
                // toast instead (see [_onPttVoiceChanged]), and this binding
                // would otherwise construct the unused full-duplex [_voice] from
                // scratch just to read `.phase` off it.
                if (askAyma == null)
                  _capped(
                    h * 0.15,
                    ListenableBuilder(
                    listenable: _voice,
                    builder: (context, _) {
                      if (_voice.phase != VoiceSessionPhase.error) {
                        final notice = _voice.endNotice;
                        if (notice == null) return const SizedBox(height: 4);
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                          child: Text(
                            notice.toUpperCase(),
                            key: const ValueKey('voice-end-notice'),
                            textAlign: TextAlign.center,
                              style: AymaType.mono(
                                size: 9,
                                color: context.ac.fgDim,
                              ).copyWith(letterSpacing: 1.8),
                          ),
                        );
                      }
                      if (_voice.cappedError) {
                        // Same reusable "out of credits" card chat/skills use,
                        // instead of a shouted all-caps error line for this one
                        // specifically-actionable case.
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                            child: OutOfCreditsBanner(
                              message: _voice.errorMessage,
                            ),
                        );
                      }
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                        child: Column(
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  width: 5,
                                  height: 5,
                                    margin: const EdgeInsets.only(
                                      right: 8,
                                      top: 3,
                                    ),
                                  decoration: const BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: AymaColors.error,
                                  ),
                                ),
                                Flexible(
                                  child: Text(
                                    (_voice.errorMessage ?? 'Voice error')
                                        .toUpperCase(),
                                    textAlign: TextAlign.center,
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                    style: AymaType.mono(
                                      size: 9,
                                      color: AymaColors.error,
                                    ).copyWith(letterSpacing: 1.8),
                                  ),
                                ),
                              ],
                            ),
                            // The one error the user can actually fix themselves —
                            // a denied notification permission — gets a real path
                            // to Settings instead of just an explanation (§ ask
                            // item 3).
                            if (_voice.backgroundPermissionDenied)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: GestureDetector(
                                    onTap: () =>
                                        CallPermissions().openSettings(),
                                  child: Text(
                                    'OPEN SETTINGS',
                                    style:
                                        AymaType.mono(
                                          size: 9,
                                          color: AymaColors.error,
                                        ).copyWith(
                                          letterSpacing: 1.8,
                                            decoration:
                                                TextDecoration.underline,
                                        ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                    ),
                  ),
                Expanded(
                  child: ListenableBuilder(
                    listenable: Listenable.merge([_store, _queue, _voiceQueue]),
                    builder: (context, _) {
                      final turns = _store.turns;
                      final waiting = _canQueue
                          ? _queue.waiting
                          : const <QueuedChatMessage>[];
                      final aymaVoiceProcessing = _canQueue
                          ? _voiceQueue.activeAymaStageLine
                          : null;
                      final aymaVoiceRow = aymaVoiceProcessing != null ? 1 : 0;
                      final bubbleRow = _bubble != null ? 1 : 0;
                      if ((turns.isEmpty &&
                              waiting.isEmpty &&
                              aymaVoiceRow == 0) ||
                          partialSheet) {
                        if (askAyma != null) {
                          // The quick-suggestion chips show here, as the body:
                          // for a brand-new conversation with no history yet,
                          // and — per the partial-sheet rule above — whenever
                          // this turn is still docked, since the transcript
                          // list below stands down there. Once expanded (or
                          // with turns outside a sheet) they pin above the
                          // composer instead (see below), so the scoped
                          // affordance is always exactly one place.
                          return Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            child: Align(
                              alignment: Alignment.topLeft,
                              child: _QuickChips(
                                suggestions: quickSuggestionsFor(askAyma),
                                onPick: (s) {
                                  _composerController.text = s;
                                  _send();
                                },
                              ),
                            ),
                          );
                        }
                        if (partialSheet) {
                          // The plain partial sheet shows no history list at
                          // all — just the composer (with its context chip)
                          // below. Turns sent from here still land in the
                          // shared store; expanding reveals them.
                          return const SizedBox.shrink();
                        }
                        if (_loadingHistory && _store.isEmpty) {
                          // GET /chat/history (+ its images): one operation,
                          // so the two lines are rephrasings, not stages —
                          // until a retry is scheduled, when the line must say
                          // so instead of holding the original indefinitely.
                          // The loader only owns the screen when nothing is
                          // painted yet: with last-known turns restored from
                          // the cache, the conversation renders during the
                          // load (offline-first).
                          return Center(
                            child: AymaWingLoader(
                              lines: _historyRetrying
                                  ? AymaLoaderLines.reconnect
                                  : AymaLoaderLines.chatHistory,
                              autoRotate: !_historyRetrying,
                            ),
                          );
                        }
                        if (_historyError != null) {
                          return CenteredScroll(
                            padding: const EdgeInsets.symmetric(horizontal: 40),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  _historyError!,
                                  textAlign: TextAlign.center,
                                  style: AymaType.sans(
                                    size: 15,
                                    soft: true,
                                    color: ac.fgMute,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                TextButton(
                                  onPressed: _retryHistory,
                                  child: const Text('Retry'),
                                ),
                              ],
                            ),
                          );
                        }
                        return CenteredScroll(
                          padding: const EdgeInsets.symmetric(horizontal: 40),
                          child: Text(
                            'Say hello to start a conversation.',
                            textAlign: TextAlign.center,
                            style: AymaType.sans(
                              size: 15,
                              soft: true,
                              color: ac.fgMute,
                            ),
                          ),
                        );
                      }
                      final loaderRow = _loadingOlder ? 1 : 0;
                      return NotificationListener<ScrollMetricsNotification>(
                        onNotification: _handleListMetrics,
                        child: NotificationListener<ScrollNotification>(
                          onNotification: _handleListScrollNotification,
                          child: RepaintBoundary(
                            key: _appShotKey,
                            child: ListView.builder(
                            controller: _scrollController,
                            // iOS has no keyboard-dismiss key — dragging the
                            // transcript away is the native escape hatch.
                            keyboardDismissBehavior:
                                ScrollViewKeyboardDismissBehavior.onDrag,
                            padding: const EdgeInsets.fromLTRB(
                              20,
                              4,
                              20,
                              kChatListBottomInset, // 12 — shared w/ DM
                            ),
                            itemCount:
                                turns.length +
                                waiting.length +
                                aymaVoiceRow +
                                bubbleRow +
                                1 +
                                loaderRow,
                            itemBuilder: (context, i) {
                              // Stable keys on the loader and divider rows:
                              // without them these unkeyed rows reconcile by
                              // index, so when the older-page loader flips on
                              // (`_loadingOlder`) — including when an older
                              // `/chat/history` page *fails* and flips it back
                              // off — every GlobalKey-ed turn row below shifts
                              // index against them and Flutter has to *move*
                              // each keyed child instead of leaving it put.
                              // That keyed-vs-unkeyed reshuffle mid-rebuild is
                              // what trips the `_children.contains` /
                              // `_elements.contains` framework assertions
                              // (GATE-RED). Keying every row makes the loader a
                              // clean keyed insert/remove with no turn moves.
                              if (loaderRow == 1 && i == 0) {
                                // Older-messages query — slot fits wings only.
                                return const Padding(
                                  key: ValueKey('chat-older-loader'),
                                  padding: EdgeInsets.symmetric(vertical: 12),
                                  child: Center(
                                    child: AymaWingLoader(
                                      size: 18,
                                      showLabel: false,
                                    ),
                                  ),
                                );
                              }
                              if (i == loaderRow) {
                                return const DividerLabel(
                                  "Your conversation",
                                  key: ValueKey('chat-conversation-divider'),
                                );
                              }
                              final idx = i - 1 - loaderRow;
                              if (aymaVoiceRow == 1 &&
                                  idx == turns.length + waiting.length) {
                                return _AymaVoiceProgressLine(
                                  key: const ValueKey('ayma-voice-progress'),
                                  stageLine: aymaVoiceProcessing!,
                                );
                              }
                              if (bubbleRow == 1 &&
                                  idx ==
                                      turns.length +
                                          waiting.length +
                                          aymaVoiceRow) {
                                return Padding(
                                  key: const ValueKey('feedback-bubble-row'),
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 8),
                                  child: FeedbackBubbleCard(
                                    trigger: _bubble!.trigger,
                                    initialText: _bubble!.prefill,
                                    fillText: _bubbleFillText,
                                    fillRevision: _bubbleFillRevision,
                                    api: _api,
                                    screenshotFile: _bubbleShotFile,
                                    screenshotPath: _bubbleShotPath,
                                    screenshotFailed: _bubbleShotFailed,
                                    initiallySent: _bubbleDone,
                                    onDismiss: () => setState(() {
                                      _bubble = null;
                                      _bubbleShotFile = null;
                                      _bubbleShotPath = null;
                                      _bubbleShotFailed = false;
                                    }),
                                    onSent: () =>
                                        setState(() => _bubbleDone = true),
                                  ),
                                );
                              }
                              if (idx >= turns.length) {
                                final queued = waiting[idx - turns.length];
                                return _QueuedBubble(
                                  key: ValueKey(queued.clientMsgId),
                                  message: queued,
                                  fundedNow:
                                      (CreditsBalance.instance.remaining.value ??
                                              0) >
                                          0,
                                  onCancel: () => _queue.cancel(queued.clientMsgId),
                                );
                              }
                              final t = turns[idx];
                              final prev = idx > 0 ? turns[idx - 1] : null;
                              final showDivider = shouldShowDateDivider(
                                prev?.createdAt,
                                t.createdAt,
                              );
                              final line = _TranscriptLine(
                                key: _turnKeys.putIfAbsent(t, () => GlobalKey()),
                                turn: t,
                                latest: idx == turns.length - 1,
                                api: _api,
                                clipPlayer: _clipPlayer,
                                nowPlaying: _nowPlaying,
                                initiallyFlagged: ThumbsDownStore.instance
                                    .isFlagged(t.text),
                                onFeedbackOutcome: (outcome) =>
                                    _store.markFeedbackOutcome(t, outcome),
                                onSwipeReply: (t.isFinal &&
                                        t.text.isNotEmpty)
                                    ? () => _onSwipeReply(t)
                                    : null,
                                onThumbsDown:
                                    (t.role == TurnRole.ayma &&
                                        t.isFinal &&
                                        t.text.isNotEmpty)
                                    ? () async {
                                        final uid = _currentUid();
                                        await _api.submitFeedback(
                                          category: 'thumbs_down',
                                          quote: t.text,
                                          sessionId: _sessionId,
                                        );
                                        await ThumbsDownStore.instance.recordThumbsDown(uid, t.text);
                                      }
                                    : null,
                              );
                              // A one-time landing spot from a "Why Ayma believes
                              // this" source tap — same soft tint the tool-use
                              // kicker chip above an Ayma line already uses.
                              final highlightedLine =
                                  identical(t, _highlightedTurn)
                                      ? AnimatedContainer(
                                          duration:
                                              const Duration(milliseconds: 300),
                                          margin: const EdgeInsets.symmetric(
                                              vertical: 2),
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 6),
                                          decoration: BoxDecoration(
                                            color: ac.accentFaint,
                                            borderRadius:
                                                BorderRadius.circular(12),
                                          ),
                                          child: line,
                                        )
                                      : line;
                              if (showDivider && t.createdAt != null) {
                                return Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    DateDividerChip(date: t.createdAt!),
                                    highlightedLine,
                                  ],
                                );
                              }
                              return highlightedLine;
                            },
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                if (photo && askAyma == null)
                  _capped(h * 0.1, _PhotoChatContext(url: widget.photoUrl)),
                // Live status ("Searching the web…") rides on the pending Ayma
                // turn now, so there's no separate "thinking" line here.
                if (askAyma != null)
                  _capped(
                    h * 0.5,
                    reverse: true,
                    // The scoped quick-suggestion chips pin above the composer
                    // once turns exist AND the history is actually listed (§
                    // D13: the sheet shares the real main history, so the
                    // empty-body placement above would almost never show) —
                    // inside this same cap, so they can never push the column
                    // past its bounds. Stood down while partial: the chips
                    // already show as the body there (see above), and showing
                    // them twice would duplicate the affordance.
                    ListenableBuilder(
                      listenable: _store,
                      builder: (context, _) {
                        final suggestions = quickSuggestionsFor(askAyma);
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (!partialSheet &&
                                _store.turns.isNotEmpty &&
                                suggestions.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                                child: _QuickChips(
                                  suggestions: suggestions,
                                  onPick: (s) {
                                    _composerController.text = s;
                                    _send();
                                  },
                                ),
                              ),
                            _buildAskAymaComposer(context),
                          ],
                        );
                      },
                    ),
                  )
                else
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ListenableBuilder(
                        listenable: _voice,
                        builder: (context, _) => _capped(
                          h * 0.5,
                          reverse: true,
                          _Composer(
                            anchorKey: widget.composerAnchorKey,
                            micAnchorKey: widget.composerAnchorKey != null
                                ? TourAnchors.keyFor(TourAnchors.asyncVoiceMic)
                                : null,
                            controller: _composerController,
                            focusNode: _composerFocus,
                            canSend:
                                (_canSend ||
                                        _pendingImage != null ||
                                        _pendingShared != null) &&
                                    !_sending,
                            onSend: _send,
                            onAttach: _attachImage,
                            pendingImage: _pendingImage,
                            onClearImage: () =>
                                setState(() => _pendingImage = null),
                            pendingShared: _pendingShared,
                            onClearShared: () =>
                                setState(() => _pendingShared = null),
                            replyingToSender: (!_voice.isActive &&
                                    _replyingToTurn != null)
                                ? (_replyingToTurn!.role == TurnRole.user
                                    ? 'You'
                                    : 'Ayma')
                                : null,
                            replyingToText: (!_voice.isActive &&
                                    _replyingToTurn != null)
                                ? _replyingToTurn!.text
                                : null,
                            onClearReply: _clearReply,
                            pageContextLabel:
                                (!_voice.isActive &&
                                        _pendingShared == null &&
                                        (_activePageContext?.screen ?? '')
                                            .isNotEmpty)
                                    ? _activePageContext!.label
                                    : null,
                            onClearPageContext: _clearPageContext,
                            voicePhase: _voice.phase,
                            relayRetrying: _voice.relayRetrying,
                            reconnecting: _voice.reconnecting,
                            muted: _voice.muted,
                            micYielded: _voice.micYielded,
                            aymaQuiet: _voice.aymaQuiet,
                            agentSpeaking: _voice.agentSpeaking,
                            activeToolLabel: _voice.activeToolLabel,
                            warmingNotice: _voice.warmingNotice,
                            awaitingFirstResponse: _voice.awaitingFirstResponse,
                            onVoiceTap: _toggleVoice,
                            onMuteTap: _voice.toggleMute,
                            onUnmuteAyma: _voice.unmuteAyma,
                            onExpandTap: _openVoiceScreen,
                            micLevel: _voice.micLevel,
                            aymaLevel: _voice.aymaLevel,
                          ),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// One fixed (non-list) part of [ChatScreen]'s column, capped at
/// [maxHeight] — see the note at the top of `_ChatScreenState.build`.
Widget _capped(double maxHeight, Widget child, {bool reverse = false}) =>
    CappedScroll(maxHeight: maxHeight, reverse: reverse, child: child);

/// Photo context immediately above the composer when "Chat about it" opens
/// a photo-scoped conversation. The close button dismisses that chat sheet.
class _PhotoChatContext extends StatelessWidget {
  const _PhotoChatContext({required this.url});
  final String url;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 6),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: 28,
              height: 28,
              child: AymaPhoto(
                url: url,
                displayWidth: 28,
                error: const SizedBox(width: 28, height: 28),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Talking about this photo',
              style: AymaType.mono(
                size: 10,
                color: ac.fgMute,
              ).copyWith(letterSpacing: 1.4),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 20),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
    );
  }
}

/// Ask-Ayma mode's header — replaces the full tab header (see
/// [ChatScreen.askAymaContext]'s doc): a generic "Ask Ayma" title with a
/// close button, a one-line prompt, and (when the context carries one) the
/// quoted-passage/finding card. Ported from the old dedicated `_AskAymaSheet`
/// this mode now supersedes — minus its own drag handle, since the shared
/// [showAymaChatModal] chrome this now opens in already draws one.
///
/// The title used to read "Edit with Ayma" unconditionally, even for a
/// read-only turn ([AskAymaOrigin.reportView] — a non-owner asking about
/// someone else's report, or any other Q&A-only entry point) where there is
/// nothing to edit at all (§ founder: "we don't only edit"). It's now the
/// same generic wording every caller sees, correction affordance or not.
/// Rebuilds [builder] when the software keyboard opens or closes. Observes
/// view metrics directly (rather than MediaQuery) because the surrounding
/// Scaffold consumes the keyboard inset from its subtree's MediaQuery.
class _KeyboardAwareHeader extends StatefulWidget {
  const _KeyboardAwareHeader({required this.builder});

  final Widget Function(bool keyboardOpen) builder;

  @override
  State<_KeyboardAwareHeader> createState() => _KeyboardAwareHeaderState();
}

class _KeyboardAwareHeaderState extends State<_KeyboardAwareHeader>
    with WidgetsBindingObserver {
  bool _open = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _open = View.of(context).viewInsets.bottom > 0;
  }

  @override
  void didChangeMetrics() {
    final open = View.of(context).viewInsets.bottom > 0;
    if (open != _open && mounted) setState(() => _open = open);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(_open);
}

class _AskAymaHeader extends StatelessWidget {
  const _AskAymaHeader({required this.ctx});
  final AskAymaContext ctx;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final quoteText = ctx.quoteText;
    // Same expand/collapse affordance (and keys) as the main header's own —
    // only one header ever renders at a time, so the keys never collide. A
    // second orb tap does the same thing (§ D13).
    final sheet = AymaChatSheetController.maybeOf(context);
    return Column(
      children: [
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              Icon(Icons.auto_awesome, size: 16, color: ac.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Ask Ayma',
                  style: AymaType.sans(size: 16, weight: FontWeight.w600, color: ac.fg),
                ),
              ),
              if (sheet != null)
                sheet.isExpanded
                    ? IconButton(
                        key: const Key('chatCollapseFullscreenButton'),
                        icon: Icon(
                          Icons.close_fullscreen_rounded,
                          size: 20,
                          color: ac.fgDim,
                        ),
                        tooltip: 'Collapse',
                        onPressed: sheet.collapse,
                      )
                    : IconButton(
                        key: const Key('chatExpandFullscreenButton'),
                        icon: Icon(
                          Icons.open_in_full_rounded,
                          size: 20,
                          color: ac.fgDim,
                        ),
                        tooltip: 'Expand to full screen',
                        onPressed: sheet.expand,
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
            "Ask a question, or tell Ayma what to change.",
            style: AymaType.sans(size: 13, color: ac.fgMute),
          ),
        ),
        if (quoteText.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: _SelectedQuote(
              title: ctx.quoteTitle.isNotEmpty
                  ? ctx.quoteTitle
                  : 'Selected text',
              text: quoteText,
            ),
          ),
      ],
    );
  }
}

class _SelectedQuote extends StatelessWidget {
  const _SelectedQuote({required this.title, required this.text});
  final String title;
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
          Text(
            title.toUpperCase(),
            style: AymaType.mono(
              size: 9,
              color: ac.fgMute,
            ).copyWith(letterSpacing: 1.4),
          ),
          const SizedBox(height: 6),
          // The FULL item text, always — no line cap, no ellipsis (§ D12:
          // a Projects quote cut mid-sentence). This card sizes to the item
          // and holds no scroll of its own; the header region's generous cap
          // above only ever binds for a pathological quote in a tiny window.
          Text(
            '"$text"',
            style: AymaType.message(color: ac.fg).copyWith(fontStyle: FontStyle.italic),
          ),
        ],
      ),
    );
  }
}

class _QuickChips extends StatelessWidget {
  const _QuickChips({required this.suggestions, required this.onPick});
  final List<String> suggestions;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final s in suggestions)
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

class _NoReply implements Exception {
  const _NoReply();
}

/// One transcript turn as a labelled line — no bubble. Ayma speaks in serif
/// italic; you answer in sans. Anything but the latest turn is dimmed. Ayma's
/// lines carry a one-tap thumbs-down that logs conversational feedback (§15).
/// Marks the end of an Ayma turn that carries a stored report, e.g.
/// `…take a look. [appearance:abc123]` or `[deep_dive:uid_x]`. The legacy
/// `[face_report:…]` / `[body_report:…]` / `[physical:…]` markers still parse
/// (old chat turns) — they open the appearance / legacy viewer. Stripped from
/// the shown text; drives the inline "View report" / "View research" card.
final _reportMarker = RegExp(
  r'\s*\[(appearance|face_report|body_report|deep_dive|physical|match):'
  r'([A-Za-z0-9_-]+)\]\s*$',
);

/// `face_report` -> `face`, `body_report` -> `body`, `deep_dive` -> `deep_dive`,
/// `appearance` -> `appearance`, `physical` -> `physical`.
String _reportKindOf(String raw) => raw.replaceFirst('_report', '');

class _TranscriptLine extends StatefulWidget {
  const _TranscriptLine({
    super.key,
    required this.turn,
    required this.latest,
    this.api,
    this.initiallyFlagged = false,
    this.onThumbsDown,
    this.onFeedbackOutcome,
    this.onSwipeReply,
    this.clipPlayer,
    this.nowPlaying,
  });

  final TranscriptTurn turn;
  final bool latest;

  /// Used to fetch a stored report when the turn carries a `[*_report:id]`
  /// marker. Null in tests that don't exercise that path.
  final ApiClient? api;

  /// The shared voice-clip player + now-playing key for voice-message turns.
  /// Null in tests that don't exercise clip playback (the play row hides).
  final AsyncVoicePlayer? clipPlayer;
  final ValueNotifier<String?>? nowPlaying;

  /// Whether this turn was already flagged with thumbs-down feedback (persisted across relaunch).
  final bool initiallyFlagged;

  /// Non-null only for a finished Ayma line — fire-and-forget feedback.
  final Future<void> Function()? onThumbsDown;

  /// Called with `'sent'` / `'dismissed'` when this turn's feedback
  /// draft card is resolved, so the outcome is recorded on the turn.
  final ValueChanged<String>? onFeedbackOutcome;

  /// Non-null for a finished line — triggers swipe to reply.
  final VoidCallback? onSwipeReply;

  @override
  State<_TranscriptLine> createState() => _TranscriptLineState();
}

class _TranscriptLineState extends State<_TranscriptLine> {
  late bool _flagged = widget.initiallyFlagged;

  @override
  void didUpdateWidget(covariant _TranscriptLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initiallyFlagged && !_flagged) {
      _flagged = true;
    }
  }

  /// Unique per line so two turns carrying the same image never collide as
  /// duplicate Hero tags in one route.
  final _photoHeroTag = UniqueKey();

  Future<void> _thumbsDown() async {
    if (_flagged) return;
    setState(() => _flagged = true);
    try {
      await widget.onThumbsDown!();
    } catch (_) {
      if (mounted) setState(() => _flagged = false);
    }
  }

  Widget _photo(BuildContext context, {required bool rounded}) {
    final turn = widget.turn;
    // A just-sent photo renders straight from the local file until the
    // Storage upload resolves and swaps in `imageUrl` (§ chat photo latency).
    final image = turn.imageUrl != null
        ? AymaPhoto(
            url: turn.imageUrl!,
            fit: BoxFit.cover,
            displayWidth: 260,
            error: const SizedBox(
              height: 60,
              child: Center(child: Icon(Icons.broken_image_outlined)),
            ),
          )
        : Image.file(turn.imageFile!, fit: BoxFit.cover);
    // Tap for the full-screen viewer (zoom / share / download) — generated
    // images, edited photos, and your own sends alike.
    return GestureDetector(
      onTap: () => AymaImageViewer.open(
        context,
        url: turn.imageUrl,
        file: turn.imageFile,
        heroTag: _photoHeroTag,
      ),
      child: Hero(
        tag: _photoHeroTag,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(rounded ? 14 : 12),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.62,
            ),
            child: image,
          ),
        ),
      ),
    );
  }

  /// The play row for a voice-message turn, or null when this turn has no
  /// clip (or the test didn't wire a player).
  Widget? _clipRow(Color iconColor, Color captionColor) {
    final turn = widget.turn;
    final player = widget.clipPlayer;
    final nowPlaying = widget.nowPlaying;
    if (player == null ||
        nowPlaying == null ||
        (turn.audioUrl == null || turn.audioUrl!.isEmpty) &&
            turn.audioFile == null) {
      return null;
    }
    return VoiceClipRow(
      audioUrl: turn.audioUrl,
      audioFile: turn.audioFile?.path,
      player: player,
      nowPlaying: nowPlaying,
      clipKey:
          '${turn.role.name}:${turn.text.hashCode}:${turn.audioUrl ?? turn.audioFile?.path}',
      iconColor: iconColor,
      captionColor: captionColor,
    );
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final turn = widget.turn;
    final isAyma = turn.role == TurnRole.ayma;
    final hasImage = turn.imageUrl != null || turn.imageFile != null;
    final width = MediaQuery.of(context).size.width;
    final timeStr = turn.createdAt != null
        ? formatMessageTime(turn.createdAt!)
        : null;

    final Widget turnWidget;
    if (!isAyma) {
      // You — a right-aligned rounded bubble (Gemini style).
      final userClip = _clipRow(ac.onAccent, ac.onAccent.withValues(alpha: 0.85));
      final hasReply = turn.replySubject.isNotEmpty;
      final showBubble = turn.text.isNotEmpty || userClip != null || hasReply;
      turnWidget = Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Align(
          alignment: Alignment.centerRight,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: width * 0.82),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (turn.sharedKind.isNotEmpty)
                  Padding(
                    padding: EdgeInsets.only(bottom: !showBubble ? 0 : 8),
                    child: _SharedRefCard.fromTurn(turn),
                  ),
                if (hasImage)
                  Padding(
                    padding: EdgeInsets.only(bottom: !showBubble ? 0 : 8),
                    child: _photo(context, rounded: true),
                  ),
                if (showBubble)
                  CopyOnLongPress(
                    text: turn.text.isNotEmpty ? turn.text : 'Voice message',
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        // Solid accent, same as a sent DM bubble — one "mine"
                        // treatment app-wide (founder, 2026-09-27; was the
                        // washed-out accentFaint tint).
                        color: ac.accent,
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(16),
                          topRight: Radius.circular(16),
                          bottomLeft: Radius.circular(16),
                          bottomRight: Radius.circular(4),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (hasReply)
                            _QuotedReplyCard(
                              key: const ValueKey('quotedReplyCard'),
                              subject: turn.replySubject,
                              snippet: turn.replySnippet,
                              kind: turn.replyKind,
                            ),
                          if (userClip != null)
                            Padding(
                              padding: EdgeInsets.only(
                                bottom: turn.text.isNotEmpty ? 6 : 0,
                              ),
                              child: userClip,
                            ),
                          if (turn.text.isNotEmpty)
                            Text(
                              turn.text,
                              style: AymaType.message(color: ac.onAccent),
                            ),
                          if (timeStr != null) ...[
                            const SizedBox(height: 2),
                            Align(
                              alignment: Alignment.centerRight,
                              child: Text(
                                timeStr,
                                style: AymaType.sans(
                                  size: 10.5,
                                  color: ac.onAccent.withValues(alpha: 0.72),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                if (!showBubble && timeStr != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4, right: 4),
                    child: Text(
                      timeStr,
                      style: AymaType.sans(
                        size: 10.5,
                        color: ac.fgMute,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    } else {
      // Ayma — full-width, no bubble; serif italic; markdown headers/lists.
      // A finished turn carries a face/body report either as fields (skill fired
      // from the Skills tab) or as a trailing `[face_report:id]` marker in the
      // text (Ayma called the tool herself). Either way: strip the marker and
      // render the report card inline. `[1]`-style citation noise is also removed.
      final marker = turn.isFinal ? _reportMarker.firstMatch(turn.text) : null;
      final reportKind = turn.reportKind.isNotEmpty
          ? turn.reportKind
          : (marker != null ? _reportKindOf(marker.group(1)!) : null);
      final reportId = turn.reportId.isNotEmpty
          ? turn.reportId
          : marker?.group(2);
      var displayText = marker != null
          ? turn.text.replaceFirst(_reportMarker, '')
          : turn.text;
      if (reportKind != null) {
        displayText = displayText.replaceAll(RegExp(r'\s*\[\d+\]'), '').trim();
      }
      // A pending ("Thinking…") turn never carries a clip — only resolve the
      // row for a finished turn.
      final aymaClip = turn.isFinal ? _clipRow(ac.accent, ac.fgMute) : null;

      turnWidget = Opacity(
      opacity: widget.latest || !turn.isFinal ? 1 : 0.62,
      child: Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (turn.tools.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: ac.accentFaint,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (turn.subjectImage != null) ...[
                        ClipOval(
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: AymaPhoto(
                              url: turn.subjectImage!,
                              displayWidth: 16,
                              error: Icon(
                                Icons.person,
                                size: 12,
                                color: ac.fgMute,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                      ] else ...[
                        Icon(Icons.auto_awesome, size: 13, color: ac.accent),
                        const SizedBox(width: 4),
                      ],
                      Flexible(
                        child: Text(
                          turn.tools.join('  ·  '),
                          style: AymaType.sans(
                            size: 12,
                            color: ac.accent,
                          ).copyWith(fontWeight: FontWeight.w600, height: 1.2),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (hasImage)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _photo(context, rounded: false),
              ),
            if (aymaClip != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: aymaClip,
              ),
            if (!turn.isFinal)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // A 16px/1.5-line-height first line is ~24px tall; nudge
                  // the smaller 14px loader down so it sits centered against
                  // that first line instead of pinned to the row's top.
                  const Padding(
                    padding: EdgeInsets.only(top: 5),
                    child: AymaWingLoader(size: 14, showLabel: false),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      turn.text,
                      style: AymaType.message(color: ac.fgDim),
                    ),
                  ),
                ],
              )
            else if (displayText.isNotEmpty)
              // Over-long Ayma turns (e.g. the 5,728-char self-check
              // report) collapse to a preview: laying the whole text
              // out on every store rebuild wedged the UI thread into
              // multi-second frames and ANRs (NOTE 144/145).
              CopyOnLongPress(
                text: displayText,
                child: CollapsibleMessageText(
                  displayText,
                  style: AymaType.message(color: ac.fg),
                  linkColor: ac.accent,
                ),
              ),
            if (turn.capped)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.tonalIcon(
                    onPressed: () => showOutOfCreditsSheet(context),
                    icon: const Icon(Icons.bolt, size: 18),
                    label: const Text('Upgrade'),
                  ),
                ),
              ),
            if (reportKind != null && reportId != null && reportId.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: _InlineReportCard(
                  kind: reportKind,
                  reportId: reportId,
                  subjectImage: turn.subjectImage ?? '',
                  api: widget.api,
                ),
              ),
            if (turn.feedbackKind.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: FeedbackDraftCard(
                  key: ValueKey('feedback-${turn.feedbackTitle}-${turn.text.hashCode}'),
                  kind: turn.feedbackKind,
                  title: turn.feedbackTitle,
                  body: turn.feedbackBody,
                  resolvedOutcome: turn.feedbackOutcome,
                  onSent: () =>
                      widget.onFeedbackOutcome?.call('sent'),
                  onDismiss: () =>
                      widget.onFeedbackOutcome?.call('dismissed'),
                  onSentExpired: () =>
                      widget.onFeedbackOutcome?.call('sent-shown'),
                  api: widget.api,
                ),
              ),
            if (widget.onThumbsDown != null ||
                (turn.isFinal && timeStr != null))
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (turn.isFinal && timeStr != null) ...[
                      Text(
                        timeStr,
                        style: AymaType.sans(
                          size: 10.5,
                          color: ac.fgMute,
                        ),
                      ),
                      if (widget.onThumbsDown != null)
                        const SizedBox(width: 8),
                    ],
                    if (widget.onThumbsDown != null)
                      InkWell(
                        onTap: _flagged ? null : _thumbsDown,
                        borderRadius: BorderRadius.circular(6),
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                _flagged
                                    ? Icons.thumb_down_alt
                                    : Icons.thumb_down_alt_outlined,
                                size: 13,
                                color: _flagged ? ac.accent : ac.fgMute,
                              ),
                              if (_flagged) ...[
                                const SizedBox(width: 4),
                                Text(
                                  'noted',
                                  style: AymaType.mono(
                                    size: 8,
                                    color: ac.fgMute,
                                  ).copyWith(letterSpacing: 1.5),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
    }

    if (widget.onSwipeReply != null) {
      return Dismissible(
        key: ValueKey('swipe-reply-${turn.hashCode}-${turn.createdAt?.millisecondsSinceEpoch ?? turn.text.hashCode}'),
        direction: DismissDirection.horizontal,
        dismissThresholds: const {
          DismissDirection.horizontal: 0.2,
          DismissDirection.startToEnd: 0.2,
          DismissDirection.endToStart: 0.2,
        },
        confirmDismiss: (_) async {
          HapticFeedback.lightImpact();
          widget.onSwipeReply?.call();
          return false;
        },
        background: Container(
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.only(left: 16),
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: ac.accentFaint,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.reply_rounded,
              color: ac.accent,
              size: 18,
            ),
          ),
        ),
        secondaryBackground: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 16),
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: ac.accentFaint,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.reply_rounded,
              color: ac.accent,
              size: 18,
            ),
          ),
        ),
        child: turnWidget,
      );
    }
    return turnWidget;
  }
}

/// An un-sent "share this into the chat" attachment held above the composer
/// (an "Ask Ayma" report chip). Posted as a shared card turn on the next send.
/// A send whose connection died before an answer arrived, parked for
/// reconciliation against the server (see `_reconcilePendingSend`). [msgId]
/// is the send's `client_msg_id` — the exact-match key into `/chat/history`
/// and the idempotency key [resend] re-asks with. [knownAyma] is the set of
/// final Ayma turns already on screen before the send, the matching fallback
/// for servers that predate ids. [message] feeds the Retry affordance if the
/// turn genuinely failed.
class _PendingSendReconcile {
  const _PendingSendReconcile({
    required this.msgId,
    required this.message,
    required this.knownAyma,
    required this.resend,
    this.imagePath = '',
    this.queueable = true,
  });

  final String msgId;
  final String message;
  final Set<String> knownAyma;
  final Future<ChatResult> Function() resend;

  /// The already-uploaded photo of this send, and whether an out-of-credits
  /// outcome may queue it (not for a shared-card send).
  final String imagePath;
  final bool queueable;
}

/// A message waiting in the [PendingChatQueue]: the user's bubble, dimmed, with
/// why it hasn't gone and a way to cancel it.
class _QueuedBubble extends StatelessWidget {
  const _QueuedBubble({
    super.key,
    required this.message,
    required this.fundedNow,
    required this.onCancel,
  });

  final QueuedChatMessage message;

  /// Credits are available, so the wait is only for the send to start.
  final bool fundedNow;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final width = MediaQuery.of(context).size.width;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Align(
        alignment: Alignment.centerRight,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: width * 0.82),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (message.imageUrl.isNotEmpty)
                Padding(
                  padding:
                      EdgeInsets.only(bottom: message.message.isEmpty ? 0 : 6),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: width * 0.62),
                      child: AymaPhoto(
                        url: message.imageUrl,
                        fit: BoxFit.cover,
                        displayWidth: 260,
                        error: const SizedBox(
                          height: 60,
                          child: Center(
                              child: Icon(Icons.broken_image_outlined)),
                        ),
                      ),
                    ),
                  ),
                ),
              if (message.message.isNotEmpty)
                Opacity(
                  opacity: 0.6,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: ac.accent,
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(16),
                        topRight: Radius.circular(16),
                        bottomLeft: Radius.circular(16),
                        bottomRight: Radius.circular(4),
                      ),
                    ),
                    child: Text(
                      message.message,
                      style: AymaType.sans(
                          size: 15, color: ac.onAccent, height: 1.4),
                    ),
                  ),
                ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.schedule_rounded, size: 14, color: ac.fgMute),
                  const SizedBox(width: 4),
                  Text(
                    fundedNow ? 'Waiting to send' : 'Waiting for credits',
                    style: AymaType.sans(size: 12, color: ac.fgMute),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(
                      minimumSize: const Size(44, 44),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    onPressed: onCancel,
                    child: const Text('Cancel'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Ayma-side progress line shown while an async voice message is being
/// processed by the backend (transcribing / thinking / answering).
class _AymaVoiceProgressLine extends StatelessWidget {
  const _AymaVoiceProgressLine({
    super.key,
    required this.stageLine,
  });

  final String stageLine;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 5),
            child: AymaWingLoader(size: 14, showLabel: false),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              stageLine,
              style: AymaType.message(color: ac.fgDim),
            ),
          ),
        ],
      ),
    );
  }
}

class _SharedDraft {
  const _SharedDraft({
    required this.kind,
    required this.uid,
    required this.name,
    required this.photo,
    required this.refId,
    this.refVersion = '',
    this.editSelf = false,
  });

  final String kind;
  final String uid;
  final String name;
  final String photo;
  final String refId;

  /// The version stamp of the exact record staged (Appearance: the
  /// report run's `created_at`) — part of the share reference, so Ayma
  /// pulls the run the user opened, not a later re-run.
  final String refVersion;
  final bool editSelf;
}

/// The card shown for a shared person / conversation / match / story / report.
/// Used both when staged above the composer (with an [onClear] button) and
/// in the transcript as a sent turn. Tapping opens the underlying screen.
class _SharedRefCard extends StatelessWidget {
  const _SharedRefCard({
    super.key,
    required this.kind,
    required this.name,
    required this.photo,
    required this.refId,
    required this.uid,
    this.onClear,
  });

  factory _SharedRefCard.fromTurn(TranscriptTurn turn) => _SharedRefCard(
        kind: turn.sharedKind,
        name: turn.sharedName,
        photo: turn.sharedPhoto,
        refId: turn.sharedRefId,
        uid: turn.sharedUid,
      );

  factory _SharedRefCard.fromDraft(
    _SharedDraft draft, {
    Key? key,
    VoidCallback? onClear,
  }) =>
      _SharedRefCard(
        key: key,
        kind: draft.kind,
        name: draft.name,
        photo: draft.photo,
        refId: draft.refId,
        uid: draft.uid,
        onClear: onClear,
      );

  final String kind;
  final String name;
  final String photo;
  final String refId;
  final String uid;
  final VoidCallback? onClear;

  ({String label, IconData icon, String route, String kindLabel}) get _meta =>
      switch (kind) {
        'conversation' => (
            label: 'Your chat with $name',
            icon: Icons.forum_outlined,
            route: refId.isEmpty ? '' : '/dm/$refId',
            kindLabel: 'CHAT',
          ),
        'deep_dive' => (
            label: 'Web research on $name',
            icon: Icons.travel_explore,
            route: refId.isEmpty ? '' : '/deep-dive/$refId',
            kindLabel: 'WEB FINDING',
          ),
        'match' => (
            label: '$name · match report',
            icon: Icons.insights_rounded,
            route: refId.isEmpty ? '' : '/match/$refId',
            kindLabel: 'MATCH REPORT',
          ),
        'story' => (
            label: 'Your Story',
            icon: Icons.auto_stories_outlined,
            route: '/profile/wiki',
            kindLabel: 'STORY',
          ),
        'appearance' => (
            label: name,
            icon: Icons.photo_library_outlined,
            route: refId.isEmpty ? '' : '/appearance/$refId',
            kindLabel: 'APPEARANCE REPORT',
          ),
        _ => (
            label: name,
            icon: Icons.person_outline,
            route: uid.isEmpty ? '' : '/profile/user/$uid',
            kindLabel: 'PROFILE',
          ),
      };

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final m = _meta;
    return InkWell(
      onTap: m.route.isEmpty ? null : () => context.push(m.route),
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: onClear != null ? 260 : 240,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: ac.bgElev,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: ac.lineSoft, width: 0.5),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(9),
              child: SizedBox(
                width: 40,
                height: 40,
                child: photo.isNotEmpty
                    ? AymaPhoto(
                        url: photo,
                        displayWidth: 40,
                        error: Icon(m.icon, size: 18, color: ac.fgMute),
                      )
                    : DecoratedBox(
                        decoration: BoxDecoration(color: ac.accentFaint),
                        child: Icon(m.icon, size: 18, color: ac.accent),
                      ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    m.label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AymaType.sans(size: 13, color: ac.fg, height: 1.25),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    m.route.isEmpty
                        ? 'SHARED WITH AYMA'
                        : '${m.kindLabel} · TAP TO OPEN',
                    style: AymaType.mono(
                      size: 8,
                      color: ac.fgMute,
                    ).copyWith(letterSpacing: 1.4),
                  ),
                ],
              ),
            ),
            if (onClear != null) ...[
              const SizedBox(width: 4),
              IconButton(
                key: const ValueKey('clearSharedDraft'),
                onPressed: onClear,
                iconSize: 16,
                icon: const Icon(Icons.close),
                color: ac.fgMute,
                visualDensity: VisualDensity.compact,
                tooltip: 'Remove attachment',
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A quoted reply card rendered above the user's message inside the bubble
/// (WhatsApp style). Used for pinned page context (naming the real subject)
/// or an earlier Ayma or user message quoted via swipe-to-reply.
class _QuotedReplyCard extends StatelessWidget {
  const _QuotedReplyCard({
    super.key,
    required this.subject,
    required this.snippet,
    required this.kind,
  });

  final String subject;
  final String snippet;
  final String kind;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final isPage = kind == 'page' && subject != 'Ayma' && subject != 'You';
    final icon = isPage ? Icons.push_pin_outlined : Icons.reply_rounded;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(8, 6, 10, 6),
      decoration: BoxDecoration(
        color: ac.onAccent.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(8),
        border: Border(
          left: BorderSide(
            color: ac.onAccent,
            width: 3.5,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 13,
                color: ac.onAccent.withValues(alpha: 0.9),
              ),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  subject,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AymaType.sans(
                    size: 12,
                    color: ac.onAccent,
                    weight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          if (snippet.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              snippet,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AymaType.sans(
                size: 11,
                color: ac.onAccent.withValues(alpha: 0.8),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A face/body report rendered inline under an Ayma turn (§ report cards).
/// Fetches the stored report + its analysed photo; renders nothing at all if
/// there's no usable report to show. Tapping opens the same report full-screen.
class _InlineReportCard extends StatefulWidget {
  const _InlineReportCard({
    required this.kind,
    required this.reportId,
    this.subjectImage = '',
    this.api,
  });

  final String kind; // 'face' | 'body' | 'deep_dive' | 'physical' | 'appearance' | 'match'
  final String reportId;
  final String subjectImage;
  final ApiClient? api;

  @override
  State<_InlineReportCard> createState() => _InlineReportCardState();
}

class _InlineReportCardState extends State<_InlineReportCard> {
  late final bool _isFace = widget.kind == 'face';
  late final bool _isDive = widget.kind == 'deep_dive';
  late final bool _isPhysical = widget.kind == 'physical';
  late final bool _isAppearance = widget.kind == 'appearance';
  late final bool _isMatch = widget.kind == 'match';

  /// The match card reads the pair's current score (it may have been
  /// recalculated since the result landed), so the label always matches the
  /// report it opens.
  late final Future<MatchReport?>? _matchFuture =
      _isMatch ? widget.api?.matchReport(widget.reportId) : null;
  late final Future<Object>? _future =
      (_isDive || _isPhysical || _isAppearance || _isMatch)
      ? null
      : (_isFace
            ? fetchStoredFaceReport(widget.reportId, api: widget.api)
            : fetchStoredBodyReport(widget.reportId, api: widget.api));

  void _openFull() {
    if (_isDive) {
      context.push('/deep-dive/${Uri.encodeComponent(widget.reportId)}');
    } else if (_isMatch) {
      context.push('/match/${Uri.encodeComponent(widget.reportId)}');
    } else if (_isAppearance) {
      context.push('/appearance/${Uri.encodeComponent(widget.reportId)}');
    } else if (_isPhysical) {
      context.push(
        '/physical-attributes/${Uri.encodeComponent(widget.reportId)}',
      );
    } else if (_isFace) {
      openStoredFaceReport(context, api: widget.api, reportId: widget.reportId);
    } else {
      openStoredBodyReport(context, api: widget.api, reportId: widget.reportId);
    }
  }

  /// A compact "open it" row (used for the text-heavy deep dive and the
  /// list-shaped physical profile).
  Widget _compactCard(
    BuildContext context, {
    required IconData icon,
    required String label,
  }) {
    final ac = context.ac;
    return GestureDetector(
      onTap: _openFull,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: ac.bgElev,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: ac.lineSoft, width: 0.5),
        ),
        child: Row(
          children: [
            ClipOval(
              child: SizedBox(
                width: 34,
                height: 34,
                child: widget.subjectImage.isNotEmpty
                    ? AymaPhoto(
                        url: widget.subjectImage,
                        displayWidth: 34,
                        error: Icon(icon, size: 16, color: ac.fgMute),
                      )
                    : DecoratedBox(
                        decoration: BoxDecoration(color: ac.accentFaint),
                        child: Icon(icon, size: 16, color: ac.accent),
                      ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(label, style: AymaType.sans(size: 13, color: ac.fg)),
            ),
            Icon(Icons.chevron_right, size: 16, color: ac.fgMute),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isDive) {
      // Web research is text-heavy — a compact "open it" card, not the report
      // rendered inline.
      return _compactCard(
        context,
        icon: Icons.public,
        label: 'Web research report',
      );
    }
    if (_isPhysical) {
      return _compactCard(
        context,
        icon: Icons.badge_outlined,
        label: 'Physical profile report',
      );
    }
    if (_isMatch) {
      return FutureBuilder<MatchReport?>(
        future: _matchFuture,
        builder: (context, snap) {
          final score = snap.data?.score;
          return _compactCard(
            context,
            icon: Icons.favorite_border,
            label: score == null
                ? 'Match report'
                : 'Match report · ${(score * 100).round()}%',
          );
        },
      );
    }
    if (_isAppearance) {
      return _compactCard(
        context,
        icon: Icons.auto_awesome_outlined,
        label: 'Appearance report',
      );
    }
    final ac = context.ac;
    return FutureBuilder<Object>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: AymaWingLoader(size: 16, showLabel: false),
          );
        }
        Widget? view;
        if (!snap.hasError && snap.data != null) {
          final data = snap.data;
          if (data is StoredFaceReport && data.report != null) {
            view = FaceReportView(
              report: data.report!,
              imageUrl: data.imageUrl,
              api: widget.api,
            );
          } else if (data is StoredBodyReport && data.report != null) {
            view = BodyReportView(
              report: data.report!,
              imageUrl: data.imageUrl,
              api: widget.api,
            );
          }
        }
        // No usable report -> show nothing (not even a button).
        if (view == null) return const SizedBox.shrink();
        return GestureDetector(
          onTap: _openFull,
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: ac.bgElev,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: ac.lineSoft, width: 0.5),
            ),
            child: view,
          ),
        );
      },
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    this.anchorKey,
    required this.controller,
    required this.focusNode,
    required this.canSend,
    required this.onSend,
    required this.onAttach,
    required this.pendingImage,
    required this.onClearImage,
    required this.pendingShared,
    required this.onClearShared,
    this.replyingToSender,
    this.replyingToText,
    this.onClearReply,
    this.pageContextLabel,
    required this.onClearPageContext,
    required this.voicePhase,
    this.relayRetrying = false,
    this.reconnecting = false,
    required this.muted,
    this.micYielded = false,
    this.aymaQuiet = false,
    required this.agentSpeaking,
    this.activeToolLabel,
    this.warmingNotice,
    this.awaitingFirstResponse = false,
    required this.onVoiceTap,
    required this.onMuteTap,
    required this.onUnmuteAyma,
    required this.onExpandTap,
    required this.micLevel,
    required this.aymaLevel,
    this.micAnchorKey,
  });

  /// Feature-tour anchor for the whole composer; forwarded to [ChatComposer].
  final Key? anchorKey;

  final Key? micAnchorKey;

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool canSend;
  final VoidCallback onSend;
  final VoidCallback onAttach;
  final File? pendingImage;
  final VoidCallback onClearImage;
  final _SharedDraft? pendingShared;
  final VoidCallback onClearShared;

  /// The earlier message sender being replied to ('Ayma' or 'You'); null when none.
  final String? replyingToSender;

  /// The earlier Ayma or user message text being replied to via swipe; null when none.
  final String? replyingToText;
  final VoidCallback? onClearReply;

  /// The "you were looking at…" chip label (see [ChatScreen.pageContext] /
  /// `_ChatScreenState._pageContext`) — null hides the chip entirely.
  final String? pageContextLabel;
  final VoidCallback onClearPageContext;
  final VoiceSessionPhase voicePhase;

  /// True while the one-shot relay-retry connect attempt is in flight —
  /// the connecting status line reads "Reconnecting…" instead.
  final bool relayRetrying;

  /// True while an established call's transport is re-establishing a
  /// dropped connection — the live status line reads "Reconnecting…"
  /// instead of claiming she's listening over dead air.
  final bool reconnecting;
  final bool muted;
  final bool micYielded;

  /// Ayma was told to "shut up" and is deliberately silent.
  final bool aymaQuiet;
  final bool agentSpeaking;

  /// The live, present-progressive label of whichever tool Ayma is running
  /// right now ("Researching them online…"), or null when none is — a
  /// transient "what she's doing" indicator for a slow tool call mid-turn
  /// (§1.7 step 3), shown in place of "Listening" while it's non-null.
  final String? activeToolLabel;

  /// Honest status shown in place of "Listening…" while the open-weights
  /// (Modal) brain is warming from a cold start (§13.9); null otherwise.
  final String? warmingNotice;

  /// True while the call is live but Ayma's first reply hasn't landed yet —
  /// the inline status reads "Connecting…" instead of "Listening…" (same
  /// honest-wait treatment as the full voice screen).
  final bool awaitingFirstResponse;
  final Future<void> Function() onVoiceTap;
  final Future<void> Function() onMuteTap;

  /// The quiet chip's Unmute button: asks the agent to talk again.
  final Future<void> Function() onUnmuteAyma;

  /// Re-opens the full-screen voice view for an already-live call — tapping
  /// the inline call bar's status label (see [ChatComposer]'s voice row)
  /// after switching back to this tab from elsewhere reaches the same
  /// immersive orb view a fresh call opens into automatically.
  final Future<void> Function() onExpandTap;

  /// Live 0..1 audio levels for the voice-mode waveform.
  final ValueListenable<double> micLevel;
  final ValueListenable<double> aymaLevel;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final voiceActive =
        voicePhase == VoiceSessionPhase.connecting ||
        voicePhase == VoiceSessionPhase.waking ||
        voicePhase == VoiceSessionPhase.live;

    final mode = !voiceActive
        ? ComposerMode.text
        : (voicePhase != VoiceSessionPhase.live
              ? ComposerMode.connecting
              : (agentSpeaking
                    ? ComposerMode.aiSpeaking
                    : (micYielded
                          ? ComposerMode.connecting
                          : ComposerMode.listening)));

    String? statusLabel;
    if (voiceActive) {
      statusLabel = switch (voicePhase) {
        // ice-relay-retry (second connect attempt, TURN relay forced).
        VoiceSessionPhase.connecting =>
          relayRetrying ? 'Reconnecting…' : 'Connecting…',
        VoiceSessionPhase.waking => 'Waking Ayma…',
        _ =>
          micYielded
              ? 'Mic yielded'
              : (muted
                    ? 'Muted'
                    : (reconnecting
                          ? 'Reconnecting…'
                          : (agentSpeaking
                                ? 'Ayma is speaking…'
                                : (activeToolLabel ??
                                      warmingNotice ??
                                      (awaitingFirstResponse
                                          ? 'Connecting…'
                                          : 'Listening…'))))),
      };
    }

    return SafeArea(
      top: false,
      child: Padding(
        // Shared with the DM thread's composer so both screens keep the same
        // gap to the persistent nav bar (founder ask).
        padding: kComposerBarPadding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (replyingToText != null && !voiceActive)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8, left: 2),
                  child: Container(
                    key: const ValueKey('composerReplyPreview'),
                    padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
                    decoration: BoxDecoration(
                      color: ac.bgElev,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: ac.lineSoft, width: 0.5),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 3,
                          height: 28,
                          decoration: BoxDecoration(
                            color: ac.accent,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(
                          Icons.reply_rounded,
                          size: 16,
                          color: ac.accent,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'Replying to ${replyingToSender ?? 'Ayma'}',
                                style: AymaType.sans(
                                  size: 11,
                                  color: ac.accent,
                                  weight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                replyingToText!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AymaType.sans(
                                  size: 12,
                                  color: ac.fgDim,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 4),
                        IconButton(
                          onPressed: onClearReply,
                          iconSize: 16,
                          icon: const Icon(Icons.close),
                          color: ac.fgMute,
                          visualDensity: VisualDensity.compact,
                          tooltip: 'Cancel reply',
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (pageContextLabel != null && !voiceActive)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8, left: 2),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
                    decoration: BoxDecoration(
                      color: ac.bgElev,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: ac.lineSoft, width: 0.5),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.push_pin_outlined,
                          size: 16,
                          color: ac.accent,
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            pageContextLabel!,
                            overflow: TextOverflow.ellipsis,
                            style: AymaType.sans(size: 12.5, color: ac.fgDim),
                          ),
                        ),
                        IconButton(
                          onPressed: onClearPageContext,
                          iconSize: 16,
                          icon: const Icon(Icons.close),
                          color: ac.fgMute,
                          visualDensity: VisualDensity.compact,
                          tooltip: 'Remove page context',
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (pendingShared != null)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8, left: 2),
                  child: _SharedRefCard.fromDraft(
                    pendingShared!,
                    key: const ValueKey('stagedSharedChip'),
                    onClear: onClearShared,
                  ),
                ),
              ),
            if (pendingImage != null)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8, left: 4),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.file(
                          pendingImage!,
                          width: 56,
                          height: 56,
                          fit: BoxFit.cover,
                        ),
                      ),
                      Positioned(
                        top: -8,
                        right: -8,
                        child: IconButton(
                          onPressed: onClearImage,
                          iconSize: 18,
                          icon: const Icon(Icons.cancel),
                          color: ac.fgMute,
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (aymaQuiet && voicePhase == VoiceSessionPhase.live)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: AymaQuietChip(onUnmute: () => onUnmuteAyma()),
              ),
            ChatComposer(
              rootKey: anchorKey,
              mode: mode,
              controller: controller,
              focusNode: focusNode,
              canSend: canSend,
              onSend: onSend,
              onAttach: onAttach,
              onMicPressed: () => onVoiceTap(),
              micKey: micAnchorKey,
              onStopPressed: () => onVoiceTap(),
              onMuteTap: () => onMuteTap(),
              onExpandTap: () => onExpandTap(),
              muted: muted || micYielded,
              userAmplitude: micLevel,
              aiAmplitude: aymaLevel,
              statusLabel: statusLabel,
            ),
          ],
        ),
      ),
    );
  }
}
