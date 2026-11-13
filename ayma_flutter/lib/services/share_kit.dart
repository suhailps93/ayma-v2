import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:share_plus/share_plus.dart';

import '../models/share_link.dart';
import 'api_client.dart';
import 'chat_inbox.dart';
import 'share_service.dart';

/// The reusable share kit (founder, 2026-11-08): ONE share mechanism for
/// every page in the app. A page builds a [ShareTarget] for the thing it
/// shows and hands it to the share sheet (`ayma_share_sheet.dart`), which
/// always offers the same two options — "Send to Ayma" and
/// "Send externally" — so no page keeps its own share flow.
///
/// REGISTERING A NEW TARGET KIND — a page supplies:
/// - [ShareTarget.kind]: the kind string (`profile`, `story`, …). The
///   same string names the kind in the chat's shared-card rendering and,
///   for public kinds, in the backend registries (`page_share.py` for
///   `/p/` links, `share.py`'s shareable types for `/s/` reports).
/// - [ShareTarget.title]: the target's REAL subject ("Dillu", never a
///   generic page name) — shown on the sheet and on the chat card.
/// - [ShareTarget.thumbnailUrl]: the card image when the kind has one
///   (profile picture, story image, report subject image, …), else ''.
/// - [ShareTarget.route]: where tapping the chat card opens the target.
/// - [ShareTarget.aymaKickoff]: the context hand-off "Send to Ayma"
///   pushes — the whole context of the target rides with the message and
///   renders as the reply-style card above it (never a pin).
/// - [ShareTarget.audience]: `public` when an external link may exist
///   for the kind, `aymaOnly` when it must never leave the app.
///
/// AYMA-ONLY KINDS ARE ENFORCED HERE, NOT JUST HIDDEN IN THE UI: for an
/// `aymaOnly` target, [AymaShare.shareExternally] throws before any link
/// is composed, any snapshot is created or any system sheet opens — and
/// the backend has no snapshot builder, route or landing for the kind
/// either. Your Story (`story`) and a human chat (`conversation`) are the
/// Ayma-only kinds.
enum ShareAudience { public, aymaOnly }

class ShareTarget {
  const ShareTarget({
    required this.kind,
    required this.id,
    required this.title,
    required this.typeLabel,
    required this.route,
    required this.audience,
    required this.aymaKickoff,
    this.thumbnailUrl = '',
    this.externalOverride,
  });

  /// The kind string — see the class doc for what registers under it.
  final String kind;

  /// The target's own id (a uid for a profile, a report id for a report).
  /// External payloads are always built from THIS exact id — the record
  /// the user opened — never re-resolved by pair or person.
  final String id;

  /// The target's real subject/title, as shown on the sheet and card.
  final String title;

  /// Short type label for the card ("Profile", "Story", "Web finding").
  final String typeLabel;

  /// In-app route the chat card opens when tapped.
  final String route;

  /// Whether an external link may ever exist for this target.
  final ShareAudience audience;

  /// The thumbnail image URL for the card, or '' when the kind has none.
  final String thumbnailUrl;

  /// Builds the "Send to Ayma" hand-off: the kickoff that carries the
  /// target's whole context into the Ayma chat.
  final ChatKickoff Function() aymaKickoff;

  /// Kinds whose external share is a rendered artifact rather than a
  /// link (the Appearance report's image card) supply their own external
  /// action here; it runs with the page's context after the sheet closes.
  /// Null for link kinds.
  final Future<void> Function(BuildContext context)? externalOverride;

  bool get canShareExternally => audience == ShareAudience.public;
}

/// Thrown when an external share is attempted for an Ayma-only target —
/// the kit refuses before anything is composed or created.
class ShareKitException implements Exception {
  ShareKitException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The two share paths every target goes through. Injectable seams
/// ([systemShare], [reportShare]) keep widget tests off the platform
/// channels and the network.
class AymaShare {
  AymaShare({
    ApiClient? api,
    ShareService? reportShares,
    http.Client? httpClient,
    Future<void> Function(ShareParams params)? systemShare,
  })  : // The public parameter names intentionally differ from the
        // private fields they seed.
        // ignore: prefer_initializing_formals
        _api = api,
        // ignore: prefer_initializing_formals
        _reportShares = reportShares,
        // ignore: prefer_initializing_formals
        _httpClient = httpClient,
        _systemShare = systemShare ??
            ((p) async {
              await SharePlus.instance.share(p);
            });

  final ApiClient? _api;
  final ShareService? _reportShares;
  final http.Client? _httpClient;
  final Future<void> Function(ShareParams params) _systemShare;

  late final ApiClient api = _api ?? ApiClient();
  late final ShareService _reports =
      _reportShares ?? ShareService(api: api, httpClient: _httpClient);

  /// "Send to Ayma": stage the target's card above the Ayma chat composer
  /// as an un-sent draft attachment. The message leaves only when the
  /// user taps send; no canned opener is sent or pre-filled. Navigation
  /// to the chat is the sheet's job.
  void sendToAyma(ShareTarget target) {
    ChatInbox.instance.push(target.aymaKickoff());
  }

  /// Creates the external link for a link kind. Refuses Ayma-only kinds
  /// (throws [ShareKitException]) and kinds with no link path.
  Future<LinkShare> createExternalLink(ShareTarget target) async {
    if (!target.canShareExternally) {
      throw ShareKitException(
          '${target.typeLabel} can only be sent to Ayma — it has no external link.');
    }
    if (target.kind != 'profile') {
      throw ShareKitException(
          'No link path is registered for ${target.kind} shares.');
    }
    return api.createLinkShare(target.kind, target.id);
  }

  /// "Send externally": compose the target's external share and hand it
  /// to the system share sheet.
  ///
  /// - `profile` → a `justabot.info/p/<token>` link (public snapshot;
  ///   opens the profile in the app when installed, else routes by
  ///   platform to the stores).
  /// - `deep_dive` / `match` → the existing `/s/<token>` report snapshot
  ///   with its rendered card, built from the exact report id the user
  ///   opened ([ShareTarget.id] — never re-resolved by pair/person).
  /// - kinds with an [ShareTarget.externalOverride] (Appearance) → the
  ///   page's own rendered-artifact share.
  /// - Ayma-only kinds → throws before anything is composed or created.
  Future<void> shareExternally(
    BuildContext context,
    ShareTarget target,
  ) async {
    if (!target.canShareExternally) {
      throw ShareKitException(
          '${target.typeLabel} can only be sent to Ayma — it has no external link.');
    }
    final override = target.externalOverride;
    if (override != null) {
      await override(context);
      return;
    }
    if (target.kind == 'deep_dive' || target.kind == 'match') {
      final share = await _reports.create(target.kind, target.id);
      // The rendered link-preview card rides along when it downloads;
      // the link text is shared either way (the old sheet's behavior).
      XFile? file;
      try {
        file = XFile((await _reports.downloadCard(share)).path,
            mimeType: 'image/png');
      } on Exception {
        file = null;
      }
      await _systemShare(ShareParams(
        text: share.message,
        subject: share.title,
        files: file == null ? null : [file],
      ));
      return;
    }
    final link = await createExternalLink(target);
    await _systemShare(ShareParams(text: link.message, subject: link.title));
  }
}

/// A `/p/` target that arrived while signed out: the resolved in-app
/// route, stashed by the link screen and drained by the router's auth
/// listener once sign-in completes (the same pattern as DeepLinkQueue).
class PendingPageShare {
  PendingPageShare._();

  static String _path = '';

  static void stash(String path) => _path = path;

  /// Stash a raw page token (e.g. from the Play install referrer) by routing
  /// it through the `/p/<token>` deep-link route on drain.
  static void stashToken(String token) {
    final t = token.trim();
    if (t.isNotEmpty) _path = '/p/$t';
  }

  static String take() {
    final p = _path;
    _path = '';
    return p;
  }

  static bool get hasPending => _path.isNotEmpty;

  /// Test seam: forget any stashed route.
  static void resetForTest() => _path = '';
}

/// Factories for the target kinds registered today. A future page adds
/// its kind here (plus its card case in the chat and, for public kinds,
/// its backend builder) — the sheet and the two paths don't change.
class ShareTargets {
  ShareTargets._();

  /// Another user's (or your own) profile — public kind, `/p/` link.
  static ShareTarget profile({
    required String uid,
    required String name,
    String photoUrl = '',
    bool editSelf = false,
  }) {
    final title = name.trim().isEmpty ? 'Profile' : name.trim();
    return ShareTarget(
      kind: 'profile',
      id: uid,
      title: title,
      typeLabel: 'Profile',
      route: '/profile/user/$uid',
      audience: ShareAudience.public,
      thumbnailUrl: photoUrl,
      aymaKickoff: () => ChatKickoff.draftAbout(
        targetUid: uid,
        label: title,
        shareKind: 'profile',
        photoUrl: photoUrl,
        editSelf: editSelf,
      ),
    );
  }

  /// Your Story — AYMA-ONLY. The Story page is private: no external
  /// link, snapshot or public route exists for this kind, in the kit or
  /// on the backend. The card thumbnail is the story's own image.
  static ShareTarget story({
    required String uid,
    String imageUrl = '',
  }) =>
      ShareTarget(
        kind: 'story',
        id: uid,
        title: 'Your Story',
        typeLabel: 'Story',
        route: '/profile/wiki',
        audience: ShareAudience.aymaOnly,
        thumbnailUrl: imageUrl,
        aymaKickoff: () => ChatKickoff.draftAbout(
          targetUid: uid,
          label: 'Your Story',
          shareKind: 'story',
          photoUrl: imageUrl,
        ),
      );

  /// A human DM conversation — AYMA-ONLY. A chat with another person never
  /// leaves the app: no external link, snapshot or public route exists for
  /// this kind, in the kit or on the backend. The card's subject is the chat
  /// partner, the thumbnail their photo, and tapping it opens the thread
  /// (`/dm/<threadId>`). "Send to Ayma" stages the reply-style card and
  /// waits; the context rides by reference only (the thread id in
  /// [ChatKickoff.refId]) and Ayma pulls the messages herself — the client
  /// never ships the message content (founder 2026-11-09, reference not
  /// content).
  static ShareTarget conversation({
    required String threadId,
    required String otherUid,
    required String otherName,
    String otherPhoto = '',
  }) {
    final name = otherName.trim();
    return ShareTarget(
      kind: 'conversation',
      id: threadId,
      title: name.isEmpty ? 'Your chat' : 'Your chat with $name',
      typeLabel: 'Chat',
      route: '/dm/$threadId',
      audience: ShareAudience.aymaOnly,
      thumbnailUrl: otherPhoto,
      aymaKickoff: () => ChatKickoff.draftAbout(
        targetUid: otherUid,
        label: name.isEmpty ? 'them' : name,
        shareKind: 'conversation',
        photoUrl: otherPhoto,
        refId: threadId,
      ),
    );
  }

  /// A web research (deep dive) report — public kind, external via the
  /// existing `/s/` snapshot of THIS report id.
  static ShareTarget webResearch({
    required String reportId,
    required String subjectUid,
    required String subjectName,
    String subjectImage = '',
  }) {
    final name = subjectName.trim();
    return ShareTarget(
      kind: 'deep_dive',
      id: reportId,
      title: name.isEmpty ? 'Web research' : 'Web research on $name',
      typeLabel: 'Web finding',
      route: '/deep-dive/$reportId',
      audience: ShareAudience.public,
      thumbnailUrl: subjectImage,
      aymaKickoff: () => ChatKickoff.draftAbout(
        targetUid: subjectUid,
        label: name.isEmpty ? 'them' : name,
        shareKind: 'deep_dive',
        photoUrl: subjectImage,
        refId: reportId,
      ),
    );
  }

  /// A match / compatibility report — public kind, external via the
  /// existing `/s/` snapshot of THIS match id.
  static ShareTarget matchReport({
    required String matchId,
    required String otherUid,
    required String otherName,
    String otherPhoto = '',
  }) {
    final name = otherName.trim();
    return ShareTarget(
      kind: 'match',
      id: matchId,
      title: name.isEmpty ? 'Match report' : 'Match report with $name',
      typeLabel: 'Match report',
      route: '/match/$matchId',
      audience: ShareAudience.public,
      thumbnailUrl: otherPhoto,
      aymaKickoff: () => ChatKickoff.draftAbout(
        targetUid: otherUid,
        label: name.isEmpty ? 'them' : name,
        shareKind: 'match',
        photoUrl: otherPhoto,
        refId: matchId,
      ),
    );
  }

  /// The Appearance report — public kind; the external share is the
  /// rendered report card image (the page supplies [externalOverride],
  /// which renders the CURRENT run's card), and the chat card's
  /// thumbnail is that card's hero photo.
  static ShareTarget appearance({
    required String uid,
    required String title,
    String photoUrl = '',
    String reportVersion = '',
    Future<void> Function(BuildContext context)? externalOverride,
  }) =>
      ShareTarget(
        kind: 'appearance',
        id: uid,
        title: title,
        typeLabel: 'Appearance report',
        route: '/appearance/$uid',
        audience: ShareAudience.public,
        thumbnailUrl: photoUrl,
        externalOverride: externalOverride,
        aymaKickoff: () => ChatKickoff.draftAbout(
          targetUid: uid,
          label: title,
          shareKind: 'appearance',
          photoUrl: photoUrl,
          refId: uid,
          // The exact run the user opened (the report's created_at): the
          // record is replaced wholesale by a re-run, so the reference
          // carries the stamp and Ayma's pull can refuse a silent swap.
          refVersion: reportVersion,
        ),
      );
}
