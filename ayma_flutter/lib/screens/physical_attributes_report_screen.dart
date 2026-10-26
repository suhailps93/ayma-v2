import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/app_context.dart';
import '../theme.dart';
import '../widgets/ayma_orb.dart';
import '../widgets/ayma_back_button.dart';
import '../widgets/overflow_guards.dart';

/// A stored physical-attributes report, re-opened from a `[physical:<id>]` chat
/// marker, the chat report card, or the Skills-screen history. Display-only —
/// it never runs a fresh vision pass (that happens in the chat).
class PhysicalAttributesReportScreen extends StatefulWidget {
  const PhysicalAttributesReportScreen({
    super.key,
    required this.reportId,
    this.apiClient,
  });

  static const path = '/physical-attributes/:id';

  final String reportId;
  final ApiClient? apiClient;

  @override
  State<PhysicalAttributesReportScreen> createState() =>
      _PhysicalAttributesReportScreenState();
}

class _PhysicalAttributesReportScreenState
    extends State<PhysicalAttributesReportScreen>
    with ScreenContextReasserter<PhysicalAttributesReportScreen> {
  late final ApiClient _api = widget.apiClient ?? ApiClient();
  late Future<PhysicalReport> _future = _api.physicalReport(widget.reportId);

  @override
  void initState() {
    super.initState();
    reassertScreenContext();
  }

  @override
  void reassertScreenContext() =>
      AppContext.instance.set(screen: 'physical_report');

  void _reload() =>
      setState(() => _future = _api.physicalReport(widget.reportId));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: const AymaBackButton(),
        title: const Text('Physical profile')),
      body: FutureBuilder<PhysicalReport>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: AymaOrb(size: 64, state: AymaOrbState.thinking));
          }
          if (snap.hasError || snap.data == null) {
            return _Message(
              text: "Couldn't load that report.",
              onRetry: _reload,
            );
          }
          return _Report(r: snap.data!);
        },
      ),
    );
  }
}

// Field -> human label, in the same stable order the API returns.
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

class _Report extends StatelessWidget {
  const _Report({required this.r});

  final PhysicalReport r;

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
    final stated = r.stated;
    final photos =
        r.fromPhotos.where((a) => a.field != 'distinguishing_features').toList();
    String notable = '';
    for (final a in r.attributes) {
      if (a.field == 'distinguishing_features') notable = a.value;
    }

    if (stated.isEmpty && photos.isEmpty && notable.isEmpty) {
      return const _Message(
        text: "No physical attributes were read for this run — add a clear "
            'photo and run it again from the Skills screen.',
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
      children: [
        Row(
          children: [
            Icon(Icons.badge_outlined, size: 34, color: ac.fgMute),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Physical profile',
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
        if (stated.isNotEmpty) ...[
          _SectionHead(label: 'FROM YOUR ANSWERS'),
          const SizedBox(height: 8),
          for (final a in stated) _Row(a: a),
          const SizedBox(height: 20),
        ],
        if (photos.isNotEmpty) ...[
          _SectionHead(label: 'READ FROM YOUR PHOTOS'),
          const SizedBox(height: 8),
          for (final a in photos) _Row(a: a),
          const SizedBox(height: 20),
        ],
        if (notable.isNotEmpty) ...[
          _SectionHead(label: 'NOTABLE FEATURES'),
          const SizedBox(height: 8),
          Text(notable,
              style: AymaType.sans(size: 14, color: ac.fg, height: 1.4)),
          const SizedBox(height: 20),
        ],
        Divider(height: 0.5, color: ac.lineSoft),
        const SizedBox(height: 12),
        Text(
          'Stated values are your own answers and always win. Photo values are '
          "apparent only — Ayma's read of your pictures, lower confidence. This "
          'profile feeds your matching and Explore search.',
          style: AymaType.sans(size: 12, soft: true, color: ac.fgMute),
        ),
      ],
    );
  }
}

class _SectionHead extends StatelessWidget {
  const _SectionHead({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Text(
        label,
        style: AymaType.mono(size: 10, color: context.ac.fgMute)
            .copyWith(letterSpacing: 1.4),
      );
}

class _Row extends StatelessWidget {
  const _Row({required this.a});

  final PhysicalAttribute a;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ConfidenceDot(confidence: a.isStated ? 'high' : a.confidence),
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

class _ConfidenceDot extends StatelessWidget {
  const _ConfidenceDot({required this.confidence});

  final String confidence;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final c = switch (confidence) {
      'high' => ac.accent,
      'medium' => ac.accent.withValues(alpha: 0.55),
      _ => ac.fgMute.withValues(alpha: 0.5),
    };
    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(color: c, shape: BoxShape.circle),
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
    return CenteredScroll(
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
    );
  }
}
