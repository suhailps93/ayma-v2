import 'package:flutter/material.dart';

/// Shared "paste the redirect URL back" dialog for every manual OAuth round
/// trip in this app (Connect Google, Connect Instagram, Sign in with
/// Instagram): there is no deep-link/App-Link handling anywhere in the app,
/// so after the user approves access in the externally-launched browser,
/// they have to copy the address bar URL (or just the `code` value) back
/// into the app themselves. Was duplicated verbatim in
/// `google_account_screen.dart` and `instagram_screen.dart`; factored out
/// once a third call site (`sign_in_screen.dart`'s "Sign in with Instagram")
/// needed the exact same thing.
Future<String?> promptForOAuthCode(BuildContext context) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Finish connecting'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'After approving access in the browser, paste the address bar '
            'URL (or just the "code" value) here.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'code=…'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () =>
              Navigator.pop(ctx, extractOAuthCode(controller.text)),
          child: const Text('Connect'),
        ),
      ],
    ),
  );
}

/// Pulls the `code` query parameter out of a pasted redirect URL, or returns
/// the trimmed input as-is when it isn't a URL (the user pasted the bare
/// code instead of the whole address bar).
String extractOAuthCode(String input) {
  final trimmed = input.trim();
  final uri = Uri.tryParse(trimmed);
  final fromQuery = uri?.queryParameters['code'];
  return (fromQuery != null && fromQuery.isNotEmpty) ? fromQuery : trimmed;
}
