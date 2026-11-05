import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/api_client.dart';
import '../services/push_service.dart';
import '../theme.dart';
import '../widgets/ayma_back_button.dart';
import '../widgets/ayma_wing_loader.dart';
import 'sign_in_screen.dart';

/// Account deletion (§3.6): explains what is removed and the 30-day recovery
/// window, requires typing [confirmWord], calls `POST /account/delete`, then
/// signs the user out and returns to the sign-in screen.
class DeleteAccountScreen extends StatefulWidget {
  const DeleteAccountScreen({
    super.key,
    this.api,
    this.auth,
    this.clearPushToken,
  });

  static const path = '/settings/delete-account';
  static const confirmWord = 'DELETE';

  final ApiClient? api;
  final FirebaseAuth? auth;

  /// Defaults to [PushService.clearToken]; injectable for tests.
  final Future<void> Function()? clearPushToken;

  @override
  State<DeleteAccountScreen> createState() => _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends State<DeleteAccountScreen> {
  late final ApiClient _api = widget.api ?? ApiClient();
  final _controller = TextEditingController();
  bool _working = false;
  String? _error;

  bool get _confirmed =>
      _controller.text.trim() == DeleteAccountScreen.confirmWord;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// The server only soft-deletes and leaves the Firebase Auth user intact,
  /// so Firebase's requires-recent-login never applies; an expired or
  /// rejected token surfaces as 401/403 and needs a fresh sign-in.
  static String _messageFor(Object e) {
    if (e is ApiException && (e.statusCode == 401 || e.statusCode == 403)) {
      return 'Your sign-in has expired. Sign out, sign back in, and try '
          'again.';
    }
    return "Couldn't delete your account. Check your connection and try "
        'again.';
  }

  Future<void> _delete() async {
    if (_working || !_confirmed) return;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await _api.deleteAccount();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _messageFor(e);
        _working = false;
      });
      return;
    }
    try {
      await (widget.clearPushToken ?? PushService().clearToken)();
      await (widget.auth ?? FirebaseAuth.instance).signOut();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Your account was deleted, but sign-out failed. Close and '
            'reopen the app to finish.';
        _working = false;
      });
      return;
    }
    if (mounted) context.go(SignInScreen.path);
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(
        leading: const AymaBackButton(),
        title: const Text('Delete account'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('Delete your Ayma account?',
              style: AymaType.serif(size: 24, color: ac.fg)),
          const SizedBox(height: 12),
          Text(
            'This removes your profile, photos, messages, voice '
            'transcripts, and the analyses and matches Ayma built from them.',
            style: AymaType.sans(size: 14, color: ac.fg),
          ),
          const SizedBox(height: 12),
          Text(
            'You have 30 days to change your mind: sign back in during that '
            'window and choose Recover to restore everything. After 30 days '
            'deletion is permanent. Copies in backups age out on a rolling '
            'basis, and we may keep limited records where the law requires.',
            style: AymaType.sans(size: 14, color: ac.fg),
          ),
          const SizedBox(height: 20),
          Text(
            'Type ${DeleteAccountScreen.confirmWord} to confirm.',
            style: AymaType.sans(size: 14, color: ac.fgMute),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _controller,
            enabled: !_working,
            autocorrect: false,
            enableSuggestions: false,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: DeleteAccountScreen.confirmWord,
            ),
            onChanged: (_) => setState(() {}),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!,
                style: AymaType.sans(size: 13, color: AymaColors.error)),
          ],
          const SizedBox(height: 20),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AymaColors.error),
            onPressed: _confirmed && !_working ? _delete : null,
            // POST /account/delete (+ sign-out) in flight — wings only.
            child: _working
                ? const AymaWingLoader(size: 18, showLabel: false)
                : const Text('Delete my account'),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _working ? null : () => context.pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }
}
