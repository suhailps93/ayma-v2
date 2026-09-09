import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/dm_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';

class _CapturingApi extends ApiClient {
  _CapturingApi() : super(auth: MockFirebaseAuth(signedIn: true));

  final List<Map<String, dynamic>> calls = [];

  @override
  Future<void> sendDmMessage(
    String threadId, {
    required String type,
    String body = '',
    String attachmentUrl = '',
    String attachmentPath = '',
    String mime = '',
    String fileName = '',
    int size = 0,
  }) async {
    calls.add({
      'threadId': threadId,
      'type': type,
      'body': body,
      'attachmentUrl': attachmentUrl,
      'attachmentPath': attachmentPath,
      'mime': mime,
      'fileName': fileName,
      'size': size,
    });
  }
}

DmService _svc(ApiClient api) => DmService(
      auth: MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'me')),
      api: api,
    );

void main() {
  test('sendAttachment maps the attachment onto the DM message endpoint',
      () async {
    final api = _CapturingApi();
    await _svc(api).sendAttachment(
      'a__me',
      type: 'image',
      caption: 'on the trail',
      attachment: const DmAttachment(
        storagePath: 'uploads/me/dm/a__me/1.jpg',
        downloadUrl: 'https://example.invalid/1.jpg',
        contentType: 'image/jpeg',
        sizeBytes: 4096,
        name: '1.jpg',
      ),
    );

    expect(api.calls.single, {
      'threadId': 'a__me',
      'type': 'image',
      'body': 'on the trail',
      'attachmentUrl': 'https://example.invalid/1.jpg',
      'attachmentPath': 'uploads/me/dm/a__me/1.jpg',
      'mime': 'image/jpeg',
      'fileName': '1.jpg',
      'size': 4096,
    });
  });

  test('sendText still posts a plain text message', () async {
    final api = _CapturingApi();
    await _svc(api).sendText('a__me', 'hello');
    expect(api.calls.single['type'], 'text');
    expect(api.calls.single['body'], 'hello');
    expect(api.calls.single['attachmentPath'], '');
  });

  test('DmMessage.fromData reads the attachment fields off a file message', () {
    final m = DmMessage.fromData('f1', {
      'sender_uid': 'a',
      'type': 'file',
      'body': 'my resume',
      'created_at': Timestamp.now(),
      'attachment_url': 'https://example.invalid/cv.pdf',
      'attachment_path': 'uploads/a/dm/a__me/cv.pdf',
      'mime': 'application/pdf',
      'file_name': 'cv.pdf',
      'size': 20480,
    });

    expect(m.id, 'f1');
    expect(m.type, 'file');
    expect(m.body, 'my resume');
    expect(m.attachmentUrl, 'https://example.invalid/cv.pdf');
    expect(m.attachmentPath, 'uploads/a/dm/a__me/cv.pdf');
    expect(m.mime, 'application/pdf');
    expect(m.fileName, 'cv.pdf');
    expect(m.size, 20480);
    expect(m.hasFile, isTrue);
    expect(m.hasImage, isFalse);
  });

  test('DmMessage.fromData leaves attachment fields empty for a text message',
      () {
    final m = DmMessage.fromData('t1', {
      'sender_uid': 'me',
      'type': 'text',
      'body': 'hi',
      'created_at': Timestamp.now(),
    });
    expect(m.attachmentUrl, '');
    expect(m.size, 0);
    expect(m.hasImage, isFalse);
    expect(m.hasFile, isFalse);
  });

  test('DmMessage.fromData flags a renderable image', () {
    final m = DmMessage.fromData('i1', {
      'sender_uid': 'a',
      'type': 'image',
      'body': '',
      'attachment_url': 'https://example.invalid/p.jpg',
    });
    expect(m.hasImage, isTrue);
  });
}
