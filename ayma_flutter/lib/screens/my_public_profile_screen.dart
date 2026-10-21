import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/api_client.dart';
import 'public_profile_screen.dart' show ProfileBody;
import '../widgets/ayma_back_button.dart';
import '../widgets/profile_photo_editor.dart';

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

  @override
  void initState() {
    super.initState();
    if (widget.openPhotoEditor) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _editPhotos());
    }
  }

  Future<void> _editPhotos() async {
    if (!mounted) return;
    await ProfilePhotoEditor.show(context);
    if (mounted) setState(() => _photoFuture = _api.publicProfile(_uid));
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
          IconButton(
            tooltip: 'Edit photos',
            icon: const Icon(Icons.add_a_photo_outlined),
            onPressed: _editPhotos,
          ),
        ],
      ),
      body: FutureBuilder<PublicProfile>(
        future: _photoFuture,
        builder: (context, snap) => ProfileBody(
          reportType: 'story_public',
          reportId: _uid,
          api: _api,
          profile: snap.data,
          headerLoading: snap.connectionState != ConnectionState.done,
        ),
      ),
    );
  }
}
