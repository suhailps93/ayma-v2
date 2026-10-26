import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/photo_service.dart';
import 'public_profile_screen.dart' show ProfileBody;
import '../widgets/ayma_back_button.dart';
import '../widgets/ayma_toast.dart';
import '../widgets/inline_photo_carousel.dart';
import 'manual_profile_edit_screen.dart';
import 'profile_proposals_screen.dart';

/// The signed-in user's own "My public profile" page (You tab). It is the
/// reference look for every profile view: the whole content is the shared
/// [ProfileBody] (photo header from `GET /explore/profile/{uid}`, then the
/// editable `story_public` Living Report), and [PublicProfileScreen] renders
/// the very same widget for Explore and self-by-uid views. Add nothing
/// profile-rendering here; change [ProfileBody] instead.
class MyPublicProfileScreen extends StatefulWidget {
  const MyPublicProfileScreen({
    super.key,
    this.apiClient,
    this.myUid,
    this.openPhotoEditor = false,
    this.photoController,
  });

  static const path = '/profile/me/public';

  /// Opens this screen and immediately opens the gallery picker to add a photo
  /// — the target of every "change my photos" entry point (Appearance re-run,
  /// deep links, the text-chat `app_open_screen` tool). Managing existing
  /// photos (delete, reorder, set primary) is always available inline in the
  /// carousel here, so no separate editor is opened.
  static const editPhotosPath = '/profile/me/public?edit=photos';

  final bool openPhotoEditor;

  final ApiClient? apiClient;

  /// Injectable for tests; production reads the signed-in Firebase uid.
  final String? myUid;

  /// Injectable for tests; production builds its own from a [PhotoService].
  final InlinePhotoController? photoController;

  @override
  State<MyPublicProfileScreen> createState() => _MyPublicProfileScreenState();
}

class _MyPublicProfileScreenState extends State<MyPublicProfileScreen> {
  late final ApiClient _api = widget.apiClient ?? ApiClient();
  late final String _uid = widget.myUid ?? _liveUid() ?? '';
  late Future<PublicProfile> _photoFuture = _api.publicProfile(_uid);
  late final InlinePhotoController _photos = widget.photoController ??
      InlinePhotoController(service: PhotoService(api: _api));
  int _reportRev = 0;
  int _pendingUpdates = 0;

  @override
  void initState() {
    super.initState();
    _loadPendingUpdates();
    _photos.onCommitError = (m) {
      if (mounted) AymaToast.show(context, m, kind: AymaToastKind.error);
    };
    _photos.load();
    if (widget.openPhotoEditor) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _addPhotos());
    }
  }

  @override
  void dispose() {
    // We own the controller only when we built it ourselves.
    if (widget.photoController == null) _photos.dispose();
    super.dispose();
  }

  /// Pick and add photos to the public carousel (the "Add photo" tile and the
  /// app-bar camera button).
  Future<void> _addPhotos() async {
    final msg = await _photos.pickAndAdd();
    if (msg != null && msg.isNotEmpty && mounted) {
      AymaToast.show(context, msg, kind: AymaToastKind.warning);
    }
  }

  void _setPrimary(GridPhoto photo) => _photos.setPrimary(photo);

  /// Tapping a thumbnail's X: block if it's the only public photo, otherwise
  /// confirm — the primary action removes it from the public profile (kept
  /// privately for Ayma), with a secondary "Delete everywhere".
  Future<void> _confirmRemove(GridPhoto photo) async {
    if (_photos.photos.length <= 1) {
      AymaToast.show(
        context,
        'Your public profile needs at least one photo — add another first.',
        kind: AymaToastKind.warning,
      );
      return;
    }
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove this photo?'),
        content: const Text(
          'It comes off your public profile but stays private for Ayma — your '
          'face and body analysis keep it. Or delete it everywhere.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'cancel'),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'delete'),
            child: const Text('Delete everywhere'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'remove'),
            child: const Text('Remove from public'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (choice == 'remove') {
      _photos.removeFromPublic(photo);
      AymaToast.show(
        context,
        'Removed from your public profile.',
        kind: AymaToastKind.info,
        action: AymaToastAction(label: 'Undo', onPressed: _photos.undoRemove),
      );
    } else if (choice == 'delete') {
      await _confirmDeleteEverywhere(photo);
    }
  }

  Future<void> _confirmDeleteEverywhere(GridPhoto photo) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete everywhere?'),
        content: const Text(
          "This erases the photo and its analysis for good. This can't be "
          'undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete everywhere'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final done = await _photos.deletePermanent(photo);
    if (done && mounted) {
      AymaToast.show(context, 'Photo deleted.', kind: AymaToastKind.success);
    }
  }

  /// How many of Ayma's suggested rewrites await approval. A failed lookup
  /// just hides the banner; the profile itself is unaffected.
  Future<void> _loadPendingUpdates() async {
    try {
      final list = await _api.profileProposals();
      if (mounted) setState(() => _pendingUpdates = list.length);
    } on Object {
      if (mounted) setState(() => _pendingUpdates = 0);
    }
  }

  void _refreshProfile() {
    setState(() {
      _reportRev++;
      _photoFuture = _api.publicProfile(_uid);
    });
    _loadPendingUpdates();
  }

  Future<void> _editManually() async {
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => ManualProfileEditScreen(apiClient: _api)));
    if (saved == true && mounted) _refreshProfile();
  }

  Future<void> _reviewUpdates() async {
    await Navigator.of(context).push<void>(MaterialPageRoute(
        builder: (_) => ProfileProposalsScreen(apiClient: _api)));
    if (mounted) _refreshProfile();
  }

  String? _liveUid() {
    try {
      return FirebaseAuth.instance.currentUser?.uid;
    } catch (_) {
      // No Firebase app configured — never crash the whole screen over it.
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: const AymaBackButton(),
        title: const Text('My public profile'),
        actions: [
          // Capped so at large text or on a narrow window the label
          // ellipsizes instead of pushing the app bar past the screen edge.
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width * 0.4,
            ),
            child: TextButton(
              onPressed: _editManually,
              child: const Text(
                'Edit manually',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Add photo',
            icon: const Icon(Icons.add_a_photo_outlined),
            onPressed: _addPhotos,
          ),
        ],
      ),
      body: Column(
        children: [
          if (_pendingUpdates > 0)
            MaterialBanner(
              content: Text(_pendingUpdates == 1
                  ? 'Ayma suggests an update to your profile.'
                  : 'Ayma suggests $_pendingUpdates updates to your profile.'),
              actions: [
                TextButton(
                    onPressed: _reviewUpdates, child: const Text('Review')),
              ],
            ),
          Expanded(
            child: FutureBuilder<PublicProfile>(
              future: _photoFuture,
              builder: (context, snap) => ProfileBody(
                key: ValueKey(_reportRev),
                reportType: 'story_public',
                reportId: _uid,
                api: _api,
                profile: snap.data,
                headerLoading: snap.connectionState != ConnectionState.done,
                editing: InlinePhotoEditing(
                  controller: _photos,
                  onAddPhoto: _addPhotos,
                  onSetPrimary: _setPrimary,
                  onRemove: _confirmRemove,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
