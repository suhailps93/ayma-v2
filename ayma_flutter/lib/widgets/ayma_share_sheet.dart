import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../screens/main_shell_screen.dart';
import '../services/share_kit.dart';
import '../theme.dart';
import 'ayma_photo.dart';
import 'ayma_toast.dart';
import 'ayma_wing_loader.dart';

/// The ONE share sheet every page uses (founder, 2026-11-08): a header
/// naming the target (thumbnail + real subject + type label) over the
/// same two options everywhere — "Send to Ayma" and "Send externally".
/// Ayma-only targets (Your Story) show ONLY "Send to Ayma"; the external
/// option isn't hidden-but-present, the kit refuses it outright (see
/// [AymaShare.shareExternally]).
Future<void> showAymaShareSheet(
  BuildContext context,
  ShareTarget target, {
  AymaShare? share,
}) {
  final kit = share ?? AymaShare();
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetCtx) => AymaShareSheet(
      target: target,
      share: kit,
      pageContext: context,
    ),
  );
}

class AymaShareSheet extends StatefulWidget {
  const AymaShareSheet({
    super.key,
    required this.target,
    required this.share,
    required this.pageContext,
  });

  final ShareTarget target;
  final AymaShare share;

  /// The page's context, captured before the sheet opened: actions run
  /// with it after the sheet pops (navigation, the Appearance card
  /// render), never with the sheet's own soon-to-die context.
  final BuildContext pageContext;

  @override
  State<AymaShareSheet> createState() => _AymaShareSheetState();
}

class _AymaShareSheetState extends State<AymaShareSheet> {
  bool _busy = false;

  Future<void> _sendToAyma() async {
    widget.share.sendToAyma(widget.target);
    final router = GoRouter.of(widget.pageContext);
    Navigator.pop(context);
    router.go(MainShellScreen.path);
  }

  Future<void> _sendExternally() async {
    if (_busy) return;
    final toast = AymaToast.of(widget.pageContext);
    setState(() => _busy = true);
    try {
      Navigator.pop(context);
      await widget.share.shareExternally(widget.pageContext, widget.target);
    } catch (_) {
      toast.show("Couldn't share that right now.", kind: AymaToastKind.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final t = widget.target;
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_busy) const LinearProgressIndicator(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(9),
                    child: SizedBox(
                      width: 40,
                      height: 40,
                      child: t.thumbnailUrl.isNotEmpty
                          ? AymaPhoto(
                              url: t.thumbnailUrl,
                              displayWidth: 40,
                              error: Icon(Icons.person_outline,
                                  size: 18, color: ac.fgMute),
                            )
                          : DecoratedBox(
                              decoration: BoxDecoration(color: ac.accentFaint),
                              child: Icon(Icons.share_outlined,
                                  size: 18, color: ac.accent),
                            ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          t.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AymaType.sans(size: 15, weight: FontWeight.w600, color: ac.fg),
                        ),
                        Text(
                          t.typeLabel,
                          style: AymaType.sans(size: 12, color: ac.fgMute),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            ListTile(
              key: const ValueKey('shareSendToAyma'),
              leading: const AymaWingsIcon(),
              title: const Text('Send to Ayma'),
              subtitle: const Text('Talk about it with Ayma'),
              onTap: _busy ? null : _sendToAyma,
            ),
            if (t.canShareExternally)
              ListTile(
                key: const ValueKey('shareSendExternally'),
                leading: const Icon(Icons.ios_share),
                title: const Text('Send externally'),
                subtitle: const Text('Share a link in any app'),
                onTap: _busy ? null : _sendExternally,
              ),
          ],
        ),
      ),
    );
  }
}

/// The standard header share button: a ≥48pt share icon that opens
/// [showAymaShareSheet] for [target]. Pages put it in the header's
/// top-right slot.
class AymaShareButton extends StatelessWidget {
  const AymaShareButton({
    super.key,
    required this.target,
    this.share,
    this.color,
  });

  final ShareTarget target;
  final AymaShare? share;
  final Color? color;

  @override
  Widget build(BuildContext context) => IconButton(
        key: const ValueKey('aymaShareButton'),
        tooltip: 'Share',
        icon: const Icon(Icons.share_outlined),
        color: color,
        onPressed: () => showAymaShareSheet(context, target, share: share),
      );
}
