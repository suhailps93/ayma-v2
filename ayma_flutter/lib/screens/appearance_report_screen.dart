import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../services/api_client.dart';
import '../services/chat_inbox.dart';
import '../services/chat_service.dart';
import '../theme.dart';
import '../widgets/ayma_orb.dart';
import '../widgets/body_report_view.dart';
import '../widgets/face_report_view.dart';
import '../widgets/finding_correction_sheet.dart';
import 'main_shell_screen.dart';
import '../widgets/photo_gallery.dart' show PhotoViewer;

/// Resolves a Storage path to a viewable URL — [resolvePhotoUrl] in
/// production, an injected fake in tests.
typedef PhotoUrlResolver = Future<String?> Function(String path);

/// An [AppearanceReport] plus every Storage path it references already
/// resolved to a viewable URL — the face / physique photo (at most one each)
/// and every photo that fed the attributes read. A path that fails to
/// resolve (or a report with none at all) is simply absent, never a crash.
class _ResolvedAppearance {
  const _ResolvedAppearance(
    this.report, {
    this.faceUrl,
    this.bodyUrl,
    this.attributesUrls = const [],
  });

  final AppearanceReport report;
  final String? faceUrl;
  final String? bodyUrl;
  final List<String> attributesUrls;
}

Future<_ResolvedAppearance> _loadAndResolve(
  ApiClient api,
  String reportId,
  PhotoUrlResolver resolve,
) async {
  final report = await api.appearanceReport(reportId);
  final facePhotos = report.face?.sourcePhotos ?? const [];
  final bodyPhotos = report.body?.sourcePhotos ?? const [];
  final faceUrl = facePhotos.isEmpty ? null : await resolve(facePhotos.first);
  final bodyUrl = bodyPhotos.isEmpty ? null : await resolve(bodyPhotos.first);
  final attrUrls = await Future.wait(
    report.attributesSourcePhotos.map(resolve),
  );
  return _ResolvedAppearance(
    report,
    faceUrl: faceUrl,
    bodyUrl: bodyUrl,
    attributesUrls: [for (final u in attrUrls) if (u != null) u],
  );
}

/// A stored **Appearance** report — the unified, persistent, ever-correctable
/// read of the user's photos: structured attributes, an honest face analysis
/// and an honest physique analysis, plus a headline score. Re-opened from an
/// `[appearance:<id>]` chat marker, the chat report card, or the Skills
/// screen's "View my report" link. Every finding — an attribute, or the
/// face/physique read as a whole — is corrected in your own words via the
/// same tap-a-claim conversational pattern Your Story's "Edit with Ayma"
/// uses, never a structured field editor. Display-only otherwise — it never
/// runs a fresh pass itself (that happens in the chat).
class AppearanceReportScreen extends StatefulWidget {
  const AppearanceReportScreen({
    super.key,
    required this.reportId,
    this.apiClient,
    this.imagePicker,
    this.chatService,
    this.photoUrlResolver = resolvePhotoUrl,
  });

  static const path = '/appearance/:id';

  final String reportId;
  final ApiClient? apiClient;
  final ImagePicker? imagePicker;
  final ChatService? chatService;

  /// Injectable for tests; production resolves through Firebase Storage.
  final PhotoUrlResolver photoUrlResolver;

  @override
  State<AppearanceReportScreen> createState() => _AppearanceReportScreenState();
}

class _AppearanceReportScreenState extends State<AppearanceReportScreen> {
  late final ApiClient _api = widget.apiClient ?? ApiClient();
  late final ImagePicker _picker = widget.imagePicker ?? ImagePicker();
  late final ChatService _chat = widget.chatService ?? ChatService();
  late Future<_ResolvedAppearance> _future = _load();

  // Corrections saved during this screen visit, overlaid on top of the loaded
  // report so a save shows up immediately — without re-fetching (the
  // correction itself already persisted server-side, in place on this same
  // report, so reopening it later shows the same thing).
  final Map<String, PhysicalAttribute> _attrCorrections = {};
  String? _faceNoteOverride;
  String? _bodyNoteOverride;

  Future<_ResolvedAppearance> _load() =>
      _loadAndResolve(_api, widget.reportId, widget.photoUrlResolver);

  void _reload() => setState(() => _future = _load());

  void _applyAttrCorrection(PhysicalAttribute updated) =>
      setState(() => _attrCorrections[updated.field] = updated);

  void _applyFaceNote(String note) => setState(() => _faceNoteOverride = note);
  void _applyBodyNote(String note) => setState(() => _bodyNoteOverride = note);

  /// Hand a fresh Appearance run to the Ayma chat with just the missing
  /// section wanted, after uploading a photo picked from the gallery.
  Future<void> _addPhotoAndRerun({
    required bool wantFace,
    required bool wantBody,
  }) async {
    final XFile? picked;
    try {
      picked = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        imageQuality: 88,
      );
    } catch (_) {
      _snack("Couldn't open your gallery — try again.");
      return;
    }
    if (picked == null || !mounted) return;
    String path;
    try {
      final up = await _chat.uploadChatImage(File(picked.path));
      path = up.storagePath;
    } catch (_) {
      _snack("Couldn't upload that photo — try again.");
      return;
    }
    if (!mounted) return;
    ChatInbox.instance.push(ChatKickoff.appearance(
      extraPaths: [path],
      wantFace: wantFace,
      wantBody: wantBody,
      useAllPhotos: true,
    ));
    context.go(MainShellScreen.path);
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Appearance')),
      body: FutureBuilder<_ResolvedAppearance>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: AymaOrb(size: 64, state: AymaOrbState.thinking));
          }
          final resolved = snap.data;
          if (snap.hasError || resolved == null) {
            return _Message(
              text: "Couldn't load that report.",
              onRetry: _reload,
            );
          }
          return _Body(
            r: resolved.report,
            api: _api,
            faceUrl: resolved.faceUrl,
            bodyUrl: resolved.bodyUrl,
            attributesUrls: resolved.attributesUrls,
            attrCorrections: _attrCorrections,
            faceNoteOverride: _faceNoteOverride,
            bodyNoteOverride: _bodyNoteOverride,
            onAttrCorrected: _applyAttrCorrection,
            onFaceNoteCorrected: _applyFaceNote,
            onBodyNoteCorrected: _applyBodyNote,
            onAddFace: () => _addPhotoAndRerun(wantFace: true, wantBody: false),
            onAddBody: () => _addPhotoAndRerun(wantFace: false, wantBody: true),
          );
        },
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.r,
    required this.api,
    this.faceUrl,
    this.bodyUrl,
    this.attributesUrls = const [],
    required this.attrCorrections,
    required this.faceNoteOverride,
    required this.bodyNoteOverride,
    required this.onAttrCorrected,
    required this.onFaceNoteCorrected,
    required this.onBodyNoteCorrected,
    required this.onAddFace,
    required this.onAddBody,
  });

  final AppearanceReport r;
  final ApiClient api;
  final String? faceUrl;
  final String? bodyUrl;
  final List<String> attributesUrls;
  final Map<String, PhysicalAttribute> attrCorrections;
  final String? faceNoteOverride;
  final String? bodyNoteOverride;
  final ValueChanged<PhysicalAttribute> onAttrCorrected;
  final ValueChanged<String> onFaceNoteCorrected;
  final ValueChanged<String> onBodyNoteCorrected;
  final VoidCallback onAddFace;
  final VoidCallback onAddBody;

  String get _when {
    final iso = r.createdAt;
    if (iso == null) return '';
    final d = DateTime.tryParse(iso);
    if (d == null) return '';
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${d.day} ${months[d.month - 1]} ${d.year}';
  }

  Future<void> _correctFace(BuildContext context) async {
    final face = r.face;
    if (face == null) return;
    final current = faceNoteOverride ?? face.verdictNote;
    await showFindingCorrectionSheet(
      context,
      title: 'Face',
      currentValue: current.isNotEmpty ? current : face.verdict,
      onSend: (message) async {
        final res = await api.correctAppearanceFinding(
          findingId: 'face', message: message,
        );
        if (!res.usageCapped) {
          onFaceNoteCorrected(res.value?.toString() ?? current);
        }
        return CorrectionReply(text: res.reply, usageCapped: res.usageCapped);
      },
    );
  }

  Future<void> _correctBody(BuildContext context) async {
    final body = r.body;
    if (body == null) return;
    final current = bodyNoteOverride ?? body.verdictNote;
    await showFindingCorrectionSheet(
      context,
      title: 'Physique',
      currentValue: current.isNotEmpty ? current : body.verdict,
      onSend: (message) async {
        final res = await api.correctAppearanceFinding(
          findingId: 'body', message: message,
        );
        if (!res.usageCapped) {
          onBodyNoteCorrected(res.value?.toString() ?? current);
        }
        return CorrectionReply(text: res.reply, usageCapped: res.usageCapped);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final face = r.face == null || faceNoteOverride == null
        ? r.face
        : _withFaceNote(r.face!, faceNoteOverride!);
    final body = r.body == null || bodyNoteOverride == null
        ? r.body
        : _withBodyNote(r.body!, bodyNoteOverride!);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
      children: [
        Row(
          children: [
            Icon(Icons.auto_awesome_outlined, size: 32, color: ac.fgMute),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Appearance',
                      style: AymaType.serif(size: 22, color: ac.fg)),
                  Text(
                    [
                      if (r.photoCount > 0) '${r.photoCount} photos',
                      if (_when.isNotEmpty) _when,
                    ].join('  ·  ').toUpperCase(),
                    style: AymaType.mono(size: 9, color: ac.fgMute)
                        .copyWith(letterSpacing: 1.2),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),

        // --- Overall (the one report-level score — an average of whichever
        // of face/physique are known; distinct from the Face and Physique
        // sections below, which each show their own score). Given its own
        // section head, like every section below it, so it never reads as
        // belonging to the section that happens to follow it.
        _SectionHead(label: 'OVERALL'),
        const SizedBox(height: 10),
        _ScoreBanner(value: r.scoreValue, basis: r.scoreBasis),
        const SizedBox(height: 28),

        // --- Attributes
        _SectionHead(label: 'ATTRIBUTES'),
        const SizedBox(height: 8),
        if (attributesUrls.isNotEmpty) ...[
          _PhotoStrip(label: 'Used for attributes', urls: attributesUrls),
          const SizedBox(height: 12),
        ],
        _AttributesSection(
          r: r,
          api: api,
          corrections: attrCorrections,
          onCorrected: onAttrCorrected,
        ),
        const SizedBox(height: 28),

        // --- Face
        _SectionHead(label: 'FACE'),
        const SizedBox(height: 10),
        if (face != null)
          FaceReportView(
            report: face,
            imageUrl: faceUrl,
            api: api,
            onCorrect: () => _correctFace(context),
          )
        else
          _StubCard(
            icon: Icons.face_retouching_natural,
            text: 'Add a clear face photo to include this.',
            actionLabel: 'Add a face photo',
            onTap: onAddFace,
          ),
        const SizedBox(height: 28),

        // --- Physique
        _SectionHead(label: 'PHYSIQUE'),
        const SizedBox(height: 10),
        if (body != null)
          BodyReportView(
            report: body,
            imageUrl: bodyUrl,
            api: api,
            onCorrect: () => _correctBody(context),
          )
        else
          _StubCard(
            icon: Icons.accessibility_new,
            text: 'Add a photo showing your upper body or more to include '
                'this.',
            actionLabel: 'Add a body photo',
            onTap: onAddBody,
          ),

        const SizedBox(height: 28),
        Divider(height: 0.5, color: ac.lineSoft),
        const SizedBox(height: 12),
        Text(
          "Tap any finding to correct it — tell Ayma what's wrong in your "
          'own words. Stated attributes are your own answers and always win. '
          "Everything else is Ayma's read of your pictures — apparent only, "
          'lower confidence. This feeds your matching and Explore search.',
          style: AymaType.sans(size: 12, soft: true, color: ac.fgMute),
        ),
      ],
    );
  }
}

/// Rebuilds [r] with a corrected [verdictNote] — every other field carried
/// over unchanged. `FaceReport` has no `copyWith`; this keeps that override
/// local to this screen rather than growing the shared model's surface.
FaceReport _withFaceNote(FaceReport r, String verdictNote) => FaceReport(
      usable: r.usable,
      overallScore: r.overallScore,
      verdict: r.verdict,
      verdictNote: verdictNote,
      features: r.features,
      quickFacts: r.quickFacts,
      strengths: r.strengths,
      improvements: r.improvements,
      recommendations: r.recommendations,
      sourcePhotos: r.sourcePhotos,
    );

BodyReport _withBodyNote(BodyReport r, String verdictNote) => BodyReport(
      usable: r.usable,
      overallScore: r.overallScore,
      verdict: r.verdict,
      verdictNote: verdictNote,
      features: r.features,
      quickFacts: r.quickFacts,
      strengths: r.strengths,
      improvements: r.improvements,
      recommendations: r.recommendations,
      sourcePhotos: r.sourcePhotos,
    );

/// The headline score, shown prominently up top — an honest average of
/// whichever of the face / physique reads are available. `null` gets a soft
/// explanatory placeholder instead of a dash or a zero.
///
/// [basis] is the backend's terse machine tag (`"face"` / `"body"` /
/// `"face+body"` / `"none"` — see `_compute_score` in `appearance.py`), NOT
/// display copy — it must never be shown to the user verbatim. [_explanation]
/// translates it into an actual sentence.
class _ScoreBanner extends StatelessWidget {
  const _ScoreBanner({required this.value, required this.basis});

  final double? value;
  final String basis;

  String get _explanation => switch (basis) {
        'face' => 'Based on your face photo.',
        'body' => 'Based on your physique photo.',
        'face+body' => 'Based on your face and physique photos.',
        _ => 'Add a clear face or body photo to get your score.',
      };

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: ac.bgCard,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: ac.line),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (value != null) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(value!.toStringAsFixed(1),
                    style: AymaType.serif(size: 40, color: ac.fg)),
                Padding(
                  padding: const EdgeInsets.only(bottom: 4, left: 3),
                  child: Text('/10',
                      style: AymaType.sans(size: 14, color: ac.fgMute)),
                ),
              ],
            ),
            const SizedBox(width: 16),
          ] else ...[
            Icon(Icons.bar_chart_rounded, size: 32, color: ac.fgMute),
            const SizedBox(width: 16),
          ],
          Expanded(
            child: Text(
              _explanation,
              style: AymaType.sans(size: 12.5, color: ac.fgMute).copyWith(height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

// Field -> human label, in the API's stable order.
const _labels = <String, String>{
  'race_ethnicity': 'Ethnicity (apparent)',
  'skin_tone': 'Skin tone',
  'eye_color': 'Eyes',
  'hair_color': 'Hair colour',
  'hair_length': 'Hair length',
  'hair_type': 'Hair type',
  'height_estimate_cm': 'Height (rough)',
  'weight_estimate_kg': 'Weight (rough)',
  'build': 'Build',
  'facial_hair': 'Facial hair',
  'glasses': 'Glasses',
  'visible_tattoos': 'Tattoos',
  'visible_piercings': 'Piercings',
  'distinguishing_features': 'Notable features',
};

String _label(String field) => _labels[field] ?? field.replaceAll('_', ' ');

String _value(PhysicalAttribute a) {
  if (a.field == 'height_estimate_cm') return '~${a.value} cm';
  if (a.field == 'weight_estimate_kg') return '~${a.value} kg';
  final v = a.value;
  return v.isEmpty ? v : v[0].toUpperCase() + v.substring(1);
}

/// Overlay locally-saved [corrections] onto the loaded [original] list — a
/// corrected field is a match by field name and always reflects the save
/// (source `stated`, confidence `high`), immediately moving it into "FROM
/// YOUR ANSWERS" on the next build without a re-fetch.
List<PhysicalAttribute> _mergeAttributes(
  List<PhysicalAttribute> original,
  Map<String, PhysicalAttribute> corrections,
) =>
    [for (final a in original) corrections[a.field] ?? a];

class _AttributesSection extends StatelessWidget {
  const _AttributesSection({
    required this.r,
    required this.api,
    required this.corrections,
    required this.onCorrected,
  });

  final AppearanceReport r;
  final ApiClient api;
  final Map<String, PhysicalAttribute> corrections;
  final ValueChanged<PhysicalAttribute> onCorrected;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final merged = _mergeAttributes(r.attributes, corrections);
    final stated = merged
        .where((a) => a.isStated && a.field != 'distinguishing_features')
        .toList();
    final photos = merged
        .where((a) => !a.isStated && a.field != 'distinguishing_features')
        .toList();
    PhysicalAttribute? notable;
    for (final a in merged) {
      if (a.field == 'distinguishing_features') notable = a;
    }

    if (stated.isEmpty && photos.isEmpty && notable == null) {
      return Text(
        r.attributesSummary.isNotEmpty
            ? r.attributesSummary
            : 'No structured attributes were read for this run.',
        style: AymaType.sans(size: 13, color: ac.fgMute),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (stated.isNotEmpty) ...[
          _SubHead(label: 'FROM YOUR ANSWERS'),
          for (final a in stated)
            _AttrRow(a: a, api: api, onCorrected: onCorrected),
          const SizedBox(height: 14),
        ],
        if (photos.isNotEmpty) ...[
          _SubHead(label: 'READ FROM YOUR PHOTOS'),
          for (final a in photos)
            _AttrRow(a: a, api: api, onCorrected: onCorrected),
          const SizedBox(height: 14),
        ],
        if (notable != null) ...[
          _SubHead(label: 'NOTABLE FEATURES'),
          const SizedBox(height: 4),
          InkWell(
            onTap: () => _correctAttribute(context, api: api, a: notable!, onSaved: onCorrected),
            child: Text(notable.value,
                style: AymaType.sans(size: 14, color: ac.fg, height: 1.4)),
          ),
        ],
      ],
    );
  }
}

/// One attribute row — tap opens the tap-a-claim conversational correction
/// sheet (§ appearance corrections), scoped to this one field.
class _AttrRow extends StatelessWidget {
  const _AttrRow({
    required this.a,
    required this.api,
    required this.onCorrected,
  });

  final PhysicalAttribute a;
  final ApiClient api;
  final ValueChanged<PhysicalAttribute> onCorrected;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final confidence = a.isStated ? 'high' : a.confidence;
    final c = switch (confidence) {
      'high' => ac.accent,
      'medium' => ac.accent.withValues(alpha: 0.55),
      _ => ac.fgMute.withValues(alpha: 0.5),
    };
    return InkWell(
      onTap: () => _correctAttribute(context, api: api, a: a, onSaved: onCorrected),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(color: c, shape: BoxShape.circle),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 128,
              child: Text(_label(a.field),
                  style: AymaType.sans(size: 13, color: ac.fgMute)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(_value(a),
                  style: AymaType.sans(size: 14, color: ac.fg, height: 1.35)),
            ),
            Icon(Icons.chat_bubble_outline,
                size: 14, color: ac.fgMute.withValues(alpha: 0.4)),
          ],
        ),
      ),
    );
  }
}

/// Opens the tap-a-claim correction sheet for one attribute [a] and, on a
/// successful (non-capped) save, calls [onSaved] with the corrected
/// attribute (`source: stated`, `confidence: high`) so the caller can update
/// the displayed view immediately.
Future<void> _correctAttribute(
  BuildContext context, {
  required ApiClient api,
  required PhysicalAttribute a,
  required ValueChanged<PhysicalAttribute> onSaved,
}) {
  return showFindingCorrectionSheet(
    context,
    title: _label(a.field),
    currentValue: _value(a),
    onSend: (message) async {
      final res = await api.correctAppearanceFinding(
        findingId: a.field, message: message,
      );
      if (!res.usageCapped && res.value != null) {
        onSaved(PhysicalAttribute(
          field: a.field,
          value: res.value.toString(),
          source: 'stated',
          confidence: 'high',
        ));
      }
      return CorrectionReply(text: res.reply, usageCapped: res.usageCapped);
    },
  );
}

class _SectionHead extends StatelessWidget {
  const _SectionHead({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Text(
        label,
        style: AymaType.mono(size: 15, color: context.ac.fg)
            .copyWith(letterSpacing: 1.6),
      );
}

/// A horizontal strip of thumbnails for every photo that contributed to one
/// part of the report (e.g. attributes, which can read several) — tap any
/// one to zoom, the same [PhotoViewer] the photo gallery already uses.
class _PhotoStrip extends StatelessWidget {
  const _PhotoStrip({required this.label, required this.urls});

  final String label;
  final List<String> urls;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SubHead(label: label.toUpperCase()),
        SizedBox(
          height: 76,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: urls.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              final url = urls[i];
              return GestureDetector(
                onTap: () => showDialog<void>(
                  context: context,
                  builder: (_) => PhotoViewer(url: url),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.network(
                    url,
                    width: 76,
                    height: 76,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      width: 76,
                      height: 76,
                      color: ac.bgCard,
                      child: Icon(Icons.broken_image_outlined,
                          color: ac.fgMute, size: 18),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _SubHead extends StatelessWidget {
  const _SubHead({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(
          label,
          style: AymaType.mono(size: 10, color: context.ac.fgMute)
              .copyWith(letterSpacing: 1.4),
        ),
      );
}

class _StubCard extends StatelessWidget {
  const _StubCard({
    required this.icon,
    required this.text,
    required this.actionLabel,
    required this.onTap,
  });

  final IconData icon;
  final String text;
  final String actionLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ac.bgElev,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: ac.lineSoft, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: ac.fgMute),
              const SizedBox(width: 12),
              Expanded(
                child: Text(text,
                    style: AymaType.sans(size: 13, color: ac.fgDim)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(onPressed: onTap, child: Text(actionLabel)),
          ),
        ],
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
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(text,
                textAlign: TextAlign.center,
                style: AymaType.sans(size: 14, color: ac.fgMute)),
            if (onRetry != null)
              TextButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
