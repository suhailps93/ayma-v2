import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../widgets/ayma_back_button.dart';

/// Plain multi-line editor for the user's own public profile text. Each
/// section sits under a `## Title` heading; the server diffs the edit, keeps
/// removed facts in the private AI notes and pins added facts. Pops `true`
/// once a save went through.
class ManualProfileEditScreen extends StatefulWidget {
  const ManualProfileEditScreen({super.key, this.apiClient});

  final ApiClient? apiClient;

  @override
  State<ManualProfileEditScreen> createState() =>
      _ManualProfileEditScreenState();
}

class _ManualProfileEditScreenState extends State<ManualProfileEditScreen> {
  late final ApiClient _api = widget.apiClient ?? ApiClient();
  final _controller = TextEditingController();
  ProfileTextDoc? _doc;
  String? _error;
  bool _loadFailed = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loadFailed = false;
      _error = null;
    });
    try {
      final doc = await _api.profilePublicText();
      if (!mounted) return;
      setState(() {
        _doc = doc;
        _controller.text = doc.text;
      });
    } on Object {
      if (mounted) setState(() => _loadFailed = true);
    }
  }

  Future<void> _save() async {
    final doc = _doc;
    if (doc == null || _saving) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await _api.profilePublicTextSave(
          text: _controller.text, baseVersion: doc.version);
      if (mounted) Navigator.of(context).pop(true);
    } on ProfileTextRejected catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on Object {
      if (mounted) {
        setState(() => _error = "Couldn't save your profile text. Try again.");
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final doc = _doc;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        leading: const AymaBackButton(),
        title: const Text('Edit manually'),
        actions: [
          TextButton(
            onPressed: doc == null || _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Save'),
          ),
        ],
      ),
      body: _loadFailed
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text("Couldn't load your profile text."),
                  TextButton(onPressed: _load, child: const Text('Retry')),
                ],
              ),
            )
          : doc == null
              ? const Center(child: CircularProgressIndicator())
              : Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'This is exactly what others see. Keep the ## '
                        'headings; they mark your sections. Anything you '
                        'remove stays in your private AI notes, and facts '
                        'you add are kept as yours.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 8),
                      Expanded(
                        child: TextField(
                          controller: _controller,
                          enabled: !_saving,
                          maxLines: null,
                          expands: true,
                          maxLength: doc.maxChars,
                          textAlignVertical: TextAlignVertical.top,
                          keyboardType: TextInputType.multiline,
                          decoration: const InputDecoration(
                              border: OutlineInputBorder()),
                        ),
                      ),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(_error!,
                              style: TextStyle(color: scheme.error)),
                        ),
                    ],
                  ),
                ),
    );
  }
}
