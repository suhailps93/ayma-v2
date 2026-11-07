import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/api_client.dart';
import '../services/copilot_highlight.dart';
import '../services/copilot_service.dart';
import '../theme.dart';
import '../widgets/ayma_back_button.dart';
import '../widgets/ayma_toast.dart';

/// Screen co-pilot: Ayma watches the screen you share and points at what
/// to tap — she never taps or types for you.
///
/// Flow (Android V1): read the explainer → grant "draw over other apps"
/// once → Start sharing (system consent, every session) → switch to any
/// app → ask Ayma here (or watch the ring appear) → she draws a pulsing
/// ring over the right button and you tap it. At a text field she drafts
/// the text instead; you review it and tap Copy, then paste it yourself.
///
/// Privacy rails surfaced in the UI because they ARE the feature: frames
/// are never saved, banking/password (FLAG_SECURE) screens pause sharing
/// automatically, and a Stop pill floats over every app while sharing.
class CopilotScreen extends StatefulWidget {
  const CopilotScreen({super.key, this.api, this.service});

  static const path = '/copilot';

  final ApiClient? api;
  final CopilotService? service;

  @override
  State<CopilotScreen> createState() => _CopilotScreenState();
}

class _CopilotScreenState extends State<CopilotScreen>
    with WidgetsBindingObserver {
  late final ApiClient _api = widget.api ?? ApiClient();
  late final CopilotService _service =
      widget.service ?? copilotServiceGlobal;

  final _goalController = TextEditingController();
  bool? _overlayGranted;
  bool _sideloaded = false;
  bool _installSourceChecked = false;
  // Set when we send the user to the system overlay page; if they come
  // back STILL ungranted, the grant is blocked (Restricted Settings on
  // sideloaded installs locks the toggle) and we show the recovery card.
  bool _overlaySettingsVisited = false;
  bool _asking = false;
  CopilotTarget? _lastTarget;
  String? _askError;
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshOverlayPermission();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _goalController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Returning from the system overlay-settings page: re-read the grant.
    if (state == AppLifecycleState.resumed) _refreshOverlayPermission();
  }

  Future<void> _refreshOverlayPermission() async {
    final granted = await _service.canDrawOverlays();
    var sideloaded = _sideloaded;
    if (!_installSourceChecked) {
      _installSourceChecked = true;
      sideloaded = await _service.wasSideloaded();
    }
    if (mounted) {
      setState(() {
        _overlayGranted = granted;
        _sideloaded = sideloaded;
      });
    }
  }

  Future<void> _openOverlaySettings() async {
    _overlaySettingsVisited = true;
    await _service.openOverlaySettings();
  }

  Future<void> _startSharing() async {
    if (_overlayGranted != true) {
      await _openOverlaySettings();
      return;
    }
    final consented = await _service.requestCaptureAndStart();
    if (!mounted) return;
    if (!consented) {
      AymaToast.show(
        context,
        'Screen sharing needs your OK on the system prompt.',
        kind: AymaToastKind.error,
      );
    }
  }

  Future<void> _ask() async {
    final goal = _goalController.text.trim();
    final frame = _service.latestFrame;
    if (goal.isEmpty || frame == null || _asking) return;
    setState(() {
      _asking = true;
      _askError = null;
      _copied = false;
    });
    try {
      final target = await _api.copilotLocate(
        frameBytes: frame.bytes,
        goal: goal,
      );
      if (!mounted) return;
      setState(() => _lastTarget = target);
      if (target.found) {
        await _service.showHighlight(target, geometry: frame.geometry());
      }
    } on ApiException catch (e) {
      if (mounted) {
        setState(() => _askError = e.message);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _askError = 'Something went wrong asking Ayma.');
      }
    } finally {
      if (mounted) setState(() => _asking = false);
    }
  }

  /// The ONLY clipboard write in the co-pilot, and it runs exclusively
  /// from the user's tap on "Copy Ayma's draft" below — or from Ayma
  /// tapping that same button via ui_action after the user said yes out
  /// loud in a voice walkthrough (she reads the draft aloud and asks
  /// first; see the backend's draft_say). Never call this from a locate
  /// result directly: no silent clipboard writes, ever.
  Future<void> _copyDraft(String draft) async {
    await Clipboard.setData(ClipboardData(text: draft));
    if (mounted) setState(() => _copied = true);
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(
        leading: const AymaBackButton(),
        title: const Text('Screen co-pilot'),
      ),
      body: AnimatedBuilder(
        animation: _service,
        builder: (context, _) {
          final sharing = _service.isSharing;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              Text(
                'Ayma watches your screen and points at what to tap. '
                'You do the tapping — she never taps, types, or controls '
                'another app for you.',
                style: AymaType.sans(size: 14, color: ac.fg),
              ),
              const SizedBox(height: 12),
              _rail(context, Icons.visibility_outlined,
                  'Frames are never saved. Only the frame you ask about is sent, and only when you ask.'),
              _rail(context, Icons.lock_outline,
                  'Bank and password screens pause sharing automatically — Ayma sees a black screen there, never your details.'),
              _rail(context, Icons.stop_circle_outlined,
                  'Stop any time: the Stop pill floats over every app while you share, and the notification has a Stop button too.'),
              const SizedBox(height: 20),
              if (!_service.isSupported)
                Text(
                  'Screen co-pilot is Android-only for now. On iPhone, '
                  'Ayma can still guide you from a screenshot you share '
                  'with her in chat.',
                  style: AymaType.sans(size: 13, soft: true, color: ac.fgMute),
                )
              else if (!sharing)
                ..._startSection(context)
              else
                ..._sharingSection(context),
            ],
          );
        },
      ),
    );
  }

  Widget _rail(BuildContext context, IconData icon, String text) {
    final ac = context.ac;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: ac.fgDim),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: AymaType.sans(size: 13, soft: true, color: ac.fgMute),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _startSection(BuildContext context) {
    final ac = context.ac;
    final granted = _overlayGranted;
    return [
      Text(
        'Before you start',
        style: AymaType.mono(size: 11, color: ac.fgMute),
      ),
      const SizedBox(height: 8),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(
          granted == true
              ? Icons.check_circle_outline
              : Icons.layers_outlined,
          color: granted == true ? ac.success : ac.fgDim,
        ),
        title: Text(
          'Draw over other apps',
          style: AymaType.sans(size: 15, color: ac.fg),
        ),
        subtitle: Text(
          granted == true
              ? 'Allowed — Ayma can draw the highlight ring.'
              : 'One-time system permission so the ring can float over the app you are using. Tap to allow.',
          style: AymaType.sans(size: 12, soft: true, color: ac.fgMute),
        ),
        trailing: granted == true
            ? null
            : Icon(Icons.chevron_right, color: ac.fgMute),
        onTap: granted == true ? null : _openOverlaySettings,
      ),
      const SizedBox(height: 12),
      FilledButton.icon(
        key: const Key('copilot_start_button'),
        onPressed: granted == null ? null : _startSharing,
        icon: const Icon(Icons.screen_share_outlined),
        label: Text(granted == true ? 'Start sharing' : 'Allow drawing first'),
      ),
      const SizedBox(height: 8),
      Text(
        'Android asks for your OK every time you start — that prompt is '
        'the consent, and sharing runs only until you stop it.',
        style: AymaType.sans(size: 12, soft: true, color: ac.fgMute),
      ),
      // Restricted Settings recovery: shown when the install is
      // sideloaded (Android locks the overlay toggle for those), or when
      // the user already went to the system page and came back still
      // ungranted — the toggle was blocked, whatever the install source.
      if (granted != true && (_sideloaded || _overlaySettingsVisited))
        ..._restrictedSettingsHelp(context),
    ];
  }

  /// The exact way out of Android's Restricted Settings lock, shown
  /// in-app instead of leaving the user at the dead system dialog
  /// ("App was denied access — this restricted permission").
  List<Widget> _restrictedSettingsHelp(BuildContext context) {
    final ac = context.ac;
    Widget step(String text) => Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            text,
            style: AymaType.sans(size: 13, soft: true, color: ac.fgMute),
          ),
        );
    return [
      const SizedBox(height: 16),
      Container(
        key: const Key('copilot_restricted_help'),
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: ac.bgCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: ac.lineSoft),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Android is locking this permission — here is the fix',
              style: AymaType.sans(size: 14, color: ac.fg),
            ),
            const SizedBox(height: 6),
            Text(
              'This Ayma install did not come from Google Play, so Android '
              'calls "Display over other apps" a restricted setting and '
              'keeps the switch off ("App was denied access") until you '
              'allow it once. It takes about 20 seconds:',
              style: AymaType.sans(size: 13, soft: true, color: ac.fgMute),
            ),
            step('1. Tap "Open App info" below (or open Settings → Apps → Ayma).'),
            step('2. Tap the three dots ⋮ at the top right of App info, then "Allow restricted settings".'),
            step('3. Confirm with your PIN, pattern, or fingerprint.'),
            step('4. Come back here and tap "Draw over other apps" again — the switch will turn on now.'),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              key: const Key('copilot_open_app_info_button'),
              onPressed: () => _service.openAppInfo(),
              icon: const Icon(Icons.info_outline),
              label: const Text('Open App info'),
            ),
          ],
        ),
      ),
    ];
  }

  List<Widget> _sharingSection(BuildContext context) {
    final ac = context.ac;
    final target = _lastTarget;
    final children = <Widget>[
      Row(
        children: [
          Icon(Icons.fiber_manual_record, size: 12, color: ac.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _service.securePaused
                  ? 'Paused — this screen is protected, so Ayma sees black.'
                  : _service.lockPaused
                      ? 'Paused — your phone is locked.'
                      : 'Sharing — Ayma can see your screen.',
              style: AymaType.sans(size: 14, color: ac.fg),
            ),
          ),
          OutlinedButton.icon(
            key: const Key('copilot_stop_button'),
            onPressed: () => _service.stopSharing(),
            icon: const Icon(Icons.stop),
            label: const Text('Stop'),
          ),
        ],
      ),
      const SizedBox(height: 16),
      Text(
        'Switch to the app you need help with, do a step, then come back '
        'here and ask. The ring appears over that app and fades after a '
        'few seconds — or when the screen changes.',
        style: AymaType.sans(size: 13, soft: true, color: ac.fgMute),
      ),
      const SizedBox(height: 16),
      TextField(
        key: const Key('copilot_goal_field'),
        controller: _goalController,
        textInputAction: TextInputAction.send,
        onSubmitted: (_) => _ask(),
        decoration: const InputDecoration(
          labelText: 'What are you trying to do?',
          hintText: 'e.g. reply to this message, pay this bill…',
          border: OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 12),
      FilledButton.icon(
        key: const Key('copilot_ask_button'),
        onPressed: (_asking || !_service.canAsk) ? null : _ask,
        icon: _asking
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.center_focus_strong_outlined),
        label: Text(_asking ? 'Ayma is looking…' : 'Ask Ayma what to tap'),
      ),
      if (!_service.canAsk && !_service.securePaused)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            'Waiting for a clear frame from your shared screen…',
            style: AymaType.sans(size: 12, soft: true, color: ac.fgMute),
          ),
        ),
      if (_askError != null)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(
            _askError!,
            style: AymaType.sans(size: 13, color: ac.error),
          ),
        ),
    ];

    if (target != null) {
      children.add(const SizedBox(height: 20));
      if (!target.found) {
        children.add(
          Text(
            target.say.isEmpty
                ? 'Ayma does not see that on this screen.'
                : target.say,
            style: AymaType.sans(size: 14, color: ac.fg),
          ),
        );
      } else {
        children.addAll([
          Text(
            target.say.isEmpty ? 'Tap the highlighted spot.' : target.say,
            style: AymaType.sans(size: 14, color: ac.fg),
          ),
          if (target.label.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Highlighting: ${target.label}',
                style:
                    AymaType.sans(size: 12, soft: true, color: ac.fgMute),
              ),
            ),
          TextButton(
            onPressed: () => _service.clearHighlight(),
            child: const Text('Clear highlight'),
          ),
        ]);
        final draft = target.draftText;
        if (target.kind == CopilotTargetKind.textField && draft != null) {
          children.addAll([
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: ac.bgCard,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: ac.lineSoft),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Ayma drafted this for the highlighted box:',
                    style: AymaType.mono(size: 11, color: ac.fgMute),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    draft,
                    style: AymaType.sans(size: 14, color: ac.fg),
                  ),
                  if (target.voiceDraftPrompt.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      'In a voice walkthrough, Ayma reads it aloud and asks '
                      'first: "${target.voiceDraftPrompt}"',
                      style: AymaType.sans(
                          size: 12, soft: true, color: ac.fgMute),
                    ),
                  ],
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    key: const Key('copilot_copy_draft_button'),
                    onPressed: () => _copyDraft(draft),
                    icon: const Icon(Icons.copy_outlined),
                    label: Text(_copied ? 'Copied' : "Copy Ayma's draft"),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Nothing is copied until you tap this — or say yes when '
                    'Ayma asks in a voice walkthrough.',
                    style:
                        AymaType.sans(size: 12, soft: true, color: ac.fgMute),
                  ),
                  if (_copied)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'Copied. Now tap the highlighted box in the other '
                        'app, long-press, and paste.',
                        style: AymaType.sans(
                            size: 12, soft: true, color: ac.fgMute),
                      ),
                    ),
                ],
              ),
            ),
          ]);
        }
      }
    }
    return children;
  }
}
