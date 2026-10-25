import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../services/api_client.dart';
import '../services/app_context.dart';
import '../services/chat_inbox.dart';
import '../services/chat_service.dart';
import '../services/profile_service.dart';
import '../theme.dart';
import '../widgets/ayma_orb.dart';
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
    this.imagePicker,
    this.chatService,
  });

  static const path = '/skills';

  final ProfileService? profileService;
  final ApiClient? api;
  final ImagePicker? imagePicker;
  final ChatService? chatService;

  @override
  State<SkillsScreen> createState() => _SkillsScreenState();
}

class _SkillsScreenState extends State<SkillsScreen>
    with ScreenContextReasserter<SkillsScreen> {
  late final ProfileService _profiles =
      widget.profileService ?? ProfileService();
  late final ApiClient _api = widget.api ?? ApiClient();
  late final ImagePicker _picker = widget.imagePicker ?? ImagePicker();
  late final ChatService _chat = widget.chatService ?? ChatService();

  ProfileData? _profile;
  bool _busy = false;

  /// Shown on the busy overlay while photos upload ("Uploading photo 2 of 4…").
  String _busyMsg = '';

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

  /// The Appearance skill. Show the photo-source sheet with a live coverage
  /// line, resolve the choice, upload any added photos, then hand a
  /// fully-specified [ChatKickoff.appearance] to the chat. Never hard-blocks —
  /// the user can run it with a gap.
  Future<void> _runAppearance() async {
    if (_busy) return;
    final choice = await showModalBottomSheet<_AppearanceChoice>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _AppearanceSheet(api: _api, picker: _picker),
    );
    if (choice == null || !mounted) return;

    var paths = <String>[];
    if (choice.mode == 'gap' && choice.pickedPath.isNotEmpty) {
      paths = [choice.pickedPath];
    } else if (choice.mode == 'added') {
      final List<XFile> picked;
      try {
        picked = await _picker.pickMultiImage(maxWidth: 1600, imageQuality: 88);
      } catch (_) {
        _snack("Couldn't open your gallery — try again.");
        return;
      }
      if (picked.isEmpty || !mounted) return;
      final take = picked.take(6).toList();
      setState(() {
        _busy = true;
        _busyMsg = take.length == 1
            ? 'Uploading your photo…'
            : 'Uploading photo 1 of ${take.length}…';
      });
      try {
        for (var i = 0; i < take.length; i++) {
          if (mounted && take.length > 1) {
            setState(() =>
                _busyMsg = 'Uploading photo ${i + 1} of ${take.length}…');
          }
          final up = await _chat.uploadChatImage(File(take[i].path));
          paths.add(up.storagePath);
        }
      } catch (_) {
        if (mounted) setState(() { _busy = false; _busyMsg = ''; });
        _snack("Couldn't upload those photos — try again.");
        return;
      }
      if (mounted) setState(() { _busy = false; _busyMsg = ''; });
    }
    if (!mounted) return;

    // Added photos may themselves supply a missing shot, so want both sections;
    // an "existing photos" run trusts the coverage gate.
    final addedPhotos = paths.isNotEmpty;
    ChatInbox.instance.push(ChatKickoff.appearance(
      extraPaths: paths,
      wantFace: addedPhotos || choice.wantFace,
      wantBody: addedPhotos || choice.wantBody,
      useAllPhotos: choice.mode != 'added',
    ));
    if (mounted) context.go(MainShellScreen.path);
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(
        leading: const AymaBackButton(),
        title: const Text('Skills')),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              _SkillCard(
                icon: Icons.travel_explore,
                title: 'Search the web about me',
                body: "Ayma looks you up online so you don't have to repeat "
                    'yourself, then confirms what she found in chat.',
                onTap: _busy ? null : _searchWeb,
                history: _WebSearchReportLink(api: widget.api),
              ),
              _SkillCard(
                icon: Icons.auto_awesome_outlined,
                title: 'Appearance',
                body: 'A full read of your photos: your structured attributes '
                    'plus an honest face and physique analysis.',
                onTap: _busy ? null : _runAppearance,
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
          if (_busy)
            Positioned.fill(
              child: ColoredBox(
                color: AymaColors.scrimBusy,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const AymaOrb(size: 56, state: AymaOrbState.thinking),
                      if (_busyMsg.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        Text(
                          _busyMsg,
                          style: AymaType.sans(size: 13, color: Colors.white),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
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

/// The choice the Appearance photo-source sheet returns.
class _AppearanceChoice {
  const _AppearanceChoice(
    this.mode, {
    this.pickedPath = '',
    this.wantFace = true,
    this.wantBody = true,
  });

  /// `existing` (run over the current grid) | `added` (pick a fresh set) |
  /// `gap` (one photo picked to fill a missing face / body shot).
  final String mode;
  final String pickedPath;
  final bool wantFace;
  final bool wantBody;
}

/// The photo-source sheet for the Appearance skill: a live coverage line
/// (✓/✗ face photo, ✓/✗ body photo) with an inline "add the missing
/// one" action, then "use what I have" / "add photos".
class _AppearanceSheet extends StatefulWidget {
  const _AppearanceSheet({required this.api, required this.picker});

  final ApiClient api;
  final ImagePicker picker;

  @override
  State<_AppearanceSheet> createState() => _AppearanceSheetState();
}

class _AppearanceSheetState extends State<_AppearanceSheet> {
  AppearanceCoverage? _coverage;
  bool _picking = false;

  @override
  void initState() {
    super.initState();
    _loadCoverage();
  }

  Future<void> _loadCoverage() async {
    try {
      final c = await widget.api.appearanceCoverage();
      if (mounted) setState(() => _coverage = c);
    } catch (_) {
      // No coverage line on failure — the run still works.
      if (mounted) setState(() => _coverage = const AppearanceCoverage());
    }
  }

  Future<void> _addMissing() async {
    if (_picking) return;
    setState(() => _picking = true);
    final chat = ChatService();
    XFile? picked;
    try {
      picked = await widget.picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        imageQuality: 88,
      );
    } catch (_) {
      picked = null;
    }
    if (picked == null) {
      if (mounted) setState(() => _picking = false);
      return;
    }
    try {
      final up = await chat.uploadChatImage(File(picked.path));
      if (!mounted) return;
      Navigator.pop(
        context,
        _AppearanceChoice('gap',
            pickedPath: up.storagePath, wantFace: true, wantBody: true),
      );
    } catch (_) {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final cov = _coverage;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Which photos should I use for your Appearance report?',
                style: AymaType.sans(size: 14, color: ac.fgDim),
              ),
            ),
          ),
          if (cov != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _CoverageChip(ok: cov.hasFacePhoto, label: 'Face photo'),
                      const SizedBox(width: 16),
                      _CoverageChip(
                          ok: cov.hasBodyPhoto, label: 'Body photo'),
                    ],
                  ),
                  if (!cov.hasBodyPhoto)
                    _picking
                        ? const Padding(
                            padding: EdgeInsets.only(top: 8),
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child:
                                  CircularProgressIndicator(strokeWidth: 1.6),
                            ),
                          )
                        : TextButton.icon(
                            onPressed: () => _addMissing(),
                            icon: const Icon(Icons.add_a_photo_outlined,
                                size: 16),
                            label: const Text('Add a body photo'),
                          )
                  else if (!cov.hasFacePhoto && !_picking)
                    TextButton.icon(
                      onPressed: () => _addMissing(),
                      icon: const Icon(Icons.add_a_photo_outlined, size: 16),
                      label: const Text('Add a face photo'),
                    )
                  else if (cov.hasBodyPhoto &&
                      !cov.hasFittedBodyPhoto &&
                      !_picking)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'For a more accurate body read, a photo without '
                        'loose or baggy clothing helps.',
                        style: AymaType.sans(size: 12, color: ac.fgDim),
                      ),
                    ),
                ],
              ),
            ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Use the photos I already have'),
            onTap: () => Navigator.pop(
              context,
              _AppearanceChoice(
                'existing',
                wantFace: cov?.hasFacePhoto ?? true,
                wantBody: cov?.hasBodyPhoto ?? true,
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.add_a_photo_outlined),
            title: const Text('Add photos'),
            onTap: () => Navigator.pop(context, const _AppearanceChoice('added')),
          ),
        ],
      ),
    );
  }
}

class _CoverageChip extends StatelessWidget {
  const _CoverageChip({required this.ok, required this.label});

  final bool ok;
  final String label;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(ok ? Icons.check_circle : Icons.cancel_outlined,
            size: 15, color: ok ? ac.accent : ac.fgMute),
        const SizedBox(width: 5),
        Text(label, style: AymaType.sans(size: 12, color: ac.fgDim)),
      ],
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
