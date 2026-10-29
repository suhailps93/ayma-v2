import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:share_plus/share_plus.dart';

import '../models/report_share.dart';
import 'api_client.dart';
import 'dm_service.dart';

/// Sharing a report: snapshot it server-side (`POST /share`), fetch the
/// server-rendered card PNG, and hand link + card to the native OS share
/// sheet or a DM. The card is rendered by the backend
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

  /// The system share sheet with the link text and the link-preview card.
  /// When the card can't be fetched, the link text is still shared on its
  /// own so the chosen app (WhatsApp, ...) always gets it.
  Future<void> shareViaSystem(ReportShare share) async {
    XFile? file;
    try {
      file = XFile((await downloadCard(share)).path, mimeType: 'image/png');
    } on Exception {
      file = null;
    }
    await SharePlus.instance.share(ShareParams(
      text: share.message,
      subject: share.title,
      files: file == null ? null : [file],
    ));
  }

  /// Sends the report into the DM thread [threadId] as an in-app card that
  /// opens the snapshot natively (never the external link).
  Future<void> sendToThread(
    DmService dm,
    String threadId,
    ReportShare share,
  ) =>
      dm.sendReportShare(threadId, share.token);
}
