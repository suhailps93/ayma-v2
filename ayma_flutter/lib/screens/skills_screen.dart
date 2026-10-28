import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/api_client.dart';
import '../services/app_context.dart';
import '../services/chat_inbox.dart';
import '../services/profile_service.dart';
import '../theme.dart';
import '../widgets/ayma_orb.dart';
import '../widgets/ayma_photo.dart';
import 'my_public_profile_screen.dart';
import 'main_shell_screen.dart';
import 'plan_screen.dart';
import '../widgets/ayma_back_button.dart';

/// Things Ayma can do on demand about *you* — search the web, and one unified
/// "Appearance" read of your photos (structured attributes + an honest face and
/// physique analysis). The run screen the Profile tab's "Search the web
/// about me" and "Appearance" rows open when there's no report yet.
///
/// Pressing a skill hands off to the Ayma chat (via [ChatInbox]) and runs there
/// — no blocking spinner on this screen. For the Appearance skill the
/// photo-source choice ("use what I have" / "add photos") and a coverage line
/// (do we have a face photo / a body photo?) are resolved *here*, before
/// the hand-off, so the chat runs the skill straight away.
class SkillsScreen extends StatefulWidget {
  const SkillsScreen({
    super.key,
    this.profileService,
    this.api,
  });

  static const path = '/skills';

  final ProfileService? profileService;
  final ApiClient? api;

  @override
  State<SkillsScreen> createState() => _SkillsScreenState();
}

class _SkillsScreenState extends State<SkillsScreen>
    with ScreenContextReasserter<SkillsScreen> {
  late final ProfileService _profiles =
      widget.profileService ?? ProfileService();
  late final ApiClient _api = widget.api ?? ApiClient();

  ProfileData? _profile;

  @override
  void initState() {
    super.initState();
    reassertScreenContext();
    _load();
  }

  @override
  void reassertScreenContext() => AppContext.instance.set(screen: 'skills');

  Future<void> _load() async {
    try {
      final data = await _profiles.readProfile();
      if (mounted) setState(() => _profile = data);
    } catch (_) {
      /* the web-search dialog just opens with an empty name field */
    }
  }

  // --- Web search --------------------------------------------------------

  Future<void> _searchWeb() async {
    final nameCtrl = TextEditingController(text: _profile?.fullName ?? '');
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
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Search'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    final name = nameCtrl.text.trim();
    final hint = hintCtrl.text.trim();
    final label = hint.isEmpty ? name : '$name — $hint';
    ChatInbox.instance.push(ChatKickoff.deepDive(
      label: label.isEmpty ? 'you' : label,
    ));
    context.go(MainShellScreen.path);
  }

  // --- Appearance -------------------------------------------------------

  /// The Appearance skill — see [runAppearanceFromPreRunSheet].
  Future<void> _runAppearance() => runAppearanceFromPreRunSheet(context, _api);

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(
        leading: const AymaBackButton(),
        title: const Text('Skills')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          _SkillCard(
            icon: Icons.travel_explore,
            title: 'Search the web about me',
            body: "Ayma looks you up online so you don't have to repeat "
                'yourself, then confirms what she found in chat.',
            onTap: _searchWeb,
            history: _WebSearchReportLink(api: widget.api),
          ),
          _SkillCard(
            icon: Icons.auto_awesome_outlined,
            title: 'Appearance',
            body: 'A full read of your photos: your structured attributes '
                'plus an honest face and physique analysis.',
            onTap: _runAppearance,
            history: _AppearanceReportLink(api: widget.api),
          ),
          const SizedBox(height: 20),
          Text(
            'Each run uses credits based on the work it does — a longer '
            'photo set or a hard-to-find name uses a bit more.',
            style: AymaType.sans(size: 12, soft: true, color: ac.fgMute),
          ),
          const SizedBox(height: 20),
          _CreditsRow(api: widget.api),
        ],
      ),
    );
  }
}

/// A subtle, always-present credits line at the foot of the Skills screen: the
/// live balance and a one-tap route to the reload screen, so topping up is
/// never a hunt even when nothing is capped. Renders "Credits" (no number)
/// until the balance loads and stays silent on error.
class _CreditsRow extends StatefulWidget {
  const _CreditsRow({this.api});

  final ApiClient? api;

  @override
  State<_CreditsRow> createState() => _CreditsRowState();
}

class _CreditsRowState extends State<_CreditsRow> {
  late final ApiClient _api = widget.api ?? ApiClient();
  int? _remaining;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final u = await _api.usage();
      if (mounted) setState(() => _remaining = u.creditsRemaining);
    } catch (_) {
      /* silent — the row still routes to the full screen */
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final n = _remaining;
    return InkWell(
      onTap: () => context.push(PlanScreen.path),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Row(
          children: [
            Icon(Icons.toll_rounded,
                size: 15, color: n == 0 ? ac.error : ac.fgMute),
            const SizedBox(width: 8),
            Text(
              n == null ? 'Credits' : '$n credits left',
              style: AymaType.sans(
                  size: 12, color: n == 0 ? ac.error : ac.fgDim),
            ),
            const Spacer(),
            Text('Upgrade',
                style: AymaType.mono(size: 11, color: ac.accent)
                    .copyWith(letterSpacing: 0.5)),
            Icon(Icons.chevron_right, size: 16, color: ac.accent),
          ],
        ),
      ),
    );
  }
}

/// The choice the Appearance pre-run sheet returns: which axes to run and the
/// exact grid photos chosen for each (empty/null when that axis is skipped or
/// has no eligible photo).
class _AppearanceChoice {
  const _AppearanceChoice({
    required this.wantFace,
    required this.wantBody,
    this.faceMediaIds,
    this.bodyMediaIds,
  });

  final bool wantFace;
  final bool wantBody;
  final List<String>? faceMediaIds;
  final List<String>? bodyMediaIds;
}

/// Show the Appearance pre-run sheet (the Face/Body photo groups) and, if the
/// user taps Run, hand a fully-specified [ChatKickoff.appearance] to the Ayma
/// chat and navigate to the shell. Shared by the Skills-screen Appearance
/// action and the Appearance report screen's Re-run, so both entry points show
/// the same grouping and skip/add-photo choices. Never hard-blocks: a skipped
/// or empty group simply doesn't run.
Future<void> runAppearanceFromPreRunSheet(
    BuildContext context, ApiClient api) async {
  final choice = await showModalBottomSheet<_AppearanceChoice>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => AppearancePreRunSheet(api: api),
  );
  if (choice == null || !context.mounted) return;
  ChatInbox.instance.push(ChatKickoff.appearance(
    wantFace: choice.wantFace,
    wantBody: choice.wantBody,
    faceMediaIds: choice.wantFace ? choice.faceMediaIds : null,
    bodyMediaIds: choice.wantBody ? choice.bodyMediaIds : null,
  ));
  if (context.mounted) context.go(MainShellScreen.path);
}

/// The pre-run sheet for the Appearance skill: the current grid photos grouped
/// into "Face analysis" and "Body analysis" as thumbnails, each group with a
/// skip toggle, and — for an empty group — a clear "add the missing kind"
/// prompt that reuses the real add-photo flow (the inline photo carousel on
/// My public profile, [MyPublicProfileScreen.editPhotosPath]). Running
/// never forces a photo: a skipped or empty group simply doesn't run, and the
/// report shows an add-photo prompt for it rather than a bogus 0-score section.
class AppearancePreRunSheet extends StatefulWidget {
  const AppearancePreRunSheet({super.key, required this.api});

  final ApiClient api;

  @override
  State<AppearancePreRunSheet> createState() => AppearancePreRunSheetState();
}

class AppearancePreRunSheetState extends State<AppearancePreRunSheet> {
  AppearanceEligibility? _elig;
  bool _loading = true;
  bool _skipFace = false;
  bool _skipBody = false;

  /// The photos currently selected for each axis (by `media_id`). Every photo
  /// in a bucket starts selected; a tap on a tile toggles it — selection is a
  /// local, in-sheet choice only and never navigates anywhere (§ founder
  /// 2026-10-28). A skipped section runs nothing regardless of its selection.
  final Set<String> _faceSel = <String>{};
  final Set<String> _bodySel = <String>{};

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

  /// Fold a fresh eligibility read in: default every pooled photo to selected,
  /// but keep any photo the user had already deselected this session so a
  /// re-read after adding a photo doesn't silently re-check their choices.
  void _applyEligibility(AppearanceEligibility e) {
    final faceIds = {for (final p in e.face) p.mediaId};
    final bodyIds = {for (final p in e.body) p.mediaId};
    final faceDeselected = {
      for (final p in e.face)
        if (_elig != null && !_faceSel.contains(p.mediaId)) p.mediaId,
    };
    final bodyDeselected = {
      for (final p in e.body)
        if (_elig != null && !_bodySel.contains(p.mediaId)) p.mediaId,
    };
    _faceSel
      ..clear()
      ..addAll(faceIds.difference(faceDeselected));
    _bodySel
      ..clear()
      ..addAll(bodyIds.difference(bodyDeselected));
    _elig = e;
    _loading = false;
  }

  Future<void> _addPhoto() async {
    // Reuse the real add-photo flow: the inline photo carousel on My public
    // profile, opened straight into its photo picker. On return, re-read
    // eligibility so a freshly-added photo shows in both groups (the backend
    // honours the user's pick even before it is shot-type classified).
    await context.push(MyPublicProfileScreen.editPhotosPath);
    if (!mounted) return;
    setState(() => _loading = true);
    await _load();
  }

  void _toggle(Set<String> sel, String mediaId) {
    setState(() {
      if (!sel.remove(mediaId)) sel.add(mediaId);
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
    final faceRun = !_skipFace && faceIds.isNotEmpty;
    final bodyRun = !_skipBody && bodyIds.isNotEmpty;
    Navigator.pop(
      context,
      _AppearanceChoice(
        wantFace: faceRun,
        wantBody: bodyRun,
        faceMediaIds: faceRun ? faceIds : null,
        bodyMediaIds: bodyRun ? bodyIds : null,
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
              "Here are your photos, sorted into Face and Body. Tap one to "
              'leave it out, add another, or skip a section — never required.',
              style: AymaType.sans(size: 12.5, soft: true, color: ac.fgMute),
            ),
            const SizedBox(height: 16),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: AymaOrb(size: 40, state: AymaOrbState.thinking),
                ),
              )
            else ...[
              _AxisGroup(
                title: 'Face analysis',
                icon: Icons.face_retouching_natural_outlined,
                photos: e?.face ?? const [],
                selected: _faceSel,
                skipped: _skipFace,
                emptyPrompt: 'Add a photo that clearly shows your face.',
                onToggleSkip: () => setState(() => _skipFace = !_skipFace),
                onTogglePhoto: (id) => _toggle(_faceSel, id),
                onAddPhoto: _addPhoto,
              ),
              const SizedBox(height: 16),
              _AxisGroup(
                title: 'Body analysis',
                icon: Icons.accessibility_new_outlined,
                photos: e?.body ?? const [],
                selected: _bodySel,
                skipped: _skipBody,
                emptyPrompt: 'Add a full-body photo for a body report.',
                onToggleSkip: () => setState(() => _skipBody = !_skipBody),
                onTogglePhoto: (id) => _toggle(_bodySel, id),
                onAddPhoto: _addPhoto,
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
/// axes, empty or not — § founder 2026-10-28). Tapping a thumbnail toggles
/// whether it feeds this axis — it never navigates. Only the explicit
/// "Add photo" tile opens the photo picker.
class _AxisGroup extends StatelessWidget {
  const _AxisGroup({
    required this.title,
    required this.icon,
    required this.photos,
    required this.selected,
    required this.skipped,
    required this.emptyPrompt,
    required this.onToggleSkip,
    required this.onTogglePhoto,
    required this.onAddPhoto,
  });

  final String title;
  final IconData icon;
  final List<EligiblePhoto> photos;
  final Set<String> selected;
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
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ac.bgElev,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: ac.lineSoft),
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
                  child: Text(skipped ? 'Include' : 'Skip'),
                ),
            ],
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
                itemCount: photos.length + 1,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, i) {
                  if (i == photos.length) {
                    return _AddPhotoTile(onTap: onAddPhoto);
                  }
                  final p = photos[i];
                  return _PhotoTile(
                    url: p.url,
                    isSelected: selected.contains(p.mediaId),
                    // Selecting is disabled visually while skipped, but the tap
                    // still toggles so the choice is ready if they un-skip.
                    onTap: () => onTogglePhoto(p.mediaId),
                  );
                },
              ),
            ),
          ),
          if (skipped && hasPhotos)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                "Skipped — I won't run this section.",
                style: AymaType.sans(size: 11.5, color: ac.fgMute),
              ),
            ),
        ],
      ),
    );
  }
}

/// A selectable thumbnail in an [_AxisGroup]. A tap toggles [isSelected] via
/// [onTap] — it NEVER navigates (§ founder 2026-10-28: tapping a photo in the
/// analysis sheet must only select/deselect it). Deselected tiles dim and lose
/// the check badge.
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
      label: isSelected ? 'Photo included — tap to leave out'
          : 'Photo left out — tap to include',
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
                top: 3,
                right: 3,
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
              const SizedBox(height: 2),
              Text('Add', style: AymaType.sans(size: 10, color: ac.fgMute)),
            ],
          ),
        ),
      ),
    );
  }
}

class _SkillCard extends StatelessWidget {
  const _SkillCard({
    required this.icon,
    required this.title,
    required this.body,
    required this.onTap,
    this.history,
  });

  final IconData icon;
  final String title;
  final String body;

  /// Typical credit cost of running this skill once (measured from real runs).
  final VoidCallback? onTap;

  /// Optional per-skill history list, shown under the tappable header.
  final Widget? history;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: ac.bgElev,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            InkWell(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(icon, color: ac.fgDim, size: 22),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title,
                              style: AymaType.sans(
                                  size: 15,
                                  weight: FontWeight.w600,
                                  color: ac.fg)),
                          const SizedBox(height: 4),
                          Text(body,
                              style: AymaType.sans(
                                  size: 12, soft: true, color: ac.fgMute)),
                          const SizedBox(height: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: ac.accent.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text('Uses credits',
                                style: AymaType.mono(size: 10, color: ac.accent)
                                    .copyWith(letterSpacing: 0.5)),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right, color: ac.fgMute, size: 18),
                  ],
                ),
              ),
            ),
            if (history != null) history!,
          ],
        ),
      ),
    );
  }
}

/// A single "View my report" link under the Appearance card, routing to the
/// one persistent, correctable Appearance report screen — replaces the old
/// growing history list now that there's one evolving report per user, not a
/// run-by-run history to browse (§ appearance redesign). Still calls
/// `GET /appearance/history` — not to render a list, just to know whether
/// the skill has ever produced anything to view; renders nothing while
/// loading, on error, or when it never has.
class _AppearanceReportLink extends StatefulWidget {
  const _AppearanceReportLink({this.api});

  final ApiClient? api;

  @override
  State<_AppearanceReportLink> createState() => _AppearanceReportLinkState();
}

class _AppearanceReportLinkState extends State<_AppearanceReportLink> {
  late final ApiClient _api = widget.api ?? ApiClient();
  bool _hasReport = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await _api.appearanceHistory();
      if (mounted) setState(() => _hasReport = rows.isNotEmpty);
    } catch (_) {
      /* no link on failure */
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasReport) return const SizedBox.shrink();
    final ac = context.ac;
    return Column(
      children: [
        Divider(height: 0.5, color: ac.lineSoft),
        InkWell(
          onTap: () => context.push('/appearance/current'),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Row(
              children: [
                Icon(Icons.auto_awesome_outlined, size: 15, color: ac.fgMute),
                const SizedBox(width: 12),
                Expanded(
                  child: Text('View my report',
                      style: AymaType.sans(size: 12.5, color: ac.fgDim)),
                ),
                Icon(Icons.chevron_right, size: 16, color: ac.fgMute),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// A single "View my report" link under the "Search the web about me"
/// card, routing to the one persistent, correctable web-search report —
/// replaces the old single-row "latest self-dive" preview now that the report
/// itself is the thing to open, not a summary to skim first (§ web-search
/// redesign). Renders nothing while loading, on error, or when no self-dive
/// has ever run.
class _WebSearchReportLink extends StatefulWidget {
  const _WebSearchReportLink({this.api});

  final ApiClient? api;

  @override
  State<_WebSearchReportLink> createState() => _WebSearchReportLinkState();
}

class _WebSearchReportLinkState extends State<_WebSearchReportLink> {
  late final ApiClient _api = widget.api ?? ApiClient();
  DeepDiveMine? _result;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await _api.deepDiveMine();
      if (mounted) setState(() => _result = r);
    } catch (_) {
      /* no link on failure */
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _result;
    if (r == null || r.reportId.isEmpty) return const SizedBox.shrink();
    final ac = context.ac;
    return Column(
      children: [
        Divider(height: 0.5, color: ac.lineSoft),
        InkWell(
          onTap: () => context.push('/deep-dive/${Uri.encodeComponent(r.reportId)}'),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Row(
              children: [
                Icon(Icons.travel_explore, size: 15, color: ac.fgMute),
                const SizedBox(width: 12),
                Expanded(
                  child: Text('View my report',
                      style: AymaType.sans(size: 12.5, color: ac.fgDim)),
                ),
                Icon(Icons.chevron_right, size: 16, color: ac.fgMute),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
