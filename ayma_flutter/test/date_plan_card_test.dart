import 'package:ayma_flutter/services/date_plan.dart';
import 'package:ayma_flutter/services/dm_service.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/date_plan_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _planMap({
  String status = 'proposed',
  Map<String, bool> approvals = const {},
  Map<String, dynamic> payments = const {},
  Map<String, dynamic> reservation = const {},
}) =>
    {
      'status': status,
      'place_name': 'Sakura Sushi',
      'place_kind': 'Sushi restaurant',
      'reason': 'Sushi came up in your conversation.',
      'time_label': 'Friday November 13 at 8:00 PM',
      'starts_at': '2026-11-13T20:00:00',
      'total_cents': 5600,
      'half_cents': 2800,
      'currency': 'USD',
      'approvals': approvals,
      'payments': payments,
      'revision': 1,
      'paypal_stubbed': false,
      'reservation': reservation,
    };

Widget _wrap(DatePlan plan,
        {VoidCallback? onApprove,
        VoidCallback? onPay,
        VoidCallback? onSuggest}) =>
    MaterialApp(
      theme: AymaTheme.dark,
      home: Scaffold(
        body: DatePlanCard(
          plan: plan,
          myUid: 'me',
          otherUid: 'them',
          otherName: 'Sofia',
          onApprove: onApprove,
          onPay: onPay,
          onSuggest: onSuggest,
        ),
      ),
    );

void main() {
  test('DmMessage.fromData parses a date plan card', () {
    final m = DmMessage.fromData('c1', {
      'sender_uid': 'ayma',
      'type': 'date_plan',
      'body': 'Date plan',
      'date_plan': _planMap(),
    });
    expect(m.isDatePlan, isTrue);
    expect(m.datePlan!.placeName, 'Sakura Sushi');
    expect(m.datePlan!.totalCents, 5600);
  });

  testWidgets('proposed card shows place, time, cost and Approve',
      (tester) async {
    var approved = 0;
    final plan = DatePlan.tryParse(_planMap())!;
    await tester.pumpWidget(_wrap(plan, onApprove: () => approved++));
    expect(find.text('Sakura Sushi'), findsOneWidget);
    expect(find.textContaining('Friday November 13'), findsOneWidget);
    expect(find.textContaining('\$56.00 total'), findsOneWidget);
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

  testWidgets('paying card shows my Pay button and half states',
      (tester) async {
    var paid = 0;
    final plan = DatePlan.tryParse(_planMap(
      status: 'paying',
      approvals: {'me': true, 'them': true},
      payments: {
        'me': {
          'order_id': 'X1',
          'approve_url': '',
          'amount_cents': 2800,
          'status': 'pending',
        },
        'them': {
          'order_id': 'X2',
          'approve_url': '',
          'amount_cents': 2800,
          'status': 'paid',
        },
      },
    ))!;
    await tester.pumpWidget(_wrap(plan, onPay: () => paid++));
    expect(find.text('One half paid — waiting for the other half'),
        findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('date-plan-pay')));
    expect(paid, 1);
  });

  testWidgets('confirmed card shows the confirmation number',
      (tester) async {
    final plan = DatePlan.tryParse(_planMap(
      status: 'confirmed',
      approvals: {'me': true, 'them': true},
      reservation: {'confirmation_number': 'AYMA-ABCD1234'},
    ))!;
    await tester.pumpWidget(_wrap(plan));
    expect(find.text('Reservation confirmed'), findsOneWidget);
    expect(
        find.text('Booking confirmation: AYMA-ABCD1234'), findsOneWidget);
    expect(find.byKey(const ValueKey('date-plan-approve')), findsNothing);
  });
}
