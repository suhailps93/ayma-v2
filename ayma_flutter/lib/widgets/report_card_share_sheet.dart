import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/report_card_share.dart';
import '../theme.dart';
import 'ayma_toast.dart';

/// Opens the report card's Share sheet: WhatsApp, Instagram, Save image,
/// More… . [renderPng] produces the card image (1080x1920) when an option is
/// picked; nothing is rendered or written until then. [caption] (with the
/// Ayma smart link) rides along to WhatsApp and the system share sheet.
Future<void> showReportCardShareSheet(
  BuildContext context, {
  required Future<Uint8List> Function() renderPng,
  String? caption,
  ReportCardShare? service,
}) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  builder: (_) => ReportCardShareSheet(
    renderPng: renderPng,
    caption: caption,
    service: service ?? ReportCardShare(),
  ),
);

class ReportCardShareSheet extends StatefulWidget {
  const ReportCardShareSheet({
    super.key,
    required this.renderPng,
    this.caption,
    required this.service,
  });

  final Future<Uint8List> Function() renderPng;

  /// The caption (with the Ayma smart link) sent alongside the card.
  final String? caption;
  final ReportCardShare service;

  /// The options, in order, with their labels.
  static const options = [
    (CardShareTarget.whatsapp, 'WhatsApp', Icons.chat_outlined),
    (CardShareTarget.instagram, 'Instagram', Icons.camera_alt_outlined),
    (CardShareTarget.save, 'Save image', Icons.download_outlined),
    (CardShareTarget.more, 'More…', Icons.ios_share),
  ];

  @override
  State<ReportCardShareSheet> createState() => _ReportCardShareSheetState();
}

class _ReportCardShareSheetState extends State<ReportCardShareSheet> {
  bool _busy = false;

  Future<void> _pick(CardShareTarget target) async {
    if (_busy) return;
    final toaster = AymaToast.of(context);
    final navigator = Navigator.of(context);
    // iPad share popover anchor, read before any await.
    final box = context.findRenderObject() as RenderBox?;
    final origin = box != null
        ? box.localToGlobal(Offset.zero) & box.size
        : null;
    setState(() => _busy = true);
    String? message;
    var kind = AymaToastKind.success;
    try {
      final png = await widget.renderPng();
      message = await widget.service.share(
        target,
        png,
        origin: origin,
        caption: widget.caption,
      );
      if (mounted) navigator.pop();
    } on ShareTargetNotInstalled catch (e) {
      // Keep the sheet open so the user can pick another option (e.g. More…).
      kind = AymaToastKind.error;
      message = "${e.appLabel} isn't installed.";
    } on PlatformException catch (e) {
      kind = AymaToastKind.error;
      message = e.code == 'PERMISSION'
          ? 'Allow Ayma to add photos in Settings to save the card.'
          : "Couldn't share that right now.";
    } catch (_) {
      kind = AymaToastKind.error;
      message = "Couldn't share that right now.";
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (message != null) {
      toaster.show(message, kind: kind);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_busy) const LinearProgressIndicator(),
          for (final (target, label, icon) in ReportCardShareSheet.options)
            ListTile(
              leading: Icon(icon, color: ac.fg),
              title: Text(label),
              enabled: !_busy,
              onTap: () => _pick(target),
            ),
        ],
      ),
    );
  }
}
