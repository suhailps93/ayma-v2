import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../screens/main_shell_screen.dart';

/// AppBar `leading` for full-page screens: the standard back button when the
/// route can pop, and — for screens opened with `context.go` / a deep link,
/// where nothing is below them and Material would show no arrow at all (iPhones
/// have no system back) — a back arrow that returns to the main shell. Also
/// puts any open keyboard away first.
class AymaBackButton extends StatelessWidget {
  const AymaBackButton({super.key});

  @override
  Widget build(BuildContext context) {
    final canPop = Navigator.of(context).canPop();
    return IconButton(
      tooltip: MaterialLocalizations.of(context).backButtonTooltip,
      icon: const BackButtonIcon(),
      onPressed: () {
        FocusManager.instance.primaryFocus?.unfocus();
        if (canPop) {
          Navigator.of(context).pop();
        } else {
          context.go(MainShellScreen.path);
        }
      },
    );
  }
}
