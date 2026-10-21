import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:share_plus/share_plus.dart';

import '../env.dart';
import '../models/report_share.dart';
import 'api_client.dart';
import 'dm_service.dart';

/// Sharing a report: snapshot it server-side (`POST /share`), fetch the
/// server-rendered card PNG, and hand link + card to Instagram Stories, the
/// system share sheet, or a DM. The card is rendered by the backend
/// (`share_page.render_card`) so the story, the DM and the link preview all
/// show the same image.
class ShareService {
  ShareService({
    ApiClient? api,
    http.Client? httpClient,
    MethodChannel? channel,
    String? facebookAppId,
    Directory? tempDir,
  })  : _apiOverride = api,
        _http = httpClient ?? http.Client(),
        _channel = channel ?? const MethodChannel('ayma/share'),
        _facebookAppId = facebookAppId ?? Env.facebookAppId,
        tempDir = tempDir ?? Directory.systemTemp;

  final ApiClient? _apiOverride;
  final http.Client _http;
  final MethodChannel _channel;
  final String _facebookAppId;

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
    final file = File(
        '${tempDir.path}/ayma_share_${share.token.substring(0, 8)}${story ? '_story' : ''}.png');
    return file.writeAsBytes(r.bodyBytes, flush: true);
  }

  /// Opens Instagram's Story composer with the story card as the background.
  /// Returns false when that isn't possible (no Facebook App ID configured,
  /// Instagram not installed, or a platform without the native handler) so
  /// the caller can fall back to [shareViaSystem].
  Future<bool> shareToInstagramStory(ReportShare share) async {
    if (_facebookAppId.isEmpty) return false;
    final card = await downloadCard(share, story: true);
    try {
      return await _channel.invokeMethod<bool>('instagramStory', {
            'path': card.path,
            'appId': _facebookAppId,
            'contentUrl': share.url,
          }) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
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
