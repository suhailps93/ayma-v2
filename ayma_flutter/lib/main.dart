import 'dart:async';

import 'package:country_picker/country_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:logging/logging.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'firebase_options.dart';
import 'routing/app_router.dart';
import 'screens/splash_screen.dart';
import 'services/accent_color_controller.dart';
import 'services/app_command_host.dart';
import 'services/app_command_service.dart';
import 'services/notification_service.dart';
import 'services/orb_animation_settings.dart';
import 'services/revenuecat_service.dart';
import 'services/sentry_config.dart';
import 'services/push_service.dart';
import 'services/theme_controller.dart';
import 'theme.dart';
import 'widgets/keyboard_dismiss.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // The whole app is designed portrait-only — a dating app is held upright, and
  // the transcript / composer / onboarding layouts assume a tall viewport.
  // Locking here means no screen can be caught in a broken landscape state.
  await SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

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

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // Crash reporting (audit Task 3): report crashes to Crashlytics so a
  // regression is found from the dashboard, not by someone tailing
  // `adb logcat`. Off in debug builds — every-day development crashes
  // shouldn't pollute production crash data.
  await FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(
    !kDebugMode,
  );
  FlutterError.onError = FirebaseCrashlytics.instance.recordFlutterFatalError;
  PlatformDispatcher.instance.onError = (error, stack) {
    FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
    return true;
  };

  await RevenueCatService.instance.init();
  FirebaseAuth.instance.authStateChanges().listen((user) {
    if (user == null) {
      unawaited(RevenueCatService.instance.logOut());
    } else {
      unawaited(RevenueCatService.instance.logIn(user.uid));
    }
  });

  AppCommandHost(AppCommandService.shared).attach();
  await themeControllerGlobal.load();
  await accentColorControllerGlobal.load();
  await orbAnimationSettingsGlobal.load();
  // Register this device for push (§7.2). Fire-and-forget — never blocks the
  // first frame, and failure is non-fatal.
  final push = PushService();
  unawaited(push.syncToken());
  // A tapped push notification (cold start or already running) opens the
  // screen its `deep_link` data names directly — a match request, a DM
  // thread, … — instead of leaving the tap to land wherever the app
  // defaults to (§7.6).
  unawaited(push.listenForTaps(
    navigate: (path) => unawaited(_pushWhenPastSplash(path)),
    resolveRoute: (deepLink) => deepLinkToRoute(
      deepLink,
      myUid: FirebaseAuth.instance.currentUser?.uid ?? '',
    ),
  ));
  if (sentryDsn.isEmpty) {
    runApp(const AymaApp());
    return;
  }
  // Sentry runs alongside Crashlytics: it chains the handlers installed above
  // rather than replacing them.
  await SentryFlutter.init(
    configureSentryOptions,
    appRunner: () => runApp(const AymaApp()),
  );
}

/// Opens [path] on top of the current screen — but on a cold start (a tapped
/// notification launched the app) the splash screen is still resolving the
/// session and will `go()` to the entry route, wiping anything pushed before
/// it. So wait until the router has left the splash, then push.
Future<void> _pushWhenPastSplash(String path) async {
  final provider = appRouter.routeInformationProvider;
  bool onSplash() => provider.value.uri.path == SplashScreen.path;
  if (onSplash()) {
    final done = Completer<void>();
    void check() {
      if (!onSplash() && !done.isCompleted) done.complete();
    }

    provider.addListener(check);
    try {
      await done.future.timeout(const Duration(seconds: 20));
    } on TimeoutException {
      return;
    } finally {
      provider.removeListener(check);
    }
  }
  appRouter.push(path);
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
      animation: Listenable.merge([
        themeControllerGlobal,
        accentColorControllerGlobal,
      ]),
      builder: (context, _) => MaterialApp.router(
        title: 'Ayma',
        debugShowCheckedModeBanner: false,
        theme: AymaTheme.lightWithAccent(accentColorControllerGlobal.color),
        darkTheme: AymaTheme.darkWithAccent(accentColorControllerGlobal.color),
        themeMode: themeControllerGlobal.mode,
        // For the country-code picker's search UI.
        localizationsDelegates: const [
          CountryLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        routerConfig: appRouter,
        // App-wide "tap outside a text field to dismiss the keyboard" —
        // iOS keyboards have no dismiss key (founder issue). A pure
        // pointer-event observer, so it cannot steal or delay any tap in
        // the tree — see [KeyboardDismissOnTap]'s doc.
        builder: (context, child) =>
            KeyboardDismissOnTap(child: child ?? const SizedBox.shrink()),
        // The persistent bottom nav bar is wired per-route in
        // `routing/app_router.dart` (`NavBarShell`), not here — it needs to
        // live *inside* each routed page so it rides the same Navigator
        // Overlay stack as the screen (so an open bottom sheet/dialog covers
        // it too), which a wrapper at this level, above the whole `Router`,
        // could not do. See `widgets/nav_bar_shell.dart`'s doc.
      ),
    );
  }
}
