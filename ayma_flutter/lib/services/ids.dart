import 'dart:math';

/// A URL-safe random session id, stable for one chat-screen lifetime. Voice and
/// text turns in that span share it so they land in one `raw_turns` doc
/// (ARCHITECTURE.md §1.7 step 8).
String newSessionId() => _randomId('s-');

/// A URL-safe random id for ONE chat send, stable across retries of that same
/// send. Threaded through `/chat`(`/stream`) as `client_msg_id` so the server
/// can answer a retry from the already-persisted reply (or the still-running
/// turn) instead of generating — and billing — the turn again, and so the
/// client can find the finished turn in `/chat/history` by exact id after a
/// dropped connection (app backgrounded mid-send).
String newClientMsgId() => _randomId('m-');

/// A URL-safe random id for ONE async voice message, stable across retries
/// of that same send. Threaded through `POST /voice/async` as `job_id` so
/// the server answers a retry from the already-finished job (or joins the
/// still-running one) instead of transcribing — and billing — the clip
/// again, and so the client can watch the finished job by exact id after a
/// dropped connection.
String newVoiceJobId() => _randomId('v-');

String _randomId(String prefix) {
  const alphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
  final rand = Random.secure();
  final buf = StringBuffer(prefix);
  for (var i = 0; i < 22; i++) {
    buf.write(alphabet[rand.nextInt(alphabet.length)]);
  }
  return buf.toString();
}
