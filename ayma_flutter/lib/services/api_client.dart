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

  /// `POST /chat` — sends a text turn, returns Ayma's reply.
  Future<String> chat(String message) async {
    final http.Response response;
    try {
      response = await _http.post(
        _uri('/chat'),
        headers: await _headers(),
        body: jsonEncode({'message': message}),
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
    return decoded['reply'] as String? ?? '';
  }
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
