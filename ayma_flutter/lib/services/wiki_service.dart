import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// One wiki page as the profile views render it (ARCHITECTURE.md §2.1).
class WikiPageView {
  const WikiPageView({
    required this.pageId,
    required this.pageType,
    required this.body,
  });

  final String pageId;
  final String pageType;

  /// `user_edits` when the user has overridden the page, otherwise `ai_body`.
  final String body;
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

  /// The public view: `public` pages only, same override rule (§2.1, Step 28).
  Future<List<WikiPageView>> readPublicWiki() => _read(const {'public'});

  Future<List<WikiPageView>> _read(Set<String> visibilities) async {
    final snap =
        await _firestore.collection('users/$_uid/wiki_pages').get();
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
      ));
    }
    pages.sort((a, b) {
      final t = a.pageType.compareTo(b.pageType);
      return t != 0 ? t : a.pageId.compareTo(b.pageId);
    });
    return pages;
  }
}
