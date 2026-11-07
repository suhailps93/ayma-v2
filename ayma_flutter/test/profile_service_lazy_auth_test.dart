import 'package:ayma_flutter/services/accent_color_controller.dart';
import 'package:ayma_flutter/services/profile_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // This file deliberately never calls Firebase.initializeApp(): it is the
  // regression guard for AYMA-FLUTTER-3E, the [core/no-app] crash when the
  // accent controller was constructed before Firebase init finished
  // (builds 2308-2339, last seen on 2339). Construction must be inert;
  // only actually reading the signed-in user may touch FirebaseAuth.
  test('ProfileService constructs before Firebase.initializeApp', () {
    expect(() => ProfileService(), returnsNormally);
  });

  test('AccentColorController constructs before Firebase.initializeApp', () {
    expect(() => AccentColorController(), returnsNormally);
  });
}
