import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import '../env.dart';

/// Thin client for the Ayma Main API. Every call attaches the current Firebase
/// ID token as a Bearer header (§3.4).
class ApiClient {
  ApiClient({http.Client? httpClient, FirebaseAuth? auth})
      : _http = httpClient ?? http.Client(),
        _auth = auth ?? FirebaseAuth.instance;

  final http.Client _http;
  final FirebaseAuth _auth;

  Uri _uri(String path) => Uri.parse('${Env.apiBaseUrl}$path');

  Future<Map<String, String>> _headers() async {
    final token = await _auth.currentUser?.getIdToken();
    if (token == null) {
      throw ApiException('Not signed in.', statusCode: 401);
    }
    return {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    };
  }

  /// `POST /bootstrap` — session bootstrap; returns the derived `session_mode`
  /// and the LiveKit join credentials for this user's voice room (§1.7 step 3,
  /// §1.1).
  Future<BootstrapResult> bootstrap({
    required String sessionId,
    List<Map<String, String>> recentTurns = const [],
  }) async {
    final http.Response response;
    try {
      response = await _http.post(
        _uri('/bootstrap'),
        headers: await _headers(),
        body: jsonEncode({
          'session_id': sessionId,
          'recent_turns': recentTurns,
        }),
      );
    } on http.ClientException catch (e) {
      throw ApiException('Network error: ${e.message}');
    }

    if (response.statusCode != 200) {
      throw ApiException(
        'Bootstrap request failed.',
        statusCode: response.statusCode,
        body: response.body,
      );
    }
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final livekit = decoded['livekit'] as Map<String, dynamic>?;
    if (livekit == null) {
      throw ApiException('Bootstrap response missing LiveKit credentials.');
    }
    return BootstrapResult(
      sessionMode: decoded['session_mode'] as String? ?? '',
      livekitUrl: livekit['url'] as String? ?? '',
      livekitToken: livekit['token'] as String? ?? '',
      room: livekit['room'] as String? ?? '',
    );
  }

  /// `POST /chat` — sends a text turn plus the recent-turns window (§1.5),
  /// returns Ayma's reply and any turn-cap signal (§3.3). A non-empty
  /// [sessionId] also persists the running window to `raw_turns` (§1.7 step 8).
  Future<ChatResult> chat(
    String message, {
    String sessionId = '',
    List<Map<String, String>> recentTurns = const [],
  }) async {
    final http.Response response;
    try {
      response = await _http.post(
        _uri('/chat'),
        headers: await _headers(),
        body: jsonEncode({
          'message': message,
          'session_id': sessionId,
          'recent_turns': recentTurns,
        }),
      );
    } on http.ClientException catch (e) {
      throw ApiException('Network error: ${e.message}');
    }

    if (response.statusCode != 200) {
      throw ApiException(
        'Chat request failed.',
        statusCode: response.statusCode,
        body: response.body,
      );
    }
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    return ChatResult(
      reply: decoded['reply'] as String? ?? '',
      capped: decoded['capped'] == true,
      fallbackForm: decoded['fallback_form'] == true,
    );
  }

  /// `POST /media` — embed an uploaded photo and record it on `user_media`
  /// (§2.5, §2.8 step 7). Call after the file is in `uploads/{uid}/…`.
  Future<void> registerMedia(
    String storagePath, {
    String context = 'profile',
  }) async {
    final response = await _http.post(
      _uri('/media'),
      headers: await _headers(),
      body: jsonEncode({'storage_path': storagePath, 'context': context}),
    );
    if (response.statusCode != 200) {
      throw ApiException(
        'Media registration failed.',
        statusCode: response.statusCode,
        body: response.body,
      );
    }
  }

  /// `POST /post-turn` — persist the session's raw turn window on session end
  /// (§1.7 step 8). Best-effort: failures are swallowed by the caller.
  Future<void> postTurn(
    String sessionId,
    List<Map<String, String>> recentTurns,
  ) async {
    if (sessionId.isEmpty || recentTurns.isEmpty) return;
    final response = await _http.post(
      _uri('/post-turn'),
      headers: await _headers(),
      body: jsonEncode({
        'session_id': sessionId,
        'recent_turns': recentTurns,
      }),
    );
    if (response.statusCode != 200) {
      throw ApiException(
        'post-turn failed.',
        statusCode: response.statusCode,
        body: response.body,
      );
    }
  }
}

/// Result of `POST /bootstrap` — the bits the client needs to open a voice
/// session. `session_mode` is consumed by later steps (screen gating, §3.3).
class BootstrapResult {
  const BootstrapResult({
    required this.sessionMode,
    required this.livekitUrl,
    required this.livekitToken,
    required this.room,
  });

  final String sessionMode;
  final String livekitUrl;
  final String livekitToken;
  final String room;
}

/// A `/chat` turn's outcome. [capped] means the turn was refused by the
/// marketing/interview cap and [reply] is Ayma's nudge; [fallbackForm] means
/// the client should switch to the plain manual profile form (§3.3).
class ChatResult {
  const ChatResult({
    required this.reply,
    this.capped = false,
    this.fallbackForm = false,
  });

  final String reply;
  final bool capped;
  final bool fallbackForm;
}

class ApiException implements Exception {
  ApiException(this.message, {this.statusCode, this.body});

  final String message;
  final int? statusCode;
  final String? body;

  @override
  String toString() =>
      'ApiException($message${statusCode != null ? ', status $statusCode' : ''})';
}
