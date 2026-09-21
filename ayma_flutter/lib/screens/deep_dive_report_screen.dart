import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/api_client.dart';
import '../services/chat_inbox.dart';
import '../widgets/ask_ayma_action.dart';
import '../widgets/ayma_orb.dart';
import '../widgets/living_report_view.dart';
import '../widgets/out_of_credits.dart';
import 'main_shell_screen.dart';

/// A stored web deep dive on one person, re-opened from a `[deep_dive:<id>]`
/// chat marker or the "View research" button on a profile — works
/// identically whether it's your own dive or someone else's (a non-owner
/// gets a read-only render; correction quick-actions are owner-only, per
/// `meta.viewer_can_edit`).
///
/// Body is the ONE shared [LivingReportView] renderer (§ generic reports) —
/// summary sentences, facts, social links, photos found online, and (for the
/// owner) pending reverse-image-search candidates ("Photos to confirm" —
/// this screen is now their ONLY home; see `photo_candidates_screen.dart`'s
/// removal) all come from the same `GET /report/deep_dive/{id}` block read.
///
/// The AppBar's "Search again" / "Ask Ayma" actions need a couple of fields
/// the block model doesn't carry (who the dive is about, for `targetUid`) —
/// those still come from the existing dedicated `deepDiveReport` read,
/// fetched alongside purely for that metadata; the render itself never uses
/// it.
class DeepDiveReportScreen extends StatefulWidget {
  const DeepDiveReportScreen({super.key, required this.reportId, this.apiClient});

  static const path = '/deep-dive/:id';

  final String reportId;
  final ApiClient? apiClient;

  @override
  State<DeepDiveReportScreen> createState() => _DeepDiveReportScreenState();
}

class _DeepDiveReportScreenState extends State<DeepDiveReportScreen> {
  late final ApiClient _api = widget.apiClient ?? ApiClient();

  /// AppBar-action metadata only — the render itself comes entirely from
  /// [LivingReportView]'s own `GET /report/deep_dive/{id}` fetch.
  DeepDiveReport? _meta;
  bool _reRunning = false;

  @override
  void initState() {
    super.initState();
    _api.deepDiveReport(widget.reportId).then((r) {
      if (mounted) setState(() => _meta = r);
    }).catchError((_) {});
  }

  /// Re-run this search from scratch — works the same whether the report is
  /// about you or someone else; a forced dive always skips the reuse cache.
  /// The fresh result lands in chat when it's ready (same as any other
  /// dive), and reopening this report afterwards picks up the update.
  Future<void> _reRun(DeepDiveReport r) async {
    if (_reRunning) return;
    setState(() => _reRunning = true);
    try {
      final res = await _api.deepDive(
        targetUid: r.isSelf ? '' : r.otherUid,
        name: r.name,
        force: true,
      );
      if (!mounted) return;
      if (res.usageCapped) {
        showOutOfCreditsSnack(context);
        return;
      }
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(
          content: Text(r.isSelf
              ? "Searching again — I'll message you in chat when it's ready."
              : "Searching again for ${r.name.isEmpty ? 'them' : r.name} — "
                  "I'll message you in chat when it's ready."),
        ));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
            const SnackBar(content: Text("Couldn't start a new search.")));
    } finally {
      if (mounted) setState(() => _reRunning = false);
    }
  }

  /// Hand this research to the Ayma chat as an un-sent draft attachment — the
  /// chat opens with the report chipped above an empty composer so the user
  /// asks their own question about it.
  void _askAyma(DeepDiveReport r) {
    ChatInbox.instance.push(ChatKickoff.draftAbout(
      targetUid: r.otherUid,
      label: r.name.isEmpty ? 'them' : r.name,
      shareKind: 'deep_dive',
      photoUrl: r.subjectImage,
      refId: widget.reportId,
    ));
    context.go(MainShellScreen.path);
  }

  @override
  Widget build(BuildContext context) {
    final meta = _meta;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Web research'),
        actions: [
          if (meta != null) ...[
            IconButton(
              tooltip: 'Search again',
              onPressed: _reRunning ? null : () => _reRun(meta),
              icon: _reRunning
                  ? const AymaOrb(size: 18, state: AymaOrbState.thinking)
                  : const Icon(Icons.refresh),
            ),
            AskAymaAction(onPressed: () => _askAyma(meta)),
          ],
        ],
      ),
      body: LivingReportView(
        reportType: 'deep_dive',
        reportId: widget.reportId,
        apiClient: _api,
      ),
    );
  }
}
