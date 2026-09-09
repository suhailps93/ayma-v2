import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../routing/app_router.dart';
import 'app_context.dart';

/// While a voice call is live, Ayma can queue one UI command at
/// `users/{uid}/app_commands/pending` (backend `skills.app_control`). This
/// watches that doc, performs the navigation, and deletes it. Started/stopped
/// by [VoiceSessionController] so it only ever acts during a call.
class AppCommandService {
  AppCommandService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
    void Function(String path)? navigate,
  })  : _fsOverride = firestore,
        _authOverride = auth,
        _navigate = navigate ?? appRouter.push;

  final FirebaseFirestore? _fsOverride;
  final FirebaseAuth? _authOverride;
  final void Function(String path) _navigate;

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _sub;

  FirebaseFirestore get _db => _fsOverride ?? FirebaseFirestore.instance;
  FirebaseAuth get _auth => _authOverride ?? FirebaseAuth.instance;

  /// Begin watching. Idempotent, and a no-op if Firestore can't be reached
  /// (e.g. no Firebase in a unit test) — voice navigation just won't work.
  void start() {
    if (_sub != null) return;
    try {
      final uid = _auth.currentUser?.uid;
      if (uid == null) return;
      _sub = _db
          .doc('users/$uid/app_commands/pending')
          .snapshots()
          .listen(_onDoc, onError: (_) {});
    } catch (_) {
      // Firestore unavailable this session.
    }
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
  }

  void _onDoc(DocumentSnapshot<Map<String, dynamic>> snap) {
    final data = snap.data();
    if (data == null) return;
    handleCommand(data);
    snap.reference.delete().catchError((_) {}); // ack — one at a time
  }

  /// Route one command. Split out so it's testable without Firestore.
  @visibleForTesting
  void handleCommand(Map<String, dynamic> cmd) {
    switch (cmd['action'] as String? ?? '') {
      case 'navigate':
        final path = _pathFor(cmd['screen'] as String? ?? '');
        if (path != null) _navigate(path);
        break;
      case 'search_explore':
        AppContext.instance.pendingExploreQuery =
            (cmd['query'] as String? ?? '').trim();
        _navigate('/explore');
        break;
      case 'open_profile':
        final uid = (cmd['uid'] as String? ?? '').trim();
        if (uid.isNotEmpty) _navigate('/profile/user/$uid');
        break;
    }
  }

  String? _pathFor(String screen) {
    switch (screen) {
      case 'explore':
        return '/explore';
      case 'messages':
        return '/messages';
      case 'profile':
        return '/profile';
      case 'matches':
        return '/matches';
      case 'story':
        return '/profile/wiki';
      case 'settings':
        return '/settings';
    }
    return null;
  }
}
