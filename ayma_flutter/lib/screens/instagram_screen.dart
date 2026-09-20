import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/instagram_service.dart';
import '../theme.dart';
import '../widgets/oauth_code_dialog.dart';

/// "Connect Instagram" — the missing UI for the already-working
/// `/instagram/auth-url` / `/instagram/connect` / `/instagram/disconnect`
/// endpoints (`instagram.py`, ARCHITECTURE.md §8.1/§8.6/§8.7). Mirrors
/// `google_account_screen.dart`'s pattern closely: the same manual
/// redirect-capture round trip (open the OAuth URL externally, then hand the
/// returned `code` back to the backend), the same status display, and the
/// same real disconnect action.
class InstagramScreen extends StatefulWidget {
  const InstagramScreen({super.key, this.service});

  static const path = '/settings/instagram';

  final InstagramService? service;

  @override
  State<InstagramScreen> createState() => _InstagramScreenState();
}

class _InstagramScreenState extends State<InstagramScreen> {
  late final InstagramService _svc = widget.service ?? InstagramService();

  bool? _connected;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final connected = await _svc.status();
      if (mounted) setState(() => _connected = connected);
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
        _snack('Could not open Instagram sign-in.');
        return;
      }
      if (!mounted) return;
      final code = await promptForOAuthCode(context);
      if (code == null || code.trim().isEmpty) return;
      final imported = await _svc.connect(code.trim());
      _snack(imported > 0
          ? 'Instagram connected — imported $imported photo(s).'
          : 'Instagram connected.');
      await _load();
    } catch (e) {
      _snack('Could not connect Instagram ($e).');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    setState(() => _busy = true);
    try {
      await _svc.disconnect();
      _snack('Instagram disconnected.');
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
        title: const Text('Connect Instagram'),
        content: SingleChildScrollView(
          child: Text(
            "Ayma will ask Instagram for read-only access to your profile "
            "and recent media. If you continue, Ayma imports your username "
            "and up to a bounded number of your recent photos and captions "
            "into your profile and private AI notes. You can disconnect at "
            "any time; already-imported photos stay as regular uploads.",
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
            child: const Text('Continue to Instagram'),
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
    final connected = _connected;
    return Scaffold(
      appBar: AppBar(title: const Text('Connect Instagram')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Let Ayma learn from Instagram',
              style: AymaType.serif(size: 20, color: ac.fg),
            ),
            const SizedBox(height: 8),
            Text(
              'Import your username and recent photos and captions. See '
              'exactly what is pulled before you connect.',
              style: AymaType.sans(size: 13, soft: true, color: ac.fgMute),
            ),
            const SizedBox(height: 24),
            if (_error != null)
              Text('Could not load status ($_error).',
                  style: AymaType.sans(size: 13, color: AymaColors.error))
            else if (connected == null)
              const Center(child: CircularProgressIndicator())
            else if (connected) ...[
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.check_circle_outline),
                title: Text(
                  'Instagram connected',
                  style: AymaType.sans(size: 15, color: ac.fg),
                ),
                subtitle: Text(
                  'Recent photos and captions imported',
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
                child: Text(_busy ? 'Connecting…' : 'Connect Instagram'),
              ),
          ],
        ),
      ),
    );
  }
}
