import 'dart:convert';

import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../theme.dart';

/// Password-gated admin console (§14.3): unlock, search users, inspect the full
/// per-user data model. The password lives only in this widget's state.
class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key, this.api});

  static const path = '/admin';

  final ApiClient? api;

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  late final ApiClient _api = widget.api ?? ApiClient();
  final _pwController = TextEditingController();
  final _queryController = TextEditingController();

  String? _password;
  bool _busy = false;
  String? _error;
  List<Map<String, dynamic>> _results = const [];
  Map<String, dynamic>? _detail;

  @override
  void dispose() {
    _pwController.dispose();
    _queryController.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final pw = _password;
    if (pw == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _detail = null;
    });
    try {
      final r = await _api.adminSearchUsers(pw, _queryController.text.trim());
      setState(() => _results = r);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open(String uid) async {
    final pw = _password;
    if (pw == null) return;
    setState(() => _busy = true);
    try {
      final d = await _api.adminUserDetail(pw, uid);
      setState(() => _detail = d);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    if (_password == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Admin')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _pwController,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Admin password'),
                onSubmitted: (_) =>
                    setState(() => _password = _pwController.text),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () =>
                    setState(() => _password = _pwController.text),
                child: const Text('Unlock'),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin'),
        actions: [
          IconButton(
            tooltip: 'Lock',
            icon: const Icon(Icons.lock_outline),
            onPressed: () => setState(() {
              _password = null;
              _results = const [];
              _detail = null;
            }),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _queryController,
                    decoration: const InputDecoration(
                        hintText: 'uid or name', isDense: true),
                    onSubmitted: (_) => _search(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: _busy ? null : _search,
                  icon: const Icon(Icons.search),
                ),
              ],
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_error!,
                  style: AymaType.sans(size: 13, color: AymaColors.error)),
            ),
          Expanded(
            child: _detail != null
                ? _DetailView(
                    detail: _detail!,
                    onBack: () => setState(() => _detail = null),
                  )
                : ListView(
                    children: [
                      for (final u in _results)
                        ListTile(
                          title: Text(
                            (u['name'] as String?)?.isNotEmpty == true
                                ? u['name'] as String
                                : u['uid'] as String,
                            style: AymaType.sans(size: 15, color: ac.fg),
                          ),
                          subtitle: Text(
                            '${u['uid']} · ${u['session_mode'] ?? '?'} · '
                            '${u['community'] ?? '?'}'
                            '${u['paused'] == true ? ' · paused' : ''}'
                            '${(u['trust_flags'] ?? 0) != 0 ? ' · ⚑${u['trust_flags']}' : ''}',
                            style: AymaType.sans(
                                size: 12, soft: true, color: ac.fgMute),
                          ),
                          onTap: () => _open(u['uid'] as String),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _DetailView extends StatelessWidget {
  const _DetailView({required this.detail, required this.onBack});
  final Map<String, dynamic> detail;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    Widget section(String title, Object? body) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: AymaType.mono(size: 11, color: ac.fgMute)),
              const SizedBox(height: 4),
              SelectableText(
                const JsonEncoder.withIndent('  ').convert(body),
                style: AymaType.sans(size: 12, color: ac.fgDim, height: 1.4),
              ),
            ],
          ),
        );

    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          child: TextButton.icon(
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back),
            label: const Text('Back to results'),
          ),
        ),
        section('uid', detail['uid']),
        section('account', detail['account']),
        section('profile', detail['profile']),
        section('trust_flags', detail['trust_flags']),
        section('wiki_pages', detail['wiki_pages']),
        section('matches', detail['matches']),
        section('dm_threads', detail['dm_threads']),
        section('deleted_account', detail['deleted_account']),
      ],
    );
  }
}
