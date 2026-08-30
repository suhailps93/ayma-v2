import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../services/api_client.dart';
import '../services/profile_service.dart';

/// Preboarding — typed/tapped form version (Step 7).
///
/// The six structural fields from §4.2 in fixed order: name, birthdate, gender,
/// interested_in, location, profile_photo. No voice (Step 31), no location
/// auto-detect (Step 35). On finish it writes `users/{uid}/profile`, kicks off
/// the photo face-embedding (§2.5, Step 30), and routes to the main shell.
class PreboardingFlowScreen extends StatefulWidget {
  const PreboardingFlowScreen({
    super.key,
    this.profileService,
    this.apiClient,
  });

  static const path = '/preboarding';

  final ProfileService? profileService;
  final ApiClient? apiClient;

  @override
  State<PreboardingFlowScreen> createState() => _PreboardingFlowScreenState();
}

class _PreboardingFlowScreenState extends State<PreboardingFlowScreen> {
  late final ProfileService _profiles =
      widget.profileService ?? ProfileService();
  late final ApiClient _api = widget.apiClient ?? ApiClient();
  final _pageController = PageController();
  final _nameController = TextEditingController();
  final _locationController = TextEditingController();

  static const _genders = ['Woman', 'Man', 'Non-binary', 'Other'];
  static const _interestOptions = ['Women', 'Men', 'Everyone'];

  int _step = 0;
  DateTime? _birthdate;
  String? _gender;
  final Set<String> _interestedIn = {};
  File? _photo;
  bool _saving = false;

  static const _lastStep = 5;

  @override
  void dispose() {
    _pageController.dispose();
    _nameController.dispose();
    _locationController.dispose();
    super.dispose();
  }

  bool get _canAdvance {
    switch (_step) {
      case 0:
        return _nameController.text.trim().isNotEmpty;
      case 1:
        return _birthdate != null && _isAdult(_birthdate!);
      case 2:
        return _gender != null;
      case 3:
        return _interestedIn.isNotEmpty;
      case 4:
        return _locationController.text.trim().isNotEmpty;
      case 5:
        return _photo != null;
      default:
        return false;
    }
  }

  static bool _isAdult(DateTime birthdate) {
    final now = DateTime.now();
    var age = now.year - birthdate.year;
    if (now.month < birthdate.month ||
        (now.month == birthdate.month && now.day < birthdate.day)) {
      age--;
    }
    return age >= 18;
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _pickBirthdate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _birthdate ?? DateTime(now.year - 25, now.month, now.day),
      firstDate: DateTime(now.year - 100),
      lastDate: now,
    );
    if (picked != null) setState(() => _birthdate = picked);
  }

  Future<void> _pickPhoto() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1600,
      imageQuality: 88,
    );
    if (picked != null) setState(() => _photo = File(picked.path));
  }

  Future<void> _next() async {
    if (!_canAdvance) {
      _snack('Please complete this step first.');
      return;
    }
    if (_step < _lastStep) {
      setState(() => _step++);
      _pageController.animateToPage(
        _step,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
      return;
    }
    await _finish();
  }

  void _back() {
    if (_step == 0) return;
    setState(() => _step--);
    _pageController.animateToPage(
      _step,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  Future<void> _finish() async {
    setState(() => _saving = true);
    try {
      final storagePath = await _profiles.uploadProfilePhoto(_photo!);
      await _profiles.savePreboarding(
        name: _nameController.text,
        birthdate: _birthdate!,
        gender: _gender!,
        interestedIn: _interestedIn.toList(),
        location: _locationController.text,
        photoStoragePath: storagePath,
      );
      // Face embedding (§2.5) — best-effort, must not block finishing onboarding.
      unawaited(_api
          .registerMedia(storagePath, context: 'profile')
          .catchError((_) {}));
      if (!mounted) return;
      context.go('/');
    } catch (e) {
      _snack('Could not save your profile: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('About you (${_step + 1}/${_lastStep + 1})'),
        leading: _step == 0
            ? null
            : IconButton(icon: const Icon(Icons.arrow_back), onPressed: _back),
      ),
      body: AbsorbPointer(
        absorbing: _saving,
        child: Column(
          children: [
            Expanded(
              child: PageView(
                controller: _pageController,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  _stepPadding(_nameStep()),
                  _stepPadding(_birthdateStep()),
                  _stepPadding(_genderStep()),
                  _stepPadding(_interestedInStep()),
                  _stepPadding(_locationStep()),
                  _stepPadding(_photoStep()),
                ],
              ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton(
                  onPressed: _saving ? null : _next,
                  child: _saving
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(_step < _lastStep ? 'Next' : 'Finish'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stepPadding(Widget child) =>
      Padding(padding: const EdgeInsets.all(24), child: child);

  Widget _nameStep() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('What should Ayma call you?'),
          const SizedBox(height: 16),
          TextField(
            controller: _nameController,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Name'),
            onChanged: (_) => setState(() {}),
          ),
        ],
      );

  Widget _birthdateStep() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Your date of birth (you must be 18+).'),
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: _pickBirthdate,
            child: Text(
              _birthdate == null
                  ? 'Pick a date'
                  : '${_birthdate!.year}-${_birthdate!.month.toString().padLeft(2, '0')}-${_birthdate!.day.toString().padLeft(2, '0')}',
            ),
          ),
          if (_birthdate != null && !_isAdult(_birthdate!))
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('You must be at least 18.',
                  style: TextStyle(color: Colors.red)),
            ),
        ],
      );

  Widget _genderStep() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('How do you identify?'),
          const SizedBox(height: 16),
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
        ],
      );

  Widget _interestedInStep() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Who would you like to be matched with?'),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            children: [
              for (final option in _interestOptions)
                FilterChip(
                  label: Text(option),
                  selected: _interestedIn.contains(option),
                  onSelected: (selected) => setState(() {
                    if (selected) {
                      _interestedIn.add(option);
                    } else {
                      _interestedIn.remove(option);
                    }
                  }),
                ),
            ],
          ),
        ],
      );

  Widget _locationStep() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Where are you based?'),
          const SizedBox(height: 16),
          TextField(
            controller: _locationController,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'City',
              hintText: 'e.g. Austin, TX',
            ),
            onChanged: (_) => setState(() {}),
          ),
        ],
      );

  Widget _photoStep() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Add a profile photo.'),
          const SizedBox(height: 16),
          if (_photo != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Image.file(_photo!, height: 200, fit: BoxFit.cover),
            ),
          OutlinedButton.icon(
            onPressed: _pickPhoto,
            icon: const Icon(Icons.photo_library_outlined),
            label: Text(_photo == null ? 'Choose photo' : 'Choose a different photo'),
          ),
        ],
      );
}
