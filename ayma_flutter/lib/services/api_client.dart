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

    // Out of credits — voice is an LLM session, so the server returns no
    // LiveKit creds and the client doesn't connect. `session_mode` is still
    // present: being broke must not dump a signed-in user into marketing mode,
    // so we route on it as usual and just surface a "reload credits" notice.
    if (decoded['usage_capped'] == true) {
      return BootstrapResult(
        sessionMode: decoded['session_mode'] as String? ?? '',
        livekitUrl: '',
        livekitToken: '',
        room: '',
        usageCapped: true,
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

  /// `POST /welcome/token` — a LiveKit token for the pre-sign-in "welcome"
  /// voice room. Unauthenticated (there is no account yet); Ayma opens the
  /// call with a short greeting.
  Future<({String url, String token})> welcomeToken() async {
    final r = await _http.post(
      _uri('/welcome/token'),
      headers: const {'Content-Type': 'application/json'},
    );
    if (r.statusCode != 200) {
      throw ApiException('welcome token failed.',
          statusCode: r.statusCode, body: r.body);
    }
    final lk = (jsonDecode(r.body) as Map<String, dynamic>)['livekit']
        as Map<String, dynamic>?;
    return (
      url: lk?['url'] as String? ?? '',
      token: lk?['token'] as String? ?? '',
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

  /// `GET /explore/profile/{uid}` — another user's public profile: photos,
  /// the public wiki narrative, plus the caller-relative score / like state
  /// and the DM thread id.
  Future<PublicProfile> publicProfile(String otherUid) async {
    final r = await _http.get(
      _uri('/explore/profile/$otherUid'),
      headers: await _headers(),
    );
    if (r.statusCode != 200) {
      throw ApiException('profile load failed.',
          statusCode: r.statusCode, body: r.body);
    }
    return PublicProfile.fromMap(jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// `POST /deep-dive` — a consented web deep-dive on a named person. Empty
  /// [targetUid] (or your own) researches you; another uid researches them.
  /// Ayma's summary is also appended to the chat transcript server-side.
  Future<DeepDiveResult> deepDive({
    String targetUid = '',
    String name = '',
    String context = '',
  }) async {
    final r = await _http.post(
      _uri('/deep-dive'),
      headers: await _headers(),
      body: jsonEncode({
        'target_uid': targetUid,
        'name': name,
        'context': context,
      }),
    );
    if (r.statusCode != 200) {
      throw ApiException('deep-dive failed.',
          statusCode: r.statusCode, body: r.body);
    }
    final m = jsonDecode(r.body) as Map<String, dynamic>;
    return DeepDiveResult(
      usageCapped: m['usage_capped'] == true,
      queued: m['queued'] == true,
      summary: m['summary'] as String? ?? '',
      reportId: m['report_id'] as String? ?? '',
      isSelf: m['is_self'] == true,
      subjectImage: m['subject_image'] as String? ?? '',
      toolLabel: m['tool_label'] as String? ?? '',
      links: (((m['digest'] as Map?) ?? const {})['links'] as List? ?? const [])
          .map((e) => DeepDiveLink(
                url: (e as Map)['url'] as String? ?? '',
                title: e['title'] as String? ?? '',
                isThem: e['is_them'] as String? ?? 'unclear',
              ))
          .where((l) => l.url.isNotEmpty)
          .toList(),
    );
  }

  /// `GET /deep-dive-report/{id}` — re-open a stored web dive by its id (from a
  /// `[deep_dive:<id>]` chat marker or the "View research" button).
  Future<DeepDiveReport> deepDiveReport(String id) async {
    final r = await _http.get(
      _uri('/deep-dive-report/${Uri.encodeComponent(id)}'),
      headers: await _headers(),
    );
    if (r.statusCode != 200) {
      throw ApiException('deep-dive report failed.',
          statusCode: r.statusCode, body: r.body);
    }
    return DeepDiveReport.fromMap(jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// `POST /face-report` — an honest, data-driven facial-beauty report on a
  /// photo. [attachmentPath] (a chat upload under `uploads/{you}/`) wins;
  /// otherwise [targetUid]'s primary profile photo (empty = your own). Ayma's
  /// one-line pointer is also appended to the chat transcript server-side.
  Future<FaceReportResult> faceReport({
    String attachmentPath = '',
    String targetUid = '',
  }) async {
    final r = await _http.post(
      _uri('/face-report'),
      headers: await _headers(),
      body: jsonEncode({
        'attachment_path': attachmentPath,
        'target_uid': targetUid,
      }),
    );
    if (r.statusCode != 200) {
      throw ApiException('face-report failed.',
          statusCode: r.statusCode, body: r.body);
    }
    final m = jsonDecode(r.body) as Map<String, dynamic>;
    return FaceReportResult(
      usageCapped: m['usage_capped'] == true,
      reportId: m['report_id'] as String? ?? '',
      report: m['report'] is Map
          ? FaceReport.fromMap((m['report'] as Map).cast<String, dynamic>())
          : null,
    );
  }

  /// `POST /body-report` — an honest, data-driven physique report on a photo.
  /// Same request shape as [faceReport].
  Future<BodyReportResult> bodyReport({
    String attachmentPath = '',
    String targetUid = '',
  }) async {
    final r = await _http.post(
      _uri('/body-report'),
      headers: await _headers(),
      body: jsonEncode({
        'attachment_path': attachmentPath,
        'target_uid': targetUid,
      }),
    );
    if (r.statusCode != 200) {
      throw ApiException('body-report failed.',
          statusCode: r.statusCode, body: r.body);
    }
    final m = jsonDecode(r.body) as Map<String, dynamic>;
    return BodyReportResult(
      usageCapped: m['usage_capped'] == true,
      reportId: m['report_id'] as String? ?? '',
      report: m['report'] is Map
          ? BodyReport.fromMap((m['report'] as Map).cast<String, dynamic>())
          : null,
    );
  }

  /// `GET /skills/report/{kind}/{reportId}` — fetch a stored face / body report
  /// referenced by a `[face_report:<id>]` / `[body_report:<id>]` marker in an
  /// Ayma chat turn. [kind] is `face` or `body`. Returns the raw
  /// `{"report": <dict>, "created_at": <iso|null>}` — the caller picks the
  /// parser ([FaceReport.fromMap] / [BodyReport.fromMap]) by [kind].
  Future<SkillReport> skillReport(String kind, String reportId) async {
    final r = await _http.get(
      _uri('/skills/report/${Uri.encodeComponent(kind)}/'
          '${Uri.encodeComponent(reportId)}'),
      headers: await _headers(),
    );
    if (r.statusCode != 200) {
      throw ApiException('skill report failed.',
          statusCode: r.statusCode, body: r.body);
    }
    final m = jsonDecode(r.body) as Map<String, dynamic>;
    final report = m['report'];
    return SkillReport(
      report: report is Map ? report.cast<String, dynamic>() : const {},
      createdAt: m['created_at'] as String?,
      imagePath: m['image_path'] as String? ?? '',
    );
  }

  /// `GET /skills/reports/{kind}` — the caller's stored face / body reports,
  /// newest first, for the per-skill history on the Skills screen.
  Future<List<SkillReportSummary>> skillReports(String kind) async {
    final r = await _http.get(
      _uri('/skills/reports/${Uri.encodeComponent(kind)}'),
      headers: await _headers(),
    );
    if (r.statusCode != 200) {
      throw ApiException('skill reports failed.',
          statusCode: r.statusCode, body: r.body);
    }
    final m = jsonDecode(r.body) as Map<String, dynamic>;
    return (m['reports'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => SkillReportSummary.fromMap(e.cast<String, dynamic>()))
        .where((s) => s.id.isNotEmpty)
        .toList();
  }

  /// `GET /physical-attributes` — the caller's stored structured physical
  /// profile (build, colouring, rough measurements). `null` when it has never
  /// been built.
  Future<PhysicalAttrsResult?> physicalAttributes() async {
    final r = await _http.get(
      _uri('/physical-attributes'),
      headers: await _headers(),
    );
    if (r.statusCode != 200) {
      throw ApiException('physical-attributes failed.',
          statusCode: r.statusCode, body: r.body);
    }
    final m = jsonDecode(r.body) as Map<String, dynamic>;
    if (m['record'] == null) return null;
    return PhysicalAttrsResult.fromMap(m);
  }

  /// `POST /physical-attributes/refresh` — force a re-run of the physical
  /// profile read. [extraPaths] are extra chat-uploaded photos (each under
  /// `uploads/{you}/`) folded into the vision pass on top of the profile grid.
  Future<PhysicalAttrsResult> refreshPhysicalAttributes({
    List<String> extraPaths = const [],
  }) async {
    final r = await _http.post(
      _uri('/physical-attributes/refresh'),
      headers: await _headers(),
      body: jsonEncode({'image_paths': extraPaths}),
    );
    if (r.statusCode != 200) {
      throw ApiException('physical-attributes refresh failed.',
          statusCode: r.statusCode, body: r.body);
    }
    return PhysicalAttrsResult.fromMap(
        jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// `GET /physical-attributes-report/{id}` — re-open a stored physical-profile
  /// report by id (from a `[physical:<id>]` chat marker or the Skills-screen
  /// history). `current` returns the live record.
  Future<PhysicalReport> physicalReport(String id) async {
    final r = await _http.get(
      _uri('/physical-attributes-report/'
          '${Uri.encodeComponent(id.isEmpty ? 'current' : id)}'),
      headers: await _headers(),
    );
    if (r.statusCode != 200) {
      throw ApiException('physical-attributes report failed.',
          statusCode: r.statusCode, body: r.body);
    }
    return PhysicalReport.fromMap(jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// `GET /physical-attributes/history` — the caller's past physical-profile
  /// runs, newest first, for the per-skill history on the Skills screen.
  Future<List<PhysicalReportSummary>> physicalHistory() async {
    final r = await _http.get(
      _uri('/physical-attributes/history'),
      headers: await _headers(),
    );
    if (r.statusCode != 200) {
      throw ApiException('physical-attributes history failed.',
          statusCode: r.statusCode, body: r.body);
    }
    final m = jsonDecode(r.body) as Map<String, dynamic>;
    return (m['reports'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => PhysicalReportSummary.fromMap(e.cast<String, dynamic>()))
        .where((s) => s.id.isNotEmpty)
        .toList();
  }

  // --- Appearance: one unified read of the user's photos ----------------

  /// `POST /appearance/report` — build the caller's unified Appearance report
  /// (structured attributes + an honest face and physique read) and persist it.
  /// [imagePaths] are chat uploads (each under `uploads/{you}/`) folded into the
  /// vision passes; [wantFace] / [wantBody] gate those sections (set from
  /// [appearanceCoverage]) — the run is never hard-blocked.
  Future<AppearanceReportResult> runAppearanceReport({
    List<String> imagePaths = const [],
    bool wantFace = true,
    bool wantBody = true,
  }) async {
    final r = await _http.post(
      _uri('/appearance/report'),
      headers: await _headers(),
      body: jsonEncode({
        'image_paths': imagePaths,
        'want_face': wantFace,
        'want_body': wantBody,
      }),
    );
    if (r.statusCode != 200) {
      throw ApiException('appearance report failed.',
          statusCode: r.statusCode, body: r.body);
    }
    final m = jsonDecode(r.body) as Map<String, dynamic>;
    return AppearanceReportResult(
      usageCapped: m['usage_capped'] == true,
      reportId: m['report_id'] as String? ?? '',
      report: m['report'] is Map
          ? AppearanceReport.fromMap((m['report'] as Map).cast<String, dynamic>())
          : null,
    );
  }

  /// `GET /appearance/report/{id}` — re-open a stored Appearance report by id
  /// (from an `[appearance:<id>]` chat marker or the Skills-screen history).
  /// An empty id (or `current`) returns the latest run.
  Future<AppearanceReport> appearanceReport(String id) async {
    final r = await _http.get(
      _uri('/appearance/report/'
          '${Uri.encodeComponent(id.isEmpty ? 'current' : id)}'),
      headers: await _headers(),
    );
    if (r.statusCode != 200) {
      throw ApiException('appearance report failed.',
          statusCode: r.statusCode, body: r.body);
    }
    return AppearanceReport.fromMap(jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// `GET /appearance/history` — the caller's Appearance runs newest-first, with
  /// the pre-merge `face_reports` / `body_reports` / `physical_reports`
  /// collections folded in as read-only `legacy: true` rows.
  Future<List<AppearanceHistoryRow>> appearanceHistory() async {
    final r = await _http.get(
      _uri('/appearance/history'),
      headers: await _headers(),
    );
    if (r.statusCode != 200) {
      throw ApiException('appearance history failed.',
          statusCode: r.statusCode, body: r.body);
    }
    final m = jsonDecode(r.body) as Map<String, dynamic>;
    return (m['reports'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => AppearanceHistoryRow.fromMap(e.cast<String, dynamic>()))
        .where((s) => s.id.isNotEmpty)
        .toList();
  }

  /// `GET /appearance/coverage` — `{hasFacePhoto, hasBodyPhoto}` for the caller,
  /// derived from the shot-type tags on their current grid photos. Backs the
  /// Skills-screen coverage line; never hard-blocks a run.
  Future<AppearanceCoverage> appearanceCoverage() async {
    final r = await _http.get(
      _uri('/appearance/coverage'),
      headers: await _headers(),
    );
    if (r.statusCode != 200) {
      throw ApiException('appearance coverage failed.',
          statusCode: r.statusCode, body: r.body);
    }
    final m = jsonDecode(r.body) as Map<String, dynamic>;
    return AppearanceCoverage(
      hasFacePhoto: m['has_face_photo'] == true,
      hasBodyPhoto: m['has_body_photo'] == true,
    );
  }

  // --- Profile completeness --------------------------------------------

  /// `GET /completeness` — the profile-completeness score, the user's stated
  /// relationship intent, a per-section breakdown, and the highest-value gaps
  /// to fill next. Ayma captures answers herself in conversation; the client
  /// only shows progress and routes the user into a chat on a topic.
  Future<Completeness> completeness() async =>
      Completeness.fromMap(await _getJson('/completeness'));

  /// `GET /questionnaire` — the full question tree with per-node coverage
  /// status (`covered` / `partial` / `missing`) for the signed-in user.
  Future<QuestionnaireTree> questionnaireTree() async =>
      QuestionnaireTree.fromMap(await _getJson('/questionnaire'));

  /// `POST /wiki/promote` — pin an AI-only report page ([pageType] one of
  /// `face_analysis`, `body_analysis`, `web_findings`) into the user's public
  /// story. Best-effort; a no-op server-side until the endpoint ships.
  Future<void> promoteWikiPage(String pageType) =>
      _postJsonOk('/wiki/promote', {'page_type': pageType});

  /// `POST /dm/{threadId}/messages` — send a DM message (§6.6). For `image` /
  /// `file` messages [body] is an optional caption and the attachment metadata
  /// (already uploaded under `uploads/{uid}/dm/{threadId}/…`) rides along.
  Future<void> sendDmMessage(
    String threadId, {
    required String type,
    String body = '',
    String attachmentUrl = '',
    String attachmentPath = '',
    String mime = '',
    String fileName = '',
    int size = 0,
  }) =>
      _postJsonOk('/dm/$threadId/messages', {
        'type': type,
        'body': body,
        if (attachmentUrl.isNotEmpty) 'attachment_url': attachmentUrl,
        if (attachmentPath.isNotEmpty) 'attachment_path': attachmentPath,
        if (mime.isNotEmpty) 'mime': mime,
        if (fileName.isNotEmpty) 'file_name': fileName,
        if (size > 0) 'size': size,
      });

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

  /// `POST /wiki/reset` — wipe what Ayma has learned (`wiki_pages` /
  /// `raw_turns` / `pending_questions`); account, profile and auth stay (§14.2).
  Future<void> resetWiki() => _postJsonOk('/wiki/reset', const {});

  /// `POST /voice/context` — mirror the screen the user is on, so the voice
  /// agent's `current_screen` tool can answer "what do you think of them?".
  /// Sent only while a voice session is live; an empty body clears it.
  Future<void> setVoiceContext(Map<String, dynamic> ctx) =>
      _postJsonOk('/voice/context', ctx);

  Future<void> clearVoiceContext() =>
      _postJsonOk('/voice/context', const {'screen': ''});

  // --- Your Story editor -------------------------------------------------

  Future<Map<String, dynamic>> _getJson(String path,
      [Map<String, String> query = const {}]) async {
    final uri = _uri(path).replace(
        queryParameters: query.isEmpty ? null : query);
    final r = await _http.get(uri, headers: await _headers());
    if (r.statusCode != 200) {
      throw ApiException('$path failed.',
          statusCode: r.statusCode, body: r.body);
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _sendJson(
    String method,
    String path,
    Map<String, dynamic> body,
  ) async {
    final req = http.Request(method, _uri(path))
      ..headers.addAll(await _headers())
      ..body = jsonEncode(body);
    final res = await http.Response.fromStream(await _http.send(req));
    if (res.statusCode != 200) {
      throw ApiException('$path failed.',
          statusCode: res.statusCode, body: res.body);
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// `GET /story` — the whole story document (one call): every visible section.
  /// The client renders the Public preview by filtering `visibility == 'public'`
  /// + stripping `{{private}}` spans; each section has its own version history.
  Future<StoryData> storyGet() async {
    final m = await _getJson('/story');
    return StoryData(
      sections: ((m['sections'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => StorySection.fromMap(e.cast<String, dynamic>()))
          .toList(),
    );
  }

  /// `PUT /story/section` — persist an edited section body (as a `user_edits`
  /// override), optionally changing its visibility. Commits a version to the
  /// section's history; returns that version id.
  Future<String> storySaveSection({
    required String pageId,
    required String body,
    String? visibility,
  }) async {
    final m = await _sendJson('PUT', '/story/section', {
      'page_id': pageId,
      'body': body,
      if (visibility != null) 'visibility': visibility,
    });
    return m['head_version_id'] as String? ?? '';
  }

  /// `POST /story/section/visibility` — flip a whole section between `public`
  /// and `private`.
  Future<String> storySetVisibility({
    required String pageId,
    required String visibility,
  }) async {
    final m = await _sendJson('POST', '/story/section/visibility', {
      'page_id': pageId,
      'visibility': visibility,
    });
    return m['head_version_id'] as String? ?? '';
  }

  /// `POST /story/edit` — one turn of the passage chat. [messages] is the
  /// running thread (`role` = `user` | `ayma`). Returns Ayma's reply and, when
  /// she proposes a concrete rewrite, the full revised section body.
  Future<StoryChatReply> storyEdit({
    required String pageId,
    required String selection,
    required List<Map<String, String>> messages,
  }) async {
    final m = await _sendJson('POST', '/story/edit', {
      'page_id': pageId,
      'selection': selection,
      'messages': messages,
    });
    return StoryChatReply(
      reply: m['reply'] as String? ?? '',
      revisedBody: m['revised_body'] as String? ?? '',
      action: m['action'] as String? ?? 'chat',
      targetVisibility: m['target_visibility'] as String?,
      usageCapped: m['usage_capped'] == true,
    );
  }

  /// `POST /story/section/remove` — take a section out of the editor (Ayma
  /// keeps it; its pre-delete state stays in history for a revert).
  Future<void> storyRemoveSection(String pageId) => _sendJson(
      'POST', '/story/section/remove', {'page_id': pageId});

  /// `GET /story/section/{pageId}/versions` — that section's history, newest
  /// first.
  Future<List<StoryVersion>> storySectionVersions(String pageId) async {
    final r = await _http.get(
      _uri('/story/section/${Uri.encodeComponent(pageId)}/versions'),
      headers: await _headers(),
    );
    if (r.statusCode != 200) {
      throw ApiException('/story section versions failed.',
          statusCode: r.statusCode, body: r.body);
    }
    return (jsonDecode(r.body) as List)
        .whereType<Map>()
        .map((e) => StoryVersion.fromMap(e.cast<String, dynamic>()))
        .toList();
  }

  /// `GET /story/section/{pageId}/versions/{versionId}` — one stored version.
  Future<StorySectionVersion> storySectionVersion(
      String pageId, String versionId) async {
    final m = await _getJson(
        '/story/section/${Uri.encodeComponent(pageId)}'
        '/versions/${Uri.encodeComponent(versionId)}');
    return StorySectionVersion.fromMap(m);
  }

  /// `POST /story/section/revert` — restore one section's body + visibility
  /// from one of its own versions.
  Future<String> storySectionRevert({
    required String pageId,
    required String versionId,
  }) async {
    final m = await _sendJson('POST', '/story/section/revert', {
      'page_id': pageId,
      'version_id': versionId,
    });
    return m['head_version_id'] as String? ?? '';
  }

  /// `GET /usage` — lifetime Gemini-token usage + the derived credit balance.
  Future<UsageSummary> usage() async {
    final r = await _http.get(_uri('/usage'), headers: await _headers());
    if (r.statusCode != 200) {
      throw ApiException('usage failed.',
          statusCode: r.statusCode, body: r.body);
    }
    return _usageFrom(jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// `POST /credits/topup` — reload the credit balance (free for now, no
  /// payment). Returns the refreshed usage view.
  Future<UsageSummary> topUpCredits() async {
    final r = await _http.post(_uri('/credits/topup'), headers: await _headers());
    if (r.statusCode != 200) {
      throw ApiException('top-up failed.',
          statusCode: r.statusCode, body: r.body);
    }
    return _usageFrom(jsonDecode(r.body) as Map<String, dynamic>);
  }

  UsageSummary _usageFrom(Map<String, dynamic> m) {
    final credits = (m['credits'] as Map?) ?? const {};
    final costs = (m['costs'] as Map?) ?? const {};
    final grant = (credits['grant'] as num?)?.toInt() ?? 0;
    final added = (credits['added'] as num?)?.toInt() ?? 0;
    final used = (credits['used'] as num?)?.toInt() ?? 0;
    return UsageSummary(
      total: (m['total'] as num?)?.toInt() ?? 0,
      cap: (m['cap'] as num?)?.toInt() ?? 0,
      remaining: (m['remaining'] as num?)?.toInt() ?? 0,
      features: ((m['features'] as Map?) ?? {}).map(
        (k, v) => MapEntry(k.toString(), (v as num).toInt()),
      ),
      creditGrant: grant,
      creditsAdded: added,
      creditsUsed: used,
      creditsRemaining: (credits['remaining'] as num?)?.toInt() ??
          (grant + added - used).clamp(0, grant + added),
      tokensPerCredit: (m['tokens_per_credit'] as num?)?.toInt() ?? 1000,
      costs: costs.map((k, v) => MapEntry(k.toString(), (v as num).toInt())),
    );
  }

  /// `POST /check-compatibility` — the on-demand pairwise match-score check
  /// (§5.3). Token-intensive: the client shows its credit cost on the button.
  Future<MatchScoreResult> checkCompatibility(
    String otherUid, {
    bool force = false,
  }) async {
    final r = await _http.post(_uri('/check-compatibility'),
        headers: await _headers(),
        body: jsonEncode({'other_uid': otherUid, 'force': force}));
    if (r.statusCode != 200) {
      throw ApiException('compatibility check failed.',
          statusCode: r.statusCode, body: r.body);
    }
    final m = jsonDecode(r.body) as Map<String, dynamic>;
    return MatchScoreResult(
      ok: m['ok'] == true,
      usageCapped: m['usage_capped'] == true,
      queued: m['queued'] == true,
      score: (m['score'] as num?)?.toDouble(),
      matchId: m['match_id'] as String?,
    );
  }

  /// `GET /match/{id}` — the stored, shareable match report (score, what lines
  /// up / what doesn't, the note written to you, both photos). 404 → null.
  Future<MatchReport?> matchReport(String matchId) async {
    final r = await _http.get(
      _uri('/match/${Uri.encodeComponent(matchId)}'),
      headers: await _headers(),
    );
    if (r.statusCode == 404) return null;
    if (r.statusCode != 200) {
      throw ApiException('match report failed.',
          statusCode: r.statusCode, body: r.body);
    }
    return MatchReport.fromMap(jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// `POST /profiles/mini` — name + resolved photo URL for a batch of users
  /// (message-list rows, match cards). `{uid: MiniProfile}`.
  Future<Map<String, MiniProfile>> miniProfiles(List<String> uids) async {
    if (uids.isEmpty) return const {};
    final r = await _http.post(
      _uri('/profiles/mini'),
      headers: await _headers(),
      body: jsonEncode({'uids': uids}),
    );
    if (r.statusCode != 200) {
      throw ApiException('mini profiles failed.',
          statusCode: r.statusCode, body: r.body);
    }
    final m = (jsonDecode(r.body) as Map<String, dynamic>)['profiles']
            as Map<String, dynamic>? ??
        const {};
    return m.map((k, v) {
      final e = (v as Map).cast<String, dynamic>();
      return MapEntry(
        k,
        MiniProfile(
          name: e['name'] as String? ?? '',
          photo: e['photo'] as String? ?? '',
          online: e['online'] == true,
        ),
      );
    });
  }

  /// `GET /wiki/ai-view` — the compiled wiki context Ayma reads about the
  /// caller, verbatim, plus every photo Ayma holds of them (debug).
  Future<AiNotes> aiNotes() async {
    final r = await _http.get(_uri('/wiki/ai-view'), headers: await _headers());
    if (r.statusCode != 200) {
      throw ApiException('ai notes failed.',
          statusCode: r.statusCode, body: r.body);
    }
    final m = jsonDecode(r.body) as Map<String, dynamic>;
    return AiNotes(
      text: m['text'] as String? ?? '',
      photos: (m['photos'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => AiNotePhoto(
                url: e['url'] as String? ?? '',
                source: e['source'] as String? ?? '',
              ))
          .where((p) => p.url.isNotEmpty)
          .toList(),
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
      currentLanguage: m['current_language'] as String? ?? '',
      languageExamples: ((m['language_examples'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList(),
    );
  }

  /// `GET /voice/preview/{name}` — a download URL for a short spoken sample in
  /// that voice preset ("Hi, I'm Ayma…"), so the picker can play it before the
  /// user commits (§13.3). Cached server-side after the first request.
  Future<String> voicePreviewUrl(String voiceName) async {
    final r = await _http.get(
      _uri('/voice/preview/${Uri.encodeComponent(voiceName)}'),
      headers: await _headers(),
    );
    if (r.statusCode != 200) {
      throw ApiException('voice preview failed.',
          statusCode: r.statusCode, body: r.body);
    }
    return (jsonDecode(r.body) as Map<String, dynamic>)['url'] as String? ?? '';
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

  /// `POST /feedback` — one-tap / typed feedback about Ayma's conduct in the
  /// conversation (§15). `quote` is the Ayma message being thumbed-down.
  Future<void> submitFeedback({
    String category = 'thumbs_down',
    String quote = '',
    String note = '',
    String sessionId = '',
  }) =>
      _postJsonOk('/feedback', {
        'category': category,
        'quote': quote,
        'note': note,
        'session_id': sessionId,
      });

  /// `POST /product-feedback` — a bug report or feature request from the
  /// Profile screen (§15). `imagePaths` are storage paths already uploaded
  /// under `uploads/{uid}/`.
  Future<void> submitProductFeedback({
    required String kind,
    required String text,
    List<String> imagePaths = const [],
    String appVersion = '',
  }) =>
      _postJsonOk('/product-feedback', {
        'kind': kind,
        'text': text,
        'image_paths': imagePaths,
        'app_version': appVersion,
      });

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

  /// `POST /explore/unlike` — undo a like (§6.5); idempotent. Drops the pair
  /// out of each other's matches when the like had made them mutual.
  Future<void> unlikeProfile(String otherUid) =>
      _postJsonOk('/explore/unlike', {'other_uid': otherUid});

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
    String imagePath = '',
    String storyPageId = '',
    String storyPassage = '',
    bool profileEdit = false,
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
          'image_path': imagePath,
          'story_page_id': storyPageId,
          'story_passage': storyPassage,
          'profile_edit': profileEdit,
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
    return ChatResult.fromMap(decoded);
  }

  /// `POST /chat/stream` — the same turn as [chat] but as Server-Sent Events:
  /// [ChatStatus] items while a tool runs (so the UI can show *"Searching the
  /// web…"* live), then one [ChatReplyEvent] carrying the final [ChatResult].
  /// Throws [ApiException] on a transport / non-200 failure — the caller can
  /// fall back to [chat].
  Stream<ChatEvent> chatStream(
    String message, {
    String sessionId = '',
    String viewingProfileUid = '',
    List<Map<String, String>> recentTurns = const [],
    String imagePath = '',
    String storyPageId = '',
    String storyPassage = '',
    bool profileEdit = false,
  }) async* {
    final req = http.Request('POST', _uri('/chat/stream'))
      ..headers.addAll(await _headers())
      ..body = jsonEncode({
        'message': message,
        'session_id': sessionId,
        'viewing_profile_uid': viewingProfileUid,
        'recent_turns': recentTurns,
        'image_path': imagePath,
        'story_page_id': storyPageId,
        'story_passage': storyPassage,
        'profile_edit': profileEdit,
      });

    final http.StreamedResponse res;
    try {
      res = await _http.send(req);
    } on http.ClientException catch (e) {
      throw ApiException('Network error: ${e.message}');
    }
    if (res.statusCode != 200) {
      final body = await res.stream.bytesToString();
      throw ApiException('Chat stream failed.',
          statusCode: res.statusCode, body: body);
    }

    var buffer = '';
    await for (final chunk
        in res.stream.transform(utf8.decoder)) {
      buffer += chunk;
      while (true) {
        final nl = buffer.indexOf('\n\n');
        if (nl < 0) break;
        final frame = buffer.substring(0, nl);
        buffer = buffer.substring(nl + 2);
        for (final line in frame.split('\n')) {
          if (!line.startsWith('data: ')) continue;
          final Map<String, dynamic> m;
          try {
            m = jsonDecode(line.substring(6)) as Map<String, dynamic>;
          } catch (_) {
            continue;
          }
          switch (m['type']) {
            case 'status':
              yield ChatStatus(m['label'] as String? ?? 'Working…');
            case 'reply':
              yield ChatReplyEvent(ChatResult.fromMap(m));
            case 'error':
              throw ApiException(
                  (m['detail'] as String?) ?? 'Chat stream error.');
          }
        }
      }
    }
  }

  /// `GET /chat/history` — a page of the durable Ayma-tab transcript (§2.2),
  /// oldest-first, plus the ISO cursor for the next older page (null at the
  /// start of history).
  Future<({List<ChatMessage> messages, String? nextBefore})> chatHistory({
    String? before,
    int limit = 40,
  }) async {
    final uri = _uri('/chat/history').replace(queryParameters: {
      'limit': '$limit',
      if (before != null && before.isNotEmpty) 'before': before,
    });
    final r = await _http.get(uri, headers: await _headers());
    if (r.statusCode != 200) {
      throw ApiException('chat history failed.',
          statusCode: r.statusCode, body: r.body);
    }
    final decoded = jsonDecode(r.body) as Map<String, dynamic>;
    return (
      messages: ((decoded['messages'] as List?) ?? [])
          .map((m) => ChatMessage.fromMap(m as Map<String, dynamic>))
          .toList(),
      nextBefore: decoded['next_before'] as String?,
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
    this.usageCapped = false,
  });

  final String sessionMode;
  final String livekitUrl;
  final String livekitToken;
  final String room;

  /// The account is soft-deleted — the client shows the recovery screen (§3.6).
  final bool recoveryRequired;

  /// Out of credits — the voice session can't start (§15). The chat screen
  /// surfaces "reload credits".
  final bool usageCapped;
}

/// One Explore feed card (§6.4).
class ExploreCard {
  const ExploreCard({
    required this.uid,
    required this.name,
    required this.age,
    required this.location,
    this.photoPath,
    this.photoUrl = '',
    this.score,
    this.liked = false,
    this.mutual = false,
    this.isSelf = false,
    this.paused = false,
  });

  final String uid;
  final String name;
  final int? age;
  final String location;
  final String? photoPath;

  /// Ready token URL for the primary photo (resolved server-side — the client
  /// can't read another user's Storage path itself).
  final String photoUrl;
  final double? score;

  /// You liked them / it's a mutual like — for the Explore filter chips.
  final bool liked;
  final bool mutual;

  /// The caller's own card — Explore now includes it (no Like/Pass).
  final bool isSelf;

  /// Your own card while "Pause matching" is on — only you can see it.
  final bool paused;

  factory ExploreCard.fromMap(Map<String, dynamic> m) => ExploreCard(
        uid: m['uid'] as String? ?? '',
        name: m['name'] as String? ?? '',
        age: (m['age'] as num?)?.toInt(),
        location: m['location'] as String? ?? '',
        photoPath: m['photo_path'] as String?,
        photoUrl: m['photo_url'] as String? ?? '',
        score: (m['score'] as num?)?.toDouble(),
        liked: m['liked'] == true,
        mutual: m['mutual'] == true,
        isSelf: m['self'] == true,
        paused: m['paused'] == true,
      );
}

/// One section of another user's public profile — a wiki page rendered as
/// `user_edits ?? ai_body`.
class ProfileSection {
  const ProfileSection({required this.pageType, required this.title, required this.body});

  final String pageType;
  final String title;
  final String body;

  factory ProfileSection.fromMap(Map<String, dynamic> m) => ProfileSection(
        pageType: m['page_type'] as String? ?? 'misc',
        title: m['title'] as String? ?? '',
        body: m['body'] as String? ?? '',
      );
}

/// One field of the owner's structured physical-attributes record
/// (`GET /physical-attributes`, or the `physical_attributes` block on the
/// owner's own `/explore/profile/{uid}`). [source] is `stated` (from the
/// user's own answers), `photo` (read from their pictures) or `none`.
class PhysicalAttribute {
  const PhysicalAttribute({
    required this.field,
    required this.value,
    required this.source,
    this.confidence = '',
  });

  final String field;
  final String value;
  final String source;

  /// `high` | `medium` | `low` | `none` — drives the confidence dot in the
  /// report view. Empty when the caller doesn't surface it.
  final String confidence;

  bool get isStated => source == 'stated';
  bool get isFromPhotos => source == 'photo';

  static PhysicalAttribute? fromEntry(String field, Object? raw) {
    if (raw is! Map) return null;
    final v = raw['value'];
    if (v == null) return null;
    final text = v is num ? v.toString() : v.toString().trim();
    if (text.isEmpty || text.toLowerCase() == 'unknown') return null;
    return PhysicalAttribute(
      field: field,
      value: text,
      source: (raw['source'] as String?) ?? 'none',
      confidence: (raw['confidence'] as String?) ?? '',
    );
  }

  /// Parse the `fields` map into a list, known values only, in a stable order.
  static List<PhysicalAttribute> listFrom(Map<String, dynamic>? fields) {
    if (fields == null) return const [];
    const order = [
      'race_ethnicity', 'skin_tone', 'eye_color', 'hair_color', 'hair_length',
      'hair_type', 'height_estimate_cm', 'weight_estimate_kg', 'build',
      'facial_hair', 'glasses', 'visible_tattoos', 'visible_piercings',
      'distinguishing_features',
    ];
    final out = <PhysicalAttribute>[];
    for (final f in order) {
      final a = PhysicalAttribute.fromEntry(f, fields[f]);
      if (a != null) out.add(a);
    }
    return out;
  }
}

/// Another user's public profile (`GET /explore/profile/{uid}`).
class PublicProfile {
  const PublicProfile({
    required this.uid,
    required this.name,
    required this.age,
    required this.location,
    required this.photos,
    required this.sections,
    required this.isSelf,
    required this.blocked,
    required this.liked,
    required this.score,
    required this.threadId,
    this.deepDiveId = '',
    this.physicalAttributes = const [],
  });

  final String uid;
  final String name;
  final int? age;
  final String location;

  /// Ready-to-render download URLs, primary first.
  final List<String> photos;
  final List<ProfileSection> sections;
  final bool isSelf;
  final bool blocked;
  final bool liked;
  final double? score;

  /// Sorted-pair id shared by `matches` and `dm_threads`; null when self.
  final String? threadId;

  /// Id of a stored web dive on this person the caller can re-open — empty
  /// when they've never run one. Drives "View research" vs. "Deep dive".
  final String deepDiveId;
  /// The owner's structured physical attributes, each with a source tag.
  /// Only populated on the owner's own view; empty otherwise.
  final List<PhysicalAttribute> physicalAttributes;

  factory PublicProfile.fromMap(Map<String, dynamic> m) => PublicProfile(
        uid: m['uid'] as String? ?? '',
        name: m['name'] as String? ?? '',
        age: (m['age'] as num?)?.toInt(),
        location: m['location'] as String? ?? '',
        photos: ((m['photos'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
        sections: ((m['pages'] as List?) ?? const [])
            .map((e) => ProfileSection.fromMap(e as Map<String, dynamic>))
            .toList(),
        isSelf: m['self'] == true,
        blocked: m['blocked'] == true,
        liked: m['liked'] == true,
        score: (m['score'] as num?)?.toDouble(),
        threadId: m['thread_id'] as String?,
        deepDiveId: m['deep_dive_id'] as String? ?? '',
        physicalAttributes: PhysicalAttribute.listFrom(
          (m['physical_attributes'] as Map<String, dynamic>?)?['fields']
              as Map<String, dynamic>?,
        ),
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
    this.imageRejected = false,
    this.usageCapped = false,
    this.toolsUsed = const [],
  });

  factory ChatResult.fromMap(Map<String, dynamic> m) => ChatResult(
        // `/chat` sends `reply`; a `/chat/stream` reply event sends `text`.
        reply: (m['reply'] ?? m['text']) as String? ?? '',
        capped: m['capped'] == true,
        fallbackForm: m['fallback_form'] == true,
        imageRejected: m['image_rejected'] == true,
        usageCapped: m['usage_capped'] == true,
        toolsUsed: ((m['tools_used'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
      );

  final String reply;
  final bool capped;
  final bool fallbackForm;

  /// The attached image failed the content check — nothing was stored.
  final bool imageRejected;

  /// Out of credits — Ayma paused for now.
  final bool usageCapped;

  /// User-facing labels for the tools Ayma used on this turn ("Searched the
  /// web", …). Empty when she just answered.
  final List<String> toolsUsed;
}

/// One frame of [ApiClient.chatStream].
sealed class ChatEvent {
  const ChatEvent();
}

/// A live "…ing" label while a tool runs ("Searching the web…").
class ChatStatus extends ChatEvent {
  const ChatStatus(this.label);
  final String label;
}

/// The finished turn.
class ChatReplyEvent extends ChatEvent {
  const ChatReplyEvent(this.result);
  final ChatResult result;
}

/// One persisted message from `GET /chat/history` (§2.2). [imagePath] is a
/// `uploads/{uid}/…` path the client resolves to a download URL itself.
class ChatMessage {
  const ChatMessage({
    required this.role,
    required this.text,
    this.imagePath = '',
    this.tools = const [],
    this.subjectImage = '',
  });

  final String role; // 'user' | 'ayma'
  final String text;
  final String imagePath;

  /// User-facing labels for what Ayma did on this turn ("Searched the web",
  /// "Researched Jane Doe online") — the kicker above the reply.
  final List<String> tools;

  /// Resolved photo URL for the person a skill was run on (Explore deep-dive),
  /// shown as a small avatar next to the kicker. Empty when not applicable.
  final String subjectImage;

  factory ChatMessage.fromMap(Map<String, dynamic> m) => ChatMessage(
        role: m['role'] as String? ?? 'ayma',
        text: m['text'] as String? ?? '',
        imagePath: m['image_path'] as String? ?? '',
        tools: ((m['tools'] as List?) ?? const [])
            .map((e) => e.toString())
            .where((s) => s.isNotEmpty)
            .toList(),
        subjectImage: m['subject_image'] as String? ?? '',
      );
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

/// `GET /usage` result — token accounting plus the user-facing credit balance
/// (a display layer over tokens) and per-action credit costs.
class UsageSummary {
  const UsageSummary({
    required this.total,
    required this.cap,
    required this.remaining,
    required this.features,
    this.creditGrant = 0,
    this.creditsAdded = 0,
    this.creditsUsed = 0,
    this.creditsRemaining = 0,
    this.tokensPerCredit = 1000,
    this.costs = const {},
  });

  final int total;
  final int cap;
  final int remaining;

  /// Tokens per feature: `chat`, `voice`, `matching`, `wiki`, `explore`,
  /// `reengage`, …
  final Map<String, int> features;

  /// Credits: the plan grant, credits added by top-ups, credits spent, and
  /// what remains (`grant + added − used`).
  final int creditGrant;
  final int creditsAdded;
  final int creditsUsed;
  final int creditsRemaining;

  /// How many tokens one credit is worth (for converting feature buckets).
  final int tokensPerCredit;

  /// Per-action credit estimates keyed by action (only actions that spend
  /// Gemini tokens — currently just `match_score`). Shown on those buttons.
  final Map<String, int> costs;

  double get fraction => cap <= 0 ? 0 : (total / cap).clamp(0.0, 1.0);
  bool get atCap => cap > 0 && total >= cap;

  /// Lifetime credits this account has been granted (free grant + top-ups).
  /// Informational only — the balance the user sees is [creditsRemaining].
  int get creditsTotal => creditGrant + creditsAdded;

  /// Credits attributable to one feature bucket (tokens ÷ ratio, rounded up).
  int creditsForFeature(int tokens) => tokensPerCredit <= 0
      ? 0
      : (tokens + tokensPerCredit - 1) ~/ tokensPerCredit;

  int get costMatchScore => costs['match_score'] ?? 0;
}

/// `POST /check-compatibility` result.
class MatchScoreResult {
  const MatchScoreResult({
    required this.ok,
    required this.usageCapped,
    this.queued = false,
    this.score,
    this.matchId,
  });

  final bool ok;
  final bool usageCapped;

  /// Scoring is running server-side; poll `GET /match/{id}` or wait for the
  /// push. [score] is null in this case.
  final bool queued;
  final double? score;
  final String? matchId;
}

/// Name + resolved photo URL for a user, from `POST /profiles/mini`.
class MiniProfile {
  const MiniProfile({
    required this.name,
    required this.photo,
    this.online = false,
  });
  final String name;
  final String photo;

  /// Touched the app in the last 5 minutes.
  final bool online;
}

/// One rubric dimension of a match score (§5.4).
class MatchDimension {
  const MatchDimension({
    required this.key,
    required this.label,
    required this.score, // 0..100
    required this.weight, // 0..1
    required this.rationale,
    required this.evidence,
    required this.confidence, // low | medium | high
    this.source = 'llm', // structured | llm | mixed
    this.coveredNodes = const [],
  });

  final String key;
  final String label;
  final double score;
  final double weight;
  final String rationale;
  final List<String> evidence;
  final String confidence;

  /// How this dimension's number was produced: `structured` = measured from
  /// the questionnaire answers, `llm` = estimated from the written profiles.
  final String source;

  /// The questionnaire node ids that fed a `structured` dimension.
  final List<String> coveredNodes;

  bool get isMeasured => source == 'structured';

  factory MatchDimension.fromMap(Map<String, dynamic> m) => MatchDimension(
        key: m['key'] as String? ?? '',
        label: m['label'] as String? ?? '',
        score: (m['score'] as num?)?.toDouble() ?? 0,
        weight: (m['weight'] as num?)?.toDouble() ?? 0,
        rationale: m['rationale'] as String? ?? '',
        evidence: (m['evidence'] as List? ?? const [])
            .map((e) => e.toString())
            .where((s) => s.isNotEmpty)
            .toList(),
        confidence: m['confidence'] as String? ?? 'low',
        source: m['source'] as String? ?? 'llm',
        coveredNodes: (m['covered_nodes'] as List? ?? const [])
            .map((e) => e.toString())
            .toList(),
      );
}

/// A hard dealbreaker the deterministic pass detected between the two people.
class MatchGateFailure {
  const MatchGateFailure({required this.label, required this.reason});

  final String label;
  final String reason;

  factory MatchGateFailure.fromMap(Map<String, dynamic> m) => MatchGateFailure(
        label: m['label'] as String? ?? '',
        reason: m['reason'] as String? ?? '',
      );
}

/// `GET /match/{id}` — the shareable match report for one pair.
class MatchReport {
  const MatchReport({
    required this.matchId,
    required this.score,
    required this.dimensions,
    required this.shared,
    required this.tensions,
    required this.missing,
    required this.explanation,
    required this.otherUid,
    required this.otherName,
    required this.otherPhoto,
    required this.myPhoto,
    this.scoreConfidence,
    this.confidenceNote = '',
    this.gateFailures = const [],
    this.method = '',
  });

  final String matchId;
  final double? score;
  final List<MatchDimension> dimensions;
  final List<String> shared;
  final List<String> tensions;

  /// Topics the wikis didn't cover well enough to score confidently —
  /// what to fill in on the profiles to sharpen the number.
  final List<String> missing;
  final String explanation;
  final String otherUid;
  final String otherName;
  final String otherPhoto;
  final String myPhoto;

  /// 0..1 — how much to trust the number. High when both profiles are
  /// detailed and the dealbreaker gates had their data.
  final double? scoreConfidence;
  final String confidenceNote;

  /// Hard dealbreakers detected deterministically. Non-empty ⇒ the score is
  /// capped low.
  final List<MatchGateFailure> gateFailures;

  /// One-line note on how the score was built (structured vs. LLM).
  final String method;

  /// `high` / `medium` / `low`, from [scoreConfidence]. Empty when unknown.
  String get confidenceBand {
    final c = scoreConfidence;
    if (c == null) return '';
    if (c >= 0.66) return 'high';
    if (c >= 0.4) return 'medium';
    return 'low';
  }

  factory MatchReport.fromMap(Map<String, dynamic> m) {
    final other = (m['other'] as Map?) ?? const {};
    final me = (m['me'] as Map?) ?? const {};
    List<String> list(Object? v) => (v as List? ?? const [])
        .map((e) => e.toString())
        .where((s) => s.isNotEmpty)
        .toList();
    return MatchReport(
      matchId: m['match_id'] as String? ?? '',
      score: (m['score'] as num?)?.toDouble(),
      dimensions: (m['dimensions'] as List? ?? const [])
          .map((e) =>
              MatchDimension.fromMap((e as Map).cast<String, dynamic>()))
          .toList(),
      shared: list(m['shared']),
      tensions: list(m['tensions']),
      missing: list(m['missing']),
      explanation: m['explanation'] as String? ?? '',
      otherUid: other['uid'] as String? ?? '',
      otherName: other['name'] as String? ?? '',
      otherPhoto: other['photo'] as String? ?? '',
      myPhoto: me['photo'] as String? ?? '',
      scoreConfidence: (m['score_confidence'] as num?)?.toDouble(),
      confidenceNote: m['confidence_note'] as String? ?? '',
      gateFailures: (m['gate_failures'] as List? ?? const [])
          .map((e) =>
              MatchGateFailure.fromMap((e as Map).cast<String, dynamic>()))
          .toList(),
      method: m['method'] as String? ?? '',
    );
  }
}

class VoicePreset {
  const VoicePreset({required this.name, required this.description});
  final String name;
  final String description;
}

class DeepDiveLink {
  const DeepDiveLink(
      {required this.url, required this.title, required this.isThem});
  final String url;
  final String title;
  final String isThem; // likely | maybe | unclear
}

class DeepDiveResult {
  const DeepDiveResult({
    required this.usageCapped,
    required this.summary,
    required this.isSelf,
    required this.links,
    this.queued = false,
    this.reportId = '',
    this.subjectImage = '',
    this.toolLabel = '',
  });
  final bool usageCapped;

  /// The dive is running server-side and will land in chat history + a push
  /// when done — [summary] is empty. A cached dive comes back inline instead.
  final bool queued;
  final String summary;

  /// Id of the saved dive — reopenable via [ApiClient.deepDiveReport] and used
  /// as the `[deep_dive:<id>]` chat marker. Empty when the dive found nothing.
  final String reportId;
  final bool isSelf;
  final List<DeepDiveLink> links;

  /// Photo URL of the person this dive was about (empty for a self-dive).
  final String subjectImage;

  /// Kicker label to show on the resulting Ayma turn ("Researched X online").
  final String toolLabel;
}

/// `GET /deep-dive-report/{id}` — a stored web dive rendered on its own screen.
class DeepDiveFact {
  const DeepDiveFact({
    required this.claim,
    required this.category,
    required this.sourceUrl,
    required this.confidence,
  });
  final String claim;
  final String category;
  final String sourceUrl;
  final String confidence; // high | medium | low

  factory DeepDiveFact.fromMap(Map m) => DeepDiveFact(
        claim: m['claim'] as String? ?? '',
        category: m['category'] as String? ?? '',
        sourceUrl: m['source_url'] as String? ?? '',
        confidence: m['confidence'] as String? ?? '',
      );
}

/// A face-verified photo of the subject found on the open web.
class DeepDiveWebImage {
  const DeepDiveWebImage({
    required this.url,
    required this.sourcePage,
    required this.similarity,
    required this.verified,
  });
  final String url;
  final String sourcePage;
  final double? similarity;
  final bool verified;

  factory DeepDiveWebImage.fromMap(Map m) => DeepDiveWebImage(
        url: m['url'] as String? ?? '',
        sourcePage: m['source_page'] as String? ?? '',
        similarity: (m['similarity'] as num?)?.toDouble(),
        verified: m['verified'] == true,
      );
}

class DeepDiveReport {
  const DeepDiveReport({
    required this.name,
    required this.summary,
    required this.confidence,
    required this.caveats,
    required this.isSelf,
    required this.otherUid,
    required this.subjectImage,
    required this.createdAt,
    required this.facts,
    required this.links,
    required this.webImages,
  });

  final String name;
  final String summary;
  final String confidence;
  final String caveats;
  final bool isSelf;

  /// The uid of the person this dive is about (empty when it's a self-dive) —
  /// lets "Ask Ayma" hand her the pair context.
  final String otherUid;
  final String subjectImage;
  final String? createdAt;
  final List<DeepDiveFact> facts;
  final List<DeepDiveLink> links;

  /// Photos of the subject found + face-matched online. `verified` ones are
  /// confident matches; unverified means the face check couldn't run.
  final List<DeepDiveWebImage> webImages;

  factory DeepDiveReport.fromMap(Map<String, dynamic> m) {
    final digest = (m['digest'] as Map?) ?? const {};
    return DeepDiveReport(
      name: (m['name'] as String?)?.trim().isNotEmpty == true
          ? m['name'] as String
          : (digest['name'] as String? ?? ''),
      summary: digest['summary'] as String? ?? '',
      confidence: digest['confidence'] as String? ?? '',
      caveats: digest['caveats'] as String? ?? '',
      isSelf: m['is_self'] == true,
      otherUid: m['target_uid'] as String? ?? '',
      subjectImage: m['subject_image'] as String? ?? '',
      createdAt: m['created_at'] as String?,
      facts: (digest['facts'] as List? ?? const [])
          .whereType<Map>()
          .map(DeepDiveFact.fromMap)
          .where((f) => f.claim.isNotEmpty)
          .toList(),
      links: (digest['links'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => DeepDiveLink(
                url: e['url'] as String? ?? '',
                title: e['title'] as String? ?? '',
                isThem: e['is_them'] as String? ?? 'unclear',
              ))
          .where((l) => l.url.isNotEmpty)
          .toList(),
      webImages: (digest['web_images'] as List? ?? const [])
          .whereType<Map>()
          .map(DeepDiveWebImage.fromMap)
          .where((im) => im.url.isNotEmpty)
          .toList(),
    );
  }
}

// --- Face / body reports ---------------------------------------------------

double _asDouble(Object? v) {
  if (v is num) return v.toDouble();
  return double.tryParse('$v') ?? 0.0;
}

List<String> _asStringList(Object? v) => (v as List? ?? const [])
    .map((e) => '$e')
    .where((s) => s.isNotEmpty)
    .toList();

class FaceFeature {
  const FaceFeature(
      {required this.name, required this.score, required this.note});
  final String name;
  final double score;
  final String note;

  factory FaceFeature.fromMap(Map<String, dynamic> m) => FaceFeature(
        name: m['name'] as String? ?? '',
        score: _asDouble(m['score']),
        note: m['note'] as String? ?? '',
      );
}

class FaceRecommendation {
  const FaceRecommendation({required this.category, required this.text});
  final String category;
  final String text;

  factory FaceRecommendation.fromMap(Map<String, dynamic> m) =>
      FaceRecommendation(
        category: m['category'] as String? ?? '',
        text: m['text'] as String? ?? '',
      );
}

class FaceReport {
  const FaceReport({
    required this.usable,
    required this.overallScore,
    required this.verdict,
    required this.verdictNote,
    required this.features,
    required this.quickFacts,
    required this.strengths,
    required this.improvements,
    required this.recommendations,
  });

  final bool usable;
  final double overallScore;
  final String verdict;
  final String verdictNote;
  final List<FaceFeature> features;
  final Map<String, String> quickFacts;
  final List<String> strengths;
  final List<String> improvements;
  final List<FaceRecommendation> recommendations;

  factory FaceReport.fromMap(Map<String, dynamic> m) => FaceReport(
        usable: m['usable'] != false,
        overallScore: _asDouble(m['overall_score']),
        verdict: m['verdict'] as String? ?? '',
        verdictNote: m['verdict_note'] as String? ?? '',
        features: (m['features'] as List? ?? const [])
            .whereType<Map>()
            .map((e) => FaceFeature.fromMap(e.cast<String, dynamic>()))
            .where((f) => f.name.isNotEmpty)
            .toList(),
        quickFacts: ((m['quick_facts'] as Map?) ?? const {}).map(
          (k, v) => MapEntry('$k', '$v'),
        )..removeWhere((_, v) => v.isEmpty),
        strengths: _asStringList(m['strengths']),
        improvements: _asStringList(m['improvements']),
        recommendations: (m['recommendations'] as List? ?? const [])
            .whereType<Map>()
            .map((e) => FaceRecommendation.fromMap(e.cast<String, dynamic>()))
            .where((r) => r.text.isNotEmpty)
            .toList(),
      );
}

class FaceReportResult {
  const FaceReportResult({
    required this.usageCapped,
    required this.report,
    required this.reportId,
  });
  final bool usageCapped;
  final FaceReport? report;
  final String reportId;
}

class BodyFeature {
  const BodyFeature(
      {required this.name, required this.score, required this.note});
  final String name;
  final double score;
  final String note;

  factory BodyFeature.fromMap(Map<String, dynamic> m) => BodyFeature(
        name: m['name'] as String? ?? '',
        score: _asDouble(m['score']),
        note: m['note'] as String? ?? '',
      );
}

class BodyRecommendation {
  const BodyRecommendation({required this.category, required this.text});
  final String category;
  final String text;

  factory BodyRecommendation.fromMap(Map<String, dynamic> m) =>
      BodyRecommendation(
        category: m['category'] as String? ?? '',
        text: m['text'] as String? ?? '',
      );
}

class BodyReport {
  const BodyReport({
    required this.usable,
    required this.overallScore,
    required this.verdict,
    required this.verdictNote,
    required this.features,
    required this.quickFacts,
    required this.strengths,
    required this.improvements,
    required this.recommendations,
  });

  final bool usable;
  final double overallScore;
  final String verdict;
  final String verdictNote;
  final List<BodyFeature> features;
  final Map<String, String> quickFacts;
  final List<String> strengths;
  final List<String> improvements;
  final List<BodyRecommendation> recommendations;

  factory BodyReport.fromMap(Map<String, dynamic> m) => BodyReport(
        usable: m['usable'] != false,
        overallScore: _asDouble(m['overall_score']),
        verdict: m['verdict'] as String? ?? '',
        verdictNote: m['verdict_note'] as String? ?? '',
        features: (m['features'] as List? ?? const [])
            .whereType<Map>()
            .map((e) => BodyFeature.fromMap(e.cast<String, dynamic>()))
            .where((f) => f.name.isNotEmpty)
            .toList(),
        quickFacts: ((m['quick_facts'] as Map?) ?? const {}).map(
          (k, v) => MapEntry('$k', '$v'),
        )..removeWhere((_, v) => v.isEmpty),
        strengths: _asStringList(m['strengths']),
        improvements: _asStringList(m['improvements']),
        recommendations: (m['recommendations'] as List? ?? const [])
            .whereType<Map>()
            .map((e) => BodyRecommendation.fromMap(e.cast<String, dynamic>()))
            .where((r) => r.text.isNotEmpty)
            .toList(),
      );
}

class BodyReportResult {
  const BodyReportResult({
    required this.usageCapped,
    required this.report,
    required this.reportId,
  });
  final bool usageCapped;
  final BodyReport? report;
  final String reportId;
}

/// `GET /skills/report/{kind}/{id}` result — the stored report dict plus when
/// it was produced. Parse [report] with [FaceReport.fromMap] or
/// [BodyReport.fromMap] depending on the marker kind.
class SkillReport {
  const SkillReport({
    required this.report,
    required this.createdAt,
    this.imagePath = '',
  });
  final Map<String, dynamic> report;
  final String? createdAt;

  /// Storage path of the analysed photo, embedded in the report card.
  final String imagePath;
}

/// One row of `GET /skills/reports/{kind}` — the per-skill history on the
/// Skills screen. Tapping opens the full stored report.
class SkillReportSummary {
  const SkillReportSummary({
    required this.id,
    required this.overallScore,
    required this.verdict,
    required this.createdAt,
    this.imagePath = '',
  });
  final String id;
  final double overallScore;
  final String verdict;
  final String? createdAt;
  final String imagePath;

  factory SkillReportSummary.fromMap(Map<String, dynamic> m) =>
      SkillReportSummary(
        id: m['id'] as String? ?? '',
        overallScore: _asDouble(m['overall_score']),
        verdict: m['verdict'] as String? ?? '',
        createdAt: m['created_at'] as String?,
        imagePath: m['image_path'] as String? ?? '',
      );
}

/// Result of `GET /physical-attributes` and `POST /physical-attributes/refresh`.
class PhysicalAttrsResult {
  const PhysicalAttrsResult({
    this.usageCapped = false,
    this.summary = '',
    this.attributes = const [],
    this.photoCount = 0,
    this.updatedAt,
    this.id = '',
  });

  /// True when the caller is out of credits — the refresh didn't run.
  final bool usageCapped;

  /// A short human line ("Physical profile — hair: black (from photos); …").
  final String summary;

  /// Known, source-tagged fields in a stable display order.
  final List<PhysicalAttribute> attributes;
  final int photoCount;
  final String? updatedAt;

  /// Stable id of the re-openable report — a `physical_reports` doc id after an
  /// explicit run, else `current`. Empty only when the record was never built.
  final String id;

  factory PhysicalAttrsResult.fromMap(Map<String, dynamic> m) {
    final record = m['record'] as Map<String, dynamic>?;
    return PhysicalAttrsResult(
      usageCapped: m['usage_capped'] == true,
      summary: m['summary'] as String? ?? '',
      attributes: PhysicalAttribute.listFrom(
        (m['fields'] as Map<String, dynamic>?) ??
            (record?['fields'] as Map<String, dynamic>?),
      ),
      photoCount: (m['photo_count'] as num?)?.toInt() ??
          (record?['photo_count'] as num?)?.toInt() ??
          0,
      updatedAt: record?['updated_at'] as String?,
      id: m['id'] as String? ?? '',
    );
  }
}

/// A stored physical-attributes report (`GET /physical-attributes-report/{id}`),
/// re-opened from a `[physical:<id>]` chat marker or the Skills-screen history.
class PhysicalReport {
  const PhysicalReport({
    required this.id,
    this.summary = '',
    this.photoCount = 0,
    this.attributes = const [],
    this.createdAt,
  });

  final String id;
  final String summary;
  final int photoCount;

  /// Known, source-tagged attributes in a stable display order.
  final List<PhysicalAttribute> attributes;
  final String? createdAt;

  List<PhysicalAttribute> get stated =>
      attributes.where((a) => a.isStated).toList();
  List<PhysicalAttribute> get fromPhotos =>
      attributes.where((a) => !a.isStated).toList();

  factory PhysicalReport.fromMap(Map<String, dynamic> m) => PhysicalReport(
        id: m['id'] as String? ?? '',
        summary: m['summary'] as String? ?? '',
        photoCount: (m['photo_count'] as num?)?.toInt() ?? 0,
        attributes: PhysicalAttribute.listFrom(
          m['fields'] as Map<String, dynamic>?,
        ),
        createdAt: m['created_at'] as String?,
      );
}

/// One row of `GET /physical-attributes/history` — a past run on the Skills
/// screen. Tapping re-opens the full report.
class PhysicalReportSummary {
  const PhysicalReportSummary({
    required this.id,
    this.summary = '',
    this.photoCount = 0,
    this.attributeCount = 0,
    this.createdAt,
  });

  final String id;
  final String summary;
  final int photoCount;
  final int attributeCount;
  final String? createdAt;

  factory PhysicalReportSummary.fromMap(Map<String, dynamic> m) =>
      PhysicalReportSummary(
        id: m['id'] as String? ?? '',
        summary: m['summary'] as String? ?? '',
        photoCount: (m['photo_count'] as num?)?.toInt() ?? 0,
        attributeCount: (m['attribute_count'] as num?)?.toInt() ?? 0,
        createdAt: m['created_at'] as String?,
      );
}

/// `{hasFacePhoto, hasBodyPhoto}` from `GET /appearance/coverage` — whether the
/// user's current grid has a usable face shot and a usable full-length shot.
class AppearanceCoverage {
  const AppearanceCoverage({
    this.hasFacePhoto = false,
    this.hasBodyPhoto = false,
  });

  final bool hasFacePhoto;
  final bool hasBodyPhoto;
}

/// The unified Appearance report (`GET /appearance/report/{id}`,
/// `POST /appearance/report`): structured attributes plus an honest face and
/// physique read. A face / body section is `null` with a non-empty status
/// (`needs_face_photo` / `needs_body_photo`) when coverage was missing.
class AppearanceReport {
  const AppearanceReport({
    required this.id,
    this.createdAt,
    this.attributes = const [],
    this.attributesSummary = '',
    this.attributesStatus = '',
    this.face,
    this.faceStatus = '',
    this.body,
    this.bodyStatus = '',
    this.photoCount = 0,
  });

  final String id;
  final String? createdAt;

  /// Known, source-tagged physical attributes in a stable display order.
  final List<PhysicalAttribute> attributes;
  final String attributesSummary;

  /// `` when produced, else `needs_photo`.
  final String attributesStatus;

  final FaceReport? face;

  /// `` when produced, else `needs_face_photo`.
  final String faceStatus;

  final BodyReport? body;

  /// `` when produced, else `needs_body_photo`.
  final String bodyStatus;

  final int photoCount;

  List<PhysicalAttribute> get statedAttributes =>
      attributes.where((a) => a.isStated).toList();
  List<PhysicalAttribute> get photoAttributes =>
      attributes.where((a) => !a.isStated).toList();

  factory AppearanceReport.fromMap(Map<String, dynamic> m) {
    final attrs = (m['attributes'] as Map?)?.cast<String, dynamic>() ?? const {};
    final face = (m['face'] as Map?)?.cast<String, dynamic>() ?? const {};
    final body = (m['body'] as Map?)?.cast<String, dynamic>() ?? const {};
    final faceStatus = face['status'] as String? ?? '';
    final bodyStatus = body['status'] as String? ?? '';
    return AppearanceReport(
      id: m['id'] as String? ?? '',
      createdAt: m['created_at'] as String?,
      attributes: PhysicalAttribute.listFrom(
        (attrs['record'] as Map?)?.cast<String, dynamic>(),
      ),
      attributesSummary: attrs['summary'] as String? ?? '',
      attributesStatus: attrs['status'] as String? ?? '',
      face: faceStatus.isEmpty && face.isNotEmpty
          ? FaceReport.fromMap(face)
          : null,
      faceStatus: faceStatus,
      body: bodyStatus.isEmpty && body.isNotEmpty
          ? BodyReport.fromMap(body)
          : null,
      bodyStatus: bodyStatus,
      photoCount: (m['photo_count'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Result of `POST /appearance/report`.
class AppearanceReportResult {
  const AppearanceReportResult({
    required this.usageCapped,
    required this.reportId,
    required this.report,
  });
  final bool usageCapped;
  final String reportId;
  final AppearanceReport? report;
}

/// One row of `GET /appearance/history` — a past Appearance run, or a
/// pre-merge per-skill report surfaced read-only ([legacy] true).
class AppearanceHistoryRow {
  const AppearanceHistoryRow({
    required this.id,
    this.createdAt,
    this.hasFace = false,
    this.hasBody = false,
    this.summary = '',
    this.legacy = false,
    this.kind = 'appearance',
  });

  final String id;
  final String? createdAt;
  final bool hasFace;
  final bool hasBody;
  final String summary;
  final bool legacy;

  /// `appearance` | `face` | `body` | `physical`.
  final String kind;

  factory AppearanceHistoryRow.fromMap(Map<String, dynamic> m) =>
      AppearanceHistoryRow(
        id: m['id'] as String? ?? '',
        createdAt: m['created_at'] as String?,
        hasFace: m['has_face'] == true,
        hasBody: m['has_body'] == true,
        summary: m['summary'] as String? ?? '',
        legacy: m['legacy'] == true,
        kind: m['kind'] as String? ?? 'appearance',
      );
}

/// The 1–5 (or arbitrary min/max) scale a `kind == 'scale'` [QuestionNode]
/// asks on. [minLabel] / [maxLabel] are the human anchors for each end.
class QuestionScale {
  const QuestionScale({
    this.min = 1,
    this.max = 5,
    this.minLabel = '',
    this.maxLabel = '',
  });

  final int min;
  final int max;
  final String minLabel;
  final String maxLabel;

  factory QuestionScale.fromMap(Map<String, dynamic> m) => QuestionScale(
        min: (m['min'] as num?)?.toInt() ?? 1,
        max: (m['max'] as num?)?.toInt() ?? 5,
        minLabel: (m['min_label'] ?? m['minLabel']) as String? ?? '',
        maxLabel: (m['max_label'] ?? m['maxLabel']) as String? ?? '',
      );
}

/// One node of the profile questionnaire tree — a single thing Ayma tries to
/// learn about the user. Appears both in `GET /questionnaire` (`nodes`) and in
/// the `next` list of `GET /completeness`. There is no "submit an answer" API:
/// Ayma captures the answer in conversation via a skill, so the client's job is
/// to show [status] and route the user into a chat on this topic.
class QuestionNode {
  const QuestionNode({
    required this.id,
    this.pageType = 'misc',
    this.branch = 'all',
    this.label = '',
    this.kind = 'text',
    this.options = const [],
    this.scale,
    this.weight = 0,
    this.hardFilter = false,
    this.datingRelevant = false,
    this.aymaPrompt = '',
    this.status = 'missing',
    this.value,
    this.source,
  });

  final String id;
  final String pageType;

  /// `all`, or an intent gate (`casual` / `long_term` / `nikah`).
  final String branch;
  final String label;

  /// `enum` | `scale` | `text` | `bool` | … — how the value is shaped.
  final String kind;

  /// Choices for `kind == 'enum'`.
  final List<String> options;

  /// The range for `kind == 'scale'` (null otherwise).
  final QuestionScale? scale;

  final int weight;
  final bool hardFilter;
  final bool datingRelevant;

  /// A one-line hint of what Ayma should actually draw out here.
  final String aymaPrompt;

  /// `covered` | `partial` | `missing`.
  final String status;

  /// The known value, when [status] isn't `missing`.
  final String? value;

  /// Where a known value came from: `profile` | `stated` | `inferred` | `wiki`.
  final String? source;

  bool get isCovered => status == 'covered';
  bool get isPartial => status == 'partial';
  bool get isMissing => !isCovered && !isPartial;

  factory QuestionNode.fromMap(Map<String, dynamic> m) => QuestionNode(
        id: m['id'] as String? ?? '',
        pageType: m['page_type'] as String? ?? 'misc',
        branch: m['branch'] as String? ?? 'all',
        label: m['label'] as String? ?? '',
        kind: m['kind'] as String? ?? 'text',
        options: ((m['options'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
        scale: m['scale'] is Map
            ? QuestionScale.fromMap((m['scale'] as Map).cast<String, dynamic>())
            : null,
        weight: (m['weight'] as num?)?.toInt() ?? 0,
        hardFilter: m['hard_filter'] == true,
        datingRelevant: m['dating_relevant'] == true,
        aymaPrompt: m['ayma_prompt'] as String? ?? '',
        status: m['status'] as String? ?? 'missing',
        value: m['value']?.toString(),
        source: m['source'] as String?,
      );
}

/// One section of the profile-completeness breakdown (`GET /completeness`).
class CompletenessSection {
  const CompletenessSection({
    required this.pageType,
    this.label = '',
    this.pct = 0,
    this.answered = 0,
    this.total = 0,
  });

  final String pageType;
  final String label;
  final int pct;
  final int answered;
  final int total;

  factory CompletenessSection.fromMap(Map<String, dynamic> m) =>
      CompletenessSection(
        pageType: m['page_type'] as String? ?? 'misc',
        label: m['label'] as String? ?? '',
        pct: (m['pct'] as num?)?.toInt() ?? 0,
        answered: (m['answered'] as num?)?.toInt() ?? 0,
        total: (m['total'] as num?)?.toInt() ?? 0,
      );
}

/// `GET /completeness` — how filled-in the user's profile is (0–100), their
/// stated relationship intent, a per-section breakdown, and the highest-value
/// gaps ([next]) to fill. Ayma fills these in conversation.
class Completeness {
  const Completeness({
    this.score = 0,
    this.intent = 'long_term',
    this.intentSet = false,
    this.sections = const [],
    this.next = const [],
    this.updatedAt,
  });

  final int score;

  /// `casual` | `long_term` | `nikah`.
  final String intent;

  /// False when the user hasn't picked one yet ("Not sure yet").
  final bool intentSet;

  final List<CompletenessSection> sections;

  /// The next few highest-value questions to cover.
  final List<QuestionNode> next;

  final String? updatedAt;

  bool get isComplete => score >= 100;

  factory Completeness.fromMap(Map<String, dynamic> m) => Completeness(
        score: (m['score'] as num?)?.toInt() ?? 0,
        intent: m['intent'] as String? ?? 'long_term',
        intentSet: m['intent_set'] == true,
        sections: ((m['sections'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => CompletenessSection.fromMap(e.cast<String, dynamic>()))
            .toList(),
        next: ((m['next'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => QuestionNode.fromMap(e.cast<String, dynamic>()))
            .where((n) => n.id.isNotEmpty)
            .toList(),
        updatedAt: m['updated_at'] as String?,
      );
}

/// `GET /questionnaire` — the full question tree with per-node coverage status
/// for the signed-in user.
class QuestionnaireTree {
  const QuestionnaireTree({
    this.intent = 'long_term',
    this.intentSet = false,
    this.score = 0,
    this.nodes = const [],
  });

  final String intent;
  final bool intentSet;
  final int score;
  final List<QuestionNode> nodes;

  /// The nodes grouped by `page_type`, in first-seen order.
  Map<String, List<QuestionNode>> get byPageType {
    final out = <String, List<QuestionNode>>{};
    for (final n in nodes) {
      (out[n.pageType] ??= <QuestionNode>[]).add(n);
    }
    return out;
  }

  factory QuestionnaireTree.fromMap(Map<String, dynamic> m) => QuestionnaireTree(
        intent: m['intent'] as String? ?? 'long_term',
        intentSet: m['intent_set'] == true,
        score: (m['score'] as num?)?.toInt() ?? 0,
        nodes: ((m['nodes'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => QuestionNode.fromMap(e.cast<String, dynamic>()))
            .where((n) => n.id.isNotEmpty)
            .toList(),
      );
}

/// One photo Ayma holds of the user, from `GET /wiki/ai-view`.
class AiNotePhoto {
  const AiNotePhoto({required this.url, required this.source});

  final String url;

  /// `profile` (a grid photo) or `chat` (sent in the Ayma chat).
  final String source;
}

/// The AI-notes debug view: the compiled wiki text plus every photo Ayma has.
class AiNotes {
  const AiNotes({required this.text, this.photos = const []});

  final String text;
  final List<AiNotePhoto> photos;
}


class VoicePresets {
  const VoicePresets({
    required this.presets,
    required this.current,
    required this.defaultName,
    this.currentLanguage = '',
    this.languageExamples = const [],
  });
  final List<VoicePreset> presets;
  final String current;
  final String defaultName;

  /// Ayma's current default accent/language — free text ("Malayalam mixed
  /// with English", "a soft Southern US accent"), set here or learned from
  /// conversation. Empty = plain English. (§13.3)
  final String currentLanguage;

  /// Example strings for the settings text-field placeholder.
  final List<String> languageExamples;

  /// The effective voice selection: the user's choice, or the default.
  String get effective => current.isNotEmpty ? current : defaultName;
}

// --- Your Story editor models -------------------------------------------

/// One section of the Your Story document. On a `GET /story` read the flags are
/// meaningful; inside a version snapshot they default to false.
class StorySection {
  const StorySection({
    required this.pageId,
    required this.pageType,
    required this.title,
    required this.body,
    required this.visibility,
    this.userEdited = false,
    this.isSkill = false,
    this.hasPrivateSpans = false,
    this.aiUpdatedSinceUser = false,
  });

  final String pageId;
  final String pageType;
  final String title;

  /// The section body, markdown. May contain `{{private}}…{{/private}}` spans.
  final String body;

  /// `private` | `public` (never `ai_only` in the editor).
  final String visibility;

  /// The user has overridden Ayma's compiled body for this section.
  final bool userEdited;

  /// A skill-generated section (Facial analysis, Web findings, …) — shown
  /// under the "From Ayma's skills" divider.
  final bool isSkill;

  /// The body contains at least one `{{private}}` span.
  final bool hasPrivateSpans;

  /// Ayma's compiled body moved on after the user's last edit.
  final bool aiUpdatedSinceUser;

  factory StorySection.fromMap(Map<String, dynamic> m) => StorySection(
        pageId: m['page_id'] as String? ?? '',
        pageType: m['page_type'] as String? ?? 'misc',
        title: m['title'] as String? ?? '',
        body: m['body'] as String? ?? '',
        visibility: m['visibility'] as String? ?? 'private',
        userEdited: m['user_edited'] == true,
        isSkill: m['is_skill'] == true,
        hasPrivateSpans: m['has_private_spans'] == true,
        aiUpdatedSinceUser: m['ai_updated_since_user'] == true,
      );

  StorySection copyWith({String? body, String? visibility}) => StorySection(
        pageId: pageId,
        pageType: pageType,
        title: title,
        body: body ?? this.body,
        visibility: visibility ?? this.visibility,
        userEdited: userEdited,
        isSkill: isSkill,
        hasPrivateSpans: hasPrivateSpans,
        aiUpdatedSinceUser: aiUpdatedSinceUser,
      );
}

/// `GET /story` result.
class StoryData {
  const StoryData({required this.sections});
  final List<StorySection> sections;
}

/// One row of a section's version history
/// (`GET /story/section/{id}/versions`), newest first.
class StoryVersion {
  const StoryVersion({
    required this.id,
    required this.author,
    required this.note,
    required this.visibility,
    required this.createdAtMs,
  });

  final String id;

  /// `user` | `ayma`.
  final String author;
  final String note;
  final String visibility;
  final int createdAtMs;

  factory StoryVersion.fromMap(Map<String, dynamic> m) => StoryVersion(
        id: m['id'] as String? ?? '',
        author: m['author'] as String? ?? 'user',
        note: m['note'] as String? ?? '',
        visibility: m['visibility'] as String? ?? 'private',
        createdAtMs: (m['created_at_ms'] as num?)?.toInt() ?? 0,
      );
}

/// `GET /story/section/{id}/versions/{versionId}` — one stored section version.
class StorySectionVersion {
  const StorySectionVersion({
    required this.id,
    required this.body,
    required this.visibility,
    required this.author,
    required this.note,
    required this.createdAtMs,
  });

  final String id;
  final String body;
  final String visibility;
  final String author;
  final String note;
  final int createdAtMs;

  factory StorySectionVersion.fromMap(Map<String, dynamic> m) =>
      StorySectionVersion(
        id: m['id'] as String? ?? '',
        body: m['body'] as String? ?? '',
        visibility: m['visibility'] as String? ?? 'private',
        author: m['author'] as String? ?? 'user',
        note: m['note'] as String? ?? '',
        createdAtMs: (m['created_at_ms'] as num?)?.toInt() ?? 0,
      );
}

/// One turn of the passage chat (`POST /story/edit`).
class StoryChatReply {
  const StoryChatReply({
    required this.reply,
    this.revisedBody = '',
    this.action = 'chat',
    this.targetVisibility,
    this.usageCapped = false,
  });

  /// What Ayma says in the thread.
  final String reply;

  /// The full revised section body — set only when she proposes a concrete
  /// change to apply.
  final String revisedBody;

  /// `chat` | `move` | `remove`.
  final String action;

  /// `private` | `public` — only for `move`.
  final String? targetVisibility;

  final bool usageCapped;
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
