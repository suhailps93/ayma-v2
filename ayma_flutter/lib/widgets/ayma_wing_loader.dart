import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

/// Thematic status lines for [AymaWingLoader], one set per loading context.
///
/// Founder rule (Nov 2026): every line must name an operation that is ACTUALLY
/// happening at that moment — whimsical wording, truthful content. A set holds
/// either the successive stages of one multi-step load (the caller drives
/// [AymaWingLoader.stage] from its real futures/state) or rephrasings of ONE
/// in-flight operation (the caller passes `autoRotate: true`).
abstract final class AymaLoaderLines {
  /// Fallback for loads with no thematic set. Deliberately operation-agnostic
  /// so it is truthful anywhere; prefer a thematic set at every call site.
  static const generic = ['Working on it…'];

  /// Cold start ([SplashScreen]): `0` while the wake-ping + first bootstrap
  /// attempt run, `1` while a backoff retry is pending/in flight.
  static const startup = ['Waking up Ayma…', 'Reconnecting…'];

  /// Retry signal: a load whose first attempt failed and whose backoff retry
  /// is pending/in flight swaps its thematic set for this single line (with
  /// `autoRotate: false`) instead of holding the original line indefinitely.
  /// A swap — not an appended entry — so rotating rephrasing sets can never
  /// show it spuriously while the first attempt is still fresh.
  static const reconnect = ['Reconnecting…'];

  /// Chat home ([ChatScreen]): the initial `/chat/history` load (single
  /// operation — rotate to rephrase).
  static const chatHistory = [
    'Loading your conversation…',
    'Remembering where you left off…',
  ];

  /// Explore feed ([ExploreScreen]): the initial `GET /explore` load.
  static const explore = ['Finding people near you…'];

  /// Messages tab ([MessagesScreen]) and the share-sheet recipient picker:
  /// DM threads + mutual matches first emissions.
  static const messages = ['Loading your conversations…'];

  /// DM thread ([DmThreadScreen]): the thread's message stream.
  static const dmThread = ['Loading your conversation…'];

  /// Matches ([MatchesScreen]): the scored-matches stream.
  static const matches = ['Loading your matches…'];

  /// Match detail ([MatchDetailScreen]): the match doc + their public profile.
  static const matchDetail = ['Loading this match…'];

  /// Notifications ([NotificationCenterScreen]): the notifications stream.
  static const notifications = ['Loading your notifications…'];

  /// Notification prefs ([NotificationPrefsScreen]): reading `notification_prefs`.
  static const notifPrefs = ['Loading your notification settings…'];

  /// Report views ([LivingReportView]): reading the stored report.
  static const report = ['Loading your report…'];

  /// Face report ([FaceReportView]): `GET /skills/report/face/{id}`.
  static const faceReport = ['Loading your face report…'];

  /// Physique report ([BodyReportView]): `GET /skills/report/body/{id}`.
  static const bodyReport = ['Loading your physique report…'];

  /// Match report ([MatchReportScreen]): `GET /match/{id}`.
  static const matchReport = ['Loading your match report…'];

  /// Physical profile ([PhysicalAttributesReportScreen]).
  static const physicalReport = ['Loading your physical profile…'];

  /// Deep dive ([DeepDiveReportScreen]): the first web search still running.
  static const deepDive = ['Searching the web for you…'];

  /// Appearance pre-run sheet: `GET /appearance/eligibility`.
  static const appearanceEligibility = ['Loading your eligible photos…'];

  /// Profile proposals ([ProfileProposalsScreen]): `GET /profile/proposals`.
  static const proposals = ["Loading Ayma's suggestions…"];

  /// Profile screens: reading the profile being shown or edited.
  static const profile = ['Loading your profile…'];

  /// Someone else's public profile ([PublicProfileScreen]).
  static const publicProfile = ['Loading this profile…'];

  /// Profile text editor: `GET /profile/public-text`.
  static const profileText = ['Loading your profile text…'];

  /// Complete-profile screen: `GET /completeness` + `GET /questionnaire`.
  static const profileProgress = ['Loading your profile progress…'];

  /// Sign-in ([SignInScreen]): the Firebase sign-in attempt in flight.
  static const signIn = ['Signing you in…'];

  /// Sign-in, create-account mode: creating the Firebase user.
  static const signUp = ['Creating your account…'];

  /// Sign-in, phone stage: sending or confirming the SMS code.
  static const phoneVerify = ['Verifying your number…'];

  /// Sign-in, forgot-password: sending the reset email.
  static const resetEmail = ['Sending your reset email…'];

  /// Plan ([PlanScreen]): RevenueCat status + plans + usage + trial offer.
  static const plan = ['Loading your plan and credits…'];

  /// Google account screen: reading the Gmail/Calendar link status.
  static const googleStatus = ['Checking your Google connection…'];

  /// Instagram screen: reading the Instagram link status.
  static const instagramStatus = ['Checking your Instagram connection…'];

  /// Invite screen: `GET`ting the personal referral code and link.
  static const inviteLink = ['Getting your invite link…'];

  /// Connect-agent screen: listing connected MCP agents.
  static const agents = ['Loading your connected agents…'];

  /// Developer screen: `GET /usage` spend figures.
  static const devSpend = ['Loading your spend…'];

  /// Admin feedback screen: listing feedback reports.
  static const adminFeedback = ['Loading feedback reports…'];

  /// Voice engine control: `GET /voice/engines` catalog + selection.
  static const voiceEngines = ['Loading your voice options…'];

  /// Brain selector: `GET /brain/preference`.
  static const brains = ['Loading your brain options…'];

  /// Practice setup ([PracticeScreen]): `POST /practice/start` building the
  /// persona session. The call site names the match when known.
  static const practiceSetup = ['Setting up your practice…'];

  /// Practice debrief: `POST`-built review of the session.
  static const debrief = ['Preparing your debrief…'];

  /// Photo placeholders: the Storage image download in flight.
  static const photo = ['Loading this photo…'];

  /// Markdown image placeholders: the image download in flight.
  static const image = ['Loading this image…'];

  /// Async voice message ([AsyncVoiceSheet], the chat recording bar): the
  /// successive stages of one send, driven by the job's real status —
  /// `0` while the clip uploads, `1` while the cloud transcribes it,
  /// `2` while Ayma thinks, `3` while she speaks the reply.
  static const asyncVoice = [
    'Sending your voice…',
    'Hearing you out…',
    'Ayma is thinking…',
    'Ayma is answering…',
  ];
}

/// The one shared loading indicator: the two wing lobes of the Ayma emblem,
/// drawn (not imaged) and fluttering, with a truthful status line beneath.
///
/// The lobes are the same two-cubic-Bézier curves as the logo fit in
/// `AymaOrbPainter` (rev. 3 control points, mirrored pair meeting at the
/// bottom-center apex and flaring up/out) — copied here, not imported, so the
/// orb's private paint machinery stays untouched. They flap out of phase on a
/// ~900ms ease-in-out loop (gentle rotation about the apex plus a whisper of
/// whole-mark scale and skew), tinted to the user's accent — the same colour
/// source the old [CircularProgressIndicator] used (`context.ac.accent`).
///
/// [lines]/[stage] drive the caption: [stage] selects the current line and the
/// caption crossfades whenever it changes, so multi-step loads wire [stage] to
/// their real step. For a single awaited operation, pass that operation's
/// rephrasings with [autoRotate] to crossfade within it every ~1.8s. Small
/// inline spots (buttons, rows) use a small [size] with `showLabel: false`.
///
/// Respects reduced motion: with [MediaQuery.disableAnimations] (or forced
/// [reduceMotion]) the wings render once in their rest pose with no controller
/// running, and caption changes swap instantly instead of crossfading.
class AymaWingLoader extends StatefulWidget {
  const AymaWingLoader({
    super.key,
    this.size = 64,
    this.lines = AymaLoaderLines.generic,
    this.stage = 0,
    this.autoRotate = false,
    this.showLabel = true,
    this.color,
    this.reduceMotion,
  });

  /// Diameter of the wing mark in logical pixels. The caption sits below it.
  final double size;

  /// Status lines for this loading context (see [AymaLoaderLines]). Must not
  /// be empty; [stage] selects among them.
  final List<String> lines;

  /// Index into [lines] for the current step, driven by the caller's real
  /// load state. Clamped into range; the caption crossfades on change.
  final int stage;

  /// When true (and [lines] holds rephrasings of ONE in-flight operation),
  /// crossfade to the next line every ~1.8s. Defaults to false so a
  /// multi-stage list never advances on its own past the real step.
  final bool autoRotate;

  /// False for tiny inline spots (buttons, dense rows): just the wing mark.
  final bool showLabel;

  /// Wing tint. Defaults to the user's accent (`context.ac.accent`).
  final Color? color;

  /// Forces the static, motion-free rendering regardless of [MediaQuery].
  /// Null (the default) reads the ambient [MediaQuery.disableAnimations].
  final bool? reduceMotion;

  @override
  State<AymaWingLoader> createState() => _AymaWingLoaderState();
}

class _AymaWingLoaderState extends State<AymaWingLoader>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;
  Timer? _rotationTimer;
  int _rotation = 0;

  bool get _reduceMotion =>
      widget.reduceMotion ??
      (MediaQuery.maybeOf(context)?.disableAnimations ?? false);

  /// The line on screen: [stage] picks the step, the rotation timer (when
  /// enabled) rephrases forward from it within the same operation.
  String get _line {
    final lines = widget.lines.isEmpty ? AymaLoaderLines.generic : widget.lines;
    final base = widget.stage.clamp(0, lines.length - 1);
    if (!widget.autoRotate || lines.length < 2 || _rotationTimer == null) {
      return lines[base];
    }
    return lines[(base + _rotation) % lines.length];
  }

  @override
  void initState() {
    super.initState();
    _syncRotationTimer();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Same reduced-motion contract as AymaLogoLoader: never spin a controller
    // up at all when motion is off.
    if (_reduceMotion) {
      _controller?.stop();
      return;
    }
    // A full out-and-back flap every ~900ms; the painter eases each half.
    _controller ??= AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
    )..repeat(reverse: true);
  }

  @override
  void didUpdateWidget(AymaWingLoader old) {
    super.didUpdateWidget(old);
    // A new step restarts any rephrase cycle from that step's own line, so
    // the caption always advances WITH the real work, never past it.
    if (old.stage != widget.stage) _rotation = 0;
    if (old.autoRotate != widget.autoRotate ||
        old.lines != widget.lines ||
        old.stage != widget.stage) {
      _syncRotationTimer();
    }
  }

  void _syncRotationTimer() {
    _rotationTimer?.cancel();
    _rotationTimer = null;
    if (widget.autoRotate && widget.lines.length > 1) {
      _rotationTimer = Timer.periodic(
        const Duration(milliseconds: 1800),
        (_) {
          if (!mounted) return;
          setState(() => _rotation++);
        },
      );
    }
  }

  @override
  void dispose() {
    _rotationTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  TextStyle _labelStyle(AymaTokens ac) =>
      AymaType.mono(size: 12, color: ac.fgMute).copyWith(letterSpacing: 1.5);

  /// Measures the caption's real height (text scale and wrapping included)
  /// so a short slot can decide honestly whether wings + caption fit.
  /// Replicates the real [Text]'s inputs exactly — inherited style merged
  /// under the caption style, ambient bold, ambient maxLines and text-height
  /// behavior — because the ambient defaults change line height (measuring
  /// with the bare style under-reads and the caption then wraps past the
  /// slot: layout-matrix overflow).
  double _measureLabelHeight(
      BuildContext context, BoxConstraints constraints) {
    final base = DefaultTextStyle.of(context);
    var style = base.style.merge(_labelStyle(context.ac));
    if (MediaQuery.boldTextOf(context)) {
      style = style.merge(const TextStyle(fontWeight: FontWeight.bold));
    }
    final textPainter = TextPainter(
      text: TextSpan(text: _line, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: base.maxLines,
      textHeightBehavior: base.textHeightBehavior ??
          DefaultTextHeightBehavior.maybeOf(context),
    )..layout(maxWidth: constraints.maxWidth);
    final height = textPainter.height;
    textPainter.dispose();
    return height;
  }

  Widget _buildMark(double markSize, Color color) {
    final controller = _controller;
    return SizedBox(
      width: markSize,
      height: markSize,
      child: RepaintBoundary(
        child: (_reduceMotion || controller == null)
            ? CustomPaint(painter: AymaWingPainter(flap: 0.5, color: color))
            : AnimatedBuilder(
                animation: controller,
                builder: (context, _) => CustomPaint(
                  painter: AymaWingPainter(
                    flap: Curves.easeInOut.transform(controller.value),
                    color: color,
                  ),
                ),
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final color = widget.color ?? ac.accent;

    return Semantics(
      label: 'Loading',
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Short slots (300px split-screen, keyboard open, 2x text) get a
          // graceful degradation instead of an overflow: full wings win over
          // tiny wings + caption, and the mark itself shrinks last.
          var markSize = widget.size;
          var showLabel = widget.showLabel;
          final maxH = constraints.maxHeight;
          if (maxH.isFinite) {
            if (showLabel) {
              final natural =
                  markSize + markSize * 0.28 + _measureLabelHeight(context, constraints);
              if (maxH < natural) showLabel = false;
            }
            if (maxH < markSize) markSize = maxH.clamp(0.0, widget.size);
          }
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildMark(markSize, color),
              if (showLabel) ...[
                SizedBox(height: markSize * 0.28),
                // The visible line is excluded from semantics: the loader's
                // announced label stays the stable "Loading" (a rotating
                // live caption would spam screen readers every 1.8s).
                ExcludeSemantics(
                  child: AnimatedSwitcher(
                    duration: _reduceMotion
                        ? Duration.zero
                        : const Duration(milliseconds: 350),
                    child: Text(
                      _line,
                      key: ValueKey(_line),
                      textAlign: TextAlign.center,
                      style: _labelStyle(ac),
                    ),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// One wing/petal lobe's shape, apex-relative, in fractions of the mark's
/// radius (+x outward from center, −y up): apex → [tip] via the outer
/// controls, [tip] → apex via the inner controls.
///
/// These are `AymaOrbPainter`'s rev. 3 reference-fit numbers (the same curves
/// the logo emblem is drawn from), mirrored pair. Copied — not shared — so
/// neither file's private paint code leaks into the other.
class AymaWingDef {
  const AymaWingDef({
    required this.outer1,
    required this.outer2,
    required this.tip,
    required this.inner1,
    required this.inner2,
  });

  final Offset outer1;
  final Offset outer2;
  final Offset tip;
  final Offset inner1;
  final Offset inner2;

  static const right = AymaWingDef(
    outer1: Offset(0.72, -0.05),
    outer2: Offset(0.99, -0.72),
    tip: Offset(0.89, -0.89),
    inner1: Offset(0.64, -1.30),
    inner2: Offset(-0.52, -0.05),
  );
  static const left = AymaWingDef(
    outer1: Offset(-0.72, -0.05),
    outer2: Offset(-0.99, -0.72),
    tip: Offset(-0.89, -0.89),
    inner1: Offset(-0.64, -1.30),
    inner2: Offset(0.52, -0.05),
  );
}

/// Paints the two wing lobes mid-flap: [flap] 0..1 (eased by the caller) opens
/// the right lobe while the left closes, and vice versa — the out-of-phase
/// flutter, plus a whisper of whole-mark breathing and skew.
class AymaWingPainter extends CustomPainter {
  AymaWingPainter({required this.flap, required this.color});

  /// Eased 0..1 flap position. 0.5 is the symmetric rest pose.
  final double flap;

  final Color color;

  /// Lobe swing each side of rest (radians about the apex).
  static const _swing = 0.11;

  static Offset _xf(Offset apex, double r, Offset local, double angle) {
    final ca = math.cos(angle), sa = math.sin(angle);
    return apex +
        Offset(
          local.dx * ca - local.dy * sa,
          local.dx * sa + local.dy * ca,
        ) *
            r;
  }

  static Path _lobe(Offset apex, double r, AymaWingDef def, double angle) {
    final o1 = _xf(apex, r, def.outer1, angle);
    final o2 = _xf(apex, r, def.outer2, angle);
    final tip = _xf(apex, r, def.tip, angle);
    final i1 = _xf(apex, r, def.inner1, angle);
    final i2 = _xf(apex, r, def.inner2, angle);
    return Path()
      ..moveTo(apex.dx, apex.dy)
      ..cubicTo(o1.dx, o1.dy, o2.dx, o2.dy, tip.dx, tip.dy)
      ..cubicTo(i1.dx, i1.dy, i2.dx, i2.dy, apex.dx, apex.dy)
      ..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    if (s <= 0) return;
    final apex = Offset(size.width / 2, size.height * 0.76);
    final r = s * 0.40;

    // Whole-mark breath + lean, synced to the flap: barely-there at rest
    // (flap 0.5), peaking mid-travel either way.
    final travel = (flap - 0.5).abs() * 2; // 0 at rest, 1 at each extreme
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.skew(0.05 * (flap - 0.5) * 2, 0);
    final breathe = 1 + 0.03 * travel;
    canvas.scale(breathe);
    canvas.translate(-size.width / 2, -size.height / 2);

    final fill = Paint()..color = color;
    canvas.drawPath(
      _lobe(apex, r, AymaWingDef.right, _swing * (flap - 0.5) * 2),
      fill,
    );
    canvas.drawPath(
      _lobe(apex, r, AymaWingDef.left, _swing * ((1 - flap) - 0.5) * 2),
      fill,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(AymaWingPainter old) =>
      old.flap != flap || old.color != color;
}
