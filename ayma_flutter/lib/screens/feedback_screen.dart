import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/api_client.dart';
import '../services/chat_service.dart';
import '../theme.dart';
import '../widgets/ayma_primitives.dart';
import '../widgets/ayma_back_button.dart';
import '../widgets/ayma_toast.dart';

/// Product feedback — bugs and feature requests (§15). This is a separate
/// bucket from conversational feedback: Ayma never sees it; the team triages it
/// by hand. Screenshots are optional and upload to the user's own `uploads/`
/// tree before submit.
class FeedbackScreen extends StatefulWidget {
  const FeedbackScreen({super.key, this.api, this.chatService, this.picker});

  static const path = '/profile/feedback';

  final ApiClient? api;
  final ChatService? chatService;
  final ImagePicker? picker;

  @override
  State<FeedbackScreen> createState() => _FeedbackScreenState();
}

class _FeedbackScreenState extends State<FeedbackScreen> {
  late final ApiClient _api = widget.api ?? ApiClient();
  late final ChatService _chat = widget.chatService ?? ChatService();
  late final ImagePicker _picker = widget.picker ?? ImagePicker();
  final _text = TextEditingController();

  String _kind = 'bug';
  final List<File> _shots = [];
  bool _sending = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _addShot() async {
    if (_shots.length >= 4) return;
    try {
      final p = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        imageQuality: 85,
      );
      if (p != null && mounted) setState(() => _shots.add(File(p.path)));
    } catch (_) {/* ignore — user can still submit text */}
  }

  Future<void> _submit() async {
    final text = _text.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final paths = <String>[];
      for (final f in _shots) {
        final up = await _chat.uploadImage(f, prefix: 'feedback');
        paths.add(up.storagePath);
      }
      await _api.submitProductFeedback(
        kind: _kind,
        text: text,
        imagePaths: paths,
      );
      if (!mounted) return;
      AymaToast.show(context, 'Thanks — sent to the team.',
          kind: AymaToastKind.success);
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() => _sending = false);
        AymaToast.show(context, "Couldn't send that ($e).",
            kind: AymaToastKind.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(
        leading: const AymaBackButton(),
        title: const Text('Send feedback')),
      body: ListView(
        // iOS has no keyboard-dismiss key — dragging the form away is the
        // native escape hatch.
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
        children: [
          Text(
            'Bugs and feature ideas for the app. This goes straight to the '
            'team — Ayma doesn’t see it.',
            style: AymaType.sans(size: 13, color: ac.fgDim, height: 1.5),
          ),
          const SizedBox(height: 20),
          const Eyebrow('Type'),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'bug', label: Text('Bug')),
              ButtonSegment(value: 'idea', label: Text('Idea')),
            ],
            selected: {_kind},
            onSelectionChanged: (s) => setState(() => _kind = s.first),
          ),
          const SizedBox(height: 20),
          const Eyebrow('What happened'),
          const SizedBox(height: 8),
          TextField(
            controller: _text,
            minLines: 4,
            maxLines: 10,
            maxLength: 4000,
            decoration: InputDecoration(
              hintText: _kind == 'bug'
                  ? 'What did you do, and what went wrong?'
                  : 'What would you like Ayma to do?',
            ),
          ),
          const SizedBox(height: 12),
          const Eyebrow('Screenshots (optional)'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < _shots.length; i++)
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.file(_shots[i],
                          width: 72, height: 72, fit: BoxFit.cover),
                    ),
                    Positioned(
                      top: -10,
                      right: -10,
                      child: IconButton(
                        iconSize: 18,
                        icon: const Icon(Icons.cancel),
                        color: ac.fgMute,
                        onPressed: () => setState(() => _shots.removeAt(i)),
                      ),
                    ),
                  ],
                ),
              if (_shots.length < 4)
                OutlinedButton(
                  onPressed: _addShot,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(72, 72),
                    padding: EdgeInsets.zero,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: const Icon(Icons.add_a_photo_outlined, size: 20),
                ),
            ],
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _sending ? null : _submit,
            child: _sending
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Send'),
          ),
        ],
      ),
    );
  }
}
