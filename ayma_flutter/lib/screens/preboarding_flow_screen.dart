import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../services/api_client.dart';
import '../services/location_service.dart';
import '../services/profile_service.dart';
import '../services/transcript_store.dart';
import '../services/voice_session_controller.dart';

/// Preboarding (§4.2). Six fields in fixed order: name, birthdate, gender,
/// interested_in, location, profile_photo. Every field is a typed/tapped form
/// control, and — when the voice session is on (Step 31) — Ayma asks each
/// question aloud and her `set_profile_field` tool autofills the control via a
/// live `users/{uid}/profile` listener; the user edits before confirming.
/// Location can also be auto-detected (Step 35). On finish it writes the
/// profile, kicks off the photo face-embedding (§2.5, Step 30), and routes on.
class PreboardingFlowScreen extends StatefulWidget {
  const PreboardingFlowScreen({
    super.key,
    this.profileService,
    this.apiClient,
    this.locationService,
    this.voiceController,
  });

  static const path = '/preboarding';

  final ProfileService? profileService;
  final ApiClient? apiClient;
  final LocationService? locationService;
  final VoiceSessionController? voiceController;

  @override
  State<PreboardingFlowScreen> createState() => _PreboardingFlowScreenState();
}

class _PreboardingFlowScreenState extends State<PreboardingFlowScreen> {
  late final ProfileService _profiles =
      widget.profileService ?? ProfileService();
  late final ApiClient _api = widget.apiClient ?? ApiClient();
  late final LocationService _location =
      widget.locationService ?? const LocationService();
  late final TranscriptStore _transcript = TranscriptStore();
  late final VoiceSessionController _voice = widget.voiceController ??
      VoiceSessionController(transcriptStore: _transcript);
  StreamSubscription<ProfileData?>? _profileSub;
  bool _detectingLocation = false;
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
  void initState() {
    super.initState();
    try {
      _profileSub = _profiles.watchProfile().listen(
        _applyAutofill,
        onError: (_) {},
      );
    } catch (_) {
      // No Firestore (e.g. widget tests without an injected service).
    }
  }

  @override
  void dispose() {
    _profileSub?.cancel();
    _pageController.dispose();
    _nameController.dispose();
    _locationController.dispose();
    if (widget.voiceController == null) _voice.dispose();
    _transcript.dispose();
    super.dispose();
  }

  /// Fold Ayma's live profile writes into the form. Only fills a control that
  /// the user hasn't already put something in — their edits always win.
  void _applyAutofill(ProfileData? data) {
    if (data == null || !mounted) return;
    setState(() {
      if (_nameController.text.trim().isEmpty && data.name.isNotEmpty) {
        _nameController.text = data.name;
      }
      _birthdate ??= data.birthdate;
      if (_gender == null && data.gender.isNotEmpty && _genders.contains(data.gender)) {
        _gender = data.gender;
      }
      if (_interestedIn.isEmpty && data.interestedIn.isNotEmpty) {
        _interestedIn.addAll(
          data.interestedIn.where(_interestOptions.contains),
        );
      }
      if (_locationController.text.trim().isEmpty &&
          data.location.isNotEmpty) {
        _locationController.text = data.location;
      }
    });
  }

  Future<void> _toggleVoice() async {
    if (_voice.isActive) {
      await _voice.stop();
    } else {
      await _voice.start();
    }
    if (mounted) setState(() {});
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
        actions: [
          IconButton(
            tooltip: _voice.isActive ? 'Stop voice' : 'Answer by voice',
            onPressed: _toggleVoice,
            icon: Icon(_voice.isActive
                ? Icons.stop_circle_outlined
                : Icons.mic_none_rounded),
          ),
        ],
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
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _detectingLocation ? null : _useMyLocation,
            icon: const Icon(Icons.my_location, size: 18),
            label: Text(_detectingLocation
                ? 'Detecting…'
                : 'Use my current location'),
          ),
        ],
      );

  Future<void> _useMyLocation() async {
    setState(() => _detectingLocation = true);
    try {
      final city = await _location.detectCity();
      if (!mounted) return;
      if (city != null) {
        _locationController.text = city;
        setState(() {});
      } else {
        _snack("Couldn't get your location — type your city instead.");
      }
    } finally {
      if (mounted) setState(() => _detectingLocation = false);
    }
  }

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
