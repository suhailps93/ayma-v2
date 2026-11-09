import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/report_share.dart';
import 'api_client.dart';

/// Sharing a report: snapshot it server-side (`POST /share`), fetch the
/// server-rendered card PNG, and hand link + card to the native OS share
/// sheet. The card is rendered by the backend
/// (`share_page.render_card`) so the share, the DM and the link preview all
/// show the same image.
class ShareService {
  ShareService({
    ApiClient? api,
    http.Client? httpClient,
    Directory? tempDir,
  })  : _apiOverride = api,
        _http = httpClient ?? http.Client(),
        tempDir = tempDir ?? Directory.systemTemp;

  final ApiClient? _apiOverride;
  final http.Client _http;

  /// Where cards are written; the platform temp directory by default.
  final Directory tempDir;

  late final ApiClient _api = _apiOverride ?? ApiClient();

  Future<ReportShare> create(String reportType, String reportId) =>
      _api.createShare(reportType, reportId);

  /// Downloads the share's PNG card (`story` = 1080x1920, else link-preview
  /// size) to a temp file.
  Future<File> downloadCard(ReportShare share, {bool story = false}) async {
    final r = await _http
        .get(Uri.parse(story ? share.storyCardUrl : share.cardUrl));
    if (r.statusCode != 200) {
      throw ApiException('card download failed.',
          statusCode: r.statusCode, body: r.body);
    }
    // The share host answers 200 with an HTML page when it isn't routed to
    // the backend; that must never be handed to WhatsApp as a "PNG".
    final b = r.bodyBytes;
    if (b.length < 4 ||
        b[0] != 0x89 ||
        b[1] != 0x50 ||
        b[2] != 0x4E ||
        b[3] != 0x47) {
      throw ApiException('card download did not return a PNG.',
          statusCode: r.statusCode);
    }
    final file = File(
        '${tempDir.path}/ayma_share_${share.token.substring(0, 8)}${story ? '_story' : ''}.png');
    return file.writeAsBytes(r.bodyBytes, flush: true);
  }
}
