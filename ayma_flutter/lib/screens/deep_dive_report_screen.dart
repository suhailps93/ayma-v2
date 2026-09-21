import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/api_client.dart';
import '../services/chat_inbox.dart';
import '../theme.dart';
import '../widgets/ayma_orb.dart';
import '../widgets/ayma_photo.dart';
import '../widgets/finding_correction_sheet.dart';
import '../widgets/out_of_credits.dart';
import 'main_shell_screen.dart';

/// A stored web deep dive on one person, re-opened from a `[deep_dive:<id>]`
/// chat marker or the "View research" button on a profile. Display-only for
/// the research itself — the AppBar "Refresh" action re-runs the search
/// (self or someone else) and the update lands in chat when it's ready.
class DeepDiveReportScreen extends StatefulWidget {
  const DeepDiveReportScreen({super.key, required this.reportId, this.apiClient});

  static const path = '/deep-dive/:id';

  final String reportId;
  final ApiClient? apiClient;

  @override
  State<DeepDiveReportScreen> createState() => _DeepDiveReportScreenState();
}

class _DeepDiveReportScreenState extends State<DeepDiveReportScreen> {
  late final ApiClient _api = widget.apiClient ?? ApiClient();
  late Future<DeepDiveReport> _future = _load();

  /// The loaded report, kept so the AppBar "Ask Ayma" / "Refresh" actions can
  /// hand it off.
  DeepDiveReport? _loaded;

  bool _reRunning = false;

  Future<DeepDiveReport> _load() {
    final f = _api.deepDiveReport(widget.reportId);
    f.then((r) {
      if (mounted) setState(() => _loaded = r);
    }).catchError((_) {});
    return f;
  }

  /// Re-run this search from scratch — works the same whether the report is
  /// about you or someone else; a forced dive always skips the reuse cache.
  /// The fresh result lands in chat when it's ready (same as any other dive),
  /// and reopening this report afterwards picks up the update.
  Future<void> _reRun(DeepDiveReport r) async {
    if (_reRunning) return;
    setState(() => _reRunning = true);
    try {
      final res = await _api.deepDive(
        targetUid: r.isSelf ? '' : r.otherUid,
        name: r.name,
        force: true,
      );
      if (!mounted) return;
      if (res.usageCapped) {
        showOutOfCreditsSnack(context);
        return;
      }
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(
          content: Text(r.isSelf
              ? "Searching again — I'll message you in chat when it's ready."
              : "Searching again for ${r.name.isEmpty ? 'them' : r.name} — "
                  "I'll message you in chat when it's ready."),
        ));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
            const SnackBar(content: Text("Couldn't start a new search.")));
    } finally {
      if (mounted) setState(() => _reRunning = false);
    }
  }

  /// Hand this research to the Ayma chat as an un-sent draft attachment — the
  /// chat opens with the report chipped above an empty composer so the user
  /// asks their own question about it.
  void _askAyma(DeepDiveReport r) {
    ChatInbox.instance.push(ChatKickoff.draftAbout(
      targetUid: r.otherUid,
      label: r.name.isEmpty ? 'them' : r.name,
      shareKind: 'deep_dive',
      photoUrl: r.subjectImage,
      refId: widget.reportId,
    ));
    context.go(MainShellScreen.path);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Web research'),
        actions: [
          if (_loaded != null) ...[
            IconButton(
              tooltip: 'Search again',
              onPressed: _reRunning ? null : () => _reRun(_loaded!),
              icon: _reRunning
                  ? const AymaOrb(size: 18, state: AymaOrbState.thinking)
                  : const Icon(Icons.refresh),
            ),
            TextButton(
              onPressed: () => _askAyma(_loaded!),
              child: const Text('Ask Ayma'),
            ),
          ],
        ],
      ),
      body: FutureBuilder<DeepDiveReport>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: AymaOrb(size: 64, state: AymaOrbState.thinking));
          }
          if (snap.hasError || snap.data == null) {
            return _Message(
              text: "Couldn't load that research.",
              onRetry: () => setState(() => _future = _load()),
            );
          }
          return _Report(r: snap.data!, reportId: widget.reportId, api: _api);
        },
      ),
    );
  }
}

class _Report extends StatefulWidget {
  const _Report({required this.r, required this.reportId, required this.api});

  final DeepDiveReport r;
  final String reportId;
  final ApiClient api;

  @override
  State<_Report> createState() => _ReportState();
}

class _ReportState extends State<_Report> {
  /// Local copy so a successful dispute drops the line immediately without
  /// waiting on a re-fetch of the whole report.
  final List<DeepDiveFact> _facts = [];

  /// Local copy so a successful summary correction updates immediately too.
  late String _summary = widget.r.summary;

  final Set<String> _disputing = {};

  @override
  void initState() {
    super.initState();
    _facts.addAll(widget.r.facts);
  }

  Future<void> _open(String url) =>
      launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

  /// A correction (summary or fact) always comes back with the FULL updated
  /// digest — the source of truth for what got applied (a "remove" drops a
  /// fact, a "revise"/"caveat" changes its text, a "keep" leaves it as is) —
  /// so this just re-derives the local view from it wholesale rather than
  /// patching one field by hand.
  void _applyCorrectedDigest(Map<String, dynamic>? digest) {
    if (digest == null) return;
    final facts = (digest['facts'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => DeepDiveFact.fromMap(e))
        .where((f) => f.claim.isNotEmpty)
        .toList();
    setState(() {
      _summary = digest['summary'] as String? ?? _summary;
      _facts
        ..clear()
        ..addAll(facts);
    });
  }

  Future<void> _correctSummary() {
    return showFindingCorrectionSheet(
      context,
      title: 'Summary',
      currentValue: _summary,
      onSend: (message) async {
        final res = await widget.api.correctDeepDive(
          reportId: widget.reportId, target: 'summary', feedback: message,
        );
        if (!res.usageCapped) _applyCorrectedDigest(res.digest);
        return CorrectionReply(text: res.reply, usageCapped: res.usageCapped);
      },
    );
  }

  Future<void> _correctFact(DeepDiveFact f) {
    return showFindingCorrectionSheet(
      context,
      title: f.category.isNotEmpty ? f.category : 'Claim',
      currentValue: f.claim,
      onSend: (message) async {
        final res = await widget.api.correctDeepDive(
          reportId: widget.reportId, target: 'fact:${f.id}', feedback: message,
        );
        if (!res.usageCapped) _applyCorrectedDigest(res.digest);
        return CorrectionReply(text: res.reply, usageCapped: res.usageCapped);
      },
    );
  }

  Future<void> _disputeFact(DeepDiveFact f) async {
    if (f.id.isEmpty || _disputing.contains(f.id)) return;
    setState(() => _disputing.add(f.id));
    try {
      await widget.api.disputeDeepDiveFact(
        reportId: widget.reportId,
        factId: f.id,
      );
      if (!mounted) return;
      setState(() {
        _facts.removeWhere((x) => x.id == f.id);
        _disputing.remove(f.id);
      });
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(const SnackBar(
          content: Text("Noted — I won't bring that up again unless I "
              "find new evidence for it."),
        ));
    } catch (_) {
      if (!mounted) return;
      setState(() => _disputing.remove(f.id));
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
            const SnackBar(content: Text("Couldn't record that correction.")));
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.r;
    final ac = context.ac;
    final them = r.links.where((l) => l.isThem == 'likely').toList();
    final maybe = r.links.where((l) => l.isThem != 'likely').toList();
    final photos = r.webImages.where((im) => im.verified).toList();
    final unverifiedPhotos =
        r.webImages.where((im) => !im.verified).toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
      children: [
        Row(
          children: [
            if (r.subjectImage.isNotEmpty)
              ClipOval(
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: AymaPhoto(
                    url: r.subjectImage,
                    displayWidth: 44,
                    error: Icon(Icons.public, color: ac.fgMute),
                  ),
                ),
              )
            else
              Icon(Icons.public, size: 40, color: ac.fgMute),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(r.name.isEmpty ? 'This person' : r.name,
                      style: AymaType.serif(size: 22, color: ac.fg)),
                  Text(
                    r.isSelf ? 'What the web says about you' : 'From the open web',
                    style: AymaType.mono(size: 9, color: ac.fgMute)
                        .copyWith(letterSpacing: 1.2),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        if (_summary.isNotEmpty)
          r.isSelf
              ? InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: _correctSummary,
                  child: Text(_summary,
                      style: AymaType.serif(size: 16, color: ac.fg)
                          .copyWith(height: 1.5)),
                )
              : Text(_summary,
                  style: AymaType.serif(size: 16, color: ac.fg)
                      .copyWith(height: 1.5)),
        if (r.socialHandles.isNotEmpty) ...[
          const SizedBox(height: 22),
          Text('SOCIAL PROFILES',
              style: AymaType.mono(size: 10, color: ac.fgMute)
                  .copyWith(letterSpacing: 1.4)),
          const SizedBox(height: 8),
          for (final s in r.socialHandles) _SocialRow(s: s, onOpen: _open),
        ],
        if (photos.isNotEmpty || unverifiedPhotos.isNotEmpty) ...[
          const SizedBox(height: 22),
          Text(
            photos.isNotEmpty
                ? (r.isSelf
                    ? 'PHOTOS OF YOU FOUND ONLINE'
                    : 'PHOTOS FOUND ONLINE — FACE-MATCHED')
                : 'PHOTOS FOUND ONLINE — UNVERIFIED',
            style: AymaType.mono(size: 10, color: ac.fgMute)
                .copyWith(letterSpacing: 1.4),
          ),
          const SizedBox(height: 8),
          _WebImageGallery(
              images: photos.isNotEmpty ? photos : unverifiedPhotos,
              onOpen: _open),
        ],
        if (_facts.isNotEmpty) ...[
          const SizedBox(height: 24),
          Text('WHAT IT FOUND',
              style: AymaType.mono(size: 10, color: ac.fgMute)
                  .copyWith(letterSpacing: 1.4)),
          const SizedBox(height: 8),
          for (final f in _facts)
            _Fact(
              f: f,
              onOpen: _open,
              onCorrect: r.isSelf && f.id.isNotEmpty
                  ? () => _correctFact(f)
                  : null,
              onDispute: r.isSelf && f.id.isNotEmpty
                  ? () => _disputeFact(f)
                  : null,
              disputing: _disputing.contains(f.id),
            ),
        ],
        if (them.isNotEmpty) ...[
          const SizedBox(height: 24),
          Text('LINKS LIKELY THEM',
              style: AymaType.mono(size: 10, color: ac.fgMute)
                  .copyWith(letterSpacing: 1.4)),
          const SizedBox(height: 8),
          for (final l in them) _Link(l: l, onOpen: _open),
        ],
        if (maybe.isNotEmpty) ...[
          const SizedBox(height: 24),
          Text('LINKS — MAYBE',
              style: AymaType.mono(size: 10, color: ac.fgMute)
                  .copyWith(letterSpacing: 1.4)),
          const SizedBox(height: 8),
          for (final l in maybe) _Link(l: l, onOpen: _open),
        ],
        if (r.caveats.isNotEmpty) ...[
          const SizedBox(height: 24),
          Text(r.caveats,
              style: AymaType.sans(size: 12, soft: true, color: ac.fgMute)),
        ],
      ],
    );
  }
}

class _WebImageGallery extends StatelessWidget {
  const _WebImageGallery({required this.images, required this.onOpen});

  final List<DeepDiveWebImage> images;
  final Future<void> Function(String) onOpen;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return SizedBox(
      height: 108,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: images.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, i) {
          final im = images[i];
          return GestureDetector(
            onTap: () => onOpen(
                im.sourcePage.isNotEmpty ? im.sourcePage : im.url),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.network(
                        im.url,
                        width: 88,
                        height: 88,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          width: 88,
                          height: 88,
                          color: ac.bgElev,
                          child: Icon(Icons.broken_image_outlined,
                              size: 20, color: ac.fgMute),
                        ),
                      ),
                    ),
                    Positioned(
                      right: 4,
                      top: 4,
                      child: Container(
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Icon(Icons.open_in_new,
                            size: 11, color: Colors.white),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  im.similarity != null
                      ? 'match ${(im.similarity! * 100).round()}% · open ↗'
                      : 'unverified · open ↗',
                  style: AymaType.mono(size: 8, color: ac.fgMute)
                      .copyWith(letterSpacing: 1),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

IconData _platformIcon(String platform) {
  switch (platform.toLowerCase()) {
    case 'instagram':
      return Icons.camera_alt;
    case 'x':
    case 'twitter':
      return Icons.alternate_email;
    case 'linkedin':
      return Icons.work_outline;
    case 'facebook':
      return Icons.facebook;
    case 'tiktok':
      return Icons.music_note;
    case 'github':
      return Icons.code;
    case 'youtube':
      return Icons.play_circle_outline;
    default:
      return Icons.public;
  }
}

class _SocialRow extends StatelessWidget {
  const _SocialRow({required this.s, required this.onOpen});

  final DeepDiveSocial s;
  final Future<void> Function(String) onOpen;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final tag = s.confidence == 'high' ? 'verified' : 'likely';
    final handleText = s.handle.isEmpty ? s.url : '@${s.handle}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GestureDetector(
        onTap: () => onOpen(s.url),
        behavior: HitTestBehavior.opaque,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(_platformIcon(s.platform), size: 18, color: ac.accent),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          handleText,
                          style: AymaType.sans(
                              size: 14, color: ac.accent, height: 1.3),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: tag == 'verified'
                              ? ac.accent.withValues(alpha: 0.16)
                              : ac.bgElev,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          tag,
                          style: AymaType.mono(size: 8, color: ac.fgMute)
                              .copyWith(letterSpacing: 1),
                        ),
                      ),
                    ],
                  ),
                  if (s.displayName.isNotEmpty)
                    Text(
                      s.displayName,
                      style: AymaType.sans(
                          size: 11, soft: true, color: ac.fgMute),
                    ),
                ],
              ),
            ),
            Icon(Icons.open_in_new, size: 13, color: ac.fgMute),
          ],
        ),
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({
    required this.f,
    required this.onOpen,
    this.onCorrect,
    this.onDispute,
    this.disputing = false,
  });

  final DeepDiveFact f;
  final Future<void> Function(String) onOpen;

  /// Present only for a self-dive report — tapping the claim opens the
  /// tap-a-claim conversational correction sheet.
  final VoidCallback? onCorrect;

  /// Present only for a self-dive report — the one-tap "this is just wrong,
  /// drop it" affordance, kept alongside [onCorrect] rather than folded into
  /// it: a quick removal shouldn't require typing anything.
  final VoidCallback? onDispute;
  final bool disputing;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final conf = f.confidence.isEmpty ? '' : ' · ${f.confidence}';
    final claim = Text('• ${f.claim}',
        style: AymaType.sans(size: 14, color: ac.fg, height: 1.4));
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                onCorrect == null
                    ? claim
                    : InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onTap: onCorrect,
                        child: claim,
                      ),
                if (f.sourceUrl.isNotEmpty || f.category.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 14, top: 2),
                    child: GestureDetector(
                      onTap: f.sourceUrl.isEmpty
                          ? null
                          : () => onOpen(f.sourceUrl),
                      child: Text(
                        '${f.category}$conf'
                        '${f.sourceUrl.isEmpty ? '' : '  ·  source ↗'}',
                        style: AymaType.mono(
                            size: 9,
                            color:
                                f.sourceUrl.isEmpty ? ac.fgMute : ac.accent),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (onDispute != null)
            SizedBox(
              width: 32,
              height: 32,
              child: disputing
                  ? const Padding(
                      padding: EdgeInsets.all(8),
                      child: AymaOrb(size: 16, state: AymaOrbState.thinking),
                    )
                  : IconButton(
                      tooltip: 'Mark incorrect',
                      padding: EdgeInsets.zero,
                      iconSize: 16,
                      icon: Icon(Icons.close, color: ac.fgMute),
                      onPressed: onDispute,
                    ),
            ),
        ],
      ),
    );
  }
}

class _Link extends StatelessWidget {
  const _Link({required this.l, required this.onOpen});

  final DeepDiveLink l;
  final Future<void> Function(String) onOpen;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GestureDetector(
        onTap: () => onOpen(l.url),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.open_in_new, size: 13, color: ac.accent),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                l.title.isEmpty ? l.url : l.title,
                style: AymaType.sans(size: 13, color: ac.accent, height: 1.35),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text, this.onRetry});

  final String text;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text, style: AymaType.sans(size: 14, color: ac.fgMute)),
          if (onRetry != null)
            TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}
