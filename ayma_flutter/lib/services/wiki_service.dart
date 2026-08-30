import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// One wiki page as the profile views render it (ARCHITECTURE.md §2.1).
class WikiPageView {
  const WikiPageView({
    required this.pageId,
    required this.pageType,
    required this.body,
    this.visibility = 'private',
  });

  final String pageId;
  final String pageType;

  /// `user_edits` when the user has overridden the page, otherwise `ai_body`.
  final String body;

  /// `public` | `private` — the owner can move a page between the two from
  /// the private view; `ai_only` pages never reach the client.
  final String visibility;

  bool get isPublic => visibility == 'public';
}

/// Read access to the user's own wiki (§2.1). `ai_body` is backend-authored;
/// the client only ever *reads* it here (edits go through the conversational
/// editor in Step 29). `ai_only` pages are never surfaced.
class WikiService {
  WikiService({FirebaseAuth? auth, FirebaseFirestore? firestore})
      : _auth = auth ?? FirebaseAuth.instance,
        _firestoreOverride = firestore;

  final FirebaseAuth _auth;
  final FirebaseFirestore? _firestoreOverride;

  FirebaseFirestore get _firestore =>
      _firestoreOverride ?? FirebaseFirestore.instance;

  String get _uid {
    final uid = _auth.currentUser?.uid;
    if (uid == null) throw StateError('No signed-in user.');
    return uid;
  }

  /// The private view: `public` + `private` pages, minus `user_hidden`,
  /// rendered as `user_edits ?? ai_body` (§2.1).
  Future<List<WikiPageView>> readPrivateWiki() =>
      _read(const {'public', 'private'});

  DocumentReference<Map<String, dynamic>> _pageDoc(String pageId) =>
      _firestore.doc('users/$_uid/wiki_pages/$pageId');

  /// Override a page's rendered text (§2.8 step 11). Writes `user_edits` only —
  /// `ai_body` is never touched.
  Future<void> setUserEdit(String pageId, String text) =>
      _pageDoc(pageId).set(editPayload(text), SetOptions(merge: true));

  /// Remove a page from the user's own views (`ai_body` retained).
  Future<void> hidePage(String pageId) =>
      _pageDoc(pageId).set(hidePayload(), SetOptions(merge: true));

  /// Drop the user's override/hide — the page renders from `ai_body` again.
  Future<void> resetPage(String pageId) =>
      _pageDoc(pageId).set(resetPayload(), SetOptions(merge: true));

  /// Move a page between `public` and `private` (§2.1). The security rules
  /// reject anything but those two values and never touch `ai_only`.
  Future<void> setVisibility(String pageId, String visibility) =>
      _pageDoc(pageId)
          .set(visibilityPayload(visibility), SetOptions(merge: true));

  // Payload builders — pure, so the write intent is unit-testable without a
  // live Firestore.
  static Map<String, dynamic> editPayload(String text) => {
        'user_edits': text.trim(),
        'user_hidden': false,
        'user_updated_at': FieldValue.serverTimestamp(),
      };

  static Map<String, dynamic> hidePayload() => {
        'user_hidden': true,
        'user_updated_at': FieldValue.serverTimestamp(),
      };

  static Map<String, dynamic> resetPayload() => {
        'user_edits': FieldValue.delete(),
        'user_hidden': FieldValue.delete(),
        'user_updated_at': FieldValue.serverTimestamp(),
      };

  static Map<String, dynamic> visibilityPayload(String visibility) {
    assert(visibility == 'public' || visibility == 'private');
    return {
      'visibility': visibility,
      'user_updated_at': FieldValue.serverTimestamp(),
    };
  }

  /// The public view: `public` pages only, same override rule (§2.1, Step 28).
  Future<List<WikiPageView>> readPublicWiki() => _read(const {'public'});

  Future<List<WikiPageView>> _read(Set<String> visibilities) async {
    // Never request `ai_only` pages — the security rules deny them and an
    // unconstrained query would be rejected outright (§9.2).
    final snap = await _firestore
        .collection('users/$_uid/wiki_pages')
        .where('visibility', whereIn: const ['public', 'private'])
        .get();
    return filterPages(
      [
        for (final doc in snap.docs) {'id': doc.id, ...doc.data()},
      ],
      visibilities,
    );
  }

  /// Pure view-model transform, shared by both views and unit-tested directly:
  /// drop `user_hidden` and out-of-tier pages (`ai_only` is never in a tier
  /// set), render `user_edits ?? ai_body`, sort by `(page_type, page_id)`.
  static List<WikiPageView> filterPages(
    List<Map<String, dynamic>> rows,
    Set<String> visibilities,
  ) {
    final pages = <WikiPageView>[];
    for (final data in rows) {
      if (data['user_hidden'] == true) continue;
      final visibility = (data['visibility'] as String?) ?? 'private';
      if (!visibilities.contains(visibility)) continue;

      final userEdits = (data['user_edits'] as String?)?.trim();
      final aiBody = (data['ai_body'] as String?)?.trim() ?? '';
      final body =
          (userEdits != null && userEdits.isNotEmpty) ? userEdits : aiBody;
      if (body.isEmpty) continue;

      pages.add(WikiPageView(
        pageId: (data['id'] as String?) ?? '',
        pageType: (data['page_type'] as String?) ?? 'misc',
        body: body,
        visibility: visibility,
      ));
    }
    pages.sort((a, b) {
      final t = a.pageType.compareTo(b.pageType);
      return t != 0 ? t : a.pageId.compareTo(b.pageId);
    });
    return pages;
  }
}
