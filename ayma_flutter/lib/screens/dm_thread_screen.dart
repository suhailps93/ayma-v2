import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/api_client.dart';
import '../services/app_context.dart';
import '../services/chat_inbox.dart';
import '../services/dm_service.dart';
import '../theme.dart';
import '../widgets/ayma_orb.dart';
import '../widgets/ayma_photo.dart';
import '../widgets/ayma_toast.dart';
import '../widgets/overflow_guards.dart';
import '../widgets/chat_bubble.dart';
import '../widgets/chat_composer.dart'
    show kChatListBottomInset, kComposerBarPadding;
import '../widgets/image_viewer.dart';
import '../widgets/keyboard_dismiss.dart';
import '../widgets/shared_report_card.dart';
import '../widgets/staggered.dart';
import 'main_shell_screen.dart';
import '../widgets/ayma_back_button.dart';
import '../services/screen_capture.dart';

/// How many of the newest DM messages Ayma's screen context may include.
const int _kContextMessages = 3;

/// One DM conversation (§6.6, §6.11 step 9). Text send is wired; photo/voice
/// use the same message pipeline once a file is uploaded (Step 51 ingests them).
/// Image / file attachments upload to `uploads/{uid}/dm/{threadId}/…` and send
/// as `image` / `file` messages carrying the download URL + metadata.
///
/// "Ayma in your DMs" coaching (§6.9) lives above the composer: up-to-4
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
  });

  static const path = '/dm';

  final String threadId;
  final String title;
  final DmService? dmService;
  final ApiClient? apiClient;
  final ImagePicker? picker;

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

  /// A picked-but-not-yet-sent attachment.
  File? _pending;
  String _pendingType = 'file'; // 'image' | 'file'

  /// Live DM coaching (chips + tip), refreshed from `POST /dm/assist` as the
  /// conversation grows. Starts empty so nothing shows until the first fetch.
  DmAssist _assist = DmAssist.empty;

  /// The exact tip text the user last dismissed. A newly-fetched, different
  /// tip re-surfaces (auto-updates); the same one stays hidden.
  String? _dismissedTip;

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

  @override
  void initState() {
    super.initState();
    reassertScreenContext();
    _loadOther();
    _dm.markThreadRead(widget.threadId);
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

  Future<void> _send() async {
    final text = _composer.text.trim();
    final pending = _pending;
    if (_sending) return;
    if (pending == null && text.isEmpty) return;

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
        await _dm.sendText(widget.threadId, text);
      }
      _composer.clear();
      if (mounted) setState(() => _pending = null);
      // Keep the conversation-starters around — they're common ground to talk
      // about, not one-shot openers.
    } catch (e) {
      if (mounted) {
        AymaToast.show(context, 'Not sent ($e).', kind: AymaToastKind.error);
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
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
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'ask_ayma',
                child: Text('Share this chat with Ayma'),
              ),
              PopupMenuItem(value: 'block', child: Text('Block & report')),
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
            child: StreamBuilder<List<DmMessage>>(
              stream: _dm.watchMessages(widget.threadId),
              builder: (context, snap) {
                final msgs = snap.data ?? const <DmMessage>[];
                _markReadIfIncoming(msgs);
                // Refresh the coaching chips/tip as the conversation grows —
                // debounced, and only on an actual message change (see
                // `_scheduleAssist`). A transient stream error leaves the last
                // suggestions in place rather than clearing them.
                if (!snap.hasError) _scheduleAssist(msgs);
                // A brand-new thread has no doc yet; the stream can be briefly
                // empty or (transiently) error — never hang the screen on it.
                if (msgs.isEmpty) {
                  if (snap.connectionState == ConnectionState.waiting &&
                      !snap.hasError) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  return Center(
                    child: Text(
                      'Say something.',
                      style: AymaType.sans(
                        size: 15,
                        soft: true,
                        color: ac.fgMute,
                      ),
                    ),
                  );
                }
                // `reverse: true` keeps the list pinned to the newest message
                // — without it the view stayed put while new bubbles landed
                // below the fold, half-clipped against the composer (founder
                // screenshot). The bottom inset matches the Ayma chat's, so
                // the last bubble clears the composer identically on both
                // screens; items are keyed by id so the reversed indexing
                // still animates each new bubble in once.
                return ListView.builder(
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
                  itemCount: msgs.length,
                  itemBuilder: (context, i) {
                    final m = msgs[msgs.length - 1 - i];
                    final bubble = _Bubble(message: m, mine: m.senderUid == me);
                    return FadeSlideIn(
                      key: ValueKey(m.id),
                      delay: staggerDelay(i),
                      offset: 8,
                      // Ayma's screen context carries only the newest few
                      // messages of a private conversation.
                      child: i < _kContextMessages
                          ? bubble
                          : NoScreenContext(child: bubble),
                    );
                  },
                );
              },
            ),
          ),
          if (_assist.chips.isNotEmpty || _visibleTip != null)
            CappedScroll(
              // Never let coaching take more than half the screen — past that
              // it scrolls inside the cap rather than squeezing out the list
              // or the composer.
              maxHeight: constraints.maxHeight * 0.5,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_assist.chips.isNotEmpty)
                    _SuggestionBar(
                      chips: _assist.chips,
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
              child: Row(
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
                  _sending
                      ? const Padding(
                          padding: EdgeInsets.all(8),
                          child: SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : IconButton.filled(
                          onPressed: _send,
                          icon: const Icon(Icons.arrow_upward_rounded),
                        ),
                ],
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

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.mine});
  final DmMessage message;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;

    final report = message.reportShare;
    final bool tight;
    final Widget content;
    if (message.isSharedReport && report != null) {
      tight = true;
      content = SharedReportCard(
        share: report,
        onTap: () => context.push('/s/${report.token}'),
      );
    } else if (message.hasImage) {
      tight = true;
      content = _image(context, ac);
    } else if (message.hasFile) {
      tight = false;
      content = _file(context, ac);
    } else {
      tight = false;
      final label = switch (message.type) {
        'photo' || 'image' => '📷 Photo',
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

    return ChatBubble(
      mine: mine,
      tight: tight,
      flagged: message.moderated,
      copyText: message.body,
      child: content,
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
                child: const CircularProgressIndicator(strokeWidth: 2),
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
