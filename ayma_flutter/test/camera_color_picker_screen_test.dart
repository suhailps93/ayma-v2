import 'package:ayma_flutter/screens/camera_color_picker_screen.dart';
import 'package:ayma_flutter/services/accent_color_controller.dart';
import 'package:ayma_flutter/services/profile_service.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeProfiles extends ProfileService {
  _FakeProfiles()
      : super(
          auth:
              MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'me')),
        );

  final List<Color> serverWrites = [];

  @override
  Future<Color?> getAccentColor() async => null;

  @override
  Future<void> setAccentColor(Color color) async {
    serverWrites.add(color);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Widget host({
    required Widget child,
    AccentColorController? accentController,
  }) {
    final c = accentController ??
        AccentColorController(profileService: _FakeProfiles());
    return MaterialApp(
      theme: AymaTheme.lightWithAccent(c.color),
      home: child,
    );
  }

  testWidgets('denied camera permission shows plain message and closes',
      (tester) async {
    bool popCalled = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => CameraColorPickerScreen(
                      requestPermission: () async => false,
                    ),
                  ),
                );
                popCalled = true;
              },
              child: const Text('Open Picker'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open Picker'));
    await tester.pumpAndSettle();

    // Verify it popped back
    expect(popCalled, isTrue);
    expect(find.byType(CameraColorPickerScreen), findsNothing);
  });

  testWidgets(
      'circular preview with center sampling ring, swatch, hex value, and Use this color button',
      (tester) async {
    final profiles = _FakeProfiles();
    final accent = AccentColorController(
      initial: AymaColors.accent,
      profileService: profiles,
    );

    const testColor = Color(0xFF2E9E5B);

    await tester.pumpWidget(
      host(
        child: CameraColorPickerScreen(
          accentController: accent,
          initialColor: testColor,
          requestPermission: () async => true,
          bypassCameraInit: true,
        ),
        accentController: accent,
      ),
    );
    await tester.pumpAndSettle();

    // Verify center sampling ring exists
    expect(find.byKey(const Key('samplingCenterRing')), findsOneWidget);

    // Verify swatch exists with the initial/sampled color
    expect(find.byKey(const Key('pickedColorSwatch')), findsOneWidget);
    final swatchBox = tester.widget<Container>(find.byKey(const Key('pickedColorSwatch')));
    final decoration = swatchBox.decoration as BoxDecoration;
    expect(decoration.color, testColor);

    // Verify hex text is displayed next to circle
    expect(find.byKey(const Key('pickedColorHex')), findsOneWidget);
    expect(find.text('#2E9E5B'), findsOneWidget);

    // Verify "Use this color" button exists
    expect(find.byKey(const Key('useThisColorButton')), findsOneWidget);
    expect(find.text('Use this color'), findsOneWidget);

    // Tap "Use this color"
    await tester.tap(find.byKey(const Key('useThisColorButton')));
    await tester.pumpAndSettle();

    // Verify color was applied to accent controller and persisted as custom color
    expect(accent.color, testColor);
    expect(accent.customColor, testColor);
    expect(profiles.serverWrites.last, testColor);
  });
}
