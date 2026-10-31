import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../util/perf_log.dart';

final _log = Logger('dev_panel');

/// The `dev_panel` feature flag, live. The backend mirrors it from
/// `config/feature_flags` to `app_config/dev_panel` (`{enabled: bool}`), a doc
/// every client may read; this listens to it so a switch from the Developer
/// panel (or `scripts/flags.py`) shows up without a restart.
///
/// A missing doc, missing field or non-bool value means ON (the flag's
/// default); only a literal `enabled: false` turns it off. A listener error
/// keeps the last known value.
class DevPanelFlag {
  DevPanelFlag._();

  static final DevPanelFlag instance = DevPanelFlag._();

  static const collection = 'app_config';
  static const docId = 'dev_panel';

  /// Whether the Developer panel and dev-facing AI annotations are on.
  final ValueNotifier<bool> enabled = ValueNotifier(true);

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _sub;

  static bool parse(Map<String, dynamic>? data) {
    final v = data?['enabled'];
    return v is bool ? v : true;
  }

  /// Starts (or restarts) listening to the flag doc.
  void listen(FirebaseFirestore db) {
    unawaited(_sub?.cancel());
    final docRef = db.collection(collection).doc(docId);
    _sub = docRef
        .snapshots()
        .listen(
          (snap) {
            PerfLog.firestoreSnapshot(
              path: docRef.path,
              isFromCache: snap.metadata.isFromCache,
              hasPendingWrites: snap.metadata.hasPendingWrites,
            );
            enabled.value = parse(snap.data());
          },
          onError: (Object e) => _log.warning('dev_panel flag listen failed: $e'),
        );
  }
}
