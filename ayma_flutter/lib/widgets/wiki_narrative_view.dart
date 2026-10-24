import 'package:flutter/material.dart';

import '../services/wiki_service.dart';
import '../theme.dart';

/// Shared renderer for the private and public profile views (§2.1). Loads a
/// page list, lays each out as a serif-titled section of flowing paragraphs
/// (light markdown stripped) — a readable narrative, not a field dump.
///
/// When [editService] is given (the private view only), each section gets the
/// edit path (§2.8 step 11, §14.3): override the text, reset to Ayma's
/// version, or move it between your public and private profile. `ai_body` is
/// never touched.
class WikiNarrativeView extends StatefulWidget {
  const WikiNarrativeView({
    super.key,
    required this.title,
    required this.load,
    required this.emptyText,
    this.editService,
  });

  final String title;
  final Future<List<WikiPageView>> Function() load;
  final String emptyText;
  final WikiService? editService;

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

  Future<void> _edit(WikiPageView page) async {
    final service = widget.editService;
    if (service == null) return;
    final controller = TextEditingController(text: page.body);
    final action = await showModalBottomSheet<_EditAction>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
            20, 16, 20, MediaQuery.of(ctx).viewInsets.bottom + 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Edit this section',
                style: AymaType.sans(size: 16, weight: FontWeight.w600, color: ctx.ac.fg)),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              minLines: 4,
              maxLines: 10,
              decoration: const InputDecoration(
                hintText: "How you'd like this to read",
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Icon(page.isPublic ? Icons.public : Icons.lock_outline,
                    size: 18, color: ctx.ac.fgMute),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    page.isPublic
                        ? 'Shown on your public profile'
                        : 'Only you and Ayma can see this',
                    style: AymaType.sans(size: 13, color: ctx.ac.fgMute),
                  ),
                ),
                Switch(
                  value: page.isPublic,
                  onChanged: (on) => Navigator.pop(
                    ctx,
                    _EditAction.visibility(on ? 'public' : 'private'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(ctx, _EditAction.save(controller.text)),
              child: const Text('Save changes'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, const _EditAction.reset()),
              child: const Text("Reset to Ayma's version"),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    try {
      switch (action.kind) {
        case _EditKind.save:
          await service.setUserEdit(page.pageId, action.text!);
        case _EditKind.reset:
          await service.resetPage(page.pageId);
        case _EditKind.visibility:
          await service.setVisibility(page.pageId, action.text!);
      }
      if (mounted) await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Edit failed ($e)')));
      }
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
                      itemBuilder: (context, i) => _Section(
                        page: _pages[i],
                        onEdit: widget.editService == null
                            ? null
                            : () => _edit(_pages[i]),
                      ),
                    ),
    );
  }
}

enum _EditKind { save, reset, visibility }

class _EditAction {
  const _EditAction._(this.kind, this.text);
  const _EditAction.reset() : this._(_EditKind.reset, null);
  const _EditAction.save(String text) : this._(_EditKind.save, text);
  const _EditAction.visibility(String value)
      : this._(_EditKind.visibility, value);

  final _EditKind kind;
  final String? text;
}

class _Section extends StatelessWidget {
  const _Section({required this.page, this.onEdit});
  final WikiPageView page;
  final VoidCallback? onEdit;

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
          Row(
            children: [
              Expanded(
                child: Text(
                  _heading(page.pageType, page.pageId),
                  style: AymaType.serif(size: 20, color: ac.fg),
                ),
              ),
              if (onEdit != null) ...[
                Icon(
                  page.isPublic ? Icons.public : Icons.lock_outline,
                  size: 15,
                  color: ac.fgMute,
                ),
                IconButton(
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  tooltip: 'Edit',
                  visualDensity: VisualDensity.compact,
                  color: ac.fgMute,
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
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
