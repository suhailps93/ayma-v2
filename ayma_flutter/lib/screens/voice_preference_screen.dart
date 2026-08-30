import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/profile_service.dart';
import '../theme.dart';

/// Pick the Gemini Live voice preset Ayma speaks with (§13.3, §13.8 step 5).
/// The description under each name is the "preview" — the presets are a fixed
/// set with distinct character, not free-form synthesis. A change takes effect
/// from the next voice session (Gemini Live sets the voice at session start).
class VoicePreferenceScreen extends StatefulWidget {
  const VoicePreferenceScreen({super.key, this.api, this.profileService});

  static const path = '/settings/voice';

  final ApiClient? api;
  final ProfileService? profileService;

  @override
  State<VoicePreferenceScreen> createState() => _VoicePreferenceScreenState();
}

class _VoicePreferenceScreenState extends State<VoicePreferenceScreen> {
  late final ApiClient _api = widget.api ?? ApiClient();
  late final ProfileService _profiles =
      widget.profileService ?? ProfileService();

  VoicePresets? _data;
  String? _error;
  String? _selected;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await _api.voicePresets();
      if (mounted) {
        setState(() {
          _data = d;
          _selected = d.effective;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _choose(String name) async {
    final previous = _selected;
    setState(() {
      _selected = name;
      _saving = true;
    });
    try {
      await _profiles.setVoicePreference(name);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Saved — Ayma uses this from your next voice session.'),
        ));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _selected = previous);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not save ($e).')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(title: const Text('Ayma’s voice')),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Could not load voices ($_error).',
                    style: AymaType.sans(size: 14, color: AymaColors.error)),
              ),
            )
          : _data == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  children: [
                    for (final p in _data!.presets)
                      RadioListTile<String>(
                        value: p.name,
                        groupValue: _selected,
                        onChanged: _saving ? null : (v) => _choose(v!),
                        title: Text(p.name,
                            style: AymaType.sans(size: 15, color: ac.fg)),
                        subtitle: Text(p.description,
                            style: AymaType.sans(
                                size: 12, soft: true, color: ac.fgMute)),
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                      child: Text(
                        'A new voice starts at your next voice session — '
                        'Ayma can’t switch voices mid-call.',
                        style: AymaType.sans(
                            size: 12, soft: true, color: ac.fgMute),
                      ),
                    ),
                  ],
                ),
    );
  }
}
