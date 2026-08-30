import 'package:flutter/material.dart';

import '../services/profile_service.dart';
import '../theme.dart';

/// Post-onboarding editor for the structured profile fields (§4.5, §4.6 step 7).
///
/// Same six fields as preboarding minus the photo (photo management is Step 60).
/// Writes only the structured `users/{uid}/profile/main` doc — never the wiki.
class ProfileSettingsScreen extends StatefulWidget {
  const ProfileSettingsScreen({super.key, this.profileService});

  static const path = '/settings/profile';

  final ProfileService? profileService;

  @override
  State<ProfileSettingsScreen> createState() => _ProfileSettingsScreenState();
}

class _ProfileSettingsScreenState extends State<ProfileSettingsScreen> {
  late final ProfileService _profiles =
      widget.profileService ?? ProfileService();
  final _nameController = TextEditingController();
  final _locationController = TextEditingController();

  static const _genders = ['Woman', 'Man', 'Non-binary', 'Other'];
  static const _interestOptions = ['Women', 'Men', 'Everyone'];

  bool _loading = true;
  bool _saving = false;
  String? _error;
  DateTime? _birthdate;
  String? _gender;
  final Set<String> _interestedIn = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _locationController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final data = await _profiles.readProfile();
      if (!mounted) return;
      setState(() {
        _nameController.text = data?.name ?? '';
        _locationController.text = data?.location ?? '';
        _birthdate = data?.birthdate;
        _gender = (data?.gender.isNotEmpty ?? false) ? data!.gender : null;
        _interestedIn
          ..clear()
          ..addAll(data?.interestedIn ?? const []);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load your profile ($e).';
        _loading = false;
      });
    }
  }

  bool get _canSave =>
      !_saving &&
      _nameController.text.trim().isNotEmpty &&
      _locationController.text.trim().isNotEmpty &&
      _gender != null &&
      _interestedIn.isNotEmpty &&
      _birthdate != null;

  Future<void> _pickBirthdate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _birthdate ?? DateTime(now.year - 25, now.month, now.day),
      firstDate: DateTime(now.year - 100),
      lastDate: DateTime(now.year - 18, now.month, now.day),
    );
    if (picked != null) setState(() => _birthdate = picked);
  }

  Future<void> _save() async {
    if (!_canSave) return;
    setState(() => _saving = true);
    try {
      await _profiles.updateStructuredFields(
        name: _nameController.text,
        birthdate: _birthdate,
        gender: _gender,
        interestedIn: _interestedIn.toList(),
        location: _locationController.text,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Profile saved')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Save failed ($e)')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(title: const Text('Edit profile')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!,
                        style: AymaType.sans(size: 14, color: AymaColors.error)),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                  children: [
                    _label('Name', ac),
                    TextField(
                      controller: _nameController,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(hintText: 'Your name'),
                    ),
                    const SizedBox(height: 20),
                    _label('Date of birth', ac),
                    OutlinedButton(
                      onPressed: _pickBirthdate,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          _birthdate == null
                              ? 'Pick a date'
                              : '${_birthdate!.year}-'
                                  '${_birthdate!.month.toString().padLeft(2, '0')}-'
                                  '${_birthdate!.day.toString().padLeft(2, '0')}',
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    _label('Gender', ac),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final g in _genders)
                          ChoiceChip(
                            label: Text(g),
                            selected: _gender == g,
                            onSelected: (_) => setState(() => _gender = g),
                          ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    _label('Interested in', ac),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final opt in _interestOptions)
                          FilterChip(
                            label: Text(opt),
                            selected: _interestedIn.contains(opt),
                            onSelected: (on) => setState(() {
                              on
                                  ? _interestedIn.add(opt)
                                  : _interestedIn.remove(opt);
                            }),
                          ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    _label('Location', ac),
                    TextField(
                      controller: _locationController,
                      onChanged: (_) => setState(() {}),
                      decoration:
                          const InputDecoration(hintText: 'City, country'),
                    ),
                    const SizedBox(height: 32),
                    FilledButton(
                      onPressed: _canSave ? _save : null,
                      child: Text(_saving ? 'Saving…' : 'Save'),
                    ),
                  ],
                ),
    );
  }

  Widget _label(String text, AymaTokens ac) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text,
            style: AymaType.sans(size: 13, soft: true, color: ac.fgMute)),
      );
}
