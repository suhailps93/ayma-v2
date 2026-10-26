import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/api_client.dart';
import 'public_profile_screen.dart' show ProfileBody;
import '../widgets/ayma_back_button.dart';
import '../widgets/profile_photo_editor.dart';
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
  });

  static const path = '/profile/me/public';

  /// Opens this screen with the photo editor already showing — the target of
  /// every "change my photos" entry point (Appearance re-run, deep links,
  /// the text-chat `app_open_screen` tool).
  static const editPhotosPath = '/profile/me/public?edit=photos';

  final bool openPhotoEditor;

  final ApiClient? apiClient;

  /// Injectable for tests; production reads the signed-in Firebase uid.
  final String? myUid;

  @override
  State<MyPublicProfileScreen> createState() => _MyPublicProfileScreenState();
}

class _MyPublicProfileScreenState extends State<MyPublicProfileScreen> {
  late final ApiClient _api = widget.apiClient ?? ApiClient();
  late final String _uid = widget.myUid ?? _liveUid() ?? '';
  late Future<PublicProfile> _photoFuture = _api.publicProfile(_uid);
  int _reportRev = 0;
  int _pendingUpdates = 0;

  @override
  void initState() {
    super.initState();
    _loadPendingUpdates();
    if (widget.openPhotoEditor) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _editPhotos());
    }
  }

  Future<void> _editPhotos() async {
    if (!mounted) return;
    await ProfilePhotoEditor.show(context);
    if (mounted) setState(() => _photoFuture = _api.publicProfile(_uid));
  }

  /// How many individual changes Ayma suggests for the public profile (summed
  /// across sections). A failed lookup just hides the banner; the profile
  /// itself is unaffected.
  Future<void> _loadPendingUpdates() async {
    try {
      final list = await _api.profileProposals();
      final count = list.fold<int>(0, (n, p) => n + p.changes.length);
      if (mounted) setState(() => _pendingUpdates = count);
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
            tooltip: 'Edit photos',
            icon: const Icon(Icons.add_a_photo_outlined),
            onPressed: _editPhotos,
          ),
        ],
      ),
      body: Column(
        children: [
          if (_pendingUpdates > 0)
            MaterialBanner(
              content: Text(_pendingUpdates == 1
                  ? 'Ayma suggests an update to your public profile.'
                  : 'Ayma suggests $_pendingUpdates updates to your '
                      'public profile.'),
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
              ),
            ),
          ),
        ],
      ),
    );
  }
}
