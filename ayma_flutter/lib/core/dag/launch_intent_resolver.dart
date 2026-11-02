import 'dart:async';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'startup_dag.dart';

sealed class LaunchIntent {
  const LaunchIntent();
}

/// Normal cold start from application launcher icon.
class IconLaunchIntent extends LaunchIntent {
  const IconLaunchIntent();

  @override
  String toString() => 'IconLaunchIntent()';
}

/// Cold start targeting monetization / subscriptions.
class PaywallDeepLinkIntent extends LaunchIntent {
  final String targetPath; // '/profile/plan' or '/profile/usage/trial'
  final String? offeringId;
  const PaywallDeepLinkIntent({required this.targetPath, this.offeringId});

  @override
  String toString() => 'PaywallDeepLinkIntent(targetPath: $targetPath)';
}

/// Cold start targeting a direct message thread.
class DmDeepLinkIntent extends LaunchIntent {
  final String? threadId;
  final String? recipientUid;
  final Map<String, dynamic> rawPayload;
  const DmDeepLinkIntent({
    this.threadId,
    this.recipientUid,
    required this.rawPayload,
  });

  @override
  String toString() =>
      'DmDeepLinkIntent(threadId: $threadId, recipientUid: $recipientUid)';
}

/// Cold start targeting generic routes (e.g. /appearance/:id, /matches).
class GenericDeepLinkIntent extends LaunchIntent {
  final String targetPath;
  final Map<String, dynamic>? rawPayload;
  const GenericDeepLinkIntent({required this.targetPath, this.rawPayload});

  @override
  String toString() => 'GenericDeepLinkIntent(targetPath: $targetPath)';
}

class LaunchIntentResolver {
  static Future<LaunchIntent> extract({
    Future<Map<String, dynamic>?> Function()? fcmPayloadGetter,
    Future<String?> Function()? nativeChannelGetter,
  }) async {
    Map<String, dynamic>? data;
    try {
      if (fcmPayloadGetter != null) {
        data = await fcmPayloadGetter();
      } else {
        data = (await FirebaseMessaging.instance.getInitialMessage())?.data;
      }
    } catch (_) {}

    if (data == null || data.isEmpty) {
      try {
        String? link;
        if (nativeChannelGetter != null) {
          link = await nativeChannelGetter();
        } else {
          link = await const MethodChannel('ayma/push')
              .invokeMethod<String>('initialDeepLink');
        }
        if (link != null && link.isNotEmpty) {
          data = {'deep_link': link};
        }
      } catch (_) {}
    }

    if (data == null || data.isEmpty) {
      return const IconLaunchIntent();
    }

    return classify(data);
  }

  static LaunchIntent classify(Map<String, dynamic> data) {
    var deepLink = data['deep_link'] as String?;
    final type = data['type'] as String?;

    if (deepLink == null || deepLink.isEmpty) {
      final sender = data['sender_uid'] as String?;
      if (type == 'dm' && sender != null && sender.isNotEmpty) {
        return DmDeepLinkIntent(recipientUid: sender, rawPayload: data);
      }
      return const IconLaunchIntent();
    }

    if (deepLink == 'plan' ||
        deepLink == '/profile/plan' ||
        deepLink.startsWith('/profile/plan')) {
      return const PaywallDeepLinkIntent(targetPath: '/profile/plan');
    }
    if (deepLink == 'trial' ||
        deepLink == '/profile/usage/trial' ||
        deepLink.startsWith('/profile/usage/trial')) {
      return const PaywallDeepLinkIntent(targetPath: '/profile/usage/trial');
    }

    final dmThreadMatch = RegExp(r'^dm_thread/(.+)$').firstMatch(deepLink);
    if (dmThreadMatch != null) {
      return DmDeepLinkIntent(
          threadId: dmThreadMatch.group(1), rawPayload: data);
    }

    final profileMatch = RegExp(r'^profile/(.+)$').firstMatch(deepLink);
    if (profileMatch != null) {
      return DmDeepLinkIntent(
          recipientUid: profileMatch.group(1), rawPayload: data);
    }

    final matchReqMatch = RegExp(r'^match_request/(.+)$').firstMatch(deepLink);
    if (matchReqMatch != null) {
      return GenericDeepLinkIntent(
        targetPath: '/match-request/${matchReqMatch.group(1)}',
        rawPayload: data,
      );
    }

    final matchMatch = RegExp(r'^match/(.+)$').firstMatch(deepLink);
    if (matchMatch != null) {
      return GenericDeepLinkIntent(
        targetPath: '/match/${matchMatch.group(1)}',
        rawPayload: data,
      );
    }

    final deepDiveMatch = RegExp(r'^deep_dive/(.+)$').firstMatch(deepLink);
    if (deepDiveMatch != null) {
      return GenericDeepLinkIntent(
        targetPath: '/deep-dive/${Uri.encodeComponent(deepDiveMatch.group(1)!)}',
        rawPayload: data,
      );
    }

    final appearanceMatch = RegExp(r'^appearance/(.+)$').firstMatch(deepLink);
    if (appearanceMatch != null) {
      return GenericDeepLinkIntent(
        targetPath:
            '/appearance/${Uri.encodeComponent(appearanceMatch.group(1)!)}',
        rawPayload: data,
      );
    }

    final dateSimMatch =
        RegExp(r'^date_sim/([^/]+)/(.+)$').firstMatch(deepLink);
    if (dateSimMatch != null) {
      final other = Uri.encodeComponent(dateSimMatch.group(1)!);
      final simId = Uri.encodeQueryComponent(dateSimMatch.group(2)!);
      return GenericDeepLinkIntent(
        targetPath: '/date-sim/$other?sim_id=$simId',
        rawPayload: data,
      );
    }

    if (deepLink == 'matches') {
      return const GenericDeepLinkIntent(targetPath: '/matches');
    }
    if (deepLink == 'profile_suggestions') {
      return const GenericDeepLinkIntent(targetPath: '/profile/me/updates');
    }

    return GenericDeepLinkIntent(
      targetPath: deepLink.startsWith('/') ? deepLink : '/$deepLink',
      rawPayload: data,
    );
  }

  static void configureDAGForIntent(StartupDAG dag, LaunchIntent intent) {
    switch (intent) {
      case PaywallDeepLinkIntent():
        debugPrint(
            '[StartupDAG] Promoting N11:revenuecat_init to critical path for paywall.');
        dag.addEdge('N11:revenuecat_init', 'N12:destination_routing');
        if (dag.nodes.containsKey('N11:revenuecat_init')) {
          // ensure node is marked critical
        }
        break;
      case DmDeepLinkIntent():
        debugPrint(
            '[StartupDAG] Enforcing strict auth critical path for DM intent.');
        dag.addEdge('N9:auth_session_restore', 'N12:destination_routing');
        break;
      case IconLaunchIntent():
        dag.addEdge('N10:boot_config_read', 'N12:destination_routing');
        break;
      case GenericDeepLinkIntent():
        dag.addEdge('N9:auth_session_restore', 'N12:destination_routing');
        break;
    }
  }
}
