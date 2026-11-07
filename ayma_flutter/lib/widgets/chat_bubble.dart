import 'package:flutter/material.dart';

import '../theme.dart';
import 'copy_on_long_press.dart';

/// The one chat bubble shared by the DM thread ([DmThreadScreen]) and the
/// Practice Date simulator ([PracticeScreen]), so both read as the same
/// conversation surface instead of two look-alikes that drift apart.
///
/// It owns the shared chrome only: the left/right [Align], the long-press-to-
/// copy gesture, the rounded, soft-bordered container (accent fill when
/// [mine], [AymaTokens.bgCard] otherwise), and the moderation "Flagged for
/// review" treatment. The message CONTENT — plain text, an image, a file chip,
/// a shared-report card — is passed in as [child] by the caller, which also
/// chooses the text ink ([AymaTokens.onAccent] when [mine] and not [flagged],
/// else [AymaTokens.fg]).
class ChatBubble extends StatelessWidget {
  const ChatBubble({
    super.key,
    required this.mine,
    required this.child,
    required this.copyText,
    this.tight = false,
    this.flagged = false,
  });

  /// The local user's own message: right-aligned on the solid accent fill.
  /// Received messages are left-aligned on [AymaTokens.bgCard].
  final bool mine;

  /// The bubble's content (text / image / file chip / report card).
  final Widget child;

  /// Copied to the clipboard on long-press; a blank string disables the
  /// gesture (see [CopyOnLongPress]).
  final String copyText;

  /// Tight padding for media/card content (an image, a report card) vs the
  /// roomier padding used for text.
  final bool tight;

  /// Moderation: renders the red-bordered "Flagged for review" treatment above
  /// the content.
  final bool flagged;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: CopyOnLongPress(
        text: copyText,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: tight
              ? const EdgeInsets.all(4)
              : const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.78,
          ),
          decoration: BoxDecoration(
            color: flagged
                ? ac.error.withValues(alpha: 0.12)
                // Sent bubbles use the full, solid accent (not a washed-out
                // tint) so they read as clearly "mine" against the received
                // bubbles' bgCard grey — matching the reference messaging app.
                : (mine ? ac.accent : ac.bgCard),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: flagged ? ac.error : ac.lineSoft,
              width: flagged ? 1.25 : 0.5,
            ),
          ),
          child: flagged
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.flag_rounded, size: 14, color: ac.error),
                        const SizedBox(width: 5),
                        Text(
                          'Flagged for review',
                          style: AymaType.sans(
                            size: 11,
                            color: ac.error,
                            weight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    child,
                  ],
                )
              : child,
        ),
      ),
    );
  }
}
