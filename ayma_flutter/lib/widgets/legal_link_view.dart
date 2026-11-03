import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme.dart';
import 'ayma_back_button.dart';
import 'overflow_guards.dart';

/// Full-screen viewer for a hosted legal document (Privacy Policy, Terms).
///
/// The canonical copy lives on the web at [url] — the single source of truth
/// shared by the app and the App Store / Play listing. The app does not bundle
/// or render the policy body; entering this screen opens [url] in the device
/// browser and leaves a short interstitial with a button to (re)open it, so a
/// failed or dismissed launch is always recoverable.
class LegalLinkView extends StatefulWidget {
  const LegalLinkView({
    super.key,
    required this.title,
    required this.url,
  });

  /// Shown in the app bar and buttons, e.g. `Privacy Policy`.
  final String title;

  /// The canonical hosted URL to open.
  final String url;

  @override
  State<LegalLinkView> createState() => _LegalLinkViewState();
}

class _LegalLinkViewState extends State<LegalLinkView> {
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  Future<void> _open() async {
    try {
      final ok = await launchUrl(
        Uri.parse(widget.url),
        mode: LaunchMode.externalApplication,
      );
      if (mounted) setState(() => _failed = !ok);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(
        leading: const AymaBackButton(),
        title: Text(widget.title),
      ),
      body: SafeArea(
        child: CenteredScroll(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.open_in_new_rounded, size: 40, color: ac.accent),
              const SizedBox(height: 16),
              Text(
                _failed
                    ? "We couldn't open your browser. Tap below, or visit this "
                        'address:'
                    : 'Opening the ${widget.title} in your browser…',
                textAlign: TextAlign.center,
                style: AymaType.sans(size: 15, color: ac.fg, height: 1.45),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                key: const Key('legal_link_open'),
                onPressed: _open,
                icon: const Icon(Icons.open_in_new_rounded, size: 18),
                label: Text('Open ${widget.title}'),
              ),
              const SizedBox(height: 20),
              SelectableText(
                widget.url,
                textAlign: TextAlign.center,
                style: AymaType.sans(size: 13, color: ac.fgMute, height: 1.4),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
