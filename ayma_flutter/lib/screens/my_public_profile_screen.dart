import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../widgets/living_report_view.dart';
import 'public_profile_screen.dart' show ProfilePhotoHeader;

/// The founder's own self-view of their public profile — "Exactly what
/// others see when they open your profile." Two data sources, same as
/// `story_editor_screen.dart`'s own photo-gallery-then-Living-Report
/// pattern:
///  * The photo carousel + name/age/location header comes from
///    `GET /explore/profile/{uid}` ([ApiClient.publicProfile]) — the SAME
///    endpoint (and the SAME [ProfilePhotoHeader] widget) Explore's
///    other-viewer profile screen and the match-request screen
///    (`matches_screen.dart`) use, called here for the signed-in user's own
///    uid. Photos are display-only here: managing/reordering them already
///    has its own dedicated screen (`PhotoManagementScreen`, reachable from
///    the Profile tab's "Photos" row), so this screen doesn't duplicate that
///    affordance.
///  * The narrative content below it is the `story_public` Living Report
///    (`report_adapters.story_public_blocks`), rendered through the shared
///    [LivingReportView] — tappable for edit, as before. No Attributes
///    section here (§ founder 2026-09-21: that lives only on the Appearance
///    report now, alongside Face/Physique — see `appearance_report_screen.
///    dart`); a 2026-09-20 change had briefly converged one in here too.
///
/// Distinct from [PublicProfileScreen] (`/profile/user/:uid`) — that screen
/// is the Explore-facing "someone else's profile" card UI. Its non-self
/// content now renders through the same shared [LivingReportView] too, as
/// the read-only `public_profile` report type (§ founder convergence,
/// 2026-09-27) — but THIS screen stays exactly as it is: the owner's own
/// editable `story_public` view, reached only from the Profile tab's "My
/// public profile" row, always for the signed-in user's own uid.
///
/// See the GUARDRAIL in `living_report_view.dart`'s own file doc: the photo
/// carousel above is the only bespoke chrome this screen keeps (photos
/// aren't a block type), embedded ahead of [LivingReportView] in one shared
/// outer `ListView` (`shrinkWrap: true`) rather than a separate scroll
/// region — do not add bespoke rendering here for anything a block already
/// covers.
class MyPublicProfileScreen extends StatefulWidget {
  const MyPublicProfileScreen({super.key, this.apiClient, this.myUid});

  static const path = '/profile/me/public';

  final ApiClient? apiClient;

  /// Injectable for tests; production reads the signed-in Firebase uid.
  final String? myUid;

  @override
  State<MyPublicProfileScreen> createState() => _MyPublicProfileScreenState();
}

class _MyPublicProfileScreenState extends State<MyPublicProfileScreen> {
  late final ApiClient _api = widget.apiClient ?? ApiClient();
  late final String _uid = widget.myUid ?? _liveUid() ?? '';
  late final Future<PublicProfile> _photoFuture = _api.publicProfile(_uid);

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
      appBar: AppBar(title: const Text('My public profile')),
      body: ListView(
        padding: EdgeInsets.zero,
        children: [
          FutureBuilder<PublicProfile>(
            future: _photoFuture,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 48),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final p = snap.data;
              if (snap.hasError || p == null) {
                return const SizedBox.shrink();
              }
              return ProfilePhotoHeader(
                photos: p.photos,
                seed: p.uid.isEmpty ? _uid : p.uid,
                name: p.name,
                age: p.age,
                location: p.location,
                isOnline: p.isOnline,
              );
            },
          ),
          LivingReportView(
            reportType: 'story_public',
            reportId: _uid,
            apiClient: _api,
            emptyMessage: 'Nothing public yet.',
            shrinkWrap: true,
          ),
        ],
      ),
    );
  }
}
