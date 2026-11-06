import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/age_gate.dart';
import '../services/api_client.dart';
import '../services/profile_service.dart';
import '../theme.dart';
import '../widgets/ayma_back_button.dart';
import '../widgets/ayma_toast.dart';
import '../widgets/ayma_wing_loader.dart';
import '../widgets/overflow_guards.dart';
import '../widgets/partner_preferences_fields.dart';

/// Post-onboarding editor for the structured profile fields (§4.5, §4.6 step 7).
///
/// Same six fields as preboarding minus the photo (photo management is Step 60).
/// Writes only the structured `users/{uid}/profile/main` doc — never the wiki.
///
/// Live updates (founder, 2026-11-06): after the initial load this screen
/// subscribes to the same profile doc, so a change Ayma makes while the
/// screen is open — partner age range, distance, gender, interested-in, or
/// any other structured field, all written to that doc by her tools
/// (`save_partner_preferences`, `set_profile_field`) — shows on the visible
/// controls in the same moment, with no navigate-away-and-back. A field the
/// user has edited locally since the last load/save keeps the user's value
/// (their unsaved edit wins, the same rule preboarding's autofill and the
/// Models screen's live update follow); untouched fields track the doc.
class ProfileSettingsScreen extends StatefulWidget {
  const ProfileSettingsScreen(
      {super.key, this.profileService, this.apiClient});

  static const path = '/settings/profile';

  final ProfileService? profileService;
  final ApiClient? apiClient;

  @override
  State<ProfileSettingsScreen> createState() => _ProfileSettingsScreenState();
}

class _ProfileSettingsScreenState extends State<ProfileSettingsScreen> {
  late final ProfileService _profiles =
      widget.profileService ?? ProfileService();
  late final ApiClient _api = widget.apiClient ?? ApiClient();
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _locationController = TextEditingController();

  static const _genders = ['Woman', 'Man', 'Non-binary', 'Other'];
  static const _interestOptions = ['Women', 'Men', 'Everyone'];

  bool _loading = true;
  bool _saving = false;
  String? _error;
  DateTime? _birthdate;
  String? _gender;
  final Set<String> _interestedIn = {};
  RangeValues _ageRange =
      const RangeValues(partnerAgeFloor, partnerAgeCeiling);
  RangeValues? _savedAgeRange;
  String _distance = defaultDistancePref;
  String? _savedDistance;

  /// Live profile-doc subscription (see the class doc) and the per-field
  /// "user edited this locally" flags that gate it.
  StreamSubscription<ProfileData?>? _profileSub;
  bool _dirtyFirstName = false;
  bool _dirtyLastName = false;
  bool _dirtyPhone = false;
  bool _dirtyLocation = false;
  bool _dirtyBirthdate = false;
  bool _dirtyGender = false;
  bool _dirtyInterestedIn = false;
  bool _dirtyAgeRange = false;
  bool _dirtyDistance = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _profileSub?.cancel();
    _firstNameController.dispose();
    _lastNameController.dispose();
    _phoneController.dispose();
    _locationController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final data = await _profiles.readProfile();
      if (!mounted) return;
      setState(() {
        _firstNameController.text = data?.firstName ?? '';
        _lastNameController.text = data?.lastName ?? '';
        // Fall back to the number they verified at sign-in if the profile
        // doc doesn't carry one yet (phone-auth users).
        final savedPhone = (data?.phone ?? '').trim();
        var authPhone = '';
        try {
          authPhone = FirebaseAuth.instance.currentUser?.phoneNumber ?? '';
        } catch (_) {/* no Firebase in tests */}
        _phoneController.text = savedPhone.isNotEmpty ? savedPhone : authPhone;
        _locationController.text = data?.location ?? '';
        _birthdate = data?.birthdate;
        _gender = (data?.gender.isNotEmpty ?? false) ? data!.gender : null;
        _interestedIn
          ..clear()
          ..addAll(data?.interestedIn ?? const []);
        final lo = data?.partnerAgeMin;
        final hi = data?.partnerAgeMax;
        if (lo != null && hi != null) {
          _ageRange = RangeValues(
            lo.clamp(partnerAgeFloor, partnerAgeCeiling).toDouble(),
            hi.clamp(partnerAgeFloor, partnerAgeCeiling).toDouble(),
          );
          _savedAgeRange = _ageRange;
        } else {
          _ageRange = defaultPartnerAgeRange(_birthdate);
        }
        final dist = data?.distancePreference ?? '';
        if (distancePrefOptions.containsKey(dist)) {
          _distance = dist;
          _savedDistance = dist;
        }
        _loading = false;
      });
      _startLiveUpdates();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load your profile ($e).';
        _loading = false;
      });
    }
  }

  /// Subscribe to the profile doc the initial load just read, so Ayma's
  /// writes to it land on the visible controls live (class doc). Started
  /// only after [_load] so the first snapshot's baseline is the loaded
  /// state, never a race against it. Best-effort: with no Firestore (e.g.
  /// a widget test that injects a read-only fake) the screen simply keeps
  /// its loaded values, exactly as before.
  void _startLiveUpdates() {
    if (_profileSub != null) return;
    try {
      _profileSub = _profiles.watchProfile().listen(
        _applyLive,
        onError: (_) {},
      );
    } catch (_) {
      // No live updates in this environment; the loaded form still works.
    }
  }

  /// Fold one live profile-doc snapshot into the form. Only fields the
  /// user has not edited locally move — their unsaved edit always wins —
  /// and the partner-preference baselines ([_savedAgeRange]/[_savedDistance])
  /// move with the applied values, so a later Save does not write Ayma's
  /// change back as if it were the user's, nor miss that it is saved.
  void _applyLive(ProfileData? data) {
    if (data == null || !mounted || _loading || _saving) return;
    setState(() {
      if (!_dirtyFirstName && _firstNameController.text != data.firstName) {
        _firstNameController.text = data.firstName;
      }
      if (!_dirtyLastName && _lastNameController.text != data.lastName) {
        _lastNameController.text = data.lastName;
      }
      if (!_dirtyPhone &&
          data.phone.isNotEmpty &&
          _phoneController.text != data.phone) {
        _phoneController.text = data.phone;
      }
      if (!_dirtyLocation && _locationController.text != data.location) {
        _locationController.text = data.location;
      }
      if (!_dirtyBirthdate && data.birthdate != null) {
        _birthdate = data.birthdate;
      }
      if (!_dirtyGender &&
          data.gender.isNotEmpty &&
          _genders.contains(data.gender)) {
        _gender = data.gender;
      }
      if (!_dirtyInterestedIn) {
        _interestedIn
          ..clear()
          ..addAll(data.interestedIn);
      }
      final lo = data.partnerAgeMin;
      final hi = data.partnerAgeMax;
      if (!_dirtyAgeRange && lo != null && hi != null) {
        _ageRange = RangeValues(
          lo.clamp(partnerAgeFloor, partnerAgeCeiling).toDouble(),
          hi.clamp(partnerAgeFloor, partnerAgeCeiling).toDouble(),
        );
        _savedAgeRange = _ageRange;
      }
      final dist = data.distancePreference;
      if (!_dirtyDistance && distancePrefOptions.containsKey(dist)) {
        _distance = dist;
        _savedDistance = dist;
      }
    });
  }

  bool get _canSave =>
      !_saving &&
      _firstNameController.text.trim().isNotEmpty &&
      _locationController.text.trim().isNotEmpty &&
      _gender != null &&
      _interestedIn.isNotEmpty &&
      _birthdate != null &&
      AgeGate.isAdult(_birthdate!);

  Future<void> _pickBirthdate() async {
    final now = DateTime.now();
    final latest = AgeGate.latestAdultBirthdate(now: now);
    final current = _birthdate;
    final picked = await showDatePicker(
      context: context,
      initialDate: current != null && !current.isAfter(latest)
          ? current
          : DateTime(now.year - 25, now.month, now.day),
      firstDate: DateTime(now.year - 100),
      lastDate: latest,
    );
    if (picked != null) {
      setState(() {
        _birthdate = picked;
        _dirtyBirthdate = true;
      });
    }
  }

  Future<void> _save() async {
    if (!_canSave) return;
    setState(() => _saving = true);
    try {
      await _profiles.updateStructuredFields(
        // `name` is the display name — keep it in sync with the first name
        // rather than asking for it as its own field.
        name: _firstNameController.text,
        firstName: _firstNameController.text,
        lastName: _lastNameController.text,
        phone: _phoneController.text,
        birthdate: _birthdate,
        gender: _gender,
        interestedIn: _interestedIn.toList(),
        location: _locationController.text,
      );
      final saveAge = _savedAgeRange != _ageRange;
      final saveDistance = _savedDistance != _distance;
      if (saveAge || saveDistance) {
        await _api.profilePreferencesSave(
          partnerAgeMin: saveAge ? _ageRange.start.round() : null,
          partnerAgeMax: saveAge ? _ageRange.end.round() : null,
          distancePref: saveDistance ? _distance : null,
        );
        _savedAgeRange = _ageRange;
        _savedDistance = _distance;
      }
      // The local edits are now the saved baseline: live doc updates apply
      // to every field again from here.
      _dirtyFirstName = false;
      _dirtyLastName = false;
      _dirtyPhone = false;
      _dirtyLocation = false;
      _dirtyBirthdate = false;
      _dirtyGender = false;
      _dirtyInterestedIn = false;
      _dirtyAgeRange = false;
      _dirtyDistance = false;
      if (!mounted) return;
      AymaToast.show(context, 'Profile saved', kind: AymaToastKind.success);
    } catch (e) {
      if (!mounted) return;
      // The form keeps every field, so Retry saves exactly the original input.
      AymaToast.show(context, 'Save failed ($e)',
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
        leading: const AymaBackButton(),
        title: const Text('Edit profile')),
      body: _loading
          // The profile/main read still in flight.
          ? const Center(
              child: AymaWingLoader(lines: AymaLoaderLines.profile),
            )
          : _error != null
              ? CenteredScroll(
                  padding: const EdgeInsets.all(24),
                  child: Text(_error!,
                      style: AymaType.sans(size: 14, color: AymaColors.error)),
                )
              : ListView(
                  // iOS has no keyboard-dismiss key — dragging the form away
                  // is the native escape hatch.
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                  children: [
                    _label('First name', ac),
                    TextField(
                      controller: _firstNameController,
                      textCapitalization: TextCapitalization.words,
                      onChanged: (_) => setState(() => _dirtyFirstName = true),
                      decoration:
                          const InputDecoration(hintText: 'Given name'),
                    ),
                    const SizedBox(height: 20),
                    _label('Last name', ac),
                    TextField(
                      controller: _lastNameController,
                      textCapitalization: TextCapitalization.words,
                      onChanged: (_) => setState(() => _dirtyLastName = true),
                      decoration:
                          const InputDecoration(hintText: 'Family name'),
                    ),
                    const SizedBox(height: 20),
                    _label('Phone', ac),
                    TextField(
                      controller: _phoneController,
                      keyboardType: TextInputType.phone,
                      onChanged: (_) => setState(() => _dirtyPhone = true),
                      decoration: const InputDecoration(
                          hintText: '+1 555 123 4567'),
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
                            onSelected: (_) => setState(() {
                              _gender = g;
                              _dirtyGender = true;
                            }),
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
                              _dirtyInterestedIn = true;
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
                      onChanged: (_) => setState(() => _dirtyLocation = true),
                      decoration:
                          const InputDecoration(hintText: 'City, country'),
                    ),
                    const SizedBox(height: 20),
                    PartnerPreferencesFields(
                      ages: _ageRange,
                      distance: _distance,
                      onAgesChanged: (v) => setState(() {
                            _ageRange = v;
                            _dirtyAgeRange = true;
                          }),
                      onDistanceChanged: (v) => setState(() {
                            _distance = v;
                            _dirtyDistance = true;
                          }),
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
