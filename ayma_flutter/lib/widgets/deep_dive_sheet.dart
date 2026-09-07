import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/api_client.dart';
import '../theme.dart';
import 'markdown_text.dart';

/// Runs a deep-dive (`POST /deep-dive`) and shows the result in a bottom sheet.
/// [targetUid] empty = research the signed-in user; otherwise that person.
/// Ayma's summary is also dropped into the chat transcript server-side, so the
/// sheet ends with a nudge to go discuss it.
Future<void> showDeepDiveSheet(
  BuildContext context, {
  ApiClient? api,
  String targetUid = '',
  String subjectLabel = 'you',
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => _DeepDiveSheet(
      api: api ?? ApiClient(),
      targetUid: targetUid,
      subjectLabel: subjectLabel,
    ),
  );
}

class _DeepDiveSheet extends StatefulWidget {
  const _DeepDiveSheet({
    required this.api,
    required this.targetUid,
    required this.subjectLabel,
  });

  final ApiClient api;
  final String targetUid;
  final String subjectLabel;

  @override
  State<_DeepDiveSheet> createState() => _DeepDiveSheetState();
}

class _DeepDiveSheetState extends State<_DeepDiveSheet> {
  late Future<DeepDiveResult> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.api.deepDive(targetUid: widget.targetUid);
  }

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
        child: FutureBuilder<DeepDiveResult>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return _busy(ac);
            }
            if (snap.hasError) {
              return _msg(ac, "Couldn't run that search. Try again in a bit.");
            }
            final r = snap.data!;
            if (r.usageCapped) {
              return _msg(ac,
                  'Out of credits — reload on your profile to run a web search.');
            }
            return ListView(
              controller: controller,
              children: [
                Text(
                  widget.targetUid.isEmpty
                      ? 'What I found about you'
                      : 'What I found',
                  style: AymaType.serif(size: 20, color: ac.fg),
                ),
                const SizedBox(height: 12),
                MarkdownText(
                  r.summary,
                  style: AymaType.sans(size: 14, color: ac.fg, height: 1.5),
                  linkColor: ac.accent,
                ),
                if (r.links.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  Text('LINKS',
                      style: AymaType.mono(size: 10, color: ac.fgMute)
                          .copyWith(letterSpacing: 1.5)),
                  const SizedBox(height: 6),
                  for (final l in r.links)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: InkWell(
                        onTap: () => launchUrl(Uri.parse(l.url),
                            mode: LaunchMode.externalApplication),
                        child: Row(
                          children: [
                            Icon(Icons.link, size: 14, color: ac.fgMute),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                l.title.isEmpty ? l.url : l.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AymaType.sans(
                                    size: 13, color: ac.accent),
                              ),
                            ),
                            Text(l.isThem,
                                style: AymaType.mono(
                                    size: 9, color: ac.fgMute)),
                          ],
                        ),
                      ),
                    ),
                ],
                const SizedBox(height: 20),
                Text(
                  "I've added this to our chat — go through it with me there "
                  "and tell me what's right.",
                  style:
                      AymaType.sans(size: 12, soft: true, color: ac.fgMute),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _busy(AymaTokens ac) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 24),
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(
            widget.targetUid.isEmpty
                ? 'Searching the web for you…'
                : 'Searching the web…',
            style: AymaType.sans(size: 13, color: ac.fgMute),
          ),
          const SizedBox(height: 8),
          Text('This takes a few seconds.',
              style: AymaType.sans(size: 11, soft: true, color: ac.fgMute)),
          const SizedBox(height: 24),
        ],
      );

  Widget _msg(AymaTokens ac, String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Text(text,
            textAlign: TextAlign.center,
            style: AymaType.sans(size: 14, color: ac.fgMute)),
      );
}
