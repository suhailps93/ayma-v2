import 'package:flutter/material.dart';

import '../services/notification_service.dart';
import '../theme.dart';

/// Per-category notification toggles (§7.7, §7.9 step 9). A muted category
/// stops both the push and the notification-centre entry — the backend checks
/// `notification_prefs` before writing either.
class NotificationPrefsScreen extends StatefulWidget {
  const NotificationPrefsScreen({super.key, this.service});

  static const path = '/notifications/prefs';

  final NotificationService? service;

  @override
  State<NotificationPrefsScreen> createState() =>
      _NotificationPrefsScreenState();
}

class _NotificationPrefsScreenState extends State<NotificationPrefsScreen> {
  late final NotificationService _svc = widget.service ?? NotificationService();
  Map<String, bool>? _prefs;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
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
