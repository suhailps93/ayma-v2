import 'dart:async';

import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../theme.dart';
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
  String _hairFilter = '';

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
      final cards = await _api.explore(
        q: _searchController.text.trim(),
        filters: {if (_hairFilter.isNotEmpty) 'hair_color': _hairFilter},
      );
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
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  for (final h in const ['blonde', 'brown', 'black', 'red'])
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: FilterChip(
                        label: Text(h),
                        selected: _hairFilter == h,
                        onSelected: (on) {
                          setState(() => _hairFilter = on ? h : '');
                          _load();
                        },
                      ),
                    ),
                ],
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
                                childAspectRatio: 0.62,
                              ),
                              itemCount: _cards.length,
                              itemBuilder: (context, i) => FadeSlideIn(
                                delay: staggerDelay(i),
                                child: _Card(
                                  card: _cards[i],
                                  api: _api,
                                  onGone: () => setState(() =>
                                      _cards = List.of(_cards)..removeAt(i)),
                                ),
                              ),
                            ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.card, required this.api, required this.onGone});
  final ExploreCard card;
  final ApiClient api;
  final VoidCallback onGone;

  Future<void> _like(BuildContext context) async {
    try {
      final mutual = await api.likeProfile(card.uid);
      onGone();
      if (context.mounted && mutual) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("It's mutual! Say hi.")),
        );
      }
    } catch (_) {}
  }

  Future<void> _pass() async {
    try {
      await api.passProfile(card.uid);
      onGone();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: ac.bgElev,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: ac.lineSoft, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: _Photo(seed: card.uid, path: card.photoPath),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(11, 10, 11, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
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
                const SizedBox(height: 4),
                if (card.location.isNotEmpty)
                  Text(
                    card.location.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AymaType.mono(size: 8, color: ac.fgMute)
                        .copyWith(letterSpacing: 1.2),
                  ),
                const SizedBox(height: 8),
                if (card.isSelf)
                  Text('This is you',
                      style: AymaType.sans(size: 11, color: ac.fgMute))
                else ...[
                  Text(
                    card.score != null
                        ? '${(card.score! * 100).round()}% match'
                        : 'check compatibility',
                    style: card.score != null
                        ? AymaType.mono(size: 10, color: ac.accent)
                        : AymaType.sans(size: 11, color: ac.fgMute),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _pass,
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(34),
                            padding: EdgeInsets.zero,
                            textStyle: AymaType.sans(
                                size: 12, weight: FontWeight.w500),
                          ),
                          child: const Text('Pass'),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: FilledButton(
                          onPressed: () => _like(context),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(34),
                            padding: EdgeInsets.zero,
                            textStyle: AymaType.sans(
                                size: 12, weight: FontWeight.w600),
                          ),
                          child: const Text('Like'),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
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
        return Image.network(
          url,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => fallback,
          loadingBuilder: (c, w, p) => p == null ? w : fallback,
        );
      },
    );
  }
}
