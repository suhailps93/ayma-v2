import 'package:flutter/foundation.dart';

/// App-wide authentication session state notifier.
///
/// Merged into [appRouter]'s `refreshListenable` so that route redirects
/// re-evaluate immediately when authentication state changes (sign-out,
/// account switch, forced 401). Deliberately decoupled from `firebase_auth`
/// so importing this class or referencing it in tests never throws
/// `[core/no-app]` — the layout matrix and every unit/widget suite run
/// without an initialized Firebase Core.
class AuthSessionState extends ChangeNotifier {
  AuthSessionState._();
  static final AuthSessionState instance = AuthSessionState._();

  bool _signedIn = false;
  String? _uid;

  bool get signedIn => _signedIn;
  String? get uid => _uid;

  void update({required bool signedIn, String? uid}) {
    if (_signedIn == signedIn && _uid == uid) return;
    _signedIn = signedIn;
    _uid = uid;
    notifyListeners();
  }

  void clear() => update(signedIn: false, uid: null);
}
