import 'package:url_launcher/url_launcher.dart';

import 'api_client.dart';

/// A ChatGPT connect that ended without a usable result (the user backed out,
/// the browser step timed out, or the server refused). [message] is safe to
/// show; [cancelled] means "say nothing".
class ChatGptException implements Exception {
  const ChatGptException(this.message, {this.cancelled = false});
  final String message;
  final bool cancelled;
  @override
  String toString() => 'ChatGptException: $message';
}

/// "Sign in with ChatGPT" (docs/chatgpt-provider.md). The app has no deep-link
/// handling, so the flow is: open the authorize URL in the system browser, the
/// browser lands on the server's HTTPS callback page, and the app polls
/// `/auth/chatgpt/return` with the secret `state` it was given until the
/// server reports the outcome. Tokens never reach the device.
class ChatGptService {
  ChatGptService({
    ApiClient? api,
    Future<bool> Function(Uri url)? openUrl,
    this.pollInterval = const Duration(seconds: 2),
    this.timeout = const Duration(minutes: 5),
  })  : _apiOverride = api,
        _openUrl = openUrl ?? _defaultOpen;

  final ApiClient? _apiOverride;
  final Future<bool> Function(Uri url) _openUrl;
  final Duration pollInterval;
  final Duration timeout;

  late final ApiClient _api = _apiOverride ?? ApiClient();

  static Future<bool> _defaultOpen(Uri url) =>
      launchUrl(url, mode: LaunchMode.externalApplication);

  /// Whether the server offers the ChatGPT option at all.
  Future<bool> isEnabled() async {
    try {
      return await _api.chatgptEnabled();
    } catch (_) {
      return false;
    }
  }

  Future<ChatGptStatus> status() => _api.chatgptStatus();

  Future<void> disconnect() => _api.chatgptDisconnect();

  /// Sign in with ChatGPT as the identity (no Firebase user yet). Returns the
  /// Firebase custom token to redeem via
  /// `AuthService.signInWithChatGptCustomToken`.
  Future<ChatGptReturn> signIn({bool Function()? isCancelled}) =>
      _run(linked: false, isCancelled: isCancelled);

  /// Attach ChatGPT to the signed-in account (Settings).
  Future<void> connect({bool Function()? isCancelled}) =>
      _run(linked: true, isCancelled: isCancelled);

  Future<ChatGptReturn> _run({
    required bool linked,
    bool Function()? isCancelled,
  }) async {
    final ChatGptStart start;
    try {
      start = await _api.chatgptStart(linked: linked);
    } on ApiException catch (e) {
      throw ChatGptException(
        e.statusCode == 404 || e.statusCode == 400
            ? 'Sign in with ChatGPT isn’t available yet.'
            : 'Couldn’t reach ChatGPT. Try again in a moment.',
      );
    }
    if (start.connected) {
      return const ChatGptReturn(status: 'done');
    }
    if (start.url.isEmpty || start.state.isEmpty) {
      throw const ChatGptException('Sign in with ChatGPT isn’t available yet.');
    }
    final opened = await _openUrl(Uri.parse(start.url));
    if (!opened) {
      throw const ChatGptException('Couldn’t open the browser.');
    }

    final deadline = DateTime.now().add(timeout);
    while (true) {
      await Future<void>.delayed(pollInterval);
      if (isCancelled?.call() ?? false) {
        throw const ChatGptException('Cancelled', cancelled: true);
      }
      if (DateTime.now().isAfter(deadline)) {
        throw const ChatGptException('ChatGPT sign-in timed out. Try again.');
      }
      final ChatGptReturn r;
      try {
        r = await _api.chatgptReturn(start.state, linked: linked);
      } on ApiException catch (e) {
        if (e.statusCode != null && e.statusCode! >= 400 && e.statusCode! < 500) {
          throw const ChatGptException('ChatGPT sign-in didn’t complete.');
        }
        continue; // transient — keep polling
      } catch (_) {
        continue;
      }
      switch (r.status) {
        case 'pending':
          continue;
        case 'done':
          if (!linked && (r.customToken ?? '').isEmpty) {
            throw const ChatGptException('ChatGPT sign-in didn’t complete.');
          }
          return r;
        default:
          throw ChatGptException(
              r.detail.isEmpty ? 'ChatGPT sign-in didn’t complete.' : r.detail);
      }
    }
  }
}
