// The standardized page/report loading indicator (founder: "when loading a
// page don't show the Ayma logo; show the loading logo used in Explore — use a
// standardized one everywhere"). Confirms it renders a CircularProgressIndicator
// tinted to the USER'S accent colour.
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/app_loading_indicator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child, Color accent) => MaterialApp(
      theme: AymaTheme.lightWithAccent(accent),
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  testWidgets('renders a CircularProgressIndicator', (tester) async {
    await tester.pumpWidget(
      _host(const AppLoadingIndicator(), const Color(0xFF2266CC)),
    );
    await tester.pump();

    expect(find.byType(AppLoadingIndicator), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AppLoadingIndicator),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
  });

  testWidgets('is tinted to the user accent colour', (tester) async {
    const accent = Color(0xFF2266CC);
    await tester.pumpWidget(_host(const AppLoadingIndicator(), accent));
    await tester.pump();

    final spinner = tester.widget<CircularProgressIndicator>(
      find.byType(CircularProgressIndicator),
    );
    expect(spinner.color, accent);
  });
}
