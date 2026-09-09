import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/api_client.dart';
import '../theme.dart';

/// Debug view of the compiled wiki context Ayma reads about the user — the
/// `ai_body` of every page, exactly as it's fed into `/chat`. Temporary;
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
  late Future<String> _future = _api.aiNotes();

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI notes'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(() => _future = _api.aiNotes()),
          ),
        ],
      ),
      body: FutureBuilder<String>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final text = (snap.data ?? '').trim();
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Could not load (${snap.error}).',
                    style: AymaType.sans(size: 13, color: AymaColors.error)),
              ),
            );
          }
          if (text.isEmpty) {
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
                  child: SelectableText(
                    text,
                    style: AymaType.mono(size: 12, color: ac.fg)
                        .copyWith(height: 1.5),
                  ),
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: text));
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
