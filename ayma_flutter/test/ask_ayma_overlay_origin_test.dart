// Ask Ayma's context/origin plumbing (`AskAymaContext`/`AskAymaOrigin` in
// `ask_ayma_overlay.dart`), exercised directly rather than through one of the
// screens that opens it — quick-suggestion chips per origin, and that a sent
// message threads `deepDiveReportId`/`deepDiveTarget`/`appearanceFindingId`
// into the `/chat` request exactly like `storyPageId`/`storyPassage`/
// `storyTimelineEntryId` already do for Story.
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:ayma_flutter/widgets/ask_ayma_overlay.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeApi extends ApiClient {
  _FakeApi() : super(auth: MockFirebaseAuth(signedIn: true));

  final List<Map<String, String>> chatCalls = [];
  ChatResult reply = const ChatResult(reply: 'ok');

  @override
  Stream<ChatEvent> chatStream(
    String message, {
    String sessionId = '',
    String viewingProfileUid = '',
    List<Map<String, String>> recentTurns = const [],
    String imagePath = '',
    String storyPageId = '',
    String storyPassage = '',
    String storyTimelineEntryId = '',
    String deepDiveReportId = '',
    String deepDiveTarget = '',
    String appearanceFindingId = '',
    String matchReportId = '',
    String sharedKind = '',
    String sharedRefId = '',
    String sharedSubjectUid = '',
    String sharedSubjectName = '',
    String sharedRefVersion = '',
    String replyImagePath = '',
    String sharedCardKind = '',
    String sharedCardUid = '',
    String sharedCardName = '',
    String sharedCardPhoto = '',
    String sharedCardRefId = '',
    bool profileEdit = false,
    String photoUrl = '',
    String photoSource = '',
    String screen = '',
    String screenSubjectUid = '',
    String screenSubjectName = '',
    String screenNote = '',
    String screenRoute = '',
    String screenPreviousRoute = '',
    String screenPreviousLabel = '',
    String clientMsgId = '',
    CallStateSnapshot callState = const CallStateSnapshot.none(),
  }) async* {
    // The sheet always tries the stream first — fail it so every call
    // exercises (and this test only has to assert on) the plain `chat` path.
    throw ApiException('no stream in tests');
  }

  @override
  Future<ChatResult> chat(
    String message, {
    String sessionId = '',
    String viewingProfileUid = '',
    List<Map<String, String>> recentTurns = const [],
    String imagePath = '',
    String storyPageId = '',
    String storyPassage = '',
    String storyTimelineEntryId = '',
    String deepDiveReportId = '',
    String deepDiveTarget = '',
    String appearanceFindingId = '',
    String matchReportId = '',
    String sharedKind = '',
    String sharedRefId = '',
    String sharedSubjectUid = '',
    String sharedSubjectName = '',
    String sharedRefVersion = '',
    String replyImagePath = '',
    String sharedCardKind = '',
    String sharedCardUid = '',
    String sharedCardName = '',
    String sharedCardPhoto = '',
    String sharedCardRefId = '',
    bool profileEdit = false,
    String photoUrl = '',
    String photoSource = '',
    String screen = '',
    String screenSubjectUid = '',
    String screenSubjectName = '',
    String screenNote = '',
    String screenRoute = '',
    String screenPreviousRoute = '',
    String screenPreviousLabel = '',
    String clientMsgId = '',
    bool tourContinuation = false,
    CallStateSnapshot callState = const CallStateSnapshot.none(),
  }) async {
    chatCalls.add({
      'message': message,
      'story_page_id': storyPageId,
      'story_passage': storyPassage,
      'story_timeline_entry_id': storyTimelineEntryId,
      'deep_dive_report_id': deepDiveReportId,
      'deep_dive_target': deepDiveTarget,
      'appearance_finding_id': appearanceFindingId,
      'match_report_id': matchReportId,
    });
    return reply;
  }
}

Future<void> _openSheet(WidgetTester tester, ApiClient api, AskAymaContext ctx) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () => showAskAymaOverlay(context, api: api, ctx: ctx, transcriptStore: TranscriptStore()),
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  group('quick-suggestion chips per origin', () {
    testWidgets('story (public passage)', (tester) async {
      await _openSheet(tester, _FakeApi(), const AskAymaContext(
        origin: AskAymaOrigin.story,
        pageId: 'career',
        quoteText: 'x',
      ));
      expect(find.text('Make private'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
      expect(find.text('Make this more concise'), findsOneWidget);
      expect(find.text('Add more details'), findsOneWidget);
      expect(find.text('Rewrite in my tone'), findsOneWidget);
    });

    testWidgets('deepDiveFact', (tester) async {
      await _openSheet(tester, _FakeApi(), const AskAymaContext(
        origin: AskAymaOrigin.deepDiveFact,
        quoteText: 'x',
      ));
      expect(find.text('Delete'), findsOneWidget);
      expect(find.text("That's not accurate"), findsOneWidget);
    });

    testWidgets('deepDiveSummary', (tester) async {
      await _openSheet(tester, _FakeApi(), const AskAymaContext(
        origin: AskAymaOrigin.deepDiveSummary,
        quoteText: 'x',
      ));
      expect(find.text("That's not accurate"), findsOneWidget);
      expect(find.text('Delete'), findsNothing);
    });

    testWidgets('deepDiveSocial', (tester) async {
      await _openSheet(tester, _FakeApi(), const AskAymaContext(
        origin: AskAymaOrigin.deepDiveSocial,
        quoteText: 'x',
      ));
      expect(find.text("That's not my link"), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
    });

    testWidgets('deepDivePhoto', (tester) async {
      await _openSheet(tester, _FakeApi(), const AskAymaContext(
        origin: AskAymaOrigin.deepDivePhoto,
        quoteText: 'x',
      ));
      expect(find.text("That's not my photo"), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
    });

    testWidgets('appearanceAttribute', (tester) async {
      await _openSheet(tester, _FakeApi(), const AskAymaContext(
        origin: AskAymaOrigin.appearanceAttribute,
        quoteText: 'x',
      ));
      expect(find.text("That's not correct"), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
    });

    testWidgets('appearanceFace', (tester) async {
      await _openSheet(tester, _FakeApi(), const AskAymaContext(
        origin: AskAymaOrigin.appearanceFace,
        quoteText: 'x',
      ));
      expect(find.text("That's not correct"), findsOneWidget);
      expect(find.text('Delete'), findsNothing);
    });

    testWidgets('appearanceBody', (tester) async {
      await _openSheet(tester, _FakeApi(), const AskAymaContext(
        origin: AskAymaOrigin.appearanceBody,
        quoteText: 'x',
      ));
      expect(find.text("That's not correct"), findsOneWidget);
      expect(find.text('Delete'), findsNothing);
    });
  });

  group('context fields thread into the chat request', () {
    testWidgets('deep-dive fields ride along, appearance stays empty',
        (tester) async {
      final api = _FakeApi();
      await _openSheet(tester, api, const AskAymaContext(
        origin: AskAymaOrigin.deepDiveFact,
        deepDiveReportId: 'report1',
        deepDiveTarget: 'fact:abc',
        quoteText: 'x',
      ));

      await tester.enterText(find.byType(TextField).last, 'Delete');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await tester.pumpAndSettle();

      expect(api.chatCalls, hasLength(1));
      final call = api.chatCalls.single;
      expect(call['deep_dive_report_id'], 'report1');
      expect(call['deep_dive_target'], 'fact:abc');
      expect(call['appearance_finding_id'], '');
      expect(call['story_page_id'], '');
    });

    testWidgets('appearance field rides along, deep-dive stays empty',
        (tester) async {
      final api = _FakeApi();
      await _openSheet(tester, api, const AskAymaContext(
        origin: AskAymaOrigin.appearanceAttribute,
        appearanceFindingId: 'eye_color',
        quoteText: 'Brown',
      ));

      await tester.enterText(
          find.byType(TextField).last, "they're actually blue");
      await tester.pump();
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await tester.pumpAndSettle();

      expect(api.chatCalls, hasLength(1));
      final call = api.chatCalls.single;
      expect(call['appearance_finding_id'], 'eye_color');
      expect(call['deep_dive_report_id'], '');
      expect(call['deep_dive_target'], '');
    });

    testWidgets(
        'match-report field rides along on a reportView-origin tap, '
        'deep-dive/appearance stay empty', (tester) async {
      final api = _FakeApi();
      // Mirrors `LivingReportView._open` for `reportType: 'match'`: always
      // `reportView` (match has no correction path — `report_type`/
      // `report_id` stay unset), but `matchReportId` still rides along so
      // `_match_edit_context` in main.py can brief Ayma.
      await _openSheet(tester, api, const AskAymaContext(
        origin: AskAymaOrigin.reportView,
        matchReportId: 'a__me',
        quoteText: 'You two line up on the big things.',
      ));

      await tester.enterText(
          find.byType(TextField).last, "I don't live in Colorado");
      await tester.pump();
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await tester.pumpAndSettle();

      expect(api.chatCalls, hasLength(1));
      final call = api.chatCalls.single;
      expect(call['match_report_id'], 'a__me');
      expect(call['deep_dive_report_id'], '');
      expect(call['appearance_finding_id'], '');
    });
  });
}
