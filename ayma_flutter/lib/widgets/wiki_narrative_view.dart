import 'package:flutter/material.dart';

import '../services/wiki_service.dart';
import '../theme.dart';

/// Shared renderer for the private and public profile views (§2.1). Loads a
/// page list, lays each out as a serif-titled section of flowing paragraphs
/// (light markdown stripped) — a readable narrative, not a field dump.
class WikiNarrativeView extends StatefulWidget {
  const WikiNarrativeView({
    super.key,
    required this.title,
    required this.load,
    required this.emptyText,
  });

  final String title;
  final Future<List<WikiPageView>> Function() load;
  final String emptyText;

  @override
  State<WikiNarrativeView> createState() => _WikiNarrativeViewState();
}

class _WikiNarrativeViewState extends State<WikiNarrativeView> {
  bool _loading = true;
  String? _error;
  List<WikiPageView> _pages = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final pages = await widget.load();
      if (!mounted) return;
      setState(() {
        _pages = pages;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load this profile ($e).';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!,
                        style: AymaType.sans(size: 14, color: AymaColors.error)),
                  ),
                )
              : _pages.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 40),
                        child: Text(
                          widget.emptyText,
                          textAlign: TextAlign.center,
                          style: AymaType.sans(
                              size: 15, soft: true, color: ac.fgMute),
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
                      itemCount: _pages.length,
                      itemBuilder: (context, i) => _Section(page: _pages[i]),
                    ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.page});
  final WikiPageView page;

  static String _heading(String pageType, String pageId) {
    final base = pageId.replaceAll('-', ' ');
    return base.isEmpty
        ? pageType
        : base[0].toUpperCase() + base.substring(1);
  }

  static List<String> _paragraphs(String body) {
    return body
        .split(RegExp(r'\n\s*\n'))
        .map((p) => p
            .replaceAll(RegExp(r'^\s*#{1,6}\s*', multiLine: true), '')
            .replaceAll(RegExp(r'^\s*[-*]\s+', multiLine: true), '• ')
            .replaceAll(RegExp(r'\s*\n\s*'), ' ')
            .trim())
        .where((p) => p.isNotEmpty)
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Padding(
      padding: const EdgeInsets.only(bottom: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _heading(page.pageType, page.pageId),
            style: AymaType.serif(size: 20, color: ac.fg),
          ),
          const SizedBox(height: 10),
          for (final para in _paragraphs(page.body))
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                para,
                style: AymaType.sans(size: 15, color: ac.fgDim, height: 1.5),
              ),
            ),
        ],
      ),
    );
  }
}
