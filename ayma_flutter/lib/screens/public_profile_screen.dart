import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../screens/main_shell_screen.dart';
import '../services/api_client.dart';
import '../services/app_context.dart';
import '../services/chat_inbox.dart';
import '../services/match_activity.dart';
import '../theme.dart';
import '../widgets/ayma_photo.dart';
import '../widgets/markdown_text.dart';

/// Another user's profile — opened from an Explore card. Shows their photos,
/// the public wiki narrative, and the actions: Chat, Like, Run match.
class PublicProfileScreen extends StatefulWidget {
  const PublicProfileScreen({super.key, required this.uid, this.api});

  static const path = '/profile/user/:uid';

  final String uid;
  final ApiClient? api;

  @override
  State<PublicProfileScreen> createState() => _PublicProfileScreenState();
}

class _PublicProfileScreenState extends State<PublicProfileScreen> {
  late final ApiClient _api = widget.api ?? ApiClient();
  late Future<PublicProfile> _future;

  Set<String> _lastActive = const {};

  @override
  void initState() {
    super.initState();
    AppContext.instance.set(screen: 'profile', subjectUid: widget.uid);
    MatchActivity.instance.recalculating.addListener(_onRecalcChanged);
    _lastActive = MatchActivity.instance.recalculating.value;
    _future = _api.publicProfile(widget.uid);
    _future.then((p) {
      if (mounted) {
        AppContext.instance.set(
          screen: 'profile',
          subjectUid: widget.uid,
          subjectName: p.name,
        );
      }
    }).catchError((_) {});
  }

  @override
  void dispose() {
    MatchActivity.instance.recalculating.removeListener(_onRecalcChanged);
    super.dispose();
  }

  /// A recalculation just finished somewhere — pull the profile again so the
  /// chip shows the new score.
  void _onRecalcChanged() {
    if (!mounted) return;
    final now = MatchActivity.instance.recalculating.value;
    final finished = _lastActive.difference(now).isNotEmpty;
    _lastActive = now;
    if (finished) {
      setState(() => _future = _api.publicProfile(widget.uid));
    }
  }

  bool _liked = false;
  bool _liking = false;
  bool _scoring = false;
  double? _score;

  Future<void> _like(PublicProfile p) async {
    if (_liking || _liked || p.liked) return;
    setState(() => _liking = true);
    try {
      final mutual = await _api.likeProfile(p.uid);
      if (!mounted) return;
      setState(() => _liked = true);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(mutual ? "It's mutual — say hi!" : 'Liked.'),
      ));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't send that like.")),
        );
      }
    } finally {
      if (mounted) setState(() => _liking = false);
    }
  }

  Future<void> _runMatch(PublicProfile p) async {
    if (_scoring) return;
    setState(() => _scoring = true);
    try {
      final res = await _api.checkCompatibility(p.uid);
      if (!mounted) return;
      final id = res.matchId ?? p.threadId;
      if (res.usageCapped) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Out of credits — reload on your profile.'),
        ));
      } else if (res.ok && res.score != null) {
        setState(() => _score = res.score);
        if (id != null && mounted) context.push('/match/$id');
      } else if (res.ok && res.queued && id != null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              "Running the match — I'll open it when it's ready. "
              "You can leave this screen."),
        ));
        await _awaitMatchReport(id);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't calculate that match.")),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't calculate that match.")),
        );
      }
    } finally {
      if (mounted) setState(() => _scoring = false);
    }
  }

  /// Poll `GET /match/{id}` while the score computes server-side; when it's
  /// there, update the chip and open the report. The push covers app-closed.
  Future<void> _awaitMatchReport(String matchId) async {
    for (var i = 0; i < 20 && mounted; i++) {
      await Future<void>.delayed(const Duration(seconds: 4));
      if (!mounted) return;
      try {
        final report = await _api.matchReport(matchId);
        if (report != null && report.score != null) {
          if (mounted) {
            setState(() => _score = report.score);
            context.push('/match/$matchId');
          }
          return;
        }
      } catch (_) {/* keep polling */}
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: FutureBuilder<PublicProfile>(
        future: _future,
        builder: (context, snap) {
          final p = snap.data;
          final title = p == null
              ? ''
              : p.isSelf
                  ? 'My public profile'
                  : (p.name.isEmpty ? 'Profile' : p.name);
          Widget content;
          if (snap.connectionState != ConnectionState.done) {
            content = const Center(child: CircularProgressIndicator());
          } else if (snap.hasError || p == null) {
            content = _Message(
              text: "Couldn't load this profile.",
              onRetry: () => setState(
                  () => _future = _api.publicProfile(widget.uid)),
            );
          } else {
            content = _Body(
              p: p,
              liked: _liked,
              liking: _liking,
              scoring: _scoring,
              localScore: _score,
              onLike: _like,
              onRunMatch: _runMatch,
            );
          }
          final photo = (p?.photos.isNotEmpty ?? false) ? p!.photos.first : '';
          return Column(
            children: [
              _TitleBar(
                title: title,
                actionLabel: p == null
                    ? null
                    : (p.isSelf ? 'Edit with Ayma' : 'Ask Ayma'),
                actionIcon:
                    (p?.isSelf ?? false) ? Icons.edit_note : Icons.auto_awesome,
                onAction: p == null
                    ? null
                    : () {
                        ChatInbox.instance.push(ChatKickoff.talkAbout(
                          targetUid: p.uid,
                          label: p.isSelf
                              ? 'my profile'
                              : (p.name.isEmpty ? 'them' : p.name),
                          shareKind: 'profile',
                          photoUrl: photo,
                          editSelf: p.isSelf,
                        ));
                        context.go(MainShellScreen.path);
                      },
              ),
              Expanded(child: content),
            ],
          );
        },
      ),
    );
  }
}

class _TitleBar extends StatelessWidget {
  const _TitleBar({
    required this.title,
    this.actionLabel,
    this.actionIcon = Icons.auto_awesome,
    this.onAction,
  });

  final String title;

  /// The Ayma action — "Ask Ayma" on someone else's profile, "Edit with Ayma"
  /// on your own. Hidden until the profile has loaded.
  final String? actionLabel;
  final IconData actionIcon;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: SizedBox(
        height: 52,
        child: Row(
          children: [
            const BackButton(),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AymaType.serif(size: 18, color: context.ac.fg),
              ),
            ),
            if (actionLabel != null && onAction != null)
              TextButton.icon(
                onPressed: onAction,
                icon: Icon(actionIcon, size: 16),
                label: Text(actionLabel!),
              ),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.p,
    required this.liked,
    required this.liking,
    required this.scoring,
    required this.localScore,
    required this.onLike,
    required this.onRunMatch,
  });

  final PublicProfile p;
  final bool liked;
  final bool liking;
  final bool scoring;
  final double? localScore;
  final void Function(PublicProfile) onLike;
  final void Function(PublicProfile) onRunMatch;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final score = localScore ?? p.score;
    final isLiked = liked || p.liked;

    return ListView(
      padding: const EdgeInsets.only(bottom: 40),
      children: [
        _Gallery(photos: p.photos, seed: p.uid),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Flexible(
                    child: Text(
                      p.name.isEmpty ? 'Someone' : p.name,
                      style: AymaType.serif(size: 28, color: ac.fg),
                    ),
                  ),
                  if (p.age != null)
                    Text('  ${p.age}',
                        style: AymaType.sans(size: 16, color: ac.fgMute)),
                ],
              ),
              if (p.location.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(p.location.toUpperCase(),
                    style: AymaType.mono(size: 10, color: ac.fgMute)
                        .copyWith(letterSpacing: 1.4)),
              ],
              if (p.threadId != null)
                ValueListenableBuilder<Set<String>>(
                  valueListenable: MatchActivity.instance.recalculating,
                  builder: (context, active, _) {
                    final busy = active.contains(p.threadId);
                    if (score == null && !busy) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: InkWell(
                        onTap: () => context.push('/match/${p.threadId}'),
                        borderRadius: BorderRadius.circular(999),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: ac.accentFaint,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (busy) ...[
                                SizedBox(
                                  width: 11,
                                  height: 11,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 1.6, color: ac.accent),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                    score == null
                                        ? 'Calculating match…'
                                        : 'Updating ${(score * 100).round()}%…',
                                    style: AymaType.mono(
                                        size: 12, color: ac.accent)),
                              ] else ...[
                                Text('${(score! * 100).round()}% match',
                                    style: AymaType.mono(
                                        size: 12, color: ac.accent)),
                                const SizedBox(width: 4),
                                Icon(Icons.chevron_right,
                                    size: 14, color: ac.accent),
                              ],
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              const SizedBox(height: 16),
              if (p.blocked)
                Text("You've blocked this person.",
                    style: AymaType.sans(size: 13, color: AymaColors.error))
              else if (!p.isSelf)
                _Actions(
                  p: p,
                  liked: isLiked,
                  liking: liking,
                  scoring: scoring,
                  hasScore: score != null,
                  onLike: onLike,
                  onRunMatch: onRunMatch,
                ),
              const SizedBox(height: 8),
              for (final s in p.sections) _Section(section: s),
              if (p.sections.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(
                    p.isSelf
                        ? 'Your public profile is still filling in.'
                        : "They haven't shared much publicly yet.",
                    style: AymaType.sans(
                        size: 13, soft: true, color: ac.fgMute),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({
    required this.p,
    required this.liked,
    required this.liking,
    required this.scoring,
    required this.hasScore,
    required this.onLike,
    required this.onRunMatch,
  });

  final PublicProfile p;
  final bool liked;
  final bool liking;
  final bool scoring;
  final bool hasScore;
  final void Function(PublicProfile) onLike;
  final void Function(PublicProfile) onRunMatch;

  // Rough credit costs, shown under the buttons so a tap is never a surprise.
  // Match scoring: CREDIT_COST_MATCH_SCORE (backend). Deep dive: same as the
  // "Search the web about me" skill — see skills_screen.dart.
  static const _matchCredits = 12;
  static const _deepDiveCredits = 15;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: p.threadId == null
                    ? null
                    : () => context.push('/dm/${p.threadId}'),
                icon: const Icon(Icons.chat_bubble_outline_rounded, size: 18),
                label: const Text('Chat'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: (liked || liking) ? null : () => onLike(p),
                icon: Icon(
                  liked
                      ? Icons.favorite_rounded
                      : Icons.favorite_border_rounded,
                  size: 18,
                ),
                label: Text(liked ? 'Liked' : 'Like'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                children: [
                  OutlinedButton.icon(
                    onPressed: scoring ? null : () => onRunMatch(p),
                    icon: scoring
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : Icon(
                            hasScore
                                ? Icons.assignment_outlined
                                : Icons.insights_rounded,
                            size: 18),
                    label: Text(hasScore ? 'View match report' : 'Run match'),
                  ),
                  // No credit line once it's scored — opening the saved report
                  // is free; recalculating lives inside the report.
                  if (!hasScore)
                    _CreditHint(credits: _matchCredits, color: ac.fgMute),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                children: [
                  if (p.deepDiveId.isNotEmpty)
                    OutlinedButton.icon(
                      onPressed: () => context.push(
                          '/deep-dive/${Uri.encodeComponent(p.deepDiveId)}'),
                      icon: const Icon(Icons.description_outlined, size: 18),
                      label: const Text('View research'),
                    )
                  else
                    OutlinedButton.icon(
                      onPressed: () {
                        ChatInbox.instance.push(ChatKickoff.deepDive(
                          targetUid: p.uid,
                          label: p.name.isEmpty ? 'them' : p.name,
                        ));
                        context.go(MainShellScreen.path);
                      },
                      icon: const Icon(Icons.travel_explore, size: 18),
                      label: const Text('Deep dive'),
                    ),
                  if (p.deepDiveId.isEmpty)
                    _CreditHint(credits: _deepDiveCredits, color: ac.fgMute),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _CreditHint extends StatelessWidget {
  const _CreditHint({required this.credits, required this.color});

  final int credits;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        '≈ $credits credits',
        style: AymaType.mono(size: 10, color: color).copyWith(letterSpacing: 0.5),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.section});

  final ProfileSection section;

  static const _labels = {
    'identity': 'Identity',
    'career': 'Work & study',
    'interests': 'Interests',
    'personality': 'Personality',
    'values': 'Values',
    'goals': 'Looking ahead',
    'lifestyle': 'Lifestyle',
    'family': 'Family',
    'relationships': 'Relationships',
    'misc': 'More',
  };

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final heading = section.title.isNotEmpty
        ? section.title
        : (_labels[section.pageType] ?? 'More');
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(heading.toUpperCase(),
              style: AymaType.mono(size: 10, color: ac.fgMute)
                  .copyWith(letterSpacing: 1.4)),
          const SizedBox(height: 6),
          MarkdownText(section.body,
              style: AymaType.sans(size: 14, color: ac.fg, height: 1.5),
              linkColor: ac.accent),
        ],
      ),
    );
  }
}

class _Gallery extends StatefulWidget {
  const _Gallery({required this.photos, required this.seed});

  final List<String> photos;
  final String seed;

  @override
  State<_Gallery> createState() => _GalleryState();
}

class _GalleryState extends State<_Gallery> {
  final _controller = PageController();
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final h1 = (widget.seed.hashCode.abs() % 360).toDouble();
    final fallback = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            HSLColor.fromAHSL(1, h1, 0.28, 0.30).toColor(),
            HSLColor.fromAHSL(1, (h1 + 40) % 360, 0.22, 0.18).toColor(),
          ],
        ),
      ),
    );

    return AspectRatio(
      aspectRatio: 1,
      child: widget.photos.isEmpty
          ? fallback
          : Stack(
              fit: StackFit.expand,
              children: [
                PageView.builder(
                  controller: _controller,
                  onPageChanged: (i) => setState(() => _page = i),
                  itemCount: widget.photos.length,
                  itemBuilder: (_, i) => AymaPhoto(
                    url: widget.photos[i],
                    displayWidth: 900,
                    error: fallback,
                  ),
                ),
                if (widget.photos.length > 1)
                  Positioned(
                    bottom: 10,
                    left: 0,
                    right: 0,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (var i = 0; i < widget.photos.length; i++)
                          Container(
                            width: 6,
                            height: 6,
                            margin: const EdgeInsets.symmetric(horizontal: 3),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: i == _page
                                  ? Colors.white
                                  : Colors.white38,
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text, required this.onRetry});

  final String text;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text, style: AymaType.sans(size: 14, color: context.ac.fgMute)),
          const SizedBox(height: 10),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}
