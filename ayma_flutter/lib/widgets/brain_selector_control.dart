import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../theme.dart';
import 'ayma_toast.dart';

/// The unified **Brain** picker (ARCHITECTURE §13.10). Reads
/// `GET /brain/preference` and lets the user choose the ONE LLM that drives
/// every text surface — chat, matching, DM coaching and cross-language
/// translation. A capability the chosen brain lacks (image reading, live web
/// research) automatically falls back to Gemini, so the choice can never drop a
/// feature; this control just states that in each brain's description.
///
/// Saving calls `POST /brain/preference`; it takes effect on the next text
/// turn. This sits ABOVE the voice stack control on the "Ayma's models" screen
/// and is independent of it — the Voice section (mode / model / voice /
/// language / accent) is unchanged.
class BrainSelectorControl extends StatefulWidget {
  const BrainSelectorControl({super.key, required this.api, this.onSaved});

  final ApiClient api;
  final VoidCallback? onSaved;

  @override
  State<BrainSelectorControl> createState() => _BrainSelectorControlState();
}

class _BrainSelectorControlState extends State<BrainSelectorControl> {
  BrainCatalog? _cat;
  String? _selected;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final cat = await widget.api.brainPreference();
      if (!mounted) return;
      setState(() {
        _cat = cat;
        _selected = cat.effectiveId;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _save() async {
    final brain = _selected;
    if (brain == null || brain.isEmpty) return;
    setState(() => _saving = true);
    try {
      await widget.api.saveBrainPreference(brain);
      if (mounted) {
        AymaToast.show(context, 'Brain saved — starts on your next message.');
        widget.onSaved?.call();
      }
    } catch (e) {
      if (mounted) {
        AymaToast.show(context, 'Could not save ($e).',
            kind: AymaToastKind.error);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    if (_error != null) {
      return Text('Could not load brains ($_error).',
          key: const ValueKey('brain-selector-error'),
          style: AymaType.sans(size: 13, color: AymaColors.error));
    }
    if (_cat == null || _selected == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final cat = _cat!;
    final shown = [for (final b in cat.brains) if (b.available) b];
    final selected = shown.any((b) => b.id == _selected)
        ? _selected
        : (shown.isNotEmpty ? shown.first.id : null);
    final current = shown.where((b) => b.id == selected);
    return Column(
      key: const ValueKey('brain-selector-control'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(ac, 'BRAIN'),
        _dropdown(
          ac,
          value: selected,
          items: [
            for (final b in shown)
              DropdownMenuItem(
                value: b.id,
                child: Text(b.label, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: shown.isEmpty || _saving
              ? null
              : (v) => setState(() => _selected = v),
        ),
        if (current.isNotEmpty && current.first.description.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              current.first.description,
              style: AymaType.sans(size: 12, soft: true, color: ac.fgMute),
            ),
          ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton(
            key: const ValueKey('brain-selector-save'),
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Save brain'),
          ),
        ),
      ],
    );
  }

  Widget _label(AymaTokens ac, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text,
            style: AymaType.mono(size: 10, color: ac.fgMute)
                .copyWith(letterSpacing: 1.5)),
      );

  Widget _dropdown(
    AymaTokens ac, {
    required String? value,
    required List<DropdownMenuItem<String>> items,
    required ValueChanged<String?>? onChanged,
  }) {
    final effective = items.any((i) => i.value == value) ? value : null;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        border: Border.all(color: ac.lineSoft),
        borderRadius: BorderRadius.circular(8),
      ),
      child: DropdownButton<String>(
        key: const ValueKey('brain-dropdown'),
        value: effective,
        isExpanded: true,
        underline: const SizedBox.shrink(),
        items: items,
        onChanged: _saving ? null : onChanged,
        style: AymaType.sans(size: 15, color: ac.fg),
      ),
    );
  }
}
