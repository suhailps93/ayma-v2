import 'package:image_picker/image_picker.dart';

/// "Take a picture" — founder feedback item 12 (Nov 6, 2026): when the user
/// asks Ayma to take a picture, she first CONFIRMS which camera (front or
/// back), then captures with that camera. The captured photo lands in the
/// conversation as a normal chat image, so the existing `/chat` vision path
/// (the same one a manually attached photo takes) lets her see and react
/// to it.
///
/// This file is the shared, pure parsing half of that flow, used by both
/// entry points so they can never drift apart:
/// * the text/PTT chat ([ChatScreen] intercepts the typed or transcribed
///   trigger deterministically and offers the front/back choice as tappable
///   options, with a typed/spoken answer as the alternative);
/// * the live-voice / text tool (`take_picture` in
///   `functions/bootstrap/skills/take_picture.py`), which queues an
///   `app_commands` `take_picture` action that [AppCommandService] executes
///   with the camera this file maps.
///
/// Action-parity / APP_ACTION_GRAPH entry name: `take_picture`.
class TakePictureIntent {
  TakePictureIntent._();

  /// The exact question Ayma asks before any capture, in both flows.
  static const confirmQuestion = 'Front or back camera?';

  static final RegExp _trigger = RegExp(
    r'^(please\s+)?(take|capture|snap|shoot)\s+(a\s+|the\s+|me\s+a\s+)?'
    r'(picture|photo|pic|selfie|snapshot)\b',
    caseSensitive: false,
  );

  /// True when [text] is a request for Ayma to take a picture ("take a
  /// picture", "snap a photo", "take a picture with the front camera", …).
  /// Deliberately anchored at the start of the message: a sentence that
  /// merely talks *about* taking pictures ("I love to take a picture of
  /// sunsets") still matches the anchor only when it leads with the
  /// imperative, which is the form a command to Ayma takes.
  static bool isRequest(String text) => _trigger.hasMatch(text.trim());

  /// A camera named anywhere inside a longer sentence ("take a picture
  /// with the **front** camera", "use the **back** one") — `'front'` or
  /// `'back'`, or null when no camera is named.
  static String? cameraMentionedIn(String text) {
    final t = text.toLowerCase();
    if (RegExp(r'\b(front|selfie)\b').hasMatch(t)) return 'front';
    if (RegExp(r'\b(back|rear)\b').hasMatch(t)) return 'back';
    return null;
  }

  static final RegExp _answer = RegExp(
    r'^(the\s+)?(front|back|rear|selfie)(\s+camera)?(\s+one)?(\s+please)?[.!]?$',
    caseSensitive: false,
  );

  /// A short standalone answer to [confirmQuestion] ("front", "back
  /// camera", "the rear one", "selfie") — `'front'` or `'back'`, or null
  /// when the message is not a camera answer (so an unrelated reply while
  /// the question is outstanding is never misread as consent to capture).
  static String? parseCameraAnswer(String text) {
    final t = text.trim();
    if (!_answer.hasMatch(t)) return null;
    return cameraMentionedIn(t);
  }

  /// The [CameraDevice] a `'front'`/`'back'` choice maps to (anything that
  /// is not front is the rear camera — matching [ImagePicker]'s default).
  static CameraDevice deviceFor(String camera) =>
      camera == 'front' ? CameraDevice.front : CameraDevice.rear;

  /// The human label for a `'front'`/`'back'` choice.
  static String labelFor(String camera) =>
      camera == 'front' ? 'front camera' : 'back camera';
}
