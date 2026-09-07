import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/api_client.dart';
import '../theme.dart';
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

  @override
  void initState() {
    super.initState();
    _future = _api.publicProfile(widget.uid);
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
      if (res.usageCapped) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Out of credits — reload on your profile.'),
        ));
      } else if (res.ok && res.score != null) {
        setState(() => _score = res.score);
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: FutureBuilder<PublicProfile>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError || !snap.hasData) {
            return _Message(
              text: "Couldn't load this profile.",
              onRetry: () => setState(
                  () => _future = _api.publicProfile(widget.uid)),
            );
          }
          return _Body(
            p: snap.data!,
            liked: _liked,
            liking: _liking,
            scoring: _scoring,
            localScore: _score,
            onLike: _like,
            onRunMatch: _runMatch,
          );
        },
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
              if (score != null) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: ac.accentFaint,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text('${(score * 100).round()}% match',
                      style: AymaType.mono(size: 12, color: ac.accent)),
                ),
              ],
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

  @override
  Widget build(BuildContext context) {
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
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: scoring ? null : () => onRunMatch(p),
            icon: scoring
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.insights_rounded, size: 18),
            label: Text(hasScore ? 'Recalculate match' : 'Run match'),
          ),
        ),
      ],
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
                  itemBuilder: (_, i) => Image.network(
                    widget.photos[i],
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => fallback,
                    loadingBuilder: (c, w, p) => p == null ? w : fallback,
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
