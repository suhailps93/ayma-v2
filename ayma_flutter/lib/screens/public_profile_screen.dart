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

  /// Tapping Explore/Messages/Profile from here (this screen is pushed on
  /// top of the shell, not one of its own tabs) hands the target tab to
  /// [TabRequest] and returns to the shell — founder ask: "make sure the
  /// bottom nav bar is visible in all pages", flagged specifically on this
  /// screen (a profile reached from Explore). See `AymaTabBar`'s and
  /// `TabRequest`'s own docs.
  void _goToTab(int i) {
    TabRequest.instance.request(i);
    context.go(MainShellScreen.path);
  }

  /// [AymaTabBar]'s `onSelected` here (see [_goToTab]'s doc for why this
  /// screen carries its own copy of the bar rather than `NavBarShell`'s).
  /// The orb gets the same treatment `NavBarShell` gives it everywhere else:
  /// this screen is never the Ayma tab, so tapping it opens the scoped
  /// page-context popup instead of navigating back to the shell (founder
  /// ask: "like the story edit"). A second orb tap while that popup is
  /// already open (its own on-top copy of this same bar, wired to this same
  /// method — see [_navBar]) dismisses it and heads to the real Ayma tab
  /// instead of stacking a second popup (founder ask, round 2).
  Future<void> _onTabTap(int i) async {
    if (i == 0) {
      if (isPageContextAymaPopupOpen) {
        // `_goToTab`'s `context.go` replaces this whole route, popup
        // included — but it doesn't pop the popup *for* us (an
        // imperatively-pushed route like this modal sheet sits outside
        // go_router's own page stack, so a declarative navigation alone
        // leaves it stranded on top, still showing). Pop it explicitly,
        // then wait for that pop's own dismiss transition to actually
        // finish (`pendingPageContextAymaPopup`) before navigating — doing
        // both in the same frame instead tears the transition down
        // mid-flight ("animation still running after the widget tree was
        // disposed").
        Navigator.of(context).pop();
        await pendingPageContextAymaPopup;
        if (mounted) _goToTab(0);
      } else {
        showPageContextAymaPopup(context, navBarBuilder: _navBar);
      }
    } else {
      _goToTab(i);
    }
  }

  /// Reused verbatim (same `onSelected`) as [showPageContextAymaPopup]'s
  /// `navBarBuilder` — see [_onTabTap]'s doc — so the on-top copy the popup
  /// renders behaves identically to this screen's own bar, including a tap
  /// on it deciding to dismiss the popup and navigate rather than opening a
  /// second one.
  Widget _navBar(BuildContext context) {
    return ListenableBuilder(
      listenable: AymaSession.instance.voice,
      builder: (context, _) => AymaTabBar(
        index: -1,
        voice: AymaSession.instance.voice,
        onSelected: _onTabTap,
      ),
    );
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
          // double-count the clearance the action rail below already adds
          // for this same bar (`AymaTabBar.contentHeight` +
          // `MediaQuery.paddingOf(context).bottom`). Living here instead,
          // `body` still spans the *whole* screen exactly as before this bar
          // existed, so the rail's own bottom offset is the only place that
          // math happens.
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
                // Docked snugly in the bottom-right corner (founder ask,
                // 3rd round: "docked to the bottom right instead of leaving
                // space") — directly above the persistent tab bar (last
                // child of this `Stack`, below), not floating with a big
                // empty gap. The old `170` bottom clearance was derived
                // against `GlobalAymaLauncher`'s orb when that orb still
                // floated bottom-right; the orb has since moved to
                // top-right (`global_ayma_launcher.dart`'s
                // `Alignment.topRight`), so that number no longer clears
                // anything real — it was just dead space. `AymaTabBar
                // .contentHeight` is the bar's own real on-screen height
                // (excluding the device's own bottom safe-area inset, which
                // is added back here explicitly rather than relying on
                // `SafeArea`'s `minimum` — that widget takes the *larger* of
                // the device inset or `minimum`, not their sum, which would
                // under-clear the bar on any device with a real inset, e.g.
                // an iPhone's home-indicator area); `16` is a small,
                // consistent gap above the bar, matching the rail's own
                // `16` right inset and the app's other edge insets.
                Positioned(
                  right: 16,
                  bottom: MediaQuery.paddingOf(context).bottom +
                      AymaTabBar.contentHeight +
                      16,
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
              // Persistent tab bar even though this screen is a pushed route,
              // not a shell tab — founder ask: "make sure the bottom nav bar
              // is visible in all pages", flagged specifically on this screen
              // (a profile reached from Explore). Tapping a tab hands the
              // target off via `TabRequest` and returns to the shell (see
              // `_goToTab`). `index: -1` — this isn't actually any of the
              // four tabs, so nothing here should read as the current one.
              Align(
                alignment: Alignment.bottomCenter,
                child: _navBar(context),
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
            // Wide enough to clear the global Ayma orb launcher's own
            // top-right footprint (`GlobalAymaLauncher`: 16px right inset +
            // 8px tap padding + 48px orb ≈ 72px from the edge) so this
            // action never sits under it.
            const SizedBox(width: 80),
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
class ProfilePhotoHeader extends StatefulWidget {
  const ProfilePhotoHeader({
    super.key,
    required this.photos,
    required this.seed,
    required this.name,
    required this.age,
    required this.location,
    this.isOnline = false,
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

  /// True only when this person's real presence data (§ `PublicProfile.
  /// isOnline`) says they're currently active — never a placeholder. Shows
  /// the small green "Active now" dot in the status row when true; when
  /// false the status row is just the location, same as before presence
  /// existed.
  final bool isOnline;

  /// Shown under the status row, in place of it having any meaning — e.g.
  /// "You've blocked this person." Null shows nothing.
  final String? blockedMessage;

  /// An optional overlay floating on the photo itself, bottom-right (e.g.
  /// [PublicProfileBody]'s like/chat/web-search/run-match rail). Null shows
  /// no overlay — [MyPublicProfileScreen] leaves photos display-only.
  final Widget? actions;

  @override
  State<ProfilePhotoHeader> createState() => _ProfilePhotoHeaderState();
}

class _ProfilePhotoHeaderState extends State<ProfilePhotoHeader> {
  // Owned here (rather than by a separate `_Gallery`) because the bottom
  // filmstrip (founder reference: a dark profile card with a row of photo
  // thumbnails pinned along the bottom, the selected one ringed in the
  // accent colour) needs to both drive and reflect the same page the
  // PageView shows — one shared controller/index for both.
  final _controller = PageController();
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _goToPage(int i) {
    if (i == _page) return;
    _controller.animateToPage(
      i,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AspectRatio(
          aspectRatio: 1,
          child: Stack(
            fit: StackFit.expand,
            children: [
              widget.photos.isEmpty
                  ? fallback
                  : PageView.builder(
                      controller: _controller,
                      onPageChanged: (i) => setState(() => _page = i),
                      itemCount: widget.photos.length,
                      itemBuilder: (_, i) => AymaPhoto(
                        url: widget.photos[i],
                        displayWidth: 900,
                        error: fallback,
                      ),
                    ),
              // Dark gradient scrim fading up from the bottom of the photo
              // (founder reference screenshot) so the name/status text
              // below stays legible over any photo — transparent at the
              // top of the scrim, solid dark at the very bottom edge.
              // Always dark regardless of app theme, same as the rail
              // caption text below: this is photo chrome, not page chrome.
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        stops: const [0.45, 1.0],
                        colors: [
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.9),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 20,
                right: widget.actions != null ? 84 : 20,
                bottom: 16,
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
                            widget.name.isEmpty ? 'Someone' : widget.name,
                            style:
                                AymaType.serif(size: 28, color: Colors.white),
                          ),
                        ),
                        if (widget.age != null)
                          Text(' · ${widget.age}',
                              style: AymaType.sans(
                                  size: 16, color: Colors.white70)),
                      ],
                    ),
                    if (widget.isOnline || widget.location.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          if (widget.isOnline) ...[
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: ac.success,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text('Active now',
                                style: AymaType.sans(
                                    size: 13, color: Colors.white70)),
                            if (widget.location.isNotEmpty)
                              Text('  ·  ',
                                  style: AymaType.sans(
                                      size: 13, color: Colors.white70)),
                          ],
                          if (widget.location.isNotEmpty)
                            Flexible(
                              child: Text(widget.location,
                                  overflow: TextOverflow.ellipsis,
                                  style: AymaType.sans(
                                      size: 13, color: Colors.white70)),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
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
              // the rail's own 16px right inset and the orb itself, which
              // floats lower still (`GlobalAymaLauncher`'s `bottom: 90`
              // screen-wide inset).
              if (widget.actions != null)
                Positioned(right: 16, bottom: 16, child: widget.actions!),
            ],
          ),
        ),
        // Horizontal filmstrip of photo thumbnails pinned along the bottom
        // edge of the header, below the gradient scrim, on its own solid
        // dark strip — replaces the small dot indicator this header used to
        // show instead (founder reference screenshot). Only shown with more
        // than one photo, same threshold the old dot indicator used.
        if (widget.photos.length > 1)
          _Filmstrip(
            photos: widget.photos,
            fallback: fallback,
            currentPage: _page,
            onSelect: _goToPage,
          ),
        if (widget.blockedMessage != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Text(widget.blockedMessage!,
                style: AymaType.sans(size: 13, color: AymaColors.error)),
          ),
      ],
    );
  }
}

/// The bottom filmstrip's own thumbnail row — see [ProfilePhotoHeader]'s
/// class doc. Tapping a thumbnail switches the carousel above to that photo.
class _Filmstrip extends StatelessWidget {
  const _Filmstrip({
    required this.photos,
    required this.fallback,
    required this.currentPage,
    required this.onSelect,
  });

  final List<String> photos;
  final Widget fallback;
  final int currentPage;
  final ValueChanged<int> onSelect;

  static const _thumb = 52.0;

  @override
  Widget build(BuildContext context) {
    // The live selected accent colour, not a hardcoded ring colour — same
    // `context.ac.accent` pattern the action rail uses (§ `_Actions`).
    final accent = context.ac.accent;
    return ColoredBox(
      color: AymaColors.darkBg,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: SizedBox(
          height: _thumb,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: photos.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (_, i) {
              final selected = i == currentPage;
              return GestureDetector(
                onTap: () => onSelect(i),
                child: Container(
                  width: _thumb,
                  height: _thumb,
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: selected ? accent : Colors.transparent,
                      width: 2,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(7),
                    child: AymaPhoto(
                      url: photos[i],
                      displayWidth: 120,
                      error: fallback,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
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
          isOnline: p.isOnline,
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

/// One profile-action rail button — a floating icon-only glyph, colored by
/// whether that action has already happened, not by button type. Each
/// glyph (`ayma_rail_icons.dart`) is the same soft filled-glass rendering —
/// `AymaOrbPainter`'s own gradient/highlight/glow technique — at two
/// intensities: not-yet-done is a paler, quieter frosted-glass glyph; liked /
/// already messaged / web search already run / match already scored is that
/// same glyph in its fuller, richer, glowing form (founder: "if liked or
/// matched or searched or messages make that fill with the theme colour").
/// `ac.accent` (the user's own accent pick, not a hardcoded brand colour) so
/// both states hold under any accent and either theme.
///
/// No label or credit-cost caption underneath any more (founder ask,
/// 2026-09-22: "make these icons double the size, remove the text below") —
/// the glyph's own not-done-vs-done state is now the ONLY signal a viewer
/// gets for each button's status, including the match score: once a report
/// exists the Match glyph simply switches to its fuller state, there's no
/// percentage printed anywhere on the rail.
///
/// Styled to read as genuinely floating — its own soft glow/contact-shadow
/// (`ayma_rail_icons.dart`) stands in for the elevation a disc/card
/// background would otherwise carry: a fixed [_width] box so every button
/// centers on the identical vertical line, and the screen-level `Positioned`
/// this rail is mounted under (`PublicProfileScreen`'s `build`) docks it
/// `right: 16` — the same right inset every other edge-anchored element on
/// this screen uses — just above the persistent tab bar.
class _RailButton extends StatelessWidget {
  const _RailButton({
    required this.icon,
    required this.active,
    required this.onPressed,
  });

  final Widget icon;
  final bool active;
  final VoidCallback? onPressed;

  /// Orb tap box width (48px circle + 8px padding each side) — see class doc.
  static const _width = 64.0;

  /// Icon-only rail (founder ask, 2026-09-22: "double the icon size, remove
  /// the text below") — 21 doubled to 42. The glyph's own `filled` flag (see
  /// `ayma_rail_icons.dart`) is now the *only* signal for each button's
  /// status: no label ("Like"/"Chat"/"Web search"/the match %) and no
  /// credit-cost caption underneath any more.
  static const _iconSize = 42.0;

  /// Padding around the glyph — shrunk from the old 13 (which paired with a
  /// 21px icon) so the doubled 42px glyph's own box (42 + 8*2 = 58) still
  /// sits inside the unchanged 64px tap-target width with a few px of
  /// breathing room on each side, instead of overflowing/clipping it.
  static const _iconPadding = 8.0;

  static const _labelShadows = [
    Shadow(color: Colors.black54, blurRadius: 6),
    Shadow(color: Colors.black45, blurRadius: 2),
  ];

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    // Fixed-width tap target so every button's glyph centers on the same
    // line as the Ayma orb (see class doc). The wrapping `Column` (rather
    // than handing the icon straight to `InkWell`/`Padding`) matters even
    // with a single child: `SizedBox(width: _width)` forces a *tight* 64px
    // width constraint down through `InkWell`/`Padding`, and only `Column`'s
    // default `crossAxisAlignment.center` loosens that back to the glyph's
    // own natural (smaller) size instead of stretching it to fill the box.
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
              // No circular disc/button behind either state (founder ask,
              // reference moodboard) — just the glyph itself. "Done" is the
              // solid filled glyph (its own glow is painted by the glyph's
              // painter, hugging its silhouette — see `ayma_rail_icons.dart`);
              // "not done" is the thin outline glyph. Same padding both ways
              // so the icon centers on the same line regardless of state.
              Padding(
                padding: const EdgeInsets.all(_iconPadding),
                child: IconTheme(
                  data: IconThemeData(
                    color: ac.accent,
                    size: _iconSize,
                    shadows: _labelShadows,
                  ),
                  child: icon,
                ),
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
