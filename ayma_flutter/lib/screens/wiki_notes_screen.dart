import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/api_client.dart';
import '../theme.dart';
import '../widgets/markdown_text.dart';

/// Debug view of what Ayma holds about the user: the compiled wiki context she
/// reads (the `ai_body` of every page, rendered as Markdown) plus every photo
/// she has — profile-grid photos and images sent in the Ayma chat. Temporary;
/// remove before launch.
class WikiNotesScreen extends StatefulWidget {
  const WikiNotesScreen({super.key, this.apiClient});

  static const path = '/debug/ai-notes';

  final ApiClient? apiClient;

  @override
  State<WikiNotesScreen> createState() => _WikiNotesScreenState();
}

class _WikiNotesScreenState extends State<WikiNotesScreen> {
  late final ApiClient _api = widget.apiClient ?? ApiClient();
  late Future<AiNotes> _future = _api.aiNotes();

  void _refresh() => setState(() => _future = _api.aiNotes());

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI notes'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
      ),
      body: FutureBuilder<AiNotes>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Could not load (${snap.error}).',
                    style: AymaType.sans(size: 13, color: AymaColors.error)),
              ),
            );
          }
          final notes = snap.data ?? const AiNotes(text: '');
          final text = notes.text.trim();
          if (text.isEmpty && notes.photos.isEmpty) {
            return Center(
              child: Text('Ayma has no compiled notes about you yet.',
                  style: AymaType.sans(size: 14, color: ac.fgMute)),
            );
          }
          return Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (notes.photos.isNotEmpty) ...[
                        Text(
                          'PHOTOS AYMA HAS (${notes.photos.length})',
                          style: AymaType.mono(size: 10, color: ac.fgMute)
                              .copyWith(letterSpacing: 1.4),
                        ),
                        const SizedBox(height: 10),
                        _PhotoGallery(photos: notes.photos),
                        const SizedBox(height: 20),
                        Divider(height: 1, color: ac.lineSoft),
                        const SizedBox(height: 16),
                      ],
                      if (text.isEmpty)
                        Text('No compiled notes yet.',
                            style:
                                AymaType.sans(size: 13, color: ac.fgMute))
                      else
                        MarkdownText(
                          text,
                          style: AymaType.sans(size: 13, color: ac.fg)
                              .copyWith(height: 1.5),
                          linkColor: ac.accent,
                        ),
                    ],
                  ),
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: OutlinedButton.icon(
                    onPressed: text.isEmpty
                        ? null
                        : () {
                            Clipboard.setData(ClipboardData(text: notes.text));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Copied')),
                            );
                          },
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('Copy all'),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// A wrap of square thumbnails; tapping one opens a full-screen zoomable viewer.
class _PhotoGallery extends StatelessWidget {
  const _PhotoGallery({required this.photos});

  final List<AiNotePhoto> photos;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final p in photos)
          InkWell(
            onTap: () => showDialog<void>(
              context: context,
              builder: (_) => _PhotoViewer(url: p.url),
            ),
            child: Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.network(
                    p.url,
                    width: 96,
                    height: 96,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      width: 96,
                      height: 96,
                      color: ac.bgElev,
                      child: Icon(Icons.broken_image_outlined,
                          size: 20, color: ac.fgMute),
                    ),
                  ),
                ),
                Positioned(
                  left: 4,
                  bottom: 4,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: const Color(0xAA000000),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      p.source.toUpperCase(),
                      style: AymaType.mono(size: 7, color: Colors.white)
                          .copyWith(letterSpacing: 1),
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _PhotoViewer extends StatelessWidget {
  const _PhotoViewer({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.black,
      insetPadding: const EdgeInsets.all(12),
      child: Stack(
        children: [
          InteractiveViewer(
            minScale: 0.8,
            maxScale: 4,
            child: Center(
              child: Image.network(
                url,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const Padding(
                  padding: EdgeInsets.all(40),
                  child: Icon(Icons.broken_image_outlined,
                      color: Colors.white54, size: 40),
                ),
              ),
            ),
          ),
          Positioned(
            top: 4,
            right: 4,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
        ],
      ),
    );
  }
}
