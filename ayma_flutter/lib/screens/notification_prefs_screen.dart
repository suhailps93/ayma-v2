import 'dart:async';

import 'package:flutter/material.dart';

import '../services/notification_service.dart';
import '../services/push_permission.dart';
import '../services/push_service.dart';
import '../theme.dart';
import '../widgets/ayma_back_button.dart';
import '../widgets/ayma_toast.dart';
import '../widgets/ayma_wing_loader.dart';
import '../widgets/overflow_guards.dart';

/// A master "Push notifications" row mirroring the real OS permission, then
/// per-category notification toggles (§7.7, §7.9 step 9). A muted category
/// stops both the push and the notification-centre entry — the backend checks
/// `notification_prefs` before writing either.
///
/// Live updates (founder, 2026-11-06): the category switches render from
/// the prefs doc Ayma's notification commands also write (server-side), via
/// [NotificationService.watchPrefs] — when she turns a category off while
/// this screen is open, the switch moves in the same moment, with no
/// navigate-away-and-back. A category whose own toggle write is still in
/// flight keeps the user's value until that write lands.
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

  /// Live prefs subscription (see the class doc) and the categories whose
  /// own toggle write is in flight (their local value wins until it lands).
  StreamSubscription<Map<String, bool>>? _prefsSub;
  final Set<String> _pendingToggles = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    _watchPrefs();
    _refreshOs();
  }

  @override
  void dispose() {
    _prefsSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Reflect prefs-doc changes made elsewhere (Ayma's server-side
  /// notification commands) on the visible switches, live. Best-effort:
  /// with no Firestore (e.g. a fake service in a widget test) the screen
  /// keeps its one-shot [_load] behaviour.
  void _watchPrefs() {
    try {
      _prefsSub = _svc.watchPrefs().listen(
        (prefs) {
          if (!mounted) return;
          setState(() {
            final local = _prefs;
            _prefs = {
              for (final e in prefs.entries)
                e.key: (_pendingToggles.contains(e.key) && local != null)
                    ? (local[e.key] ?? e.value)
                    : e.value,
            };
            _error = null;
          });
        },
        onError: (_) {},
      );
    } catch (_) {
      // No live updates in this environment; _load still rendered.
    }
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
    _pendingToggles.add(category);
    setState(() => _prefs = {...?_prefs, category: value});
    try {
      await _svc.setPref(category, value);
    } catch (e) {
      if (!mounted) return;
      setState(() => _prefs = {...?_prefs, category: !value});
      AymaToast.show(context, 'Could not save ($e).',
          kind: AymaToastKind.error);
    } finally {
      _pendingToggles.remove(category);
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
          contentPadding: const EdgeInsets.symmetric(horizontal: 20),
          title: Text('Push notifications',
              style: AymaType.sans(size: 15, color: ac.fg)),
          subtitle: Text(label, style: AymaType.sans(size: 13, color: ac.fg)),
          trailing: on
              ? null
              : FilledButton(
                  style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 48)),
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
      appBar: AppBar(
        leading: const AymaBackButton(),
        title: const Text('Notification preferences')),
      body: _error != null
          ? CenteredScroll(
              padding: const EdgeInsets.all(24),
              child: Text('Could not load ($_error).',
                  style: AymaType.sans(size: 14, color: ac.errorText)),
            )
          : _prefs == null
              // The notification_prefs read still in flight.
              ? const Center(
                  child: AymaWingLoader(lines: AymaLoaderLines.notifPrefs),
                )
              : ListView(
                  children: [
                    _pushSection(ac),
                    for (final entry in notificationCategories.entries)
                      SwitchListTile(
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 20),
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
