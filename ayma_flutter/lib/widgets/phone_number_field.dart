import 'package:country_picker/country_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// A phone-number input with a tappable country selector — no one has to guess
/// the `+country` format. [controller] holds only the national digits; [e164]
/// prepends the picked country's dial code.
class PhoneNumberField extends StatefulWidget {
  const PhoneNumberField({
    super.key,
    required this.controller,
    this.initialE164,
    this.label = 'Phone number',
    this.enabled = true,
    this.onSubmitted,
  });

  /// Holds the national number the user types (digits only).
  final TextEditingController controller;

  /// A full `+…` number to pre-split into country + national parts (e.g. the
  /// number the user already verified at sign-in).
  final String? initialE164;

  final String label;
  final bool enabled;
  final VoidCallback? onSubmitted;

  @override
  State<PhoneNumberField> createState() => PhoneNumberFieldState();
}

class PhoneNumberFieldState extends State<PhoneNumberField> {
  final _svc = CountryService();
  late Country _country;

  @override
  void initState() {
    super.initState();
    _country = _svc.findByCode(
          WidgetsBinding.instance.platformDispatcher.locale.countryCode,
        ) ??
        _svc.findByCode('US')!;

    final e = widget.initialE164?.trim() ?? '';
    if (e.startsWith('+') && widget.controller.text.trim().isEmpty) {
      final digits = e.substring(1);
      Country? best;
      for (final c in _svc.getAll()) {
        if (digits.startsWith(c.phoneCode) &&
            (best == null || c.phoneCode.length > best.phoneCode.length)) {
          best = c;
        }
      }
      if (best != null) {
        _country = best;
        widget.controller.text = digits.substring(best.phoneCode.length);
      } else {
        widget.controller.text = digits;
      }
    }
  }

  /// `+<dial><national digits>` — pass this to Firebase.
  String get e164 =>
      '+${_country.phoneCode}${widget.controller.text.replaceAll(RegExp(r'\D'), '')}';

  /// Enough digits to be worth sending an SMS to.
  bool get isPlausible =>
      widget.controller.text.replaceAll(RegExp(r'\D'), '').length >= 6;

  void _pickCountry() {
    showCountryPicker(
      context: context,
      showPhoneCode: true,
      onSelect: (c) => setState(() => _country = c),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return TextField(
      controller: widget.controller,
      enabled: widget.enabled,
      keyboardType: TextInputType.phone,
      onSubmitted: (_) => widget.onSubmitted?.call(),
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(
        labelText: widget.label,
        prefixIcon: Padding(
          padding: const EdgeInsets.only(left: 4),
          child: TextButton(
            onPressed: widget.enabled ? _pickCountry : null,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${_country.flagEmoji} +${_country.phoneCode}',
                    style: AymaType.sans(size: 15, color: ac.fg)),
                Icon(Icons.arrow_drop_down, size: 18, color: ac.fgMute),
              ],
            ),
          ),
        ),
        prefixIconConstraints: const BoxConstraints(minWidth: 92),
      ),
    );
  }
}
