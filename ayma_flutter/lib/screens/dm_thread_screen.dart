import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/api_client.dart';
import '../services/app_context.dart';
import '../services/async_voice_player.dart';
import '../services/async_voice_recorder.dart';
import '../services/dm_voice_engine.dart';
import '../services/voice_note_controller.dart';
import '../services/chat_inbox.dart';
import '../services/dm_service.dart';
import '../services/fresh_data.dart';
import '../theme.dart';
import '../widgets/ayma_orb.dart';
import '../widgets/ayma_photo.dart';
import '../widgets/ayma_toast.dart';
import '../widgets/ayma_wing_loader.dart';
import '../widgets/overflow_guards.dart';
import '../widgets/chat_bubble.dart';
import '../widgets/chat_composer.dart'
    show kChatListBottomInset, kComposerBarPadding;
import '../widgets/freshness_indicator.dart';
import '../widgets/image_viewer.dart';
import '../widgets/keyboard_dismiss.dart';
import '../widgets/message_timestamp.dart';
import '../widgets/shared_report_card.dart';
import '../widgets/staggered.dart';
import '../widgets/voice_clip_row.dart';
import '../widgets/voice_note_composer.dart';
import 'main_shell_screen.dart';
import '../widgets/ayma_back_button.dart';
import '../services/screen_capture.dart';
import '../utils/dm_language.dart';

/// How many of the newest DM messages Ayma's screen context may include.
const int _kContextMessages = 3;

/// One DM conversation (§6.6, §6.11 step 9). Text send is wired; photo/voice
/// use the same message pipeline once a file is uploaded (Step 51 ingests them).
/// Image / file attachments upload to `uploads/{uid}/dm/{threadId}/…` and send
/// as `image` / `file` messages carrying the download URL + metadata.
///
/// "Ayma in your DMs" coaching (§6.9) lives above the composer: up-to-2
/// suggestion chips (tap → drop into the composer) plus an optional one-line
/// tip. Both come from `POST /dm/assist` and refresh (debounced) as the
/// conversation grows, so they stay relevant instead of being one-shot
/// openers. Any load failure degrades silently — never blocks typing/sending.
class DmThreadScreen extends StatefulWidget {
  const DmThreadScreen({
    super.key,
    required this.threadId,
    this.title = 'Conversation',
    this.dmService,
    this.apiClient,
    this.picker,
    this.voiceNoteRecorder,
    this.voicePlayer,
  });

  static const path = '/dm';

  final String threadId;
  final String title;
  final DmService? dmService;
  final ApiClient? apiClient;
  final ImagePicker? picker;

  /// Test seams for the voice-note composer: a fake recorder / player.
  /// Null builds the real ones.
  final AsyncVoiceRecorder? voiceNoteRecorder;
  final AsyncVoicePlayer? voicePlayer;

  @override
  State<DmThreadScreen> createState() => _DmThreadScreenState();
}

class _DmThreadScreenState extends State<DmThreadScreen>
    with ScreenContextReasserter<DmThreadScreen> {
  late final DmService _dm = widget.dmService ?? DmService();
  late final ApiClient _api = widget.apiClient ?? ApiClient();
  late final ImagePicker _picker = widget.picker ?? ImagePicker();
  final _composer = TextEditingController();
  final _composerFocus = FocusNode();
  bool _sending = false;

  /// Voice notes (WhatsApp model, founder 2026-11-06): the engine records
  /// and hands finished clips to [_sendVoiceClip]; the gesture controller
  /// drives the composer mic / recording bar.
  late final DmVoiceNoteEngine _voiceEngine = DmVoiceNoteEngine(
    recorder: widget.voiceNoteRecorder,
    onSendClip: _sendVoiceClip,
  );
  late final VoiceNoteController _voiceNote = VoiceNoteController(
    engine: _voiceEngine,
  );
  late final AsyncVoicePlayer _clipPlayer =
      widget.voicePlayer ?? JustAudioVoicePlayer();

  /// Which DM voice clip is playing (VoiceClipRow keys) - one at a time.
  final ValueNotifier<String?> _nowPlaying = ValueNotifier<String?>(null);

  /// Voice notes I just sent, shown immediately as playable bubbles from
  /// their local files while the upload + post lands; each is hidden once
  /// the stream echoes a voice message of mine at/after its send time.
  final List<DmMessage> _localVoice = [];
  final Map<String, String> _localVoiceFiles = {};

  /// Transcript window (Phase 2 pagination design §3.3): the live tail
  /// (newest 30) streams in; [_olderMessages] holds paged history
  /// (oldest-first), prepended without disturbing the reversed list.
  final _listController = ScrollController();
  final List<DmMessage> _olderMessages = [];
  bool _fetchingOlder = false;
  bool _olderDone = false;

  /// Oldest merged message id (history anchor) and whether the live tail
  /// filled its page, sampled each build for the scroll-up trigger.
  String? _oldestId;
  bool _tailFull = false;

  static const _historyPageSize = 30;

  /// A picked-but-not-yet-sent attachment.
  File? _pending;
  String _pendingType = 'file'; // 'image' | 'file'

  /// Live DM coaching (chips + tip), refreshed from `POST /dm/assist` as the
  /// conversation grows. Starts empty so nothing shows until the first fetch.
  DmAssist _assist = DmAssist.empty;

  /// The exact tip text the user last dismissed. A newly-fetched, different
  /// tip re-surfaces (auto-updates); the same one stays hidden.
  String? _dismissedTip;

  /// The exact safety-note text the user last dismissed. A later refresh
  /// carrying a *different* heads-up re-surfaces it; the same one stays hidden.
  String? _dismissedSafety;

  /// Debounce for the assist refetch, and the message signature that last
  /// triggered one — so we refetch only on an actual new sent/received
  /// message, not on every stream rebuild or keystroke.
  Timer? _assistDebounce;
  String? _lastAssistSig;

  /// The first assist load (thread open) fires immediately; later refreshes
  /// are debounced so a burst of messages collapses into one call.
  bool _assistLoadedOnce = false;

  /// The other person — name + photo + presence, so the header reads like a
  /// real conversation instead of "Conversation".
  MiniProfile? _other;

  /// Cross-language DM translation (§6.12). [_preferredLang] is the language
  /// incoming messages are translated INTO — the user's saved voice-engine
  /// language if they have one, else the device locale. [_otherLang] is the
  /// match's language, learned from the detected source of a message we've
  /// translated; it's the target for an outgoing "translate before sending".
  /// [_autoTranslate] auto-translates incoming messages for this thread;
  /// [_translateOutgoing] is the opt-in "send in their language" control.
  String _preferredLang = '';
  String _otherLang = '';
  bool _autoTranslate = false;
  bool _translateOutgoing = false;

  @override
  void initState() {
    super.initState();
    _listController.addListener(_onListScroll);
    _composer.addListener(_onComposerTextChanged);
    _voiceEngine.addListener(_onVoiceEngineChanged);
    reassertScreenContext();
    _loadOther();
    _preferredLang = _deviceLanguage();
    _loadPreferredLang();
    _dm.markThreadRead(widget.threadId);
  }

  /// The device's language tag ("en-US"), the fallback target for incoming
  /// translation when the user has set no preferred language.
  String _deviceLanguage() {
    try {
      return WidgetsBinding.instance.platformDispatcher.locale.toLanguageTag();
    } catch (_) {
      return 'en';
    }
  }

  /// Best-effort: prefer the user's saved voice-engine language over the device
  /// locale as the translation target (the voice switcher is where they pick a
  /// language). Never blocks the thread — any failure keeps the device locale.
  Future<void> _loadPreferredLang() async {
    try {
      final cat = await _api.voiceEngines();
      final code = cat.current.languageCode.trim();
      if (code.isNotEmpty && mounted) setState(() => _preferredLang = code);
    } catch (_) {
      // Keep the device-locale default — translation is a nicety, never blocks.
    }
  }

  /// Remember the match's language the first time we detect it from a message
  /// we translated, so "translate before sending" knows the outgoing target.
  void _onOtherLangDetected(String lang) {
    final l = lang.trim();
    if (l.isEmpty || l == _otherLang) return;
    setState(() => _otherLang = l);
  }

  /// Tail + paged history merged oldest-first, deduplicated by id (live
  /// wins — design §6.2). Unstamped local writes sort as newest.
  List<DmMessage> _mergeTail(List<DmMessage> tail) {
    if (_olderMessages.isEmpty) return tail;
    final byId = <String, DmMessage>{
      for (final m in _olderMessages) m.id: m,
      for (final m in tail) m.id: m,
    };
    return byId.values.toList()
      ..sort((a, b) {
        final ta = a.createdAt;
        final tb = b.createdAt;
        if (ta == null && tb == null) return a.id.compareTo(b.id);
        if (ta == null) return 1;
        if (tb == null) return -1;
        final c = ta.compareTo(tb);
        return c != 0 ? c : a.id.compareTo(b.id);
      });
  }

  /// History paging trigger (design §3.3.2/§4.1): within 500px of the top
  /// of the reversed transcript, fetch the next older page.
  void _onListScroll() {
    if (!_listController.hasClients || _fetchingOlder || _olderDone) return;
    // A tail that never filled its page means no history exists (yet).
    if (!_tailFull && _olderMessages.isEmpty) return;
    final pos = _listController.position;
    if (pos.pixels < pos.maxScrollExtent - 500) return;
    final anchor = _oldestId;
    if (anchor == null) return;
    _loadOlder(anchor);
  }

  Future<void> _loadOlder(String lastMessageId) async {
    setState(() => _fetchingOlder = true);
    try {
      final page = await _dm.fetchOlderMessages(
        widget.threadId,
        lastMessageId: lastMessageId,
        limit: _historyPageSize,
      );
      if (!mounted) return;
      final known = {for (final m in _olderMessages) m.id};
      final fresh = page.where((m) => known.add(m.id)).toList();
      setState(() {
        _olderMessages.insertAll(0, fresh);
        _fetchingOlder = false;
        if (page.length < _historyPageSize) _olderDone = true;
      });
    } catch (_) {
      // History is best-effort: the live tail stays fully usable, and the
      // next scroll to the top retries.
      if (!mounted) return;
      setState(() => _fetchingOlder = false);
    }
  }

  /// Id of the newest incoming message already marked read, so a rebuild
  /// doesn't re-write for the same message.
  String? _markedReadFor;

  void _markReadIfIncoming(List<DmMessage> msgs) {
    if (msgs.isEmpty) return;
    final last = msgs.last;
    if (last.senderUid == _dm.uid || last.id == _markedReadFor) return;
    _markedReadFor = last.id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _dm.markThreadRead(widget.threadId);
    });
  }

  @override
  void reassertScreenContext() {
    final name = _other?.name.isNotEmpty ?? false
        ? _other!.name
        : (widget.title == 'Conversation' ? '' : widget.title);
    AppContext.instance.set(
      screen: 'dm',
      subjectUid: _safeOtherUid(),
      subjectName: name,
    );
  }

  Future<void> _loadOther() async {
    final uid = _safeOtherUid();
    if (uid.isEmpty) return;
    try {
      final m = await _api.miniProfiles([uid]);
      if (!mounted) return;
      final mini = m[uid];
      if (mini == null) return;
      setState(() => _other = mini);
      if (mini.name.isNotEmpty) reassertScreenContext();
    } catch (_) {
      // Header falls back to widget.title — never block the thread on this.
    }
  }

  String get _headerName => (_other?.name.isNotEmpty ?? false)
      ? _other!.name
      : (widget.title == 'Conversation' ? 'Conversation' : widget.title);

  String _safeOtherUid() {
    try {
      return _dm.otherUidOf(widget.threadId);
    } catch (_) {
      return '';
    }
  }

  @override
  void dispose() {
    _assistDebounce?.cancel();
    _listController
      ..removeListener(_onListScroll)
      ..dispose();
    _composer.removeListener(_onComposerTextChanged);
    _voiceEngine.removeListener(_onVoiceEngineChanged);
    _voiceNote.dispose();
    _voiceEngine.dispose();
    _nowPlaying.dispose();
    _composer.dispose();
    _composerFocus.dispose();
    super.dispose();
  }

  /// Schedule an assist refetch for [msgs] if (and only if) the thread tail
  /// actually changed since the last fetch — a new message sent or received,
  /// not a mere rebuild. The first load (thread open) fires immediately; later
  /// ones debounce ~1.5s so a burst collapses into a single call. Called from
  /// the message [StreamBuilder]; scheduling a timer during build is safe (the
  /// state change happens later, in [_fetchAssist]).
  void _scheduleAssist(List<DmMessage> msgs) {
    final sig = '${msgs.length}:${msgs.isNotEmpty ? msgs.last.id : ''}';
    if (sig == _lastAssistSig) return;
    _lastAssistSig = sig;
    final immediate = !_assistLoadedOnce;
    _assistLoadedOnce = true;
    _assistDebounce?.cancel();
    final snapshot = List<DmMessage>.unmodifiable(msgs);
    _assistDebounce = Timer(
      immediate ? Duration.zero : const Duration(milliseconds: 1500),
      () => _fetchAssist(snapshot),
    );
  }

  Future<void> _fetchAssist(List<DmMessage> msgs) async {
    try {
      final a = await _dm.assist(widget.threadId, msgs);
      if (mounted) setState(() => _assist = a);
    } catch (_) {
      // Coaching is a nicety — degrade silently, never block typing/sending.
    }
  }

  /// Quietly dismiss the current tip. It stays hidden until a *different* tip
  /// arrives from a later refresh (then it auto-updates back into view).
  void _dismissTip() => setState(() => _dismissedTip = _assist.tip);

  /// The tip to show right now, or null: the live tip unless the user dismissed
  /// that exact text.
  String? get _visibleTip =>
      (_assist.tip != null && _assist.tip != _dismissedTip)
          ? _assist.tip
          : null;

  /// Quietly dismiss the current safety note. It stays hidden until a
  /// *different* heads-up arrives from a later refresh.
  void _dismissSafety() =>
      setState(() => _dismissedSafety = _assist.safety.reason);

  /// The protective safety note to show right now, or null: the live note when
  /// it's a genuine concern (>= caution) and the user hasn't dismissed that
  /// exact text. Advisory only — it never affects sending.
  DmSafety? get _visibleSafety =>
      (_assist.safety.shouldSurface &&
              _assist.safety.reason != _dismissedSafety)
          ? _assist.safety
          : null;

  /// Composer text changed - the mic/send slot swap follows it.
  void _onComposerTextChanged() {
    if (mounted) setState(() {});
  }

  /// Surface a voice-note recording failure once, as a toast.
  void _onVoiceEngineChanged() {
    final error = _voiceEngine.takeError();
    if (error != null && mounted) {
      AymaToast.show(context, error, kind: AymaToastKind.error);
    }
  }

  /// A finished voice-note clip from the composer: show it immediately as
  /// a playable bubble from the local file, then upload + post it in the
  /// background. The stream echo replaces the local bubble (see
  /// [_visibleLocalVoice]); a failed upload keeps the local bubble and
  /// says so - the clip itself is never silently dropped.
  Future<void> _sendVoiceClip(File file) async {
    final id = 'local-voice-${DateTime.now().microsecondsSinceEpoch}';
    final local = DmMessage(
      id: id,
      senderUid: _dm.uid,
      type: 'voice',
      body: '',
      createdAt: DateTime.now(),
    );
    if (mounted) {
      setState(() {
        _localVoice.add(local);
        _localVoiceFiles[id] = file.path;
      });
    } else {
      _localVoice.add(local);
      _localVoiceFiles[id] = file.path;
    }
    try {
      final att = await _dm.uploadVoiceClip(file, threadId: widget.threadId);
      await _dm.sendVoice(widget.threadId, att.storagePath);
    } catch (e) {
      if (mounted) {
        AymaToast.show(
          context,
          "Voice message couldn't send ($e).",
          kind: AymaToastKind.error,
        );
      }
    }
  }

  /// Local voice bubbles not yet echoed by the stream: a stream voice
  /// message from me created at/after a local's send time replaces it.
  List<DmMessage> _visibleLocalVoice(List<DmMessage> streamed) {
    if (_localVoice.isEmpty) return const [];
    final echoedAt = <DateTime>[
      for (final m in streamed)
        if (m.type == 'voice' && m.senderUid == _dm.uid && m.createdAt != null)
          m.createdAt!,
    ];
    return [
      for (final local in _localVoice)
        if (!echoedAt.any(
          (t) => !t.isBefore(
            local.createdAt!.subtract(const Duration(seconds: 2)),
          ),
        ))
          local,
    ];
  }

  Future<void> _send() async {
    final text = _composer.text.trim();
    final pending = _pending;
    if (_sending) return;
    if (pending == null && text.isEmpty) return;

    // Opt-in outgoing translation (§6.12), plain text only: translate the draft
    // into the match's language and show exactly what will be sent before it
    // goes — never silently alter the user's words.
    String outgoing = text;
    if (_translateOutgoing && pending == null && text.isNotEmpty) {
      final confirmed = await _confirmOutgoingTranslation(text);
      if (confirmed == null) return; // cancelled / unavailable — keep the draft
      outgoing = confirmed;
    }

    setState(() => _sending = true);
    try {
      if (pending != null) {
        final att = await _dm.uploadAttachment(
          pending,
          threadId: widget.threadId,
        );
        await _dm.sendAttachment(
          widget.threadId,
          type: _pendingType,
          attachment: att,
          caption: text,
        );
      } else {
        await _dm.sendText(widget.threadId, outgoing);
      }
      _composer.clear();
      if (mounted) setState(() => _pending = null);
      // Keep the conversation-starters around — they're common ground to talk
      // about, not one-shot openers.
    } catch (e) {
      if (mounted) {
        // The composer keeps the text (and any picked attachment), so Retry
        // resends exactly the original input.
        AymaToast.show(context, 'Not sent ($e).',
            kind: AymaToastKind.error,
            action: AymaToastAction(label: 'Retry', onPressed: _send));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// For opt-in outgoing translation: returns the text to actually send — the
  /// translation (after the user confirms the preview), or the original when
  /// it's already in the match's language — or null to abort (the user
  /// cancelled, we don't know the match's language yet, or translation failed).
  Future<String?> _confirmOutgoingTranslation(String text) async {
    if (_otherLang.isEmpty) {
      AymaToast.show(
        context,
        'Translate one of their messages first so Ayma knows their language.',
      );
      return null;
    }
    DmTranslation tr;
    try {
      tr = await _dm.translate(widget.threadId, text, _otherLang);
    } catch (_) {
      if (mounted) {
        AymaToast.show(
          context,
          "Couldn't translate — your message wasn't sent.",
          kind: AymaToastKind.error,
        );
      }
      return null;
    }
    if (!mounted) return null;
    final translated = tr.translated.trim();
    if (translated.isEmpty || translated == text) {
      // Already in their language (or nothing to change): send as typed.
      return text;
    }
    final ok = await _showOutgoingPreview(original: text, translated: translated);
    return ok == true ? translated : null;
  }

  /// A confirm sheet showing exactly what will be sent (the translation) with
  /// the user's original kept visible, so an outgoing translation is never a
  /// silent change to their words. Returns true to send the translation.
  Future<bool?> _showOutgoingPreview({
    required String original,
    required String translated,
  }) {
    final ac = context.ac;
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Send in their language?',
                style: AymaType.sans(size: 15, weight: FontWeight.w600, color: ac.fg),
              ),
              const SizedBox(height: 10),
              Text(
                "You'll send",
                style: AymaType.sans(size: 12, soft: true, color: ac.fgMute),
              ),
              const SizedBox(height: 4),
              Text(translated, style: AymaType.message(color: ac.fg)),
              const SizedBox(height: 10),
              Text(
                'Your original',
                style: AymaType.sans(size: 12, soft: true, color: ac.fgMute),
              ),
              const SizedBox(height: 4),
              Text(
                original,
                style: AymaType.sans(size: 14, soft: true, color: ac.fgDim),
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Send'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _askAyma() {
    final name = widget.title == 'Conversation' ? 'them' : widget.title;
    ChatInbox.instance.push(
      ChatKickoff.talkAbout(
        targetUid: _dm.otherUidOf(widget.threadId),
        label: name,
        conversation: true,
        shareKind: 'conversation',
        refId: widget.threadId,
      ),
    );
    context.go(MainShellScreen.path);
  }

  Future<void> _openAttachSheet() async {
    _composerFocus.unfocus();
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Photo'),
              onTap: () => Navigator.pop(ctx, 'gallery'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Camera'),
              onTap: () => Navigator.pop(ctx, 'camera'),
            ),
            ListTile(
              leading: const Icon(Icons.attach_file),
              title: const Text('File'),
              onTap: () => Navigator.pop(ctx, 'file'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    try {
      switch (choice) {
        case 'gallery':
          await _pickImage(ImageSource.gallery);
        case 'camera':
          await _pickImage(ImageSource.camera);
        case 'file':
          await _pickFile();
      }
    } catch (e) {
      if (mounted) {
        AymaToast.show(context, "Couldn't attach that ($e).",
            kind: AymaToastKind.error);
      }
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    final p = await _picker.pickImage(
      source: source,
      maxWidth: 2000,
      imageQuality: 85,
    );
    if (p != null && mounted) {
      setState(() {
        _pending = File(p.path);
        _pendingType = 'image';
      });
    }
  }

  Future<void> _pickFile() async {
    final res = await FilePicker.platform.pickFiles(withReadStream: false);
    final path = res?.files.single.path;
    if (path != null && mounted) {
      setState(() {
        _pending = File(path);
        _pendingType = 'file';
      });
    }
  }

  /// A GIF/image inserted from the keyboard's GIF/image button (§6.6). The
  /// keyboard hands us the bytes directly (no file on disk), so — WhatsApp-style
  /// — it uploads and sends immediately as a `gif`/`image` message. Keeps any
  /// text already in the composer untouched; degrades with a toast if the
  /// keyboard gives only a content URI we can't read, or on an upload failure.
  Future<void> _onContentInserted(KeyboardInsertedContent content) async {
    if (_sending) return;
    final Uint8List? bytes = content.data;
    if (bytes == null || bytes.isEmpty) {
      if (mounted) {
        AymaToast.show(
          context,
          "Couldn't read that — tap + to attach it instead.",
          kind: AymaToastKind.error,
        );
      }
      return;
    }
    final mime = content.mimeType;
    final type = mime.toLowerCase() == 'image/gif' ? 'gif' : 'image';
    setState(() => _sending = true);
    try {
      final att = await _dm.uploadInsertedAttachment(
        bytes,
        threadId: widget.threadId,
        mime: mime,
      );
      await _dm.sendAttachment(widget.threadId, type: type, attachment: att);
    } catch (e) {
      if (mounted) {
        AymaToast.show(context, 'Not sent ($e).', kind: AymaToastKind.error);
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _blockAndReport() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: const Text('Block & report'),
        content: const Text(
          'They will no longer be able to message you, this thread is hidden, '
          'and they drop out of your matches. This cannot be undone here.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Block'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _dm.block(_dm.otherUidOf(widget.threadId));
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        AymaToast.show(context, 'Could not block ($e).',
            kind: AymaToastKind.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final me = _dm.uid;
    return Scaffold(
      appBar: AppBar(
        leading: const AymaBackButton(),
        
        titleSpacing: 0,
        title: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            final uid = _safeOtherUid();
            if (uid.isNotEmpty) context.push('/profile/user/$uid');
          },
          child: _Header(name: _headerName, mini: _other),
        ),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'block') _blockAndReport();
              if (v == 'ask_ayma') _askAyma();
              if (v == 'auto_translate') {
                setState(() => _autoTranslate = !_autoTranslate);
              }
              if (v == 'translate_outgoing') {
                setState(() => _translateOutgoing = !_translateOutgoing);
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'ask_ayma',
                child: Text('Share this chat with Ayma'),
              ),
              // Cross-language DM (§6.12): auto-translate incoming messages into
              // your language, and opt in to translating what you send into
              // theirs (with a preview before it goes).
              CheckedPopupMenuItem(
                value: 'auto_translate',
                checked: _autoTranslate,
                child: const Text('Auto-translate their messages'),
              ),
              CheckedPopupMenuItem(
                value: 'translate_outgoing',
                checked: _translateOutgoing,
                child: const Text('Translate what I send'),
              ),
              const PopupMenuItem(
                value: 'block',
                child: Text('Block & report'),
              ),
            ],
          ),
        ],
      ),
      // LayoutBuilder gives the coaching region a real height to cap against:
      // in a Column its children get unbounded vertical space, so the chips +
      // tip would otherwise push the composer off-screen in a short window
      // (split-screen, landscape, text 2.0). Capped to a share of the viewport
      // and scrolled past that, the composer always stays reachable.
      body: LayoutBuilder(
        builder: (context, constraints) => Column(
        children: [
          Expanded(
            child: StreamBuilder<FreshData<List<DmMessage>>>(
              stream: _dm.watchMessagesFresh(widget.threadId),
              builder: (context, snap) {
                final fresh = snap.data;
                final tail = fresh?.data ?? const <DmMessage>[];
                final merged = _mergeTail(tail);
                final msgs = [
                  ...merged,
                  ..._visibleLocalVoice(merged),
                ];
                _oldestId = msgs.isEmpty ? null : msgs.first.id;
                _tailFull = tail.length >= _historyPageSize;
                _markReadIfIncoming(msgs);
                // Refresh the coaching chips/tip as the conversation grows —
                // debounced, and only on an actual message change (see
                // `_scheduleAssist`). A transient stream error leaves the last
                // suggestions in place rather than clearing them.
                if (!snap.hasError) _scheduleAssist(msgs);
                // A brand-new thread has no doc yet; the stream can be briefly
                // empty or (transiently) error — never hang the screen on it.
                final waiting = fresh == null &&
                    snap.connectionState == ConnectionState.waiting &&
                    !snap.hasError;
                // `reverse: true` keeps the list pinned to the newest message
                // — without it the view stayed put while new bubbles landed
                // below the fold, half-clipped against the composer (founder
                // screenshot). The bottom inset matches the Ayma chat's, so
                // the last bubble clears the composer identically on both
                // screens; items are keyed by id so the reversed indexing
                // still animates each new bubble in once. The freshness banner
                // (PERF_PLAN Phase 1) sits above the transcript so Live /
                // Syncing / Stale / Refused is visible without guessing.
                return Column(
                  children: [
                    if (fresh != null) FreshnessIndicator.fromFresh(fresh),
                    Expanded(
                      child: msgs.isEmpty
                          // First emission of the thread's message stream.
                          ? (waiting
                              ? const Center(
                                  child: AymaWingLoader(
                                    lines: AymaLoaderLines.dmThread,
                                  ),
                                )
                              : Center(
                                  child: Text(
                                    'Say something.',
                                    style: AymaType.sans(
                                      size: 15,
                                      soft: true,
                                      color: ac.fgMute,
                                    ),
                                  ),
                                ))
                          : ListView.builder(
                              controller: _listController,
                              reverse: true,
                              // iOS has no keyboard-dismiss key — dragging the
                              // transcript away is the native escape hatch.
                              keyboardDismissBehavior:
                                  ScrollViewKeyboardDismissBehavior.onDrag,
                              padding: const EdgeInsets.fromLTRB(
                                16,
                                16,
                                16,
                                kChatListBottomInset, // bottom 12
                              ),
                              itemCount: msgs.length + (_fetchingOlder ? 1 : 0),
                              itemBuilder: (context, i) {
                                if (i >= msgs.length) {
                                  // History page in flight — pinned to the top
                                  // of the reversed transcript (last index).
                                  // Older-messages query — inline slot, wings only.
                                  return const Padding(
                                    padding:
                                        EdgeInsets.symmetric(vertical: 16),
                                    child: Center(
                                      child: AymaWingLoader(
                                        size: 20,
                                        showLabel: false,
                                      ),
                                    ),
                                  );
                                }
                                final m = msgs[msgs.length - 1 - i];
                                final mine = m.senderUid == me;
                                final prev = (msgs.length - 1 - i > 0)
                                    ? msgs[msgs.length - 1 - i - 1]
                                    : null;
                                final showDivider = shouldShowDateDivider(
                                    prev?.createdAt, m.createdAt);
                                final bubble = _Bubble(
                                  message: m,
                                  mine: mine,
                                  voicePlayer: _clipPlayer,
                                  nowPlaying: _nowPlaying,
                                  localVoiceFile: _localVoiceFiles[m.id],
                                  voiceUrlResolver: _dm.voiceDownloadUrl,
                                  // Incoming text bubbles get the translate
                                  // affordance; auto-translate kicks in when
                                  // the thread toggle is on.
                                  translate: mine
                                      ? null
                                      : (text) => _dm.translate(
                                            widget.threadId,
                                            text,
                                            _preferredLang,
                                          ),
                                  autoTranslate: _autoTranslate,
                                  onDetected: _onOtherLangDetected,
                                  preferredLang: _preferredLang,
                                );
                                final content =
                                    (showDivider && m.createdAt != null)
                                        ? Column(
                                            mainAxisSize: MainAxisSize.min,
                                            crossAxisAlignment:
                                                CrossAxisAlignment.stretch,
                                            children: [
                                              DateDividerChip(
                                                  date: m.createdAt!),
                                              bubble,
                                            ],
                                          )
                                        : bubble;
                                return FadeSlideIn(
                                  key: ValueKey(m.id),
                                  delay: staggerDelay(i),
                                  offset: 8,
                                  // Ayma's screen context carries only the
                                  // newest few messages of a private
                                  // conversation.
                                  child: i < _kContextMessages
                                      ? content
                                      : NoScreenContext(child: content),
                                );
                              },
                            ),
                    ),
                  ],
                );
              },
            ),
          ),
          if (_assist.chips.isNotEmpty ||
              _visibleTip != null ||
              _visibleSafety != null)
            CappedScroll(
              // Never let coaching take more than half the screen — past that
              // it is clipped at the cap (never scrolled) rather than squeezing
              // out the list or the composer.
              maxHeight: constraints.maxHeight * 0.5,
              scrollable: false,
              // Pin the BOTTOM of the coaching region in view. The tip is the
              // last child and the one the founder most wants visible; without
              // this the region is top-aligned, so once the keyboard shrinks
              // the cap the tip scrolls off below the fold ("hidden behind the
              // keyboard"). Bottom-anchored, the tip sits directly above the
              // composer — which already rides above the keyboard inset — and
              // the chips clip off the top instead. No effect when the
              // content fits (the scroll view is then just its content tall).
              reverse: true,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // The safety heads-up is the highest-priority note — it sits
                  // above the coaching chips/tip. Advisory only: it never
                  // blocks typing or sending.
                  if (_visibleSafety != null)
                    _SafetyNote(
                      safety: _visibleSafety!,
                      onDismiss: _dismissSafety,
                    ),
                  if (_assist.chips.isNotEmpty)
                    _SuggestionBar(
                      chips: _assist.chips.take(_maxCoachChips).toList(),
                      onTap: (text) {
                        _composer.text = text;
                        _composer.selection = TextSelection.collapsed(
                          offset: _composer.text.length,
                        );
                        _composerFocus.requestFocus();
                      },
                    ),
                  if (_visibleTip != null)
                    _CoachTip(tip: _visibleTip!, onDismiss: _dismissTip),
                ],
              ),
            ),
          if (_pending != null)
            _PendingAttachment(
              file: _pending!,
              isImage: _pendingType == 'image',
              busy: _sending,
              onRemove: _sending ? null : () => setState(() => _pending = null),
            ),
          // When "Translate what I send" is on, a quiet one-line banner so it's
          // never a surprise that an outgoing message will be translated
          // (§6.12). The actual translation is still previewed before it sends.
          if (_translateOutgoing)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
              child: Row(
                children: [
                  Icon(Icons.translate, size: 14, color: ac.accent),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Ayma will translate your message to their language — '
                      "you'll see it before it sends.",
                      style: AymaType.sans(size: 12, soft: true, color: ac.fgMute),
                    ),
                  ),
                ],
              ),
            ),
          // No SafeArea here, deliberately: this screen is always wrapped in
          // `NavBarShell`, whose `AymaTabBar` below already consumes the
          // device's bottom inset itself — a SafeArea would pad that inset in
          // a second time, floating the composer visibly higher above the nav
          // bar than the Ayma chat's (founder ask: same spacing). The padding
          // is the same shared constant the Ayma chat's composer uses.
          // KeepKeyboardOnTap: the composer bar (attach / send included) is a
          // keep-the-keyboard zone for the app-root tap-outside-dismiss —
          // mirrors ChatComposer's own marker. Pure registry entry, changes
          // nothing about hit testing.
          KeepKeyboardOnTap(
            child: Padding(
              padding: kComposerBarPadding,
              child: ListenableBuilder(
                listenable: _voiceNote,
                // Stack, always: the row stays MOUNTED under the recording
                // bar while a hold is in progress - replacing it unmounted
                // the held mic button and killed its gesture recognizer,
                // so the release that sends the clip never fired.
                builder: (context, _) => Stack(
                  children: [
                    Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // The attach button lives inside the pill's left edge
                  // (leading icon, same rounded container as the text
                  // field) rather than as a separate button beside it, so
                  // the input itself spans the full available width —
                  // mirrors ChatComposer's leading/trailing-icon-in-pill
                  // pattern (lib/widgets/chat_composer.dart).
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: ac.bgElev,
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(color: ac.lineSoft, width: 1),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          IconButton(
                            onPressed: _sending ? null : _openAttachSheet,
                            icon: const Icon(Icons.add),
                            tooltip: 'Attach',
                          ),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 11),
                              child: TextField(
                                controller: _composer,
                                focusNode: _composerFocus,
                                minLines: 1,
                                maxLines: 4,
                                // Declare rich-content support so Gboard's
                                // GIF/image button inserts media here instead
                                // of showing "This app does not support images
                                // here" — the inserted bytes upload + send as a
                                // gif/image message (§6.6).
                                contentInsertionConfiguration:
                                    ContentInsertionConfiguration(
                                  onContentInserted: _onContentInserted,
                                ),
                                decoration: const InputDecoration(
                                  filled: false,
                                  border: InputBorder.none,
                                  focusedBorder: InputBorder.none,
                                  enabledBorder: InputBorder.none,
                                  disabledBorder: InputBorder.none,
                                  isCollapsed: true,
                                  hintText: 'Message',
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // WhatsApp swap (founder, 2026-11-06): the slot is the
                  // MIC while the input is empty and nothing is staged,
                  // and SEND only with text or a staged attachment.
                  if (_sending)
                    // POST /dm/{threadId}/messages in flight - the send
                    // slot, wings only.
                    const Padding(
                      padding: EdgeInsets.all(8),
                      child: AymaWingLoader(size: 24, showLabel: false),
                    )
                  else if (_composer.text.trim().isNotEmpty ||
                      _pending != null)
                    IconButton.filled(
                      key: const ValueKey('composerSendButton'),
                      onPressed: _send,
                      icon: const Icon(Icons.arrow_upward_rounded),
                    )
                  else
                    VoiceNoteMicButton(
                      controller: _voiceNote,
                      background: ac.bgElev,
                      foreground: ac.fgDim,
                      onTap: () => AymaToast.show(
                        context,
                        'Hold to record a voice message.',
                      ),
                    ),
                ],
              ),
                    if (_voiceNote.isActive)
                      Positioned.fill(
                        child: VoiceNoteRecordingBar(
                          controller: _voiceNote,
                        ),
                      ),
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

/// The DM app-bar title: the other person's avatar + name, with a small dot
/// when they've used the app in the last few minutes. Mirrors a Messages row.
class _Header extends StatelessWidget {
  const _Header({required this.name, required this.mini});

  final String name;
  final MiniProfile? mini;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final photo = mini?.photo ?? '';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Stack(
          children: [
            ClipOval(
              child: SizedBox(
                width: 32,
                height: 32,
                child: photo.isEmpty
                    ? Container(
                        color: ac.bgCard,
                        alignment: Alignment.center,
                        child: Text(
                          name.isNotEmpty ? name[0].toUpperCase() : '?',
                          style: AymaType.sans(size: 14, color: ac.fgMute),
                        ),
                      )
                    : AymaPhoto(url: photo, displayWidth: 32),
              ),
            ),
            if (mini?.online ?? false)
              Positioned(
                right: 0,
                bottom: 0,
                child: Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: ac.success,
                    shape: BoxShape.circle,
                    border: Border.all(color: ac.bg, width: 2),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AymaType.sans(size: 16, weight: FontWeight.w600, color: ac.fg),
          ),
        ),
      ],
    );
  }
}

/// The picked-but-unsent attachment shown just above the composer, with a
/// thumbnail (images) or a file chip, a remove button, and a progress bar
/// while the send is uploading.
class _PendingAttachment extends StatelessWidget {
  const _PendingAttachment({
    required this.file,
    required this.isImage,
    required this.busy,
    required this.onRemove,
  });

  final File file;
  final bool isImage;
  final bool busy;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final name = file.uri.pathSegments.isNotEmpty
        ? file.uri.pathSegments.last
        : 'file';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: ac.lineSoft, width: 0.5)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: isImage
                    ? Image.file(file, width: 44, height: 44, fit: BoxFit.cover)
                    : Container(
                        width: 44,
                        height: 44,
                        color: ac.bgCard,
                        alignment: Alignment.center,
                        child: Icon(
                          Icons.insert_drive_file_outlined,
                          size: 22,
                          color: ac.fgDim,
                        ),
                      ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AymaType.sans(size: 13, color: ac.fgDim),
                ),
              ),
              IconButton(
                iconSize: 18,
                icon: const Icon(Icons.close),
                color: ac.fgMute,
                onPressed: onRemove,
              ),
            ],
          ),
          if (busy)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: LinearProgressIndicator(minHeight: 2),
            ),
        ],
      ),
    );
  }
}

/// Ayma's live suggestion chips above the composer (§6.9). Tap one to drop its
/// text into the composer. The set refreshes as the conversation grows — these
/// are common ground to keep talking about, not one-shot openers, so there's
/// no manual dismiss; an empty set simply hides the bar.
/// Most suggestion chips shown above the composer — keeps the coaching region
/// short enough to sit above the keyboard.
const int _maxCoachChips = 2;

class _SuggestionBar extends StatelessWidget {
  const _SuggestionBar({required this.chips, required this.onTap});
  final List<String> chips;
  final void Function(String) onTap;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: ac.lineSoft, width: 0.5)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Things to talk about',
            style: AymaType.sans(size: 12, soft: true, color: ac.fgMute),
          ),
          const SizedBox(height: 6),
          for (final c in chips)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: InkWell(
                onTap: () => onTap(c),
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: ac.bgCard,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: ac.lineSoft, width: 0.5),
                  ),
                  child: Text(
                    c,
                    softWrap: true,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AymaType.sans(size: 13, color: ac.fg),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A calm, protective safety heads-up (§6.9.1), visually distinct from the
/// coaching tip: a shield glyph, a soft tinted card, and a short supportive
/// line — never an alarmist red full-bleed banner. Shown only for a genuine
/// concern (level caution/warning) and dismissible. It is advisory only and
/// never blocks typing or sending; it never shames the user. `warning` reads a
/// touch stronger than `caution` (a slightly firmer tint + a "Heads up" label),
/// but both stay quiet and supportive.
class _SafetyNote extends StatelessWidget {
  const _SafetyNote({required this.safety, required this.onDismiss});
  final DmSafety safety;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final isWarning = safety.level == 'warning';
    // Lean on the theme's warning hue, but muted into a soft card — calm, not
    // screaming. A warning is a little more present than a caution.
    final tint = ac.warning.withValues(alpha: isWarning ? 0.12 : 0.08);
    final line = ac.warning.withValues(alpha: isWarning ? 0.45 : 0.30);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
        decoration: BoxDecoration(
          color: tint,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: line, width: 1),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(
                Icons.shield_outlined,
                size: 18,
                color: ac.warning,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Heads up from Ayma',
                    style: AymaType.sans(
                      size: 12,
                      weight: FontWeight.w600,
                      color: ac.fg,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    safety.reason,
                    softWrap: true,
                    style: AymaType.sans(size: 13, color: ac.fgDim),
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: onDismiss,
              iconSize: 15,
              icon: const Icon(Icons.close),
              color: ac.fgMute,
              visualDensity: VisualDensity.compact,
              tooltip: 'Dismiss safety note',
            ),
          ],
        ),
      ),
    );
  }
}

/// A quiet one-line coaching nudge from Ayma, just above the composer: a small
/// Ayma glyph, muted text, and a small dismiss button. Shown only when the
/// assist response carries a tip; kept deliberately low-key so it reads as a
/// gentle aside, not an alert.
class _CoachTip extends StatelessWidget {
  const _CoachTip({required this.tip, required this.onDismiss});
  final String tip;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: ac.lineSoft, width: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: AymaOrb(size: 15, showGlow: false),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              tip,
              softWrap: true,
              style: AymaType.sans(size: 12, soft: true, color: ac.fgMute),
            ),
          ),
          IconButton(
            onPressed: onDismiss,
            iconSize: 15,
            icon: const Icon(Icons.close),
            color: ac.fgMute,
            visualDensity: VisualDensity.compact,
            tooltip: 'Dismiss tip',
          ),
        ],
      ),
    );
  }
}

/// A DM voice-note bubble: the shared WhatsApp-style playable row
/// ([VoiceClipRow]) over the clip. While the sender's upload is still
/// landing it plays the local file; afterwards it resolves the stored
/// clip's storage path (the message body) to a download URL.
class _DmVoiceBubble extends StatefulWidget {
  const _DmVoiceBubble({
    required this.message,
    required this.player,
    required this.nowPlaying,
    required this.iconColor,
    required this.captionColor,
    this.localFile,
    this.urlResolver,
  });

  final DmMessage message;
  final AsyncVoicePlayer player;
  final ValueNotifier<String?> nowPlaying;
  final Color iconColor;
  final Color captionColor;
  final String? localFile;
  final Future<String?> Function(String storagePath)? urlResolver;

  @override
  State<_DmVoiceBubble> createState() => _DmVoiceBubbleState();
}

class _DmVoiceBubbleState extends State<_DmVoiceBubble> {
  String? _url;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant _DmVoiceBubble old) {
    super.didUpdateWidget(old);
    if (old.message.id != widget.message.id ||
        old.localFile != widget.localFile) {
      _url = null;
      _resolve();
    }
  }

  Future<void> _resolve() async {
    final m = widget.message;
    if (widget.localFile != null && widget.localFile!.isNotEmpty) return;
    if (m.attachmentUrl.isNotEmpty) {
      _url = m.attachmentUrl;
      return;
    }
    final resolver = widget.urlResolver;
    if (resolver == null || m.body.isEmpty) return;
    try {
      final url = await resolver(m.body);
      if (mounted && url != null) setState(() => _url = url);
    } catch (_) {
      // Unresolvable right now - the labelled placeholder stays.
    }
  }

  @override
  Widget build(BuildContext context) {
    final local = widget.localFile;
    final hasLocal = local != null && local.isNotEmpty;
    if (!hasLocal && _url == null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.mic_rounded, size: 18, color: widget.captionColor),
          const SizedBox(width: 8),
          Text(
            'Voice message',
            style: AymaType.sans(size: 12, color: widget.captionColor),
          ),
        ],
      );
    }
    return VoiceClipRow(
      audioUrl: hasLocal ? null : _url,
      audioFile: hasLocal ? local : null,
      player: widget.player,
      nowPlaying: widget.nowPlaying,
      clipKey: 'dm-${widget.message.id}',
      iconColor: widget.iconColor,
      captionColor: widget.captionColor,
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.message,
    required this.mine,
    this.translate,
    this.autoTranslate = false,
    this.onDetected,
    this.preferredLang = '',
    this.voicePlayer,
    this.nowPlaying,
    this.localVoiceFile,
    this.voiceUrlResolver,
  });
  final DmMessage message;
  final bool mine;

  /// Voice-note playback wiring (voice messages only): the shared player,
  /// the app-wide now-playing key, this bubble's local file while its
  /// upload is still landing, and a resolver from a stored clip's storage
  /// path (the message body) to a playable URL.
  final AsyncVoicePlayer? voicePlayer;
  final ValueNotifier<String?>? nowPlaying;
  final String? localVoiceFile;
  final Future<String?> Function(String storagePath)? voiceUrlResolver;

  /// Translate this bubble's text into the reader's language (incoming text
  /// bubbles only; null disables the affordance). [autoTranslate] runs it on
  /// first display; [onDetected] reports the detected source language up so an
  /// outgoing translation knows the match's language. [preferredLang] is the
  /// reader's language, used to decide whether a message is in a different
  /// writing system (and so reliably foreign).
  final Future<DmTranslation> Function(String text)? translate;
  final bool autoTranslate;
  final void Function(String lang)? onDetected;
  final String preferredLang;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;

    final report = message.reportShare;
    final bool tight;
    final Widget content;
    if (message.type == 'voice' && voicePlayer != null && nowPlaying != null) {
      // A voice note: a playable WhatsApp-style row, from the local file
      // while uploading or from the stored clip's URL once posted.
      tight = false;
      content = _DmVoiceBubble(
        message: message,
        player: voicePlayer!,
        nowPlaying: nowPlaying!,
        localFile: localVoiceFile,
        urlResolver: voiceUrlResolver,
        iconColor: _ink(ac),
        captionColor: _ink(ac),
      );
    } else if (message.isSharedReport && report != null) {
      tight = true;
      content = SharedReportCard(
        share: report,
        onTap: () => context.push('/s/${report.token}'),
      );
    } else if (message.hasImage || message.hasGif) {
      // A GIF renders the same way (Image.network animates it inline); it only
      // differs in its stored type + label.
      tight = true;
      content = _image(context, ac);
    } else if (message.hasFile) {
      tight = false;
      content = _file(context, ac);
    } else if (!mine &&
        message.type == 'text' &&
        message.body.trim().isNotEmpty &&
        translate != null) {
      // Incoming text in a (possibly) different language: show the original
      // with a subtle Translate affordance (§6.12).
      tight = false;
      content = _TranslatableText(
        key: ValueKey('tr-${message.id}'),
        text: message.body,
        ink: _ink(ac),
        translate: translate!,
        autoTranslate: autoTranslate,
        onDetected: onDetected,
        preferredLang: preferredLang,
      );
    } else {
      tight = false;
      final label = switch (message.type) {
        'photo' || 'image' => '📷 Photo',
        'gif' => '📷 GIF',
        'voice' => '🎙 Voice message',
        'file' => '📎 File',
        'shared_profile' => '👤 Shared a profile',
        'shared_report' => '📄 Shared a report',
        _ => message.body,
      };
      content = Text(
        label,
        style: AymaType.message(color: _ink(ac)),
      );
    }

    // WhatsApp-style time label appended at the bottom-right of the bubble
    // (display-only; shown when the message carries a createdAt).
    final timeStr = message.createdAt != null
        ? formatMessageTime(message.createdAt!)
        : null;
    final withTime = timeStr == null
        ? content
        : Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              content,
              const SizedBox(height: 2),
              Padding(
                padding: EdgeInsets.only(
                  right: tight ? 4 : 0,
                  bottom: tight ? 2 : 0,
                ),
                child: Text(
                  timeStr,
                  style: AymaType.sans(
                    size: 10.5,
                    color: (mine && !message.moderated)
                        ? ac.onAccent.withValues(alpha: 0.72)
                        : ac.fgMute,
                  ),
                ),
              ),
            ],
          );

    return ChatBubble(
      mine: mine,
      tight: tight,
      flagged: message.moderated,
      copyText: message.body,
      child: withTime,
    );
  }

  /// Ink for text/icons drawn on top of this bubble. A sent (non-flagged)
  /// bubble now renders on the solid [AymaTokens.accent] fill, so it needs
  /// [AymaTokens.onAccent] — the same ink the rest of the app uses on any
  /// accent-filled surface — instead of the regular foreground colour.
  Color _ink(AymaTokens ac) =>
      (mine && !message.moderated) ? ac.onAccent : ac.fg;

  Widget _image(BuildContext context, AymaTokens ac) {
    final heroTag = 'dm-image-${message.id}';
    final thumb = ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Image.network(
        message.attachmentUrl,
        width: 220,
        fit: BoxFit.cover,
        loadingBuilder: (ctx, child, progress) => progress == null
            ? child
            : Container(
                width: 220,
                height: 220,
                color: ac.bgCard,
                alignment: Alignment.center,
                child: const AymaWingLoader(
                  size: 40,
                  lines: AymaLoaderLines.photo,
                ),
              ),
        errorBuilder: (ctx, _, __) => Container(
          width: 220,
          height: 120,
          color: ac.bgCard,
          alignment: Alignment.center,
          child: Icon(Icons.broken_image_outlined, color: ac.fgMute),
        ),
      ),
    );
    return Column(
      crossAxisAlignment: mine
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: () => AymaImageViewer.open(
            context,
            url: message.attachmentUrl,
            heroTag: heroTag,
          ),
          child: Hero(tag: heroTag, child: thumb),
        ),
        if (message.body.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 6, 6, 2),
            child: Text(
              message.body,
              style: AymaType.message(color: _ink(ac)),
            ),
          ),
      ],
    );
  }

  Widget _file(BuildContext context, AymaTokens ac) {
    return Column(
      crossAxisAlignment: mine
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: () => launchUrl(
            Uri.parse(message.attachmentUrl),
            mode: LaunchMode.externalApplication,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _fileIcon(message.mime),
                color: mine && !message.moderated ? ac.onAccent : ac.fgDim,
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      message.fileName.isNotEmpty
                          ? message.fileName
                          : 'Attachment',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AymaType.sans(
                        size: 14,
                        color: _ink(ac),
                        weight: FontWeight.w500,
                      ),
                    ),
                    if (message.size > 0)
                      Text(
                        _fmtBytes(message.size),
                        style: AymaType.sans(
                          size: 12,
                          color: mine && !message.moderated
                              ? ac.onAccent.withValues(alpha: 0.7)
                              : ac.fgMute,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (message.body.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              message.body,
              style: AymaType.message(color: _ink(ac)),
            ),
          ),
      ],
    );
  }
}

/// Incoming message text with a subtle "Translate" affordance (§6.12). The
/// original is always shown; tapping Translate (or the thread's auto-translate
/// toggle) renders the translation beneath it with a "translated from `lang`"
/// label and a toggle to hide it again. Any failure degrades to just the
/// original — translation never blocks reading the message.
///
/// Whether to even offer a translation is decided per message, so the reader is
/// never offered "Translate" on a message already in their own language:
/// - A DIFFERENT writing system than [preferredLang] (e.g. Malayalam text for
///   an English reader) is reliably foreign on script alone — the "Translate"
///   affordance shows immediately, no detection round-trip needed.
/// - SAME-script text (English, Spanish, French for an English reader) is
///   ambiguous — especially short messages like "hello" — so we quietly run the
///   backend detector once: it returns a real translation only when confident
///   the text is a different language, otherwise the original (so nothing is
///   offered). The "Translate" affordance appears only for confidently-foreign
///   same-script messages; the translation is cached and revealed on tap.
class _TranslatableText extends StatefulWidget {
  const _TranslatableText({
    super.key,
    required this.text,
    required this.ink,
    required this.translate,
    required this.autoTranslate,
    this.onDetected,
    this.preferredLang = '',
  });

  final String text;
  final Color ink;
  final Future<DmTranslation> Function(String text) translate;
  final bool autoTranslate;
  final void Function(String lang)? onDetected;
  final String preferredLang;

  @override
  State<_TranslatableText> createState() => _TranslatableTextState();
}

class _TranslatableTextState extends State<_TranslatableText> {
  DmTranslation? _tr;
  bool _loading = false;
  bool _failed = false;
  bool _manual = false; // the user tapped Translate (vs auto/eager detection)
  bool _show = true; // show the translation block (toggle to hide)

  /// A reliably-foreign message (different writing system than the reader's
  /// language): offer "Translate" immediately, no detection needed.
  bool get _foreignByScript =>
      isForeignScript(widget.text, widget.preferredLang);

  /// Same-script text that must be detected to tell the reader's own language
  /// (don't offer) from a confidently-foreign one (offer). Script-less noise
  /// (emoji/numbers) is neither, so it is never detected or offered.
  bool get _ambiguousSameScript =>
      dominantScript(widget.text) != 'none' && !_foreignByScript;

  @override
  void initState() {
    super.initState();
    // Auto-translate runs everything; otherwise quietly detect same-script text
    // so a message already in the reader's language never shows "Translate".
    if (widget.autoTranslate || _ambiguousSameScript) _run(manual: false);
  }

  @override
  void didUpdateWidget(covariant _TranslatableText old) {
    super.didUpdateWidget(old);
    // The thread's auto-translate toggle flipped on after this bubble appeared.
    if (widget.autoTranslate &&
        !old.autoTranslate &&
        _tr == null &&
        !_loading) {
      _run(manual: false);
    }
  }

  Future<void> _run({required bool manual}) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _failed = false;
      if (manual) {
        _manual = true;
        _show = true;
      }
    });
    try {
      final tr = await widget.translate(widget.text);
      if (!mounted) return;
      if (tr.detectedSourceLang.isNotEmpty) {
        widget.onDetected?.call(tr.detectedSourceLang);
      }
      setState(() {
        _tr = tr;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  bool get _isTranslated {
    final t = _tr;
    return t != null &&
        t.translated.trim().isNotEmpty &&
        t.translated.trim() != widget.text.trim();
  }

  /// Whether the translation block is currently visible — auto-translate shows
  /// it inline; a manual tap reveals the (possibly already-fetched) translation.
  bool get _revealed => widget.autoTranslate || _manual;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final muted = AymaType.sans(size: 12, soft: true, color: ac.fgMute);

    final rows = <Widget>[
      // The original is always present and accessible.
      Text(widget.text, style: AymaType.message(color: widget.ink)),
    ];

    // Only surface a spinner when the reader asked (tapped) or auto-translate
    // is on — the quiet same-script detection must not flash "Translating…" on
    // every ordinary same-language message.
    final showLoading = _loading && _revealed;

    if (showLoading) {
      rows.add(Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const AymaWingLoader(size: 12, showLabel: false),
            const SizedBox(width: 6),
            Flexible(child: Text('Translating…', style: muted)),
          ],
        ),
      ));
    } else if (_isTranslated) {
      final from = _tr!.detectedSourceLang;
      if (_revealed && _show) {
        // Reader is seeing the translation inline (auto-translate or after tap).
        rows.add(Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            _tr!.translated,
            style: AymaType.message(color: widget.ink),
          ),
        ));
        rows.add(_affordance(
          label: from.isEmpty
              ? 'translated · Show original'
              : 'translated from $from · Show original',
          muted: muted,
          onTap: () => setState(() => _show = false),
        ));
      } else if (_revealed) {
        // Reader hid the translation (manual/auto) — let them bring it back.
        rows.add(_affordance(
          label: 'Show translation',
          muted: muted,
          onTap: () => setState(() => _show = true),
        ));
      } else {
        // Confidently foreign but not yet revealed: offer the translation
        // (already fetched for same-script, or fetched on tap for a different
        // script — either way no extra round-trip is needed to reveal it).
        rows.add(_affordance(
          label: 'Translate',
          muted: muted,
          onTap: () => _reveal(),
        ));
      }
    } else if (_tr != null) {
      // Detected and resolved to the reader's own language: offer nothing,
      // unless the reader explicitly tapped Translate on it.
      if (_manual) {
        rows.add(Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('Already in your language', style: muted),
        ));
      }
    } else if (_failed) {
      rows.add(_affordance(
        label: "Couldn't translate · Try again",
        muted: muted,
        onTap: () => _run(manual: true),
      ));
    } else if (_foreignByScript) {
      // Reliably foreign, not yet fetched (different script, auto-translate off).
      rows.add(_affordance(
        label: 'Translate',
        muted: muted,
        onTap: () => _run(manual: true),
      ));
    }
    // Otherwise (same-script detection pending, or script-less noise): show just
    // the original with no affordance.

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: rows,
    );
  }

  /// Reveal an already-fetched translation (no new round-trip).
  void _reveal() => setState(() {
        _manual = true;
        _show = true;
      });

  Widget _affordance({
    required String label,
    required TextStyle muted,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 2),
        child: Text(label, style: muted),
      ),
    );
  }
}

IconData _fileIcon(String mime) {
  if (mime.startsWith('image/')) return Icons.image_outlined;
  if (mime.startsWith('audio/')) return Icons.audiotrack_outlined;
  if (mime.startsWith('video/')) return Icons.movie_outlined;
  if (mime == 'application/pdf') return Icons.picture_as_pdf_outlined;
  if (mime.contains('zip') || mime.contains('compressed')) {
    return Icons.folder_zip_outlined;
  }
  if (mime.startsWith('text/')) return Icons.description_outlined;
  return Icons.insert_drive_file_outlined;
}

String _fmtBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
