import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../services/api_client.dart';
import '../services/chat_inbox.dart';
import '../services/chat_service.dart';
import '../services/profile_service.dart';
import '../theme.dart';
import '../widgets/body_report_view.dart';
import '../widgets/face_report_view.dart';
import 'main_shell_screen.dart';

/// Things Ayma can do on demand about *you* — search the web, read a face photo,
/// read a physique photo. Reached from one row on the Profile tab; replaces the
/// three loose rows that used to live there.
class SkillsScreen extends StatefulWidget {
  const SkillsScreen({
    super.key,
    this.profileService,
    this.api,
    this.chatService,
    this.imagePicker,
  });

  static const path = '/skills';

  final ProfileService? profileService;
  final ApiClient? api;
  final ChatService? chatService;
  final ImagePicker? imagePicker;

  @override
  State<SkillsScreen> createState() => _SkillsScreenState();
}

class _SkillsScreenState extends State<SkillsScreen> {
  late final ProfileService _profiles =
      widget.profileService ?? ProfileService();
  late final ApiClient _api = widget.api ?? ApiClient();
  late final ChatService _chat = widget.chatService ?? ChatService();
  late final ImagePicker _picker = widget.imagePicker ?? ImagePicker();

  ProfileData? _profile;
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await _profiles.readProfile();
      if (mounted) setState(() => _profile = data);
    } catch (_) {
      /* the web-search dialog just opens with an empty name field */
    }
  }

  // --- Web search --------------------------------------------------------

  Future<void> _searchWeb() async {
    final nameCtrl = TextEditingController(text: _profile?.fullName ?? '');
    final hintCtrl = TextEditingController();
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Search the web about me'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Your name'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: hintCtrl,
              decoration: const InputDecoration(
                labelText: 'Anything that helps',
                hintText: 'add anything that helps find the right you '
                    '(city, employer)',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Search'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    final name = nameCtrl.text.trim();
    final hint = hintCtrl.text.trim();
    final label = hint.isEmpty ? name : '$name — $hint';
    ChatInbox.instance.push(ChatKickoff.deepDive(
      label: label.isEmpty ? 'you' : label,
    ));
    context.go(MainShellScreen.path);
  }

  // --- Photo reports ----------------------------------------------------

  Future<void> _photoReport({required bool face}) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.account_circle_outlined),
              title: const Text('Use my profile photo'),
              onTap: () => Navigator.pop(ctx, 'profile'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose a photo'),
              onTap: () => Navigator.pop(ctx, 'pick'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;

    if (choice == 'profile') {
      face
          ? await showFaceReportSheet(context, api: _api, subjectLabel: 'you')
          : await showBodyReportSheet(context, api: _api, subjectLabel: 'you');
      return;
    }

    // choice == 'pick'
    final XFile? picked;
    try {
      picked = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        imageQuality: 88,
      );
    } catch (_) {
      _snack("Couldn't open that image.");
      return;
    }
    if (picked == null || !mounted) return;

    setState(() => _uploading = true);
    String path;
    try {
      final up = await _chat.uploadChatImage(File(picked.path));
      path = up.storagePath;
    } catch (_) {
      if (mounted) {
        setState(() => _uploading = false);
        _snack("Couldn't upload that photo.");
      }
      return;
    }
    if (!mounted) return;
    setState(() => _uploading = false);
    face
        ? await showFaceReportSheet(context, api: _api, attachmentPath: path)
        : await showBodyReportSheet(context, api: _api, attachmentPath: path);
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(title: const Text('Skills')),
      body: AbsorbPointer(
        absorbing: _uploading,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            _SkillCard(
              icon: Icons.travel_explore,
              title: 'Search the web about me',
              body: "Ayma looks you up online so you don't have to repeat "
                  'yourself, then confirms what she found in chat.',
              onTap: _searchWeb,
            ),
            _SkillCard(
              icon: Icons.face_retouching_natural,
              title: 'Facial beauty report',
              body: 'An honest, data-driven read on a face photo.',
              onTap: () => _photoReport(face: true),
            ),
            _SkillCard(
              icon: Icons.accessibility_new,
              title: 'Physique report',
              body: 'An honest, data-driven read on a full-body photo.',
              onTap: () => _photoReport(face: false),
            ),
            if (_uploading) ...[
              const SizedBox(height: 16),
              const Center(child: CircularProgressIndicator()),
            ],
            const SizedBox(height: 20),
            Text(
              'These run on Gemini and use credits.',
              style: AymaType.sans(size: 12, soft: true, color: ac.fgMute),
            ),
          ],
        ),
      ),
    );
  }
}

class _SkillCard extends StatelessWidget {
  const _SkillCard({
    required this.icon,
    required this.title,
    required this.body,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String body;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: ac.bgElev,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: ac.fgDim, size: 22),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: AymaType.sans(
                              size: 15,
                              weight: FontWeight.w600,
                              color: ac.fg)),
                      const SizedBox(height: 4),
                      Text(body,
                          style: AymaType.sans(
                              size: 12, soft: true, color: ac.fgMute)),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: ac.fgMute, size: 18),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
