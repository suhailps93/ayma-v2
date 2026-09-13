import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../services/api_client.dart';
import '../services/chat_inbox.dart';
import '../services/chat_service.dart';
import '../theme.dart';
import '../widgets/body_report_view.dart';
import '../widgets/face_report_view.dart';
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

/// A stored **Appearance** report — the unified read of the user's photos:
/// structured attributes, an honest face analysis and an honest physique
/// analysis. Re-opened from an `[appearance:<id>]` chat marker, the chat report
/// card, or the Skills-screen history. Display-only — it never runs a fresh
/// pass (that happens in the chat).
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

  Future<_ResolvedAppearance> _load() =>
      _loadAndResolve(_api, widget.reportId, widget.photoUrlResolver);

  void _reload() => setState(() => _future = _load());

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
            return const Center(child: CircularProgressIndicator());
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
    required this.onAddFace,
    required this.onAddBody,
  });

  final AppearanceReport r;
  final ApiClient api;
  final String? faceUrl;
  final String? bodyUrl;
  final List<String> attributesUrls;
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

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
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
        const SizedBox(height: 24),

        // --- Attributes
        _SectionHead(label: 'ATTRIBUTES'),
        const SizedBox(height: 8),
        if (attributesUrls.isNotEmpty) ...[
          _PhotoStrip(label: 'Used for attributes', urls: attributesUrls),
          const SizedBox(height: 12),
        ],
        _AttributesSection(r: r),
        const SizedBox(height: 28),

        // --- Face
        _SectionHead(label: 'FACE'),
        const SizedBox(height: 10),
        if (r.face != null)
          FaceReportView(report: r.face!, imageUrl: faceUrl, api: api)
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
        if (r.body != null)
          BodyReportView(report: r.body!, imageUrl: bodyUrl, api: api)
        else
          _StubCard(
            icon: Icons.accessibility_new,
            text: 'Add a full-length photo to include this.',
            actionLabel: 'Add a full-length photo',
            onTap: onAddBody,
          ),

        const SizedBox(height: 28),
        Divider(height: 0.5, color: ac.lineSoft),
        const SizedBox(height: 12),
        Text(
          'Stated attributes are your own answers and always win. Everything '
          "else is Ayma's read of your pictures — apparent only, lower "
          'confidence. This feeds your matching and Explore search.',
          style: AymaType.sans(size: 12, soft: true, color: ac.fgMute),
        ),
      ],
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

class _AttributesSection extends StatelessWidget {
  const _AttributesSection({required this.r});

  final AppearanceReport r;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final stated = r.statedAttributes;
    final photos = r.photoAttributes
        .where((a) => a.field != 'distinguishing_features')
        .toList();
    String notable = '';
    for (final a in r.attributes) {
      if (a.field == 'distinguishing_features') notable = a.value;
    }

    if (stated.isEmpty && photos.isEmpty && notable.isEmpty) {
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
          for (final a in stated) _AttrRow(a: a),
          const SizedBox(height: 14),
        ],
        if (photos.isNotEmpty) ...[
          _SubHead(label: 'READ FROM YOUR PHOTOS'),
          for (final a in photos) _AttrRow(a: a),
          const SizedBox(height: 14),
        ],
        if (notable.isNotEmpty) ...[
          _SubHead(label: 'NOTABLE FEATURES'),
          const SizedBox(height: 4),
          Text(notable,
              style: AymaType.sans(size: 14, color: ac.fg, height: 1.4)),
        ],
      ],
    );
  }
}

class _AttrRow extends StatelessWidget {
  const _AttrRow({required this.a});

  final PhysicalAttribute a;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final confidence = a.isStated ? 'high' : a.confidence;
    final c = switch (confidence) {
      'high' => ac.accent,
      'medium' => ac.accent.withValues(alpha: 0.55),
      _ => ac.fgMute.withValues(alpha: 0.5),
    };
    return Padding(
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
        ],
      ),
    );
  }
}

class _SectionHead extends StatelessWidget {
  const _SectionHead({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Text(
        label,
        style: AymaType.mono(size: 11, color: context.ac.fg)
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
