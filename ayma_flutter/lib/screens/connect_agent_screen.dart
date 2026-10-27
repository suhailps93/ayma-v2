import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../env.dart';
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

  /// Ayma's MCP endpoint, derived from the API base the rest of the app uses
  /// (never hardcoded here) — this is what the user adds in their AI assistant.
  final String _mcpUrl = '${Env.apiBaseUrl}/mcp';

  McpPending? _pending;
  bool _busy = false;
  bool _loadingConnections = true;
  // Turns true if the server answers that the feature is off (`mcp_server`
  // flag). Connecting then can't succeed, so we say so instead of letting a
  // code fail quietly.
  bool _disabled = false;
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
      if (e.disabled) {
        setState(() => _disabled = true);
      } else {
        AymaToast.show(context, e.message, kind: AymaToastKind.error);
      }
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
      if (!mounted) return;
      if (e.disabled) setState(() => _disabled = true);
      AymaToast.show(context, e.message, kind: AymaToastKind.error);
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
      if (!mounted) return;
      if (e.disabled) setState(() => _disabled = true);
      AymaToast.show(context, e.message, kind: AymaToastKind.error);
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

  Future<void> _copyUrl() async {
    try {
      await Clipboard.setData(ClipboardData(text: _mcpUrl));
      if (mounted) AymaToast.show(context, 'Copied', kind: AymaToastKind.success);
    } catch (_) {
      if (mounted) {
        AymaToast.show(context, "Couldn't copy that.", kind: AymaToastKind.error);
      }
    }
  }

  void _showHelp() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _HelpSheet(mcpUrl: _mcpUrl, onCopyUrl: _copyUrl),
    );
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
            'Let an outside AI assistant — like Claude — act for you in Ayma. '
            'It does all the thinking; Ayma is its hands and memory, and carries '
            'out only what you allow. Every action still runs the same safety '
            'checks as when you use Ayma yourself.',
            style: theme.textTheme.bodyMedium,
          ),
          if (_disabled) ...[
            const SizedBox(height: 16),
            _DisabledNote(),
          ],
          const SizedBox(height: 20),
          _CapabilitiesCard(),
          const SizedBox(height: 20),
          _InstructionsCard(
            mcpUrl: _mcpUrl,
            onCopyUrl: _copyUrl,
            onLearnMore: _showHelp,
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

/// "What your agent can do" — the plain-language capabilities a connected
/// agent has, drawn directly from the real MCP tools (`docs/MCP_SERVER.md`):
/// profile/story writes, match reads, DM reads + drafts/sends, and practice
/// prep. Shown near the intro, above the code field — this is *what it does*,
/// separate from the "How to connect" steps (*how to set it up*). Ends with
/// the guardrails every action still runs through.
class _CapabilitiesCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('What your agent can do', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            const _Capability(
              icon: Icons.edit_outlined,
              title: 'Update your profile & story',
              body: 'Write a sharper bio or story for you. Ayma saves exactly '
                  'what your agent writes — nothing goes up until it clears '
                  'moderation.',
            ),
            const _Capability(
              icon: Icons.favorite_outline,
              title: 'See and understand your matches',
              body: 'Look through who you\'ve matched with, your scores, and '
                  'what you have in common or where you differ.',
            ),
            const _Capability(
              icon: Icons.chat_bubble_outline,
              title: 'Read your conversations',
              body: 'Go through your chats and draft replies — or send '
                  'messages for you when you let it.',
            ),
            const _Capability(
              icon: Icons.school_outlined,
              title: 'Help you practice & prep',
              body: 'Run practice conversations so you can rehearse before you '
                  'reach out for real.',
            ),
            const SizedBox(height: 4),
            _GuardrailsNote(),
          ],
        ),
      ),
    );
  }
}

/// One capability line: a leading icon, a bold title, and a short plain
/// description beneath. Wraps and scales with text size rather than clipping.
class _Capability extends StatelessWidget {
  const _Capability({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 20, color: theme.colorScheme.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(body, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The guardrails that bound every agent action, closing the capabilities
/// card: same safety checks as the user, your data only, revoke anytime.
class _GuardrailsNote extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.shield_outlined, size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Every action runs the same checks you do — 18+, moderation and '
              'consent. An agent only ever touches your own data, can never do '
              'more than you could, and you can disconnect it anytime.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

/// The step-by-step "how to actually connect an agent" block, shown above the
/// code field. Plain, scannable, and it carries the real MCP URL (copyable)
/// plus a "Learn more" that opens [_HelpSheet].
class _InstructionsCard extends StatelessWidget {
  const _InstructionsCard({
    required this.mcpUrl,
    required this.onCopyUrl,
    required this.onLearnMore,
  });

  final String mcpUrl;
  final VoidCallback onCopyUrl;
  final VoidCallback onLearnMore;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('How to connect', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            _Step(
              number: 1,
              child: Text(
                'In your AI assistant (like Claude), add Ayma as an MCP server:',
                style: theme.textTheme.bodyMedium,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 32, top: 6, bottom: 4),
              child: _UrlRow(url: mcpUrl, onCopy: onCopyUrl),
            ),
            _Step(
              number: 2,
              child: Text(
                'Start it — your assistant will show you a short code.',
                style: theme.textTheme.bodyMedium,
              ),
            ),
            _Step(
              number: 3,
              child: Text(
                'Type that code below and tap Review.',
                style: theme.textTheme.bodyMedium,
              ),
            ),
            _Step(
              number: 4,
              child: Text(
                'Approve the connection. Your assistant can then act for you '
                'in Ayma, within what you allow.',
                style: theme.textTheme.bodyMedium,
              ),
            ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                onPressed: onLearnMore,
                child: const Text('Learn more'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One numbered line: the index in a small circle, then wrapping content.
class _Step extends StatelessWidget {
  const _Step({required this.number, required this.child});

  final int number;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: theme.colorScheme.secondaryContainer,
                shape: BoxShape.circle,
              ),
              child: Text(
                '$number',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSecondaryContainer,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// The MCP URL shown as selectable text with a copy button. Wraps instead of
/// overflowing on a narrow screen.
class _UrlRow extends StatelessWidget {
  const _UrlRow({required this.url, required this.onCopy});

  final String url;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: SelectableText(
            url,
            style: theme.textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
              color: theme.colorScheme.primary,
            ),
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: 'Copy',
          icon: const Icon(Icons.copy_rounded, size: 18),
          onPressed: onCopy,
        ),
      ],
    );
  }
}

/// Honest note when the `mcp_server` flag is off: a code can be typed but can't
/// connect yet. Shown only after the server tells us the feature is disabled.
class _DisabledNote extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              "Agent connections aren't switched on yet. You can enter a code, "
              "but it won't connect until this feature is live.",
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

/// The fuller "how this works" explanation, from `docs/MCP_SERVER.md`: the
/// device flow, what access the agent gets, and the safety boundaries.
class _HelpSheet extends StatelessWidget {
  const _HelpSheet({required this.mcpUrl, required this.onCopyUrl});

  final String mcpUrl;
  final VoidCallback onCopyUrl;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        children: [
          Text('Connecting an agent', style: theme.textTheme.titleLarge),
          const SizedBox(height: 12),
          Text(
            'An agent is an outside AI assistant — like Claude — that you let '
            'act for you in Ayma. It does the thinking; Ayma is its hands and '
            'memory. Nothing connects until you approve it here, in the app '
            'where you\'re already signed in.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          Text('The steps', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            'Add Ayma as an MCP server in your assistant:',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 6),
          _UrlRow(url: mcpUrl, onCopy: onCopyUrl),
          const SizedBox(height: 6),
          Text(
            'Your assistant starts a one-time sign-in and shows you a short '
            'code. You type that code on this screen and tap Review — Ayma '
            'shows you which assistant is asking and exactly what it wants to '
            'do. If it looks right, tap Approve. The code is single-use and '
            'expires in about ten minutes.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          Text('Staying safe', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            'Ayma is 18+. Every action an agent takes runs the same age, '
            'moderation and privacy checks as you using the app yourself — it '
            'can never do more than you could, and it only ever touches your '
            'own data. You choose what access to grant, and you can disconnect '
            'any agent at any time from this screen. Only approve a code you '
            'started yourself.',
            style: theme.textTheme.bodyMedium,
          ),
        ],
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
