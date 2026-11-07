import 'dart:async';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../services/age_gate.dart';
import '../services/api_client.dart';
import '../services/location_service.dart';
import '../services/profile_service.dart';
import '../services/push_permission.dart';
import '../services/revenuecat_service.dart';
import '../widgets/ayma_toast.dart';
import '../widgets/ayma_wing_loader.dart';
import 'trial_paywall_screen.dart';
import 'underage_screen.dart';
import '../theme.dart';
import 'push_primer_dialog.dart';
import '../widgets/partner_preferences_fields.dart';
import '../widgets/phone_number_field.dart';

/// Preboarding (§4.2). One scrollable page collecting every field in a fixed
/// order: name, birthdate, gender, interested_in, location, verification
/// selfie, profile_photo(s) — matching the styling of the post-onboarding
/// Edit Profile screen (labeled fields, chip selectors, single Save button).
/// A live `users/{uid}/profile` listener autofills a control if something set
/// it elsewhere (e.g. Ayma's voice `set_profile_field` tool); the user edits
/// before saving. Location can also be auto-detected (Step 35). On save it
/// writes the profile, kicks off the photo face-embedding (§2.5, Step 30),
/// and routes on. (Ayma's voice does not run here — the greeting lives on the
/// sign-in screen only.)
class PreboardingFlowScreen extends StatefulWidget {
  const PreboardingFlowScreen({
    super.key,
    this.profileService,
    this.apiClient,
    this.locationService,
    this.pushPermission,
    this.revenueCat,
  });

  static const path = '/preboarding';

  final ProfileService? profileService;
  final ApiClient? apiClient;
  final LocationService? locationService;
  final PushPermission? pushPermission;
  final RevenueCatService? revenueCat;

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

  DateTime? _birthdate;

  /// The age step passed: an 18+ birthdate was confirmed. Nothing else on
  /// the page is shown (or savable) before this.
  bool _ageConfirmed = false;
  String? _gender;
  final Set<String> _interestedIn = {};
  RangeValues? _pickedAges;

  /// Partner age range Ayma set on the profile doc (via her questionnaire
  /// answers) while this screen is open — shown live until the user picks
  /// their own (founder, 2026-11-06: Ayma-driven changes update the
  /// visible UI in real time).
  RangeValues? _liveAges;
  String _distance = defaultDistancePref;
  bool _distancePicked = false;

  /// The user's pick, else Ayma's live-set range, else a default derived
  /// from their own age.
  RangeValues get _ages =>
      _pickedAges ?? _liveAges ?? defaultPartnerAgeRange(_birthdate);
  File? _verificationSelfie;
  final List<File> _photos = [];
  bool _saving = false;

  static const _maxPhotos = 6;

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
      if (_birthdate != null && AgeGate.isAdult(_birthdate!)) {
        _ageConfirmed = true;
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
      // Partner preferences: Ayma's questionnaire writes land on the same
      // doc this listener reads — show them on the slider/chips at once
      // unless the user has already picked their own.
      final lo = data.partnerAgeMin;
      final hi = data.partnerAgeMax;
      if (lo != null && hi != null) {
        _liveAges = RangeValues(
          lo.clamp(partnerAgeFloor, partnerAgeCeiling).toDouble(),
          hi.clamp(partnerAgeFloor, partnerAgeCeiling).toDouble(),
        );
      }
      if (!_distancePicked &&
          distancePrefOptions.containsKey(data.distancePreference)) {
        _distance = data.distancePreference;
      }
    });
  }

  bool get _canSave =>
      !_saving &&
      _firstNameController.text.trim().isNotEmpty &&
      _lastNameController.text.trim().isNotEmpty &&
      _ageConfirmed &&
      _birthdate != null &&
      AgeGate.isAdult(_birthdate!) &&
      _gender != null &&
      _interestedIn.isNotEmpty &&
      _locationController.text.trim().isNotEmpty &&
      _verificationSelfie != null &&
      _photos.isNotEmpty;

  /// Age step: an 18+ birthdate unlocks the form; anything under 18 is a
  /// hard stop (the server is told, and closes the account).
  Future<void> _confirmAge() async {
    final birthdate = _birthdate;
    if (birthdate == null) {
      _snack('Enter your date of birth to continue.',
          kind: AymaToastKind.warning);
      return;
    }
    if (!AgeGate.isAdult(birthdate)) {
      await _stopUnderage(birthdate);
      return;
    }
    setState(() => _ageConfirmed = true);
  }

  Future<void> _stopUnderage(DateTime birthdate) async {
    try {
      await _api.declareBirthdate(AgeGate.isoDate(birthdate));
    } catch (_) {/* the stop screen does not depend on the server call */}
    if (!mounted) return;
    context.go(UnderageScreen.path);
  }

  void _snack(String message,
      {AymaToastKind kind = AymaToastKind.info,
      AymaToastAction? action}) {
    if (!mounted) return;
    AymaToast.show(context, message, kind: kind, action: action);
  }

  Future<void> _pickBirthdate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialEntryMode: DatePickerEntryMode.calendarOnly,
      initialDate: _birthdate != null && AgeGate.isAdult(_birthdate!)
          ? _birthdate!
          : DateTime(now.year - 25, now.month, now.day),
      firstDate: DateTime(now.year - 100),
      lastDate: AgeGate.latestAdultBirthdate(now: now),
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

  /// Lenient birthdate parser. Accepts `mmddyyyy`, `mm/dd/yyyy`, `mm-dd-yyyy`,
  /// `mm.dd.yyyy`, `yyyy-mm-dd`, `m/d/yy`, and `6 Mar 1993` / `March 6 1993`.
  /// Numeric date-first input is read **month-first (US MM/DD)** — the launch
  /// audience's convention and the placeholder's own example — falling back to
  /// day-first only when month-first can't be a valid date.
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
    // Month-first (US MM/DD), then fall back to day-first if month-first is
    // impossible (e.g. a first group > 12 can only be a day).
    return _valid(year, parts[0], parts[1]) ?? _valid(year, parts[1], parts[0]);
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

  /// Front-camera-only capture for the verification selfie (§ face
  /// verification) — never the gallery, so the reference photo is always a
  /// fresh, live capture. `preferredCameraDevice: front` defaults the camera
  /// UI to the front lens; on some platforms the system camera screen still
  /// exposes a flip-to-rear button (a real gap — see this task's report).
  Future<void> _pickVerificationSelfie() async {
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.front,
        maxWidth: 1600,
        imageQuality: 88,
      );
      if (picked == null || !mounted) return;
      setState(() => _verificationSelfie = File(picked.path));
    } catch (_) {
      if (mounted) {
        _snack("Couldn't open the camera.",
            kind: AymaToastKind.error);
      }
    }
  }

  Future<void> _pickPhotos() async {
    final picked = await ImagePicker().pickMultiImage(
      maxWidth: 1600,
      imageQuality: 88,
    );
    if (picked.isEmpty) return;
    setState(() {
      for (final x in picked) {
        if (_photos.length >= _maxPhotos) break;
        _photos.add(File(x.path));
      }
    });
  }

  Future<void> _useMyLocation() async {
    setState(() => _detectingLocation = true);
    try {
      final city = await _location.detectCity();
      if (!mounted) return;
      if (city != null) {
        _locationController.text = city;
        setState(() {});
      } else {
        _snack("Couldn't get your location — type your city instead.",
            kind: AymaToastKind.error);
      }
    } finally {
      if (mounted) setState(() => _detectingLocation = false);
    }
  }

  Future<void> _save() async {
    final birthdate = _birthdate;
    if (birthdate != null && !AgeGate.isAdult(birthdate)) {
      await _stopUnderage(birthdate);
      return;
    }
    if (!_canSave) {
      _snack('Please fill in every field above, including a verification '
          'selfie and at least one photo.', kind: AymaToastKind.warning);
      return;
    }
    setState(() => _saving = true);
    try {
      final storagePaths = <String>[];
      for (final file in _photos) {
        storagePaths.add(await _profiles.uploadProfilePhoto(file));
      }
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
        photoStoragePath: storagePaths.first,
      );
      // Partner age range + distance: saved where matching and Ayma read
      // them. Pre-filled defaults, so a failure here must not block finishing
      // onboarding — Edit profile can set them again.
      try {
        await _api.profilePreferencesSave(
          partnerAgeMin: _ages.start.round(),
          partnerAgeMax: _ages.end.round(),
          distancePref: _distance,
        );
      } catch (_) {/* best-effort */}
      // Reliable post-onboarding trigger (§ web search about me — reliable
      // trigger): fires once, right as onboarding actually finishes, rather
      // than hoping a later `/bootstrap` call races in. Idempotent
      // server-side; best-effort, same reliability posture as the calls
      // below — must not block finishing onboarding.
      unawaited(() async {
        try {
          await _api.completeOnboarding();
        } catch (_) {/* best-effort */}
      }());
      // Photo pipeline + grid (§8.5, §8.3) — moderate/embed every photo in
      // the order picked (first becomes the primary), then add the whole set
      // to the grid in one batched call (§ appearance batching) instead of
      // looping single adds. Best-effort, must not block finishing onboarding.
      unawaited(() async {
        final mediaIds = <String>[];
        for (final path in storagePaths) {
          try {
            final media =
                await _api.registerMedia(path, context: 'profile');
            if (media.published && media.mediaId.isNotEmpty) {
              mediaIds.add(media.mediaId);
            }
          } catch (_) {/* best-effort */}
        }
        if (mediaIds.isEmpty) return;
        try {
          await _api.addPhotosBatch(mediaIds);
        } catch (_) {/* best-effort */}
      }());
      // Verification selfie (§ face verification): moderate -> embed ->
      // store as the account's reference, and seed the initial Appearance
      // read. Best-effort, same as the photo pipeline above — must not block
      // finishing onboarding.
      final selfie = _verificationSelfie;
      if (selfie != null) {
        unawaited(() async {
          try {
            final path = await _profiles.uploadVerificationSelfie(selfie);
            await _api.verifySelfie(path);
          } catch (_) {/* best-effort */}
        }());
      }
      if (!mounted) return;
      await showPushPrimer(context, permission: widget.pushPermission);
      if (!mounted) return;
      await showOnboardingPaywall(context, service: widget.revenueCat);
      if (!mounted) return;
      context.go('/');
    } catch (e) {
      // The form keeps every field, so Retry saves exactly the original input.
      _snack('Could not save your profile: $e',
          kind: AymaToastKind.error,
          action: AymaToastAction(label: 'Retry', onPressed: _save));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tell us about you'),
        automaticallyImplyLeading: false,
      ),
      body: AbsorbPointer(
        absorbing: _saving,
        child: Column(
          children: [
            Expanded(
              child: ListView(
                // iOS has no keyboard-dismiss key — dragging the form away
                // is the native escape hatch.
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                children: [
                  Text(
                    AgeGate.mustBeAdultMessage,
                    key: const Key('preboarding_age_title'),
                    style: AymaType.serif(size: 24, color: ac.fg),
                  ),
                  const SizedBox(height: 8),
                  _hint(
                    "Ayma is strictly 18+. We start with your date of birth, "
                    "and it can't be changed to anything under 18 later.",
                    ac,
                  ),
                  const SizedBox(height: 16),
                  _label('Date of birth', ac),
                  TextField(
                    key: const Key('preboarding_dob'),
                    controller: _dobController,
                    onChanged: _onDobChanged,
                    keyboardType: TextInputType.datetime,
                    textInputAction: TextInputAction.done,
                    decoration: const InputDecoration(
                      hintText:
                          'e.g. 03/05/1993 · 03051993 · 1993-03-05 · 5 Mar 1993',
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (_birthdate != null)
                    Text(
                      AgeGate.isAdult(_birthdate!)
                          ? '→ ${_formatDob(_birthdate!)}'
                          : AgeGate.mustBeAdultMessage,
                      style: AymaType.sans(
                        size: 13,
                        color: AgeGate.isAdult(_birthdate!)
                            ? ac.fgMute
                            : AymaColors.error,
                      ),
                    )
                  else if (_dobController.text.trim().isNotEmpty)
                    Text("Couldn't read that date — try 03/05/1993 or 1993-03-05.",
                        style: AymaType.sans(size: 13, color: ac.fgMute)),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _pickBirthdate,
                      icon: const Icon(Icons.calendar_today_outlined, size: 16),
                      label: const Text('Pick from calendar'),
                    ),
                  ),
                  if (!_ageConfirmed) ...[
                    const SizedBox(height: 12),
                    FilledButton(
                      key: const Key('preboarding_age_continue'),
                      onPressed: _confirmAge,
                      child: const Text('Continue'),
                    ),
                  ],
                  if (_ageConfirmed) ...[
                    const SizedBox(height: 24),
                    _hint(
                      "Ayma calls you by your first name, and uses your full "
                      "name to look you up online so you don't have to repeat "
                      'yourself.',
                      ac,
                    ),
                    const SizedBox(height: 12),
                    _label('First name', ac),
                    TextField(
                      key: const Key('preboarding_first_name'),
                      controller: _firstNameController,
                      textCapitalization: TextCapitalization.words,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(hintText: 'Given name'),
                    ),
                    const SizedBox(height: 20),
                    _label('Last name', ac),
                    TextField(
                      key: const Key('preboarding_last_name'),
                      controller: _lastNameController,
                      textCapitalization: TextCapitalization.words,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(hintText: 'Family name'),
                    ),
                    const SizedBox(height: 20),
                    PhoneNumberField(
                      key: _phoneFieldKey,
                      controller: _phoneController,
                      initialE164: _authPhone,
                      label: 'Phone (optional)',
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
                    const SizedBox(height: 20),
                    _label('Location', ac),
                    TextField(
                      key: const Key('preboarding_location'),
                      controller: _locationController,
                      textCapitalization: TextCapitalization.words,
                      onChanged: (_) => setState(() {}),
                      decoration:
                          const InputDecoration(hintText: 'e.g. Austin, TX'),
                    ),
                    const SizedBox(height: 8),
                    TextButton.icon(
                      onPressed: _detectingLocation ? null : _useMyLocation,
                      icon: const Icon(Icons.my_location, size: 18),
                      label: Text(_detectingLocation
                          ? 'Detecting…'
                          : 'Use my current location'),
                    ),
                    const SizedBox(height: 12),
                    PartnerPreferencesFields(
                      ages: _ages,
                      distance: _distance,
                      onAgesChanged: (v) => setState(() => _pickedAges = v),
                      onDistanceChanged: (v) => setState(() {
                            _distance = v;
                            _distancePicked = true;
                          }),
                    ),
                    const SizedBox(height: 12),
                    _label('Verification selfie', ac),
                    _hint(
                      "One quick selfie to verify it's really you — this is "
                      'never shown on your profile. It just helps Ayma confirm '
                      "you're a real person and make sure the photo reads she "
                      'gives you are actually about you.',
                      ac,
                    ),
                    const SizedBox(height: 12),
                    if (_verificationSelfie != null) ...[
                      Center(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: Image.file(_verificationSelfie!,
                              width: 160, height: 160, fit: BoxFit.cover),
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    OutlinedButton.icon(
                      onPressed: _pickVerificationSelfie,
                      icon: const Icon(Icons.camera_alt_outlined),
                      label: Text(_verificationSelfie == null
                          ? 'Take a selfie'
                          : 'Retake selfie'),
                    ),
                    const SizedBox(height: 20),
                    _label('Photos', ac),
                    _hint(
                      'Add a few photos — the first one is your main picture. '
                      'You can add up to $_maxPhotos.',
                      ac,
                    ),
                    const SizedBox(height: 12),
                    if (_photos.isNotEmpty) ...[
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (var i = 0; i < _photos.length; i++) _photoThumb(i),
                        ],
                      ),
                      const SizedBox(height: 12),
                    ],
                    OutlinedButton.icon(
                      onPressed: _photos.length >= _maxPhotos ? null : _pickPhotos,
                      icon: const Icon(Icons.photo_library_outlined),
                      label: Text(
                        _photos.isEmpty
                            ? 'Choose photos'
                            : _photos.length >= _maxPhotos
                                ? 'Maximum $_maxPhotos photos'
                                : 'Add more photos',
                      ),
                    ),
                  ],
                ],
              ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton(
                  onPressed: _saving ? null : _save,
                  // Photo uploads + preboarding save in flight — wings only.
                  child: _saving
                      ? const AymaWingLoader(size: 20, showLabel: false)
                      : const Text('Save'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _label(String text, AymaTokens ac) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text,
            style: AymaType.sans(size: 13, soft: true, color: ac.fgMute)),
      );

  Widget _hint(String text, AymaTokens ac) =>
      Text(text, style: AymaType.sans(size: 13, color: ac.fgMute));

  Widget _photoThumb(int i) {
    const size = 104.0;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.file(_photos[i], fit: BoxFit.cover),
          ),
          if (i == 0)
            Positioned(
              left: 4,
              bottom: 4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text('Main',
                    style: TextStyle(color: Colors.white, fontSize: 11)),
              ),
            ),
          Positioned(
            right: 0,
            top: 0,
            child: GestureDetector(
              onTap: () => setState(() => _photos.removeAt(i)),
              child: SizedBox(
                width: 44,
                height: 44,
                child: Center(
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6),
                      shape: BoxShape.circle,
                    ),
                    padding: const EdgeInsets.all(4),
                    child: const Icon(Icons.close, size: 16, color: Colors.white),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
