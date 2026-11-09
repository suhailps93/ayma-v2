import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../models/share_link.dart';
import '../services/api_client.dart';
import '../services/share_kit.dart';
import '../theme.dart';
import '../widgets/ayma_wing_loader.dart';
import '../widgets/overflow_guards.dart';
import 'sign_in_screen.dart';

/// The in-app landing for a page-share link
/// (`https://justabot.info/p/<token>`) — the route the OS app-link
/// machinery delivers the tap to
/// when Ayma is installed. Resolves the token against the public
/// `GET /p/{token}/data` (no auth — the token is the credential) and
/// opens the target natively: a profile opens the real profile screen.
///
/// Signed out: the link target needs an account, so the resolved route
/// is stashed ([PendingPageShare]) and this screen shows the public
/// teaser with a sign-in button; the router's auth listener drains the
/// stash the moment sign-in completes.
class SharedProfileLinkScreen extends StatefulWidget {
  const SharedProfileLinkScreen({super.key, required this.token, this.api});

  static const path = '/p/:token';

  final String token;
  final ApiClient? api;

  @override
  State<SharedProfileLinkScreen> createState() =>
      _SharedProfileLinkScreenState();
}

class _SharedProfileLinkScreenState extends State<SharedProfileLinkScreen> {
  late final ApiClient _api = widget.api ?? ApiClient();
  PageShareTarget? _target;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  bool get _signedIn {
    try {
      final u = FirebaseAuth.instance.currentUser;
      return u != null && !u.isAnonymous;
    } catch (_) {
      // No Firebase app (tests) — treat as signed out; the teaser still
      // renders and the stash drains on a real sign-in.
      return false;
    }
  }

  Future<void> _resolve() async {
    try {
      final t = await _api.pageShareTarget(widget.token);
      if (!mounted) return;
      final route = t.route;
      if (route.isEmpty) {
        setState(() => _failed = true);
        return;
      }
      if (_signedIn) {
        context.go(route);
      } else {
        PendingPageShare.stash(route);
        setState(() => _target = t);
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final t = _target;
    return Scaffold(
      appBar: AppBar(title: const Text('Ayma')),
      body: CenteredScroll(
        padding: const EdgeInsets.all(24),
        child: _failed
            ? Text(
                "This link isn't available.",
                textAlign: TextAlign.center,
                style: AymaType.sans(size: 15, color: ac.fg),
              )
            : t == null
                ? const AymaWingLoader(lines: AymaLoaderLines.publicProfile)
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        t.title,
                        textAlign: TextAlign.center,
                        style: AymaType.sans(
                            size: 20, weight: FontWeight.w600, color: ac.fg),
                      ),
                      if (t.summary.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          t.summary,
                          textAlign: TextAlign.center,
                          style: AymaType.sans(size: 14, color: ac.fgMute),
                        ),
                      ],
                      const SizedBox(height: 24),
                      FilledButton(
                        onPressed: () => context.go(SignInScreen.path),
                        style: FilledButton.styleFrom(
                            minimumSize: const Size(64, 48)),
                        child: const Text('Sign in to see this profile'),
                      ),
                    ],
                  ),
      ),
    );
  }
}
