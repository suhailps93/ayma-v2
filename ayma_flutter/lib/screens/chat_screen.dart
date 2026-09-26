import 'dart:async';
import 'dart:io';

import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../services/api_client.dart';
import '../services/app_context.dart';
import '../services/call_permissions.dart';
import '../services/chat_inbox.dart';
import '../services/chat_service.dart';
import '../services/ids.dart';
import '../services/profile_service.dart';
import '../services/transcript_store.dart';
import '../services/voice_session_controller.dart';
import '../services/voice_transport.dart';
import '../theme.dart';
import '../widgets/ask_ayma_context.dart';
import '../widgets/ayma_orb.dart';
import '../widgets/ayma_photo.dart';
import '../widgets/ayma_primitives.dart';
import '../widgets/body_report_view.dart';
import '../widgets/face_report_view.dart';
import '../widgets/markdown_text.dart';
import '../widgets/chat_composer.dart';
import '../widgets/out_of_credits.dart';
import 'preboarding_flow_screen.dart';

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
    this.voiceApiClient,
    this.voiceTransportFactory,
  });

  static const path = '/chat';

  final ApiClient? apiClient;
  final VoiceSessionController? voiceController;
  final TranscriptStore? transcriptStore;
  final ChatService? chatService;
  final ImagePicker? imagePicker;

  /// The screen the user was on when this chat was opened (the global
  /// floating Ayma launcher's page-context threading) — a snapshot of
  /// [AppContext.instance] taken at open time, not a live mirror. Folded
  /// into every `/chat` turn alongside [viewingProfileUid], which already
  /// covers the `screen == 'profile'` case in full; null everywhere else
  /// (the Ayma tab, the marketing route, the Story sheets) that already has
  /// its own, more specific context params.
  final ScreenContext? pageContext;

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
  /// `AskAymaContext`'s own doc for the forward-compat fields). Changes this
  /// screen in several ways, all gated on this being non-null: no server
  /// history is loaded (a fresh, ephemeral conversation every time, exactly
  /// like the old dedicated sheet); the header becomes the compact "Edit with
  /// Ayma" title + quoted-passage card instead of the full tab header; an
  /// empty transcript shows [quickSuggestionsFor]'s chips instead of "Say
  /// hello…"; [askAymaContext]'s fields ride along on every `/chat` turn
  /// alongside the message (see [_send]); voice is push-to-talk (tap the mic,
  /// speak, the finalized transcript is sent through the exact same [_send]
  /// text path, then the session tears down before any spoken reply —
  /// [_pttVoice]) rather than the full-duplex live call [_voice] otherwise
  /// gives you, because the LiveKit voice agent doesn't bind these
  /// correction tools; and this screen never touches [AppContext] or
  /// [ChatInbox] (a scoped correction turn has no business changing what the
  /// rest of the app thinks the current screen or kickoff is).
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

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final String _sessionId = newSessionId();
  late final ApiClient _api = widget.apiClient ?? ApiClient();
  late final TranscriptStore _store =
      widget.transcriptStore ?? TranscriptStore();
  late final ChatService _chat = widget.chatService ?? ChatService();
  late final ImagePicker _picker = widget.imagePicker ?? ImagePicker();
  late final VoiceSessionController _voice =
      widget.voiceController ??
      VoiceSessionController(transcriptStore: _store, sessionId: _sessionId);
  final _composerController = TextEditingController();
  final _composerFocus = FocusNode();
  late final ScrollController _scrollController =
      widget.scrollController ?? ScrollController();
  bool _canSend = false;
  bool _sending = false;

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
    _scrollController.addListener(_maybeLoadOlderHistory);
    if (widget.askAymaContext == null) {
      // So Ayma's `current_screen` tool can answer "what page am I on?"
      // during a voice call. The tab shell also sets this, but a standalone
      // ChatScreen (pre-signup marketing route, "Chat about it" photo sheet)
      // has no shell above it. Skipped for a scoped Ask-Ayma correction turn
      // — see [ChatScreen.askAymaContext]'s doc for why.
      AppContext.instance.set(screen: 'ayma');
      _loadHistory();
      ChatInbox.instance.pending.addListener(_consumeKickoff);
      WidgetsBinding.instance.addPostFrameCallback((_) => _consumeKickoff());
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
    }
  }

  /// A "draft about this" kickoff (e.g. "Ask Ayma" on a Web-research report):
  /// attach the report as an un-sent chip above an empty, focused composer.
  /// Nothing is added to the transcript and nothing is sent — [_send] posts the
  /// card the moment the user sends their own first message.
  void _startDraftAbout(ChatKickoff k) {
    if (k.targetUid.isNotEmpty) _viewingOverride = k.targetUid;
    setState(() {
      _pendingShared = _SharedDraft(
        kind: k.shareKind.isEmpty ? 'deep_dive' : k.shareKind,
        uid: k.targetUid,
        name: k.label.isNotEmpty ? k.label : 'them',
        photo: k.photoUrl,
        refId: k.refId,
      );
    });
    _composerFocus.requestFocus();
  }

  /// A `page_context` kickoff — the Ayma tab was just switched to from
  /// another tab (see `MainShellScreen._selectTab`). Updates the chip and
  /// what [_send] folds into `/chat`; never touches the transcript.
  void _applyPageContext(ChatKickoff k) {
    if (!mounted) return;
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

  /// A `/chat/stream` failure after the app was backgrounded mid-request
  /// (see [_backgroundedDuringSend]) may just mean the *client's* connection
  /// died — the server keeps processing and persisting the reply
  /// independent of whether the streaming response ever reaches back, so it
  /// can already be sitting in `/chat/history`. A few quick polls (same
  /// cursor-less "newest page" check [_awaitBackgroundReply] uses for a
  /// queued background skill, just a much shorter budget — this is "did it
  /// already finish", not "wait on a long job") turn that into a quiet
  /// recovery instead of a hard error the user has to notice and retry.
  /// [knownAyma] is the set of Ayma turns already in the transcript *before*
  /// this send started, so a genuinely fresh reply is never confused with
  /// one already shown. Returns true if a fresh reply was found and resolved
  /// (leaving the "Thinking…" turn already swapped for it).
  Future<bool> _recoverBackgroundedReply(Set<String> knownAyma) async {
    for (var i = 0; i < 3 && mounted; i++) {
      if (i > 0) {
        await Future<void>.delayed(const Duration(seconds: 2));
        if (!mounted) return true;
      }
      try {
        final page = await _api.chatHistory(limit: 4);
        final fresh = page.messages.lastWhere(
          (m) => m.role == 'ayma' && !knownAyma.contains(m.text),
          orElse: () => const ChatMessage(role: '', text: ''),
        );
        if (fresh.text.isNotEmpty) {
          if (!mounted) return true;
          _store.resolvePending(
            fresh.text,
            tools: fresh.tools,
            subjectImage: fresh.subjectImage.isEmpty
                ? null
                : fresh.subjectImage,
          );
          return true;
        }
      } catch (_) {
        /* the connection may still be settling — keep trying */
      }
    }
    return false;
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

      var page = await _api.chatHistory(limit: 40);
      var messages = page.messages;
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

      final turns = <TranscriptTurn>[];
      for (final m in messages) {
        String? url;
        if (m.imagePath.isNotEmpty) {
          try {
            url = await FirebaseStorage.instance
                .ref(m.imagePath)
                .getDownloadURL();
          } catch (_) {
            /* dropped image — render text only */
          }
        }
        turns.add(
          TranscriptTurn(
            role: m.role == 'ayma' ? TurnRole.ayma : TurnRole.user,
            text: m.text,
            source: TurnSource.text,
            imageUrl: url,
            tools: m.tools,
            subjectImage: m.subjectImage.isEmpty ? null : m.subjectImage,
            createdAt: m.createdAt,
          ),
        );
      }
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

      _store.seed(windowed);
      _seededCount = windowed.length;
      _historyError = null;
      if (target != null) {
        _scrollToTarget(anchor);
      } else {
        _pendingTargetScroll = false;
      }
    } catch (e) {
      // A load failure must not render the same as an empty history — record it
      // so the view can offer a retry (see `_historyError`).
      debugPrint('chat history load failed: $e');
      if (mounted) _historyError = "Couldn't load your conversation history.";
      _pendingTargetScroll = false;
    } finally {
      if (mounted) setState(() => _loadingHistory = false);
    }
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
        String? url;
        if (m.imagePath.isNotEmpty) {
          try {
            url = await FirebaseStorage.instance
                .ref(m.imagePath)
                .getDownloadURL();
          } catch (_) {
            /* dropped image — render text only */
          }
        }
        olderTurns.add(
          TranscriptTurn(
            role: m.role == 'ayma' ? TurnRole.ayma : TurnRole.user,
            text: m.text,
            source: TurnSource.text,
            imageUrl: url,
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
    });
    _loadHistory();
  }

  @override
  void dispose() {
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
      await _voice.start();
      if (!mounted) return;
      if (_voice.phase == VoiceSessionPhase.error &&
          _voice.errorMessage != null) {
        if (_voice.cappedError) {
          // Same reusable "out of credits" affordance as everywhere else
          // (chat's skills-triggered jobs, the profile screen) — a real
          // Reload action, not just a mention of the word in plain text.
          showOutOfCreditsSnack(context, message: _voice.errorMessage);
        } else {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(_voice.errorMessage!)));
        }
      }
    }
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
        showOutOfCreditsSnack(context, message: msg);
      } else {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(content: Text(msg)));
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
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            content: Text(
              "You're already on a voice call with Ayma — finish that "
              'first, then try again here.',
            ),
          ),
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
        : (_pttVoice!.agentSpeaking
              ? ComposerMode.aiSpeaking
              : ComposerMode.listening);
    String? voiceStatus;
    if (voiceActive) {
      voiceStatus = switch (_pttVoice!.phase) {
        VoiceSessionPhase.connecting => 'Connecting…',
        VoiceSessionPhase.waking => 'Waking Ayma…',
        _ =>
          _pttVoice.muted
              ? 'Muted'
              : (_pttVoice.agentSpeaking
                    ? 'Ayma is speaking…'
                    : (_pttVoice.activeToolLabel ?? 'Listening…')),
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
          canSend: !_sending && (_canSend || _pendingImage != null),
          onSend: _send,
          onAttach: _attachImage,
          onMicPressed: _onPttMicPressed,
          onStopPressed: _onPttVoiceStopPressed,
          onMuteTap: () => _pttVoice.toggleMute(),
          muted: _pttVoice!.muted,
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
      _bottomBaseline = target;
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't open that image.")),
        );
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

  Future<void> _send({String? retry, bool skipUserTurn = false}) async {
    // A draft attachment (an "Ask Ayma" report chip) is posted as a shared
    // card the moment the user sends their own first message, then the send
    // proceeds normally with that card as the tail user turn.
    if (retry == null && _pendingShared != null && !_sending) {
      final draftText = _composerController.text.trim();
      if (draftText.isEmpty) return;
      final ps = _pendingShared!;
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
    if ((message.isEmpty && image == null) || _sending) return;

    final window = _store.wireTurns();
    setState(() {
      _sending = true;
      if (retry == null) {
        _composerController.clear();
        _pendingImage = null;
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
      // the same text as `message`; drop it here so it isn't sent twice, but it
      // stays in the store for context on later turns.
      if (window.isNotEmpty &&
          window.last['role'] == 'user' &&
          window.last['text'] == message) {
        window.removeLast();
      }
    } else if (retry == null) {
      optimisticTurn = _store.addTurn(
        TurnRole.user,
        message,
        TurnSource.text,
        imageFile: image,
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't upload that image.")),
        );
      }
      return;
    }

    final wireMessage = message.isEmpty ? '(shared a photo)' : message;
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
      } on ApiException {
        if (!mounted) return;
        _store.dropPending();
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(
              content: const Text("Couldn't reach Ayma. Check your connection."),
              action: SnackBarAction(
                label: 'Retry',
                onPressed: () => _send(retry: message),
              ),
            ),
          );
      } catch (_) {
        if (!mounted) return;
        _store.dropPending();
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(
              content: const Text('Something went wrong sending that message.'),
              action: SnackBarAction(
                label: 'Retry',
                onPressed: () => _send(retry: message),
              ),
            ),
          );
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
    final matchReportId =
        (askAyma?.matchReportId.isNotEmpty ?? false)
            ? askAyma!.matchReportId
            : _matchReportId;
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
          profileEdit: _profileEdit,
          photoUrl: widget.photoUrl,
          photoSource: widget.photoSource,
          screen: _pageContext?.screen ?? '',
          screenSubjectUid: _pageContext?.subjectUid ?? '',
          screenSubjectName: _pageContext?.subjectName ?? '',
          screenNote: _pageContext?.note ?? '',
        )) {
          if (!mounted) return;
          if (ev is ChatStatus) {
            _store.updatePendingText(ev.label);
          } else if (ev is ChatReplyEvent) {
            result = ev.result;
          }
        }
      } on ApiException {
        // Stream unavailable (proxy, old build) — fall back to the plain call.
        result = await _api.chat(
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
          profileEdit: _profileEdit,
          photoUrl: widget.photoUrl,
          photoSource: widget.photoSource,
          screen: _pageContext?.screen ?? '',
          screenSubjectUid: _pageContext?.subjectUid ?? '',
          screenSubjectName: _pageContext?.subjectName ?? '',
          screenNote: _pageContext?.note ?? '',
        );
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
      );
      if (!result.usageCapped) {
        // Let the caller (an Ask-Ayma correction origin) catch up in place
        // — while the screen is still open, not just once it closes. A
        // no-op for every other caller, which never sets this.
        widget.onExchange?.call();
      }
      if (result.imageRejected) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('That image was blocked by our check.')),
        );
      }
      if (result.fallbackForm) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Let’s finish the basics on a quick form.'),
            action: SnackBarAction(
              label: 'Open',
              onPressed: () => context.go('/settings/profile'),
            ),
          ),
        );
      }
    } on ApiException {
      // Transient failure — don't leave a stuck "thinking" turn, unless the
      // app was backgrounded mid-request and the reply is actually sitting
      // in history already (see [_recoverBackgroundedReply]).
      if (!mounted) return;
      if (_backgroundedDuringSend &&
          await _recoverBackgroundedReply(knownAymaBeforeSend)) {
        return;
      }
      if (!mounted) return;
      _store.dropPending();
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: const Text("Couldn't reach Ayma. Check your connection."),
            action: SnackBarAction(
              label: 'Retry',
              onPressed: () => _send(retry: message),
            ),
          ),
        );
    } catch (_) {
      if (!mounted) return;
      if (_backgroundedDuringSend &&
          await _recoverBackgroundedReply(knownAymaBeforeSend)) {
        return;
      }
      if (!mounted) return;
      _store.dropPending();
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: const Text('Something went wrong sending that message.'),
            action: SnackBarAction(
              label: 'Retry',
              onPressed: () => _send(retry: message),
            ),
          ),
        );
    } finally {
      if (mounted) {
        setState(() => _sending = false);
        _composerFocus.requestFocus();
      }
    }
  }

  late final ProfileService _profiles =
      widget.profileService ?? ProfileService();

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
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            if (askAyma != null)
              _AskAymaHeader(ctx: askAyma)
            else if (!photo)
              AymaScreenHeader(
                title: 'Ayma',
                titleSize: 34,
                padding: const EdgeInsets.fromLTRB(20, 24, 12, 12),
                action: widget.marketing
                    ? TextButton(
                        onPressed: _getStarted,
                        child: const Text('Get started'),
                      )
                    : null,
              ),
            // Live call state (Listening / Muted / Connecting…) lives only in
            // the composer bar now — no second copy under the header. The one
            // thing the composer can't show is a hard error (it falls back to
            // the plain text composer), so that still surfaces here. Skipped
            // in Ask-Ayma mode: that mode's push-to-talk errors surface via a
            // SnackBar instead (see [_onPttVoiceChanged]), and this binding
            // would otherwise construct the unused full-duplex [_voice] from
            // scratch just to read `.phase` off it.
            if (askAyma == null)
              ListenableBuilder(
                listenable: _voice,
                builder: (context, _) {
                  if (_voice.phase != VoiceSessionPhase.error) {
                    return const SizedBox(height: 4);
                  }
                  if (_voice.cappedError) {
                    // Same reusable "out of credits" card chat/skills use,
                    // instead of a shouted all-caps error line for this one
                    // specifically-actionable case.
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(20, 2, 20, 10),
                      child: OutOfCreditsBanner(message: _voice.errorMessage),
                    );
                  }
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(20, 2, 20, 6),
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 5,
                              height: 5,
                              margin: const EdgeInsets.only(right: 8, top: 3),
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
                              onTap: () => CallPermissions().openSettings(),
                              child: Text(
                                'OPEN SETTINGS',
                                style:
                                    AymaType.mono(
                                      size: 9,
                                      color: AymaColors.error,
                                    ).copyWith(
                                      letterSpacing: 1.8,
                                      decoration: TextDecoration.underline,
                                    ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            Expanded(
              child: ListenableBuilder(
                listenable: _store,
                builder: (context, _) {
                  final turns = _store.turns;
                  if (turns.isEmpty) {
                    if (askAyma != null) {
                      // Ask-Ayma mode never loads history (see that field's
                      // doc) — an empty transcript always means "hasn't sent
                      // anything yet", so the quick-suggestion chips (the
                      // same affordance the old dedicated sheet had) show
                      // immediately instead of "Say hello…".
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
                    if (_loadingHistory) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (_historyError != null) {
                      return Center(
                        child: Padding(
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
                        ),
                      );
                    }
                    return Center(
                      child: Padding(
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
                      ),
                    );
                  }
                  final loaderRow = _loadingOlder ? 1 : 0;
                  return NotificationListener<ScrollMetricsNotification>(
                    onNotification: _handleListMetrics,
                    child: NotificationListener<ScrollNotification>(
                      onNotification: _handleListScrollNotification,
                      child: ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                        itemCount: turns.length + 1 + loaderRow,
                        itemBuilder: (context, i) {
                          if (loaderRow == 1 && i == 0) {
                            return const Padding(
                              padding: EdgeInsets.symmetric(vertical: 12),
                              child: Center(
                                child: SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              ),
                            );
                          }
                          if (i == loaderRow) {
                            return const DividerLabel("Your conversation");
                          }
                          final idx = i - 1 - loaderRow;
                          final t = turns[idx];
                          final line = _TranscriptLine(
                            key: _turnKeys.putIfAbsent(t, () => GlobalKey()),
                            turn: t,
                            latest: idx == turns.length - 1,
                            api: _api,
                            onThumbsDown:
                                (t.role == TurnRole.ayma &&
                                    t.isFinal &&
                                    t.text.isNotEmpty)
                                ? () => _api.submitFeedback(
                                    category: 'thumbs_down',
                                    quote: t.text,
                                    sessionId: _sessionId,
                                  )
                                : null,
                          );
                          // A one-time landing spot from a "Why Ayma believes
                          // this" source tap — same soft tint the tool-use
                          // kicker chip above an Ayma line already uses.
                          if (!identical(t, _highlightedTurn)) return line;
                          return AnimatedContainer(
                            duration: const Duration(milliseconds: 300),
                            margin: const EdgeInsets.symmetric(vertical: 2),
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            decoration: BoxDecoration(
                              color: ac.accentFaint,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: line,
                          );
                        },
                      ),
                    ),
                  );
                },
              ),
            ),
            if (photo && askAyma == null)
              _PhotoChatContext(url: widget.photoUrl),
            // Live status ("Searching the web…") rides on the pending Ayma
            // turn now, so there's no separate "thinking" line here.
            if (askAyma != null)
              _buildAskAymaComposer(context)
            else
              ListenableBuilder(
                listenable: _voice,
                builder: (context, _) => _Composer(
                  controller: _composerController,
                  focusNode: _composerFocus,
                  canSend: (_canSend || _pendingImage != null) && !_sending,
                  onSend: _send,
                  onAttach: _attachImage,
                  pendingImage: _pendingImage,
                  onClearImage: () => setState(() => _pendingImage = null),
                  pendingShared: _pendingShared,
                  onClearShared: () => setState(() => _pendingShared = null),
                  pageContextLabel:
                      (_pageContext != null &&
                          _pageContext!.screen.isNotEmpty)
                      ? _pageContext!.label
                      : null,
                  onClearPageContext: _clearPageContext,
                  voicePhase: _voice.phase,
                  muted: _voice.muted,
                  agentSpeaking: _voice.agentSpeaking,
                  activeToolLabel: _voice.activeToolLabel,
                  onVoiceTap: _toggleVoice,
                  onMuteTap: _voice.toggleMute,
                  micLevel: _voice.micLevel,
                  aymaLevel: _voice.aymaLevel,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

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
class _AskAymaHeader extends StatelessWidget {
  const _AskAymaHeader({required this.ctx});
  final AskAymaContext ctx;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final quoteText = ctx.quoteText;
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
                  style: AymaType.serif(size: 19, color: ac.fg),
                ),
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
          Text(
            '"$text"',
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: AymaType.serif(
              size: 14,
              italic: true,
              color: ac.fg,
            ).copyWith(height: 1.4),
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
  r'\s*\[(appearance|face_report|body_report|deep_dive|physical):'
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
    this.onThumbsDown,
  });

  final TranscriptTurn turn;
  final bool latest;

  /// Used to fetch a stored report when the turn carries a `[*_report:id]`
  /// marker. Null in tests that don't exercise that path.
  final ApiClient? api;

  /// Non-null only for a finished Ayma line — fire-and-forget feedback.
  final Future<void> Function()? onThumbsDown;

  @override
  State<_TranscriptLine> createState() => _TranscriptLineState();
}

class _TranscriptLineState extends State<_TranscriptLine> {
  bool _flagged = false;

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
    return ClipRRect(
      borderRadius: BorderRadius.circular(rounded ? 14 : 12),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.62,
        ),
        child: image,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final turn = widget.turn;
    final isAyma = turn.role == TurnRole.ayma;
    final hasImage = turn.imageUrl != null || turn.imageFile != null;
    final width = MediaQuery.of(context).size.width;

    if (!isAyma) {
      // You — a right-aligned rounded bubble (Gemini style).
      return Padding(
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
                    padding: EdgeInsets.only(bottom: turn.text.isEmpty ? 0 : 6),
                    child: _SharedRefCard(turn: turn),
                  ),
                if (hasImage)
                  Padding(
                    padding: EdgeInsets.only(bottom: turn.text.isEmpty ? 0 : 6),
                    child: _photo(context, rounded: true),
                  ),
                if (turn.text.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: ac.accentFaint,
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(16),
                        topRight: Radius.circular(16),
                        bottomLeft: Radius.circular(16),
                        bottomRight: Radius.circular(4),
                      ),
                    ),
                    child: Text(
                      turn.text,
                      style: AymaType.sans(size: 15, color: ac.fg, height: 1.4),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    }

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

    return Opacity(
      opacity: widget.latest || !turn.isFinal ? 1 : 0.62,
      child: Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (turn.tools.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 5,
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
                        const SizedBox(width: 6),
                      ] else ...[
                        Icon(Icons.auto_awesome, size: 13, color: ac.accent),
                        const SizedBox(width: 6),
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
            if (!turn.isFinal)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // A 16px/1.5-line-height first line is ~24px tall; nudge
                  // the smaller 14px orb down so it sits centered against
                  // that first line instead of pinned to the row's top.
                  const Padding(
                    padding: EdgeInsets.only(top: 5),
                    child: AymaOrb(size: 14, state: AymaOrbState.thinking),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      turn.text,
                      style: AymaType.serif(
                        size: 16,
                        color: ac.fgDim,
                      ).copyWith(height: 1.5),
                    ),
                  ),
                ],
              )
            else if (displayText.isNotEmpty)
              MarkdownText(
                displayText,
                style: AymaType.serif(
                  size: 16,
                  color: ac.fg,
                ).copyWith(height: 1.55),
                linkColor: ac.accent,
              ),
            if (turn.capped)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.tonalIcon(
                    onPressed: () => openCredits(context),
                    icon: const Icon(Icons.bolt, size: 18),
                    label: const Text('Reload credits'),
                  ),
                ),
              ),
            if (reportKind != null && reportId != null && reportId.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: _InlineReportCard(
                  kind: reportKind,
                  reportId: reportId,
                  subjectImage: turn.subjectImage ?? '',
                  api: widget.api,
                ),
              ),
            if (widget.onThumbsDown != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: InkWell(
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
                          const SizedBox(width: 6),
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
              ),
          ],
        ),
      ),
    );
  }
}

/// An un-sent "share this into the chat" attachment held above the composer
/// (an "Ask Ayma" report chip). Posted as a shared card turn on the next send.
class _SharedDraft {
  const _SharedDraft({
    required this.kind,
    required this.uid,
    required this.name,
    required this.photo,
    required this.refId,
  });

  final String kind;
  final String uid;
  final String name;
  final String photo;
  final String refId;
}

/// The card shown for a user turn that shared a person / conversation / match
/// report into the chat. Tapping opens the underlying screen.
class _SharedRefCard extends StatelessWidget {
  const _SharedRefCard({required this.turn});

  final TranscriptTurn turn;

  ({String label, IconData icon, String route}) get _meta => switch (turn
      .sharedKind) {
    'conversation' => (
      label: 'Your chat with ${turn.sharedName}',
      icon: Icons.forum_outlined,
      route: turn.sharedRefId.isEmpty ? '' : '/dm/${turn.sharedRefId}',
    ),
    'deep_dive' => (
      label: 'Web research on ${turn.sharedName}',
      icon: Icons.travel_explore,
      route: turn.sharedRefId.isEmpty ? '' : '/deep-dive/${turn.sharedRefId}',
    ),
    'match' => (
      label: '${turn.sharedName} · match report',
      icon: Icons.insights_rounded,
      route: turn.sharedRefId.isEmpty ? '' : '/match/${turn.sharedRefId}',
    ),
    _ => (
      label: turn.sharedName,
      icon: Icons.person_outline,
      route: turn.sharedUid.isEmpty ? '' : '/profile/user/${turn.sharedUid}',
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
        width: 240,
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
                child: turn.sharedPhoto.isNotEmpty
                    ? AymaPhoto(
                        url: turn.sharedPhoto,
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
                    m.route.isEmpty ? 'SHARED WITH AYMA' : 'TAP TO OPEN',
                    style: AymaType.mono(
                      size: 8,
                      color: ac.fgMute,
                    ).copyWith(letterSpacing: 1.4),
                  ),
                ],
              ),
            ),
          ],
        ),
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

  final String kind; // 'face' | 'body' | 'deep_dive' | 'physical'
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
  late final Future<Object>? _future = (_isDive || _isPhysical || _isAppearance)
      ? null
      : (_isFace
            ? fetchStoredFaceReport(widget.reportId, api: widget.api)
            : fetchStoredBodyReport(widget.reportId, api: widget.api));

  void _openFull() {
    if (_isDive) {
      context.push('/deep-dive/${Uri.encodeComponent(widget.reportId)}');
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
            const SizedBox(width: 10),
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
            child: AymaOrb(size: 16, state: AymaOrbState.thinking),
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
    required this.controller,
    required this.focusNode,
    required this.canSend,
    required this.onSend,
    required this.onAttach,
    required this.pendingImage,
    required this.onClearImage,
    required this.pendingShared,
    required this.onClearShared,
    this.pageContextLabel,
    required this.onClearPageContext,
    required this.voicePhase,
    required this.muted,
    required this.agentSpeaking,
    this.activeToolLabel,
    required this.onVoiceTap,
    required this.onMuteTap,
    required this.micLevel,
    required this.aymaLevel,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool canSend;
  final VoidCallback onSend;
  final VoidCallback onAttach;
  final File? pendingImage;
  final VoidCallback onClearImage;
  final _SharedDraft? pendingShared;
  final VoidCallback onClearShared;

  /// The "you were looking at…" chip label (see [ChatScreen.pageContext] /
  /// `_ChatScreenState._pageContext`) — null hides the chip entirely.
  final String? pageContextLabel;
  final VoidCallback onClearPageContext;
  final VoiceSessionPhase voicePhase;
  final bool muted;
  final bool agentSpeaking;

  /// The live, present-progressive label of whichever tool Ayma is running
  /// right now ("Researching them online…"), or null when none is — a
  /// transient "what she's doing" indicator for a slow tool call mid-turn
  /// (§1.7 step 3), shown in place of "Listening" while it's non-null.
  final String? activeToolLabel;
  final Future<void> Function() onVoiceTap;
  final Future<void> Function() onMuteTap;

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
        : (agentSpeaking ? ComposerMode.aiSpeaking : ComposerMode.listening);

    String? statusLabel;
    if (voiceActive) {
      statusLabel = switch (voicePhase) {
        VoiceSessionPhase.connecting => 'Connecting…',
        VoiceSessionPhase.waking => 'Waking Ayma…',
        _ =>
          muted
              ? 'Muted'
              : (agentSpeaking
                    ? 'Ayma is speaking…'
                    : (activeToolLabel ?? 'Listening…')),
      };
    }

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (pageContextLabel != null)
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
                        Icon(Icons.push_pin_outlined,
                            size: 16, color: ac.accent),
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
                        Icon(Icons.travel_explore, size: 16, color: ac.accent),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            'Web research on ${pendingShared!.name}',
                            overflow: TextOverflow.ellipsis,
                            style: AymaType.sans(size: 12.5, color: ac.fgDim),
                          ),
                        ),
                        IconButton(
                          onPressed: onClearShared,
                          iconSize: 16,
                          icon: const Icon(Icons.close),
                          color: ac.fgMute,
                          visualDensity: VisualDensity.compact,
                          tooltip: 'Remove attachment',
                        ),
                      ],
                    ),
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
            ChatComposer(
              mode: mode,
              controller: controller,
              focusNode: focusNode,
              canSend: canSend,
              onSend: onSend,
              onAttach: onAttach,
              onMicPressed: () => onVoiceTap(),
              onStopPressed: () => onVoiceTap(),
              onMuteTap: () => onMuteTap(),
              muted: muted,
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
