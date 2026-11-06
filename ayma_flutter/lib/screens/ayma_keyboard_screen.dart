import 'package:flutter/material.dart';

import '../services/keyboard_draft_store.dart';
import '../theme.dart';
import '../widgets/ayma_back_button.dart';

/// In-app explainer shown before the user enables the Ayma Keyboard.
///
/// This screen carries the V1 privacy posture verbatim (also in
/// docs/AYMA_KEYBOARD.md):
///  * The keyboard never logs or transmits keystrokes.
///  * The keyboard makes no network calls in V1.
///  * The Ayma strip only ever shows a draft the user explicitly sent to
///    the keyboard from inside Ayma, and only for one hour.
///  * Password / secure fields get nothing from the Ayma strip: Android
///    does not offer third-party keyboards their contents, the strip is
///    hidden for password fields, and Insert is disabled there.
///  * Ayma never types on her own. The user enables the keyboard, the
///    user switches to it, and the user taps Insert.
class AymaKeyboardScreen extends StatelessWidget {
  const AymaKeyboardScreen({super.key, this.service});

  static const path = '/settings/ayma-keyboard';

  final KeyboardDraftService? service;

  KeyboardDraftService get _service => service ?? keyboardDraftService;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(
        leading: const AymaBackButton(),
        title: Text('Ayma Keyboard',
            style: AymaType.sans(size: 18, color: ac.fg)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        children: [
          Text(
            'Use a draft Ayma wrote, in any app',
            style: AymaType.sans(size: 20, color: ac.fg),
          ),
          const SizedBox(height: 10),
          Text(
            'When Ayma drafts a message for you, tap "Send to Ayma Keyboard" '
            'in Ayma. Then open any app, tap a text field, switch to the '
            'Ayma Keyboard, and tap Insert. The draft goes in exactly as '
            'written — nothing is sent until you send it in that app.',
            style: AymaType.sans(size: 14, soft: true, color: ac.fgMute),
          ),
          const SizedBox(height: 24),
          Text('How it works',
              style: AymaType.mono(size: 11, color: ac.fgMute)),
          const SizedBox(height: 8),
          ...const [
            '1. In Ayma, tap "Send to Ayma Keyboard" on a draft.',
            '2. Open the other app and tap its text field.',
            '3. Switch keyboards to Ayma Keyboard (globe key or keyboard icon).',
            '4. Check the draft in the strip on top, then tap Insert.',
            '5. Send it in that app when you are happy with it.',
          ].map(
            (line) => Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(line,
                  style: AymaType.sans(size: 14, color: ac.fg)),
            ),
          ),
          const SizedBox(height: 16),
          Text('Privacy — please read this first',
              style: AymaType.mono(size: 11, color: ac.fgMute)),
          const SizedBox(height: 8),
          ...const [
            'The keyboard never logs, stores, or sends your keystrokes. '
                'What you type on it stays in the app you are typing in.',
            'The keyboard makes no network calls. The draft it shows was '
                'saved on this phone, inside Ayma, when you tapped '
                '"Send to Ayma Keyboard".',
            'Drafts expire after one hour and can be cleared from the '
                'keyboard strip at any time.',
            'Password fields get nothing: the strip hides and Insert is '
                'off in password and other secure fields.',
            'Ayma never types on her own. You enable the keyboard, you '
                'switch to it, and you tap Insert — every time.',
          ].map(
            (line) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.lock_outline, size: 16, color: ac.fgMute),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(line,
                        style: AymaType.sans(
                            size: 13, soft: true, color: ac.fgMute)),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            key: const ValueKey('ayma-keyboard-enable'),
            onPressed: () => _service.openKeyboardSettings(),
            icon: const Icon(Icons.keyboard_outlined),
            label: const Text('Enable Ayma Keyboard'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            key: const ValueKey('ayma-keyboard-switch'),
            onPressed: () => _service.showKeyboardPicker(),
            icon: const Icon(Icons.swap_horiz),
            label: const Text('Switch to Ayma Keyboard'),
          ),
          const SizedBox(height: 10),
          Text(
            'Android asks you to confirm enabling any keyboard and warns '
            'that keyboards can in principle read what you type. That '
            'warning is shown for every keyboard. Ayma Keyboard does not '
            'read, record, or send your typing — see above.',
            style: AymaType.sans(size: 12, soft: true, color: ac.fgMute),
          ),
        ],
      ),
    );
  }
}
