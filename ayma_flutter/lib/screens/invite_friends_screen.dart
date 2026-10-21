import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../services/api_client.dart';
import '../theme.dart';
import '../widgets/ayma_back_button.dart';

/// "Invite friends" (founder feature 2026-09-29): the user's personal referral
/// link, one big Share button (into any other app via the system share sheet),
/// and a copy affordance. The code itself is shown too — a new user can just
/// type it at sign-up if the link never gets tapped.
class InviteFriendsScreen extends StatefulWidget {
  const InviteFriendsScreen({super.key, this.api, this.share});

  static const path = '/invite-friends';

  final ApiClient? api;

  /// Injectable share seam for tests; defaults to the system share sheet.
  final Future<void> Function(String text)? share;

  @override
  State<InviteFriendsScreen> createState() => _InviteFriendsScreenState();
}

class _InviteFriendsScreenState extends State<InviteFriendsScreen> {
  late final ApiClient _api = widget.api ?? ApiClient();

  String? _code;
  String? _link;
  bool _failed = false;

  String get _message =>
      "I've been using Ayma, an AI that gets to know you and finds people "
      "who actually fit. She finds your person. Join me, my invite is inside: "
      '$_link';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await _api.referral();
      if (mounted) {
        setState(() {
          _code = r.code;
          _link = r.link;
          _failed = r.link.isEmpty;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _share() async {
    final share = widget.share ??
        (String text) => SharePlus.instance.share(ShareParams(text: text));
    try {
      await share(_message);
    } catch (_) {/* the sheet being dismissed/unavailable is not an error */}
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _link!));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(const SnackBar(content: Text('Link copied')));
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(
        leading: const AymaBackButton(),
        title: const Text('Invite friends')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: _failed
                  ? Text(
                      'Couldn’t load your invite link. Check your connection '
                      'and come back in a moment.',
                      textAlign: TextAlign.center,
                      style: AymaType.sans(size: 14, color: ac.fgMute),
                    )
                  : _link == null
                      ? const Padding(
                          padding: EdgeInsets.symmetric(vertical: 48),
                          child: Center(child: CircularProgressIndicator()),
                        )
                      : _body(ac),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(AymaTokens ac) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Know someone still looking?',
          textAlign: TextAlign.center,
          style: AymaType.serif(size: 22, color: ac.fg),
        ),
        const SizedBox(height: 8),
        Text(
          'Send them your link — Ayma gets to know them and finds their '
          'person too.',
          textAlign: TextAlign.center,
          style: AymaType.sans(size: 14, soft: true, color: ac.fgMute),
        ),
        const SizedBox(height: 28),
        Container(
          decoration: BoxDecoration(
            color: ac.bgElev,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: ac.lineSoft, width: 0.5),
          ),
          padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _link!,
                      style: AymaType.mono(size: 13, color: ac.fg),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Code: $_code',
                      style:
                          AymaType.sans(size: 12, soft: true, color: ac.fgMute),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Copy link',
                icon: Icon(Icons.copy_rounded, size: 18, color: ac.fgDim),
                onPressed: _copy,
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: _share,
          icon: const Icon(Icons.ios_share, size: 18),
          label: const Text('Share your link'),
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
          ),
        ),
      ],
    );
  }
}
