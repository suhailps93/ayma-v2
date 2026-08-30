import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/api_client.dart';
import '../theme.dart';

/// Shown when `/bootstrap` reports the account is soft-deleted (§3.6). The
/// person can restore everything, or leave it — a scheduled job purges the
/// quarantine after the recovery window.
class RecoveryScreen extends StatefulWidget {
  const RecoveryScreen({super.key, this.apiClient});

  static const path = '/recover';

  final ApiClient? apiClient;

  @override
  State<RecoveryScreen> createState() => _RecoveryScreenState();
}

class _RecoveryScreenState extends State<RecoveryScreen> {
  late final ApiClient _api = widget.apiClient ?? ApiClient();
  bool _working = false;
  String? _error;

  Future<void> _recover() async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await _api.recoverAccount();
      if (!mounted) return;
      context.go('/');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Recovery failed ($e).';
        _working = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Welcome back',
                  style: AymaType.serif(size: 28, color: ac.fg)),
              const SizedBox(height: 12),
              Text(
                'Your account is scheduled for deletion but still here for now. '
                'Recover it and everything — your conversations, your profile, '
                'your story — comes back exactly as it was.',
                style: AymaType.sans(size: 15, color: ac.fgDim, height: 1.5),
              ),
              const SizedBox(height: 28),
              FilledButton(
                onPressed: _working ? null : _recover,
                child: Text(_working ? 'Recovering…' : 'Recover my account'),
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(_error!,
                    style:
                        AymaType.sans(size: 13, color: AymaColors.error)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
