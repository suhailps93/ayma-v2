import 'api_client.dart';

/// Backs the Google account import screen: connect/disconnect round trip and
/// status, proxied straight onto [ApiClient] the same way [PhotoService]
/// proxies the Instagram actions.
class GoogleAccountService {
  GoogleAccountService({ApiClient? api}) : _apiOverride = api;

  final ApiClient? _apiOverride;
  late final ApiClient _api = _apiOverride ?? ApiClient();

  Future<String> authUrl() => _api.googleAuthUrl();

  Future<String> connect(String code) => _api.googleConnect(code);

  Future<void> disconnect() => _api.googleDisconnect();

  Future<GoogleAccountStatus> status() => _api.googleStatus();
}
