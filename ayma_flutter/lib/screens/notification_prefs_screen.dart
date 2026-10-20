import 'package:flutter/material.dart';

import '../services/notification_service.dart';
import '../services/push_permission.dart';
import '../services/push_service.dart';
import '../theme.dart';

/// A master "Push notifications" row mirroring the real OS permission, then
/// per-category notification toggles (§7.7, §7.9 step 9). A muted category
/// stops both the push and the notification-centre entry — the backend checks
/// `notification_prefs` before writing either.
class NotificationPrefsScreen extends StatefulWidget {
  const NotificationPrefsScreen({
    super.key,
    this.service,
    this.permission,
    this.onGranted,
  });

  static const path = '/notifications/prefs';

  final NotificationService? service;
  final PushPermission? permission;

  /// Runs when the OS permission becomes granted so the FCM token registers.
  /// Defaults to [PushService.syncToken].
  final Future<void> Function()? onGranted;

  @override
  State<NotificationPrefsScreen> createState() =>
      _NotificationPrefsScreenState();
}

class _NotificationPrefsScreenState extends State<NotificationPrefsScreen>
    with WidgetsBindingObserver {
  late final NotificationService _svc = widget.service ?? NotificationService();
  late final PushPermission _permission =
      widget.permission ?? PushPermission();
  Map<String, bool>? _prefs;
  String? _error;
  PushPermissionState? _osState;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    _refreshOs();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshOs();
  }

  Future<void> _refreshOs([PushPermissionState? known]) async {
    final s = known ?? await _permission.status();
    if (!mounted) return;
    final becameGranted = s == PushPermissionState.granted &&
        _osState != PushPermissionState.granted;
    setState(() => _osState = s);
    if (becameGranted) {
      try {
        await (widget.onGranted ?? PushService().syncToken)();
      } catch (e) {
        debugPrint('Push token sync after grant failed: $e');
      }
    }
  }

  Future<void> _enable() async {
    if (_osState == PushPermissionState.notAsked) {
      await _refreshOs(await _permission.request());
      if (_osState != PushPermissionState.denied) return;
    }
    await _permission.openSystemSettings();
  }

  Future<void> _load() async {
    try {
      final p = await _svc.readPrefs();
      if (mounted) setState(() => _prefs = p);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _toggle(String category, bool value) async {
    setState(() => _prefs = {...?_prefs, category: value});
    try {
      await _svc.setPref(category, value);
    } catch (e) {
      if (!mounted) return;
      setState(() => _prefs = {...?_prefs, category: !value});
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not save ($e).')));
    }
  }

  Widget _pushSection(AymaTokens ac) {
    final s = _osState;
    if (s == null) return const SizedBox.shrink();
    final on = s == PushPermissionState.granted;
    final label = switch (s) {
      PushPermissionState.granted => 'On',
      PushPermissionState.denied => 'Off in system settings',
      PushPermissionState.notAsked => 'Not turned on yet',
    };
    return Column(
      children: [
        ListTile(
          title: Text('Push notifications',
              style: AymaType.sans(size: 15, color: ac.fg)),
          subtitle: Text(label, style: AymaType.sans(size: 13, color: ac.fg)),
          trailing: on
              ? null
              : FilledButton(
                  onPressed: _enable,
                  child: Text(s == PushPermissionState.notAsked
                      ? 'Turn on'
                      : 'Open settings'),
                ),
        ),
        if (on)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: TextButton(
                onPressed: _permission.openSystemSettings,
                child: const Text('Manage in system settings'),
              ),
            ),
          ),
        const Divider(height: 1),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(title: const Text('Notification preferences')),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Could not load ($_error).',
                    style: AymaType.sans(size: 14, color: AymaColors.error)),
              ),
            )
          : _prefs == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  children: [
                    _pushSection(ac),
                    for (final entry in notificationCategories.entries)
                      SwitchListTile(
                        title: Text(entry.value,
                            style: AymaType.sans(size: 15, color: ac.fg)),
                        value: _prefs![entry.key] ?? true,
                        onChanged: (v) => _toggle(entry.key, v),
                      ),
                  ],
                ),
    );
  }
}
