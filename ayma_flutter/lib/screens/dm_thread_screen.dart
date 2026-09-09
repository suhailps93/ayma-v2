import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/dm_service.dart';
import '../theme.dart';
import '../widgets/staggered.dart';

/// One DM conversation (§6.6, §6.11 step 9). Text send is wired; photo/voice
/// use the same message pipeline once a file is uploaded (Step 51 ingests them).
/// Image / file attachments upload to `uploads/{uid}/dm/{threadId}/…` and send
/// as `image` / `file` messages carrying the download URL + metadata.
/// Icebreaker chips (§6.9) show above the composer while the thread is empty and
/// a compatibility check has produced a `matches` doc for the pair.
class DmThreadScreen extends StatefulWidget {
  const DmThreadScreen({
    super.key,
    required this.threadId,
    this.title = 'Conversation',
    this.dmService,
    this.picker,
  });

  static const path = '/dm';

  final String threadId;
  final String title;
  final DmService? dmService;
  final ImagePicker? picker;

  @override
  State<DmThreadScreen> createState() => _DmThreadScreenState();
}

class _DmThreadScreenState extends State<DmThreadScreen> {
  late final DmService _dm = widget.dmService ?? DmService();
  late final ImagePicker _picker = widget.picker ?? ImagePicker();
  final _composer = TextEditingController();
  final _composerFocus = FocusNode();
  bool _sending = false;

  /// A picked-but-not-yet-sent attachment.
  File? _pending;
  String _pendingType = 'file'; // 'image' | 'file'

  List<String> _icebreakers = const [];

  @override
  void initState() {
    super.initState();
    _loadIcebreakers();
  }

  @override
  void dispose() {
    _composer.dispose();
    _composerFocus.dispose();
    super.dispose();
  }

  Future<void> _loadIcebreakers() async {
    try {
      final chips = await _dm.icebreakers(widget.threadId);
      if (mounted) setState(() => _icebreakers = chips);
    } catch (_) {
      // Icebreakers are a nicety — never surface a failure here.
    }
  }

  Future<void> _send() async {
    final text = _composer.text.trim();
    final pending = _pending;
    if (_sending) return;
    if (pending == null && text.isEmpty) return;

    setState(() => _sending = true);
    try {
      if (pending != null) {
        final att = await _dm.uploadAttachment(pending, threadId: widget.threadId);
        await _dm.sendAttachment(
          widget.threadId,
          type: _pendingType,
          attachment: att,
          caption: text,
        );
      } else {
        await _dm.sendText(widget.threadId, text);
      }
      _composer.clear();
      if (mounted) setState(() => _pending = null);
      // Keep the conversation-starters around — they're common ground to talk
      // about, not one-shot openers.
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Not sent ($e).')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _openAttachSheet() async {
    _composerFocus.unfocus();
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Photo'),
              onTap: () => Navigator.pop(ctx, 'gallery'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Camera'),
              onTap: () => Navigator.pop(ctx, 'camera'),
            ),
            ListTile(
              leading: const Icon(Icons.attach_file),
              title: const Text('File'),
              onTap: () => Navigator.pop(ctx, 'file'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    try {
      switch (choice) {
        case 'gallery':
          await _pickImage(ImageSource.gallery);
        case 'camera':
          await _pickImage(ImageSource.camera);
        case 'file':
          await _pickFile();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text("Couldn't attach that ($e).")));
      }
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    final p = await _picker.pickImage(
      source: source,
      maxWidth: 2000,
      imageQuality: 85,
    );
    if (p != null && mounted) {
      setState(() {
        _pending = File(p.path);
        _pendingType = 'image';
      });
    }
  }

  Future<void> _pickFile() async {
    final res = await FilePicker.platform.pickFiles(withReadStream: false);
    final path = res?.files.single.path;
    if (path != null && mounted) {
      setState(() {
        _pending = File(path);
        _pendingType = 'file';
      });
    }
  }

  Future<void> _blockAndReport() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Block & report'),
        content: const Text(
          'They will no longer be able to message you, this thread is hidden, '
          'and they drop out of your matches. This cannot be undone here.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Block')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _dm.block(_dm.otherUidOf(widget.threadId));
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not block ($e).')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final me = _dm.uid;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'block') _blockAndReport();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'block', child: Text('Block & report')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<List<DmMessage>>(
              stream: _dm.watchMessages(widget.threadId),
              builder: (context, snap) {
                final msgs = snap.data ?? const <DmMessage>[];
                // A brand-new thread has no doc yet; the stream can be briefly
                // empty or (transiently) error — never hang the screen on it.
                if (msgs.isEmpty) {
                  if (snap.connectionState == ConnectionState.waiting &&
                      !snap.hasError) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  return Center(
                    child: Text('Say something.',
                        style: AymaType.sans(
                            size: 15, soft: true, color: ac.fgMute)),
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  itemCount: msgs.length,
                  itemBuilder: (context, i) => FadeSlideIn(
                    delay: staggerDelay(i),
                    offset: 8,
                    child: _Bubble(
                      message: msgs[i],
                      mine: msgs[i].senderUid == me,
                    ),
                  ),
                );
              },
            ),
          ),
          if (_icebreakers.isNotEmpty)
            _IcebreakerBar(
              chips: _icebreakers,
              onTap: (text) {
                _composer.text = text;
                _composer.selection = TextSelection.collapsed(
                    offset: _composer.text.length);
                _composerFocus.requestFocus();
              },
            ),
          if (_pending != null)
            _PendingAttachment(
              file: _pending!,
              isImage: _pendingType == 'image',
              busy: _sending,
              onRemove: _sending ? null : () => setState(() => _pending = null),
            ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 12, 8),
              child: Row(
                children: [
                  IconButton(
                    onPressed: _sending ? null : _openAttachSheet,
                    icon: const Icon(Icons.add),
                    tooltip: 'Attach',
                  ),
                  Expanded(
                    child: TextField(
                      controller: _composer,
                      focusNode: _composerFocus,
                      minLines: 1,
                      maxLines: 4,
                      decoration: const InputDecoration(
                          hintText: 'Message', isDense: true),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _sending
                      ? const Padding(
                          padding: EdgeInsets.all(8),
                          child: SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : IconButton.filled(
                          onPressed: _send,
                          icon: const Icon(Icons.arrow_upward_rounded),
                        ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The picked-but-unsent attachment shown just above the composer, with a
/// thumbnail (images) or a file chip, a remove button, and a progress bar
/// while the send is uploading.
class _PendingAttachment extends StatelessWidget {
  const _PendingAttachment({
    required this.file,
    required this.isImage,
    required this.busy,
    required this.onRemove,
  });

  final File file;
  final bool isImage;
  final bool busy;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final name = file.uri.pathSegments.isNotEmpty
        ? file.uri.pathSegments.last
        : 'file';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: ac.lineSoft, width: 0.5)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: isImage
                    ? Image.file(file,
                        width: 44, height: 44, fit: BoxFit.cover)
                    : Container(
                        width: 44,
                        height: 44,
                        color: ac.bgCard,
                        alignment: Alignment.center,
                        child: Icon(Icons.insert_drive_file_outlined,
                            size: 22, color: ac.fgDim),
                      ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AymaType.sans(size: 13, color: ac.fgDim),
                ),
              ),
              IconButton(
                iconSize: 18,
                icon: const Icon(Icons.close),
                color: ac.fgMute,
                onPressed: onRemove,
              ),
            ],
          ),
          if (busy)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: LinearProgressIndicator(minHeight: 2),
            ),
        ],
      ),
    );
  }
}

class _IcebreakerBar extends StatelessWidget {
  const _IcebreakerBar({required this.chips, required this.onTap});
  final List<String> chips;
  final void Function(String) onTap;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: ac.lineSoft, width: 0.5)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Things to talk about',
              style: AymaType.sans(size: 12, soft: true, color: ac.fgMute)),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 168),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final c in chips)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: InkWell(
                        onTap: () => onTap(c),
                        borderRadius: BorderRadius.circular(14),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(
                            color: ac.bgCard,
                            borderRadius: BorderRadius.circular(14),
                            border:
                                Border.all(color: ac.lineSoft, width: 0.5),
                          ),
                          child: Text(
                            c,
                            softWrap: true,
                            style: AymaType.sans(size: 13, color: ac.fg),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.mine});
  final DmMessage message;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;

    if (message.hasImage) {
      return _wrap(context, tight: true, child: _image(context, ac));
    }
    if (message.hasFile) {
      return _wrap(context, tight: false, child: _file(context, ac));
    }

    final label = switch (message.type) {
      'photo' || 'image' => '📷 Photo',
      'voice' => '🎙 Voice message',
      'file' => '📎 File',
      'shared_profile' => '👤 Shared a profile',
      _ => message.body,
    };
    return _wrap(
      context,
      tight: false,
      child: Text(label,
          style: AymaType.sans(size: 15, color: ac.fg, height: 1.4)),
    );
  }

  Widget _wrap(BuildContext context,
      {required Widget child, required bool tight}) {
    final ac = context.ac;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: tight
            ? const EdgeInsets.all(4)
            : const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        decoration: BoxDecoration(
          color: mine ? ac.accentSoft : ac.bgCard,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: ac.lineSoft, width: 0.5),
        ),
        child: child,
      ),
    );
  }

  Widget _image(BuildContext context, AymaTokens ac) {
    final thumb = ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Image.network(
        message.attachmentUrl,
        width: 220,
        fit: BoxFit.cover,
        loadingBuilder: (ctx, child, progress) => progress == null
            ? child
            : Container(
                width: 220,
                height: 220,
                color: ac.bgCard,
                alignment: Alignment.center,
                child: const CircularProgressIndicator(strokeWidth: 2),
              ),
        errorBuilder: (ctx, _, __) => Container(
          width: 220,
          height: 120,
          color: ac.bgCard,
          alignment: Alignment.center,
          child: Icon(Icons.broken_image_outlined, color: ac.fgMute),
        ),
      ),
    );
    return Column(
      crossAxisAlignment:
          mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: () => showDialog<void>(
            context: context,
            builder: (_) => _ImageViewer(message.attachmentUrl),
          ),
          child: thumb,
        ),
        if (message.body.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 6, 6, 2),
            child: Text(message.body,
                style: AymaType.sans(size: 14, color: ac.fg, height: 1.4)),
          ),
      ],
    );
  }

  Widget _file(BuildContext context, AymaTokens ac) {
    return Column(
      crossAxisAlignment:
          mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: () => launchUrl(
            Uri.parse(message.attachmentUrl),
            mode: LaunchMode.externalApplication,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_fileIcon(message.mime), color: ac.fgDim),
              const SizedBox(width: 10),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      message.fileName.isNotEmpty
                          ? message.fileName
                          : 'Attachment',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AymaType.sans(
                          size: 14, color: ac.fg, weight: FontWeight.w500),
                    ),
                    if (message.size > 0)
                      Text(_fmtBytes(message.size),
                          style: AymaType.sans(size: 12, color: ac.fgMute)),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (message.body.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(message.body,
                style: AymaType.sans(size: 14, color: ac.fg, height: 1.4)),
          ),
      ],
    );
  }
}

IconData _fileIcon(String mime) {
  if (mime.startsWith('image/')) return Icons.image_outlined;
  if (mime.startsWith('audio/')) return Icons.audiotrack_outlined;
  if (mime.startsWith('video/')) return Icons.movie_outlined;
  if (mime == 'application/pdf') return Icons.picture_as_pdf_outlined;
  if (mime.contains('zip') || mime.contains('compressed')) {
    return Icons.folder_zip_outlined;
  }
  if (mime.startsWith('text/')) return Icons.description_outlined;
  return Icons.insert_drive_file_outlined;
}

String _fmtBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// A tap-to-zoom full-screen view of a DM image.
class _ImageViewer extends StatelessWidget {
  const _ImageViewer(this.url);
  final String url;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.black,
      insetPadding: EdgeInsets.zero,
      child: Stack(
        children: [
          Positioned.fill(
            child: InteractiveViewer(
              minScale: 0.5,
              maxScale: 4,
              child: Image.network(
                url,
                fit: BoxFit.contain,
                errorBuilder: (ctx, _, __) => const Center(
                  child: Icon(Icons.broken_image_outlined, color: Colors.white),
                ),
              ),
            ),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
        ],
      ),
    );
  }
}
