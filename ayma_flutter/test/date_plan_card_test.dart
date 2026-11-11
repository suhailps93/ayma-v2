import 'package:ayma_flutter/services/date_plan.dart';
import 'package:ayma_flutter/services/dm_service.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/date_plan_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _planMap({
  String status = 'proposed',
  Map<String, bool> approvals = const {},
  double? lat = 37.3382,
  double? lng = -121.8863,
  bool momentFired = false,
  int revision = 1,
}) =>
    {
      'status': status,
      'proposer_uid': 'me',
      'place_name': 'Sakura Sushi',
      'address': '1 Main St, San Jose',
      if (lat != null) 'lat': lat,
      if (lng != null) 'lng': lng,
      'time_label': 'Fri, Nov 13 at 8:00 PM',
      'starts_at': '2026-11-13T20:00:00+00:00',
      'approvals': approvals,
      'revision': revision,
      'moment_fired': momentFired,
    };

Widget _wrap(DatePlan plan,
        {VoidCallback? onApprove, VoidCallback? onSuggest}) =>
    MaterialApp(
      theme: AymaTheme.dark,
      home: Scaffold(
        body: DatePlanCard(
          plan: plan,
          myUid: 'me',
          otherUid: 'them',
          otherName: 'Sofia',
          onApprove: onApprove,
          onSuggest: onSuggest,
        ),
      ),
    );

void main() {
  test('DmMessage.fromData parses a payment-free date plan card', () {
    final m = DmMessage.fromData('c1', {
      'sender_uid': 'ayma',
      'type': 'date_plan',
      'body': 'Date plan',
      'date_plan': _planMap(),
    });
    expect(m.isDatePlan, isTrue);
    expect(m.datePlan!.placeName, 'Sakura Sushi');
    expect(m.datePlan!.address, '1 Main St, San Jose');
    expect(m.datePlan!.hasCoords, isTrue);
    expect(m.datePlan!.momentFired, isFalse);
    // No payment fields exist on the model.
  });

  test('a plan without coordinates is still parsed but not matchable', () {
    final plan = DatePlan.tryParse(_planMap(lat: null, lng: null))!;
    expect(plan.hasCoords, isFalse);
  });

  testWidgets('proposed card shows place, address, time and Approve',
      (tester) async {
    var approved = 0;
    final plan = DatePlan.tryParse(_planMap())!;
    await tester.pumpWidget(_wrap(plan, onApprove: () => approved++));
    expect(find.text('Sakura Sushi'), findsOneWidget);
    expect(find.text('1 Main St, San Jose'), findsOneWidget);
    expect(find.textContaining('Fri, Nov 13'), findsOneWidget);
    expect(find.text('Waiting for both of you to approve'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('date-plan-approve')));
    expect(approved, 1);
  });

  testWidgets('one approval shows who is still missing', (tester) async {
    final plan = DatePlan.tryParse(_planMap(
      status: 'partially_approved',
      approvals: {'them': true},
    ))!;
    await tester.pumpWidget(_wrap(plan));
    expect(find.text('They approved — waiting for you'), findsOneWidget);
    expect(find.textContaining('Sofia — approved'), findsOneWidget);
    expect(find.textContaining('You — not approved yet'), findsOneWidget);
  });

  testWidgets('both approved hides Approve and reads the date is on',
      (tester) async {
    final plan = DatePlan.tryParse(_planMap(
      status: 'both_approved',
      approvals: {'me': true, 'them': true},
    ))!;
    await tester.pumpWidget(_wrap(plan));
    expect(find.text('Both approved — the date is on'), findsOneWidget);
    expect(find.byKey(const ValueKey('date-plan-approve')), findsNothing);
    // Suggest-a-change stays available.
    expect(find.byKey(const ValueKey('date-plan-suggest')), findsOneWidget);
  });

  testWidgets('suggest-a-change fires its callback', (tester) async {
    var suggested = 0;
    final plan = DatePlan.tryParse(_planMap())!;
    await tester.pumpWidget(_wrap(plan, onSuggest: () => suggested++));
    await tester.tap(find.byKey(const ValueKey('date-plan-suggest')));
    expect(suggested, 1);
  });
}
