import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'build_info.dart';
import 'release_notes.dart';

/// Build facts the brain needs to answer "what build are you running / what's
/// new". Read synchronously by the `/chat`, `/chat/stream` and `/bootstrap`
/// payload builders; empty until [loadBuildAwareness] completes.
class BuildAwareness {
  BuildAwareness._();

  static String appVersion = '';
  static String whatsNew = '';
}

/// Populates [BuildAwareness] once at startup. Best-effort: on failure the
/// fields stay empty and the payloads simply omit them.
Future<void> loadBuildAwareness() async {
  try {
    final info = await PackageInfo.fromPlatform();
    BuildAwareness.appVersion = formatVersionString(
        version: info.version, buildNumber: info.buildNumber);
    BuildAwareness.whatsNew = latestReleaseNotesBody();
  } catch (e) {
    debugPrint('build awareness unavailable: $e');
  }
}
