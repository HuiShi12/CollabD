import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../main.dart';
import '../../../Data_layer/repository/Attraction Repository/attraction.dart';
import '../../../Data_layer/repository/Progress Repository/progress.dart';
import '../../../Data_layer/repository/Puzzle Repository/puzzle.dart';
import '../../../Data_layer/repository/Visit Proof Repository/visit_proof.dart';
import '../../../Data_layer/service/Map Tiles Service/map_tiles.dart';
import '../../viewmodel/Mystery Place Puzzle Game ViewModel/mystery_place_puzzle_game_viewmodel.dart';

enum _SavedGameType { tripPath, puzzle }

/// Backs the "Continue Your Mystery" swipe-to-delete action with a real
/// Supabase delete, scoped to the signed-in user and to sessions still in
/// progress — a completed or already-deleted row is left untouched and
/// reported back as a failure rather than silently no-op'ing.
class _SavedGameDeleteRepository {
  Future<void> deleteUnfinishedGame(_SavedGameType type, String id) async {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null) {
      throw StateError('Please sign in again before deleting a game.');
    }
    final isTripPath = type == _SavedGameType.tripPath;
    final rows = await client
        .from(isTripPath ? 'trip_path_quests' : 'game_sessions')
        .delete()
        .eq('id', id)
        .eq('user_id', userId)
        .eq('status', isTripPath ? 'in_progress' : 'In Progress')
        .select('id');
    if (rows.isEmpty) {
      throw StateError(
        'The game could not be deleted. It may already be completed or unavailable.',
      );
    }
  }
}

Future<bool> _confirmSavedGameDeletion(
  BuildContext context, {
  required _SavedGameType type,
  required String id,
}) async {
  return await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _DeleteSavedGameDialog(type: type, id: id),
      ) ??
      false;
}

class _DeleteSavedGameDialog extends StatefulWidget {
  const _DeleteSavedGameDialog({required this.type, required this.id});
  final _SavedGameType type;
  final String id;

  @override
  State<_DeleteSavedGameDialog> createState() =>
      _DeleteSavedGameDialogState();
}

class _DeleteSavedGameDialogState extends State<_DeleteSavedGameDialog> {
  bool _busy = false;
  String? _error;

  Future<void> _delete() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _SavedGameDeleteRepository().deleteUnfinishedGame(
        widget.type,
        widget.id,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error =
            'Unable to delete this game. Check your connection and try '
            'again. Completed games cannot be deleted.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: const Text('Delete game?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This permanently deletes this saved game and its progress. '
              'You cannot continue it afterward.',
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
        actions: [
          // A plain actions list lets Flutter's OverflowBar stack these
          // vertically once combined width doesn't fit — an explicit Row
          // instead keeps Cancel and Delete side by side always.
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor:
                        Theme.of(context).colorScheme.surfaceContainerHighest,
                    foregroundColor:
                        Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  onPressed:
                      _busy ? null : () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                  ),
                  onPressed: _busy ? null : _delete,
                  child: Text(_busy ? 'Deleting…' : 'Delete'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class MysteryPlacePuzzleGameView extends StatefulWidget {
  final String touristId;
  final void Function(BuildContext)? onRewards;

  /// UC-03 → UC-05 entry source (FR03_9). Shown to the tourist when the game
  /// was started from a Proximity Game marker rather than the Puzzle button.
  final String? entrySourceNote;

  /// Deep-link entry from Profile / Game History's "Continue" action on one
  /// specific saved game — jumps straight into it instead of showing Intro
  /// or the "Continue Your Mystery" picker first.
  final String? initialSessionId;

  const MysteryPlacePuzzleGameView({
    super.key,
    required this.touristId,
    this.entrySourceNote,
    this.onRewards,
    this.initialSessionId,
  });

  @override
  State<MysteryPlacePuzzleGameView> createState() =>
      _MysteryPlacePuzzleGameViewState();
}

class _MysteryPlacePuzzleGameViewState
    extends State<MysteryPlacePuzzleGameView> {
  // Tracks which VisitProofResult the bottom sheet was last shown for, so a
  // rebuild while the sheet is still open doesn't try to show it again.
  VisitProofResult? _shownVerificationOutcome;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final vm = context.read<MysteryPlacePuzzleGameViewModel>();
      final initialSessionId = widget.initialSessionId;
      if (initialSessionId != null && initialSessionId.isNotEmpty) {
        vm.resumeSessionById(initialSessionId);
      } else if (vm.preselectedPlaceId != null) {
        // UC-03 FR03_9 — a Proximity Game marker already chose a specific
        // place, so Continue-Your-Mystery / Choose-a-Mystery are skipped
        // entirely (a claimed place never has a marker to tap in the first
        // place — see Claimed Places Repository — so there's no "resume
        // this same place" ambiguity here, only ever a fresh start). The
        // instructions still show first, same as every other entry path;
        // "Start Game" (proceedFromIntro) is what starts that place's
        // puzzle directly.
        vm.showIntroForPreselectedPlace();
      } else {
        vm.checkForSavedSessions();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<MysteryPlacePuzzleGameViewModel>(
      builder: (context, vm, child) {
        // vm.stage starts at `entryCheck` (a brief loading sheet) while
        // checkForSavedSessions() decides where to land: `resume` if an
        // unfinished mystery exists, otherwise `intro` — so the
        // instructions only show up front when there's nothing to resume.
        // Tapping "Start New Mystery" on `resume` sends it back to `intro`
        // before moving on to `options` once "Start Game" is tapped there.
        // All four render as a sheet over the transparent Map.
        // isCheckingSavedSessions is deliberately NOT part of `loading`: that
        // check runs quietly behind the entryCheck sheet instead of blocking
        // it via the (unrelated) isLoading spinner.
        // isLoading is reused by later stages too (e.g. saving puzzle
        // completion) — this must stay scoped to these sheet stages
        // specifically, or those unrelated moments would wrongly go
        // transparent too.
        final onSheetStage = vm.stage == MysteryPuzzleScreenStage.entryCheck ||
            vm.stage == MysteryPuzzleScreenStage.intro ||
            vm.stage == MysteryPuzzleScreenStage.resume ||
            vm.stage == MysteryPuzzleScreenStage.options;
        final loading = vm.isLoading;

        // Trip-Path-style result sheet — shows once per fresh verification
        // outcome, after the current frame so it isn't built mid-layout.
        final outcome = vm.verificationOutcomeForSheet;
        if (outcome != null && !identical(outcome, _shownVerificationOutcome)) {
          _shownVerificationOutcome = outcome;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _showVerificationResultSheet(outcome, vm);
          });
        } else if (outcome == null) {
          _shownVerificationOutcome = null;
        }

        // Deep-linked from Profile / Game History: show a plain spinner
        // while resumeSessionById() looks the session up, instead of
        // flashing Intro or the picker sheet first.
        if (widget.initialSessionId != null &&
            (vm.isCheckingSavedSessions || vm.isResumingSession)) {
          return const Scaffold(
            backgroundColor: Color(0xFF041428),
            body: Center(
              child: CircularProgressIndicator(color: Color(0xFF1FB1FF)),
            ),
          );
        }

        return Scaffold(
          // Transparent while still on the intro/choosing sheets: this route
          // is opaque:false, so the real Map screen shows straight through —
          // matches Trip Path's entry instead of covering the whole screen
          // with a separate page.
          backgroundColor:
              onSheetStage ? Colors.transparent : const Color(0xFF041428),
          body: SafeArea(
            child: loading
                ? (onSheetStage
                    ? const _OptionsLoadingSheet()
                    : const Center(
                        child: CircularProgressIndicator(
                          color: Color(0xFF1FB1FF),
                        ),
                      ))
                : _buildByStage(vm),
          ),
        );
      },
    );
  }

  Widget _buildByStage(MysteryPlacePuzzleGameViewModel vm) {
    switch (vm.stage) {
      case MysteryPuzzleScreenStage.entryCheck:
        return const _OptionsLoadingSheet(
          message: 'Checking your mysteries...',
        );

      case MysteryPuzzleScreenStage.intro:
        return _IntroScreen(
          onStart: () => vm.proceedFromIntro(widget.touristId),
        );

      case MysteryPuzzleScreenStage.resume:
        return _ResumeSavedGamesScreen(vm: vm, touristId: widget.touristId);

      case MysteryPuzzleScreenStage.options:
        return _OptionsScreen(
          vm: vm,
          touristId: widget.touristId,
          entrySourceNote: widget.entrySourceNote,
        );

      case MysteryPuzzleScreenStage.imagePreview:
        return _ImagePreviewScreen(vm: vm);

      case MysteryPuzzleScreenStage.puzzle:
        return _PuzzleScreen(vm: vm);

      case MysteryPuzzleScreenStage.navigate:
        return _NavigateScreen(vm: vm);

      // Reference + Your Photo live on one page (matches Trip Path Quest's
      // verification page) — reviewPhoto only changes what that page shows
      // (a captured-photo preview instead of the "Take Photo" card), not
      // which screen renders.
      case MysteryPuzzleScreenStage.verifyReference:
      case MysteryPuzzleScreenStage.reviewPhoto:
        return _VerifyReferenceScreen(vm: vm, touristId: widget.touristId);

      case MysteryPuzzleScreenStage.verified:
        return _VerifiedScreen(vm: vm, onRewards: widget.onRewards);

      case MysteryPuzzleScreenStage.error:
        return _ErrorScreen(vm: vm);
    }
  }

  // ============================================================
  // VERIFICATION RESULT SHEET
  //
  // Same rounded-top bottom-sheet card as Trip Path Quest's verification
  // page (trip_path_quest_verification.dart's _showVerificationResultSheet)
  // so both game modes present a photo-verification outcome the same way.
  // Puzzle's VisitProofResult is a plain isSuccess/message pair rather than
  // Trip Path's matched/retake/not-matched tri-state, so this only needs
  // two visual variants.
  // ============================================================

  void _showVerificationResultSheet(
    VisitProofResult result,
    MysteryPlacePuzzleGameViewModel vm,
  ) {
    final matched = result.isSuccess;
    // Middle tier between matched/rejected — same underlying engine as Trip
    // Path Quest's verification page (see visit_proof.dart), styled the same
    // amber way here instead of collapsing it into a hard "not verified".
    final retake = !matched && result.shouldRetake;

    final IconData resultIcon;
    final Color resultColor;
    final Color resultBackground;
    final String displayTitle;
    final String displayMessage;
    final String actionLabel;
    final IconData actionIcon;

    if (matched) {
      resultIcon = Icons.verified_rounded;
      resultColor = const Color(0xFF16A34A);
      resultBackground = const Color(0xFFF0FDF4);
      displayTitle = 'Visit Verified!';
      displayMessage = 'Your photo matches this landmark. Continue to claim '
          'your Digital Travel Stamp.';
      actionLabel = 'Continue';
      actionIcon = Icons.flag_rounded;
    } else if (retake) {
      resultIcon = Icons.camera_alt_rounded;
      resultColor = const Color(0xFFD97706);
      resultBackground = const Color(0xFFFFFBEB);
      displayTitle = 'Retake Photo';
      displayMessage = result.message;
      actionLabel = 'Retake Photo';
      actionIcon = Icons.camera_alt_rounded;
    } else {
      resultIcon = Icons.cancel_rounded;
      resultColor = const Color(0xFFDC2626);
      resultBackground = const Color(0xFFFEF2F2);
      displayTitle = 'Photo Not Verified';
      displayMessage = result.message;
      actionLabel = 'Try Another Photo';
      actionIcon = Icons.refresh_rounded;
    }

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return SafeArea(
          top: false,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0xFFCBD5E1),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                const SizedBox(height: 22),
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: resultBackground,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(resultIcon, color: resultColor, size: 38),
                ),
                const SizedBox(height: 16),
                Text(
                  displayTitle,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: resultColor,
                    fontSize: 21,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    displayMessage,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xFF64748B),
                      fontSize: 13,
                      height: 1.45,
                    ),
                  ),
                ),
                const SizedBox(height: 22),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: FilledButton.icon(
                    onPressed: () => Navigator.of(sheetContext).pop(),
                    style: FilledButton.styleFrom(
                      backgroundColor: matched
                          ? const Color(0xFF16A34A)
                          : const Color(0xFF0284C7),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(15),
                      ),
                    ),
                    icon: Icon(actionIcon, size: 20),
                    label: Text(
                      actionLabel,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ).whenComplete(vm.acknowledgeVerificationOutcome);
  }
}

class _AppTopBar extends StatelessWidget {
  final String title;

  /// Labelled left action (e.g. "✕ Exit", "Retake"). Ignored when [onBack] is
  /// given.
  final String? leftText;
  final VoidCallback? onLeftTap;

  /// When set, the left slot shows the shared [AppBackButton] instead of a
  /// labelled pill, so "go back" looks the same here as everywhere else.
  final VoidCallback? onBack;

  /// When [onBack] is also set, shows the Navigate screen's round dark
  /// floating icon button ([_NavRoundIconButton]) instead of the plain
  /// [AppBackButton] — for screens that want that exact look.
  final bool roundBackButton;

  final bool lightBackground;

  const _AppTopBar({
    required this.title,
    this.leftText,
    this.onLeftTap,
    this.onBack,
    this.roundBackButton = false,
    this.lightBackground = false,
  });

  @override
  Widget build(BuildContext context) {
    // On the light-background screens the bar follows the app theme; the
    // permanently-navy game screens keep white text.
    final titleColor =
        lightBackground ? context.colors.onSurface : Colors.white;
    final actionColor =
        lightBackground ? context.colors.primary : Colors.white;

    Widget leading;
    if (onBack != null && roundBackButton) {
      leading = Align(
        alignment: Alignment.centerLeft,
        child: _NavRoundIconButton(
          icon: Icons.arrow_back_ios_new_rounded,
          onTap: onBack!,
        ),
      );
    } else if (onBack != null) {
      leading = Align(
        alignment: Alignment.centerLeft,
        child: AppBackButton(onTap: onBack, color: actionColor),
      );
    } else if (leftText != null) {
      leading = Align(
        alignment: Alignment.centerLeft,
        child: GestureDetector(
          onTap: onLeftTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: lightBackground
                ? null
                : BoxDecoration(
                    color: const Color(0xFF1E2D46),
                    borderRadius: BorderRadius.circular(12),
                  ),
            child: Text(
              leftText!,
              style: TextStyle(
                color: actionColor,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      );
    } else {
      leading = const SizedBox();
    }

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          SizedBox(width: 84, child: leading),
          Expanded(
            child: Center(
              child: Text(
                title,
                style: TextStyle(
                  color: titleColor,
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ),
          const SizedBox(width: 84),
        ],
      ),
    );
  }
}

/// Pill drag-handle look shared by [_OptionsLoadingSheet] and [_OptionsScreen]
/// so the loading beat and the real sheet read as the same rising card.
class _SheetPill extends StatelessWidget {
  const _SheetPill();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 5,
      margin: const EdgeInsets.only(top: 12, bottom: 8),
      decoration: BoxDecoration(
        color: context.colors.outlineVariant,
        borderRadius: BorderRadius.circular(3),
      ),
    );
  }
}

/// Drag handle for the Choose-a-Mystery sheet — swipe down to close instead
/// of a back button, matching Trip Path's pre-quest sheets. Reports the live
/// drag to [_PuzzleDismissibleSheet], which is what actually moves the sheet.
class _PuzzleSheetDragHandle extends StatelessWidget {
  const _PuzzleSheetDragHandle({
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  final ValueChanged<double> onDragUpdate;
  final ValueChanged<double> onDragEnd;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: (details) => onDragUpdate(details.delta.dy),
      onVerticalDragEnd: (details) => onDragEnd(details.primaryVelocity ?? 0),
      child: Container(
        // Generous padding around the visible pill so the swipe-down
        // gesture is easy to grab without needing pixel-perfect accuracy.
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 40),
        margin: const EdgeInsets.only(top: 12, bottom: 4),
        child: Container(
          width: 40,
          height: 5,
          decoration: BoxDecoration(
            color: context.colors.outlineVariant,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
      ),
    );
  }
}

/// Makes the swipe-down on [_PuzzleSheetDragHandle] actually move the sheet:
/// it tracks the finger 1:1 while dragging, then either eases back to 0 or —
/// past a distance/velocity threshold — slides the rest of the way
/// off-screen and pops the route once that animation finishes.
class _PuzzleDismissibleSheet extends StatefulWidget {
  const _PuzzleDismissibleSheet({required this.builder});

  /// Builds the sheet, wiring [_PuzzleSheetDragHandle]'s callbacks to the
  /// two arguments passed here.
  final Widget Function(
    BuildContext context,
    ValueChanged<double> onDragUpdate,
    ValueChanged<double> onDragEnd,
  ) builder;

  @override
  State<_PuzzleDismissibleSheet> createState() =>
      _PuzzleDismissibleSheetState();
}

class _PuzzleDismissibleSheetState extends State<_PuzzleDismissibleSheet>
    with SingleTickerProviderStateMixin {
  static const _dismissDistance = 130.0;
  static const _dismissVelocity = 700.0;

  late final AnimationController _controller = AnimationController(
    vsync: this,
  )..addListener(() => setState(() {}));

  Animation<double>? _snapAnimation;
  double _dragExtent = 0;

  double get _offset => _snapAnimation?.value ?? _dragExtent;

  void _onDragUpdate(double dy) {
    _snapAnimation = null;
    setState(() {
      _dragExtent = (_dragExtent + dy).clamp(0.0, double.infinity);
    });
  }

  void _onDragEnd(double velocity) {
    final dismiss =
        velocity > _dismissVelocity || _dragExtent > _dismissDistance;
    final target = dismiss ? MediaQuery.of(context).size.height : 0.0;

    _snapAnimation = Tween<double>(begin: _dragExtent, end: target).animate(
      CurvedAnimation(
        parent: _controller,
        curve: dismiss ? Curves.easeIn : Curves.easeOutCubic,
      ),
    );
    _controller
      ..duration = Duration(milliseconds: dismiss ? 200 : 220)
      ..forward(from: 0).whenComplete(() {
        if (!mounted) return;
        if (dismiss) {
          Navigator.of(context).maybePop();
        } else {
          setState(() {
            _dragExtent = 0;
            _snapAnimation = null;
          });
        }
      });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Transform.translate(
      offset: Offset(0, _offset),
      child: widget.builder(context, _onDragUpdate, _onDragEnd),
    );
  }
}

/// Backdrop behind a Puzzle sheet — tapping it dismisses the sheet the same
/// way dragging it all the way down does (back out to the Map screen this
/// route was pushed from). Lighter than a plain modal barrier so the Map
/// underneath still reads as "there", not just a flat black box.
class _PuzzleScrimBarrier extends StatelessWidget {
  const _PuzzleScrimBarrier();

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.of(context).maybePop(),
      child: Container(color: Colors.black.withValues(alpha: 0.4)),
    );
  }
}

/// Shown while loadNearbyPuzzleOptions() is fetching. Shaped like the actual
/// Choose-a-Mystery sheet (same pill, same rounded card) rather than a bare
/// spinner, so the slide-up-from-bottom route transition animates something
/// that already looks like the sheet — otherwise the real sheet would just
/// snap in once loading finished, with no animation of its own.
class _OptionsLoadingSheet extends StatelessWidget {
  final String message;

  const _OptionsLoadingSheet({
    this.message = 'Finding nearby mysteries...',
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Container(color: Colors.black.withValues(alpha: 0.45)),
        Align(
          alignment: Alignment.bottomCenter,
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: context.colors.surface,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(28),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const _SheetPill(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 40),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.4,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            context.colors.primary,
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        message,
                        style: context.text.bodyMedium?.copyWith(
                          color: context.colors.onSurface,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Shown before the nearby-places fetch starts — explains the
/// objective/rules/reward up front so a tourist isn't dropped straight into
/// "Choose a Mystery" with no context. Appears either right after entry (no
/// unfinished mystery to resume) or after tapping "Start New Mystery" on the
/// resume prompt. "Start Game" is what actually triggers
/// [MysteryPlacePuzzleGameViewModel.loadNearbyPuzzleOptions].
class _IntroScreen extends StatelessWidget {
  final VoidCallback onStart;

  const _IntroScreen({required this.onStart});

  @override
  Widget build(BuildContext context) {
    final maxSheetHeight = MediaQuery.of(context).size.height * 0.88;

    // Same sheet-over-transparent-Map presentation as _OptionsScreen, since
    // this stage renders right before it in the same route.
    return Stack(
      fit: StackFit.expand,
      children: [
        const _PuzzleScrimBarrier(),
        Align(
          alignment: Alignment.bottomCenter,
          child: _PuzzleDismissibleSheet(
            builder: (context, onDragUpdate, onDragEnd) => Container(
              width: double.infinity,
              constraints: BoxConstraints(maxHeight: maxSheetHeight),
              decoration: BoxDecoration(
                color: context.colors.surface,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(28),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _PuzzleSheetDragHandle(
                    onDragUpdate: onDragUpdate,
                    onDragEnd: onDragEnd,
                  ),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(22, 4, 22, 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 52,
                                height: 52,
                                decoration: BoxDecoration(
                                  color: context.colors.primary,
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: const Icon(
                                  Icons.extension_rounded,
                                  color: Colors.white,
                                  size: 28,
                                ),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Text(
                                  'Hidden Place Discovery',
                                  style: context.text.titleLarge?.copyWith(
                                    color: context.colors.onSurface,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 20),
                          _IntroInfoCard(
                            icon: Icons.track_changes_rounded,
                            iconColor: context.colors.error,
                            title: 'Objective',
                            description:
                                'Solve a visual puzzle to uncover a hidden '
                                'local attraction near you.',
                          ),
                          const SizedBox(height: 10),
                          _IntroInfoCard(
                            icon: Icons.assignment_rounded,
                            iconColor: context.appColors.warning,
                            title: 'How to Play',
                            description:
                                'Select a mystery puzzle card, piece '
                                'together the image, then navigate to the '
                                'real location to verify your visit.',
                          ),
                          const SizedBox(height: 10),
                          _IntroInfoCard(
                            icon: Icons.straighten_rounded,
                            iconColor: context.colors.primary,
                            title: 'Rules',
                            description:
                                'Maximum 3 hints allowed · Verify within '
                                '50 m · Photo submission required.',
                          ),
                          const SizedBox(height: 10),
                          _IntroInfoCard(
                            icon: Icons.emoji_events_rounded,
                            iconColor: context.colors.tertiary,
                            title: 'Reward',
                            description:
                                'Earn a unique Digital Travel Stamp for '
                                'each completed discovery.',
                          ),
                          const SizedBox(height: 22),
                          SizedBox(
                            width: double.infinity,
                            height: 52,
                            child: ElevatedButton(
                              onPressed: onStart,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: context.colors.primary,
                                foregroundColor: context.colors.onPrimary,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                elevation: 0,
                              ),
                              child: const Text(
                                'Start Game',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _IntroInfoCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String description;

  const _IntroInfoCard({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: iconColor, size: 21),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: context.text.bodyMedium?.copyWith(
                    color: context.colors.onSurface,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  description,
                  style: context.text.bodySmall?.copyWith(
                    color: context.colors.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// UC-05 — shown instead of [_IntroScreen] whenever the tourist has one or
/// more resumable puzzle sessions. Same sheet chrome as [_OptionsScreen],
/// since this stage renders right before it in the same route.
class _ResumeSavedGamesScreen extends StatefulWidget {
  final MysteryPlacePuzzleGameViewModel vm;
  final String touristId;

  const _ResumeSavedGamesScreen({required this.vm, required this.touristId});

  @override
  State<_ResumeSavedGamesScreen> createState() =>
      _ResumeSavedGamesScreenState();
}

class _ResumeSavedGamesScreenState extends State<_ResumeSavedGamesScreen> {
  // Only remove cards after Supabase confirms deletion.
  final Set<String> _deletedIds = {};

  @override
  Widget build(BuildContext context) {
    final vm = widget.vm;
    final savedSessions = vm.savedSessions;
    final visibleSessions = savedSessions
        .where((s) => !_deletedIds.contains(s.id))
        .toList();
    final maxSheetHeight = MediaQuery.of(context).size.height * 0.88;

    return Stack(
      fit: StackFit.expand,
      children: [
        const _PuzzleScrimBarrier(),
        Align(
          alignment: Alignment.bottomCenter,
          child: _PuzzleDismissibleSheet(
            builder: (context, onDragUpdate, onDragEnd) => Container(
              width: double.infinity,
              constraints: BoxConstraints(maxHeight: maxSheetHeight),
              decoration: BoxDecoration(
                color: context.colors.surface,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(28),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _PuzzleSheetDragHandle(
                    onDragUpdate: onDragUpdate,
                    onDragEnd: onDragEnd,
                  ),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(22, 4, 22, 16),
                      child: Column(
                        children: [
                          GestureDetector(
                            onTap: vm.startNewMysteryFromResume,
                            child: Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: context.colors.primaryContainer,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: context.colors.primary
                                      .withValues(alpha: 0.35),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.add_circle_rounded,
                                    color: context.colors.primary,
                                    size: 26,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Start New Mystery',
                                          style: context.text.bodyMedium
                                              ?.copyWith(
                                            color:
                                                context.colors.onPrimaryContainer,
                                            fontWeight: FontWeight.w800,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          'Your unfinished mysteries stay saved.',
                                          style: context.text.labelMedium
                                              ?.copyWith(
                                            color: context
                                                .colors.onPrimaryContainer
                                                .withValues(alpha: 0.8),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 20),
                          Row(
                            children: [
                              Container(
                                width: 54,
                                height: 54,
                                decoration: BoxDecoration(
                                  gradient: const LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: [
                                      Color(0xFF1FB1FF),
                                      Color(0xFF0390E8),
                                    ],
                                  ),
                                  borderRadius: BorderRadius.circular(15),
                                ),
                                child: const Icon(
                                  Icons.extension_rounded,
                                  color: Colors.white,
                                  size: 29,
                                ),
                              ),
                              const SizedBox(width: 13),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Continue Your Mystery',
                                      style: context.text.bodyLarge?.copyWith(
                                        fontSize: 20,
                                        height: 1.15,
                                        fontWeight: FontWeight.w800,
                                        color: context.colors.onSurface,
                                      ),
                                    ),
                                    const SizedBox(height: 5),
                                    Text(
                                      savedSessions.length == 1
                                          ? 'You have 1 unfinished mystery.'
                                          : 'You have ${savedSessions.length} unfinished mysteries.',
                                      style: context.text.labelMedium
                                          ?.copyWith(
                                        color: context.colors.onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          if (visibleSessions.isNotEmpty)
                            const SizedBox(height: 14),
                          for (var i = 0; i < visibleSessions.length; i++) ...[
                            Dismissible(
                              key: ValueKey(
                                'saved-puzzle-${visibleSessions[i].id}',
                              ),
                              direction: vm.isResumingSession
                                  ? DismissDirection.none
                                  : DismissDirection.horizontal,
                              confirmDismiss: (_) => _confirmSavedGameDeletion(
                                context,
                                type: _SavedGameType.puzzle,
                                id: visibleSessions[i].id,
                              ),
                              background: const _PuzzleDeleteCardBackground(
                                alignment: Alignment.centerLeft,
                              ),
                              secondaryBackground:
                                  const _PuzzleDeleteCardBackground(
                                alignment: Alignment.centerRight,
                              ),
                              onDismissed: (_) => setState(() {
                                _deletedIds.add(visibleSessions[i].id);
                              }),
                              child: _SavedSessionCard(
                                saved: visibleSessions[i],
                                busy: vm.isResumingSession,
                                onContinue: () =>
                                    vm.resumeSession(visibleSessions[i]),
                              ),
                            ),
                            if (i != visibleSessions.length - 1)
                              const SizedBox(height: 13),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Delete action revealed while swiping a saved puzzle — confirmDismiss on
/// the Dismissible above gates the actual swipe on the confirmation dialog
/// and Supabase delete succeeding, so this backdrop only ever completes its
/// animation once the row is really gone.
class _PuzzleDeleteCardBackground extends StatelessWidget {
  const _PuzzleDeleteCardBackground({required this.alignment});

  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 13),
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: context.colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      alignment: alignment,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.delete_outline_rounded,
            color: context.colors.onSurfaceVariant,
            size: 18,
          ),
          const SizedBox(width: 8),
          Text(
            'Delete Game',
            style: context.text.labelMedium?.copyWith(
              color: context.colors.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// Same relative-time formatting Trip Path Quest's own saved-game card uses
/// (savedQuestLastPlayedTextFor in trip_path_quest_viewmodel.dart) — kept as
/// an independent copy here since Puzzle's SavedPuzzleSession is a different
/// model with its own `updatedAt` field.
String _formatLastPlayed(DateTime? value) {
  if (value == null) return 'Recently';

  final difference = DateTime.now().difference(value);

  if (difference.inMinutes < 1) return 'Just now';
  if (difference.inHours < 1) return '${difference.inMinutes} min ago';
  if (difference.inDays < 1) return '${difference.inHours} hr ago';
  if (difference.inDays == 1) return 'Yesterday';

  return '${value.day.toString().padLeft(2, '0')}/'
      '${value.month.toString().padLeft(2, '0')}/'
      '${value.year}';
}

class _SavedSessionCard extends StatelessWidget {
  final SavedPuzzleSession saved;
  final bool busy;
  final VoidCallback onContinue;

  const _SavedSessionCard({
    required this.saved,
    required this.busy,
    required this.onContinue,
  });

  @override
  Widget build(BuildContext context) {
    final isNavigating = saved.stage == 'navigate';
    final color = _categoryColor(saved.category);
    // Puzzle only has two stages (solving the jigsaw, then navigating to
    // verify) — shown the same way Trip Path shows checkpoint progress.
    const total = 2;
    final completed = isNavigating ? 1 : 0;
    final progress = completed / total;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: context.colors.outlineVariant, width: 1.3),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: context.isDark ? 0.3 : 0.06),
            blurRadius: 14,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: _SafeNetworkImage(imageUrl: saved.referenceImageUrl),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Category only — same privacy convention as everywhere
                    // else (the real name/address stays hidden until
                    // verified, UC-03 C3 / FR03_6), even on the tourist's
                    // own resume card.
                    Text(
                      _categoryDisplayLabel(saved.category),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.bodyMedium?.copyWith(
                        color: context.colors.onSurface,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Icon(
                          isNavigating
                              ? Icons.navigation_rounded
                              : Icons.extension_rounded,
                          size: 13,
                          color: color,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            isNavigating
                                ? 'Puzzle solved · ready to navigate'
                                : 'Solving puzzle',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.text.labelMedium?.copyWith(
                              color: context.colors.onSurfaceVariant,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  'Mystery progress · ${_formatLastPlayed(saved.updatedAt)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.labelMedium?.copyWith(
                    color: context.colors.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                isNavigating ? 'Ready to navigate' : 'Solving puzzle',
                style: context.text.labelMedium?.copyWith(
                  color: context.colors.onSurface,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              minHeight: 7,
              value: progress,
              backgroundColor: context.colors.surfaceContainerHighest,
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            height: 46,
            child: FilledButton.icon(
              onPressed: busy ? null : onContinue,
              icon: busy
                  ? const SizedBox(
                      width: 17,
                      height: 17,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          Colors.white,
                        ),
                      ),
                    )
                  : const Icon(Icons.play_arrow_rounded),
              label: Text(
                busy ? 'Loading…' : 'Continue Game',
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: color,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _OptionsScreen extends StatelessWidget {
  final MysteryPlacePuzzleGameViewModel vm;
  final String touristId;
  final String? entrySourceNote;

  const _OptionsScreen({
    required this.vm,
    required this.touristId,
    this.entrySourceNote,
  });

  @override
  Widget build(BuildContext context) {
    final maxSheetHeight = MediaQuery.of(context).size.height * 0.88;

    // The route behind this is opaque:false, so the real Map screen shows
    // straight through the scrim below — a sheet rising over Map, matching
    // Trip Path's entry, instead of covering the whole screen with a
    // separate page.
    return Stack(
      fit: StackFit.expand,
      children: [
        const _PuzzleScrimBarrier(),
        Align(
          alignment: Alignment.bottomCenter,
          child: _PuzzleDismissibleSheet(
            builder: (context, onDragUpdate, onDragEnd) => Container(
            width: double.infinity,
            constraints: BoxConstraints(maxHeight: maxSheetHeight),
            decoration: BoxDecoration(
              color: context.colors.surface,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(28),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _PuzzleSheetDragHandle(
                  onDragUpdate: onDragUpdate,
                  onDragEnd: onDragEnd,
                ),
                const _AppTopBar(
                  title: 'Choose a Mystery',
                  lightBackground: true,
                ),
                const SizedBox(height: 14),
                if (entrySourceNote != null) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 22),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: context.colors.primaryContainer,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: context.colors.primary.withValues(alpha: 0.35),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.travel_explore_rounded,
                            color: context.colors.onPrimaryContainer,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              entrySourceNote!,
                              style: context.text.labelMedium?.copyWith(
                                color: context.colors.onPrimaryContainer,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                ],
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 22),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '${vm.availableOptions.length} hidden places found nearby. Choose one to discover!',
                      style: context.text.bodyMedium?.copyWith(
                        color: context.colors.onSurfaceVariant,
                        height: 1.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                // A plain (non-scrolling) list — with 3 compact cards this
                // fits on screen without needing to drag. Still wrapped in a
                // scroll view as a safety net on short devices/large text
                // settings, so it degrades to scrollable rather than
                // overflowing, but that shouldn't be needed in practice.
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(22, 4, 22, 16),
                    child: Column(
                      children: [
                        for (var index = 0;
                            index < vm.availableOptions.length;
                            index++) ...[
                          GestureDetector(
                            onTap: () => vm.chooseOption(
                              touristId: touristId,
                              option: vm.availableOptions[index],
                            ),
                            child: _MysteryOptionCard(
                              option: vm.availableOptions[index],
                              index: index,
                            ),
                          ),
                          if (index != vm.availableOptions.length - 1)
                            const SizedBox(height: 12),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
            ),
          ),
        ),
      ],
    );
  }
}

class _MysteryOptionCard extends StatelessWidget {
  final MysteryPlaceOption option;
  final int index;

  const _MysteryOptionCard({required this.option, required this.index});

  @override
  Widget build(BuildContext context) {
    final imageUrl = _cacheSafeUrl(option.imageUrl);

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: context.colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: context.colors.outlineVariant),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: context.isDark ? 0.3 : 0.08),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: const BoxDecoration(
              color: Color(0xFF08316A),
              borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
            ),
            child: Row(
              children: [
                Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A4B8F),
                    borderRadius: BorderRadius.circular(15),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(15),
                    child: Image.network(
                      imageUrl,
                      fit: BoxFit.cover,
                      loadingBuilder: (context, child, loadingProgress) {
                        if (loadingProgress == null) return child;
                        return const Center(
                          child: CircularProgressIndicator(
                            color: Color(0xFF1FB1FF),
                            strokeWidth: 2,
                          ),
                        );
                      },
                      errorBuilder: (context, error, stackTrace) {
                        return const Center(
                          child: Icon(
                            Icons.image_not_supported,
                            color: Colors.white,
                            size: 22,
                          ),
                        );
                      },
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'MYSTERY #${index + 1}',
                        style: const TextStyle(
                          color: Color(0xFF8DBBFF),
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 1.2,
                        ),
                      ),
                      const SizedBox(height: 4),
                      // Category only — no address, and no separate "Hidden
                      // Place" title now that this is it. The exact spot
                      // still isn't revealed until the puzzle is solved.
                      Text(
                        _categoryDisplayLabel(option.category),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '"${option.description}"',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.text.labelMedium?.copyWith(
                      color: context.colors.onSurfaceVariant,
                      height: 1.4,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  '→',
                  style: TextStyle(
                    color: context.colors.primary,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ImagePreviewScreen extends StatelessWidget {
  final MysteryPlacePuzzleGameViewModel vm;

  const _ImagePreviewScreen({required this.vm});

  @override
  Widget build(BuildContext context) {
    final option = vm.selectedOption!;

    return Container(
      color: const Color(0xFF041428),
      child: Column(
        children: [
          const SizedBox(height: 10),
          _AppTopBar(
            title: 'Memorise the Image',
            leftText: '✕ Exit',
            onLeftTap: vm.resetToOptions,
          ),
          const SizedBox(height: 18),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 22),
            child: Text(
              'Remember this mystery image. It will be shuffled into a 3×3 puzzle.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Color(0xFFC8D4E5),
                fontSize: 13,
                height: 1.45,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 22),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF0B203A),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: const Color(0xFF1FB1FF), width: 1.2),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: _SafeNetworkImage(
                    imageUrl: option.imageUrl,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 22),
          const Text(
            'Puzzle starts in a few seconds...',
            style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
          ),
          const SizedBox(height: 18),
          const CircularProgressIndicator(
            color: Color(0xFF1FB1FF),
            strokeWidth: 2,
          ),
        ],
      ),
    );
  }
}

/// Confirms before leaving a puzzle in progress — reached from the on-screen
/// back arrow and from the system back gesture/button (via the PopScope in
/// [_PuzzleScreenState.build]). The session already autosaves ([[puzzle-save-
/// resume]]), so this is a "do you want to leave" prompt rather than a
/// destructive-action warning.
Future<void> _confirmExitPuzzle(BuildContext context) async {
  final leave = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Leave this mystery?'),
      content: const Text(
        'Your progress is saved. You can continue this mystery later from '
        'Continue Your Mystery.',
      ),
      actions: [
        Row(
          children: [
            Expanded(
              child: TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF0B95E9),
                  foregroundColor: Colors.white,
                ),
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Leave'),
              ),
            ),
          ],
        ),
      ],
    ),
  );

  if (leave == true && context.mounted) {
    // pop(), not maybePop(): the enclosing PopScope's canPop:false blocks
    // maybePop() too (it re-negotiates the same pop this dialog already
    // confirmed) — only an unconditional pop() actually leaves the route.
    Navigator.of(context).pop();
  }
}

class _PuzzleScreen extends StatefulWidget {
  final MysteryPlacePuzzleGameViewModel vm;

  const _PuzzleScreen({required this.vm});

  @override
  State<_PuzzleScreen> createState() => _PuzzleScreenState();
}

class _PuzzleScreenState extends State<_PuzzleScreen> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // Drives vm.elapsedSeconds; the VM auto-marks the wrong tiles every minute.
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      widget.vm.registerElapsedSecond();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  static String _formatElapsed(int totalSeconds) {
    final m = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final s = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final vm = widget.vm;
    final option = vm.selectedOption!;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _confirmExitPuzzle(context);
      },
      child: Stack(
      children: [
        Container(
          color: const Color(0xFF041428),
          child: SingleChildScrollView(
            physics: const ClampingScrollPhysics(),
            child: Column(
              children: [
              const SizedBox(height: 10),
              _AppTopBar(
                title: 'Solve the Puzzle',
                // A continued game is already tied to its saved session
                // (and a deep-linked resume from Profile / Game History
                // never populated availableOptions in the first place), so
                // just close the route instead of routing back through
                // resetToOptions() into "Choose a Mystery" — matches the
                // Navigate screen's own back button below. Confirms first
                // (same as the system back gesture/button via PopScope
                // above) since it's easy to tap by accident mid-puzzle.
                onBack: () => _confirmExitPuzzle(context),
                roundBackButton: true,
              ),
              const SizedBox(height: 6),
              Text(
                '⏱ ${_formatElapsed(vm.elapsedSeconds)}'
                '                            💡 ${vm.hintsLeft} hints',
                style: const TextStyle(
                  color: Color(0xFFC9DBF4),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              if (vm.errorMessage != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _InfoBanner(
                    message: vm.errorMessage!,
                    onClose: vm.clearMessage,
                  ),
                ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0B203A),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: GridView.builder(
                      padding: EdgeInsets.zero,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: vm.puzzlePieces.length,
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            mainAxisSpacing: 4,
                            crossAxisSpacing: 4,
                            childAspectRatio: 1.0,
                          ),
                      itemBuilder: (context, index) {
                        final piece = vm.puzzlePieces[index];
                        final isSelected = vm.selectedPuzzleIndex == index;
                        final isHintTile =
                            vm.highlightedWrongTiles.contains(index);

                        return GestureDetector(
                          onTap: () => vm.tapPuzzlePiece(index),
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: isSelected
                                    ? const Color(0xFFF59E0B)
                                    : isHintTile
                                    ? const Color(0xFFFF3B30)
                                    : const Color(0xFF1B365A),
                                width: isSelected || isHintTile ? 3 : 1.2,
                              ),
                              boxShadow: isHintTile
                                  ? [
                                      BoxShadow(
                                        color: const Color(
                                          0xFFFF3B30,
                                        ).withValues(alpha: 0.45),
                                        blurRadius: 12,
                                        spreadRadius: 1,
                                      ),
                                    ]
                                  : [],
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: _PuzzleImageTile(
                                imageUrl: option.imageUrl,
                                piece: piece,
                                rows: 3,
                                cols: 3,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0B203A),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Current Mystery',
                        style: TextStyle(
                          color: Color(0xFF1FB1FF),
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '"${option.description}"',
                        style: const TextStyle(
                          color: Color(0xFFC8D4E5),
                          fontSize: 12,
                          height: 1.45,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: vm.useHint,
                        child: Container(
                          height: 54,
                          decoration: BoxDecoration(
                            color: const Color(0xFF1A1C22),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: const Color(0xFFFFB000),
                              width: 1.2,
                            ),
                          ),
                          child: Center(
                            child: Text(
                              '💡 Hint (${vm.hintsLeft})',
                              style: const TextStyle(
                                color: Color(0xFFFFC33C),
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: GestureDetector(
                        onTap: () => vm.checkPuzzleSolved(),
                        child: Container(
                          height: 54,
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [Color(0xFF1FB1FF), Color(0xFF0390E8)],
                            ),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: const Center(
                            child: Text(
                              'Check',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              ],
            ),
          ),
        ),
        if (vm.showHintPreviewImage)
          _HintImageOverlay(imageUrl: option.imageUrl, onClose: () {}),
      ],
      ),
    );
  }
}

class _HintImageOverlay extends StatelessWidget {
  final String imageUrl;
  final VoidCallback onClose;

  const _HintImageOverlay({required this.imageUrl, required this.onClose});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withValues(alpha: 0.88),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF0B203A),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: const Color(0xFF1FB1FF), width: 1.2),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Original Image Hint',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: _SafeNetworkImage(
                      imageUrl: imageUrl,
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'The puzzle will return automatically.',
                  style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NavigateScreen extends StatefulWidget {
  final MysteryPlacePuzzleGameViewModel vm;

  const _NavigateScreen({required this.vm});

  @override
  State<_NavigateScreen> createState() => _NavigateScreenState();
}

class _NavigateScreenState extends State<_NavigateScreen> {
  final _mapKey = GlobalKey<_NavigateMapState>();

  // Fixed clearance for the floating back/controls row (top) and the info
  // card (bottom) so a fitted point never lands underneath them. A dynamic,
  // measured version of this (via GlobalKey RenderBox sizes) caused the fit
  // to occasionally collapse to the map's minZoom (whole-world view) —
  // fixed, generous constants are simpler and can't hit that failure mode.
  //
  // Bottom clearance covers the full card (category row + metric boxes +
  // range banner + Verify button) at its TALLEST — the not-arrived range
  // banner wraps to a title line plus a "Verify unlocks within 50 m"
  // subtitle, ~15px taller than the single-line arrived state — plus the
  // Exit button beneath it. 380 was tuned against the shorter variant and
  // still wasn't enough (reported twice); trimming the proven 460 down to
  // 420 for more zoom detail brought the same "point under the card" bug
  // back a third time. 460 stays put — don't lower it again. MediaQuery's
  // bottom inset is added on top since the device's own nav bar/home
  // indicator sits below the Exit button and isn't otherwise accounted
  // for, so it ate into this same clearance on gesture-nav phones.
  //
  // Top clearance instead of bottom is where there's real slack: the only
  // things up there are the back button (~54px incl. SafeArea) and, on the
  // right edge only, the 4-button zoom/recenter column (~206px) — nowhere
  // near the 200px this used to reserve across the FULL width. Cutting it
  // to 110 accepts a narrow-strip risk (a point could end up close to the
  // right-hand button column specifically) in exchange for real map height
  // back, instead of eating further into the bottom clearance that's
  // already failed twice at lower values.
  static const _fitPaddingTop = 110.0;
  static const _fitPaddingBottomContent = 460.0;
  static const _fitPaddingHorizontal = 24.0;

  EdgeInsets _fitPadding(BuildContext context) => EdgeInsets.fromLTRB(
        _fitPaddingHorizontal,
        _fitPaddingTop,
        _fitPaddingHorizontal,
        _fitPaddingBottomContent + MediaQuery.of(context).padding.bottom,
      );

  @override
  void initState() {
    super.initState();
    widget.vm.startNavigationTracking();
  }

  @override
  void dispose() {
    widget.vm.stopNavigationTracking();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vm = widget.vm;
    final option = vm.selectedOption!;
    final distance = vm.liveDistanceMeters;
    final arrived = vm.navigationArrived;

    final distanceLabel = distance == null
        ? '—'
        : distance >= 1000
            ? '${(distance / 1000).toStringAsFixed(1)} km'
            : '${distance.round()} m';

    // Full-bleed map with floating controls, like Trip Path's Navigation
    // page, instead of a small map box above a separate info card.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _confirmExitPuzzle(context);
      },
      child: Stack(
      children: [
        Positioned.fill(
          child: _NavigateMap(
            key: _mapKey,
            destination: LatLng(option.latitude, option.longitude),
            current: (vm.currentLat != null && vm.currentLng != null)
                ? LatLng(vm.currentLat!, vm.currentLng!)
                : null,
            proximityMeters:
                MysteryPlacePuzzleGameViewModel.verificationRangeMeters
                    .toDouble(),
            // Keeps both points clear of the floating controls/card.
            fitPadding: _fitPadding(context),
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _NavMapIconButton(
                  icon: Icons.arrow_back_ios_new_rounded,
                  tooltip: 'Back',
                  // The puzzle is already solved and the session autosaves as
                  // 'navigate' ([[puzzle-save-resume]]), so there's nothing to
                  // lose here in terms of data — but it's easy to tap by
                  // accident mid-navigation, so confirm first (same dialog
                  // and PopScope pattern as the Solve-the-Puzzle screen).
                  onTap: () => _confirmExitPuzzle(context),
                ),
                const Spacer(),
                Column(
                  children: [
                    _NavMapIconButton(
                      icon: Icons.my_location_rounded,
                      tooltip: 'Recenter map',
                      onTap: () => _mapKey.currentState?.recenter(),
                    ),
                    const SizedBox(height: 10),
                    _NavMapIconButton(
                      icon: Icons.add_rounded,
                      tooltip: 'Zoom in',
                      onTap: () => _mapKey.currentState?.zoomIn(),
                    ),
                    const SizedBox(height: 10),
                    _NavMapIconButton(
                      icon: Icons.remove_rounded,
                      tooltip: 'Zoom out',
                      onTap: () => _mapKey.currentState?.zoomOut(),
                    ),
                    const SizedBox(height: 10),
                    _NavMapIconButton(
                      icon: Icons.navigation_rounded,
                      tooltip: 'Recenter on me',
                      onTap: () => _mapKey.currentState?.recenterOnMe(),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // One consolidated card — place header, Distance/Direction,
                  // status banner and the Verify button together — same
                  // layout as Trip Path Quest's Navigate card.
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x140F172A),
                          blurRadius: 14,
                          offset: Offset(0, 5),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: const Color(0xFFEAF4FF),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(
                                _categoryIcon(option.category),
                                color: const Color(0xFF0B95E9),
                                size: 22,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              // Category only — not the real name/address,
                              // which would give the hidden place away
                              // before it's verified (UC-03 C3 / FR03_6).
                              child: Text(
                                _categoryDisplayLabel(option.category),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Color(0xFF07162E),
                                  fontSize: 15,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Expanded(
                              child: _PuzzleMetricBox(
                                icon: Icons.navigation_rounded,
                                label: 'Distance',
                                value: distanceLabel,
                                color: const Color(0xFF0B95E9),
                                bgColor: const Color(0xFFEAF4FF),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _PuzzleMetricBox(
                                icon: _directionArrowIcon(vm.directionText),
                                label: 'Direction',
                                value: vm.directionText,
                                color: const Color(0xFFF08A00),
                                bgColor: const Color(0xFFFFF4DF),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        _PuzzleVerificationRangeCard(
                          arrived: arrived,
                          hasLocation: distance != null,
                        ),
                        const SizedBox(height: 14),
                        // Only unlocks from a real GPS reading within
                        // verificationRangeMeters — no demo shortcut,
                        // matching Trip Path Quest's Navigate button exactly.
                        SizedBox(
                          width: double.infinity,
                          height: 50,
                          child: FilledButton(
                            onPressed:
                                arrived ? vm.goToVerifyReference : null,
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFF087FF5),
                              foregroundColor: Colors.white,
                              disabledBackgroundColor:
                                  const Color(0xFFE2E8F0),
                              disabledForegroundColor:
                                  const Color(0xFF64748B),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                              elevation: arrived ? 5 : 0,
                              shadowColor: const Color(0x55087FF5),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  arrived
                                      ? Icons.verified_rounded
                                      : Icons.lock_rounded,
                                  size: 22,
                                ),
                                const SizedBox(width: 10),
                                Flexible(
                                  child: Text(
                                    arrived
                                        ? 'Verify Visit'
                                        : 'Move Within 50 m to Verify',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: OutlinedButton.icon(
                      // The puzzle session already autosaves at this stage
                      // (see the back button above), so exiting here is just
                      // a plain pop once confirmed — nothing extra needs
                      // saving first.
                      onPressed: () => _confirmExitPuzzle(context),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF64748B),
                        side: const BorderSide(color: Color(0xFFE2E8F0)),
                        backgroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      icon: const Icon(Icons.exit_to_app_rounded, size: 19),
                      label: const Text(
                        'Save & Exit Quest · Back to Home',
                        maxLines: 1,
                        overflow: TextOverflow.fade,
                        softWrap: false,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
      ),
    );
  }
}

/// Displayed category name for a hidden place — matched by the same
/// keywords as [_categoryIcon]/[_categoryColor] and renamed to match Trip
/// Path Quest's theme names ("Food Quest", "Culture Quest", "Heritage
/// Quest", "Nature Quest") so a mystery and a quest read as the same kind
/// of thing. Puzzle only ever offers these four categories when browsing
/// "Choose a Mystery" (gm.dart's fetchNearbyPuzzlePlaces drops the generic
/// "Local Attraction" catch-all before it gets this far). A marker-specific
/// entry can still hand in an uncategorised place (Map itself has no such
/// restriction), so this never falls back to the raw category text —
/// unrecognised input reads as a generic "Mystery Quest" instead of e.g.
/// "Local Attraction".
String _categoryDisplayLabel(String category) {
  final c = category.toLowerCase();
  if (c.contains('food') || c.contains('restaurant') || c.contains('cafe')) {
    return 'Food Quest';
  }
  if (c.contains('museum') || c.contains('gallery') || c.contains('cultur')) {
    return 'Culture Quest';
  }
  if (c.contains('park') || c.contains('garden') || c.contains('nature')) {
    return 'Nature Quest';
  }
  if (c.contains('heritage')) {
    return 'Heritage Quest';
  }
  return 'Mystery Quest';
}

/// Material icon for a hidden place's general category (e.g. "Museum &
/// Gallery") — matched by keyword so it also covers the offline sample
/// places' shorter category strings ("Park", "Heritage", "Cultural Hub").
IconData _categoryIcon(String category) {
  final c = category.toLowerCase();
  if (c.contains('food') || c.contains('restaurant') || c.contains('cafe')) {
    return Icons.restaurant_rounded;
  }
  if (c.contains('museum') || c.contains('gallery') || c.contains('cultur')) {
    return Icons.museum_rounded;
  }
  if (c.contains('park') || c.contains('garden') || c.contains('nature')) {
    return Icons.park_rounded;
  }
  if (c.contains('heritage')) {
    return Icons.account_balance_rounded;
  }
  return Icons.explore_rounded;
}

/// Accent color for a hidden place's general category — same palette Trip
/// Path Quest uses for its theme cards, so a saved mystery and a saved quest
/// read as part of the same visual language.
Color _categoryColor(String category) {
  final c = category.toLowerCase();
  if (c.contains('food') || c.contains('restaurant') || c.contains('cafe')) {
    return const Color(0xFFEA580C);
  }
  if (c.contains('museum') || c.contains('gallery') || c.contains('cultur')) {
    return const Color(0xFF7C3AED);
  }
  if (c.contains('park') || c.contains('garden') || c.contains('nature')) {
    return const Color(0xFF16A34A);
  }
  if (c.contains('heritage')) {
    return const Color(0xFFB45309);
  }
  return const Color(0xFF0284C7);
}

/// Material icon for an 8-point compass label (e.g. "North-East"), same
/// mapping Trip Path's navigation card uses.
IconData _directionArrowIcon(String label) {
  switch (label) {
    case 'North':
      return Icons.north_rounded;
    case 'North-East':
      return Icons.north_east_rounded;
    case 'East':
      return Icons.east_rounded;
    case 'South-East':
      return Icons.south_east_rounded;
    case 'South':
      return Icons.south_rounded;
    case 'South-West':
      return Icons.south_west_rounded;
    case 'West':
      return Icons.west_rounded;
    case 'North-West':
      return Icons.north_west_rounded;
    default:
      return Icons.navigation_rounded;
  }
}

/// Compact Distance/Direction stat box on the Navigate floating card — same
/// icon-circle + label + value pattern as Trip Path's metric cards.
class _PuzzleMetricBox extends StatelessWidget {
  const _PuzzleMetricBox({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
    required this.bgColor,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;
  final Color bgColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 70),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFD9E8F7)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x100F172A),
            blurRadius: 8,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(color: bgColor, shape: BoxShape.circle),
            child: Icon(icon, color: color, size: 18),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  softWrap: false,
                  style: const TextStyle(
                    color: Color(0xFF64748B),
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: color,
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Status banner beneath the Distance/Direction row — green once within the
/// 50 m verify range, neutral blue otherwise. Same layout and copy as Trip
/// Path Quest's `_VerificationRangeCard`.
class _PuzzleVerificationRangeCard extends StatelessWidget {
  final bool arrived;
  final bool hasLocation;

  const _PuzzleVerificationRangeCard({
    required this.arrived,
    required this.hasLocation,
  });

  @override
  Widget build(BuildContext context) {
    final reached = arrived && hasLocation;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 9, 10, 9),
      decoration: BoxDecoration(
        color: reached ? const Color(0xFFE9FFF2) : const Color(0xFFF1F7FD),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: reached ? const Color(0xFFB7F1CF) : const Color(0xFFD7E6F5),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: reached
                  ? const Color(0xFFD4F9E4)
                  : const Color(0xFFE2EDF8),
              shape: BoxShape.circle,
            ),
            child: Icon(
              reached ? Icons.location_on_rounded : Icons.lock_rounded,
              color: reached
                  ? const Color(0xFF18A957)
                  : const Color(0xFF64748B),
              size: 19,
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  reached
                      ? "You're close enough! Verification is now available."
                      : hasLocation
                          ? 'Keep moving toward the mystery location'
                          : 'Waiting for your GPS position',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: reached
                        ? const Color(0xFF087A38)
                        : const Color(0xFF334155),
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                if (!reached) ...[
                  const SizedBox(height: 3),
                  Text(
                    hasLocation
                        ? 'Verify unlocks within 50 m'
                        : 'Location is required to unlock verification.',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFF64748B),
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Small floating circular icon button used over the Navigate map (back,
/// recenter) — same visual language as Trip Path's map controls.
class _NavRoundIconButton extends StatelessWidget {
  const _NavRoundIconButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xCC0B1F3D),
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 42,
          height: 42,
          child: Icon(icon, color: Colors.white, size: 19),
        ),
      ),
    );
  }
}

/// Floating icon button for the Navigate screen's map controls (back,
/// recenter, zoom) — same white rounded-square style and elevation as View
/// Map's `_MapIconButton`, so both map screens read as one design language
/// instead of Navigate's older dark circular buttons.
class _NavMapIconButton extends StatelessWidget {
  const _NavMapIconButton({
    required this.icon,
    required this.onTap,
    required this.tooltip,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: context.appColors.mapPanel,
        elevation: 8,
        shadowColor: Colors.black.withValues(alpha: 0.4),
        borderRadius: AppRadius.brMd,
        child: InkWell(
          borderRadius: AppRadius.brMd,
          onTap: onTap,
          child: SizedBox.square(
            dimension: 44,
            child: Icon(icon, color: context.appColors.onMapPanel, size: 21),
          ),
        ),
      ),
    );
  }
}

/// A real map for the Navigate screen — same Google/OSM tiles as View Map,
/// showing just the tourist and the destination (no route line).
class _NavigateMap extends StatefulWidget {
  const _NavigateMap({
    super.key,
    required this.destination,
    this.current,
    this.proximityMeters = 50,
    this.fitPadding = const EdgeInsets.all(48),
  });

  final LatLng destination;
  final LatLng? current;

  /// UC-05 A2 verification radius, drawn as a circle around the destination.
  final double proximityMeters;

  /// How much of each edge the floating back/controls row and bottom info
  /// card cover — [_fit] keeps both points clear of this, not just clear of
  /// the raw widget bounds, or a point can land directly under the bottom
  /// card (reported: "下面的box 会挡住部分map").
  final EdgeInsets fitPadding;

  @override
  State<_NavigateMap> createState() => _NavigateMapState();
}

class _NavigateMapState extends State<_NavigateMap> {
  final MapController _controller = MapController();
  late final Future<String> _urlTemplate = _resolveTiles();

  /// The position the camera was last fit to. `_refreshDistance()` polls GPS
  /// every 3s and updates `widget.current` even when the tourist hasn't
  /// actually moved — ordinary GPS jitter (a few metres) was enough to
  /// change the fit bounds on every tick, making the view visibly bounce /
  /// re-zoom every few seconds. Re-fitting only once the tourist has moved a
  /// meaningful distance keeps the camera stable in between.
  LatLng? _lastFitCurrent;
  static const _refitThresholdMeters = 15.0;

  @override
  void initState() {
    super.initState();
    // _startingCamera() below only gives MapOptions a rough, unpadded
    // midpoint so the very first frame has something to paint — it doesn't
    // know about the bottom card. didUpdateWidget's _fit() normally
    // corrects that, but only once `current` changes by _refitThresholdMeters,
    // which never happens if the GPS fix is already available when this
    // screen mounts — leaving both points sitting exactly where the initial
    // report said: under the bottom card. Scheduling the real, padded _fit()
    // for right after the first frame (not from onMapReady — see
    // _startingCamera's doc comment) fixes the initial position without
    // reviving the blank-map bug.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fit();
    });
    // The attempt above can lose a race: _urlTemplate resolves the tile
    // source asynchronously (a network round-trip for Google's session,
    // slower and more variable than the OSM fallback), and until it
    // resolves the build below shows a loading placeholder instead of
    // FlutterMap — no MapController is attached yet, so that first _fit()
    // silently does nothing whenever tiles happen to still be loading at
    // that point. That's exactly why this bug was intermittent ("sometimes
    // both points show, sometimes not") rather than a plain padding/zoom
    // miscalculation. Re-running _fit() once tiles are actually ready (and
    // one more frame has passed for FlutterMap to mount) guarantees at
    // least one attempt happens after the controller is truly attached,
    // regardless of how the race above went.
    _urlTemplate.then((_) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _fit();
      });
    });
  }

  Future<String> _resolveTiles() async {
    try {
      final service = const MapTilesService();
      if (service.hasApiKey) {
        // The puzzle flow is a permanently dark surface, so the navigate map
        // uses dark Google tiles to match it.
        final session = await service.createSession(dark: true);
        return service.tileUrlTemplate(session);
      }
    } catch (_) {}
    return 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
  }

  /// Zoom buttons — same +/- step and clamp as View Map's.
  void _zoomBy(double amount) {
    final camera = _controller.camera;
    _lastFitCurrent = widget.current;
    _controller.move(camera.center, (camera.zoom + amount).clamp(3.0, 19.0));
  }

  void zoomIn() => _zoomBy(1.0);
  void zoomOut() => _zoomBy(-1.0);

  /// "My location" button — centres on the tourist alone, unlike [_fit] /
  /// [recenter] which frame both points.
  ///
  /// A plain `move(current, 17)` centres `current` on the FULL viewport,
  /// including the area the bottom card covers — on this screen that pushes
  /// the dot up near (or under) the card instead of the middle of the
  /// visually safe area above it. Giving it a small real bounding box (an
  /// exact zero-size LatLngBounds isn't guaranteed to fit reliably) and
  /// pinning both zoom bounds to 17 reuses [_fit]'s own tested
  /// padding-aware centering math for a single point instead of "whatever
  /// fits two points".
  void recenterOnMe() {
    final current = widget.current;
    if (current == null) return;
    _lastFitCurrent = current;
    const distance = Distance();
    var bounds = LatLngBounds(current, current);
    for (final bearing in [0.0, 90.0, 180.0, 270.0]) {
      bounds.extend(distance.offset(current, 20, bearing));
    }
    _controller.fitCamera(
      CameraFit.bounds(
        bounds: bounds,
        padding: widget.fitPadding,
        minZoom: 17,
        maxZoom: 17,
      ),
    );
  }

  void _fit() {
    final current = widget.current;
    _lastFitCurrent = current;
    // Defensive: this can run before FlutterMap has actually mounted (see
    // initState's _urlTemplate race above) — MapController throws if used
    // before it's attached to a live map. Swallowing that here means a
    // mistimed call just does nothing instead of crashing the screen; the
    // _urlTemplate.then() retry in initState is what makes sure a *working*
    // attempt still happens once the map is really there.
    try {
      if (current == null) {
        _controller.move(widget.destination, 16);
        return;
      }
      _fitBothPoints(current);
    } catch (_) {}
  }

  void _fitBothPoints(LatLng current) {
    // LatLngBounds(destination, current) alone only covers those two center
    // points — not the drawn proximity circle's radius around destination.
    // When the tourist is close to the destination the fit zooms in tight,
    // and a circle that extends outward in every direction from destination
    // then overflows that tight box (particularly the bottom/top, since the
    // box is only ever as tall as the destination-to-current line implies).
    // Extending the bounds by the circle's own radius keeps the whole circle
    // inside the fitted — and padded-safe — area instead of poking out from
    // under the bottom card.
    var bounds = LatLngBounds(widget.destination, current);
    const distance = Distance();
    for (final bearing in [0.0, 90.0, 180.0, 270.0]) {
      bounds.extend(
        distance.offset(widget.destination, widget.proximityMeters, bearing),
      );
    }
    // minZoom is a safety floor, not a target — guards against a bad
    // padding/bounds computation collapsing the fit down to MapOptions'
    // global minZoom (a whole-world view). It must stay well below any real
    // destination distance, or it does the opposite of its job: clamping
    // the zoom in *tighter* than the fit actually needs pushes one of the
    // two points (usually the destination) outside the padded-safe area,
    // landing it under the bottom card. The game's nearby-search radius is
    // only ~5km, but the tourist's live GPS distance to it can read higher
    // than that mid-navigation (routing isn't a straight line), so the
    // floor needs real headroom past 5km, not to sit right at it.
    _controller.fitCamera(
      CameraFit.bounds(
        bounds: bounds,
        padding: widget.fitPadding,
        maxZoom: 17,
        minZoom: 9,
      ),
    );
  }

  /// Exposed so the floating recenter button (owned by the parent screen,
  /// which doesn't otherwise have a handle on this map) can re-fit the
  /// camera on demand. Safe here — the map has already rendered its first
  /// tiles by the time this can be tapped; see the onMapReady note below
  /// for why the very first positioning must NOT go through the controller.
  void recenter() => _fit();

  /// A rough (not exact bounds-fit) starting centre/zoom, computed as plain
  /// maths with no MapController involved — used for MapOptions.initialCenter
  /// / initialZoom instead of positioning via the controller in onMapReady.
  ///
  /// flutter_map has a confirmed bug where repositioning the map through
  /// MapController from onMapReady blocks the very first tile load — the
  /// map stays blank until the tourist happens to pan it themselves, which
  /// only registers as a "new" camera position because the controller was
  /// never touched before that (fleaflet/flutter_map#1507). This screen
  /// used to call fitCamera()/move() straight from onMapReady precisely to
  /// frame both destination and current, which is exactly the trigger.
  /// Getting the initial position right from MapOptions up front avoids
  /// ever needing to move the map before its first paint; didUpdateWidget's
  /// _fit() below still refines it via the controller once current changes,
  /// which is safe since that always runs after the first tiles are in.
  static (LatLng, double) _startingCamera(
    LatLng destination,
    LatLng? current,
  ) {
    if (current == null) return (destination, 16);
    final center = LatLng(
      (destination.latitude + current.latitude) / 2,
      (destination.longitude + current.longitude) / 2,
    );
    final meters = const Distance().as(
      LengthUnit.Meter,
      destination,
      current,
    );
    final zoom = switch (meters) {
      < 30 => 17.0,
      < 100 => 16.5,
      < 300 => 15.5,
      < 800 => 14.5,
      < 2000 => 13.5,
      _ => 12.5,
    };
    return (center, zoom);
  }

  @override
  void didUpdateWidget(_NavigateMap old) {
    super.didUpdateWidget(old);

    // The overlay heights are measured after layout, so the very first fit
    // (right after onMapCreated-equivalent) necessarily runs before that
    // measurement lands — re-fit once it does, regardless of the movement
    // threshold below, or a stale/default padding would leave a point
    // sitting under the bottom card until the tourist happens to move far
    // enough to trigger the next fit anyway.
    if (widget.fitPadding != old.fitPadding) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _fit();
      });
      return;
    }

    final current = widget.current;
    if (current == null || current == old.current) return;

    final last = _lastFitCurrent;
    final movedEnough = last == null ||
        const Distance().as(LengthUnit.Meter, last, current) >=
            _refitThresholdMeters;
    if (!movedEnough) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fit();
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _urlTemplate,
      builder: (context, snapshot) {
        final url = snapshot.data;
        if (url == null) {
          return const ColoredBox(
            color: Color(0xFF021E39),
            child: Center(
              child: CircularProgressIndicator(color: Color(0xFF1FB1FF)),
            ),
          );
        }
        // A spinner sits behind the map so the gap between the session
        // resolving and the actual tile images streaming in (a second or
        // two, easy to mistake for "the map didn't load") reads as loading
        // rather than blank. Dark background to match, instead of the light
        // grey placeholder that looked broken against this screen's theme.
        return Stack(
          children: [
            const Center(
              child: CircularProgressIndicator(color: Color(0xFF1FB1FF)),
            ),
            Builder(
              builder: (context) {
                final (startCenter, startZoom) =
                    _startingCamera(widget.destination, widget.current);
                return FlutterMap(
                  mapController: _controller,
                  options: MapOptions(
                    initialCenter: startCenter,
                    initialZoom: startZoom,
                    minZoom: 3,
                    maxZoom: 19,
                    backgroundColor: const Color(0xFF021E39),
                    interactionOptions: const InteractionOptions(
                      flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                    ),
                    // Deliberately no onMapReady repositioning — see
                    // _startingCamera()'s doc comment for why.
                  ),
                  children: [
            TileLayer(
              urlTemplate: url,
              userAgentPackageName: 'com.example.collab_d',
            ),
            // Dashed guidance line to the destination, matching Trip Path's
            // navigation map. Ends at the proximity circle's centre — safe to
            // draw since that centre is already visible via the circle
            // itself; no separate destination pin is added (FR03_6).
            if (widget.current != null)
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: [widget.current!, widget.destination],
                    strokeWidth: 4,
                    color: const Color(0xFF0B95E9),
                    pattern: StrokePattern.dashed(segments: const [14, 10]),
                  ),
                ],
              ),
            CircleLayer(
              circles: [
                // Actual UC-05 A2 verification zone. The larger "getting
                // close" guide ring (6x this radius) used to also be drawn
                // here but dominated the whole map at any reasonable zoom —
                // removed per feedback.
                CircleMarker(
                  point: widget.destination,
                  radius: widget.proximityMeters,
                  useRadiusInMeter: true,
                  color: const Color(0x3338BDF8),
                  borderColor: const Color(0xFF0B95E9),
                  borderStrokeWidth: 2.5,
                ),
              ],
            ),
            // No destination pin — the tourist only sees the proximity zone
            // and has to find the exact spot within it (UC-05, more challenging).
            MarkerLayer(
              markers: [
                if (widget.current != null)
                  Marker(
                    point: widget.current!,
                    width: 34,
                    height: 34,
                    child: const _MapDot(),
                  ),
              ],
            ),
                  ],
                );
              },
            ),
          ],
        );
      },
    );
  }
}

/// Same look as View Map's `CurrentLocationMarker` default icon (gradient
/// circle + white navigation arrow) instead of a plain dot, so "where am I"
/// reads the same way across both map screens. Puzzle's navigate map has no
/// heading data or equipped-skin context to plug into the fuller version,
/// so this is just its static default-icon appearance.
class _MapDot extends StatelessWidget {
  const _MapDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          colors: [Color(0xFF38BDF8), Color(0xFF0369A1)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: const [BoxShadow(color: Color(0x660284C7), blurRadius: 14)],
      ),
      child: const Icon(
        Icons.navigation_rounded,
        color: Colors.white,
        size: 18,
      ),
    );
  }
}

/// Reference Photo + Your Photo on one scrollable page — same layout as
/// Trip Path Quest's verification page (trip_path_quest_verification.dart),
/// swapping the "Your Photo" card between a Take-Photo prompt and a
/// captured-photo preview depending on `vm.capturedPhoto`, instead of
/// routing to a separate Review Photo screen.
class _VerifyReferenceScreen extends StatelessWidget {
  final MysteryPlacePuzzleGameViewModel vm;
  final String touristId;

  const _VerifyReferenceScreen({required this.vm, required this.touristId});

  @override
  Widget build(BuildContext context) {
    final option = vm.selectedOption!;
    final hasPhoto = vm.capturedPhoto != null;

    return Container(
      color: const Color(0xFFF0F9FF),
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 24),
        child: Column(
          children: [
            const SizedBox(height: 10),
            _AppTopBar(
              title: 'Verify Your Visit',
              lightBackground: true,
              onBack: vm.goToNavigate,
            ),
            const SizedBox(height: 18),
            if (vm.errorMessage != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFDECEC),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFFF5B5B5)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline,
                          color: Color(0xFFC62828), size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          vm.errorMessage!,
                          style: const TextStyle(
                            color: Color(0xFFB71C1C),
                            fontSize: 12.5,
                            height: 1.35,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      GestureDetector(
                        onTap: vm.clearMessage,
                        child: const Icon(Icons.close,
                            color: Color(0xFFC62828), size: 18),
                      ),
                    ],
                  ),
                ),
              ),
            // Same dark gradient checkpoint-status card Trip Path uses on
            // this page, kept in Puzzle's own navy tones — static like Trip
            // Path's own (it doesn't poll distance on this screen either).
            // The 50 m limit itself is enforced at the "Verify Photo" tap via
            // vm.recheckDistanceForVerification(), not by this card.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF0B203A), Color(0xFF124A82)],
                  ),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 50,
                      height: 50,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(15),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.14),
                        ),
                      ),
                      child: const Icon(
                        Icons.verified_rounded,
                        color: Color(0xFF86EFAC),
                        size: 28,
                      ),
                    ),
                    const SizedBox(width: 13),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            "You've Arrived!",
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 17,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            vm.liveDistanceMeters == null
                                ? 'Within 50 m of the mystery location.'
                                : '${vm.liveDistanceMeters!.round()} m away '
                                    '· within the 50 m verify range.',
                            style: const TextStyle(
                              color: Color(0xFFBAE6FD),
                              fontSize: 12.5,
                              height: 1.4,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),
            // ==========================================================
            // REFERENCE PHOTO
            // ==========================================================
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Reference Photo',
                          style: TextStyle(
                            color: Color(0xFF0F172A),
                            fontSize: 17,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                      const _PuzzleReadyBadge(text: 'REFERENCE READY'),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Text(
                    'Use this reference when taking your photo of '
                    '${option.name}.',
                    style: const TextStyle(
                      color: Color(0xFF64748B),
                      fontSize: 12.5,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: AspectRatio(
                      aspectRatio: 16 / 10,
                      child: Container(
                        color: const Color(0xFFF1F5F9),
                        child: Image.network(
                          _cacheSafeUrl(option.imageUrl),
                          fit: BoxFit.cover,
                          loadingBuilder:
                              (context, child, loadingProgress) {
                            if (loadingProgress == null) return child;
                            return const Center(
                              child: CircularProgressIndicator(
                                color: Color(0xFF0284C7),
                                strokeWidth: 2,
                              ),
                            );
                          },
                          errorBuilder: (context, error, stackTrace) {
                            return const Center(
                              child: Icon(
                                Icons.broken_image_outlined,
                                color: Color(0xFF64748B),
                                size: 34,
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: const Color(0xFFBAE6FD)),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: const Color(0xFFE0F2FE),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: const Icon(
                            Icons.photo_camera_back_rounded,
                            color: Color(0xFF0284C7),
                          ),
                        ),
                        const SizedBox(width: 13),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                option.name,
                                style: const TextStyle(
                                  color: Color(0xFF0F172A),
                                  fontSize: 14,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 4),
                              const Text(
                                'Take your own photo of the same physical '
                                'landmark or storefront.',
                                style: TextStyle(
                                  color: Color(0xFF64748B),
                                  fontSize: 11.5,
                                  height: 1.4,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            // ==========================================================
            // YOUR PHOTO
            // ==========================================================
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Your Photo',
                          style: TextStyle(
                            color: Color(0xFF0F172A),
                            fontSize: 17,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                      if (hasPhoto)
                        const _PuzzleReadyBadge(text: 'PHOTO READY'),
                    ],
                  ),
                  const SizedBox(height: 5),
                  const Text(
                    'Take another photo of the same object or landmark '
                    'using the Camera.',
                    style: TextStyle(
                      color: Color(0xFF64748B),
                      fontSize: 12.5,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (!hasPhoto) _buildTakePhotoCard() else _buildPhotoPreview(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTakePhotoCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        children: [
          Container(
            width: 62,
            height: 62,
            decoration: const BoxDecoration(
              color: Color(0xFFE0F2FE),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.camera_alt_outlined,
              color: Color(0xFF0284C7),
              size: 29,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'No photo taken yet',
            style: TextStyle(
              color: Color(0xFF0F172A),
              fontSize: 14,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 5),
          const Text(
            'Take a clear second photo of the reference object.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xFF64748B), fontSize: 11.5),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: FilledButton.icon(
              onPressed: vm.takePhoto,
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF0284C7),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              icon: const Icon(Icons.camera_alt_rounded),
              label: const Text(
                'Take Photo',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPhotoPreview() {
    final verifying = vm.isVerifying;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFBAE6FD)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: AspectRatio(
              aspectRatio: 4 / 3,
              child: Image.file(vm.capturedPhoto!, fit: BoxFit.cover),
            ),
          ),
          if (verifying) ...[
            const SizedBox(height: 14),
            const LinearProgressIndicator(color: Color(0xFF0284C7)),
            const SizedBox(height: 10),
            const Text(
              'Comparing your photo against the reference...\n'
              'Please keep this page open.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xFF64748B), fontSize: 12),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: verifying ? null : vm.retakePhoto,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF0284C7),
                    minimumSize: const Size.fromHeight(48),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  icon: const Icon(Icons.refresh_rounded, size: 19),
                  label: const Text(
                    'Retake',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Builder(
                  builder: (context) => FilledButton.icon(
                    // Always tappable (bar being mid-verify) — same as Trip
                    // Path Quest's own Verify Photo button. The 50 m limit
                    // isn't a pre-emptive disabled state here; it's enforced
                    // by the fresh GPS recheck run at the moment of the tap,
                    // just like Trip Path's, which shows this same kind of
                    // SnackBar instead of proceeding when out of range.
                    onPressed: verifying
                        ? null
                        : () async {
                            final rejection =
                                await vm.recheckDistanceForVerification();
                            if (rejection != null) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text(rejection)),
                                );
                              }
                              return;
                            }
                            vm.submitPhotoForVerification(
                              touristId: touristId,
                            );
                          },
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF0284C7),
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: const Color(0xFFCBD5E1),
                      minimumSize: const Size.fromHeight(48),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    icon: verifying
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.verified_rounded, size: 19),
                    label: Text(
                      verifying ? 'Verifying...' : 'Verify Photo',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Small "ready" status pill — same shape/colour as Trip Path's equivalent
/// badge (`_ReadyBadge`) so the two modules' verify screens share this one
/// piece of visual language, even though the surrounding cards keep each
/// module's own dark (Puzzle) / light (Trip Path) palette.
class _PuzzleReadyBadge extends StatelessWidget {
  final String text;

  const _PuzzleReadyBadge({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFFDCFCE7),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFFBBF7D0)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.check_circle_rounded,
            size: 13,
            color: Color(0xFF16A34A),
          ),
          const SizedBox(width: 5),
          Text(
            text,
            style: const TextStyle(
              color: Color(0xFF15803D),
              fontSize: 10,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.35,
            ),
          ),
        ],
      ),
    );
  }
}


class _VerifiedScreen extends StatelessWidget {
  final MysteryPlacePuzzleGameViewModel vm;

  final void Function(BuildContext)? onRewards;
  const _VerifiedScreen({required this.vm, this.onRewards});

  @override
  Widget build(BuildContext context) {
    final option = vm.selectedOption!;
    final accent = _categoryColor(option.category);

    // Same dark "Quest Complete" layout as Trip Path Quest's
    // _QuestCompletePage, so a solved mystery and a finished quest read as
    // one design language instead of Puzzle's old plain white celebration
    // card. Puzzle has no checkpoint progression, so the stats row swaps
    // Trip Path's "x / y Checkpoints" for a "Solved" / "Unlocked" pair.
    return Container(
      color: const Color(0xFF03152E),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
          child: Column(
            children: [
              Container(
                width: 86,
                height: 86,
                decoration: BoxDecoration(
                  color: const Color(0x1AF59E0B),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: const Color(0x66FBBF24),
                    width: 2,
                  ),
                ),
                child: const Icon(
                  Icons.emoji_events_rounded,
                  color: Color(0xFFFBBF24),
                  size: 48,
                ),
              ),
              const SizedBox(height: 18),
              const Text(
                'Visit Verified!',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                "You've successfully discovered ${option.name}.",
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Color(0xFF7DD3FC),
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 24),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      accent.withValues(alpha: 0.30),
                      const Color(0xFF0A2A52),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: accent.withValues(alpha: 0.45)),
                ),
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0x22FFFFFF),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: const Text(
                        'DIGITAL STAMP',
                        style: TextStyle(
                          color: Color(0xFFFDE68A),
                          fontSize: 10.5,
                          letterSpacing: 1.2,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    // Round medallion frame, matching the circular Digital
                    // Travel Stamp shown on the Reward Details page (the
                    // stamp itself is a separately-composed postmark PNG
                    // with its own baked-in ring/caption — this is just this
                    // celebration screen's own photo echoing that shape).
                    Container(
                      width: 168,
                      height: 168,
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: accent.withValues(alpha: 0.55),
                          width: 2,
                        ),
                      ),
                      child: ClipOval(
                        child: Container(
                          color: const Color(0xFF0A2A52),
                          child: Image.network(
                            _cacheSafeUrl(option.imageUrl),
                            fit: BoxFit.cover,
                            loadingBuilder: (context, child, loadingProgress) {
                              if (loadingProgress == null) return child;
                              return const Center(
                                child: CircularProgressIndicator(
                                  color: Color(0xFFFBBF24),
                                  strokeWidth: 2,
                                ),
                              );
                            },
                            errorBuilder: (context, error, stackTrace) {
                              return Center(
                                child: Icon(
                                  _categoryIcon(option.category),
                                  color: Colors.white38,
                                  size: 34,
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _categoryIcon(option.category),
                          color: Colors.white,
                          size: 22,
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            option.name,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Digital Travel Stamp earned! Open Rewards to view it.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Color(0xFFBAE6FD),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 15,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Row(
                  children: [
                    const Expanded(
                      child: _PuzzleVerifiedStat(
                        icon: Icons.check_circle_rounded,
                        value: 'Solved',
                        label: 'Mystery',
                      ),
                    ),
                    Container(
                      width: 1,
                      height: 48,
                      color: Colors.white12,
                    ),
                    const Expanded(
                      child: _PuzzleVerifiedStat(
                        icon: Icons.emoji_events_rounded,
                        value: 'Unlocked',
                        label: 'Stamp',
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: FilledButton.icon(
                  onPressed: () {
                    // Leave Puzzle FIRST (pops this route). Then also clear
                    // anything further back (e.g. Manage Profile / Game
                    // History, when this game was opened via "Continue Game"
                    // there rather than directly from Map) all the way down
                    // to the app's root Map screen, before pushing Rewards
                    // on top of it — so backing out of Rewards always lands
                    // on Map, no matter how this game was entered.
                    // navigator.context (the Navigator's own element) stays
                    // valid even after this widget's route is gone, unlike
                    // `context`.
                    final navigator = Navigator.of(context);
                    navigator.pop();
                    navigator.popUntil((route) => route.isFirst);
                    onRewards?.call(navigator.context);
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFFBBF24),
                    foregroundColor: const Color(0xFF03152E),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(17),
                    ),
                  ),
                  icon: const Icon(Icons.emoji_events_outlined),
                  label: const Text(
                    'View Reward',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: OutlinedButton.icon(
                  onPressed: () {
                    // Same reasoning as the View Reward button above: leave
                    // Puzzle first, then also clear anything further back
                    // (Manage Profile / Game History, when this game was
                    // opened via "Continue Game" there) all the way down to
                    // the app's root Map screen — so Home always lands on
                    // Map, no matter how this game was entered.
                    final navigator = Navigator.of(context);
                    navigator.pop();
                    navigator.popUntil((route) => route.isFirst);
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white30),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(17),
                    ),
                  ),
                  icon: const Icon(Icons.home_outlined, size: 18),
                  label: const Text('Home'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Stat cell for the Verified screen's checkpoint-style summary row — same
/// layout as Trip Path Quest's `_QuestCompleteStat`, kept as its own copy
/// since that one is private to trip_path_quest.dart.
class _PuzzleVerifiedStat extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;

  const _PuzzleVerifiedStat({
    required this.icon,
    required this.value,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, color: const Color(0xFF4ADE80), size: 22),
        const SizedBox(height: 5),
        Text(
          value,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white54, fontSize: 10.5),
        ),
      ],
    );
  }
}

class _ErrorScreen extends StatelessWidget {
  final MysteryPlacePuzzleGameViewModel vm;

  const _ErrorScreen({required this.vm});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF041428),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(26),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text('⚠️', style: TextStyle(fontSize: 70)),
              const SizedBox(height: 18),
              const Text(
                'Something went wrong',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                vm.errorMessage ?? 'Unknown error',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Color(0xFFC8D4E5),
                  fontSize: 14,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 18),
              ElevatedButton(
                onPressed: () => vm.loadNearbyPuzzleOptions(),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoBanner extends StatelessWidget {
  final String message;
  final VoidCallback onClose;

  const _InfoBanner({required this.message, required this.onClose});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFEFF6FF),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFBFDBFE)),
      ),
      child: Row(
        children: [
          const Text('ℹ️'),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: Color(0xFF0284C7),
                fontSize: 12,
                height: 1.35,
              ),
            ),
          ),
          GestureDetector(
            onTap: onClose,
            child: const Icon(Icons.close, size: 16, color: Color(0xFF0284C7)),
          ),
        ],
      ),
    );
  }
}

class _PuzzleImageTile extends StatelessWidget {
  final String imageUrl;
  final PuzzlePieceData piece;
  final int rows;
  final int cols;

  const _PuzzleImageTile({
    required this.imageUrl,
    required this.piece,
    required this.rows,
    required this.cols,
  });

  @override
  Widget build(BuildContext context) {
    final safeUrl = _cacheSafeUrl(imageUrl);

    return LayoutBuilder(
      builder: (context, constraints) {
        final tileWidth = constraints.maxWidth;
        final tileHeight = constraints.maxHeight;

        final fullWidth = tileWidth * cols;
        final fullHeight = tileHeight * rows;

        final row = piece.pieceId ~/ cols;
        final col = piece.pieceId % cols;

        return ClipRect(
          child: SizedBox(
            width: tileWidth,
            height: tileHeight,
            child: Stack(
              children: [
                Positioned(
                  left: -col * tileWidth,
                  top: -row * tileHeight,
                  child: SizedBox(
                    width: fullWidth,
                    height: fullHeight,
                    child: Image.network(
                      safeUrl,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      loadingBuilder: (context, child, loadingProgress) {
                        if (loadingProgress == null) return child;

                        return Container(
                          color: const Color(0xFF0B203A),
                          child: const Center(
                            child: CircularProgressIndicator(
                              color: Color(0xFF1FB1FF),
                              strokeWidth: 2,
                            ),
                          ),
                        );
                      },
                      errorBuilder: (context, error, stackTrace) {
                        return Container(
                          color: const Color(0xFF0B203A),
                          child: const Center(
                            child: Icon(
                              Icons.broken_image,
                              color: Colors.white,
                              size: 28,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}


String _cacheSafeUrl(String url) {
  if (url.isEmpty) return url;

  // Don't append a cache-buster to:
  //  - Places API (New) photos — it rejects unknown query params (HTTP 400);
  //  - picsum.photos — a fresh `cache` value returns a *different* random
  //    image, which would give the 9 puzzle tiles 9 mismatched pictures;
  //  - legacy Google photos — the reference already pins one image.
  if (url.contains('googleapis.com') || url.contains('picsum.photos')) {
    return url;
  }

  final separator = url.contains('?') ? '&' : '?';
  return '$url${separator}cache=${DateTime.now().millisecondsSinceEpoch}';
}

class _SafeNetworkImage extends StatelessWidget {
  final String imageUrl;
  final BoxFit fit;

  const _SafeNetworkImage({required this.imageUrl, this.fit = BoxFit.cover});

  @override
  Widget build(BuildContext context) {
    return Image.network(
      _cacheSafeUrl(imageUrl),
      fit: fit,
      gaplessPlayback: true,
      loadingBuilder: (context, child, loadingProgress) {
        if (loadingProgress == null) return child;

        return Container(
          color: const Color(0xFF0B203A),
          child: const Center(
            child: CircularProgressIndicator(
              color: Color(0xFF1FB1FF),
              strokeWidth: 2,
            ),
          ),
        );
      },
      errorBuilder: (context, error, stackTrace) {
        return Container(
          color: const Color(0xFF0B203A),
          child: const Center(
            child: Icon(
              Icons.broken_image,
              color: Colors.white,
              size: 32,
            ),
          ),
        );
      },
    );
  }
}
