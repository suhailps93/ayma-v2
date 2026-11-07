import 'package:flutter/material.dart';

import '../services/legal_links.dart';
import 'ayma_toast.dart';

/// The whole body of the legacy `/terms` and `/privacy` routes.
///
/// Nothing in the app navigates here any more — every Terms / Privacy tap
/// opens the hosted page directly from the screen the user is on (see
/// [LegalLinks]). The routes themselves stay registered only so a path
/// that still arrives from outside a tap — Ayma opening the page by voice
/// or chat through the app registry, a queued deep link, an older build's
/// saved state — lands somewhere sane instead of nowhere.
///
/// Arriving here does exactly what a tap does, then leaves: it opens the
/// hosted page in the browser and pops straight back to the screen the
/// user was on. It renders nothing at any point — no message, no button,
/// no address — so there is no in-between screen to see or get stuck on.
/// If the browser cannot be opened, a small error toast (the app's
/// snackbar) with a retry is shown on the screen it returns to.
class LegalRedirect extends StatefulWidget {
  const LegalRedirect({super.key, required this.title, required this.url});

  /// e.g. `Terms of Service` — used only in the failure toast.
  final String title;

  /// The canonical hosted URL to open.
  final String url;

  @override
  State<LegalRedirect> createState() => _LegalRedirectState();
}

class _LegalRedirectState extends State<LegalRedirect> {
  bool _started = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _go());
  }

  Future<void> _go() async {
    if (_started || !mounted) return;
    _started = true;
    final ok = await LegalLinks.tryOpen(widget.url);
    if (!mounted) return;
    // Only leave when there is a screen to go back to. When this widget
    // is pumped on its own (the layout matrix), it simply stays blank.
    if (!Navigator.of(context).canPop()) return;
    if (!ok) {
      // Raised before the pop: the toast layer sits above the router, so
      // the message lands on — and stays on — the screen we return to.
      AymaToast.show(
        context,
        'Could not open ${widget.title}: ${widget.url}',
        kind: AymaToastKind.error,
        action: AymaToastAction(
          label: 'Retry',
          onPressed: () => LegalLinks.tryOpen(widget.url),
        ),
      );
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: SizedBox.shrink());
}
