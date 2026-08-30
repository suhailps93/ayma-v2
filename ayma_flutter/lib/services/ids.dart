import 'dart:math';

/// A URL-safe random session id, stable for one chat-screen lifetime. Voice and
/// text turns in that span share it so they land in one `raw_turns` doc
/// (ARCHITECTURE.md §1.7 step 8).
String newSessionId() {
  const alphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
  final rand = Random.secure();
  final buf = StringBuffer('s-');
  for (var i = 0; i < 22; i++) {
    buf.write(alphabet[rand.nextInt(alphabet.length)]);
  }
  return buf.toString();
}
