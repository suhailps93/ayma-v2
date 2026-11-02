import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'ayma_session.dart';
import 'credits_balance.dart';
import 'transcript_store.dart';

/// A chat message the user sent while out of credits, held until it can go.
@immutable
class QueuedChatMessage {
  const QueuedChatMessage({
    required this.clientMsgId,
    required this.message,
    this.imagePath = '',
    this.imageUrl = '',
  });

  /// The `client_msg_id` of this send. Stable for the message's whole life in
  /// the queue, so every attempt to deliver it is idempotent server-side — a
  /// flush after a dropped connection can never run (or bill) the turn twice.
  final String clientMsgId;
  final String message;

  /// A photo already uploaded for this message (`uploads/{uid}/…`), and the
  /// download URL its bubble renders from. Empty for a text-only message.
  final String imagePath;
  final String imageUrl;

  Map<String, dynamic> toJson() => {
        'id': clientMsgId,
        'message': message,
        'image_path': imagePath,
        'image_url': imageUrl,
      };

  static QueuedChatMessage? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final message = raw['message'];
    if (id is! String || id.isEmpty || message is! String) return null;
    return QueuedChatMessage(
      clientMsgId: id,
      message: message,
      imagePath: raw['image_path'] as String? ?? '',
      imageUrl: raw['image_url'] as String? ?? '',
    );
  }
}

/// Chat messages sent while the account had no credits.
///
/// `POST /chat` answers an out-of-credits turn with `usage_capped: true`
/// (HTTP 200) and persists nothing, so the same `client_msg_id` can be sent
/// again later as a brand-new turn. This queue keeps those messages — on disk,
/// per account, so they survive an app restart — and sends them, in order, as
/// soon as the balance is positive again (see [flushIfFunded]). Browsing and
/// chatting stay free of any hard block: the user can always type, and a
/// message simply waits for credits instead of failing.
///
/// Delivery goes through the same idempotent `/chat` call the screen's own
/// send uses. Before sending, the queue checks `/chat/history` for the
/// message's id, so a turn the server already finished (connection died after
/// it landed, app restarted before the queue was cleared) is adopted rather
/// than sent or shown twice.
class PendingChatQueue extends ChangeNotifier {
  PendingChatQueue({
    ApiClient? api,
    TranscriptStore? store,
    String? sessionId,
    String? Function()? currentUid,
  })  : _apiOverride = api,
        _storeOverride = store,
        _sessionIdOverride = sessionId,
        _currentUid = currentUid ?? _firebaseUid;

  static String? _firebaseUid() {
    try {
      return FirebaseAuth.instance.currentUser?.uid;
    } catch (_) {
      return null; // Firebase not initialised (unit tests): nothing to load.
    }
  }

  /// The app-wide queue, delivering into the shared [AymaSession] transcript.
  static final PendingChatQueue instance = PendingChatQueue();

  static const _keyPrefix = 'pending_chat_queue_v1:';

  final ApiClient? _apiOverride;
  final TranscriptStore? _storeOverride;
  final String? _sessionIdOverride;
  final String? Function() _currentUid;

  late final ApiClient _api = _apiOverride ?? ApiClient();
  TranscriptStore get _store =>
      _storeOverride ?? AymaSession.instance.store;
  String get _sessionId =>
      _sessionIdOverride ?? AymaSession.instance.sessionId;

  final List<QueuedChatMessage> _items = [];
  String? _loadedUid;
  bool _balanceListening = false;
  bool _flushing = false;
  String? _sendingId;

  /// Every message still waiting, oldest first — including the one being sent
  /// right now.
  List<QueuedChatMessage> get items => List.unmodifiable(_items);
  bool get isEmpty => _items.isEmpty;

  /// The messages to show as "waiting" bubbles: all but the one whose delivery
  /// is in flight (that one is already a normal bubble in the transcript).
  List<QueuedChatMessage> get waiting => [
        for (final m in _items)
          if (m.clientMsgId != _sendingId) m,
      ];

  /// Load the signed-in account's persisted queue (once per account) and start
  /// reacting to balance changes. If anything was left over from a previous
  /// run, refresh the balance and send it right away.
  Future<void> activate() async {
    if (!_balanceListening) {
      _balanceListening = true;
      CreditsBalance.instance.remaining.addListener(_onBalanceChanged);
    }
    final uid = _currentUid();
    if (uid == null || uid.isEmpty || uid == _loadedUid) return;
    _loadedUid = uid;
    _items.clear();
    try {
      final raw =
          (await SharedPreferences.getInstance()).getString('$_keyPrefix$uid');
      if (raw != null && raw.isNotEmpty && _loadedUid == uid) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          _items.addAll(decoded
              .map(QueuedChatMessage.fromJson)
              .whereType<QueuedChatMessage>());
        }
      }
    } catch (e) {
      debugPrint('PendingChatQueue load failed: $e');
    }
    notifyListeners();
    unawaited(syncBalanceAndFlush());
  }

  /// Hold [message] until credits are available. A duplicate id is ignored.
  Future<void> enqueue(QueuedChatMessage message) async {
    if (_items.any((m) => m.clientMsgId == message.clientMsgId)) return;
    _items.add(message);
    notifyListeners();
    await _persist();
  }

  /// Drop a waiting message the user no longer wants sent. A message already
  /// being delivered can't be cancelled (the server may be running it).
  Future<void> cancel(String clientMsgId) async {
    if (clientMsgId == _sendingId) return;
    final before = _items.length;
    _items.removeWhere((m) => m.clientMsgId == clientMsgId);
    if (_items.length == before) return;
    notifyListeners();
    await _persist();
  }

  /// Ask the server for the current balance (a grant or purchase may have
  /// landed while the app was away) and flush if it is positive.
  Future<void> syncBalanceAndFlush() async {
    if (_items.isEmpty) return;
    try {
      final usage = await _api.usage();
      CreditsBalance.instance.remaining.value = usage.creditsRemaining;
      await flushIfFunded();
    } catch (e) {
      debugPrint('PendingChatQueue balance sync failed: $e');
    }
  }

  void _onBalanceChanged() => unawaited(flushIfFunded());

  /// Flush when the last-known balance is positive. Called whenever the app
  /// learns the balance (top-up, usage fetch, resume).
  Future<void> flushIfFunded() async {
    final balance = CreditsBalance.instance.remaining.value;
    if (balance == null || balance <= 0) return;
    await _flush();
  }

  /// Send the queued messages in order. Stops at the first one that can't go
  /// (out of credits again, offline, server error) — it stays queued, and so
  /// does everything behind it.
  Future<void> _flush() async {
    if (_flushing) return;
    _flushing = true;
    try {
      while (_items.isNotEmpty) {
        if (!await _deliver(_items.first)) break;
      }
    } finally {
      _flushing = false;
    }
  }

  Future<bool> _deliver(QueuedChatMessage item) async {
    final store = _store;
    final landed = await _landedReply(item);
    if (landed != null) {
      _adoptLanded(item, landed);
      await _remove(item);
      return true;
    }

    _sendingId = item.clientMsgId;
    store.clearCappedTurns();
    final window = store.wireTurns();
    store.addTurn(
      TurnRole.user,
      item.message,
      TurnSource.text,
      imageUrl: item.imageUrl.isEmpty ? null : item.imageUrl,
    );
    store.addPending('Thinking…');
    notifyListeners();
    try {
      final result = await _api.chat(
        item.message.isEmpty ? '(shared a photo)' : item.message,
        sessionId: _sessionId,
        recentTurns: window,
        imagePath: item.imagePath,
        clientMsgId: item.clientMsgId,
      );
      if (result.usageCapped) {
        store.resolvePending(result.reply, capped: true);
        _dropUserTurn(item);
        return false;
      }
      store.resolvePending(
        result.reply,
        tools: result.toolsUsed,
        imageUrl: result.imageUrl,
      );
      await _remove(item);
      return true;
    } catch (e) {
      debugPrint('PendingChatQueue delivery failed: $e');
      store.dropPending();
      _dropUserTurn(item);
      return false;
    } finally {
      _sendingId = null;
      notifyListeners();
    }
  }

  /// The Ayma reply the server already finished for [item], if any.
  Future<ChatMessage?> _landedReply(QueuedChatMessage item) async {
    try {
      // Fail fast: the queue has its own retry/dedup, so the landed-reply
      // check must not incur the GET retry-backoff (a backoff would outlive
      // this flush and skip the online retry, PERF_PLAN GATE-RED).
      final page = await _api.chatHistory(limit: 10, noRetry: true);
      for (final m in page.messages) {
        if (m.role == 'ayma' && m.clientMsgId == item.clientMsgId) return m;
      }
    } catch (e) {
      debugPrint('PendingChatQueue history check failed: $e');
    }
    return null;
  }

  /// Show a turn the server finished on its own — unless the transcript
  /// (loaded from history) already has it.
  void _adoptLanded(QueuedChatMessage item, ChatMessage reply) {
    final store = _store;
    final alreadyShown = store.turns.reversed.take(10).any(
        (t) => t.role == TurnRole.ayma && t.isFinal && t.text == reply.text);
    if (alreadyShown) return;
    store.addTurn(
      TurnRole.user,
      item.message,
      TurnSource.text,
      imageUrl: item.imageUrl.isEmpty ? null : item.imageUrl,
    );
    store.addTurn(
      TurnRole.ayma,
      reply.text,
      TurnSource.text,
      tools: reply.tools,
      imageUrl: reply.imageUrl.isEmpty ? null : reply.imageUrl,
    );
  }

  /// Take the user bubble [item] showed while being delivered back out of the
  /// transcript — the item is still queued, so it renders as waiting again.
  void _dropUserTurn(QueuedChatMessage item) {
    final store = _store;
    for (final t in store.turns.reversed) {
      if (t.role == TurnRole.user && t.text == item.message) {
        store.removeTurn(t);
        return;
      }
    }
  }

  Future<void> _remove(QueuedChatMessage item) async {
    _items.removeWhere((m) => m.clientMsgId == item.clientMsgId);
    notifyListeners();
    await _persist();
  }

  Future<void> _persist() async {
    final uid = _loadedUid;
    if (uid == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_items.isEmpty) {
        await prefs.remove('$_keyPrefix$uid');
      } else {
        await prefs.setString(
          '$_keyPrefix$uid',
          jsonEncode([for (final m in _items) m.toJson()]),
        );
      }
    } catch (e) {
      debugPrint('PendingChatQueue persist failed: $e');
    }
  }
}
