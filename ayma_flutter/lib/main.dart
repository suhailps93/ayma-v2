import 'package:flutter/material.dart';

void main() {
  runApp(const AymaApp());
}

/// Root of the Ayma app.
///
/// Step 1 scaffolding only: a single blank screen. Auth, routing, and the
/// real app shell arrive in later steps (see PLAN.md Phase 1).
class AymaApp extends StatelessWidget {
  const AymaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Ayma',
      debugShowCheckedModeBanner: false,
      home: Scaffold(body: SizedBox.expand()),
    );
  }
}
