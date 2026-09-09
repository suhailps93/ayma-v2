import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/api_client.dart';
import '../theme.dart';
import '../widgets/ayma_photo.dart';

/// A stored web deep dive on one person, re-opened from a `[deep_dive:<id>]`
/// chat marker or the "View research" button on a profile. Display-only — it
/// never runs a fresh search (that happens in the chat).
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
  late Future<DeepDiveReport> _future = _api.deepDiveReport(widget.reportId);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Web research')),
      body: FutureBuilder<DeepDiveReport>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError || snap.data == null) {
            return _Message(
              text: "Couldn't load that research.",
              onRetry: () => setState(
                  () => _future = _api.deepDiveReport(widget.reportId)),
            );
          }
          return _Report(r: snap.data!);
        },
      ),
    );
  }
}

class _Report extends StatelessWidget {
  const _Report({required this.r});

  final DeepDiveReport r;

  Future<void> _open(String url) =>
      launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final them = r.links.where((l) => l.isThem == 'likely').toList();
    final maybe = r.links.where((l) => l.isThem != 'likely').toList();
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
        if (r.summary.isNotEmpty)
          Text(r.summary,
              style: AymaType.serif(size: 16, color: ac.fg).copyWith(height: 1.5)),
        if (r.facts.isNotEmpty) ...[
          const SizedBox(height: 24),
          Text('WHAT IT FOUND',
              style: AymaType.mono(size: 10, color: ac.fgMute)
                  .copyWith(letterSpacing: 1.4)),
          const SizedBox(height: 8),
          for (final f in r.facts) _Fact(f: f, onOpen: _open),
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

class _Fact extends StatelessWidget {
  const _Fact({required this.f, required this.onOpen});

  final DeepDiveFact f;
  final Future<void> Function(String) onOpen;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final conf = f.confidence.isEmpty ? '' : ' · ${f.confidence}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('• ${f.claim}',
              style: AymaType.sans(size: 14, color: ac.fg, height: 1.4)),
          if (f.sourceUrl.isNotEmpty || f.category.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 14, top: 2),
              child: GestureDetector(
                onTap:
                    f.sourceUrl.isEmpty ? null : () => onOpen(f.sourceUrl),
                child: Text(
                  '${f.category}$conf'
                  '${f.sourceUrl.isEmpty ? '' : '  ·  source ↗'}',
                  style: AymaType.mono(
                      size: 9,
                      color: f.sourceUrl.isEmpty ? ac.fgMute : ac.accent),
                ),
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
