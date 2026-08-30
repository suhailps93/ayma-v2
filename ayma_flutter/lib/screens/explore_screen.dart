import 'dart:async';

import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../theme.dart';

/// Explore — the live filtered feed (§6.1, §6.4, §6.11 step 6). Text search is
/// parsed server-side; the hair-colour chips are exact dropdown filters.
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
      appBar: AppBar(title: const Text('Explore')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              controller: _searchController,
              onChanged: _onSearchChanged,
              onSubmitted: (_) => _load(),
              decoration: const InputDecoration(
                hintText: 'Search — e.g. “blondes in tech”',
                prefixIcon: Icon(Icons.search),
                isDense: true,
              ),
            ),
          ),
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
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
                                    size: 15, soft: true, color: ac.fgMute)),
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.all(16),
                            itemCount: _cards.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 12),
                            itemBuilder: (context, i) => _Card(
                              card: _cards[i],
                              api: _api,
                              onGone: () => setState(
                                  () => _cards = List.of(_cards)..removeAt(i)),
                            ),
                          ),
          ),
        ],
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
    final subtitle = [
      if (card.age != null) '${card.age}',
      if (card.location.isNotEmpty) card.location,
    ].join(' · ');
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ac.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: ac.lineSoft, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(card.name.isEmpty ? 'Someone' : card.name,
                        style: AymaType.serif(size: 18, color: ac.fg)),
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(subtitle,
                          style: AymaType.sans(size: 13, color: ac.fgMute)),
                    ],
                  ],
                ),
              ),
              if (card.score != null)
                Text('${(card.score! * 100).round()}%',
                    style: AymaType.mono(size: 12, color: ac.accent))
              else
                Text('check compatibility',
                    style: AymaType.sans(size: 12, color: ac.fgMute)),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _pass,
                  child: const Text('Pass'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: () => _like(context),
                  child: const Text('Like'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
