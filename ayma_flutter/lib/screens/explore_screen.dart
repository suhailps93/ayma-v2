import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/api_client.dart';
import '../services/pair_key.dart';
import '../theme.dart';
import '../widgets/ayma_photo.dart';
import '../widgets/ayma_primitives.dart';
import '../widgets/notification_bell.dart';
import '../widgets/staggered.dart';

/// Explore — the live filtered feed (§6.1, §6.4, §6.11 step 6). Text search is
/// parsed server-side; the hair-colour chips are exact dropdown filters.
///
/// Laid out as the design's two-column card grid: a photo (or a seeded gradient
/// when there's none), a serif name, and the location in mono.
class ExploreScreen extends StatefulWidget {
  const ExploreScreen({super.key, this.apiClient});

  static const path = '/explore';

  final ApiClient? apiClient;

  @override
  State<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends State<ExploreScreen> {
  late final ApiClient _api = widget.apiClient ?? ApiClient();
  final _searchController = TextEditingController();
  Timer? _debounce;

  bool _loading = true;
  String? _error;
  List<ExploreCard> _cards = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final cards = await _api.explore(q: _searchController.text.trim());
      if (!mounted) return;
      setState(() {
        _cards = cards;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load Explore ($e).';
        _loading = false;
      });
    }
  }

  void _onSearchChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), _load);
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            const AymaScreenHeader(
              eyebrow: 'Search · in your words',
              title: 'Explore',
              action: NotificationBellButton(),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: TextField(
                controller: _searchController,
                onChanged: _onSearchChanged,
                onSubmitted: (_) => _load(),
                decoration: const InputDecoration(
                  hintText: 'Describe who you’re looking for…',
                  prefixIcon: Icon(Icons.search),
                  isDense: true,
                ),
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(_error!,
                                style: AymaType.sans(
                                    size: 14, color: AymaColors.error)),
                          ),
                        )
                      : _cards.isEmpty
                          ? Center(
                              child: Text('No one matches that yet.',
                                  style: AymaType.sans(
                                      size: 15,
                                      soft: true,
                                      color: ac.fgMute)),
                            )
                          : GridView.builder(
                              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                              gridDelegate:
                                  const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 2,
                                mainAxisSpacing: 12,
                                crossAxisSpacing: 12,
                                childAspectRatio: 0.66,
                              ),
                              itemCount: _cards.length,
                              itemBuilder: (context, i) => FadeSlideIn(
                                delay: staggerDelay(i),
                                child: _Card(card: _cards[i], api: _api),
                              ),
                            ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Card extends StatefulWidget {
  const _Card({required this.card, required this.api});

  final ExploreCard card;
  final ApiClient api;

  @override
  State<_Card> createState() => _CardState();
}

class _CardState extends State<_Card> {
  ExploreCard get card => widget.card;

  bool _liked = false;
  bool _liking = false;
  bool _scoring = false;
  double? _score;

  @override
  void initState() {
    super.initState();
    _score = card.score;
  }

  Future<void> _like() async {
    if (_liking || _liked) return;
    setState(() => _liking = true);
    try {
      final mutual = await widget.api.likeProfile(card.uid);
      if (!mounted) return;
      setState(() => _liked = true);
      if (mutual) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("It's mutual — say hi!")),
        );
      }
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

  void _message() {
    final me = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (me.isEmpty) return;
    context.push('/dm/${sortedPairKey(me, card.uid)}');
  }

  Future<void> _runMatch() async {
    if (_scoring) return;
    setState(() => _scoring = true);
    try {
      final res = await widget.api.checkCompatibility(card.uid);
      if (!mounted) return;
      if (res.usageCapped) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Out of credits — reload on your profile.')),
        );
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
    final ac = context.ac;
    final score = _score;

    return GestureDetector(
      onTap: () => context.push('/profile/user/${card.uid}'),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: ac.bgElev,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: ac.lineSoft, width: 0.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _Photo(seed: card.uid, path: card.photoPath),
                  if (!card.isSelf)
                    Positioned(
                      right: 6,
                      bottom: 6,
                      child: _ActionRail(
                        liked: _liked,
                        liking: _liking,
                        scoring: _scoring,
                        score: score,
                        onLike: _like,
                        onMessage: _message,
                        onMatch: _runMatch,
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(11, 10, 11, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Flexible(
                        child: Text(
                          card.name.isEmpty ? 'Someone' : card.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AymaType.serif(size: 18, color: ac.fg),
                        ),
                      ),
                      if (card.age != null)
                        Text(' · ${card.age}',
                            style: AymaType.sans(size: 11, color: ac.fgMute)),
                    ],
                  ),
                  if (card.location.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      card.location.toUpperCase(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AymaType.mono(size: 8, color: ac.fgMute)
                          .copyWith(letterSpacing: 1.2),
                    ),
                  ],
                  const SizedBox(height: 6),
                  Text(
                    card.isSelf
                        ? 'This is you'
                        : score != null
                            ? '${(score * 100).round()}% match'
                            : 'View profile',
                    style: card.isSelf
                        ? AymaType.sans(size: 11, color: ac.fgMute)
                        : score != null
                            ? AymaType.mono(size: 10, color: ac.accent)
                            : AymaType.sans(size: 11, color: ac.fgMute),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Instagram-Reels-style vertical action column over the photo's bottom-right.
class _ActionRail extends StatelessWidget {
  const _ActionRail({
    required this.liked,
    required this.liking,
    required this.scoring,
    required this.score,
    required this.onLike,
    required this.onMessage,
    required this.onMatch,
  });

  final bool liked;
  final bool liking;
  final bool scoring;
  final double? score;
  final VoidCallback onLike;
  final VoidCallback onMessage;
  final VoidCallback onMatch;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _RailButton(
          icon: liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
          label: liked ? 'Liked' : 'Like',
          active: liked,
          busy: liking,
          onTap: onLike,
        ),
        const SizedBox(height: 8),
        _RailButton(
          icon: Icons.chat_bubble_outline_rounded,
          label: 'Message',
          onTap: onMessage,
        ),
        const SizedBox(height: 8),
        _RailButton(
          icon: Icons.insights_rounded,
          label: score != null ? '${(score! * 100).round()}%' : 'Match',
          active: score != null,
          busy: scoring,
          onTap: onMatch,
        ),
      ],
    );
  }
}

class _RailButton extends StatelessWidget {
  const _RailButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return GestureDetector(
      onTap: busy ? null : onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.black.withValues(alpha: 0.45),
            ),
            alignment: Alignment.center,
            child: busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : Icon(icon,
                    size: 20,
                    color: active ? ac.accent : Colors.white),
          ),
          const SizedBox(height: 2),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              label,
              style: AymaType.mono(size: 8, color: Colors.white)
                  .copyWith(letterSpacing: 0.5),
            ),
          ),
        ],
      ),
    );
  }
}

/// A profile photo, or — when there's no path or it can't be resolved — a
/// seeded two-tone gradient placeholder (the design's `Photo` fallback).
class _Photo extends StatelessWidget {
  const _Photo({required this.seed, this.path});

  final String seed;
  final String? path;

  Future<String?> _resolve() async {
    if (path == null || path!.isEmpty) return null;
    try {
      return await FirebaseStorage.instance.ref(path).getDownloadURL();
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final h1 = (seed.hashCode.abs() % 360).toDouble();
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
    if (path == null || path!.isEmpty) return fallback;
    return FutureBuilder<String?>(
      future: _resolve(),
      builder: (context, snap) {
        final url = snap.data;
        if (url == null) return fallback;
        // Explore is list-heavy — decode/cache these small and hard.
        return AymaPhoto(url: url, displayWidth: 260, error: fallback);
      },
    );
  }
}
