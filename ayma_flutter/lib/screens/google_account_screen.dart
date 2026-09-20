import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/api_client.dart';
import '../services/google_account_service.dart';
import '../theme.dart';
import '../widgets/oauth_code_dialog.dart';

/// "Connect Google" (new): links Gmail / Google Calendar (read-only) so Ayma
/// can pull real facts into the wiki instead of only learning from
/// conversation. Google Photos was dropped from this feature entirely — see
/// google_account.py's module docstring. Same round-trip shape as Instagram's
/// connect flow in `photo_management_screen.dart` — open the OAuth URL
/// externally, then hand the returned `code` back to the backend — plus a
/// status display and a real disconnect action, since unlike the Instagram
/// entry point this one is expected to show connected/disconnected state.
class GoogleAccountScreen extends StatefulWidget {
  const GoogleAccountScreen({super.key, this.service});

  static const path = '/settings/google-account';

  final GoogleAccountService? service;

  @override
  State<GoogleAccountScreen> createState() => _GoogleAccountScreenState();
}

class _GoogleAccountScreenState extends State<GoogleAccountScreen> {
  late final GoogleAccountService _svc = widget.service ?? GoogleAccountService();

  GoogleAccountStatus? _status;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await _svc.status();
      if (mounted) setState(() => _status = s);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _connect() async {
    final proceed = await _showConsentDialog();
    if (proceed != true) return;
    setState(() => _busy = true);
    try {
      final url = await _svc.authUrl();
      final opened =
          await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      if (!opened) {
        _snack('Could not open Google sign-in.');
        return;
      }
      if (!mounted) return;
      final code = await promptForOAuthCode(context);
      if (code == null || code.trim().isEmpty) return;
      final email = await _svc.connect(code.trim());
      _snack(email.isEmpty
          ? 'Google account connected.'
          : 'Connected as $email.');
      await _load();
    } catch (e) {
      _snack('Could not connect Google ($e).');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    setState(() => _busy = true);
    try {
      await _svc.disconnect();
      _snack('Google account disconnected.');
      await _load();
    } catch (e) {
      _snack('Could not disconnect ($e).');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool?> _showConsentDialog() {
    final ac = context.ac;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Connect Google'),
        content: SingleChildScrollView(
          child: Text(
            "Ayma will ask Google for read-only access to:\n\n"
            "• Gmail — recent message subjects and senders for every "
            "message, plus the text body of a small number of them (Ayma "
            "skips senders like banks and payment providers)\n"
            "• Google Calendar — recent and upcoming event titles, never "
            "attendee details\n\n"
            "Ayma reads a bounded, recent window (not your full history), "
            "and never stores the raw emails or events. An AI pass distills "
            "a short set of facts about you (for example \"travels often "
            "for work\") into your private AI notes — the notes are not "
            "shown on your public profile unless you choose to share them. "
            "You can disconnect at any time, which revokes Google's access "
            "immediately.",
            style: AymaType.sans(size: 13, color: ac.fg),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Continue to Google'),
          ),
        ],
      ),
    );
  }

  void _snack(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final status = _status;
    return Scaffold(
      appBar: AppBar(title: const Text('Connect Google')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Let Ayma learn from Gmail and Calendar',
              style: AymaType.serif(size: 20, color: ac.fg),
            ),
            const SizedBox(height: 8),
            Text(
              'Ayma extracts short facts about you — never raw emails, '
              'events, or photos. See exactly what is pulled before you '
              'connect.',
              style: AymaType.sans(size: 13, soft: true, color: ac.fgMute),
            ),
            const SizedBox(height: 24),
            if (_error != null)
              Text('Could not load status ($_error).',
                  style: AymaType.sans(size: 13, color: AymaColors.error))
            else if (status == null)
              const Center(child: CircularProgressIndicator())
            else if (status.connected) ...[
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.check_circle_outline),
                title: Text(
                  status.email.isEmpty
                      ? 'Google account connected'
                      : 'Connected as ${status.email}',
                  style: AymaType.sans(size: 15, color: ac.fg),
                ),
                subtitle: Text(
                  'Gmail and Calendar, read-only',
                  style: AymaType.sans(size: 12, soft: true, color: ac.fgMute),
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: _busy ? null : _disconnect,
                child: Text(_busy ? 'Disconnecting…' : 'Disconnect'),
              ),
            ] else
              FilledButton(
                onPressed: _busy ? null : _connect,
                child: Text(_busy ? 'Connecting…' : 'Connect Google'),
              ),
          ],
        ),
      ),
    );
  }
}
