import 'package:flutter/foundation.dart';

/// The outcome of one Ayma-driven photo-carousel move.
///
/// [photoCount] is the real number of photos in the currently open
/// carousel (0 when no carousel is open), and [currentPhoto] is the
/// 1-based photo showing after the attempt (0 when there is none).
/// An out-of-range ask never moves the carousel: [ok] is false,
/// [reason] is `out_of_range`, and [photoCount] still carries the real
/// count so Ayma can honestly say "there are only 3 photos" instead of
/// claiming she showed a photo that does not exist.
class PhotoCarouselResult {
  const PhotoCarouselResult({
    required this.ok,
    required this.photoCount,
    required this.currentPhoto,
    this.requestedPhoto,
    this.reason = '',
  });

  final bool ok;

  /// How many photos the open carousel actually has.
  final int photoCount;

  /// The 1-based photo showing after the attempt (unchanged on failure).
  final int currentPhoto;

  /// The 1-based photo a `goto` asked for, when one was asked for.
  final int? requestedPhoto;

  /// Why a move did not happen: `no_carousel`, `out_of_range`,
  /// `at_first`, `at_last` or `unknown_op`. Empty on success.
  final String reason;

  /// The one line Ayma can relay about this move.
  String get resultText {
    if (ok) return 'Showing photo $currentPhoto of $photoCount.';
    switch (reason) {
      case 'out_of_range':
        return photoCount == 1
            ? 'There is only 1 photo on this profile.'
            : 'There are only $photoCount photos on this profile.';
      case 'at_last':
        return 'That is the last photo — there are $photoCount in total.';
      case 'at_first':
        return 'That is the first photo — there are $photoCount in total.';
      case 'no_carousel':
        return 'No profile photo carousel is open right now.';
      default:
        return 'That photo move is not available.';
    }
  }
}

/// The live hooks of one mounted photo carousel (today exactly one:
/// `ProfilePhotoHeader`, the header every profile screen renders through,
/// so the owner's own profile and anyone else's are both covered).
///
/// The widget owns its `PageController`; this handle is how the command
/// layer reaches it without owning it — the same shape as
/// `AppContext.instance.pendingExploreQuery` (a singleton slot a screen
/// consumes) and `ScreenCapture.instance` (a singleton the command layer
/// calls into). [animateToPage] takes a 0-based page and must animate
/// exactly like a user swipe / filmstrip tap.
class PhotoCarouselHandle {
  const PhotoCarouselHandle({
    required this.photoCount,
    required this.currentPage,
    required this.animateToPage,
  });

  /// How many photos the carousel currently shows.
  final int Function() photoCount;

  /// The 0-based page currently showing.
  final int Function() currentPage;

  /// Animate to the 0-based [page], like a user swipe.
  final void Function(int page) animateToPage;
}

/// App-wide slot for the one photo carousel currently on screen.
///
/// The carousel widget registers its [PhotoCarouselHandle] on mount and
/// unregisters on dispose; [AppCommandService] drives whichever handle is
/// registered, so a carousel command works for the currently open profile
/// (and for any other carousel that registers the same way) from both the
/// voice and the text-chat command lanes — both queue through the one
/// `AppCommandService`, never through a screen.
class PhotoCarouselRegistry {
  PhotoCarouselRegistry();

  static final PhotoCarouselRegistry instance = PhotoCarouselRegistry();

  PhotoCarouselHandle? _active;

  /// The handle of the carousel currently on screen, if any.
  PhotoCarouselHandle? get active => _active;

  bool get hasCarousel => _active != null;

  void register(PhotoCarouselHandle handle) {
    _active = handle;
  }

  void unregister(PhotoCarouselHandle handle) {
    if (identical(_active, handle)) _active = null;
  }

  /// Run one carousel command: [op] is `goto` (with the 1-based [index]
  /// the user spoke), `next` or `previous`. Bounds are checked against
  /// the live count before anything moves, so an out-of-range ask is a
  /// no-move result carrying the real count — never a crash, never a
  /// wild jump.
  PhotoCarouselResult perform({required String op, int? index}) {
    final handle = _active;
    if (handle == null) {
      return const PhotoCarouselResult(
        ok: false,
        photoCount: 0,
        currentPhoto: 0,
        reason: 'no_carousel',
      );
    }
    final count = handle.photoCount();
    if (count <= 0) {
      return const PhotoCarouselResult(
        ok: false,
        photoCount: 0,
        currentPhoto: 0,
        reason: 'no_carousel',
      );
    }
    final current0 = handle.currentPage().clamp(0, count - 1);
    final current1 = current0 + 1;
    switch (op) {
      case 'goto':
      case 'go_to':
      case 'show':
        final want = index ?? 0;
        if (want < 1 || want > count) {
          return PhotoCarouselResult(
            ok: false,
            photoCount: count,
            currentPhoto: current1,
            requestedPhoto: want,
            reason: 'out_of_range',
          );
        }
        handle.animateToPage(want - 1);
        return PhotoCarouselResult(
          ok: true,
          photoCount: count,
          currentPhoto: want,
          requestedPhoto: want,
        );
      case 'last':
        handle.animateToPage(count - 1);
        return PhotoCarouselResult(
          ok: true,
          photoCount: count,
          currentPhoto: count,
          requestedPhoto: count,
        );
      case 'next':
        if (current0 >= count - 1) {
          return PhotoCarouselResult(
            ok: false,
            photoCount: count,
            currentPhoto: current1,
            reason: 'at_last',
          );
        }
        handle.animateToPage(current0 + 1);
        return PhotoCarouselResult(
          ok: true,
          photoCount: count,
          currentPhoto: current1 + 1,
        );
      case 'previous':
      case 'prev':
        if (current0 <= 0) {
          return PhotoCarouselResult(
            ok: false,
            photoCount: count,
            currentPhoto: current1,
            reason: 'at_first',
          );
        }
        handle.animateToPage(current0 - 1);
        return PhotoCarouselResult(
          ok: true,
          photoCount: count,
          currentPhoto: current1 - 1,
        );
      default:
        return PhotoCarouselResult(
          ok: false,
          photoCount: count,
          currentPhoto: current1,
          reason: 'unknown_op',
        );
    }
  }

  /// Test-only: drop any registered handle.
  @visibleForTesting
  void clear() {
    _active = null;
  }
}
