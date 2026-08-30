import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';

/// Uploads a photo a user attached in the Ayma chat to their own
/// `uploads/{uid}/…` tree (§2.2). The backend downloads it from there to
/// moderate + show Ayma; the client keeps the returned download URL to render
/// the bubble now and after a reload.
class ChatImageUpload {
  const ChatImageUpload({required this.storagePath, required this.downloadUrl});

  /// `uploads/{uid}/chat_<ts>.<ext>` — sent to `POST /chat` as `image_path`.
  final String storagePath;
  final String downloadUrl;
}

class ChatService {
  ChatService({FirebaseAuth? auth, FirebaseStorage? storage})
      : _authOverride = auth,
        _storageOverride = storage;

  final FirebaseAuth? _authOverride;
  final FirebaseStorage? _storageOverride;

  FirebaseAuth get _auth => _authOverride ?? FirebaseAuth.instance;
  FirebaseStorage get _storage => _storageOverride ?? FirebaseStorage.instance;

  String get _uid {
    final u = _auth.currentUser?.uid;
    if (u == null) throw StateError('No signed-in user.');
    return u;
  }

  Future<ChatImageUpload> uploadChatImage(File file) async {
    final ext = file.path.contains('.')
        ? file.path.substring(file.path.lastIndexOf('.')).toLowerCase()
        : '.jpg';
    final path =
        'uploads/$_uid/chat_${DateTime.now().millisecondsSinceEpoch}$ext';
    final ref = _storage.ref(path);
    await ref.putFile(file);
    return ChatImageUpload(
      storagePath: path,
      downloadUrl: await ref.getDownloadURL(),
    );
  }
}
