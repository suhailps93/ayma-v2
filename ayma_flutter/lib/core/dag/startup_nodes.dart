import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../firebase_options.dart';
import '../../models/boot_config.dart';
import '../../routing/app_router.dart';
import '../../routing/entry.dart';
import '../../screens/splash_screen.dart';
import '../../services/accent_color_controller.dart';
import '../../services/api_client.dart';
import '../../services/app_command_host.dart';
import '../../services/app_command_service.dart';
import '../../services/auth_service.dart';
import '../../services/biometric_consent.dart';
import '../../services/deep_link_queue.dart';
import '../../services/dev_panel_session.dart';
import '../../services/error_reporting.dart';
import '../../services/meta_integrations.dart';
import '../../services/orb_animation_settings.dart';
import '../../services/push_service.dart';
import '../../services/report_cache.dart';
import '../../services/revenuecat_service.dart';
import '../../services/screen_capture.dart';
import '../../services/sentry_config.dart';
import '../../services/theme_controller.dart';
import '../../widgets/ask_ayma_overlay.dart';
import '../../widgets/graceful_error.dart';
import 'launch_intent_resolver.dart';
import 'startup_dag.dart';

/// Catalog of node factories for the 19 startup nodes defining the parallel DAG.
class StartupNodes {
  StartupNodes._();

  /// N1: Engine Binding — WidgetsFlutterBinding.ensureInitialized()
  static StartupNode<void> createEngineBindingNode() {
    return StartupNode<void>(
      id: 'N1:engine_binding',
      dependencies: {},
      critical: true,
      action: (ctx) async {
        WidgetsFlutterBinding.ensureInitialized();
      },
    );
  }

  /// N2: Orientation Lock — SystemChrome.setPreferredOrientations
  static StartupNode<void> createOrientationNode() {
    return StartupNode<void>(
      id: 'N2:orientation_lock',
      dependencies: {'N1:engine_binding'},
      timeout: const Duration(milliseconds: 100),
      action: (ctx) async {
        await SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
        ]);
      },
    );
  }

  /// N3: Fatal Error Handlers — FlutterError.onError, PlatformDispatcher.instance.onError
  static StartupNode<void> createCrashlyticsFatalNode() {
    return StartupNode<void>(
      id: 'N3:crashlytics_fatal',
      dependencies: {'N1:engine_binding'},
      action: (ctx) async {
        FlutterError.onError = (details) {
          // Debug/profile: dump the full exception + stack to the console.
          // Overriding onError here replaces Flutter's own default console
          // dump, which otherwise hid every non-layout build-throw from
          // `adb logcat` (J1: the self web-search /deep-dive render). Gated
          // off release, so release stays silent + Crashlytics-only.
          dumpBuildErrorToConsole(details, source: 'FlutterError.onError');
          logLayoutErrorLoudly(details);
          try {
            FirebaseCrashlytics.instance.recordFlutterFatalError(details);
          } catch (_) {}
        };
        PlatformDispatcher.instance.onError = (error, stack) {
          dumpAsyncErrorToConsole(error, stack,
              source: 'PlatformDispatcher.onError');
          try {
            FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
          } catch (_) {}
          return true;
        };
        ErrorWidget.builder = gracefulErrorWidget;
      },
    );
  }

  /// N4: SharedPreferences Preload
  static StartupNode<SharedPreferences> createPrefsPreloadNode() {
    return StartupNode<SharedPreferences>(
      id: 'N4:prefs_preload',
      dependencies: {'N1:engine_binding'},
      timeout: const Duration(milliseconds: 1000),
      action: (ctx) async {
        final prefs = await SharedPreferences.getInstance();
        ctx.put('prefs', prefs);
        return prefs;
      },
    );
  }

  /// N5: UI Controllers Hydration from SharedPreferences
  ///
  /// Depends on N7:firebase_core: the first access to `accentColorControllerGlobal`
  /// (and the other global controllers) lazily constructs it, and
  /// `AccentColorController()` builds a `ProfileService()` whose constructor binds
  /// `FirebaseAuth.instance`. Running this before N7 throws [core/no-app].
  static StartupNode<void> createUIControllersNode() {
    return StartupNode<void>(
      id: 'N5:ui_controllers',
      dependencies: {'N4:prefs_preload', 'N7:firebase_core'},
      action: (ctx) async {
        final prefs = ctx.get<SharedPreferences>('prefs');
        themeControllerGlobal.loadFromPrefs(prefs);
        accentColorControllerGlobal.loadFromPrefs(prefs);
        orbAnimationSettingsGlobal.loadFromPrefs(prefs);
        MetaIntegrations.loadFromPrefs(prefs);
        ReportCache.instance.hydrateFromPrefs(prefs);
      },
    );
  }

  /// N6: Launch Intent Resolver — extracts intent from FCM initial tap or native channel
  /// Note: M2 edge correction requires N7:firebase_core so FCM initialMessage is safe.
  static StartupNode<LaunchIntent> createLaunchIntentNode() {
    return StartupNode<LaunchIntent>(
      id: 'N6:launch_intent',
      dependencies: {'N1:engine_binding', 'N7:firebase_core'},
      timeout: const Duration(milliseconds: 1000),
      action: (ctx) async {
        final intent = await LaunchIntentResolver.extract();
        ctx.put('launch_intent', intent);
        return intent;
      },
    );
  }

  /// N7: Firebase Core Init
  static StartupNode<void> createFirebaseCoreNode() {
    return StartupNode<void>(
      id: 'N7:firebase_core',
      dependencies: {'N1:engine_binding'},
      timeout: const Duration(seconds: 3),
      action: (ctx) async {
        try {
          await Firebase.initializeApp(
            options: DefaultFirebaseOptions.currentPlatform,
          );
        } catch (e) {
          debugPrint('[N7:firebase_core] initializeApp warning: $e');
        }
      },
    );
  }

  /// N8: Mount Root Widget (runApp)
  static StartupNode<void> createFirstFrameMountNode({Widget? app}) {
    return StartupNode<void>(
      id: 'N8:first_frame_mount',
      dependencies: {
        'N2:orientation_lock',
        'N3:crashlytics_fatal',
        'N5:ui_controllers',
        'N7:firebase_core',
      },
      critical: true,
      action: (ctx) async {
        // N12's optimistic cached-route navigation must not leave the splash
        // before its minimum dwell has elapsed since this mount (loader
        // retest, Nov 2026: the wake line never surfaced otherwise).
        ctx.put(
          'first_frame_mount_at_ms',
          DateTime.now().millisecondsSinceEpoch,
        );
        runApp(app ?? const SizedBox.shrink());
      },
    );
  }

  /// N9: Auth Session Restore
  static StartupNode<User?> createAuthSessionRestoreNode({AuthService? authService}) {
    return StartupNode<User?>(
      id: 'N9:auth_session_restore',
      dependencies: {'N7:firebase_core'},
      action: (ctx) async {
        final auth = authService ?? AuthService.instance;
        final user = await auth.ensureAuthReady();
        ctx.put('auth_user', user);
        return user;
      },
    );
  }

  /// N10: BootConfig Cache Read
  static StartupNode<BootConfig?> createBootConfigReadNode() {
    return StartupNode<BootConfig?>(
      id: 'N10:boot_config_read',
      dependencies: {'N4:prefs_preload', 'N9:auth_session_restore'},
      timeout: const Duration(milliseconds: 300),
      action: (ctx) async {
        final user = ctx.get<User?>('auth_user');
        if (user == null || user.uid.isEmpty) return null;
        final config = await ReportCache.instance.readBootConfig(user.uid);
        ctx.put('boot_config', config);
        return config;
      },
    );
  }

  /// N11: RevenueCat Deferred Init
  ///
  /// Depends on N7:firebase_core: `listenForEntitlementChanges(ApiClient())`
  /// constructs an `ApiClient`, whose constructor binds `FirebaseAuth.instance`.
  /// Running this before N7 throws [core/no-app] and leaves RevenueCat (and so
  /// subscriptions) uninitialized at boot.
  static StartupNode<void> createRevenueCatInitNode() {
    return StartupNode<void>(
      id: 'N11:revenuecat_init',
      dependencies: {'N1:engine_binding', 'N7:firebase_core'},
      timeout: const Duration(seconds: 4),
      action: (ctx) async {
        await RevenueCatService.instance.initDeferred();
        RevenueCatService.instance.listenForEntitlementChanges(ApiClient());
      },
    );
  }

  /// N12: Destination Route Resolution
  static StartupNode<void> createDestinationRoutingNode({GoRouter? router}) {
    return StartupNode<void>(
      id: 'N12:destination_routing',
      dependencies: {
        'N6:launch_intent',
        'N8:first_frame_mount',
        'N9:auth_session_restore',
        'N10:boot_config_read',
      },
      action: (ctx) async {
        final intent = ctx.contains('launch_intent')
            ? ctx.get<LaunchIntent>('launch_intent')
            : const IconLaunchIntent();
        final effectiveRouter = router ?? appRouter;

        if (intent is! IconLaunchIntent) {
          await DeepLinkQueue.instance.handleIntent(
            intent,
            router: effectiveRouter,
            authService: AuthService.instance,
            navigate: (path) => effectiveRouter.go(path),
          );
          return;
        }

        final config = ctx.contains('boot_config')
            ? ctx.get<BootConfig?>('boot_config')
            : null;
        if (config != null && config.entryRoute.isNotEmpty) {
          // Same minimum dwell as the splash's own optimistic navigation:
          // without it this `go` can land pre-first-frame and the wake line
          // never paints at all. Absent mount time (a node under test, never
          // in production) means no wait.
          final mountAtMs = ctx.getOrNull<int>('first_frame_mount_at_ms');
          if (mountAtMs != null) {
            final wait = SplashScreen.dwellRemaining(
              shownAtMs: mountAtMs,
              nowMs: DateTime.now().millisecondsSinceEpoch,
            );
            if (wait > Duration.zero) {
              await Future<void>.delayed(wait);
            }
          }
          effectiveRouter.go(config.entryRoute);
          DeepLinkQueue.instance.notifyNavigationSettled();
        }
      },
    );
  }

  /// N13: RevenueCat Auth Bind
  static StartupNode<void> createRevenueCatAuthBindNode() {
    return StartupNode<void>(
      id: 'N13:revenuecat_auth_bind',
      dependencies: {'N9:auth_session_restore', 'N11:revenuecat_init'},
      action: (ctx) async {
        final user = ctx.get<User?>('auth_user');
        if (user != null && !user.isAnonymous) {
          await RevenueCatService.instance.logIn(user.uid);
        }
      },
    );
  }

  /// N14: Background Refresher Contract
  static StartupNode<void> createBackgroundRefresherNode({ApiClient? apiClient}) {
    return StartupNode<void>(
      id: 'N14:background_refresher',
      dependencies: {'N9:auth_session_restore', 'N12:destination_routing'},
      timeout: const Duration(seconds: 8),
      action: (ctx) async {
        final user = ctx.get<User?>('auth_user');
        if (user == null || user.isAnonymous) return;
        try {
          final client = apiClient ?? ApiClient();
          final result = await client.bootstrap(sessionId: '');
          // A soft-deleted account must be routed to recovery, not into the
          // app (B9, §3.6). This background path previously ignored
          // `recovery_required`, so a resumed deleted session fell through to
          // its cached entry route (the shell), whose consent-gated calls then
          // stranded it on the consent screen. Signal recovery — the router
          // redirects to /recover — and don't cache an app entry route for it.
          if (result.recoveryRequired) {
            RecoveryRequiredState.instance.markRequired();
            return;
          }
          final config = BootConfig(
            uid: user.uid,
            sessionMode: result.sessionMode,
            entryRoute: entryRouteFor(result.sessionMode),
            cachedAtEpochMs: DateTime.now().millisecondsSinceEpoch,
          );
          await ReportCache.instance.writeBootConfig(user.uid, config);
        } catch (e) {
          debugPrint('[N14:background_refresher] Error: $e');
        }
      },
    );
  }

  /// N15: Crashlytics Native Toggle
  static StartupNode<void> createCrashlyticsEnableNode() {
    return StartupNode<void>(
      id: 'N15:crashlytics_enable',
      dependencies: {'N7:firebase_core', 'N8:first_frame_mount'},
      action: (ctx) async {
        try {
          await FirebaseCrashlytics.instance
              .setCrashlyticsCollectionEnabled(!kDebugMode);
        } catch (_) {}
      },
    );
  }

  /// N16: Push Token Sync
  static StartupNode<void> createPushTokenSyncNode({PushService? pushService}) {
    return StartupNode<void>(
      id: 'N16:push_token_sync',
      dependencies: {'N7:firebase_core', 'N9:auth_session_restore'},
      action: (ctx) async {
        final user = ctx.get<User?>('auth_user');
        if (user != null && !user.isAnonymous) {
          final service = pushService ?? PushService();
          await service.syncToken();
        }
      },
    );
  }

  /// N17: Dev Observers & Attaches
  static StartupNode<void> createDevObserversNode({GoRouter? router}) {
    return StartupNode<void>(
      id: 'N17:dev_observers',
      dependencies: {'N8:first_frame_mount'},
      action: (ctx) async {
        WidgetsBinding.instance.addObserver(DevPanelSession.instance);
        AppCommandHost(AppCommandService.shared).attach();
        final effectiveRouter = router ?? appRouter;
        ScreenCapture.instance.attach(effectiveRouter, beforeAct: () async {
          if (!isAymaSheetOpen) return;
          screenPopupTracker.navigator?.pop();
          await pendingAymaSheet;
          await Future<void>.delayed(const Duration(milliseconds: 400));
        });
      },
    );
  }

  /// N18: Sentry SDK Init
  static StartupNode<void> createSentryInitNode() {
    return StartupNode<void>(
      id: 'N18:sentry_init',
      dependencies: {
        'N4:prefs_preload',
        'N7:firebase_core',
        'N8:first_frame_mount',
      },
      timeout: const Duration(seconds: 5),
      action: (ctx) async {
        if (sentryDsn.isEmpty || !sentryCompiledIn) return;
        final prefs = ctx.get<SharedPreferences>('prefs');
        final sentryFlag = SentryFlag.loadFromPrefs(prefs);
        if (!sentryShouldRun(sentryFlag)) return;
        try {
          await SentryFlutter.init(
            (options) => configureSentryOptions(options, sentryFlag),
          );
        } catch (e) {
          debugPrint('[N18:sentry_init] error: $e');
        }
      },
    );
  }

  /// N19: Remote Sync (Meta, Sentry flags, Accent color)
  static StartupNode<void> createRemoteSyncNode() {
    return StartupNode<void>(
      id: 'N19:remote_sync',
      dependencies: {'N7:firebase_core'},
      action: (ctx) async {
        try {
          final db = FirebaseFirestore.instance;
          unawaited(MetaIntegrations.refresh(db));
          unawaited(SentryFlag.refresh(db));
          final user = ctx.contains('auth_user') ? ctx.get<User?>('auth_user') : null;
          if (user != null && !user.isAnonymous) {
            unawaited(accentColorControllerGlobal.syncRemoteIfMissing());
          }
        } catch (e) {
          debugPrint('[N19:remote_sync] error: $e');
        }
      },
    );
  }

  /// Builds a [StartupDAG] populated with all 19 nodes and explicit dependencies.
  static StartupDAG buildDefaultDAG({Widget? app, GoRouter? router}) {
    final dag = StartupDAG();
    dag.addNode(createEngineBindingNode());
    dag.addNode(createOrientationNode());
    dag.addNode(createCrashlyticsFatalNode());
    dag.addNode(createPrefsPreloadNode());
    dag.addNode(createUIControllersNode());
    dag.addNode(createLaunchIntentNode());
    dag.addNode(createFirebaseCoreNode());
    dag.addNode(createFirstFrameMountNode(app: app));
    dag.addNode(createAuthSessionRestoreNode());
    dag.addNode(createBootConfigReadNode());
    dag.addNode(createRevenueCatInitNode());
    dag.addNode(createDestinationRoutingNode(router: router));
    dag.addNode(createRevenueCatAuthBindNode());
    dag.addNode(createBackgroundRefresherNode());
    dag.addNode(createCrashlyticsEnableNode());
    dag.addNode(createPushTokenSyncNode());
    dag.addNode(createDevObserversNode(router: router));
    dag.addNode(createSentryInitNode());
    dag.addNode(createRemoteSyncNode());
    return dag;
  }
}
