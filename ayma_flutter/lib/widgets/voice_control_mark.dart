import 'package:flutter/widgets.dart';

/// Marks a control that can start, stop or mute a live voice call (the nav-bar
/// orb, the composer's mic and call bar). The guided tour leaves an opened page
/// usable while it waits for the user's go, but on a call it keeps blocking
/// these: a tap on one can disconnect Ayma.
class VoiceControlMark extends StatelessWidget {
  const VoiceControlMark({super.key, required this.child});

  final Widget child;

  static const Object tag = 'ayma-voice-control';

  @override
  Widget build(BuildContext context) => MetaData(metaData: tag, child: child);
}
