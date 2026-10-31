import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../services/api_client.dart';
import '../../theme.dart';
import 'practice_models.dart';

/// Practice Date debrief (hackathon deliverable B) — shown after the user ends a
/// practice conversation. Three honest, specific sections: what worked, lines
/// they could actually send next, and what to avoid. Generated from the
/// practice transcript; contains no private data about the match.
class PracticeDebriefScreen extends StatefulWidget {
  const PracticeDebriefScreen({
    super.key,
    required this.sessionId,
    this.name = '',
    this.api,
  });

  static const path = '/practice/:uid/debrief';

  final String sessionId;
  final String name;
  final ApiClient? api;

  @override
  State<PracticeDebriefScreen> createState() => _PracticeDebriefScreenState();
}

class _PracticeDebriefScreenState extends State<PracticeDebriefScreen> {
  late final ApiClient _api = widget.api ?? ApiClient();
  bool _loading = true;
  String? _error;
  PracticeDebrief? _debrief;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (widget.sessionId.isEmpty) {
      setState(() {
        _loading = false;
        _error = 'This practice session has expired.';
      });
      return;
    }
    try {
      final d = await _api.practiceDebrief(widget.sessionId);
      if (!mounted) return;
      setState(() {
        _debrief = d;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = "Couldn't build your debrief. Please try again.";
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      backgroundColor: ac.bg,
      appBar: AppBar(
        backgroundColor: ac.bg,
        foregroundColor: ac.fg,
        elevation: 0,
        title: Text(
          'Your debrief',
          style: AymaType.sans(size: 17, weight: FontWeight.w600, color: ac.fg),
        ),
      ),
      body: SafeArea(child: _body(ac)),
    );
  }

  Widget _body(AymaTokens ac) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _error!,
            key: const Key('debriefError'),
            textAlign: TextAlign.center,
            style: AymaType.sans(size: 15, color: ac.fgDim),
          ),
        ),
      );
    }
    final d = _debrief!;
    return ListView(
      key: const Key('practiceDebrief'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Text(
          widget.name.isEmpty
              ? 'Here is how that practice went.'
              : 'Here is how your practice with ${widget.name} went.',
          style: AymaType.serif(size: 24, color: ac.fg),
        ),
        const SizedBox(height: 20),
        _Section(
          key: const Key('debriefWhatWorked'),
          title: 'What worked',
          icon: Icons.check_circle_outline,
          tint: ac.success,
          items: d.whatWorked,
          emptyLabel: 'Nothing stood out yet — keep practising.',
        ),
        _Section(
          key: const Key('debriefNextLines'),
          title: 'Try saying next',
          icon: Icons.chat_bubble_outline,
          tint: ac.accent,
          items: d.suggestedNextLines,
          emptyLabel: 'No suggestions this time.',
          quoted: true,
        ),
        _Section(
          key: const Key('debriefAvoid'),
          title: 'What to avoid',
          icon: Icons.warning_amber_rounded,
          tint: ac.warning,
          items: d.avoid,
          emptyLabel: 'Nothing to flag — nicely done.',
        ),
        const SizedBox(height: 12),
        Center(
          child: FilledButton(
            key: const Key('debriefDoneButton'),
            onPressed: () => context.pop(),
            child: const Text('Done'),
          ),
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    super.key,
    required this.title,
    required this.icon,
    required this.tint,
    required this.items,
    required this.emptyLabel,
    this.quoted = false,
  });

  final String title;
  final IconData icon;
  final Color tint;
  final List<String> items;
  final String emptyLabel;
  final bool quoted;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: tint),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: AymaType.sans(
                      size: 16, weight: FontWeight.w600, color: ac.fg),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (items.isEmpty)
            Text(emptyLabel,
                style: AymaType.sans(size: 14, color: ac.fgMute, height: 1.4))
          else
            ...items.map(
              (t) => Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 8),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: ac.bgCard,
                  borderRadius: BorderRadius.circular(14),
                  border: Border(left: BorderSide(color: tint, width: 3)),
                ),
                child: Text(
                  quoted ? '“$t”' : t,
                  style: AymaType.sans(size: 14.5, color: ac.fg, height: 1.4)
                      .copyWith(
                    fontStyle: quoted ? FontStyle.italic : FontStyle.normal,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
