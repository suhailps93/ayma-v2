import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../theme.dart';
import '../widgets/ayma_back_button.dart';
import '../widgets/ayma_toast.dart';

/// Import the user's LinkedIn work history into dated Career nodes (founder
/// order, 2026-11-18). The official LinkedIn API gives no work history to a
/// standard app (Sign in with LinkedIn / OpenID Connect grants name, email and
/// picture only — positions need a restricted partner program), so the route is
/// the user's own LinkedIn data export: LinkedIn -> Settings -> "Get a copy of
/// your data" ships a `Positions.csv`. The user uploads that file here; Ayma
/// parses it on the server into dated career nodes and the Career timeline in
/// Your Story fills. No LinkedIn credentials, no scraping.
class LinkedInImportScreen extends StatefulWidget {
  const LinkedInImportScreen({super.key, this.api});

  static const path = '/settings/linkedin-import';

  final ApiClient? api;

  @override
  State<LinkedInImportScreen> createState() => _LinkedInImportScreenState();
}

class _LinkedInImportScreenState extends State<LinkedInImportScreen> {
  late final ApiClient _api = widget.api ?? ApiClient();
  bool _busy = false;
  String? _error;
  String? _done;

  Future<void> _pickAndImport() async {
    setState(() {
      _busy = true;
      _error = null;
      _done = null;
    });
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['csv', 'txt'],
        withData: true,
      );
      if (picked == null || picked.files.isEmpty) {
        setState(() => _busy = false); // user cancelled — no error
        return;
      }
      final file = picked.files.first;
      final bytes = file.bytes;
      if (bytes == null || bytes.isEmpty) {
        setState(() {
          _busy = false;
          _error = "That file was empty. Pick the Positions.csv from your "
              "LinkedIn data export.";
        });
        return;
      }
      final csv = utf8.decode(bytes, allowMalformed: true);
      final result = await _api.linkedinImport(csv: csv);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _done = _summary(result);
      });
      AymaToast.show(context, 'LinkedIn work history imported.');
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = "Couldn't read that file. Pick the Positions.csv from your "
            "LinkedIn data export.";
      });
    }
  }

  String _summary(Map<String, dynamic> r) {
    final parsed = (r['parsed'] as num?)?.toInt() ?? 0;
    final created = (r['created'] as num?)?.toInt() ?? 0;
    final folded = (r['folded'] as num?)?.toInt() ?? 0;
    final updated = (r['updated'] as num?)?.toInt() ?? 0;
    if (parsed == 0) {
      return "No work history found in that file. Make sure it's the "
          "Positions.csv from your LinkedIn data export.";
    }
    final parts = <String>[];
    if (created > 0) parts.add('$created added');
    if (folded > 0) parts.add('$folded merged with your notes');
    if (updated > 0) parts.add('$updated updated');
    final detail = parts.isEmpty ? '' : ' (${parts.join(', ')})';
    return 'Imported $parsed role${parsed == 1 ? '' : 's'}$detail. '
        'Your Career timeline in Your Story is now up to date.';
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      backgroundColor: ac.bg,
      appBar: AppBar(
        leading: const AymaBackButton(),
        backgroundColor: ac.bg,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        foregroundColor: ac.fg,
        title: Text('Import from LinkedIn',
            style: AymaType.sans(size: 17, color: ac.fg)),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.work_history_outlined, color: ac.accent, size: 36),
              const SizedBox(height: 16),
              Text('Bring in your work history',
                  style: AymaType.serif(size: 22, color: ac.fg)),
              const SizedBox(height: 10),
              Text(
                'Ayma builds a dated Career timeline in Your Story from your '
                'real roles. Import them straight from your LinkedIn data '
                'export — no password, nothing scraped.',
                style: AymaType.sans(size: 14, soft: true, color: ac.fgMute),
              ),
              const SizedBox(height: 20),
              _stepsCard(ac),
              const SizedBox(height: 20),
              if (_error != null) ...[
                Text(_error!,
                    style: AymaType.sans(size: 13, color: ac.error)),
                const SizedBox(height: 12),
              ],
              if (_done != null) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: ac.accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(_done!,
                      style: AymaType.sans(size: 13, color: ac.fg)),
                ),
                const SizedBox(height: 12),
              ],
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _busy ? null : _pickAndImport,
                  style: FilledButton.styleFrom(
                      minimumSize: const Size(64, 50)),
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.upload_file_outlined),
                  label: Text(_busy
                      ? 'Importing…'
                      : (_done == null
                          ? 'Choose your Positions.csv'
                          : 'Import another file')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _stepsCard(AymaTokens ac) {
    const steps = [
      'On LinkedIn: Settings & Privacy → Data Privacy → "Get a copy of your '
          'data".',
      'Pick "Positions" (or the full archive) and download the email LinkedIn '
          'sends.',
      'Unzip it and come back here to choose the Positions.csv file.',
    ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ac.bgCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: ac.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < steps.length; i++)
            Padding(
              padding: EdgeInsets.only(bottom: i == steps.length - 1 ? 0 : 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${i + 1}.',
                      style: AymaType.sans(
                          size: 13, color: ac.accent, weight: FontWeight.w600)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(steps[i],
                        style:
                            AymaType.sans(size: 13, soft: true, color: ac.fgMute)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
