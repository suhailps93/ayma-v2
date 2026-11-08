import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/api_client.dart';
import '../theme.dart';
import '../widgets/ayma_toast.dart';
import '../widgets/ayma_wing_loader.dart';
import 'connect_agent_screen.dart';
import 'voice_preference_screen.dart';
import '../widgets/ayma_back_button.dart';

/// Ayma's settings: the voice she speaks with,
/// wiki reset (§14.2), and connecting your own AI agent (MCP). Reached from the "Ayma" group on the Profile tab.
class AymaSettingsScreen extends StatefulWidget {
  const AymaSettingsScreen({super.key, this.api});

  static const path = '/settings/ayma';

  final ApiClient? api;

  @override
  State<AymaSettingsScreen> createState() => _AymaSettingsScreenState();
}

class _AymaSettingsScreenState extends State<AymaSettingsScreen> {
  late final ApiClient _api = widget.api ?? ApiClient();

  bool _resetting = false;

  Future<void> _confirmReset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: const Text('Wipe what Ayma has learned?'),
        content: const Text(
          'This clears your wiki and conversation history. Your account, '
          'profile and photos stay. This cannot be undone.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Wipe')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _resetting = true);
    try {
      await _api.resetWiki();
      if (mounted) {
        AymaToast.show(context, 'Ayma’s memory of you has been cleared.',
            kind: AymaToastKind.success);
      }
    } catch (e) {
      if (mounted) {
        AymaToast.show(context, 'Could not reset ($e).',
            kind: AymaToastKind.error);
      }
    } finally {
      if (mounted) setState(() => _resetting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(
        leading: const AymaBackButton(),
        title: const Text('Ayma’s settings')),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child:
                Text('Models', style: AymaType.mono(size: 11, color: ac.fgMute)),
          ),
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            leading: Icon(Icons.record_voice_over_outlined, color: ac.fgDim),
            title: Text('Ayma’s models',
                style: AymaType.sans(size: 15, color: ac.fg)),
            subtitle: Text('Pick her brain, voice & language',
                style: AymaType.sans(size: 12, soft: true, color: ac.fgMute)),
            trailing: Icon(Icons.chevron_right, color: ac.fgMute),
            onTap: () => context.push(VoicePreferenceScreen.path),
          ),
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            key: const Key('ayma_settings_connect_agent'),
            leading: Icon(Icons.hub_outlined, color: ac.fgDim),
            title: Text('Connect an agent (MCP)',
                style: AymaType.sans(size: 15, color: ac.fg)),
            subtitle: Text('Let your own AI agent use Ayma',
                style: AymaType.sans(size: 12, soft: true, color: ac.fgMute)),
            trailing: Icon(Icons.chevron_right, color: ac.fgMute),
            onTap: () => context.push(ConnectAgentScreen.path),
          ),
          Divider(color: ac.lineSoft),
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            title: Text('Wipe what Ayma has learned',
                style: AymaType.sans(size: 15, color: AymaColors.error)),
            subtitle: Text('Clears your wiki + history; keeps your account.',
                style:
                    AymaType.sans(size: 12, soft: true, color: ac.fgMute)),
            // Wiki/history wipe in flight — trailing slot, wings only.
            trailing: _resetting
                ? const AymaWingLoader(size: 18, showLabel: false)
                : null,
            onTap: _resetting ? null : _confirmReset,
          ),
        ],
      ),
    );
  }
}
