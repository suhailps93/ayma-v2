import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../services/api_client.dart';
import '../services/chat_inbox.dart';
import '../services/chat_service.dart';
import '../services/profile_service.dart';
import '../services/report_events.dart';
import '../theme.dart';
import '../widgets/ayma_photo.dart';
import '../widgets/ayma_wing_loader.dart';
import '../widgets/ayma_toast.dart';
import 'main_shell_screen.dart';

/// The two self-report RUN flows, opened directly from the Profile (You) tab
/// rows — there is no "Skills" menu page any more (founder Nov 16: the menu was
/// deleted; the rows go straight to the report, or to its run flow when there's
/// no report yet).
///
/// The web-search skill hands off to the Ayma chat (via [ChatInbox]) and runs
/// there ([runWebSearchFromProfile]). The Appearance skill instead opens a
/// pre-run sheet (Face/Body photo groups, per-group skip, a private Add-photo
/// tile), then runs the analysis directly and opens the resulting report
/// in-place — it does NOT open the chat (§ founder 2026-10-28). Photos added in
/// the sheet are uploaded privately and folded into that run only; they are
/// never added to the public profile grid.

/// Hand the web search off to the Ayma chat: ask for a name + an optional hint,
/// push a deep-dive kickoff into the chat inbox and jump to the chat shell. The
/// Profile tab's "Search the web about me" row calls this when no web-research
/// report exists yet. Best-effort prefills the name from the stored profile.
Future<void> runWebSearchFromProfile(
  BuildContext context, {
  ProfileService? profileService,
}) async {
  var fullName = '';
  try {
    final data = await (profileService ?? ProfileService()).readProfile();
    fullName = data?.fullName ?? '';
  } catch (_) {
    /* the dialog just opens with an empty name field */
  }
  if (!context.mounted) return;
  final nameCtrl = TextEditingController(text: fullName);
  final hintCtrl = TextEditingController();
  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      scrollable: true,
      title: const Text('Search the web about me'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: nameCtrl,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Your name'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: hintCtrl,
            decoration: const InputDecoration(
              labelText: 'Anything that helps',
              hintText: 'add anything that helps find the right you '
                  '(city, employer)',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          style: TextButton.styleFrom(minimumSize: const Size(0, 44)),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Search'),
        ),
      ],
    ),
  );
  if (go != true || !context.mounted) return;
  final name = nameCtrl.text.trim();
  final hint = hintCtrl.text.trim();
  final label = hint.isEmpty ? name : '$name — $hint';
  ChatInbox.instance.push(ChatKickoff.deepDive(
    label: label.isEmpty ? 'you' : label,
  ));
  context.go(MainShellScreen.path);
}

class _AppearanceChoice {
  const _AppearanceChoice({
    required this.wantFace,
    required this.wantBody,
    this.faceMediaIds,
    this.bodyMediaIds,
    this.imagePaths = const [],
  });

  final bool wantFace;
  final bool wantBody;
  final List<String>? faceMediaIds;
  final List<String>? bodyMediaIds;

  /// Privately-uploaded photos added in the sheet for this run only (storage
  /// paths under `uploads/{uid}/`). Folded into the vision pass as
  /// `image_paths` — they are NEVER added to the public profile grid (§ founder
  /// 2026-10-28 privacy fix).
  final List<String> imagePaths;
}

/// Show the Appearance pre-run sheet (the Face/Body photo groups) and, if the
/// user taps Run, kick off the appearance run with the chosen photos **in the
/// background** and let the user stay put or navigate away freely (§ founder
/// 2026-10-28: the analysis must run in the background again — tapping Back
/// must NOT cancel it, as a blocking dialog did). The run is fired as a
/// lifecycle-independent request: `POST /appearance/report` persists the report
/// and writes its `[appearance:<id>]` chat marker + bumps the `appearance/
/// current` pointer server-side regardless of what the UI does next, so the
/// report card simply updates when the run lands. We only surface a
/// non-blocking toast — never a modal the user can accidentally kill the run
/// by dismissing. Shared by the Skills-screen Appearance action and the
/// Appearance report screen's Re-run. Never hard-blocks: a skipped or empty
/// group simply doesn't run.
Future<void> runAppearanceFromPreRunSheet(
    BuildContext context, ApiClient api, {
  ChatService? chatService,
  Future<List<File>> Function()? pickImages,
  // How long to keep watching for a SLOW build to land after the POST exceeds
  // the client budget (see [_runAppearanceInBackground]), and how often to
  // check. Overridable so tests don't wait real minutes.
  Duration landingPollInterval = const Duration(seconds: 8),
  Duration landingPollTimeout = const Duration(minutes: 4),
}) async {
  final choice = await showModalBottomSheet<_AppearanceChoice>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => AppearancePreRunSheet(
      api: api,
      chatService: chatService,
      pickImages: pickImages,
    ),
  );
  if (choice == null || !context.mounted) return;
  // Both axes skipped / empty: nothing to run. (The Run button is still live,
  // so guard here rather than silently POSTing an empty run.)
  if (!choice.wantFace && !choice.wantBody) {
    AymaToast.show(context, 'Nothing selected to analyse.');
    return;
  }
  // Non-blocking acknowledgement, then fire-and-forget: the run is NOT tied to
  // this screen's lifecycle, so the user can leave (Back) and it keeps going.
  AymaToast.show(
    context,
    "Running your analysis — I'll update your report when it's ready.",
  );
  unawaited(_runAppearanceInBackground(
    context, api, choice,
    landingPollInterval: landingPollInterval,
    landingPollTimeout: landingPollTimeout,
  ));
}

/// Drives the appearance run to completion independently of any widget: the
/// HTTP request lives on the event loop, not the navigator, so navigating away
/// can't cancel it. Surfacing the outcome is best-effort — a still-mounted
/// caller gets a toast; a user who has moved on still gets the result via the
/// report card refresh (and the backend's chat marker), so nothing is lost.
Future<void> _runAppearanceInBackground(
    BuildContext context, ApiClient api, _AppearanceChoice choice,
    {required Duration landingPollInterval,
    required Duration landingPollTimeout}) async {
  // Capture which run is current BEFORE kicking off the build. A full
  // multi-photo face+body build regularly runs LONGER than the client POST
  // budget (`kLongTimeout`), so the POST times out (ApiException 408) while the
  // server keeps going and persists the report anyway. Because the "report is
  // ready" refresh signal (`completed`) used to fire ONLY on POST success, a
  // slow-but-successful build never refreshed the open report view in-session —
  // the card lagged minutes behind the landed node and only caught up on
  // relaunch (founder NOTE 245 Leg 1 follow-on, 2026-11-17). We detect the new
  // run by its id changing from this baseline, so a 408 refreshes the moment
  // the node lands instead of never.
  final before = await _currentAppearanceReportId(api);
  // Flip the shared "appearance running" flag so any open report view shows its
  // loading state (spinning Re-run + "Updating…") for the life of the run
  // (founder 2026-10-29: the run must visibly look like it's running).
  ReportEvents.instance.started('appearance');
  try {
    await api.runAppearanceReport(
      wantFace: choice.wantFace,
      wantBody: choice.wantBody,
      faceMediaIds: choice.wantFace ? choice.faceMediaIds : null,
      bodyMediaIds: choice.wantBody ? choice.bodyMediaIds : null,
      imagePaths: choice.imagePaths,
    );
    // The backend has persisted the report and bumped the `appearance/current`
    // pointer. Tell any open Appearance report screen / report card to re-fetch
    // so the fresh report shows without the user reloading (founder 2026-10-28:
    // "it didn't create a new report" when it actually had).
    ReportEvents.instance.completed('appearance');
    if (context.mounted) {
      AymaToast.show(context, 'Your Appearance report is ready.');
    }
  } on ApiException catch (e) {
    // A client timeout (408) on this known long-build endpoint is NOT a
    // failure: the server persists the report regardless. Wait for the new run
    // to actually land (its id changes from `before`), then fire the refresh —
    // so the open view updates promptly instead of only on relaunch.
    final landed = e.statusCode == 408 &&
        await _awaitAppearanceLanded(
            api, before, landingPollInterval, landingPollTimeout);
    if (landed) {
      ReportEvents.instance.completed('appearance');
      if (context.mounted) {
        AymaToast.show(context, 'Your Appearance report is ready.');
      }
    } else if (context.mounted) {
      AymaToast.show(
        context,
        "Couldn't finish the analysis. Please try again.",
        kind: AymaToastKind.error,
      );
    }
  } catch (_) {
    if (context.mounted) {
      AymaToast.show(
        context,
        "Couldn't finish the analysis. Please try again.",
        kind: AymaToastKind.error,
      );
    }
  } finally {
    // Clear the running state whether the run succeeded or failed, so the
    // loading indication never sticks on.
    ReportEvents.instance.stopped('appearance');
  }
}

/// The caller's current Appearance report id, or `` when there is none yet
/// (first-ever run) or the read fails — any landed run then counts as new.
Future<String> _currentAppearanceReportId(ApiClient api) async {
  try {
    return (await api.appearanceReport('current')).id;
  } catch (_) {
    // Best-effort baseline: a missing / unreadable current report just means
    // any run that lands next counts as new.
    return '';
  }
}

/// Poll the current Appearance report until a run NEWER than [before] lands
/// (its id differs), bounded by [timeout]. Returns whether a new run appeared.
/// Used only after a long-build POST timed out client-side while the server
/// kept building — so the open report view refreshes the instant the node
/// lands rather than waiting for a relaunch.
Future<bool> _awaitAppearanceLanded(
    ApiClient api, String before, Duration interval, Duration timeout) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    try {
      final id = (await api.appearanceReport('current')).id;
      if (id.isNotEmpty && id != before) return true;
    } catch (_) {
      // A transient read failure / not-ready read just means wait and retry.
    }
    if (!DateTime.now().isBefore(deadline)) return false;
    await Future<void>.delayed(interval);
  }
}

/// The pre-run sheet for the Appearance skill: the current grid photos grouped
/// into "Face analysis" and "Body analysis" as thumbnails, each group with a
/// skip toggle and an always-present "Add photo" tile. "Add photo" uploads the
/// picked image(s) PRIVATELY — to the caller's own `uploads/{uid}/` tree, the
/// same private channel chat attachments use — and folds them into THIS run
/// only via `image_paths`. It NEVER adds the photo to the public profile grid
/// or any public collection (§ founder 2026-10-28 privacy fix). Running never
/// forces a photo: a skipped or empty group simply doesn't run, and the report
/// shows an add-photo prompt for it rather than a bogus 0-score section.
class AppearancePreRunSheet extends StatefulWidget {
  const AppearancePreRunSheet({
    super.key,
    required this.api,
    this.chatService,
    this.pickImages,
  });

  final ApiClient api;

  /// The private upload channel for added photos; injectable for tests.
  /// Production uploads to `uploads/{uid}/` via [ChatService] (never the grid).
  final ChatService? chatService;

  /// Picks image files to add; injectable for tests. Production opens the OS
  /// gallery picker. Returns the picked files (empty when the user cancels).
  final Future<List<File>> Function()? pickImages;

  @override
  State<AppearancePreRunSheet> createState() => AppearancePreRunSheetState();
}

class AppearancePreRunSheetState extends State<AppearancePreRunSheet> {
  /// Max photos analysed per axis. All ticked photos for an axis are sent in
  /// ONE combined vision call; more than this wastes credits for diminishing
  /// returns. Mirrors the backend caps (`appearance._MAX_PHOTOS` and the
  /// `POST /appearance/report` `face_media_ids`/`body_media_ids` max length).
  static const int kMaxPerAxis = 6;

  AppearanceEligibility? _elig;
  bool _loading = true;
  bool _skipFace = false;
  bool _skipBody = false;

  /// Number of add-photo uploads still in flight per axis. Each in-flight
  /// upload renders one "Uploading…" spinner placeholder tile in that axis's
  /// strip; it is decremented (and replaced by the real tile, or dropped on
  /// failure) as each upload resolves. Counting — rather than a single bool —
  /// lets several concurrent adds each show their own spinner (§ founder
  /// 2026-10-28: the carousel must show the upload is happening).
  int _faceUploading = 0;
  int _bodyUploading = 0;

  late final ChatService _chat = widget.chatService ?? ChatService();

  /// The photos currently ticked for each axis — MULTI-select, up to
  /// [kMaxPerAxis]. All ticked photos for an axis are analysed TOGETHER in one
  /// combined read of the same person (§ founder: real multi-select). Grid
  /// photos are keyed by `media_id`; privately-added photos are keyed by their
  /// `uploads/{uid}/…` storage path (stored in [_faceAdded]/[_bodyAdded]). A tap
  /// on a tile toggles it in or out of the set, capped at [kMaxPerAxis].
  /// Selection is a local, in-sheet choice only and never navigates anywhere.
  /// To leave a section out, use Skip — a skipped section runs nothing
  /// regardless of its selection.
  final Set<String> _faceSel = <String>{};
  final Set<String> _bodySel = <String>{};

  /// Photos the user added in THIS sheet, uploaded privately (not on the grid).
  /// Represented as [EligiblePhoto] with `mediaId` = the private storage path,
  /// so they render in the strip exactly like grid photos but are passed to the
  /// run as `image_paths`, never as grid `media_id`s.
  final List<EligiblePhoto> _faceAdded = <EligiblePhoto>[];
  final List<EligiblePhoto> _bodyAdded = <EligiblePhoto>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final e = await widget.api.appearanceEligibility();
      if (mounted) setState(() => _applyEligibility(e));
    } catch (_) {
      // No groups on failure — the run still works (auto-pick server-side).
      if (mounted) setState(() => _applyEligibility(const AppearanceEligibility()));
    }
  }

  /// Fold a fresh eligibility read in. Multi-select: on first load each axis
  /// defaults to ALL the photos the server marked `autoSelect` — solo shots of
  /// the user that actually show that axis (§ founder 2026-10-28: a multi-person
  /// photo is never auto-selected, and a face-only photo is never auto-selected
  /// into Body), capped at [kMaxPerAxis]. The rest still render; the user can
  /// tick or untick any. A re-read preserves exactly the photos the user
  /// currently has chosen, so neither a changed default nor a manual pick is
  /// silently flipped. Privately-added photos (keyed by storage path) are
  /// preserved untouched — only grid `media_id`s are rebuilt here.
  void _applyEligibility(AppearanceEligibility e) {
    // First load (_elig == null): pre-select every auto-select photo for each
    // axis (capped). A re-read preserves exactly what the user currently has
    // selected among surfaced grid photos.
    final faceIds = _elig == null
        ? _autoSelectAll(e.face)
        : {
            for (final p in e.face)
              if (_faceSel.contains(p.mediaId)) p.mediaId,
          };
    final bodyIds = _elig == null
        ? _autoSelectAll(e.body)
        : {
            for (final p in e.body)
              if (_bodySel.contains(p.mediaId)) p.mediaId,
          };
    // Added-photo selections are keyed by storage path, not grid media_id, so
    // preserve them across the grid rebuild.
    final faceAddedSel = {
      for (final p in _faceAdded)
        if (_faceSel.contains(p.mediaId)) p.mediaId,
    };
    final bodyAddedSel = {
      for (final p in _bodyAdded)
        if (_bodySel.contains(p.mediaId)) p.mediaId,
    };
    _faceSel
      ..clear()
      ..addAll(faceIds)
      ..addAll(faceAddedSel);
    _bodySel
      ..clear()
      ..addAll(bodyIds)
      ..addAll(bodyAddedSel);
    _elig = e;
    _loading = false;
  }

  /// Every auto-select photo's id, capped at [kMaxPerAxis] in grid order — the
  /// multi-select default for an axis on first load (empty when none is
  /// auto-selected).
  static Set<String> _autoSelectAll(List<EligiblePhoto> photos) {
    final out = <String>{};
    for (final p in photos) {
      if (p.autoSelect) {
        out.add(p.mediaId);
        if (out.length >= kMaxPerAxis) break;
      }
    }
    return out;
  }

  /// Add a photo to [face] (true) or the Body group (false) PRIVATELY: pick
  /// image(s), upload each to the caller's own `uploads/{uid}/` tree (the
  /// private chat-attachment channel), and show them as pre-selected tiles in
  /// the group. The upload NEVER touches the public profile grid or any public
  /// collection — the photos ride the run as `image_paths` only (§ founder
  /// 2026-10-28 privacy fix). This is the ONLY place the sheet opens a picker;
  /// it does not navigate anywhere.
  Future<void> _addPhoto({required bool face}) async {
    final List<File> files;
    try {
      files = await (widget.pickImages?.call() ?? _defaultPick());
    } catch (_) {
      return; // Picker unavailable / cancelled — nothing to do.
    }
    if (files.isEmpty || !mounted) return;
    // Show one spinner placeholder per picked file straight away, so the strip
    // visibly reflects the in-flight upload (§ founder 2026-10-28). Concurrent
    // adds stack their own placeholders via these counters.
    setState(() {
      if (face) {
        _faceUploading += files.length;
      } else {
        _bodyUploading += files.length;
      }
    });
    var failures = 0;
    for (final f in files) {
      EligiblePhoto? photo;
      try {
        final up = await _chat.uploadImage(f, prefix: 'appearance');
        photo = EligiblePhoto(mediaId: up.storagePath, url: up.downloadUrl);
      } catch (_) {
        failures++;
      }
      if (!mounted) return;
      // Retire this upload's placeholder and, on success, swap in its tile
      // (pre-selected). On failure the placeholder simply disappears.
      setState(() {
        if (face) {
          _faceUploading--;
          if (photo != null) {
            _faceAdded.add(photo);
            // Multi-select: a freshly-added photo joins the Face selection
            // (unless that axis is already at the cap).
            if (_faceSel.length < kMaxPerAxis) _faceSel.add(photo.mediaId);
          }
        } else {
          _bodyUploading--;
          if (photo != null) {
            _bodyAdded.add(photo);
            // Multi-select: a freshly-added photo joins the Body selection
            // (unless that axis is already at the cap).
            if (_bodySel.length < kMaxPerAxis) _bodySel.add(photo.mediaId);
          }
        }
      });
    }
    if (failures > 0 && mounted) {
      AymaToast.show(
        context,
        failures == 1
            ? "Couldn't add that photo."
            : "Couldn't add $failures photos.",
        kind: AymaToastKind.error,
      );
    }
  }

  Future<List<File>> _defaultPick() async {
    final picked = await ImagePicker().pickMultiImage();
    return [for (final x in picked) File(x.path)];
  }

  /// Multi-select per axis: tapping a photo toggles it in or out of this axis's
  /// set, enforcing the [kMaxPerAxis] cap (a tap that would exceed it is a no-op
  /// with a brief hint). All ticked photos are analysed together. To leave a
  /// section out, use Skip; selection never navigates.
  void _toggle(Set<String> sel, String mediaId) {
    setState(() {
      if (sel.contains(mediaId)) {
        sel.remove(mediaId);
      } else if (sel.length < kMaxPerAxis) {
        sel.add(mediaId);
      } else {
        AymaToast.show(
          context,
          'Up to $kMaxPerAxis photos per section.',
          kind: AymaToastKind.info,
        );
      }
    });
  }

  void _run() {
    final e = _elig ?? const AppearanceEligibility();
    final faceIds = [
      for (final p in e.face)
        if (_faceSel.contains(p.mediaId)) p.mediaId,
    ];
    final bodyIds = [
      for (final p in e.body)
        if (_bodySel.contains(p.mediaId)) p.mediaId,
    ];
    // Privately-added photos ride along as image_paths (never grid media_ids).
    final faceAddedPaths = [
      for (final p in _faceAdded)
        if (_faceSel.contains(p.mediaId)) p.mediaId,
    ];
    final bodyAddedPaths = [
      for (final p in _bodyAdded)
        if (_bodySel.contains(p.mediaId)) p.mediaId,
    ];
    final faceRun = !_skipFace && (faceIds.isNotEmpty || faceAddedPaths.isNotEmpty);
    final bodyRun = !_skipBody && (bodyIds.isNotEmpty || bodyAddedPaths.isNotEmpty);
    final imagePaths = <String>{
      if (faceRun) ...faceAddedPaths,
      if (bodyRun) ...bodyAddedPaths,
    }.toList();
    Navigator.pop(
      context,
      _AppearanceChoice(
        wantFace: faceRun,
        wantBody: bodyRun,
        faceMediaIds: faceRun ? faceIds : null,
        bodyMediaIds: bodyRun ? bodyIds : null,
        imagePaths: imagePaths,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final e = _elig;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Your Appearance report',
              style: AymaType.serif(size: 20, color: ac.fg),
            ),
            const SizedBox(height: 4),
            Text(
              "Here are your photos, sorted into Face and Body. Tap to pick as "
              'many as you like per section (up to $kMaxPerAxis) — I read them '
              'together. Add another, or skip a section — never required.',
              style: AymaType.sans(size: 12.5, soft: true, color: ac.fgMute),
            ),
            const SizedBox(height: 8),
            // The single most important guidance: couple/group shots muddy the
            // read, so steer to solo photos up front (§ founder 2026-10-28).
            Text(
              'Use photos of just you — no other people.',
              style: AymaType.sans(
                  size: 12.5, weight: FontWeight.w600, color: ac.fgDim),
            ),
            const SizedBox(height: 16),
            if (_loading)
              // GET /appearance/eligibility still in flight.
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: AymaWingLoader(
                    size: 40,
                    lines: AymaLoaderLines.appearanceEligibility,
                  ),
                ),
              )
            else ...[
              _AxisGroup(
                title: 'Face analysis',
                icon: Icons.face_retouching_natural_outlined,
                guidance: 'Clear photos of your face.',
                photos: [...?e?.face, ..._faceAdded],
                uploadingCount: _faceUploading,
                selected: _faceSel,
                maxSel: kMaxPerAxis,
                skipped: _skipFace,
                emptyPrompt: 'Add a photo that clearly shows your face.',
                onToggleSkip: () => setState(() => _skipFace = !_skipFace),
                onTogglePhoto: (id) => _toggle(_faceSel, id),
                onAddPhoto: () => _addPhoto(face: true),
              ),
              const SizedBox(height: 16),
              _AxisGroup(
                title: 'Body analysis',
                icon: Icons.accessibility_new_outlined,
                guidance: 'Clear photos of your full body.',
                photos: [...?e?.body, ..._bodyAdded],
                uploadingCount: _bodyUploading,
                selected: _bodySel,
                maxSel: kMaxPerAxis,
                skipped: _skipBody,
                emptyPrompt: 'Add a full-body photo for a body report.',
                onToggleSkip: () => setState(() => _skipBody = !_skipBody),
                onTogglePhoto: (id) => _toggle(_bodySel, id),
                onAddPhoto: () => _addPhoto(face: false),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton(
                  onPressed: _run,
                  child: const Text('Run analysis'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One axis group inside [AppearancePreRunSheet]: its photos as a horizontal
/// strip of selectable thumbnails (dimmed when skipped), a skip/include toggle
/// when it has photos, and an "Add photo" tile that is ALWAYS present (both
/// axes, empty or not — § founder 2026-10-28). Multi-select: tapping a
/// thumbnail toggles it in or out of this axis's set (up to [maxSel]); all
/// ticked photos are analysed together — it never navigates. Only the explicit
/// "Add photo" tile opens the photo picker.
class _AxisGroup extends StatelessWidget {
  const _AxisGroup({
    required this.title,
    required this.icon,
    required this.guidance,
    required this.photos,
    required this.uploadingCount,
    required this.selected,
    required this.maxSel,
    required this.skipped,
    required this.emptyPrompt,
    required this.onToggleSkip,
    required this.onTogglePhoto,
    required this.onAddPhoto,
  });

  final String title;
  final IconData icon;

  /// One short line under the header saying what photos this axis wants.
  final String guidance;
  final List<EligiblePhoto> photos;

  /// How many add-photo uploads are still in flight for this axis; each renders
  /// a spinner placeholder tile in the strip (before the Add tile).
  final int uploadingCount;
  final Set<String> selected;

  /// Max photos tickable for this axis (the per-axis cap).
  final int maxSel;
  final bool skipped;
  final String emptyPrompt;
  final VoidCallback onToggleSkip;
  final void Function(String mediaId) onTogglePhoto;
  final VoidCallback onAddPhoto;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final hasPhotos = photos.isNotEmpty;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ac.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: ac.boundary),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: ac.fgDim),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: AymaType.sans(
                      size: 14, weight: FontWeight.w600, color: ac.fg),
                ),
              ),
              if (hasPhotos)
                TextButton(
                  onPressed: onToggleSkip,
                  style: TextButton.styleFrom(minimumSize: const Size(0, 44)),
                  child: Text(skipped ? 'Include' : 'Skip'),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            hasPhotos && !skipped && selected.isNotEmpty
                ? '$guidance  ·  ${selected.length} selected'
                    '${selected.length >= maxSel ? ' (max)' : ''}'
                : guidance,
            style: AymaType.sans(size: 12, soft: true, color: ac.fgDim),
          ),
          const SizedBox(height: 8),
          if (!hasPhotos)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                emptyPrompt,
                style: AymaType.sans(size: 12.5, color: ac.fgDim),
              ),
            ),
          Opacity(
            opacity: skipped ? 0.4 : 1.0,
            child: SizedBox(
              height: 64,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                // Strip order: existing tiles, then one spinner per in-flight
                // upload, then the always-present Add tile.
                itemCount: photos.length + uploadingCount + 1,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, i) {
                  if (i < photos.length) {
                    final p = photos[i];
                    return _PhotoTile(
                      url: p.url,
                      isSelected: selected.contains(p.mediaId),
                      // Selecting is dimmed visually while skipped, but the tap
                      // still toggles this photo so the choice is ready if they
                      // un-skip.
                      onTap: () => onTogglePhoto(p.mediaId),
                    );
                  }
                  if (i < photos.length + uploadingCount) {
                    return const _UploadingTile();
                  }
                  return _AddPhotoTile(onTap: onAddPhoto);
                },
              ),
            ),
          ),
          if (skipped && hasPhotos)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                "Skipped — I won't run this section.",
                style: AymaType.sans(size: 11.5, color: ac.fgDim),
              ),
            ),
        ],
      ),
    );
  }
}

/// A selectable thumbnail in an [_AxisGroup]. A tap toggles this photo in or
/// out of the axis's set via [onTap] — it NEVER navigates (§ founder
/// 2026-10-28: tapping a photo in the analysis sheet must only pick it).
/// Unselected tiles dim and lose the check badge.
class _PhotoTile extends StatelessWidget {
  const _PhotoTile({
    required this.url,
    required this.isSelected,
    required this.onTap,
  });

  final String url;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Semantics(
      button: true,
      selected: isSelected,
      label: isSelected
          ? 'Photo selected for analysis, tap to remove'
          : 'Tap to add this photo to the analysis',
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        child: SizedBox(
          width: 64,
          height: 64,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Opacity(
                  opacity: isSelected ? 1.0 : 0.45,
                  child: AymaPhoto(
                    url: url,
                    fit: BoxFit.cover,
                    displayWidth: 64,
                  ),
                ),
              ),
              if (isSelected)
                DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: ac.accent, width: 2),
                  ),
                ),
              Positioned(
                top: 4,
                right: 4,
                child: Container(
                  decoration: BoxDecoration(
                    color: isSelected ? ac.accent : ac.bg.withValues(alpha: 0.7),
                    shape: BoxShape.circle,
                  ),
                  padding: const EdgeInsets.all(2),
                  child: Icon(
                    isSelected ? Icons.check : Icons.circle_outlined,
                    size: 13,
                    color: isSelected ? ac.onAccent : ac.fgMute,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The always-present "Add photo" tile at the end of an [_AxisGroup]'s strip:
/// the ONLY element in the sheet that opens the photo picker.
class _AddPhotoTile extends StatelessWidget {
  const _AddPhotoTile({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Semantics(
      button: true,
      label: 'Add photo',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: ac.lineSoft),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.add_a_photo_outlined, size: 18, color: ac.fgDim),
              const SizedBox(height: 4),
              Text('Add', style: AymaType.sans(size: 10, color: ac.fgMute)),
            ],
          ),
        ),
      ),
    );
  }
}

/// A placeholder tile shown in an [_AxisGroup]'s strip while an added photo is
/// still uploading: a small spinner over "Uploading…", same 64px footprint as
/// a real thumbnail so the strip doesn't jump when the tile swaps in. One of
/// these shows per in-flight upload (§ founder 2026-10-28: the carousel must
/// show the upload is happening, not sit blank).
class _UploadingTile extends StatelessWidget {
  const _UploadingTile();

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Semantics(
      label: 'Uploading photo',
      excludeSemantics: true,
      child: Container(
        width: 64,
        height: 64,
        decoration: BoxDecoration(
          color: ac.bg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: ac.lineSoft),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Storage photo upload in flight — tile slot, wings only.
            AymaWingLoader(size: 16, showLabel: false, color: ac.fgDim),
            const SizedBox(height: 4),
            Text('Uploading…', style: AymaType.sans(size: 9, color: ac.fgMute)),
          ],
        ),
      ),
    );
  }
}

