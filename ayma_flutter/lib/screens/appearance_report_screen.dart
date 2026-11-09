import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../models/appearance_card.dart';
import '../models/living_report.dart';
import '../services/api_client.dart';
import '../services/app_context.dart';
import '../services/profile_service.dart';
import '../services/report_card_share.dart';
import '../services/share_kit.dart';
import '../widgets/ayma_share_sheet.dart';
import '../services/report_events.dart';
import '../theme.dart';
import '../widgets/appearance_report_card.dart';
import '../widgets/ayma_back_button.dart';
import '../widgets/ayma_toast.dart';
import '../widgets/ayma_wing_loader.dart';
import '../widgets/living_report_view.dart';
import 'skills_screen.dart';

/// The caller's unified Appearance report: the shareable report card on top
/// (photos, Face and Body scores, positive findings), one Share button, the
/// private "What to do next" list, then the full report without its
/// recommendations (structured attributes plus an honest face analysis and an honest physique analysis).
/// Re-opened from an `[appearance:<id>]` chat marker, the chat report card,
/// or the Skills screen's "View my report" link.
///
/// The full report is the ONE shared [LivingReportView] renderer (§ generic
/// reports), embedded (`shrinkWrap`) so the whole screen scrolls as one
/// region. `report_hub.resolve_owner` treats "appearance"'s `{report_id}` as
/// the subject's own uid (there is only ever one current Appearance report
/// per user) — [reportId] (an older, possibly-stale marker id from before
/// that convergence) is kept only as a fallback for the rare case the caller
/// can't be resolved to a signed-in uid.
///
/// GUARDRAIL (see `living_report_view.dart`'s file doc): the card is a share
/// artifact built from the report's own blocks, not a second renderer of
/// them; it is only offered when both scores exist, and never shows
/// recommendations or anything but strengths.
class AppearanceReportScreen extends StatefulWidget {
  const AppearanceReportScreen({
    super.key,
    required this.reportId,
    this.apiClient,
    this.myUid,
    this.profileService,
    this.imageFor,
    this.shareService,
  });

  static const path = '/appearance/:id';

  final String reportId;
  final ApiClient? apiClient;

  /// Injectable for tests; production reads the signed-in Firebase uid.
  final String? myUid;

  /// Injectable for tests; production reads the signed-in user's profile.
  final ProfileService? profileService;

  /// Injectable for tests; production loads photos through the same disk
  /// cache every other photo in the app uses.
  final ImageProvider Function(String url)? imageFor;
  final ReportCardShare? shareService;

  @override
  State<AppearanceReportScreen> createState() => _AppearanceReportScreenState();
}

class _AppearanceReportScreenState extends State<AppearanceReportScreen>
    with ScreenContextReasserter<AppearanceReportScreen> {
  AppearanceCardData? _card;

  /// The version stamp (the report's `created_at`) of the exact run
  /// currently on screen, captured with the card in [_onReport]. A
  /// Send-to-Ayma share carries it in the reference so Ayma pulls THIS
  /// run — a re-run replaces the record wholesale, and the stamp is how
  /// the backend tells the shared run from a silent swap (founder,
  /// 2026-11-09).
  String _reportCreatedAt = '';

  /// Every analysed photo in the card's pool, decoded and keyed by url (the
  /// whole pool, not just the four shown, so removing a photo slides the next
  /// one in with no re-decode). A url absent here failed to decode.
  Map<String, DecodedImage> _decoded = const {};
  String _name = 'You';
  int _loadGen = 0;

  /// The sharer's referral code, folded into the smart link in the caption.
  /// Best-effort: null when unknown (offline, no referral, or no API).
  String? _refCode;

  /// True while the card image is being rendered for a share, so the Share
  /// button shows a spinner and a second tap can't start a second render.
  bool _sharing = false;

  late final ReportCardShare _share = widget.shareService ?? ReportCardShare();

  ImageProvider _image(String url) =>
      widget.imageFor?.call(url) ?? CachedNetworkImageProvider(url);

  ApiClient get _api => widget.apiClient ?? ApiClient();

  /// The pool photos the card actually shows now: not hidden, decoded, capped
  /// at [AppearanceCardData.maxPhotos]. A hidden or undecodable photo is
  /// skipped and the next pooled one takes its place.
  List<CardPhoto> _shownPool() {
    final c = _card;
    if (c == null) return const [];
    final out = <CardPhoto>[];
    for (final p in c.pool) {
      if (c.hidden.contains(p.id) || _decoded[p.url] == null) continue;
      out.add(p);
      if (out.length == AppearanceCardData.maxPhotos) break;
    }
    return out;
  }

  List<(ImageProvider, String)> _shownImages() => [
    for (final p in _shownPool()) (_decoded[p.url]!, p.label),
  ];

  /// Rebuilds the screen when an appearance run starts/stops so the Re-run
  /// control and the "Updating…" banner reflect the live run state.
  void _onReportEvents() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    reassertScreenContext();
    _loadName();
    _loadReferralCode();
    ReportEvents.instance.addListener(_onReportEvents);
  }

  Future<void> _loadReferralCode() async {
    try {
      final r = await (widget.apiClient ?? ApiClient()).referral();
      if (mounted && r.code.isNotEmpty) setState(() => _refCode = r.code);
    } catch (_) {
      // No referral yet, offline, or zero-credit: the plain /get link is used.
    }
  }

  // No logo decode step: the card's mark is the canonical painted orb
  // (AymaOrbMark), which draws synchronously in the card's accent, so the
  // PNG export captures it on the first frame exactly like the photos.

  String? _liveUid() {
    try {
      return FirebaseAuth.instance.currentUser?.uid;
    } catch (_) {
      // No Firebase app configured (shouldn't happen in the real app, but
      // never crash the whole screen over it) — falls through to [reportId].
      return null;
    }
  }

  static String _firstWord(String s) => s.trim().split(RegExp(r'\s+')).first;

  Future<void> _loadName() async {
    String name = '';
    try {
      final profile = await (widget.profileService ?? ProfileService())
          .readProfile();
      name = _firstWord(
        profile?.firstName.isNotEmpty == true
            ? profile!.firstName
            : profile?.name ?? '',
      );
    } catch (_) {
      // No profile yet or offline: fall back to the account name below.
    }
    if (name.isEmpty) {
      try {
        name = _firstWord(FirebaseAuth.instance.currentUser?.displayName ?? '');
      } catch (_) {
        // No Firebase app (tests): keep the neutral fallback.
      }
    }
    if (mounted && name.isNotEmpty) setState(() => _name = name);
  }

  Future<void> _onReport(LivingReport report) async {
    final gen = ++_loadGen;
    final card = AppearanceCardData.fromReport(report);
    if (card == null) {
      final old = _decoded;
      setState(() {
        _card = null;
        _reportCreatedAt = '';
        _decoded = const {};
      });
      _release(old);
      reassertScreenContext();
      return;
    }
    // Decode the WHOLE pool (not just the four shown) so a remove can slide
    // the next photo in instantly, with no await and no flicker.
    final urls = [for (final p in card.pool) p.url];
    final decoded = await Future.wait([
      for (final url in urls) ReportCardShare.decode(_image(url)),
    ]);
    final map = <String, DecodedImage>{};
    for (var i = 0; i < urls.length; i++) {
      final img = decoded[i];
      if (img != null) map[urls[i]] = DecodedImage(img);
    }
    if (!mounted || gen != _loadGen) {
      _release(map);
      return;
    }
    final old = _decoded;
    setState(() {
      // Photos are always on the card; with none loadable it isn't offered.
      _decoded = map;
      _card = map.isEmpty ? null : card;
      _reportCreatedAt =
          map.isEmpty ? '' : (report.meta.createdAt ?? '');
    });
    _release(old);
    reassertScreenContext();
  }

  /// Removes photo [shownIndex] (an index into [_shownImages]) from the card:
  /// the next pooled photo slides in, or the card shrinks when the pool is
  /// spent. Card-only — the photo and its analysis are untouched. A quick
  /// Undo toast restores it; both the choice and the undo persist to the
  /// profile so the card (and the shared image) stay in sync across sessions.
  void _removePhoto(int shownIndex) {
    final c = _card;
    final shown = _shownPool();
    if (c == null || shownIndex < 0 || shownIndex >= shown.length) return;
    final prev = c.hidden;
    _applyHidden({...prev, shown[shownIndex].id});
    AymaToast.show(
      context,
      'Removed from card',
      action: AymaToastAction(label: 'Undo', onPressed: () => _applyHidden(prev)),
    );
  }

  void _applyHidden(Set<String> next) {
    final c = _card;
    if (c == null) return;
    setState(() => _card = c.withHidden(next));
    reassertScreenContext();
    unawaited(_persistHidden(next));
  }

  Future<void> _persistHidden(Set<String> ids) async {
    final toaster = AymaToast.of(context);
    try {
      await _api.setReportCardHiddenPhotos(ids.toList());
    } catch (_) {
      // The local change stands; it just may not survive a restart. Tell the
      // user rather than fail silently.
      toaster.show(
        "Couldn't save that change.",
        kind: AymaToastKind.error,
      );
    }
  }

  /// Frees decoded photos once nothing shows them any more.
  static void _release(Map<String, DecodedImage> photos) {
    for (final p in photos.values) {
      PaintingBinding.instance.imageCache.evict(p);
      p.image.dispose();
    }
  }

  @override
  void dispose() {
    ReportEvents.instance.removeListener(_onReportEvents);
    _release(_decoded);
    super.dispose();
  }

  @override
  void reassertScreenContext() {
    final c = _card;
    final shown = _shownPool().length;
    AppContext.instance.set(
      screen: 'appearance_report',
      detail: c == null || shown == 0
          ? ''
          : 'Top: your shareable report card ($shown photos, each with a '
                'Remove-from-card (X) control, '
                'Face ${c.faceScore}${c.faceVerdict.isEmpty ? '' : ' ${c.faceVerdict.toLowerCase()}'}, '
                'Body ${c.bodyScore}${c.bodyVerdict.isEmpty ? '' : ' ${c.bodyVerdict.toLowerCase()}'}'
                '${c.standOuts.isEmpty ? '' : ', stands out: ${c.standOuts.join('; ')}'}). '
                'Below it a Share button (WhatsApp, Instagram, Save image, More…), '
                'then the private "What to do next" list, then the full report.',
    );
  }

  /// [onRemove] is passed only for the live on-screen card; the exported PNG
  /// (the shared picture) is rendered without it, so the X controls never
  /// appear in what gets shared.
  AppearanceReportCard _cardWidget(
    AppearanceCardData card,
    Color accent, {
    void Function(int index)? onRemove,
  }) => AppearanceReportCard(
    data: card,
    name: _name,
    accent: accent,
    photos: _shownImages(),
    onRemovePhoto: onRemove,
  );

  @override
  Widget build(BuildContext context) {
    final resolvedMyUid = widget.myUid ?? _liveUid() ?? '';
    final uid = resolvedMyUid.isNotEmpty ? resolvedMyUid : widget.reportId;
    final card = _card;
    // No card when every analysed photo has been removed from it (the pool is
    // spent): fall back to the normal report, consistent with the no-score /
    // no-photo rule.
    final showCard = card != null && _shownPool().isNotEmpty;
    final ac = context.ac;
    // A run fired from here (or the Skills screen) is in flight: show it IS
    // running — a spinner in place of the Re-run icon and an "Updating…" banner
    // over the (still-visible) current report (founder 2026-10-29).
    final running = ReportEvents.instance.isRunning('appearance');
    return Scaffold(
      appBar: AppBar(
        leading: const AymaBackButton(),
        title: const Text('Appearance'),
        actions: [
          // Re-run opens the same pre-run sheet the Skills screen uses: your
          // current photos grouped into Face / Body, with a per-group skip and
          // an add-photo prompt for an empty group. While a run is in flight the
          // control shows a spinner and is disabled so a second run can't stack.
          IconButton(
            tooltip: running ? 'Running your analysis…' : 'Re-run',
            onPressed: running
                ? null
                : () => runAppearanceFromPreRunSheet(
                    context, widget.apiClient ?? ApiClient()),
            // POST /appearance/report in flight — icon slot, wings only.
            icon: running
                ? const AymaWingLoader(size: 20, showLabel: false)
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        children: [
          if (running) const _UpdatingBanner(),
          if (showCard) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: AppearanceReportCard.width,
                  ),
                  child: Semantics(
                    container: true,
                    label: 'Your Appearance report card',
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(18),
                        boxShadow: [
                          BoxShadow(
                            color: ReportCardColors.shadow.withAlpha(0x40),
                            blurRadius: 34,
                            offset: const Offset(0, 14),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(18),
                        child: AspectRatio(
                          aspectRatio:
                              AppearanceReportCard.width /
                              AppearanceReportCard.height,
                          child: FittedBox(
                            child: _cardWidget(
                              card,
                              ac.accent,
                              onRemove: _removePhoto,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Semantics(
                button: true,
                label: 'Share',
                hint: 'Share your report card image',
                excludeSemantics: true,
                onTap: _sharing ? null : () => _openShareSheet(card, ac.accent, uid),
                child: SizedBox(
                  height: 48,
                  child: FilledButton.icon(
                    key: const ValueKey('reportCardShare'),
                    onPressed:
                        _sharing ? null : () => _openShareSheet(card, ac.accent, uid),
                    // Report-card PNG render + share sheet — wings only.
                    icon: _sharing
                        ? const AymaWingLoader(size: 18, showLabel: false)
                        : const Icon(Icons.ios_share),
                    label: const Text('Share'),
                  ),
                ),
              ),
            ),
            if (card.nextSteps.isNotEmpty) _NextSteps(steps: card.nextSteps),
          ],
          LivingReportView(
            // Stable key so toggling the card block above (removing the last
            // photo) never shifts this view's slot and remounts it — a remount
            // would refetch and reset the card's in-session hidden set,
            // flashing removed photos back.
            key: const ValueKey('appearanceFullReport'),
            reportType: 'appearance',
            reportId: uid,
            apiClient: widget.apiClient,
            shrinkWrap: true,
            hideBlock: AppearanceCardData.isRecommendation,
            onLoaded: _onReport,
          ),
        ],
      ),
    );
  }

  /// The big Share button runs on the shared share kit (founder,
  /// 2026-11-08): the sheet offers "Send to Ayma" — the report as a
  /// reply-style card in the Ayma chat — and "Send externally", which is
  /// [_openShare] below, unchanged: the CURRENT run's rendered card image
  /// with its caption through the system share sheet. (The card is built
  /// from the live on-screen run, never a cached older one, and the
  /// private "What to do next" section is never part of it.)
  void _openShareSheet(AppearanceCardData card, Color accent, String uid) {
    showAymaShareSheet(
      context,
      ShareTargets.appearance(
        uid: uid,
        title: 'Your appearance report',
        photoUrl: card.photoUrls.isEmpty ? '' : card.photoUrls.first,
        reportVersion: _reportCreatedAt,
        externalOverride: (_) => _openShare(card, accent),
      ),
    );
  }

  /// Renders the card image and opens the native OS share sheet — the
  /// kit's external path for this page. The user picks the destination
  /// (WhatsApp, Instagram, Messages, save-to-photos, …) there; Ayma targets no
  /// single app itself.
  Future<void> _openShare(AppearanceCardData card, Color accent) async {
    if (_sharing) return;
    final toast = AymaToast.of(context);
    // iPad share-popover anchor: the Share button's rect, read before awaits.
    final box = context.findRenderObject() as RenderBox?;
    final origin =
        box != null ? box.localToGlobal(Offset.zero) & box.size : null;
    final view = View.of(context);
    setState(() => _sharing = true);
    try {
      await _share.shareCard(
        _cardWidget(card, accent),
        view: view,
        logicalSize: AppearanceReportCard.size,
        caption: ReportCardShare.captionFor(_refCode),
        origin: origin,
      );
    } catch (_) {
      toast.show("Couldn't share that right now.", kind: AymaToastKind.error);
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }
}

/// A slim banner shown at the top of the report while a background run is in
/// flight, so the current (soon-to-be-replaced) report doesn't just sit there
/// looking static. Pairs with the spinning Re-run control (founder 2026-10-29).
class _UpdatingBanner extends StatelessWidget {
  const _UpdatingBanner();

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Semantics(
      liveRegion: true,
      label: 'Updating your appearance report',
      child: Container(
        width: double.infinity,
        color: ac.bgElev,
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
        child: Row(
          children: [
            const AymaWingLoader(size: 16, showLabel: false),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Updating your report…',
                style: AymaType.sans(size: 13, color: ac.fg),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The recommendations, privately, under the card. Never on the card.
class _NextSteps extends StatelessWidget {
  const _NextSteps({required this.steps});

  final List<(String, String)> steps;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              'What to do next',
              style: AymaType.serif(size: 28, color: ac.fg),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Only you see this. It is never part of the shared card.',
            style: AymaType.sans(size: 12.5, color: ac.fgMute),
          ),
          const SizedBox(height: 12),
          for (final (category, text) in steps)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: ac.bgElev,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: ac.lineSoft),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    category.toUpperCase(),
                    style: AymaType.mono(size: 9.5, color: ac.fgMute),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    text,
                    style: AymaType.sans(
                      size: 13.5,
                      height: 1.35,
                      color: ac.fg,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
