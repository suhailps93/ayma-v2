import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../theme.dart';

/// "Is this you?" review queue for reverse-image-search hits (§ web photo
/// search). Reverse-image search runs automatically — once after onboarding
/// finishes (`POST /onboarding/complete`) and again after any later "add
/// more photos" batch (`POST /web-search/photos/rescan`, wired from
/// [PhotoManagementScreen]) — and stages whatever it finds as pending
/// candidates rather than ever writing to the user's report unasked. This
/// screen is where the user actually confirms or rejects each one; nothing
/// here is written into the persistent "about me" web-search report until
/// they do.
///
/// Entry point: a banner on [PhotoManagementScreen] (see
/// `_CandidatesBanner` there) shown whenever there's at least one pending
/// candidate. That screen was chosen as the entry point — over, say, the
/// Skills screen or the web-search report screen — because it's the natural
/// "photos" surface the user is already on right after adding photos (the
/// moment a rescan is most likely to have just queued new candidates), and
/// because this task's scope explicitly excludes editing the Skills screen
/// and the web-search report screen (a parallel agent owns both — see this
/// task's final report for the hook it should consider adding on the report
/// screen once it lands).
class PhotoCandidatesScreen extends StatefulWidget {
  const PhotoCandidatesScreen({super.key, this.api});

  static const path = '/web-search/photo-candidates';

  final ApiClient? api;

  @override
  State<PhotoCandidatesScreen> createState() => _PhotoCandidatesScreenState();
}

class _PhotoCandidatesScreenState extends State<PhotoCandidatesScreen> {
  late final ApiClient _api = widget.api ?? ApiClient();

  List<PhotoCandidate>? _candidates;
  String? _error;
  final Set<String> _busyIds = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final c = await _api.webSearchPhotoCandidates();
      if (mounted) setState(() { _candidates = c; _error = null; });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _decide(PhotoCandidate c, {required bool confirm}) async {
    if (_busyIds.contains(c.candidateId)) return;
    setState(() => _busyIds.add(c.candidateId));
    try {
      if (confirm) {
        await _api.confirmPhotoCandidate(c.candidateId);
      } else {
        await _api.rejectPhotoCandidate(c.candidateId);
      }
      if (!mounted) return;
      setState(() {
        _candidates = [..._candidates!]
          ..removeWhere((x) => x.candidateId == c.candidateId);
        _busyIds.remove(c.candidateId);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _busyIds.remove(c.candidateId));
      _snack("Couldn't save that — try again ($e).");
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final candidates = _candidates;
    return Scaffold(
      appBar: AppBar(title: const Text('Photos found online')),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text("Couldn't load ($_error).",
                    style: AymaType.sans(size: 14, color: ac.error)),
              ),
            )
          : candidates == null
              ? const Center(child: CircularProgressIndicator())
              : candidates.isEmpty
                  ? _EmptyState(ac: ac)
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(4, 8, 4, 16),
                          child: Text(
                            "Ayma found these while searching the web for "
                            'you. Only confirm the ones that are really you '
                            "— confirming adds it to what Ayma knows about "
                            'you; rejecting just discards it.',
                            style: AymaType.sans(
                                size: 13, soft: true, color: ac.fgMute),
                          ),
                        ),
                        for (final c in candidates)
                          _CandidateCard(
                            candidate: c,
                            busy: _busyIds.contains(c.candidateId),
                            onConfirm: () => _decide(c, confirm: true),
                            onReject: () => _decide(c, confirm: false),
                          ),
                      ],
                    ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.ac});

  final AymaTokens ac;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.image_search, size: 40, color: ac.fgMute),
            const SizedBox(height: 16),
            Text(
              "Nothing left to review.",
              textAlign: TextAlign.center,
              style: AymaType.sans(size: 15, soft: true, color: ac.fgMute),
            ),
          ],
        ),
      ),
    );
  }
}

class _CandidateCard extends StatelessWidget {
  const _CandidateCard({
    required this.candidate,
    required this.busy,
    required this.onConfirm,
    required this.onReject,
  });

  final PhotoCandidate candidate;
  final bool busy;
  final VoidCallback onConfirm;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final domain = candidate.sourceDomain;
    final title = candidate.sourceTitle;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Material(
        color: ac.bgElev,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 4 / 3,
              child: Image.network(
                candidate.imageUrl,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  color: ac.bgCard,
                  alignment: Alignment.center,
                  child: Icon(Icons.broken_image_outlined,
                      color: ac.fgMute, size: 28),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (title.isNotEmpty)
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AymaType.sans(
                          size: 13, weight: FontWeight.w600, color: ac.fg),
                    ),
                  if (domain.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(
                        domain,
                        style: AymaType.sans(
                            size: 11, soft: true, color: ac.fgMute),
                      ),
                    ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: busy ? null : onReject,
                          child: const Text('Not me'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton(
                          onPressed: busy ? null : onConfirm,
                          child: busy
                              ? const SizedBox(
                                  height: 16,
                                  width: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2),
                                )
                              : const Text('This is me'),
                        ),
                      ),
                    ],
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
