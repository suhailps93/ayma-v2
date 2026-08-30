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

    if (decoded['recovery_required'] == true) {
      return const BootstrapResult(
        sessionMode: '',
        livekitUrl: '',
        livekitToken: '',
        room: '',
        recoveryRequired: true,
      );
    }

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

  /// `GET /explore` — the live filtered feed (§6.1). [q] is a natural-language
  /// search parsed once server-side; [filters] are exact dropdown values.
  Future<List<ExploreCard>> explore({
    String q = '',
    Map<String, String> filters = const {},
  }) async {
    final params = <String, String>{
      if (q.isNotEmpty) 'q': q,
      ...filters,
    };
    final uri = _uri('/explore').replace(queryParameters: params);
    final response = await _http.get(uri, headers: await _headers());
    if (response.statusCode != 200) {
      throw ApiException('explore failed.',
          statusCode: response.statusCode, body: response.body);
    }
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    return ((decoded['cards'] as List?) ?? [])
        .map((c) => ExploreCard.fromMap(c as Map<String, dynamic>))
        .toList();
  }

  /// `POST /dm/{threadId}/messages` — send a DM message (§6.6).
  Future<void> sendDmMessage(
    String threadId, {
    required String type,
    required String body,
  }) =>
      _postJsonOk('/dm/$threadId/messages', {'type': type, 'body': body});

  /// `GET /dm/{threadId}/icebreakers` — suggested opener chips (§6.9). Empty
  /// until a compatibility check has produced a `matches` doc for the pair.
  Future<List<String>> dmIcebreakers(String threadId) async {
    final r = await _http.get(
      _uri('/dm/$threadId/icebreakers'),
      headers: await _headers(),
    );
    if (r.statusCode != 200) {
      throw ApiException('icebreakers failed.',
          statusCode: r.statusCode, body: r.body);
    }
    final decoded = jsonDecode(r.body) as Map<String, dynamic>;
    return ((decoded['icebreakers'] as List?) ?? [])
        .map((e) => e.toString())
        .toList();
  }

  /// `GET /admin/users?q=` — password-gated user search (§14.3).
  Future<List<Map<String, dynamic>>> adminSearchUsers(
      String password, String q) async {
    final uri = _uri('/admin/users').replace(queryParameters: {'q': q});
    final r = await _http.get(uri, headers: {'X-Admin-Password': password});
    if (r.statusCode != 200) {
      throw ApiException('admin search failed.',
          statusCode: r.statusCode, body: r.body);
    }
    return ((jsonDecode(r.body) as Map<String, dynamic>)['users'] as List? ?? [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();
  }

  /// `GET /admin/users/{uid}` — full per-user detail (§14.3).
  Future<Map<String, dynamic>> adminUserDetail(
      String password, String uid) async {
    final r = await _http.get(_uri('/admin/users/$uid'),
        headers: {'X-Admin-Password': password});
    if (r.statusCode != 200) {
      throw ApiException('admin detail failed.',
          statusCode: r.statusCode, body: r.body);
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// `POST /wiki/reset` — wipe what Ayma has learned (`wiki_pages` /
  /// `raw_turns` / `pending_questions`); account, profile and auth stay (§14.2).
  Future<void> resetWiki() => _postJsonOk('/wiki/reset', const {});

  /// `GET /usage` — this user's lifetime Gemini-token usage vs. the cap.
  Future<UsageSummary> usage() async {
    final r = await _http.get(_uri('/usage'), headers: await _headers());
    if (r.statusCode != 200) {
      throw ApiException('usage failed.',
          statusCode: r.statusCode, body: r.body);
    }
    final m = jsonDecode(r.body) as Map<String, dynamic>;
    return UsageSummary(
      total: (m['total'] as num?)?.toInt() ?? 0,
      cap: (m['cap'] as num?)?.toInt() ?? 0,
      remaining: (m['remaining'] as num?)?.toInt() ?? 0,
      features: ((m['features'] as Map?) ?? {}).map(
        (k, v) => MapEntry(k.toString(), (v as num).toInt()),
      ),
    );
  }

  /// `GET /voice/presets` — the selectable Gemini Live voice presets plus the
  /// user's current choice (§13.3).
  Future<VoicePresets> voicePresets() async {
    final r = await _http.get(_uri('/voice/presets'), headers: await _headers());
    if (r.statusCode != 200) {
      throw ApiException('voice presets failed.',
          statusCode: r.statusCode, body: r.body);
    }
    final m = jsonDecode(r.body) as Map<String, dynamic>;
    return VoicePresets(
      presets: ((m['presets'] as List?) ?? [])
          .map((e) => VoicePreset(
                name: (e as Map)['name'] as String? ?? '',
                description: e['description'] as String? ?? '',
              ))
          .toList(),
      current: m['current'] as String? ?? '',
      defaultName: m['default'] as String? ?? '',
    );
  }

  /// `GET /media/photos` — the current profile-photo grid (§8.3). Returns the
  /// list of `{media_id, order}` maps, order ascending.
  Future<List<Map<String, dynamic>>> listPhotos() async {
    final r = await _http.get(_uri('/media/photos'), headers: await _headers());
    if (r.statusCode != 200) {
      throw ApiException('list photos failed.',
          statusCode: r.statusCode, body: r.body);
    }
    return ((jsonDecode(r.body) as Map<String, dynamic>)['photos'] as List? ??
            [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();
  }

  /// `POST /media/photos` — add an already-processed photo to the grid.
  Future<void> addPhoto(String mediaId) =>
      _postJsonOk('/media/photos', {'media_id': mediaId});

  /// `POST /media/photos/{id}/remove` — soft-remove (the `user_media` doc,
  /// Storage file and embedding all stay, §8.3).
  Future<void> removePhoto(String mediaId) =>
      _postJsonOk('/media/photos/$mediaId/remove', const {});

  /// `PUT /media/photos/order` — `mediaIds[0]` becomes the primary photo.
  Future<void> reorderPhotos(List<String> mediaIds) async {
    final r = await _http.put(_uri('/media/photos/order'),
        headers: await _headers(),
        body: jsonEncode({'media_ids': mediaIds}));
    if (r.statusCode != 200) {
      throw ApiException('reorder photos failed.',
          statusCode: r.statusCode, body: r.body);
    }
  }

  /// `GET /instagram/auth-url` — the URL the client opens to authorise
  /// Instagram access (§8.1).
  Future<String> instagramAuthUrl() async {
    final r = await _http.get(_uri('/instagram/auth-url'),
        headers: await _headers());
    if (r.statusCode != 200) {
      throw ApiException('instagram auth-url failed.',
          statusCode: r.statusCode, body: r.body);
    }
    return (jsonDecode(r.body) as Map<String, dynamic>)['url'] as String? ?? '';
  }

  /// `POST /instagram/connect` — exchange the OAuth `code`, import recent
  /// photos + captions (§8.2). Returns the number imported.
  Future<int> instagramConnect(String code) async {
    final r = await _http.post(_uri('/instagram/connect'),
        headers: await _headers(), body: jsonEncode({'code': code}));
    if (r.statusCode != 200) {
      throw ApiException('instagram connect failed.',
          statusCode: r.statusCode, body: r.body);
    }
    return (jsonDecode(r.body) as Map<String, dynamic>)['imported'] as int? ?? 0;
  }

  /// `POST /instagram/disconnect` — forget the token; imported photos stay.
  Future<void> instagramDisconnect() => _postJsonOk('/instagram/disconnect', {});

  /// `POST /notifications/token` — register/refresh this device's FCM token
  /// (§7.2, §7.9 step 2).
  Future<void> registerFcmToken(String token) =>
      _postJsonOk('/notifications/token', {'token': token});

  /// `POST /notifications/token/remove` — drop a device token (sign-out /
  /// rotation).
  Future<void> removeFcmToken(String token) =>
      _postJsonOk('/notifications/token/remove', {'token': token});

  /// `POST /explore/like` — returns true if it created a mutual match (§6.5).
  Future<bool> likeProfile(String otherUid) async {
    final r = await _http.post(_uri('/explore/like'),
        headers: await _headers(),
        body: jsonEncode({'other_uid': otherUid}));
    if (r.statusCode != 200) {
      throw ApiException('like failed.', statusCode: r.statusCode, body: r.body);
    }
    return (jsonDecode(r.body) as Map<String, dynamic>)['mutual'] == true;
  }

  /// `POST /explore/pass` — seen/passed marker (§6.5).
  Future<void> passProfile(String otherUid) =>
      _postJsonOk('/explore/pass', {'other_uid': otherUid});

  /// `POST /profile/share` — send a shared_profile card into a DM thread (§6.7).
  Future<void> shareProfile(
          {required String sharedUid, required String threadWith}) =>
      _postJsonOk('/profile/share',
          {'shared_uid': sharedUid, 'thread_with': threadWith});

  Future<void> _postJsonOk(String path, Map<String, dynamic> body) async {
    final r = await _http.post(_uri(path),
        headers: await _headers(), body: jsonEncode(body));
    if (r.statusCode != 200) {
      throw ApiException('$path failed.',
          statusCode: r.statusCode, body: r.body);
    }
  }

  /// `POST /match/{id}/respond` — accept or reject a scored match (§5.7).
  Future<void> respondToMatch(String matchId, {required bool accept}) async {
    final response = await _http.post(
      _uri('/match/$matchId/respond'),
      headers: await _headers(),
      body: jsonEncode({'response': accept ? 'accept' : 'reject'}),
    );
    if (response.statusCode != 200) {
      throw ApiException('match respond failed.',
          statusCode: response.statusCode, body: response.body);
    }
  }

  /// `POST /block` — block a user; they drop out of all future match sourcing
  /// (§5.1, §5.10 step 11).
  Future<void> block(String blockedUid) async {
    final response = await _http.post(
      _uri('/block'),
      headers: await _headers(),
      body: jsonEncode({'blocked_uid': blockedUid}),
    );
    if (response.statusCode != 200) {
      throw ApiException('block failed.',
          statusCode: response.statusCode, body: response.body);
    }
  }

  /// `POST /account/delete` — soft-delete into the 30-day recovery window
  /// (§3.6). The Firebase Auth session is untouched.
  Future<void> deleteAccount() => _postOk('/account/delete');

  /// `POST /account/recover` — restore a soft-deleted account (§3.6).
  Future<void> recoverAccount() => _postOk('/account/recover');

  Future<void> _postOk(String path) async {
    final response =
        await _http.post(_uri(path), headers: await _headers());
    if (response.statusCode != 200) {
      throw ApiException(
        '$path failed.',
        statusCode: response.statusCode,
        body: response.body,
      );
    }
  }

  /// `POST /chat` — sends a text turn plus the recent-turns window (§1.5),
  /// returns Ayma's reply and any turn-cap signal (§3.3). A non-empty
  /// [sessionId] also persists the running window to `raw_turns` (§1.7 step 8).
  Future<ChatResult> chat(
    String message, {
    String sessionId = '',
    String viewingProfileUid = '',
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
          'viewing_profile_uid': viewingProfileUid,
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

  /// `POST /media` — run the unified photo pipeline (moderation → embed →
  /// attributes → caption, §8.5) on an uploaded photo. Call after the file is
  /// in `uploads/{uid}/…`.
  Future<MediaResult> registerMedia(
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
    final m = jsonDecode(response.body) as Map<String, dynamic>;
    return MediaResult(
      mediaId: m['media_id'] as String? ?? '',
      published: m['published'] as bool? ?? true,
      moderationStatus: m['moderation_status'] as String? ?? 'approved',
      reason: m['reason'] as String? ?? '',
    );
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
    this.recoveryRequired = false,
  });

  final String sessionMode;
  final String livekitUrl;
  final String livekitToken;
  final String room;

  /// The account is soft-deleted — the client shows the recovery screen (§3.6).
  final bool recoveryRequired;
}

/// One Explore feed card (§6.4).
class ExploreCard {
  const ExploreCard({
    required this.uid,
    required this.name,
    required this.age,
    required this.location,
    this.photoPath,
    this.score,
  });

  final String uid;
  final String name;
  final int? age;
  final String location;
  final String? photoPath;
  final double? score;

  factory ExploreCard.fromMap(Map<String, dynamic> m) => ExploreCard(
        uid: m['uid'] as String? ?? '',
        name: m['name'] as String? ?? '',
        age: (m['age'] as num?)?.toInt(),
        location: m['location'] as String? ?? '',
        photoPath: m['photo_path'] as String?,
        score: (m['score'] as num?)?.toDouble(),
      );
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

/// Result of `POST /media` (§8.4/§8.5). [published] is false when moderation
/// [reason] held the photo out of the grid / Explore / DM.
class MediaResult {
  const MediaResult({
    required this.mediaId,
    required this.published,
    required this.moderationStatus,
    required this.reason,
  });

  final String mediaId;
  final bool published;
  final String moderationStatus;
  final String reason;
}

/// `GET /usage` result — lifetime Gemini-token accounting for the user.
class UsageSummary {
  const UsageSummary({
    required this.total,
    required this.cap,
    required this.remaining,
    required this.features,
  });

  final int total;
  final int cap;
  final int remaining;

  /// Tokens per feature: `chat`, `voice`, `icebreakers`, `matching`, `wiki`.
  final Map<String, int> features;

  double get fraction => cap <= 0 ? 0 : (total / cap).clamp(0.0, 1.0);
  bool get atCap => cap > 0 && total >= cap;
}

class VoicePreset {
  const VoicePreset({required this.name, required this.description});
  final String name;
  final String description;
}

class VoicePresets {
  const VoicePresets({
    required this.presets,
    required this.current,
    required this.defaultName,
  });
  final List<VoicePreset> presets;
  final String current;
  final String defaultName;

  /// The effective selection: the user's choice, or the default.
  String get effective => current.isNotEmpty ? current : defaultName;
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
