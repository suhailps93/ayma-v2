import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../services/api_client.dart';
import '../services/chat_inbox.dart';
import '../services/chat_service.dart';
import '../services/profile_service.dart';
import '../theme.dart';
import '../widgets/body_report_view.dart';
import '../widgets/face_report_view.dart';
import 'main_shell_screen.dart';

/// Things Ayma can do on demand about *you* — search the web, read a face photo,
/// read a physique photo, build a structured physical profile. Reached from one
/// row on the Profile tab.
///
/// Pressing a skill hands off to the Ayma chat (via [ChatInbox]) and runs there
/// — no blocking spinner on this screen. For the photo skills the photo-source
/// choice ("use what I have" / "add photos") is resolved *here*, before the
/// hand-off, so the chat runs the skill straight away with no second prompt.
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

class _SkillsScreenState extends State<SkillsScreen> {
  late final ProfileService _profiles =
      widget.profileService ?? ProfileService();
  late final ImagePicker _picker = widget.imagePicker ?? ImagePicker();
  late final ChatService _chat = widget.chatService ?? ChatService();

  ProfileData? _profile;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

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

  // --- Photo skills ------------------------------------------------------

  /// One flow for all three photo skills. [kind] is `face`, `body` or
  /// `physical`. Resolve the photo source on this screen, upload any added
  /// photos, then hand a fully-specified [ChatKickoff] to the chat.
  Future<void> _runPhotoSkill(String kind) async {
    if (_busy) return;
    final multi = kind == 'physical';
    final subject = switch (kind) {
      'face' => 'facial beauty report',
      'body' => 'physique report',
      _ => 'physical profile',
    };

    final source = await showModalBottomSheet<String>(
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
                  'Which photos should I use for your $subject?',
                  style: AymaType.sans(size: 14, color: ctx.ac.fgDim),
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Use the photos I already have'),
              onTap: () => Navigator.pop(ctx, 'existing'),
            ),
            ListTile(
              leading: const Icon(Icons.add_a_photo_outlined),
              title: Text(multi ? 'Add photos' : 'Add a photo'),
              onTap: () => Navigator.pop(ctx, 'added'),
            ),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;

    var paths = <String>[];
    if (source == 'added') {
      final List<XFile> picked;
      try {
        if (multi) {
          picked = await _picker.pickMultiImage(
              maxWidth: 1600, imageQuality: 88);
        } else {
          final one = await _picker.pickImage(
            source: ImageSource.gallery,
            maxWidth: 1600,
            imageQuality: 88,
          );
          picked = one == null ? const [] : [one];
        }
      } catch (_) {
        _snack("Couldn't open your gallery — try again.");
        return;
      }
      if (picked.isEmpty || !mounted) return;

      setState(() => _busy = true);
      try {
        for (final x in picked.take(6)) {
          final up = await _chat.uploadChatImage(File(x.path));
          paths.add(up.storagePath);
        }
      } catch (_) {
        if (mounted) setState(() => _busy = false);
        _snack("Couldn't upload those photos — try again.");
        return;
      }
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;

    final useExisting = source == 'existing';
    final ChatKickoff k;
    switch (kind) {
      case 'physical':
        k = ChatKickoff.physicalAttributes(
          extraPaths: paths,
          useAllPhotos: useExisting,
        );
      case 'face':
        k = ChatKickoff.faceReport(
          attachmentPath: paths.isEmpty ? '' : paths.first,
          photoSource: source,
        );
      default:
        k = ChatKickoff.bodyReport(
          attachmentPath: paths.isEmpty ? '' : paths.first,
          photoSource: source,
        );
    }
    ChatInbox.instance.push(k);
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
      appBar: AppBar(title: const Text('Skills')),
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
                // ~15 credits: measured from real runs — a deep dive is two
                // grounded Gemini calls (research + digest), ~16k tokens.
                costCredits: 15,
                onTap: _busy ? null : _searchWeb,
              ),
              _SkillCard(
                icon: Icons.face_retouching_natural,
                title: 'Facial beauty report',
                body: 'An honest, data-driven read on a face photo.',
                // ~4 credits: one Gemini vision call, ~3.5k tokens measured.
                costCredits: 4,
                onTap: _busy ? null : () => _runPhotoSkill('face'),
                history: _ReportHistory(kind: 'face', api: widget.api),
              ),
              _SkillCard(
                icon: Icons.accessibility_new,
                title: 'Physique report',
                body: 'An honest, data-driven read on a full-body photo.',
                costCredits: 4,
                onTap: _busy ? null : () => _runPhotoSkill('body'),
                history: _ReportHistory(kind: 'body', api: widget.api),
              ),
              _SkillCard(
                icon: Icons.badge_outlined,
                title: 'Physical attributes',
                body: 'A structured read of your build, hair & eye colour, '
                    'skin tone, apparent ethnicity and rough height/weight — '
                    'used to sharpen your matches and Explore search.',
                // ~6 credits: one multi-image Gemini vision pass over the
                // whole profile grid (up to 6 photos) + a structured schema.
                costCredits: 6,
                onTap: _busy ? null : () => _runPhotoSkill('physical'),
                history: _PhysicalUpdated(api: widget.api),
              ),
              const SizedBox(height: 20),
              Text(
                'Credit costs are typical — a longer photo or a hard-to-find '
                'name can run a little higher.',
                style: AymaType.sans(size: 12, soft: true, color: ac.fgMute),
              ),
            ],
          ),
          if (_busy)
            const Positioned.fill(
              child: ColoredBox(
                color: Color(0x66000000),
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      ),
    );
  }
}

class _SkillCard extends StatelessWidget {
  const _SkillCard({
    required this.icon,
    required this.title,
    required this.body,
    required this.costCredits,
    required this.onTap,
    this.history,
  });

  final IconData icon;
  final String title;
  final String body;

  /// Typical credit cost of running this skill once (measured from real runs).
  final int costCredits;
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
                            child: Text('≈ $costCredits credits',
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

/// Past reports for one skill (`face` / `body`). Renders nothing while loading,
/// on error, or when there are none — so an empty skill shows no clutter.
class _ReportHistory extends StatefulWidget {
  const _ReportHistory({required this.kind, this.api});

  final String kind;
  final ApiClient? api;

  @override
  State<_ReportHistory> createState() => _ReportHistoryState();
}

class _ReportHistoryState extends State<_ReportHistory> {
  late final ApiClient _api = widget.api ?? ApiClient();
  List<SkillReportSummary> _rows = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await _api.skillReports(widget.kind);
      if (mounted) setState(() => _rows = rows);
    } catch (_) {
      /* no history section on failure */
    }
  }

  String _when(String? iso) {
    if (iso == null) return '';
    final d = DateTime.tryParse(iso);
    if (d == null) return '';
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${d.day} ${months[d.month - 1]}';
  }

  void _open(String id) {
    if (widget.kind == 'face') {
      openStoredFaceReport(context, api: _api, reportId: id);
    } else {
      openStoredBodyReport(context, api: _api, reportId: id);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_rows.isEmpty) return const SizedBox.shrink();
    final ac = context.ac;
    return Column(
      children: [
        Divider(height: 0.5, color: ac.lineSoft),
        for (final r in _rows.take(6))
          InkWell(
            onTap: () => _open(r.id),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: Row(
                children: [
                  Icon(Icons.assessment_outlined, size: 15, color: ac.fgMute),
                  const SizedBox(width: 12),
                  Text('${r.overallScore.toStringAsFixed(1)}/10',
                      style: AymaType.mono(size: 12, color: ac.fg)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      r.verdict,
                      overflow: TextOverflow.ellipsis,
                      style: AymaType.sans(size: 12, color: ac.fgDim),
                    ),
                  ),
                  Text(_when(r.createdAt),
                      style: AymaType.sans(
                          size: 11, soft: true, color: ac.fgMute)),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// A single "last updated" line under the Physical attributes card.
/// Renders nothing while loading, on error, or when the record was never built.
class _PhysicalUpdated extends StatefulWidget {
  const _PhysicalUpdated({this.api});

  final ApiClient? api;

  @override
  State<_PhysicalUpdated> createState() => _PhysicalUpdatedState();
}

class _PhysicalUpdatedState extends State<_PhysicalUpdated> {
  late final ApiClient _api = widget.api ?? ApiClient();
  PhysicalAttrsResult? _rec;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rec = await _api.physicalAttributes();
      if (mounted) setState(() => _rec = rec);
    } catch (_) {
      /* no line on failure */
    }
  }

  String _when(String? iso) {
    if (iso == null) return '';
    final d = DateTime.tryParse(iso);
    if (d == null) return '';
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${d.day} ${months[d.month - 1]}';
  }

  @override
  Widget build(BuildContext context) {
    final rec = _rec;
    final when = _when(rec?.updatedAt);
    if (rec == null || when.isEmpty) return const SizedBox.shrink();
    final ac = context.ac;
    return Column(
      children: [
        Divider(height: 0.5, color: ac.lineSoft),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(
            children: [
              Icon(Icons.badge_outlined, size: 15, color: ac.fgMute),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '${rec.attributes.length} attributes read'
                  '${rec.photoCount > 0 ? ' from ${rec.photoCount} photos' : ''}',
                  overflow: TextOverflow.ellipsis,
                  style: AymaType.sans(size: 12, color: ac.fgDim),
                ),
              ),
              Text('updated $when',
                  style: AymaType.sans(size: 11, soft: true, color: ac.fgMute)),
            ],
          ),
        ),
      ],
    );
  }
}
