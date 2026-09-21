import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../screens/main_shell_screen.dart';
import '../services/api_client.dart';
import '../services/app_context.dart';
import '../services/chat_inbox.dart';
import '../services/match_activity.dart';
import '../theme.dart';
import '../widgets/ask_ayma_action.dart';
import '../widgets/ayma_photo.dart';
import '../widgets/markdown_text.dart';
import '../widgets/out_of_credits.dart';

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

class _PublicProfileScreenState extends State<PublicProfileScreen>
    with ScreenContextReasserter<PublicProfileScreen> {
  late final ApiClient _api = widget.api ?? ApiClient();
  late Future<PublicProfile> _future;

  Set<String> _lastActive = const {};
  String _subjectName = '';

  @override
  void initState() {
    super.initState();
    reassertScreenContext();
    MatchActivity.instance.recalculating.addListener(_onRecalcChanged);
    _lastActive = MatchActivity.instance.recalculating.value;
    _future = _api.publicProfile(widget.uid);
    _future.then((p) {
      if (mounted) {
        _subjectName = p.name;
        reassertScreenContext();
      }
    }).catchError((_) {});
  }

  @override
  void reassertScreenContext() => AppContext.instance.set(
        screen: 'profile',
        subjectUid: widget.uid,
        subjectName: _subjectName,
      );

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

  bool _liking = false;
  bool _scoring = false;
  double? _score;

  /// In-session like state — null means "use `p.liked` from the server".
  bool? _likedOverride;

  /// True when the like we made this session came back reciprocal; gates the
  /// "you'll drop out of each other's matches" confirm on unlike.
  bool _mutualLike = false;

  bool _isLiked(PublicProfile p) => _likedOverride ?? p.liked;

  Future<void> _like(PublicProfile p) async {
    if (_liking || _isLiked(p)) return;
    setState(() => _liking = true);
    try {
      final mutual = await _api.likeProfile(p.uid);
      if (!mounted) return;
      setState(() {
        _likedOverride = true;
        _mutualLike = mutual;
      });
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

  Future<void> _unlike(PublicProfile p) async {
    if (_liking || !_isLiked(p)) return;
    if (_mutualLike) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Remove your like?'),
          content:
              const Text("You'll drop out of each other's matches."),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Keep')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Remove')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    setState(() => _liking = true);
    try {
      await _api.unlikeProfile(p.uid);
      if (!mounted) return;
      setState(() {
        _likedOverride = false;
        _mutualLike = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Removed your like.')),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't remove that like.")),
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
        showOutOfCreditsSnack(context);
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
              liked: _isLiked(p),
              liking: _liking,
              scoring: _scoring,
              localScore: _score,
              onLike: _like,
              onUnlike: _unlike,
              onRunMatch: _runMatch,
            );
          }
          final photo = (p?.photos.isNotEmpty ?? false) ? p!.photos.first : '';
          return Column(
            children: [
              _TitleBar(
                title: title,
                action: p == null
                    ? null
                    : AskAymaAction(
                        label: p.isSelf ? 'Edit with Ayma' : 'Ask Ayma',
                        onPressed: () {
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
  const _TitleBar({required this.title, this.action});

  final String title;

  /// The Ayma action — "Ask Ayma" on someone else's profile, "Edit with Ayma"
  /// on your own (an [AskAymaAction]). Hidden until the profile has loaded.
  final Widget? action;

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
            if (action != null) action!,
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
    required this.onUnlike,
    required this.onRunMatch,
  });

  final PublicProfile p;

  /// Resolved like state (in-session override or the server's `p.liked`).
  final bool liked;
  final bool liking;
  final bool scoring;
  final double? localScore;
  final void Function(PublicProfile) onLike;
  final void Function(PublicProfile) onUnlike;
  final void Function(PublicProfile) onRunMatch;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final score = localScore ?? p.score;

    return ListView(
      padding: const EdgeInsets.only(bottom: 40),
      children: [
        Stack(
          children: [
            _Gallery(photos: p.photos, seed: p.uid),
            // TikTok-style action rail, floating on the photo itself rather
            // than as a row of buttons below it (founder reference: liked /
            // already messaged / web search run / match scored -> solid
            // app-color circle; not done -> white circle). Founder ask:
            // restyle as genuine floating buttons on the same vertical
            // column as the app-wide Ayma orb (`GlobalAymaLauncher`), not
            // wherever they happened to land. That orb sits at `right: 16`
            // in a 48+8+8 tap box, so its own painted center is 48px in from
            // the screen edge; `_RailButton._width` below matches that same
            // 64px box so a `right: 16` rail — this photo is full-bleed,
            // same width as the orb's screen — lines every circle up on
            // that exact centerline.
            if (!p.blocked && !p.isSelf)
              Positioned(
                right: 16,
                top: 0,
                bottom: 0,
                child: Center(
                  child: _Actions(
                    p: p,
                    liked: liked,
                    liking: liking,
                    scoring: scoring,
                    score: score,
                    onLike: onLike,
                    onUnlike: onUnlike,
                    onRunMatch: onRunMatch,
                  ),
                ),
              ),
          ],
        ),
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
              if (p.blocked) ...[
                const SizedBox(height: 16),
                Text("You've blocked this person.",
                    style: AymaType.sans(size: 13, color: AymaColors.error)),
              ],
              const SizedBox(height: 8),
              if (p.isSelf && p.physicalAttributes.isNotEmpty)
                _PhysicalSection(attributes: p.physicalAttributes),
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

/// One profile-action rail button — a floating circular icon over the photo
/// with a short caption underneath, colored by whether that action has
/// already happened, not by button type. Founder spec: liked / already
/// messaged / web search already run / match already scored -> solid
/// app-color circle; the not-yet-done state of the same action -> white
/// circle with a black icon. `ac.bg`/`ac.fg` rather than literal white/black
/// so this still holds under dark theme; the caption itself is always white
/// with a shadow since it sits over an arbitrary photo, not the page
/// background.
///
/// Restyled (founder ask) to read as genuinely floating and detached from
/// the photo — like the app-wide Ayma-orb launcher button
/// (`GlobalAymaLauncher`), not flush-embedded against the image — and to
/// share that same launcher's horizontal column: a fixed [_width] box (equal
/// to the orb's own 48px circle + 8px tap padding on each side) so every
/// button's circle centers on the identical vertical line regardless of how
/// wide its own caption is, and `_Actions`'s `Positioned(right: 16)` matches
/// the orb's own right inset exactly.
class _RailButton extends StatelessWidget {
  const _RailButton({
    required this.icon,
    required this.label,
    required this.active,
    required this.onPressed,
    this.caption,
  });

  final Widget icon;
  final String label;
  final bool active;
  final VoidCallback? onPressed;

  /// A small second line under the label — only ever a credit-cost notice
  /// for a not-yet-done action, so a tap is never a surprise (§ this app's
  /// standing credit-transparency convention).
  final String? caption;

  /// Orb tap box width (48px circle + 8px padding each side) — see class doc.
  static const _width = 64.0;

  static const _labelShadows = [
    Shadow(color: Colors.black54, blurRadius: 6),
    Shadow(color: Colors.black45, blurRadius: 2),
  ];

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final bg = active ? ac.accent : ac.bg;
    final fg = active ? ac.onAccent : ac.fg;
    // One tap target for the whole item — circle *and* caption — not just
    // the circle: the label sits below it, outside the circle's own bounds,
    // so a tap there must still register. Fixed-width so every button's
    // circle centers on the same line as the Ayma orb regardless of caption
    // width (see class doc).
    return SizedBox(
      width: _width,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // A genuinely floating circle: elevated to FAB-standard depth
              // (was 2/3 — read as barely-there against a busy photo) with a
              // soft ambient shadow, plus a colored glow echoing the Ayma
              // orb's own soft halo when this action is the "done" one, so
              // the rail reads as one visual family with the orb rather
              // than a flat row of icons pasted on the image.
              DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.28),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                    if (active)
                      BoxShadow(
                        color: ac.accent.withValues(alpha: 0.45),
                        blurRadius: 14,
                        spreadRadius: 1,
                      ),
                  ],
                ),
                child: Material(
                  color: bg,
                  shape: const CircleBorder(),
                  child: Padding(
                    padding: const EdgeInsets.all(13),
                    child: IconTheme(
                      data: IconThemeData(color: fg, size: 21),
                      child: icon,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                label,
                textAlign: TextAlign.center,
                style: AymaType.sans(size: 11, weight: FontWeight.w700)
                    .copyWith(color: Colors.white, shadows: _labelShadows),
              ),
              if (caption != null)
                Text(
                  caption!,
                  textAlign: TextAlign.center,
                  style: AymaType.sans(size: 9, color: Colors.white70)
                      .copyWith(shadows: _labelShadows),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({
    required this.p,
    required this.liked,
    required this.liking,
    required this.scoring,
    required this.score,
    required this.onLike,
    required this.onUnlike,
    required this.onRunMatch,
  });

  final PublicProfile p;
  final bool liked;
  final bool liking;
  final bool scoring;

  /// The current match score (local override or the profile's), or null when
  /// this pair has never been scored.
  final double? score;
  final void Function(PublicProfile) onLike;
  final void Function(PublicProfile) onUnlike;
  final void Function(PublicProfile) onRunMatch;

  // Rough credit costs, shown as a caption so a tap is never a surprise.
  // Match scoring: CREDIT_COST_MATCH_SCORE (backend). Deep dive: same as the
  // "Search the web about me" skill — see skills_screen.dart.
  static const _matchCredits = 12;
  static const _deepDiveCredits = 15;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _RailButton(
          active: liked,
          onPressed: liking ? null : () => liked ? onUnlike(p) : onLike(p),
          icon: Icon(
              liked ? Icons.favorite_rounded : Icons.favorite_border_rounded),
          label: liked ? 'Liked' : 'Like',
        ),
        const SizedBox(height: 16),
        _RailButton(
          // `p.threadId` is a bare deterministic pair id present for any
          // non-self profile — it exists whether or not they've ever
          // actually spoken. Only `hasChatted` (a real message sent either
          // way) should light this up.
          active: p.hasChatted,
          onPressed: p.threadId == null
              ? null
              : () => context.push('/dm/${p.threadId}'),
          icon: const Icon(Icons.chat_bubble_outline_rounded),
          label: 'Chat',
        ),
        const SizedBox(height: 16),
        _RailButton(
          active: p.deepDiveId.isNotEmpty,
          onPressed: p.deepDiveId.isNotEmpty
              ? () => context
                  .push('/deep-dive/${Uri.encodeComponent(p.deepDiveId)}')
              : () {
                  ChatInbox.instance.push(ChatKickoff.deepDive(
                    targetUid: p.uid,
                    label: p.name.isEmpty ? 'them' : p.name,
                  ));
                  context.go(MainShellScreen.path);
                },
          icon: Icon(p.deepDiveId.isNotEmpty
              ? Icons.description_outlined
              : Icons.travel_explore),
          label: 'Web search',
          caption: p.deepDiveId.isEmpty ? '$_deepDiveCredits cr' : null,
        ),
        const SizedBox(height: 16),
        // Listens to MatchActivity so the button flips live when a recalc
        // kicked off elsewhere lands.
        ValueListenableBuilder<Set<String>>(
          valueListenable: MatchActivity.instance.recalculating,
          builder: (context, active, _) {
            final recalculating = active.contains(p.threadId);
            final hasScore = score != null;
            final busy = scoring || recalculating;
            return _RailButton(
              active: hasScore,
              onPressed: busy ? null : () => onRunMatch(p),
              icon: busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(hasScore
                      ? Icons.assignment_outlined
                      : Icons.insights_rounded),
              // Once a real match report exists, show its actual percentage
              // at a glance instead of the generic label — no need to
              // re-run it just to see the number again.
              label: hasScore ? '${(score! * 100).round()}%' : 'Match report',
              caption: hasScore ? null : '$_matchCredits cr',
            );
          },
        ),
      ],
    );
  }
}

/// The owner-only "Physical" section: each attribute with its value and a
/// small tag saying whether it came from the user's answers or their photos.
class _PhysicalSection extends StatelessWidget {
  const _PhysicalSection({required this.attributes});

  final List<PhysicalAttribute> attributes;

  static const _labels = {
    'race_ethnicity': 'Ethnicity (apparent)',
    'skin_tone': 'Skin tone',
    'eye_color': 'Eyes',
    'hair_color': 'Hair',
    'hair_length': 'Hair length',
    'hair_type': 'Hair type',
    'height_estimate_cm': 'Height (rough)',
    'weight_estimate_kg': 'Weight (rough)',
    'build': 'Build',
    'facial_hair': 'Facial hair',
    'glasses': 'Glasses',
    'visible_tattoos': 'Tattoos',
    'visible_piercings': 'Piercings',
    'distinguishing_features': 'Notable features',
  };

  String _value(PhysicalAttribute a) {
    if (a.field == 'height_estimate_cm') return '~${a.value} cm';
    if (a.field == 'weight_estimate_kg') return '~${a.value} kg';
    return a.value;
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('PHYSICAL',
              style: AymaType.mono(size: 10, color: ac.fgMute)
                  .copyWith(letterSpacing: 1.4)),
          const SizedBox(height: 8),
          for (final a in attributes)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  SizedBox(
                    width: 128,
                    child: Text(_labels[a.field] ?? a.field,
                        style: AymaType.sans(size: 13, color: ac.fgMute)),
                  ),
                  Expanded(
                    child: Text(_value(a),
                        style: AymaType.sans(size: 13, color: ac.fg)),
                  ),
                  Text(
                    a.isStated ? 'from your answers' : 'from photos',
                    style: AymaType.mono(size: 9, color: ac.fgMute)
                        .copyWith(letterSpacing: 0.6),
                  ),
                ],
              ),
            ),
        ],
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
