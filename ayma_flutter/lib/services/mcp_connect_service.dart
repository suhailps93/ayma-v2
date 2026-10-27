import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import '../env.dart';

/// Talks to the Ayma MCP server's in-app "Connect an agent" surface
/// (`/mcp/connect/*`, backend `mcp_server.py`). This is the approval side of
/// the OAuth 2.1 Device Authorization Grant: an external MCP client shows the
/// user a short code, the user types it here, and this authenticated call binds
/// that code to the user's uid.
///
/// Kept separate from `ApiClient` (its own small http round-trips, same Firebase
/// Bearer token) so the MCP feature stays self-contained. Every call sends the
/// current Firebase ID token; a 503 means the `mcp_server` feature flag is off.
class McpConnectService {
  McpConnectService({http.Client? client, FirebaseAuth? auth})
    : _http = client ?? http.Client(),
      _auth = auth ?? FirebaseAuth.instance;

  final http.Client _http;
  final FirebaseAuth _auth;

  Uri _uri(String path) => Uri.parse('${Env.apiBaseUrl}$path');

  Future<Map<String, String>> _headers() async {
    final token = await _auth.currentUser?.getIdToken();
    if (token == null) {
      throw McpConnectException('Not signed in.');
    }
    return {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    };
  }

  Never _fail(http.Response r) {
    if (r.statusCode == 503) {
      throw McpConnectException(
        'Agent connections are turned off right now.',
        disabled: true,
      );
    }
    String msg = 'Something went wrong (${r.statusCode}).';
    try {
      final body = jsonDecode(r.body);
      if (body is Map && body['error_description'] is String) {
        msg = body['error_description'] as String;
      } else if (body is Map && body['error'] is String) {
        msg = body['error'] as String;
      }
    } catch (_) {}
    throw McpConnectException(msg);
  }

  /// What the code is asking to connect (client name + requested scopes), so
  /// the user sees it before approving. `null` when the code is unknown/expired.
  Future<McpPending?> pending(String userCode) async {
    final r = await _http.get(
      _uri('/mcp/connect/pending?user_code=${Uri.encodeQueryComponent(userCode)}'),
      headers: await _headers(),
    );
    if (r.statusCode == 404) return null;
    if (r.statusCode != 200) _fail(r);
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    return McpPending.fromJson(body);
  }

  /// Approve the code (optionally narrowing [scopes]); binds it to this uid.
  Future<void> approve(String userCode, {List<String>? scopes}) async {
    final r = await _http.post(
      _uri('/mcp/connect/approve'),
      headers: await _headers(),
      body: jsonEncode({
        'user_code': userCode,
        'approve': true,
        if (scopes != null) 'scopes': scopes,
      }),
    );
    if (r.statusCode != 200) _fail(r);
  }

  Future<void> deny(String userCode) async {
    final r = await _http.post(
      _uri('/mcp/connect/approve'),
      headers: await _headers(),
      body: jsonEncode({'user_code': userCode, 'approve': false}),
    );
    if (r.statusCode != 200) _fail(r);
  }

  /// The user's currently-connected agents (active access tokens).
  Future<List<McpConnection>> connections() async {
    final r = await _http.get(_uri('/mcp/connect/tokens'), headers: await _headers());
    if (r.statusCode != 200) _fail(r);
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    final rows = (body['connections'] as List?) ?? const [];
    return rows
        .map((e) => McpConnection.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Revoke one connected agent (instantly stops its access).
  Future<void> revoke(String tokenId) async {
    final r = await _http.post(
      _uri('/mcp/connect/tokens/revoke'),
      headers: await _headers(),
      body: jsonEncode({'token_id': tokenId}),
    );
    if (r.statusCode != 200) _fail(r);
  }
}

class McpConnectException implements Exception {
  McpConnectException(this.message, {this.disabled = false});
  final String message;
  final bool disabled;
  @override
  String toString() => message;
}

class McpPending {
  McpPending({required this.clientId, required this.scopes, this.expiresAt});
  final String clientId;
  final List<String> scopes;
  final String? expiresAt;

  factory McpPending.fromJson(Map<String, dynamic> j) => McpPending(
    clientId: (j['client_id'] ?? 'an agent').toString(),
    scopes: ((j['scope'] as List?) ?? const []).map((e) => e.toString()).toList(),
    expiresAt: j['expires_at'] as String?,
  );
}

class McpConnection {
  McpConnection({
    required this.tokenId,
    required this.clientId,
    required this.scopes,
    this.createdAt,
    this.lastUsedAt,
  });
  final String tokenId;
  final String clientId;
  final List<String> scopes;
  final String? createdAt;
  final String? lastUsedAt;

  factory McpConnection.fromJson(Map<String, dynamic> j) => McpConnection(
    tokenId: (j['token_id'] ?? '').toString(),
    clientId: (j['client_id'] ?? 'an agent').toString(),
    scopes: ((j['scope'] as List?) ?? const []).map((e) => e.toString()).toList(),
    createdAt: j['created_at'] as String?,
    lastUsedAt: j['last_used_at'] as String?,
  );
}

/// Human labels for the MCP scopes, so the approval screen explains what access
/// is being granted in plain words.
const Map<String, String> kMcpScopeLabels = {
  'profile:read': 'Read your profile',
  'profile:write': 'Update your profile',
  'matches:read': 'See your matches',
  'dm:read': 'Read your messages',
  'dm:send': 'Send messages as you',
  'persona:read': 'Practice conversations',
};
