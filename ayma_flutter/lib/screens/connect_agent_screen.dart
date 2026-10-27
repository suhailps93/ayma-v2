import 'package:flutter/material.dart';

import '../services/mcp_connect_service.dart';
import '../widgets/ayma_back_button.dart';
import '../widgets/ayma_toast.dart';

/// "Connect an agent" — the in-app approval step of the Ayma MCP server's OAuth
/// device flow (`docs/MCP_SERVER.md`). An outside AI client (e.g. Claude) shows
/// the user a short code; the user — already signed in here — types it, sees
/// which client is asking and what access it wants, and approves. Approval is
/// the only point the user's identity is bound to the connection, so it happens
/// inside the authenticated app, never in a browser.
///
/// Also lists already-connected agents and lets the user revoke any of them.
class ConnectAgentScreen extends StatefulWidget {
  const ConnectAgentScreen({super.key, this.service});

  static const path = '/settings/connect-agent';

  final McpConnectService? service;

  @override
  State<ConnectAgentScreen> createState() => _ConnectAgentScreenState();
}

class _ConnectAgentScreenState extends State<ConnectAgentScreen> {
  late final McpConnectService _svc = widget.service ?? McpConnectService();
  final _codeController = TextEditingController();

  McpPending? _pending;
  bool _busy = false;
  bool _loadingConnections = true;
  List<McpConnection> _connections = const [];

  @override
  void initState() {
    super.initState();
    _loadConnections();
  }

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _loadConnections() async {
    setState(() => _loadingConnections = true);
    try {
      final rows = await _svc.connections();
      if (!mounted) return;
      setState(() => _connections = rows);
    } on McpConnectException catch (e) {
      if (!mounted) return;
      if (!e.disabled) AymaToast.show(context, e.message, kind: AymaToastKind.error);
    } catch (_) {
      // A missing connection list must never block approving a new one.
    } finally {
      if (mounted) setState(() => _loadingConnections = false);
    }
  }

  Future<void> _review() async {
    final code = _codeController.text.trim();
    if (code.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    try {
      final p = await _svc.pending(code);
      if (!mounted) return;
      if (p == null) {
        AymaToast.show(
          context,
          "That code wasn't found — it may have expired. Ask the agent for a new one.",
          kind: AymaToastKind.error,
        );
      }
      setState(() => _pending = p);
    } on McpConnectException catch (e) {
      if (mounted) AymaToast.show(context, e.message, kind: AymaToastKind.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _approve() async {
    final code = _codeController.text.trim();
    setState(() => _busy = true);
    try {
      await _svc.approve(code);
      if (!mounted) return;
      AymaToast.show(context, 'Agent connected.', kind: AymaToastKind.success);
      _codeController.clear();
      setState(() => _pending = null);
      await _loadConnections();
    } on McpConnectException catch (e) {
      if (mounted) AymaToast.show(context, e.message, kind: AymaToastKind.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deny() async {
    final code = _codeController.text.trim();
    setState(() => _busy = true);
    try {
      await _svc.deny(code);
    } on McpConnectException catch (_) {
      // Denial is best-effort; the code expires on its own regardless.
    } finally {
      if (mounted) {
        setState(() {
          _pending = null;
          _busy = false;
        });
        _codeController.clear();
      }
    }
  }

  Future<void> _revoke(McpConnection c) async {
    setState(() => _busy = true);
    try {
      await _svc.revoke(c.tokenId);
      if (mounted) {
        AymaToast.show(context, 'Disconnected.', kind: AymaToastKind.success);
      }
      await _loadConnections();
    } on McpConnectException catch (e) {
      if (mounted) AymaToast.show(context, e.message, kind: AymaToastKind.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(leading: const AymaBackButton(), title: const Text('Connect an agent')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          Text(
            'Let an outside AI assistant act for you in Ayma — read and update '
            'your profile, see your matches, and read or send your messages. '
            'The assistant does all the thinking; Ayma just carries it out, and '
            'every action still runs the same safety checks.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _codeController,
            autocorrect: false,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
              labelText: 'Code from the agent',
              hintText: 'ABCD-2345',
            ),
            onSubmitted: (_) => _busy ? null : _review(),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _busy ? null : _review,
              child: const Text('Review'),
            ),
          ),
          if (_pending != null) ...[
            const SizedBox(height: 20),
            _PendingCard(
              pending: _pending!,
              busy: _busy,
              onApprove: _approve,
              onDeny: _deny,
            ),
          ],
          const SizedBox(height: 28),
          Text('Connected agents', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          if (_loadingConnections)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_connections.isEmpty)
            Text('No agents are connected.', style: theme.textTheme.bodyMedium)
          else
            ..._connections.map(
              (c) => _ConnectionTile(
                connection: c,
                busy: _busy,
                onRevoke: () => _revoke(c),
              ),
            ),
        ],
      ),
    );
  }
}

class _PendingCard extends StatelessWidget {
  const _PendingCard({
    required this.pending,
    required this.busy,
    required this.onApprove,
    required this.onDeny,
  });

  final McpPending pending;
  final bool busy;
  final VoidCallback onApprove;
  final VoidCallback onDeny;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(pending.clientId, style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text('wants permission to:', style: theme.textTheme.bodyMedium),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final s in pending.scopes)
                  Chip(label: Text(kMcpScopeLabels[s] ?? s)),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: busy ? null : onApprove,
                child: const Text('Approve'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: busy ? null : onDeny,
                child: const Text('Deny'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConnectionTile extends StatelessWidget {
  const _ConnectionTile({
    required this.connection,
    required this.busy,
    required this.onRevoke,
  });

  final McpConnection connection;
  final bool busy;
  final VoidCallback onRevoke;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scopeText = connection.scopes
        .map((s) => kMcpScopeLabels[s] ?? s)
        .join(', ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(connection.clientId, style: theme.textTheme.titleSmall),
          if (scopeText.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(scopeText, style: theme.textTheme.bodySmall),
            ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              onPressed: busy ? null : onRevoke,
              child: const Text('Disconnect'),
            ),
          ),
          const Divider(height: 1),
        ],
      ),
    );
  }
}
