import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/api_client.dart';
import '../services/assist_context.dart';
import '../services/assistant_service.dart';
import '../services/orb_animation_settings.dart';
import '../theme.dart';
import '../widgets/ayma_toast.dart';
import '../widgets/ayma_wing_loader.dart';
import 'assistant_screen.dart';
import 'connect_agent_screen.dart';
import 'copilot_screen.dart';
import 'voice_preference_screen.dart';
import '../widgets/ayma_back_button.dart';

/// Ayma's settings: the voice she speaks with, how her orb animates, and the
/// wiki reset (§14.2), and connecting your own AI agent (MCP). Reached from the "Ayma" group on the Profile tab.
class AymaSettingsScreen extends StatefulWidget {
  const AymaSettingsScreen(
      {super.key, this.api, this.orbAnimationSettings, this.assistantService});

  static const path = '/settings/ayma';

  final ApiClient? api;
  final OrbAnimationSettings? orbAnimationSettings;
  final AssistantService? assistantService;

  @override
  State<AymaSettingsScreen> createState() => _AymaSettingsScreenState();
}

class _AymaSettingsScreenState extends State<AymaSettingsScreen>
    with WidgetsBindingObserver {
  OrbAnimationSettings get _orbAnim =>
      widget.orbAnimationSettings ?? orbAnimationSettingsGlobal;
  late final ApiClient _api = widget.api ?? ApiClient();
  late final AssistantService _assistant =
      widget.assistantService ?? AssistantService.instance;

  bool _resetting = false;

  /// Null until the platform answers: whether Ayma is the default
  /// digital assistant right now.
  bool? _isDefaultAssistant;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadAssistantStatus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from the system default-apps page: reflect the choice.
    if (state == AppLifecycleState.resumed) _loadAssistantStatus();
  }

  Future<void> _loadAssistantStatus() async {
    final value = await _assistant.isDefaultAssistant();
    if (mounted) setState(() => _isDefaultAssistant = value);
  }

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
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child:
                Text('Models', style: AymaType.mono(size: 11, color: ac.fgMute)),
          ),
          ListTile(
            leading: Icon(Icons.record_voice_over_outlined, color: ac.fgDim),
            title: Text('Ayma’s models',
                style: AymaType.sans(size: 15, color: ac.fg)),
            subtitle: Text('Pick her brain, voice & language',
                style: AymaType.sans(size: 12, soft: true, color: ac.fgMute)),
            trailing: Icon(Icons.chevron_right, color: ac.fgMute),
            onTap: () => context.push(VoicePreferenceScreen.path),
          ),
          ListTile(
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
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Text('Co-pilot',
                style: AymaType.mono(size: 11, color: ac.fgMute)),
          ),
          ListTile(
            key: const Key('ayma_settings_copilot'),
            leading: Icon(Icons.screen_share_outlined, color: ac.fgDim),
            title: Text('Screen co-pilot',
                style: AymaType.sans(size: 15, color: ac.fg)),
            subtitle: Text(
                'Share your screen and Ayma points at what to tap',
                style: AymaType.sans(size: 12, soft: true, color: ac.fgMute)),
            trailing: Icon(Icons.chevron_right, color: ac.fgMute),
            onTap: () => context.push(CopilotScreen.path),
          ),
          Divider(color: ac.lineSoft),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Text('Animation',
                style: AymaType.mono(size: 11, color: ac.fgMute)),
          ),
          AnimatedBuilder(
            animation: _orbAnim,
            builder: (context, _) => Column(
              children: [
                SwitchListTile(
                  title: Text('Wing flutter animation',
                      style: AymaType.sans(size: 15, color: ac.fg)),
                  subtitle: Text(
                      'The orb’s continuous petal motion. Off rests the '
                      'petals everywhere — and saves battery.',
                      style: AymaType.sans(
                          size: 12, soft: true, color: ac.fgMute)),
                  value: _orbAnim.flutterEnabled,
                  onChanged: (v) => _orbAnim.setFlutterEnabled(v),
                ),
                SwitchListTile(
                  title: Text('Wing flutter in nav bar',
                      style: AymaType.sans(
                          size: 15,
                          color: _orbAnim.flutterEnabled ? ac.fg : ac.fgMute)),
                  subtitle: Text(
                      _orbAnim.flutterEnabled
                          ? 'Off keeps only the small nav-bar orb still.'
                          : 'Turn on “Wing flutter animation” first.',
                      style: AymaType.sans(
                          size: 12, soft: true, color: ac.fgMute)),
                  value: _orbAnim.navBarFlutterEnabled,
                  // Everywhere-off wins — the scoped toggle is inert then,
                  // shown disabled rather than hidden.
                  onChanged: _orbAnim.flutterEnabled
                      ? (v) => _orbAnim.setNavBarFlutterEnabled(v)
                      : null,
                ),
              ],
            ),
          ),
          Divider(color: ac.lineSoft),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Text('Assistant',
                style: AymaType.mono(size: 11, color: ac.fgMute)),
          ),
          ListTile(
            key: const Key('ayma_settings_assistant'),
            leading: Icon(Icons.smart_button_outlined, color: ac.fgDim),
            title: Text('Ayma Assistant',
                style: AymaType.sans(size: 15, color: ac.fg)),
            subtitle: Text(
                _isDefaultAssistant == true
                    ? 'Ayma is your default assistant — long-press Home '
                        'in any app to summon her'
                    : 'Summon Ayma from any app as your default assistant',
                style: AymaType.sans(size: 12, soft: true, color: ac.fgMute)),
            trailing: Icon(Icons.chevron_right, color: ac.fgMute),
            onTap: () => context.push(AssistantScreen.path),
          ),
          ListTile(
            key: const Key('ayma_settings_default_assistant'),
            leading: Icon(Icons.settings_outlined, color: ac.fgDim),
            title: Text('Default assistant app',
                style: AymaType.sans(size: 15, color: ac.fg)),
            subtitle: Text(
                _isDefaultAssistant == true
                    ? 'Ayma is selected in Android settings'
                    : 'Choose Ayma in Android default app settings',
                style: AymaType.sans(size: 12, soft: true, color: ac.fgMute)),
            trailing: Icon(Icons.open_in_new, color: ac.fgMute),
            onTap: () => _assistant.openDefaultAssistantSettings(),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(AssistPrivacy.settingsBlurb,
                style: AymaType.sans(size: 12, soft: true, color: ac.fgMute)),
          ),
          Divider(color: ac.lineSoft),
          ListTile(
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
