import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// Saves image bytes into the device gallery through the small
/// `ayma/media_save` channel: Android's MainActivity writes MediaStore
/// `Pictures/Ayma` (no permission on API 29+; on API 26-28 the legacy storage
/// permission is requested first), iOS's AppDelegate adds it to Photos with
/// add-only access. Returns the human-readable place it was saved.
///
/// Throws [PlatformException] with code `PERMISSION` when the user declined
/// access, anything else when the save failed.
class GallerySaver {
  const GallerySaver({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('ayma/media_save');

  final MethodChannel _channel;

  Future<String> save(Uint8List bytes, String name, String mime) async {
    Future<String?> attempt() => _channel.invokeMethod<String>('saveImage', {
      'bytes': bytes,
      'name': name,
      'mime': mime,
    });
    try {
      return (await attempt())!;
    } on PlatformException catch (e) {
      if (e.code != 'PERMISSION' ||
          defaultTargetPlatform != TargetPlatform.android) {
        rethrow;
      }
      // Android 8-9 only: legacy WRITE_EXTERNAL_STORAGE.
      final status = await Permission.storage.request();
      if (!status.isGranted) rethrow;
      return (await attempt())!;
    }
  }
}

/// The outcome of a best-effort save into the user's photo library.
enum LibrarySaveOutcome { saved, denied, failed }

/// Saves [bytes] into the user's photo library through [saver] (the
/// existing `ayma/media_save` flow), mapping the channel's `PERMISSION`
/// refusal to [LibrarySaveOutcome.denied] and any other failure to
/// [LibrarySaveOutcome.failed], so callers can keep their other copy of
/// the photo either way and report the library state honestly.
Future<LibrarySaveOutcome> saveToPhotoLibrary(
  GallerySaver saver,
  Uint8List bytes,
  String name,
  String mime,
) async {
  try {
    await saver.save(bytes, name, mime);
    return LibrarySaveOutcome.saved;
  } on PlatformException catch (e) {
    return e.code == 'PERMISSION'
        ? LibrarySaveOutcome.denied
        : LibrarySaveOutcome.failed;
  } catch (_) {
    return LibrarySaveOutcome.failed;
  }
}
