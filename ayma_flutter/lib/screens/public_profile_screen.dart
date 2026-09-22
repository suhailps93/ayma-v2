import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../screens/main_shell_screen.dart';
import '../services/api_client.dart';
import '../services/app_context.dart';
import '../services/ayma_session.dart';
import '../services/chat_inbox.dart';
import '../services/match_activity.dart';
import '../services/tab_request.dart';
import '../theme.dart';
import '../widgets/ask_ayma_action.dart';
import '../widgets/ask_ayma_overlay.dart';
import '../widgets/ayma_photo.dart';
import '../widgets/ayma_rail_icons.dart';
import '../widgets/ayma_tab_bar.dart';
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

  /// Tapping a tab from here (this screen is pushed on top of the shell, not
  /// one of its own tabs) hands the target tab to [TabRequest] and returns to
  /// the shell — founder ask: "make sure the bottom nav bar is visible in
  /// all pages", flagged specifically on this screen (a profile reached from
  /// Explore). See `AymaTabBar`'s and `TabRequest`'s own docs.
  void _goToTab(int i) {
    TabRequest.instance.request(i);
    context.go(MainShellScreen.path);
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
            // Extra bottom padding so the last of the scrollable content
            // clears the persistent tab bar this screen now floats at its own
            // bottom edge (see the `Stack`'s last child below) instead of
            // disappearing behind its opaque background at full scroll — the
            // default `PublicProfileBody` padding (40) predates that bar.
            content = PublicProfileBody(p: p, bottomPadding: 120);
          }
          // Screen-level `Stack` — a sibling of the scrollable content below,
          // not a descendant of it — so the action rail can float fixed on
          // screen the same way `GlobalAymaLauncher`'s orb does (see that
          // widget's class doc): the rail used to live `Positioned` *inside*
          // the photo's own `Stack`, which was itself just the first item of
          // `_Body`'s `ListView`, so it scrolled away with the rest of the
          // list the moment the user scrolled past the photo. Anchoring it
          // here, above the `Column` that holds the scrollable body, is what
          // actually keeps it fixed regardless of scroll position.
          //
          // The persistent tab bar (last child, § below) lives in this same
          // Stack rather than as `Scaffold.bottomNavigationBar` deliberately:
          // that property would shrink `body`'s height, which would in turn
          // shift every `SafeArea`-relative offset above (the action rail's
          // carefully calibrated `170`) by the bar's own height, throwing off
          // its alignment with the globally-floating Ayma orb. Living here
          // instead, `body` still spans the *whole* screen exactly as before
          // this bar existed, so none of that math needs to change.
          return Stack(
            children: [
              Column(
                children: [
                  _TitleBar(
                    title: title,
                    action: p == null
                        ? null
                        : AskAymaAction(
                            label: p.isSelf ? 'Edit with Ayma' : 'Ask Ayma',
                            onPressed: () => showAskAymaOverlay(
                              context,
                              api: _api,
                              ctx: AskAymaContext(
                                // No `LivingReportView`/block model backs
                                // this screen (§ `MyPublicProfileScreen`'s
                                // own doc: it's explicitly out of scope for
                                // the generic-report convergence and "stays
                                // exactly as it was"), so there's no real
                                // block/report id to hand over — same as a
                                // non-owner's read-only report tap, this
                                // opens plain Q&A about the profile via
                                // [quoteTitle], not a scoped correction.
                                origin: AskAymaOrigin.reportView,
                                quoteTitle: title,
                              ),
                            ),
                          ),
                  ),
                  Expanded(child: content),
                ],
              ),
              if (p != null && !p.blocked && !p.isSelf)
                Align(
                  alignment: Alignment.bottomRight,
                  child: SafeArea(
                    // Stacked vertically, floating, bottom-right — directly
                    // above the floating Ayma orb (`GlobalAymaLauncher`),
                    // never inside any scrollable widget. Derived from that
                    // launcher's own current values, not guessed: its orb
                    // sits at `SafeArea(minimum: bottom: 90, right: 16)` in a
                    // 48px orb + 8px tap padding per side = 64px box, so the
                    // *top* of that box is `90 + 64 = 154` above the screen
                    // bottom. `16` more (the same gap `_Actions` already
                    // uses between its own buttons) clears the orb: `154 +
                    // 16 = 170`. Right inset matches the orb's own (`16`)
                    // exactly, same as before, so the two read as one
                    // aligned column.
                    minimum: const EdgeInsets.only(bottom: 170, right: 16),
                    child: _Actions(
                      key: const Key('profileActionRail'),
                      p: p,
                      liked: _isLiked(p),
                      liking: _liking,
                      scoring: _scoring,
                      score: _score ?? p.score,
                      onLike: _like,
                      onUnlike: _unlike,
                      onRunMatch: _runMatch,
                    ),
                  ),
                ),
              // Persistent tab bar even though this screen is a pushed route,
              // not a shell tab — founder ask: "make sure the bottom nav bar
              // is visible in all pages", flagged specifically on this screen
              // (a profile reached from Explore). Tapping a tab hands the
              // target off via `TabRequest` and returns to the shell (see
              // `_goToTab`). `index: -1` — this isn't actually any of the
              // four tabs, so nothing here should read as the current one.
              Align(
                alignment: Alignment.bottomCenter,
                child: ListenableBuilder(
                  listenable: AymaSession.instance.voice,
                  builder: (context, _) => AymaTabBar(
                    index: -1,
                    voiceActive: AymaSession.instance.voice.isActive,
                    onSelected: _goToTab,
                  ),
                ),
              ),
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

/// The photo carousel + name/age/location header shared by every screen that
/// shows "the same photo header a viewer sees when they open this profile" —
/// [PublicProfileBody] (Explore/match-request browsing, with the optional
/// action rail) and [MyPublicProfileScreen]'s self-view (photos display-only
/// there — managing/reordering photos already has its own dedicated screen,
/// `PhotoManagementScreen`). Extracted so there's exactly ONE photo-carousel
/// implementation, not a near-identical second one per caller.
class ProfilePhotoHeader extends StatelessWidget {
  const ProfilePhotoHeader({
    super.key,
    required this.photos,
    required this.seed,
    required this.name,
    required this.age,
    required this.location,
    this.blockedMessage,
    this.actions,
  });

  /// Ready-to-render download URLs, primary first.
  final List<String> photos;

  /// Seeds the fallback gradient shown when [photos] is empty.
  final String seed;

  final String name;
  final int? age;
  final String location;

  /// Shown under the location line, in place of it having any meaning — e.g.
  /// "You've blocked this person." Null shows nothing.
  final String? blockedMessage;

  /// An optional overlay floating on the photo itself, bottom-right (e.g.
  /// [PublicProfileBody]'s like/chat/web-search/run-match rail). Null shows
  /// no overlay — [MyPublicProfileScreen] leaves photos display-only.
  final Widget? actions;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Stack(
          children: [
            _Gallery(photos: photos, seed: seed),
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
            //
            // Vertically anchored to the *bottom* of the photo, not
            // centered — founder screenshot showed the rail sitting up near
            // the top of the photo with a wide dead gap below it down to the
            // orb; bottom-anchoring pulls the whole rail down into that gap
            // so it reads as "floating just above the orb" instead of
            // "pinned to the middle of the image". 16px bottom inset matches
            // the rail's own 16px right inset and clears the pagination
            // dots (which sit centered, `bottom: 10`, well clear of this
            // right-edge column) and the orb itself, which floats lower
            // still (`GlobalAymaLauncher`'s `bottom: 90` screen-wide inset).
            if (actions != null)
              Positioned(right: 16, bottom: 16, child: actions!),
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
                      name.isEmpty ? 'Someone' : name,
                      style: AymaType.serif(size: 28, color: ac.fg),
                    ),
                  ),
                  if (age != null)
                    Text('  $age',
                        style: AymaType.sans(size: 16, color: ac.fgMute)),
                ],
              ),
              if (location.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(location.toUpperCase(),
                    style: AymaType.mono(size: 10, color: ac.fgMute)
                        .copyWith(letterSpacing: 1.4)),
              ],
              if (blockedMessage != null) ...[
                const SizedBox(height: 16),
                Text(blockedMessage!,
                    style: AymaType.sans(size: 13, color: AymaColors.error)),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// The read-only/browsing rendering of someone's public profile — photo
/// gallery, name/age/location, and bio sections. Public and reusable: any
/// screen that needs to show "the same full public profile a user would see
/// if they tapped into that person's profile normally" (e.g. the match
/// request screen, §14.3) renders this instead of building its own bespoke
/// display. Display-only — the floating like/chat/web-search/run-match rail
/// lives at the screen level in whichever screen embeds this (see
/// `PublicProfileScreen.build`), not inside this widget.
class PublicProfileBody extends StatelessWidget {
  const PublicProfileBody({super.key, required this.p, this.bottomPadding = 40});

  final PublicProfile p;

  /// Clears whatever chrome the embedding screen floats at its own bottom
  /// edge — plain 40 by default; `PublicProfileScreen` passes more to clear
  /// its persistent tab bar (see its build method).
  final double bottomPadding;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;

    return ListView(
      padding: EdgeInsets.only(bottom: bottomPadding),
      children: [
        ProfilePhotoHeader(
          photos: p.photos,
          seed: p.uid,
          name: p.name,
          age: p.age,
          location: p.location,
          blockedMessage: p.blocked ? "You've blocked this person." : null,
          // The like/chat/web-search/run-match rail floats at the screen
          // level in PublicProfileScreen.build, not inside this header.
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
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

/// One profile-action rail button — a floating icon with a short caption
/// underneath, colored by whether that action has already happened, not by
/// button type. Founder spec (2nd reference screenshot — a generic app's own
/// rail: outline-only icons, no fill, no circle background, in the theme
/// colour): not-yet-done state -> theme-accent-coloured OUTLINE icon, no
/// filled circle at all; liked / already messaged / web search already run /
/// match already scored -> that same icon switches to a solid theme-accent
/// circle (founder: "if liked or matched or searched or messages make that
/// fill with the theme colour"). `ac.accent` (the user's own accent pick, not
/// a hardcoded brand colour) rather than literal white/black so both states
/// hold under any accent and either theme; the caption itself is always white
/// with a shadow since the rail floats over arbitrary scrolled content, not
/// the page background.
///
/// Styled to read as genuinely floating — like the app-wide Ayma-orb launcher
/// button (`GlobalAymaLauncher`) — and to share that same launcher's
/// horizontal column: a fixed [_width] box (equal to the orb's own 48px
/// circle + 8px tap padding on each side) so every button centers on the
/// identical vertical line regardless of how wide its own caption is, and the
/// screen-level `Align`/`SafeArea` this rail is mounted under
/// (`PublicProfileScreen`'s `build`) matches the orb's own right inset (16px)
/// exactly.
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
              if (active)
                // Done: a genuinely floating solid circle — elevated to
                // FAB-standard depth with a soft ambient shadow, plus a
                // colour glow echoing the Ayma orb's own soft halo, so the
                // rail reads as one visual family with the orb rather than a
                // flat row of icons pasted on the image.
                DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.28),
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                      ),
                      BoxShadow(
                        color: ac.accent.withValues(alpha: 0.45),
                        blurRadius: 14,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                  child: Material(
                    color: ac.accent,
                    // A thin translucent white ring so the filled circle
                    // still reads against a light photo, not just a dark one.
                    shape: CircleBorder(
                      side: BorderSide(
                        color: Colors.white.withValues(alpha: 0.4),
                        width: 1.2,
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(13),
                      child: IconTheme(
                        data: IconThemeData(color: ac.onAccent, size: 21),
                        child: icon,
                      ),
                    ),
                  ),
                )
              else
                // Not yet done: outline only — no fill, no circle background
                // at all (founder ask, reference screenshot). Just the icon
                // itself in the theme accent colour, with the same drop
                // shadow the caption below already uses so it stays legible
                // over a light patch of an arbitrary photo without needing
                // any painted surface behind it.
                Padding(
                  padding: const EdgeInsets.all(13),
                  child: IconTheme(
                    data: IconThemeData(
                      color: ac.accent,
                      size: 21,
                      shadows: _labelShadows,
                    ),
                    child: icon,
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
    super.key,
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
    // The live selected accent colour — every glyph reads it fresh on each
    // build, so a pick made on the Accent Color settings screen recolours
    // this rail immediately (§ `AccentColorController` / `context.ac`), with
    // no restart and no colour literal of our own anywhere in this file.
    final accent = context.ac.accent;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _RailButton(
          active: liked,
          onPressed: liking ? null : () => liked ? onUnlike(p) : onLike(p),
          icon: AymaHeartGlyph(accent: accent, filled: liked),
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
          icon: AymaChatGlyph(accent: accent, filled: p.hasChatted),
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
          icon: AymaSearchGlyph(
              accent: accent, filled: p.deepDiveId.isNotEmpty),
          // Two lines ("Web" / "search") per spec, no secondary text below.
          label: 'Web\nsearch',
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
                  : AymaMatchGlyph(accent: accent, filled: hasScore),
              // Once a real match report exists, show its actual percentage
              // at a glance — never a placeholder "0%" for a pair that just
              // hasn't been scored yet.
              label: hasScore ? '${(score! * 100).round()}%' : 'Match',
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
