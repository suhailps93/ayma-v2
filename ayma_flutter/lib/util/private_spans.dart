/// Whether raw-body offset [offset] of [raw] sits inside a
/// `{{private}}…{{/private}}` span — a light client-side mirror of
/// `story.py`'s `_parse_spans` depth tracking, used only to decide which of
/// "Make public" / "Make private" reflects the *current* state in the
/// sentence toolbar (§ Your Story). The actual edit still goes through
/// `setPrivacy` (`widgets/selectable_markdown.dart`) — this never writes
/// anything.
bool isPrivateAt(String raw, int offset) {
  const open = '{{private}}';
  const close = '{{/private}}';
  var depth = 0;
  var i = 0;
  final stop = offset.clamp(0, raw.length);
  while (i < stop) {
    if (raw.startsWith(open, i)) {
      depth++;
      i += open.length;
      continue;
    }
    if (raw.startsWith(close, i)) {
      depth = depth > 0 ? depth - 1 : 0;
      i += close.length;
      continue;
    }
    i++;
  }
  return depth > 0;
}
