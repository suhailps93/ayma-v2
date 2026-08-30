import 'package:flutter/material.dart';

import '../services/wiki_service.dart';
import '../theme.dart';

/// The user's own private profile — their story as Ayma has compiled it (§2.1,
/// §2.8 step 9). `public` + `private` pages, `user_edits ?? ai_body`, minus
/// `user_hidden`, laid out as a readable narrative rather than a field list.
class PrivateWikiScreen extends StatefulWidget {
  const PrivateWikiScreen({super.key, this.wikiService});

  static const path = '/profile/wiki';

  final WikiService? wikiService;

  @override
  State<PrivateWikiScreen> createState() => _PrivateWikiScreenState();
}

class _PrivateWikiScreenState extends State<PrivateWikiScreen> {
  late final WikiService _wiki = widget.wikiService ?? WikiService();

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
      final pages = await _wiki.readPrivateWiki();
      if (!mounted) return;
      setState(() {
        _pages = pages;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load your profile ($e).';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(title: const Text('Your story')),
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
                          'Once you and Ayma have talked a little, your story '
                          'will start to take shape here.',
                          textAlign: TextAlign.center,
                          style: AymaType.sans(
                              size: 15, soft: true, color: ac.fgMute),
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
                      itemCount: _pages.length,
                      itemBuilder: (context, i) =>
                          _Section(page: _pages[i]),
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

  /// Turn lightly-marked-up `ai_body` into plain flowing paragraphs.
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
