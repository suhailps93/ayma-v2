import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// App-root "tap outside a text field to put the keyboard away" behaviour
/// (founder issue, iPhone testers: iOS keyboards have no dismiss key, and
/// this app's Material text fields never dismiss on their own).
///
/// Installed once, from `MaterialApp.router`'s `builder`, wrapping the whole
/// Navigator — see `main.dart`.
///
/// ## Why this provably can't break existing taps
///
/// This is a [Listener], NOT a `GestureDetector`. A `Listener` merely
/// observes raw pointer events as they're routed along the hit-test path — it
/// never registers a gesture-arena competitor, so no button, link, `InkWell`,
/// scroll view, slider or text-selection gesture anywhere below it can lose
/// (or even be delayed in) the arena because of it. The wrapped subtree
/// receives exactly the events it would receive without this widget.
///
/// A root `GestureDetector(behavior: translucent, onTap: unfocus)` — the
/// commonly-suggested alternative — is rejected here for two reasons: its tap
/// recognizer *does* enter the arena (a class of interference this widget is
/// immune to by construction), and it plain doesn't work over scrollables
/// (the `Scrollable`'s drag recognizer, being deeper in the hit path, wins
/// the arena sweep for a clean tap, so taps on a transcript's empty space —
/// the single most important surface here — would never dismiss).
///
/// ## When it dismisses
///
/// On pointer *up*, when ALL of the following hold:
///  * an [EditableText] owned the focus when the pointer went down
///    (otherwise there's no keyboard to put away);
///  * the pointer didn't move beyond [kTouchSlop] (drags are scrolling —
///    scrollables that want drag-dismiss declare
///    `keyboardDismissBehavior: onDrag` themselves);
///  * the tap didn't land on any text region ([RenderEditable] in the
///    hit-test path — tapping any field's text must move the caret, never
///    flicker the keyboard);
///  * the tap didn't land within the focused field's own bounds (the
///    enclosing [TextField]/[CupertinoTextField] chrome — its padding and
///    decoration are part of the field, not "outside");
///  * the tap didn't land inside a [KeepKeyboardOnTap] region (the chat / DM
///    composers: mic, attach and send must be tappable repeatedly without
///    the keyboard bouncing);
///  * and — checked in a microtask, i.e. *after* this pointer's gesture
///    arena has resolved and any tap-target callbacks have run — the
///    primary focus is still the very node that was focused on pointer
///    down. If the tap moved focus itself (tapping straight into another
///    field), we do nothing, so switching fields never hides the keyboard.
class KeyboardDismissOnTap extends StatefulWidget {
  const KeyboardDismissOnTap({super.key, required this.child});

  final Widget child;

  @override
  State<KeyboardDismissOnTap> createState() => _KeyboardDismissOnTapState();
}

class _KeyboardDismissOnTapState extends State<KeyboardDismissOnTap> {
  Offset? _downPosition;
  FocusNode? _downFocus;

  void _onPointerDown(PointerDownEvent event) {
    _downPosition = event.position;
    _downFocus = FocusManager.instance.primaryFocus;
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _downPosition = null;
    _downFocus = null;
  }

  void _onPointerUp(PointerUpEvent event) {
    final down = _downPosition;
    final focus = _downFocus;
    _downPosition = null;
    _downFocus = null;
    if (down == null || focus == null) return;

    // Only act when the software keyboard is plausibly up: the focused node
    // must belong to an EditableText.
    final focusContext = focus.context;
    if (focusContext == null || !focusContext.mounted) return;
    if (focusContext.findAncestorWidgetOfExactType<EditableText>() == null) {
      return;
    }

    // A drag, not a tap.
    if ((event.position - down).distance > kTouchSlop) return;

    // Tap on any text region (this field or another): caret placement /
    // focus hand-off — leave it entirely alone.
    if (_hitsEditable(event.position)) return;

    // Tap within the focused field's own chrome (decorator padding, prefix
    // icons…): still "inside the field".
    if (_focusedFieldBounds(focusContext)?.contains(event.position) ?? false) {
      return;
    }

    // Tap inside an explicitly protected region (composers).
    if (KeepKeyboardOnTap.anyContains(event.position)) return;

    // Defer past this pointer's gesture-arena resolution (which happens
    // synchronously later in this same event dispatch): if the tap's real
    // target took the focus itself, respect that and do nothing.
    scheduleMicrotask(() {
      if (FocusManager.instance.primaryFocus == focus) focus.unfocus();
    });
  }

  /// Whether a hit test at [position] passes through any [RenderEditable].
  bool _hitsEditable(Offset position) {
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(
      result,
      position,
      View.of(context).viewId,
    );
    return result.path.any((entry) => entry.target is RenderEditable);
  }

  /// Global bounds of the field that owns [focusContext] — the nearest
  /// enclosing [TextField]/[TextFormField]/[CupertinoTextField] if there is
  /// one (so the whole decorated pill counts as "inside"), else the
  /// [EditableText] itself (bare-EditableText composers).
  Rect? _focusedFieldBounds(BuildContext focusContext) {
    Element? fieldElement;
    focusContext.visitAncestorElements((element) {
      final w = element.widget;
      if (w is EditableText && fieldElement == null) {
        fieldElement = element; // Fallback; keep walking for real chrome.
      }
      if (w is TextField || w is TextFormField || w is CupertinoTextField) {
        fieldElement = element;
        return false;
      }
      return true;
    });
    final render = fieldElement?.renderObject;
    if (render is! RenderBox || !render.attached || !render.hasSize) {
      return null;
    }
    return MatrixUtils.transformRect(
      render.getTransformTo(null),
      Offset.zero & render.size,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointerDown,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: widget.child,
    );
  }
}

/// Marks its subtree as a region where a tap must NOT dismiss the keyboard,
/// even though it isn't a text field — the chat and DM composer bars (mic /
/// attach / send sit right beside the input, and firing them repeatedly with
/// the keyboard up is core UX). Purely a registry entry read by
/// [KeyboardDismissOnTap]; it inserts nothing into the hit test or gesture
/// arena, so it cannot affect how its children receive taps.
class KeepKeyboardOnTap extends StatefulWidget {
  const KeepKeyboardOnTap({super.key, required this.child});

  final Widget child;

  /// Whether [position] (global) falls inside any mounted, laid-out
  /// [KeepKeyboardOnTap] region.
  static bool anyContains(Offset position) {
    for (final state in _KeepKeyboardOnTapState._live) {
      if (state._contains(position)) return true;
    }
    return false;
  }

  @override
  State<KeepKeyboardOnTap> createState() => _KeepKeyboardOnTapState();
}

class _KeepKeyboardOnTapState extends State<KeepKeyboardOnTap> {
  static final Set<_KeepKeyboardOnTapState> _live = {};

  @override
  void initState() {
    super.initState();
    _live.add(this);
  }

  @override
  void dispose() {
    _live.remove(this);
    super.dispose();
  }

  bool _contains(Offset position) {
    if (!mounted) return false;
    final render = context.findRenderObject();
    if (render is! RenderBox || !render.attached || !render.hasSize) {
      return false;
    }
    final rect = MatrixUtils.transformRect(
      render.getTransformTo(null),
      Offset.zero & render.size,
    );
    return rect.contains(position);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
