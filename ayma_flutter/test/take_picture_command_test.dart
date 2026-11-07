import 'package:ayma_flutter/services/app_command_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';

/// The `take_picture` app command (founder feedback item 12): the backend
/// `take_picture` tool queues it after the user has answered "Front or back
/// camera?", and [AppCommandService] owns its ack — the ack carries the
/// capture's `image_path` and the vision reaction on success, or the
/// failure `reason` the tool turns into an honest line.
void main() {
  group('take_picture command', () {
    late FakeFirebaseFirestore fs;
    late MockFirebaseAuth auth;

    DocumentReference<Map<String, dynamic>> pending() =>
        fs.doc('users/me/app_commands/pending');
    DocumentReference<Map<String, dynamic>> ack() =>
        fs.doc('users/me/app_commands/ack');

    AppCommandService svcWith(
      Future<TakePictureOutcome> Function(Map<String, dynamic>) f,
    ) => AppCommandService(
      firestore: fs,
      auth: auth,
      navigate: (_) {},
      takePicture: f,
    );

    setUp(() {
      fs = FakeFirebaseFirestore();
      auth = MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'me'));
    });

    test('a capture command acks ok with the image_path and the vision '
        'reaction, and clears the pending doc', () async {
      Map<String, dynamic>? seen;
      final svc = svcWith((cmd) async {
        seen = cmd;
        return const TakePictureOutcome.captured(
          imagePath: 'uploads/me/chat_1.jpg',
          result: 'Nice light in here!',
        );
      })..start();
      addTearDown(svc.stop);

      await pending().set({
        'action': 'take_picture',
        'camera': 'front',
        'id': 'pic-1',
        'ts': Timestamp.now(),
      });
      await pumpEventQueue();

      expect(seen?['camera'], 'front');
      final ackDoc = (await ack().get()).data();
      expect(ackDoc?['id'], 'pic-1');
      expect(ackDoc?['ok'], isTrue);
      expect(ackDoc?['image_path'], 'uploads/me/chat_1.jpg');
      expect(ackDoc?['library_saved'], isTrue);
      expect(ackDoc?['result'], 'Nice light in here!');
      expect((await pending().get()).exists, isFalse);
    });

    test('a cancelled capture acks ok=false with reason cancelled', () async {
      final svc = svcWith(
        (_) async => const TakePictureOutcome.failed('cancelled'),
      )..start();
      addTearDown(svc.stop);

      await pending().set({
        'action': 'take_picture',
        'camera': 'back',
        'id': 'pic-2',
        'ts': Timestamp.now(),
      });
      await pumpEventQueue();

      final ackDoc = (await ack().get()).data();
      expect(ackDoc?['id'], 'pic-2');
      expect(ackDoc?['ok'], isFalse);
      expect(ackDoc?['reason'], 'cancelled');
      expect((await pending().get()).exists, isFalse);
    });

    test('a capture whose library save was refused acks library_saved '
        'false, so the tool can say the library copy is missing', () async {
      final svc = svcWith((_) async => const TakePictureOutcome.captured(
            imagePath: 'uploads/me/chat_1.jpg',
            result: 'Nice light in here!',
            librarySaved: false,
            libraryDenied: true,
          ))
        ..start();
      addTearDown(svc.stop);

      await pending().set({
        'action': 'take_picture',
        'camera': 'back',
        'id': 'pic-3',
        'ts': Timestamp.now(),
      });
      await pumpEventQueue();

      final ackDoc = (await ack().get()).data();
      expect(ackDoc?['ok'], isTrue);
      expect(ackDoc?['library_saved'], isFalse);
      expect((await pending().get()).exists, isFalse);
    });

    test('runTakePicture never throws: a crashing capture is reported as '
        'camera_unavailable', () async {
      final svc = svcWith((_) async => throw StateError('boom'));
      final out = await svc.runTakePicture({
        'action': 'take_picture',
        'camera': 'front',
      });
      expect(out.ok, isFalse);
      expect(out.reason, 'camera_unavailable');
    });
  });
}
