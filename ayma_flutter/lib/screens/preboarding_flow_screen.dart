import 'dart:async';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../services/api_client.dart';
import '../services/location_service.dart';
import '../services/profile_service.dart';
import '../theme.dart';
import '../widgets/phone_number_field.dart';

/// Preboarding (§4.2). Six fields in fixed order: name, birthdate, gender,
/// interested_in, location, profile_photo — every one a typed/tapped form
/// control. A live `users/{uid}/profile` listener autofills a control if
/// something set it elsewhere; the user edits before confirming. Location can
/// also be auto-detected (Step 35). On finish it writes the profile, kicks off
/// the photo face-embedding (§2.5, Step 30), and routes on. (Ayma's voice does
/// not run here — the greeting lives on the sign-in screen only.)
class PreboardingFlowScreen extends StatefulWidget {
  const PreboardingFlowScreen({
    super.key,
    this.profileService,
    this.apiClient,
    this.locationService,
  });

  static const path = '/preboarding';

  final ProfileService? profileService;
  final ApiClient? apiClient;
  final LocationService? locationService;

  @override
  State<PreboardingFlowScreen> createState() => _PreboardingFlowScreenState();
}

class _PreboardingFlowScreenState extends State<PreboardingFlowScreen> {
  late final ProfileService _profiles =
      widget.profileService ?? ProfileService();
  late final ApiClient _api = widget.apiClient ?? ApiClient();
  late final LocationService _location =
      widget.locationService ?? const LocationService();
  StreamSubscription<ProfileData?>? _profileSub;
  bool _detectingLocation = false;
  final _pageController = PageController();
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _phoneFieldKey = GlobalKey<PhoneNumberFieldState>();
  final _locationController = TextEditingController();
  final _dobController = TextEditingController();

  /// The number the user verified at sign-in (if they used phone auth) — the
  /// phone field pre-splits it so they don't re-type it.
  String _authPhone = '';

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
    // Prefill from the credential they just signed in with — don't make them
    // type their name or number twice.
    try {
      final user = FirebaseAuth.instance.currentUser;
      _authPhone = user?.phoneNumber ?? '';
      final display = (user?.displayName ?? '').trim();
      if (display.isNotEmpty) {
        final parts = display.split(RegExp(r'\s+'));
        _firstNameController.text = parts.first;
        if (parts.length > 1) _lastNameController.text = parts.sublist(1).join(' ');
      }
    } catch (_) {/* no Firebase in some tests */}
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
    _firstNameController.dispose();
    _lastNameController.dispose();
    _phoneController.dispose();
    _locationController.dispose();
    _dobController.dispose();
    super.dispose();
  }

  /// Fold Ayma's live profile writes into the form. Only fills a control that
  /// the user hasn't already put something in — their edits always win.
  void _applyAutofill(ProfileData? data) {
    if (data == null || !mounted) return;
    setState(() {
      if (_firstNameController.text.trim().isEmpty &&
          data.firstName.isNotEmpty) {
        _firstNameController.text = data.firstName;
      }
      if (_lastNameController.text.trim().isEmpty && data.lastName.isNotEmpty) {
        _lastNameController.text = data.lastName;
      }
      if (_phoneController.text.trim().isEmpty && data.phone.isNotEmpty) {
        _phoneController.text = data.phone;
      }
      if (_birthdate == null && data.birthdate != null) {
        _birthdate = data.birthdate;
        _dobController.text = _formatDob(data.birthdate!);
      }
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

  bool get _canAdvance {
    switch (_step) {
      case 0:
        return _firstNameController.text.trim().isNotEmpty &&
            _lastNameController.text.trim().isNotEmpty;
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
      initialEntryMode: DatePickerEntryMode.calendarOnly,
      initialDate: _birthdate ?? DateTime(now.year - 25, now.month, now.day),
      firstDate: DateTime(now.year - 100),
      lastDate: now,
    );
    if (picked != null) {
      setState(() {
        _birthdate = picked;
        _dobController.text = _formatDob(picked);
      });
    }
  }

  static const _months = [
    'january', 'february', 'march', 'april', 'may', 'june', 'july',
    'august', 'september', 'october', 'november', 'december'
  ];

  static String _formatDob(DateTime d) =>
      '${d.day} ${_months[d.month - 1][0].toUpperCase()}'
      '${_months[d.month - 1].substring(1)} ${d.year}';

  /// Lenient birthdate parser. Accepts `ddmmyyyy`, `dd/mm/yyyy`, `dd-mm-yyyy`,
  /// `dd.mm.yyyy`, `yyyy-mm-dd`, `d/m/yy`, and `6 Mar 1993` / `March 6 1993`.
  /// All-numeric input is read **day-first** unless that can't be a valid date.
  static DateTime? _parseDob(String raw) {
    final s = raw.trim().toLowerCase();
    if (s.isEmpty) return null;

    // Month-name forms: "6 mar 1993" / "march 6, 1993" / "6 march 93"
    final nameMatch = RegExp(
      r'^(?:(\d{1,2})\s+([a-z]{3,})|([a-z]{3,})\s+(\d{1,2}))[,\s]+(\d{2,4})$',
    ).firstMatch(s);
    if (nameMatch != null) {
      final monName = (nameMatch.group(2) ?? nameMatch.group(3))!;
      final mi = _months.indexWhere((m) => m.startsWith(monName));
      final day = int.tryParse(nameMatch.group(1) ?? nameMatch.group(4) ?? '');
      final year = _expandYear(int.tryParse(nameMatch.group(5)!));
      if (mi >= 0 && day != null && year != null) {
        return _valid(year, mi + 1, day);
      }
      return null;
    }

    final digits = s.replaceAll(RegExp(r'[^0-9]'), '');
    List<int>? parts;
    final sep = RegExp(r'^(\d{1,4})[/\-. ](\d{1,2})[/\-. ](\d{1,4})$').firstMatch(s);
    if (sep != null) {
      parts = [
        int.parse(sep.group(1)!),
        int.parse(sep.group(2)!),
        int.parse(sep.group(3)!),
      ];
    } else if (digits.length == 8) {
      parts = [
        int.parse(digits.substring(0, 2)),
        int.parse(digits.substring(2, 4)),
        int.parse(digits.substring(4, 8)),
      ];
    } else if (digits.length == 6) {
      parts = [
        int.parse(digits.substring(0, 2)),
        int.parse(digits.substring(2, 4)),
        int.parse(digits.substring(4, 6)),
      ];
    }
    if (parts == null) return null;

    // yyyy-mm-dd when the first group is a 4-digit year.
    if (parts[0] > 31) {
      return _valid(_expandYear(parts[0]), parts[1], parts[2]);
    }
    final year = _expandYear(parts[2]);
    if (year == null) return null;
    // day-first, then fall back to month-first if day-first is impossible.
    return _valid(year, parts[1], parts[0]) ?? _valid(year, parts[0], parts[1]);
  }

  static int? _expandYear(int? y) {
    if (y == null) return null;
    if (y >= 1000) return y;
    final nowYy = DateTime.now().year % 100;
    return y <= nowYy ? 2000 + y : 1900 + y;
  }

  static DateTime? _valid(int? y, int m, int d) {
    if (y == null || m < 1 || m > 12 || d < 1 || d > 31) return null;
    final dt = DateTime(y, m, d);
    if (dt.year != y || dt.month != m || dt.day != d) return null; // overflow
    if (dt.isAfter(DateTime.now())) return null;
    return dt;
  }

  void _onDobChanged(String text) {
    final parsed = _parseDob(text);
    if (parsed != _birthdate) setState(() => _birthdate = parsed);
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
        name: _firstNameController.text,
        firstName: _firstNameController.text,
        lastName: _lastNameController.text,
        phone: _phoneFieldKey.currentState?.isPlausible == true
            ? _phoneFieldKey.currentState!.e164
            : '',
        birthdate: _birthdate!,
        gender: _gender!,
        interestedIn: _interestedIn.toList(),
        location: _locationController.text,
        photoStoragePath: storagePath,
      );
      // Photo pipeline + grid (§8.5, §8.3) — best-effort, must not block
      // finishing onboarding.
      unawaited(() async {
        try {
          final media =
              await _api.registerMedia(storagePath, context: 'profile');
          if (media.published && media.mediaId.isNotEmpty) {
            await _api.addPhoto(media.mediaId);
          }
        } catch (_) {/* best-effort */}
      }());
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

  Widget _nameStep() => ListView(
        shrinkWrap: true,
        children: [
          const Text('Your name — Ayma calls you by your first name, and uses '
              'your full name to look you up online so you don’t have to '
              'repeat yourself.'),
          const SizedBox(height: 16),
          TextField(
            controller: _firstNameController,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'First name'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _lastNameController,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Last name'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          PhoneNumberField(
            key: _phoneFieldKey,
            controller: _phoneController,
            initialE164: _authPhone,
            label: 'Phone (optional)',
          ),
        ],
      );

  Widget _birthdateStep() {
    final ac = context.ac;
    final typed = _dobController.text.trim().isNotEmpty;
    final parsed = _birthdate;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Your date of birth (you must be 18+).'),
        const SizedBox(height: 16),
        TextField(
          controller: _dobController,
          onChanged: _onDobChanged,
          keyboardType: TextInputType.datetime,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(
            labelText: 'Date of birth',
            hintText: 'e.g. 03/05/1993 · 03051993 · 1993-05-03 · 3 May 1993',
          ),
        ),
        const SizedBox(height: 8),
        if (parsed != null)
          Text(
            _isAdult(parsed)
                ? '→ ${_formatDob(parsed)}'
                : 'You must be at least 18.',
            style: AymaType.sans(
              size: 13,
              color: _isAdult(parsed) ? ac.fgMute : AymaColors.error,
            ),
          )
        else if (typed)
          Text("Couldn't read that date — try 03/05/1993 or 1993-05-03.",
              style: AymaType.sans(size: 13, color: ac.fgMute)),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _pickBirthdate,
            icon: const Icon(Icons.calendar_today_outlined, size: 16),
            label: const Text('Pick from calendar'),
          ),
        ),
      ],
    );
  }

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
