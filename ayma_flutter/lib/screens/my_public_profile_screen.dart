import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../widgets/living_report_view.dart';

/// The founder's own self-view of their public profile — "Exactly what
/// others see when they open your profile," plus (converged in, § founder
/// direction 2026-09-20) the structured physical-attribute fields that used
/// to live on a separate "My public profile" self-view sourced from
/// `public_profile._physical_attributes`. Both now come from the SAME
/// `story_public` Living Report (`report_adapters.story_public_blocks`),
/// rendered through the ONE shared [LivingReportView].
///
/// Distinct from [PublicProfileScreen] (`/profile/user/:uid`) — that screen
/// is the Explore-facing "someone else's profile" card UI and is explicitly
/// out of scope for this convergence; it stays exactly as it was. This
/// screen is reached only from the Profile tab's own "My public profile"
/// row, always for the signed-in user's own uid.
class MyPublicProfileScreen extends StatelessWidget {
  const MyPublicProfileScreen({super.key, this.apiClient, this.myUid});

  static const path = '/profile/me/public';

  final ApiClient? apiClient;

  /// Injectable for tests; production reads the signed-in Firebase uid.
  final String? myUid;

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
    final uid = myUid ?? _liveUid() ?? '';
    return Scaffold(
      appBar: AppBar(title: const Text('My public profile')),
      body: LivingReportView(
        reportType: 'story_public',
        reportId: uid,
        apiClient: apiClient,
        emptyMessage: 'Nothing public yet.',
      ),
    );
  }
}
