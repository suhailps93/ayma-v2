import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';

import '../models/story_node.dart';
import '../services/api_client.dart';
import '../services/auto_retry.dart';
import '../theme.dart';
import 'ayma_toast.dart';
import 'ayma_wing_loader.dart';
import 'node_visualiser.dart';

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

/// A stored face report as its display sections plus a resolved URL for the
/// photo it was run on. Used by both the chat inline card and the
/// Skills-screen history.
class StoredFaceReport {
  const StoredFaceReport({this.sections = const [], this.imageUrl});
  final List<GraphTreeSection> sections;
  final String? imageUrl;
}

/// Fetch a stored face report by id and resolve its photo URL.
Future<StoredFaceReport> fetchStoredFaceReport(
  String reportId, {
  ApiClient? api,
}) async {
  final r = await (api ?? ApiClient()).skillReport('face', reportId);
  return StoredFaceReport(
    sections: r.sections,
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
  // Auto-retry a transient load failure before showing the error (founder
  // 2026-11-01). The GET is idempotent; worst case stays bounded.
  late final Future<StoredFaceReport> _future = withAutoRetry(
      () => fetchStoredFaceReport(widget.reportId, api: widget.api));

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
              // GET /skills/report/face/{id} (+ photo URL) still in flight.
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: AymaWingLoader(lines: AymaLoaderLines.faceReport),
                ),
              );
            }
            final sections = snap.data?.sections ?? const [];
            if (snap.hasError || sections.isEmpty) {
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
                FaceReportView(
                  sections: sections,
                  imageUrl: snap.data?.imageUrl,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// A stored Face report — the score as text ("Face 6.9/10" with its band),
/// every element labelled, "What to do next" last — rendered from the
/// server's node tree with the SAME [NodeVisualiserSection] the Appearance
/// screen uses for its Face/Body sections.
class FaceReportView extends StatelessWidget {
  const FaceReportView({
    super.key,
    required this.sections,
    this.imageUrl,
    this.api,
  });

  final List<GraphTreeSection> sections;

  /// The analysed photo, embedded at the top of the card (§ report cards).
  final String? imageUrl;

  /// Injectable for tests; the "Add this to my story" action uses it.
  final ApiClient? api;

  @override
  Widget build(BuildContext context) => ScoredReadView(
        title: 'FACIAL BEAUTY REPORT',
        sections: sections,
        imageUrl: imageUrl,
        storyPageType: 'face_analysis',
        api: api,
      );
}

/// The shared Face/Body read card: a small title, the analysed photo, the
/// report's sections through [NodeVisualiserSection] on the report surface,
/// and the "Add this to my story" action. Display-only — the rows are not
/// tap targets here (a tap on the chat card opens the full report).
class ScoredReadView extends StatelessWidget {
  const ScoredReadView({
    super.key,
    required this.title,
    required this.sections,
    required this.storyPageType,
    this.imageUrl,
    this.api,
  });

  final String title;
  final List<GraphTreeSection> sections;
  final String storyPageType;
  final String? imageUrl;
  final ApiClient? api;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: AymaType.mono(size: 10, color: ac.fgMute)),
        const SizedBox(height: 12),
        if (imageUrl != null) ...[
          _ReportPhoto(url: imageUrl!),
          const SizedBox(height: 16),
        ],
        IgnorePointer(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (i, section) in sections.indexed)
                NodeVisualiserSection(
                  key: Key('scored_read_section_$i'),
                  section: section,
                  surface: NodeVisualiserSurface.report,
                  api: api,
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: AddToStoryButton(pageType: storyPageType, api: api),
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
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 48),
      ),
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
      borderRadius: BorderRadius.circular(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 320),
        child: Image.network(
          url,
          fit: BoxFit.cover,
          width: double.infinity,
          loadingBuilder: (c, w, p) => p == null
              ? w
              : Container(
                  height: 220,
                  color: ac.bgCard,
                  child: const Center(
                    child: AymaWingLoader(
                      size: 40,
                      lines: AymaLoaderLines.photo,
                    ),
                  ),
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
