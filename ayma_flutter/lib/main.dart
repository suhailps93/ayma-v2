import 'dart:async';

import 'package:country_picker/country_picker.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:logging/logging.dart';

import 'firebase_options.dart';
import 'overlay_bubble.dart';
import 'routing/app_router.dart';
import 'services/push_service.dart';
import 'services/theme_controller.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // The whole app is designed portrait-only — a dating app is held upright, and
  // the transcript / composer / onboarding layouts assume a tall viewport.
  // Locking here means no screen can be caught in a broken landscape state.
  await SystemChrome.setPreferredOrientations(
    const [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown],
  );

  // Route LiveKit's internal client logs (Logger 'livekit', which propagates
  // to the root logger) to the debug console so a broken voice connect is
  // diagnosable from `adb logcat -s flutter`. Debug builds only. Do NOT call
  // livekit's setLoggingLevel — it sets a non-root logger level and throws
  // unless hierarchicalLoggingEnabled is on; the root level below covers it.
  if (kDebugMode) {
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen(
      (r) => debugPrint('[${r.loggerName}] ${r.level.name}: ${r.message}'),
    );
  }

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  await themeControllerGlobal.load();
  // Register this device for push (§7.2). Fire-and-forget — never blocks the
  // first frame, and failure is non-fatal.
  unawaited(PushService().syncToken());
  runApp(const AymaApp());
}

/// Entry point for the floating call-overlay window (Android only, F4). Runs
/// in its own separate Flutter engine — invoked by `flutter_overlay_window`'s
/// native side by this exact function name, never called directly from Dart.
/// See [CallOverlayService].
@pragma('vm:entry-point')
void overlayMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: CallOverlayBubble(),
  ));
}

/// Root of the Ayma app.
///
/// Step 4: `go_router` with placeholder screens (splash / preboarding / main
/// shell). Real redirect logic and the 4-tab shell come later.
class AymaApp extends StatelessWidget {
  const AymaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: themeControllerGlobal,
      builder: (context, _) => MaterialApp.router(
        title: 'Ayma',
        debugShowCheckedModeBanner: false,
        theme: AymaTheme.light,
        darkTheme: AymaTheme.dark,
        themeMode: themeControllerGlobal.mode,
        // For the country-code picker's search UI.
        localizationsDelegates: const [
          CountryLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        routerConfig: appRouter,
      ),
    );
  }
}
