import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../theme.dart';
import 'app_loading_indicator.dart';
import 'ayma_toast.dart';
import 'score_bar.dart';

/// Resolve a Storage path to a download URL, or null if it can't be read.
/// Shared by every report surface (face / body / appearance) so a photo
/// reference is always resolved the same way.
Future<String?> resolvePhotoUrl(String path) async {
  if (path.isEmpty) return null;
  try {
    return await FirebaseStorage.instance.ref(path).getDownloadURL();
  } catch (_) {
    return null;
  }
}

/// Resolve every non-empty path in [paths], dropping any that fail.
Future<List<String>> resolvePhotoUrls(Iterable<String> paths) async {
  final urls = await Future.wait(paths.map(resolvePhotoUrl));
  return [for (final u in urls) if (u != null) u];
}

/// A stored face report ([FaceReport]) plus a resolved URL for the photo it
/// was run on. Used by both the chat inline card and the Skills-screen history.
class StoredFaceReport {
  const StoredFaceReport({this.report, this.imageUrl});
  final FaceReport? report;
  final String? imageUrl;
}

/// Fetch a stored face report by id and resolve its photo URL.
Future<StoredFaceReport> fetchStoredFaceReport(
  String reportId, {
  ApiClient? api,
}) async {
  final r = await (api ?? ApiClient()).skillReport('face', reportId);
  return StoredFaceReport(
    report: r.report.isEmpty ? null : FaceReport.fromMap(r.report),
    imageUrl: await resolvePhotoUrl(r.imagePath),
  );
}

/// Open a report already stored server-side in a bottom sheet — from the
/// Skills-screen history, or a chat turn that carries a `[face_report:<id>]`
/// marker. Display-only: it fetches the stored doc, it never runs a fresh
/// analysis (that happens in the chat).
Future<void> openStoredFaceReport(
  BuildContext context, {
  ApiClient? api,
  required String reportId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => _StoredFaceReportSheet(
      api: api ?? ApiClient(),
      reportId: reportId,
    ),
  );
}

class _StoredFaceReportSheet extends StatefulWidget {
  const _StoredFaceReportSheet({required this.api, required this.reportId});

  final ApiClient api;
  final String reportId;

  @override
  State<_StoredFaceReportSheet> createState() => _StoredFaceReportSheetState();
}

class _StoredFaceReportSheetState extends State<_StoredFaceReportSheet> {
  late final Future<StoredFaceReport> _future =
      fetchStoredFaceReport(widget.reportId, api: widget.api);

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, controller) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: FutureBuilder<StoredFaceReport>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: AppLoadingIndicator(),
                ),
              );
            }
            final report = snap.data?.report;
            if (snap.hasError || report == null) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: Text(
                  "Couldn't load that report.",
                  textAlign: TextAlign.center,
                  style: AymaType.sans(size: 14, color: ac.fgMute),
                ),
              );
            }
            return ListView(
              controller: controller,
              children: [
                FaceReportView(report: report, imageUrl: snap.data?.imageUrl),
              ],
            );
          },
        ),
      ),
    );
  }
}

String _humanise(String raw) {
  final parts = raw.split(RegExp(r'[_\s]+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return raw;
  return parts
      .map((p) => p[0].toUpperCase() + p.substring(1).toLowerCase())
      .join(' ');
}

/// A clean "FACE ≈ FORM"-style card for a [FaceReport] — black-on-light, thin
/// hairline dividers, restrained. Renders the overall score, the per-feature
/// breakdown with score bars, quick facts, strengths / improvements, and
/// recommendations.
class FaceReportView extends StatelessWidget {
  const FaceReportView({
    super.key,
    required this.report,
    this.imageUrl,
    this.api,
    this.onCorrect,
  });

  final FaceReport report;

  /// The analysed photo, embedded at the top of the card (§ report cards).
  final String? imageUrl;

  /// Injectable for tests; the "Add this to my story" action uses it.
  final ApiClient? api;

  /// When given, the score/verdict header becomes tappable — opens the
  /// tap-a-claim conversational correction flow for this section (the unified
  /// Appearance report screen wires this; other callers of this widget, e.g.
  /// the chat inline card, leave it null and get the plain, inert header
  /// exactly as before).
  final VoidCallback? onCorrect;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final scoreHeader = _ScoreHeader(
      score: report.overallScore,
      verdict: report.verdict,
      verdictNote: report.verdictNote,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('FACIAL BEAUTY REPORT',
            style: AymaType.mono(size: 10, color: ac.fgMute)),
        const SizedBox(height: 12),
        if (imageUrl != null) ...[
          _ReportPhoto(url: imageUrl!),
          const SizedBox(height: 16),
        ],
        onCorrect == null
            ? scoreHeader
            : InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: onCorrect,
                child: scoreHeader,
              ),
        if (onCorrect != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('Tap to correct',
                style: AymaType.mono(size: 9.5, color: ac.fgMute)
                    .copyWith(letterSpacing: 0.8)),
          ),
        if (report.features.isNotEmpty) ...[
          const SizedBox(height: 20),
          _SectionLabel('FEATURE ANALYSIS'),
          const SizedBox(height: 4),
          for (final f in report.features)
            _FeatureRow(
                name: _humanise(f.name), score: f.score, note: f.note),
        ],
        if (report.quickFacts.isNotEmpty) ...[
          const SizedBox(height: 20),
          _SectionLabel('QUICK FACTS'),
          const SizedBox(height: 8),
          _QuickFacts(facts: report.quickFacts),
        ],
        if (report.strengths.isNotEmpty) ...[
          const SizedBox(height: 20),
          _SectionLabel('STRENGTHS'),
          const SizedBox(height: 8),
          for (final s in report.strengths)
            _Bullet(text: s, icon: Icons.check, color: ac.success),
        ],
        if (report.improvements.isNotEmpty) ...[
          const SizedBox(height: 20),
          _SectionLabel('AREAS FOR IMPROVEMENT'),
          const SizedBox(height: 8),
          for (final s in report.improvements)
            _Bullet(text: s, icon: Icons.circle, color: ac.fgMute, dot: true),
        ],
        if (report.recommendations.isNotEmpty) ...[
          const SizedBox(height: 20),
          _SectionLabel('RECOMMENDATIONS'),
          const SizedBox(height: 8),
          for (final r in report.recommendations)
            _RecoRow(category: _humanise(r.category), text: r.text),
        ],
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: AddToStoryButton(pageType: 'face_analysis', api: api),
        ),
        const SizedBox(height: 12),
      ],
    );
  }
}

/// A text button that pins this AI-only report into the user's public story via
/// `POST /wiki/promote`. Confirms with a toast; a server no-op is still a
/// success for the user until the endpoint ships.
class AddToStoryButton extends StatefulWidget {
  const AddToStoryButton({super.key, required this.pageType, this.api});

  final String pageType;
  final ApiClient? api;

  @override
  State<AddToStoryButton> createState() => _AddToStoryButtonState();
}

class _AddToStoryButtonState extends State<AddToStoryButton> {
  bool _busy = false;
  bool _done = false;

  Future<void> _add() async {
    if (_busy || _done) return;
    setState(() => _busy = true);
    try {
      await (widget.api ?? ApiClient()).promoteWikiPage(widget.pageType);
      if (!mounted) return;
      setState(() => _done = true);
      AymaToast.show(context, 'Added to your story.',
          kind: AymaToastKind.success);
    } catch (_) {
      if (!mounted) return;
      AymaToast.show(context, "Couldn't add that just now.",
          kind: AymaToastKind.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: _done ? null : _add,
      icon: Icon(_done ? Icons.check : Icons.auto_stories_outlined, size: 16),
      label: Text(_done ? 'In your story' : 'Add this to my story'),
    );
  }
}

/// The analysed photo shown at the top of a report card — capped height,
/// rounded, with a graceful fallback if the URL won't load.
class _ReportPhoto extends StatelessWidget {
  const _ReportPhoto({required this.url});
  final String url;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 280),
        child: Image.network(
          url,
          fit: BoxFit.cover,
          width: double.infinity,
          loadingBuilder: (c, w, p) => p == null
              ? w
              : Container(
                  height: 200,
                  color: ac.bgCard,
                  child: const Center(child: CircularProgressIndicator()),
                ),
          errorBuilder: (c, e, s) => Container(
            height: 120,
            color: ac.bgCard,
            child: Icon(Icons.broken_image_outlined, color: ac.fgMute),
          ),
        ),
      ),
    );
  }
}

class _ScoreHeader extends StatelessWidget {
  const _ScoreHeader({
    required this.score,
    required this.verdict,
    required this.verdictNote,
  });

  final double score;
  final String verdict;
  final String verdictNote;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ac.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: ac.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(score.toStringAsFixed(1),
                  style: AymaType.serif(size: 44, color: ac.fg)),
              const SizedBox(width: 4),
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text('/10',
                    style: AymaType.sans(size: 15, color: ac.fgMute)),
              ),
              const Spacer(),
              if (verdict.isNotEmpty)
                Flexible(
                  child: Text(
                    verdict,
                    textAlign: TextAlign.right,
                    style: AymaType.sans(
                        size: 14, weight: FontWeight.w600, color: ac.fg),
                  ),
                ),
            ],
          ),
          if (verdictNote.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(verdictNote,
                style: AymaType.sans(size: 13, color: ac.fgDim, height: 1.4)),
          ],
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Text(text, style: AymaType.mono(size: 10, color: ac.fgMute)),
    );
  }
}

class _FeatureRow extends StatelessWidget {
  const _FeatureRow(
      {required this.name, required this.score, required this.note});

  final String name;
  final double score;
  final String note;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(name,
                    style: AymaType.sans(
                        size: 14, weight: FontWeight.w600, color: ac.fg)),
              ),
              Text('${score.toStringAsFixed(1)}/10',
                  style: AymaType.mono(size: 11, color: ac.fgDim)),
            ],
          ),
          const SizedBox(height: 6),
          ScoreBar(value: score, max: 10),
          if (note.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(note,
                style: AymaType.sans(size: 12, color: ac.fgDim, height: 1.4)),
          ],
          const SizedBox(height: 6),
          Divider(height: 1, thickness: 1, color: ac.lineSoft),
        ],
      ),
    );
  }
}

class _QuickFacts extends StatelessWidget {
  const _QuickFacts({required this.facts});
  final Map<String, String> facts;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final entries = facts.entries.toList();
    return Column(
      children: [
        for (final e in entries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 150,
                  child: Text(_humanise(e.key),
                      style: AymaType.sans(size: 12, color: ac.fgMute)),
                ),
                Expanded(
                  child: Text(e.value,
                      style: AymaType.sans(
                          size: 12, weight: FontWeight.w600, color: ac.fg)),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet({
    required this.text,
    required this.icon,
    required this.color,
    this.dot = false,
  });

  final String text;
  final IconData icon;
  final Color color;
  final bool dot;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.only(top: dot ? 6 : 2, right: 8),
            child: Icon(icon, size: dot ? 6 : 14, color: color),
          ),
          Expanded(
            child: Text(text,
                style: AymaType.sans(size: 13, color: ac.fg, height: 1.4)),
          ),
        ],
      ),
    );
  }
}

class _RecoRow extends StatelessWidget {
  const _RecoRow({required this.category, required this.text});
  final String category;
  final String text;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(category.toUpperCase(),
              style: AymaType.mono(size: 9, color: ac.accent)),
          const SizedBox(height: 3),
          Text(text,
              style: AymaType.sans(size: 13, color: ac.fg, height: 1.4)),
        ],
      ),
    );
  }
}
