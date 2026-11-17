import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/api_client.dart';
import '../services/instagram_service.dart';
import '../services/meta_integrations.dart';
import '../theme.dart';
import '../widgets/ayma_back_button.dart';
import '../widgets/ayma_toast.dart';
import '../widgets/oauth_code_dialog.dart';
import 'instagram_screen.dart';

/// Connector action buttons sit inside a row, so they must be compact — the
/// app's default button theme stretches buttons full-width, which is illegal
/// (infinite width) inside a Row. Height stays ≥48 for the tap target.
const ButtonStyle _actionStyle = ButtonStyle(
  minimumSize: WidgetStatePropertyAll(Size(72, 48)),
);

/// "Connectors" — one screen that lists every external account Ayma can
/// genuinely connect, the way Claude/Muse present their connectors: a row per
/// provider with what it connects, the live connection status, and a working
/// connect/disconnect flow.
///
/// Only connectors with a real backend are listed:
/// - **Google (Gmail + Calendar)** — the `/google/*` OAuth endpoints
///   (`google_account*.py`). Read-only; content enriches the profile.
/// - **Instagram** — the `/instagram/*` endpoints, behind the
///   `meta_integrations` flag. When the flag is off it is shown as
///   unavailable (never a dead button); when on, the row opens the dedicated
///   [InstagramScreen] connect flow.
///
/// This is a fresh screen built on the reused backends — it is NOT the deleted
/// GoogleAccountScreen (closed decision) and does not reuse its client code.
class ConnectorsScreen extends StatefulWidget {
  const ConnectorsScreen({
    super.key,
    this.apiClient,
    this.instagramService,
    this.launcher,
  });

  static const path = '/settings/connectors';

  final ApiClient? apiClient;
  final InstagramService? instagramService;

  /// Test seam for the external OAuth URL open; defaults to [launchUrl].
  final Future<bool> Function(Uri uri)? launcher;

  @override
  State<ConnectorsScreen> createState() => _ConnectorsScreenState();
}

class _ConnectorsScreenState extends State<ConnectorsScreen> {
  late final ApiClient _api = widget.apiClient ?? ApiClient();
  late final InstagramService _instagram =
      widget.instagramService ?? InstagramService();

  // Google
  bool _googleLoading = true;
  bool _googleConnected = false;
  String _googleEmail = '';
  bool _googleBusy = false;
  bool _googleError = false;

  // Instagram
  bool _igLoading = true;
  bool _igConnected = false;

  @override
  void initState() {
    super.initState();
    _loadGoogle();
    if (MetaIntegrations.enabled.value) _loadInstagram();
  }

  Future<bool> _open(Uri uri) =>
      (widget.launcher ?? (u) => launchUrl(u, mode: LaunchMode.externalApplication))(uri);

  // --- Google (Gmail + Calendar) -----------------------------------------

  Future<void> _loadGoogle() async {
    try {
      final s = await _api.googleStatus();
      if (!mounted) return;
      setState(() {
        _googleConnected = s.connected;
        _googleEmail = s.email;
        _googleLoading = false;
        _googleError = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _googleLoading = false;
        _googleError = true;
      });
    }
  }

  Future<void> _connectGoogle() async {
    final proceed = await _consentDialog(
      title: 'Connect Google',
      body: 'Ayma asks Google for READ-ONLY access to your recent Gmail and '
          'Calendar. It imports a bounded amount of recent context into your '
          'private AI notes to enrich your profile — never your passwords, and '
          'it never sends email or changes your calendar. You can disconnect '
          'at any time.',
      cta: 'Continue to Google',
    );
    if (proceed != true) return;
    setState(() => _googleBusy = true);
    try {
      final url = await _api.googleAuthUrl();
      final opened = await _open(Uri.parse(url));
      if (!opened) {
        _toast('Could not open Google sign-in.', kind: AymaToastKind.error);
        return;
      }
      if (!mounted) return;
      final code = await promptForOAuthCode(context);
      if (code == null || code.trim().isEmpty) return;
      final email = await _api.googleConnect(code.trim());
      _toast(
        email.isNotEmpty ? 'Google connected — $email.' : 'Google connected.',
        kind: AymaToastKind.success,
      );
      await _loadGoogle();
    } catch (e) {
      _toast('Could not connect Google ($e).', kind: AymaToastKind.error);
    } finally {
      if (mounted) setState(() => _googleBusy = false);
    }
  }

  Future<void> _disconnectGoogle() async {
    setState(() => _googleBusy = true);
    try {
      await _api.googleDisconnect();
      _toast('Google disconnected.', kind: AymaToastKind.success);
      await _loadGoogle();
    } catch (e) {
      _toast('Could not disconnect ($e).', kind: AymaToastKind.error);
    } finally {
      if (mounted) setState(() => _googleBusy = false);
    }
  }

  // --- Instagram ----------------------------------------------------------

  Future<void> _loadInstagram() async {
    try {
      final connected = await _instagram.status();
      if (!mounted) return;
      setState(() {
        _igConnected = connected;
        _igLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _igLoading = false);
    }
  }

  Future<void> _openInstagram() async {
    await context.push(InstagramScreen.path);
    // Refresh status when returning from the dedicated connect screen.
    if (mounted) await _loadInstagram();
  }

  // --- shared -------------------------------------------------------------

  Future<bool?> _consentDialog({
    required String title,
    required String body,
    required String cta,
  }) {
    final ac = context.ac;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Text(body, style: AymaType.sans(size: 13, color: ac.fg)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            style: TextButton.styleFrom(minimumSize: const Size(0, 44)),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(minimumSize: const Size(0, 44)),
            child: Text(cta),
          ),
        ],
      ),
    );
  }

  void _toast(String m, {AymaToastKind kind = AymaToastKind.info}) {
    if (mounted) AymaToast.show(context, m, kind: kind);
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(
        leading: const AymaBackButton(),
        title: const Text('Connectors'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        children: [
          Text(
            'Connect your accounts so Ayma can learn from them. You choose '
            'what to connect, and you can disconnect any time.',
            style: AymaType.sans(size: 13, soft: true, color: ac.fgMute),
          ),
          const SizedBox(height: 20),
          _googleTile(ac),
          const SizedBox(height: 12),
          _instagramTile(ac),
        ],
      ),
    );
  }

  Widget _googleTile(AymaTokens ac) {
    final String status;
    if (_googleLoading) {
      status = 'Checking…';
    } else if (_googleError) {
      status = 'Couldn’t load status';
    } else if (_googleConnected) {
      status = _googleEmail.isNotEmpty
          ? 'Connected · $_googleEmail'
          : 'Connected';
    } else {
      status = 'Not connected';
    }

    Widget action;
    if (_googleLoading) {
      action = const SizedBox.shrink();
    } else if (_googleConnected) {
      action = OutlinedButton(
        style: _actionStyle,
        onPressed: _googleBusy ? null : _disconnectGoogle,
        child: Text(_googleBusy ? 'Working…' : 'Disconnect'),
      );
    } else {
      action = FilledButton(
        style: _actionStyle,
        onPressed: _googleBusy ? null : _connectGoogle,
        child: Text(_googleBusy ? 'Connecting…' : 'Connect'),
      );
    }

    return _ConnectorTile(
      key: const Key('connector_google'),
      icon: Icons.mail_outline,
      name: 'Google',
      blurb: 'Gmail + Calendar — read-only context for your profile',
      status: status,
      connected: _googleConnected && !_googleLoading,
      action: action,
    );
  }

  Widget _instagramTile(AymaTokens ac) {
    final enabled = MetaIntegrations.enabled.value;
    if (!enabled) {
      return _ConnectorTile(
        key: const Key('connector_instagram'),
        icon: Icons.camera_alt_outlined,
        name: 'Instagram',
        blurb: 'Import your photos and captions',
        status: 'Not available in this version',
        connected: false,
        action: const SizedBox.shrink(),
      );
    }

    final status = _igLoading
        ? 'Checking…'
        : (_igConnected ? 'Connected' : 'Not connected');
    return _ConnectorTile(
      key: const Key('connector_instagram'),
      icon: Icons.camera_alt_outlined,
      name: 'Instagram',
      blurb: 'Import your photos and captions',
      status: status,
      connected: _igConnected && !_igLoading,
      action: _igLoading
          ? const SizedBox.shrink()
          : (_igConnected
              ? OutlinedButton(
                  style: _actionStyle,
                  onPressed: _openInstagram,
                  child: const Text('Manage'),
                )
              : FilledButton(
                  style: _actionStyle,
                  onPressed: _openInstagram,
                  child: const Text('Connect'),
                )),
    );
  }
}

/// One connector row: icon, name, what it connects, status, and its action.
class _ConnectorTile extends StatelessWidget {
  const _ConnectorTile({
    super.key,
    required this.icon,
    required this.name,
    required this.blurb,
    required this.status,
    required this.connected,
    required this.action,
  });

  final IconData icon;
  final String name;
  final String blurb;
  final String status;
  final bool connected;
  final Widget action;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ac.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: ac.line),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: ac.fgDim),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: AymaType.sans(size: 15, color: ac.fg)),
                const SizedBox(height: 2),
                Text(blurb,
                    style:
                        AymaType.sans(size: 12, soft: true, color: ac.fgMute)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(
                      connected
                          ? Icons.check_circle_outline
                          : Icons.circle_outlined,
                      size: 14,
                      color: connected ? ac.accent : ac.fgMute,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        status,
                        style: AymaType.sans(
                            size: 12, soft: true, color: ac.fgMute),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          action,
        ],
      ),
    );
  }
}
