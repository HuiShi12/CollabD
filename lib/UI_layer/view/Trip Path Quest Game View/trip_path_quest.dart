import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:provider/provider.dart';

import '../../../main.dart';
import '../../../Data_layer/repository/Trip Path Quest Repository/trip_path_quest_progress_repository.dart';
import '../../viewmodel/Trip Path Quest Game ViewModel/trip_path_quest_viewmodel.dart';
import 'trip_path_quest_verification.dart';

enum _SavedGameType { tripPath, puzzle }

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
      throw StateError('The game could not be deleted. It may already be completed or unavailable.');
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
  State<_DeleteSavedGameDialog> createState() => _DeleteSavedGameDialogState();
}

class _DeleteSavedGameDialogState extends State<_DeleteSavedGameDialog> {
  bool _busy = false;
  String? _error;

  Future<void> _delete() async {
    if (_busy) return;
    setState(() { _busy = true; _error = null; });
    try {
      await _SavedGameDeleteRepository().deleteUnfinishedGame(widget.type, widget.id);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Unable to delete this game. Check your connection and try again. Completed games cannot be deleted.';
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
            const Text('This permanently deletes this saved game and its progress. You cannot continue it afterward.'),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ],
        ),
        actions: [
          // A plain actions list lets Flutter's OverflowBar stack these
          // vertically once combined width doesn't fit — an explicit Row
          // instead keeps Cancel and Delete Game side by side always.
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                    foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  onPressed: _busy ? null : () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
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

class TripPathQuestView extends StatefulWidget {
  final TripPathQuestViewModel viewModel;
  final String? initialQuestId;

  // Optional hook for the real app shell. When Trip Path is pushed
  // as a route, the built-in fallback will Navigator.pop() back to
  // the previous Home/Map screen even when this callback is omitted.
  final VoidCallback? onExitQuest;

  /// Opens the Reward Dashboard from the Quest Complete screen.
  final void Function(BuildContext)? onRewards;

  const TripPathQuestView({
    super.key,
    required this.viewModel,
    this.initialQuestId,
    this.onExitQuest,
    this.onRewards,
  });

  @override
  State<TripPathQuestView> createState() =>
      _TripPathQuestViewState();
}

class _TripPathQuestViewState extends State<TripPathQuestView> {
  @override
  void initState() {
    super.initState();

    // Re-check when the Trip Path screen itself opens. This covers
    // apps where the ViewModel was created before the user logged in.
    final questId = widget.initialQuestId;
    unawaited(
      questId != null && questId.isNotEmpty
          ? widget.viewModel.continueQuestById(questId)
          : widget.viewModel.checkForSavedQuest(),
    );
  }

  Future<void> _handleExitQuest() async {
    await widget.viewModel.saveAndExitQuest();

    if (!mounted) {
      return;
    }

    final callback = widget.onExitQuest;

    if (callback != null) {
      callback();
      return;
    }

    final navigator = Navigator.of(context);

    if (navigator.canPop()) {
      navigator.pop();
    }
    // Standalone Trip Path test builds have no previous route. In that
    // case saveAndExitQuest() already returned to Theme Selection and
    // the saved-game prompt remains available.
  }

  @override
  Widget build(BuildContext context) {
    final viewModel = widget.viewModel;

    return AnimatedBuilder(
      animation: viewModel,
      builder: (context, child) {
        switch (viewModel.currentStage) {
          case TripPathQuestStage.themeSelection:
          // Saved games are checked before Theme Selection. This avoids
          // briefly showing themes and then covering them with a resume
          // dialog, and it supports any number of unfinished games.
            if (viewModel.isCheckingSavedQuest) {
              return const _SavedQuestLoadingPage();
            }

            if (viewModel.showResumePrompt) {
              return _SavedGamesPage(
                viewModel: viewModel,
              );
            }

            return _ThemeSelectionPage(
              viewModel: viewModel,
            );

          case TripPathQuestStage.questInformation:
            return _QuestInformationPage(
              viewModel: viewModel,
              onExitQuest: _handleExitQuest,
            );

          case TripPathQuestStage.artworkIntro:
            return _QuestArtworkIntroPage(
              viewModel: viewModel,
              onExitQuest: _handleExitQuest,
            );

          case TripPathQuestStage.clue:
            return _QuestCluePage(
              viewModel: viewModel,
              onExitQuest: _handleExitQuest,
            );

          case TripPathQuestStage.navigation:
            return _NavigationPage(
              viewModel: viewModel,
              onExitQuest: _handleExitQuest,
            );

          case TripPathQuestStage.verification:
          // Verify Your Visit is a light screen like Theme Selection/Quest
          // Information (not one of the fixed-navy immersive ones), so it
          // gets the same dark-aware override instead of the module's
          // pinned-light Theme. Wrapped here rather than inside the page's
          // own build() because it's a StatefulWidget whose dialogs/
          // snackbars are opened from State.context in methods outside
          // build() — those only see a Theme applied above this widget,
          // not one added inside its own subtree.
            return Theme(
              data: _darkAwareTripPathTheme(context),
              child: Builder(
                builder: (context) => TripPathQuestVerificationPage(
                  viewModel: viewModel,
                ),
              ),
            );

          case TripPathQuestStage.questComplete:
            return _QuestCompletePage(
              viewModel: viewModel,
              onExitQuest: _handleExitQuest,
              onRewards: widget.onRewards,
            );
        }
      },
    );
  }
}


// Guards against the dialog opening twice when a tap registers as a rapid
// double-tap — the "Save & Exit" button only disables once
// viewModel.isSavingAndExiting flips true, which happens well after the
// dialog is already showing, so a second tap in that window could otherwise
// call showDialog again and stack two identical confirmation dialogs.
bool _isConfirmingSaveAndExit = false;

Future<void> _confirmSaveAndExitQuest(
    BuildContext context,
    TripPathQuestViewModel viewModel,
    Future<void> Function() onExitQuest,
    ) async {
  if (viewModel.isSavingAndExiting || _isConfirmingSaveAndExit) {
    return;
  }
  _isConfirmingSaveAndExit = true;

  bool? shouldExit;
  try {
  shouldExit = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      return Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 32),
        child: Container(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 54,
                height: 54,
                decoration: const BoxDecoration(
                  color: Color(0xFFEAF4FF),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.save_rounded,
                  color: Color(0xFF087FF5),
                  size: 27,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Save & Exit Quest?',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF0F172A),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'Your progress (${viewModel.completedCheckpoints}/${viewModel.totalCheckpoints} checkpoints) will stay saved. '
                    'You can continue this same quest later.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 13.5,
                  color: Color(0xFF64748B),
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 22),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton.icon(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF087FF5),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  icon: const Icon(Icons.save_rounded, size: 18),
                  label: const Text(
                    'Save & Exit',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              SizedBox(
                width: double.infinity,
                height: 44,
                child: TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text(
                    'Stay',
                    style: TextStyle(
                      color: Color(0xFF64748B),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
  } finally {
    _isConfirmingSaveAndExit = false;
  }

  if (shouldExit != true) {
    return;
  }

  await onExitQuest();
}

// ============================================================
// THEME STYLE
// ============================================================

class _ThemeStyle {
  final Color color;
  final Color background;
  final IconData icon;

  const _ThemeStyle({
    required this.color,
    required this.background,
    required this.icon,
  });
}

_ThemeStyle _getThemeStyle(String themeId) {
  switch (themeId) {
    case 'food':
      return const _ThemeStyle(
        color: Color(0xFFEA580C),
        background: Color(0xFFFFF7ED),
        icon: Icons.restaurant_rounded,
      );

    case 'culture':
      return const _ThemeStyle(
        color: Color(0xFF7C3AED),
        background: Color(0xFFF5F3FF),
        icon: Icons.theater_comedy_rounded,
      );

    case 'heritage':
      return const _ThemeStyle(
        color: Color(0xFFB45309),
        background: Color(0xFFFFFBEB),
        icon: Icons.account_balance_rounded,
      );

    case 'nature':
      return const _ThemeStyle(
        color: Color(0xFF16A34A),
        background: Color(0xFFF0FDF4),
        icon: Icons.park_rounded,
      );

    default:
      return const _ThemeStyle(
        color: Color(0xFF0284C7),
        background: Color(0xFFF0F9FF),
        icon: Icons.route_rounded,
      );
  }
}

// ============================================================
// PHONE FRAME
// ============================================================

class _PhoneFrame extends StatelessWidget {
  final Widget child;

  /// Used by the pre-quest screens (resume prompt, theme selection, saved-
  /// quest loading): Trip Path's route is opaque:false, so the real Map
  /// screen stays visible underneath — this lets it show through instead of
  /// being covered by the frame's own solid colour.
  final bool transparentBackground;

  const _PhoneFrame({
    required this.child,
    this.transparentBackground = false,
  });

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: transparentBackground
          ? Colors.transparent
          : const Color(0xFF071426),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: 393,
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Drag handle for the pre-quest screens (resume prompt and theme selection).
/// They're styled as a bottom sheet (rounded top corners + a pill handle), so
/// dismissal is swipe-down-to-close on the handle — like a real bottom sheet —
/// rather than an on-screen back button. Reports the live drag to
/// [_DismissibleSheet], which is what actually moves the sheet.
/// Backdrop behind a Trip Path pre-quest sheet (Theme Selection, Continue
/// Your Quest) — tapping it dismisses the sheet the same way dragging it all
/// the way down does (back out to the Map screen this route was pushed
/// from). Matches Puzzle's _PuzzleScrimBarrier so both game modes behave the
/// same way when the tourist taps outside the sheet.
class _TripPathScrimBarrier extends StatelessWidget {
  const _TripPathScrimBarrier();

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.of(context).maybePop(),
      child: Container(color: Colors.black.withOpacity(0.45)),
    );
  }
}

class _SheetDragHandle extends StatelessWidget {
  const _SheetDragHandle({
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
        margin: const EdgeInsets.only(top: 12, bottom: 16),
        child: Container(
          width: 40,
          height: 5,
          decoration: BoxDecoration(
            color: const Color(0xFFE0E7EF),
            borderRadius: BorderRadius.circular(3),
          ),
        ),
      ),
    );
  }
}

/// Makes the swipe-down on [_SheetDragHandle] actually move the sheet: the
/// whole sheet tracks the finger 1:1 while dragging, then either eases back
/// to 0 or — past a distance/velocity threshold — slides the rest of the way
/// off-screen and pops the Trip Path route once that animation finishes.
class _DismissibleSheet extends StatefulWidget {
  const _DismissibleSheet({required this.builder});

  /// Builds the sheet, wiring [_SheetDragHandle]'s callbacks to the two
  /// arguments passed here.
  final Widget Function(
      BuildContext context,
      ValueChanged<double> onDragUpdate,
      ValueChanged<double> onDragEnd,
      ) builder;

  @override
  State<_DismissibleSheet> createState() => _DismissibleSheetState();
}

class _DismissibleSheetState extends State<_DismissibleSheet>
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

/// Read-only map tiles behind the pre-quest screens, centred on the tourist's
/// position (falls back to central Kuala Lumpur when it isn't known yet) — a
/// real map instead of a decorative icon, so it's visually clear this is
// ============================================================
// SAVED GAMES ENTRY
//
// This screen intentionally appears BEFORE Theme Selection whenever
// one or more in-progress quests exist. Each Supabase in_progress row
// gets its own card, so 2 saved games show 2 cards, etc.
// ============================================================

class _SavedQuestLoadingPage extends StatelessWidget {
  const _SavedQuestLoadingPage();

  @override
  Widget build(BuildContext context) {
    // Transparent so the real Map screen (still mounted behind Trip Path's
    // opaque:false route) shows through — otherwise this brief loading beat
    // would flash a solid colour that breaks the "still the same map" effect
    // the moment the tourist taps in.
    //
    // Shaped like the actual bottom sheet (white rounded card anchored at
    // the bottom, same pill) rather than a full-screen spinner: the
    // slide-up-from-bottom route transition animates whatever's on screen
    // during this ~1-request beat, so if this didn't already look like the
    // sheet, the real slide-up motion read as happening on the wrong thing
    // and the resume/theme sheet would just snap in once checking finished.
    return Theme(
      data: _darkAwareTripPathTheme(context),
      child: Builder(
        builder: (context) => _PhoneFrame(
      transparentBackground: true,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: [
            const Positioned.fill(
              child: _TripPathScrimBarrier(),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: SafeArea(
                top: false,
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
                      Container(
                        width: 40,
                        height: 5,
                        margin: const EdgeInsets.only(top: 12, bottom: 16),
                        decoration: BoxDecoration(
                          color: context.colors.outlineVariant,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
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
                              'Checking saved quests...',
                              style: TextStyle(
                                color: context.colors.onSurface,
                                fontSize: 14,
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
            ),
          ],
        ),
      ),
        ),
      ),
    );
  }
}

// Trip Path's screens are pinned to AppTheme.light() at the module root
// (see TripPathQuestModule) since most of them use raw hardcoded light
// colors. The saved-quest check and its resume sheet are the exception —
// they mirror Puzzle's own equivalent screens closely enough that they
// should follow the same light/dark choice, so this re-reads the app's
// real theme mode instead of trusting the pinned-light ambient Theme.
ThemeData _darkAwareTripPathTheme(BuildContext context) {
  final mode = context.watch<ThemeController>().mode;
  final platformBrightness = MediaQuery.platformBrightnessOf(context);
  final isDark = mode == ThemeMode.dark ||
      (mode == ThemeMode.system && platformBrightness == Brightness.dark);
  return isDark ? AppTheme.dark() : AppTheme.light();
}

class _SavedGamesPage extends StatefulWidget {
  final TripPathQuestViewModel viewModel;

  const _SavedGamesPage({
    required this.viewModel,
  });

  @override
  State<_SavedGamesPage> createState() => _SavedGamesPageState();
}

class _SavedGamesPageState extends State<_SavedGamesPage> {
  // Remove cards only after the database confirms deletion.
  final Set<String> _deletedIds = {};

  @override
  Widget build(BuildContext context) {
    final viewModel = widget.viewModel;
    final savedGames = viewModel.savedQuests;
    final visibleGames = savedGames
        .where((g) => !_deletedIds.contains(g.id))
        .toList();
    // Leaves more of the real Map screen visible above the sheet instead of
    // covering almost the whole screen.
    final maxSheetHeight = MediaQuery.of(context).size.height * 0.72;

    // Transparent: Trip Path's route is opaque:false, so the real Map screen
    // shows through here exactly as the tourist left it, instead of a
    // recreated lookalike — only the scrim below is Trip Path's own.
    return Theme(
      data: _darkAwareTripPathTheme(context),
      child: Builder(
        builder: (context) => _PhoneFrame(
      transparentBackground: true,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: [
            const Positioned.fill(
              child: _TripPathScrimBarrier(),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: _DismissibleSheet(
                builder: (context, onDragUpdate, onDragEnd) => SafeArea(
                  top: false,
                  child: Container(
                    width: double.infinity,
                    constraints: BoxConstraints(
                      maxHeight: maxSheetHeight,
                    ),
                    decoration: BoxDecoration(
                      color: context.colors.surface,
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(28),
                      ),
                    ),
                    // The handle lives outside the ScrollView so it stays
                    // pinned and visible whether the tourist is scrolling the
                    // saved-quest list or dragging the sheet down to dismiss.
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _SheetDragHandle(
                          onDragUpdate: onDragUpdate,
                          onDragEnd: onDragEnd,
                        ),
                        Flexible(
                          child: SingleChildScrollView(
                            physics: const BouncingScrollPhysics(),
                            padding: const EdgeInsets.only(bottom: 28),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 18,
                                  ),
                                  // Swapped with the header below: it's the
                                  // one action always available, ahead of
                                  // "Continue Your Quest" and the resumable
                                  // games under it.
                                  child: _StartNewQuestCard(
                                    enabled: !viewModel.isResumingQuest,
                                    onTap: () {
                                      unawaited(
                                        viewModel
                                            .startNewGameFromSavedQuest(),
                                      );
                                    },
                                  ),
                                ),
                                const SizedBox(height: 20),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 18,
                                  ),
                                  child: Row(
                                    children: [
                                      Container(
                                        width: 54,
                                        height: 54,
                                        decoration: BoxDecoration(
                                          gradient: const LinearGradient(
                                            begin: Alignment.topLeft,
                                            end: Alignment.bottomRight,
                                            colors: [
                                              Color(0xFF0EA5E9),
                                              Color(0xFF0284C7),
                                            ],
                                          ),
                                          borderRadius:
                                          BorderRadius.circular(15),
                                        ),
                                        child: const Icon(
                                          Icons.play_circle_fill_rounded,
                                          color: Colors.white,
                                          size: 29,
                                        ),
                                      ),
                                      const SizedBox(width: 13),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              'Continue Your Quest',
                                              style: TextStyle(
                                                fontSize: 20,
                                                height: 1.15,
                                                fontWeight: FontWeight.w800,
                                                color: context.colors.onSurface,
                                              ),
                                            ),
                                            const SizedBox(height: 5),
                                            Text(
                                              visibleGames.length == 1
                                                  ? 'You have 1 unfinished game.'
                                                  : 'You have ${visibleGames.length} unfinished games.',
                                              style: TextStyle(
                                                fontSize: 12.5,
                                                color: context.colors.onSurfaceVariant,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                if (visibleGames.isNotEmpty)
                                  const SizedBox(height: 14),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 18,
                                  ),
                                  child: Column(
                                    children: [
                                      for (var index = 0;
                                      index < visibleGames.length;
                                      index++) ...[
                                        Dismissible(
                                          key: ValueKey(
                                            'saved-quest-${visibleGames[index].id}',
                                          ),
                                          direction: viewModel.isResumingQuest
                                              ? DismissDirection.none
                                              : DismissDirection.horizontal,
                                          confirmDismiss: (_) => _confirmSavedGameDeletion(
                                            context,
                                            type: _SavedGameType.tripPath,
                                            id: visibleGames[index].id,
                                          ),
                                          background: const _DeleteCardBackground(
                                            alignment: Alignment.centerLeft,
                                          ),
                                          secondaryBackground:
                                          const _DeleteCardBackground(
                                            alignment: Alignment.centerRight,
                                          ),
                                          onDismissed: (_) => setState(() {
                                            _deletedIds
                                                .add(visibleGames[index].id);
                                          }),
                                          child: _SavedGameCard(
                                            viewModel: viewModel,
                                            saved: visibleGames[index],
                                          ),
                                        ),
                                        if (index != visibleGames.length - 1)
                                          const SizedBox(height: 13),
                                      ],
                                      if (viewModel.resumeGameError !=
                                          null) ...[
                                        const SizedBox(height: 12),
                                        Container(
                                          width: double.infinity,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 14,
                                            vertical: 11,
                                          ),
                                          decoration: BoxDecoration(
                                            color: context.colors.errorContainer,
                                            borderRadius:
                                            BorderRadius.circular(14),
                                            border: Border.all(
                                              color: context.colors.error.withValues(alpha: 0.4),
                                            ),
                                          ),
                                          child: Text(
                                            viewModel.resumeGameError!,
                                            textAlign: TextAlign.center,
                                            style: TextStyle(
                                              color: context.colors.onErrorContainer,
                                              fontSize: 11.5,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ],
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
            ),
          ],
        ),
      ),
        ),
      ),
    );
  }
}

/// Delete action revealed while swiping a saved quest.
class _DeleteCardBackground extends StatelessWidget {
  const _DeleteCardBackground({required this.alignment});

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
            style: TextStyle(
              color: context.colors.onSurfaceVariant,
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _StartNewQuestCard extends StatelessWidget {
  final bool enabled;
  final VoidCallback onTap;

  const _StartNewQuestCard({
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.55,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: enabled ? onTap : null,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 15,
          ),
          decoration: BoxDecoration(
            color: context.colors.primaryContainer,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: context.colors.primary.withValues(alpha: 0.35),
              width: 1.5,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: context.colors.primary.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.add_rounded,
                  color: context.colors.primary,
                  size: 28,
                ),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Start New Quest',
                      style: TextStyle(
                        color: context.colors.onPrimaryContainer,
                        fontSize: 15.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Choose another theme. Your unfinished games stay saved.',
                      style: TextStyle(
                        color: context.colors.onPrimaryContainer.withValues(alpha: 0.8),
                        fontSize: 11.5,
                        height: 1.25,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.arrow_forward_ios_rounded,
                size: 16,
                color: context.colors.primary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SavedGameCard extends StatelessWidget {
  final TripPathQuestViewModel viewModel;
  final SavedTripPathQuest saved;

  const _SavedGameCard({
    required this.viewModel,
    required this.saved,
  });

  @override
  Widget build(BuildContext context) {
    final style = _getThemeStyle(saved.themeId);
    final total = saved.totalCheckpoints <= 0
        ? 3
        : saved.totalCheckpoints;
    final completed = saved.completedCheckpoints
        .clamp(0, total)
        .toInt();
    final progress = (completed / total).clamp(0.0, 1.0).toDouble();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: context.colors.outlineVariant,
          width: 1.3,
        ),
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
                decoration: BoxDecoration(
                  color: style.color.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  style.icon,
                  color: style.color,
                  size: 26,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${saved.themeName} Quest',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: context.colors.onSurface,
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Next: Checkpoint ${saved.currentCheckpoint}  •  '
                          '${viewModel.savedQuestLastPlayedTextFor(saved)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: context.colors.onSurfaceVariant,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
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
              Text(
                'Quest progress',
                style: TextStyle(
                  color: context.colors.onSurfaceVariant,
                  fontSize: 11.8,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                '$completed / $total checkpoints',
                style: TextStyle(
                  color: context.colors.onSurface,
                  fontSize: 11.8,
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
              valueColor: AlwaysStoppedAnimation<Color>(
                style.color,
              ),
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            height: 46,
            child: FilledButton.icon(
              onPressed: viewModel.isResumingQuest
                  ? null
                  : () {
                unawaited(
                  viewModel.continuePreviousGame(saved),
                );
              },
              icon: viewModel.isResumingQuest
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
                viewModel.isResumingQuest
                    ? 'Loading…'
                    : 'Continue Game',
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: style.color,
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

// ============================================================
// PAGE 1
// THEME SELECTION
// ============================================================

class _ThemeSelectionPage extends StatelessWidget {
  final TripPathQuestViewModel viewModel;

  const _ThemeSelectionPage({
    required this.viewModel,
  });

  @override
  Widget build(BuildContext context) {
    // Transparent: Trip Path's route is opaque:false, so the real Map screen
    // shows through here exactly as the tourist left it, instead of a
    // recreated lookalike — only the scrim below is Trip Path's own.
    //
    // Wrapped in the same dark-aware Theme as the saved-quest screens (see
    // _darkAwareTripPathTheme) instead of trusting the module-level pinned-
    // light Theme, so this sheet follows the app's actual light/dark/system
    // choice.
    return Theme(
      data: _darkAwareTripPathTheme(context),
      child: Builder(
        builder: (context) => _PhoneFrame(
      transparentBackground: true,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: [
            const Positioned.fill(
              child: _TripPathScrimBarrier(),
            ),

            Align(
              alignment: Alignment.bottomCenter,
              child: _DismissibleSheet(
                builder: (context, onDragUpdate, onDragEnd) => Container(
                  width: double.infinity,
                  padding: const EdgeInsets.only(
                    bottom: 32,
                  ),
                  decoration: BoxDecoration(
                    color: context.colors.surface,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(28),
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _SheetDragHandle(
                        onDragUpdate: onDragUpdate,
                        onDragEnd: onDragEnd,
                      ),

                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                        ),
                        child: Column(
                          children: [
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
                                        Color(0xFF0EA5E9),
                                        Color(0xFF0284C7),
                                      ],
                                    ),
                                    borderRadius:
                                    BorderRadius.circular(
                                      15,
                                    ),
                                  ),
                                  child: const Icon(
                                    Icons.route_rounded,
                                    color: Colors.white,
                                    size: 29,
                                  ),
                                ),

                                const SizedBox(
                                  width: 13,
                                ),

                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Nearby Trip Path Quests',
                                        style: TextStyle(
                                          fontSize: 20,
                                          height: 1.15,
                                          fontWeight:
                                          FontWeight.w800,
                                          color:
                                          context.colors.onSurface,
                                        ),
                                      ),
                                      const SizedBox(
                                        height: 5,
                                      ),
                                      Text(
                                        'Choose an available quest theme',
                                        style: TextStyle(
                                          fontSize: 12.5,
                                          color:
                                          context.colors.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),

                            const SizedBox(
                              height: 20,
                            ),

                            GridView.builder(
                              shrinkWrap: true,
                              physics:
                              const NeverScrollableScrollPhysics(),
                              itemCount:
                              viewModel.availableThemes.length,
                              gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 2,
                                crossAxisSpacing: 12,
                                mainAxisSpacing: 12,
                                mainAxisExtent: 184,
                              ),
                              itemBuilder: (
                                  context,
                                  index,
                                  ) {
                                final theme =
                                viewModel.availableThemes[index];

                                final style =
                                _getThemeStyle(theme.id);

                                return InkWell(
                                  borderRadius:
                                  BorderRadius.circular(
                                    20,
                                  ),
                                  onTap: () {
                                    viewModel.selectTheme(
                                      theme,
                                    );
                                  },
                                  child: Container(
                                    padding:
                                    const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 10,
                                    ),
                                    decoration: BoxDecoration(
                                      // The pastel tint reads well on a light
                                      // sheet but washes out against a dark
                                      // one — fall back to a translucent tint
                                      // of the same brand accent instead.
                                      color: context.isDark
                                          ? style.color.withOpacity(0.16)
                                          : style.background,
                                      borderRadius:
                                      BorderRadius.circular(
                                        20,
                                      ),
                                      border: Border.all(
                                        color:
                                        style.color.withOpacity(
                                          0.22,
                                        ),
                                        width: 1.5,
                                      ),
                                    ),
                                    child: Column(
                                      mainAxisAlignment:
                                      MainAxisAlignment.center,
                                      children: [
                                        Container(
                                          width: 50,
                                          height: 50,
                                          decoration:
                                          BoxDecoration(
                                            color: style.color
                                                .withOpacity(
                                              0.10,
                                            ),
                                            shape:
                                            BoxShape.circle,
                                          ),
                                          child: Icon(
                                            style.icon,
                                            size: 28,
                                            color: style.color,
                                          ),
                                        ),

                                        const SizedBox(
                                          height: 10,
                                        ),

                                        Text(
                                          '${theme.name} Quest',
                                          textAlign:
                                          TextAlign.center,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 15,
                                            fontWeight:
                                            FontWeight.w800,
                                            color: style.color,
                                          ),
                                        ),

                                        const SizedBox(
                                          height: 7,
                                        ),

                                        Text(
                                          theme.area,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          textAlign: TextAlign.center,
                                          style:
                                          TextStyle(
                                            color:
                                            context.colors.onSurfaceVariant,
                                            fontSize: 11.5,
                                          ),
                                        ),

                                        const SizedBox(
                                          height: 7,
                                        ),

                                        Text(
                                          'FIXED THEME',
                                          style: TextStyle(
                                            color: style.color,
                                            fontSize: 9.5,
                                            fontWeight:
                                            FontWeight.w800,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
        ),
      ),
    );
  }
}

// ============================================================
// PAGE 2
// QUEST INFORMATION
// ============================================================

/// Confirms before leaving Quest Information — same "Leave" pattern Puzzle
/// uses on its own pre-quest/in-quest screens. [onConfirmed] is whatever
/// back actually does here: fully exiting the quest (marker entry) or
/// returning to Theme Selection (normal browse entry).
///
/// Guards against the dialog opening twice when the back button/gesture
/// registers as a rapid double-tap — nothing else here disables the button
/// while the dialog is showing.
bool _isConfirmingExitQuest = false;

Future<void> _confirmExitQuest(
  BuildContext context,
  Future<void> Function() onConfirmed,
) async {
  if (_isConfirmingExitQuest) {
    return;
  }
  _isConfirmingExitQuest = true;

  final bool? leave;
  try {
  leave = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Leave this quest?'),
      content: const Text(
        'You have not started this quest yet. You can come back and start '
        'it anytime.',
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
                  backgroundColor: context.colors.primary,
                  foregroundColor: context.colors.onPrimary,
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
  } finally {
    _isConfirmingExitQuest = false;
  }

  if (leave == true) {
    await onConfirmed();
  }
}

class _QuestInformationPage extends StatelessWidget {
  final TripPathQuestViewModel viewModel;
  final Future<void> Function() onExitQuest;

  const _QuestInformationPage({
    required this.viewModel,
    required this.onExitQuest,
  });

  @override
  Widget build(BuildContext context) {
    final theme = viewModel.selectedTheme!;

    final style = _getThemeStyle(
      theme.id,
    );

    // Wrapped in the same dark-aware Theme as the saved-quest screens (see
    // _darkAwareTripPathTheme) instead of trusting the module-level pinned-
    // light Theme, so this screen follows the app's actual light/dark/system
    // choice. backAction/the dialog it opens are built with the inner
    // Builder's context so showDialog captures this same Theme.
    return Theme(
      data: _darkAwareTripPathTheme(context),
      child: Builder(
        builder: (context) {
          // A marker-specific entry never showed Theme Selection, so
          // viewModel.goBack()'s normal "return to Theme Selection" would
          // surface a browse screen the tourist never opened. Leave the
          // quest entirely instead — see selectTheme(fromMarker:). Either
          // way, confirm first.
          final Future<void> Function() onConfirmedBack =
              viewModel.shouldExitOnQuestInfoBack
                  ? onExitQuest
                  : () async => viewModel.goBack();

          final VoidCallback backAction =
              () => unawaited(_confirmExitQuest(context, onConfirmedBack));

          return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) backAction();
      },
      child: _PhoneFrame(
      child: Scaffold(
        backgroundColor: context.colors.surface,
        appBar: AppBar(
          backgroundColor: context.colors.surface,
          elevation: 0,
          centerTitle: true,
          leading: IconButton(
            onPressed: backAction,
            icon: const Icon(
              Icons.arrow_back_ios_new_rounded,
            ),
          ),
          title: Text(
            'Quest Information',
            style: TextStyle(
              color: context.colors.onSurface,
              fontSize: 17,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            20,
            8,
            20,
            30,
          ),
          child: Column(
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(
                  20,
                ),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      style.color,
                      style.color.withOpacity(
                        0.78,
                      ),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(
                    20,
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 62,
                      height: 62,
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(
                          0.15,
                        ),
                        borderRadius:
                        BorderRadius.circular(
                          18,
                        ),
                      ),
                      child: Icon(
                        style.icon,
                        color: Colors.white,
                        size: 36,
                      ),
                    ),

                    const SizedBox(
                      width: 14,
                    ),

                    Expanded(
                      child: Column(
                        crossAxisAlignment:
                        CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${theme.name} Quest',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 22,
                              fontWeight:
                              FontWeight.w800,
                            ),
                          ),

                          const SizedBox(
                            height: 4,
                          ),

                          Text(
                            'Trip Path Quest · ${theme.area}',
                            style: const TextStyle(
                              color:
                              Color(0xCCFFFFFF),
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(
                height: 16,
              ),

              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(
                  16,
                ),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color(0xFF03152E),
                      Color(0xFF0A2A52),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(
                    18,
                  ),
                ),
                child: const Row(
                  children: [
                    Icon(
                      Icons.palette_rounded,
                      color: Color(0xFF38BDF8),
                      size: 36,
                    ),

                    SizedBox(
                      width: 14,
                    ),

                    Expanded(
                      child: Column(
                        crossAxisAlignment:
                        CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Quest Artwork Reward',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight:
                              FontWeight.w700,
                            ),
                          ),
                          SizedBox(
                            height: 3,
                          ),
                          Text(
                            'Complete all 3 checkpoints to reveal your Theme Souvenir.',
                            style: TextStyle(
                              color:
                              Color(0xFF7DD3FC),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(
                height: 16,
              ),

              _InformationCard(
                title: 'Quest Details',
                child: Column(
                  children: [
                    const _DetailRow(
                      label: 'Checkpoints',
                      value: '3 locations',
                    ),
                    _DetailRow(
                      label: 'Theme',
                      value: theme.name,
                    ),
                    _DetailRow(
                      label: 'Area',
                      value: theme.area,
                    ),
                    const _DetailRow(
                      label: 'Reward',
                      value: 'Theme Souvenir',
                      showBorder: false,
                    ),
                  ],
                ),
              ),

              const SizedBox(
                height: 14,
              ),

              _InformationCard(
                title: 'Checkpoints',
                child: Column(
                  children: List.generate(
                    3,
                        (index) {
                      return _MysteryCheckpointRow(
                        number: index + 1,
                        theme: theme.name,
                        area: theme.area,
                        showBorder: index != 2,
                      );
                    },
                  ),
                ),
              ),

              const SizedBox(
                height: 14,
              ),

              const _InformationCard(
                title: 'How It Works',
                child: Column(
                  children: [
                    _RuleRow(
                      icon:
                      Icons.lightbulb_outline_rounded,
                      text:
                      'Follow the clues to discover each mystery checkpoint.',
                    ),
                    _RuleRow(
                      icon:
                      Icons.help_outline_rounded,
                      text:
                      'Up to 3 clues are available for each checkpoint.',
                    ),
                    _RuleRow(
                      icon:
                      Icons.location_on_outlined,
                      text:
                      'Reach within 50 m of the checkpoint to enable Verify Visit.',
                    ),
                    _RuleRow(
                      icon:
                      Icons.camera_alt_outlined,
                      text:
                      'Take a landmark photo and submit it for verification.',
                    ),
                    _RuleRow(
                      icon:
                      Icons.emoji_events_outlined,
                      text:
                      'Complete all 3 checkpoints to receive the Theme Souvenir.',
                      showBottomSpace: false,
                    ),
                  ],
                ),
              ),

              const SizedBox(
                height: 20,
              ),

              if (!viewModel.isPreparingQuestLocations &&
                  viewModel.questLocationError != null) ...[
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(
                    bottom: 12,
                  ),
                  padding: const EdgeInsets.all(
                    14,
                  ),
                  decoration: BoxDecoration(
                    color: context.appColors.warningSurface,
                    borderRadius: BorderRadius.circular(
                      14,
                    ),
                    border: Border.all(
                      color: context.appColors.warning.withValues(alpha: 0.45),
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment:
                    CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.error_outline_rounded,
                        color: context.appColors.warning,
                        size: 22,
                      ),
                      const SizedBox(
                        width: 10,
                      ),
                      Expanded(
                        child: Text(
                          viewModel.questLocationError!,
                          style: TextStyle(
                            color: context.colors.onSurface,
                            fontSize: 12,
                            fontWeight:
                            FontWeight.w600,
                            height: 1.35,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              SizedBox(
                width: double.infinity,
                height: 54,
                child: FilledButton.icon(
                  onPressed:
                  viewModel.isPreparingQuestLocations
                      ? null
                      : viewModel.startQuest,
                  style: FilledButton.styleFrom(
                    backgroundColor:
                    context.colors.primary,
                    foregroundColor: context.colors.onPrimary,
                    disabledBackgroundColor:
                    context.colors.primary.withValues(alpha: 0.4),
                    disabledForegroundColor:
                    context.colors.onPrimary,
                    shape: RoundedRectangleBorder(
                      borderRadius:
                      BorderRadius.circular(
                        16,
                      ),
                    ),
                  ),
                  icon: viewModel.isPreparingQuestLocations
                      ? SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      valueColor:
                      AlwaysStoppedAnimation<Color>(
                        context.colors.onPrimary,
                      ),
                    ),
                  )
                      : const Icon(
                    Icons.rocket_launch_rounded,
                  ),
                  label: Text(
                    viewModel.isPreparingQuestLocations
                        ? 'Preparing Quest...'
                        : viewModel.questLocationError != null
                        ? 'Try Again'
                        : 'Start Quest',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight:
                      FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      ),
    );
        },
      ),
    );
  }
}

// ============================================================
// PAGE 3
// QUEST ARTWORK INTRO
// ============================================================

class _QuestArtworkIntroPage extends StatelessWidget {
  final TripPathQuestViewModel viewModel;
  final Future<void> Function() onExitQuest;

  const _QuestArtworkIntroPage({
    required this.viewModel,
    required this.onExitQuest,
  });

  @override
  Widget build(BuildContext context) {
    final theme = viewModel.selectedTheme!;
    final style = _getThemeStyle(theme.id);
    final questCompleted = viewModel.isQuestCompleted;
    final currentCheckpointReady =
        viewModel.isCurrentCheckpointReady;
    final waitingForCheckpoint =
        !questCompleted && !currentCheckpointReady;
    final checkpointPreparationError =
        viewModel.remainingCheckpointPreparationError;

    return _PhoneFrame(
      child: Scaffold(
        backgroundColor: const Color(0xFF03152E),
        appBar: AppBar(
          backgroundColor: const Color(0xFF03152E),
          foregroundColor: Colors.white,
          elevation: 0,
          centerTitle: true,
          leading: IconButton(
            onPressed: viewModel.goBack,
            icon: const Icon(
              Icons.arrow_back_ios_new_rounded,
            ),
          ),
          title: const Text(
            'Quest Artwork',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 17,
            ),
          ),
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            20,
            12,
            20,
            32,
          ),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: style.color.withOpacity(0.20),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      style.icon,
                      color: Colors.white,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${theme.name} Quest',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 18),

              Text(
                questCompleted
                    ? 'Quest Artwork Restored!'
                    : 'Restore Your Quest Artwork',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                ),
              ),

              const SizedBox(height: 8),

              Text(
                questCompleted
                    ? 'All 3 checkpoints are complete. Your souvenir artwork is now fully restored.'
                    : 'Complete all 3 checkpoints to restore the full colour of your souvenir artwork.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Color(0xFF7DD3FC),
                  fontSize: 14,
                  height: 1.5,
                ),
              ),

              const SizedBox(height: 26),

              _QuestArtwork(
                themeStyle: style,
                completed: viewModel.completedCheckpoints,
                imageUrl: viewModel.artworkImageUrl,
              ),

              const SizedBox(height: 22),

              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.07),
                  borderRadius: BorderRadius.circular(18),
                  border: questCompleted
                      ? Border.all(
                    color: const Color(0x55F59E0B),
                  )
                      : null,
                ),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          questCompleted
                              ? 'Quest Completed'
                              : 'Quest Progress',
                          style: const TextStyle(
                            color: Colors.white60,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          '${viewModel.completedCheckpoints} / ${viewModel.totalCheckpoints}',
                          style: TextStyle(
                            color: questCompleted
                                ? const Color(0xFF4ADE80)
                                : const Color(0xFFF59E0B),
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 12),

                    _ArtworkProgressRow(
                      number: 1,
                      section: 'puzzle piece 1',
                      completed: viewModel.completedCheckpoints >= 1,
                    ),
                    _ArtworkProgressRow(
                      number: 2,
                      section: 'puzzle piece 2',
                      completed: viewModel.completedCheckpoints >= 2,
                    ),
                    _ArtworkProgressRow(
                      number: 3,
                      section: 'puzzle piece 3',
                      completed: viewModel.completedCheckpoints >= 3,
                      showBorder: false,
                    ),
                  ],
                ),
              ),

              if (questCompleted) ...[
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0x1AF59E0B),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: const Color(0x55F59E0B),
                    ),
                  ),
                  child: const Row(
                    children: [
                      Icon(
                        Icons.emoji_events_rounded,
                        color: Color(0xFFFBBF24),
                        size: 26,
                      ),
                      SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Theme Souvenir Unlocked',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              'View your completed quest reward.',
                              style: TextStyle(
                                color: Color(0xFFBAE6FD),
                                fontSize: 11.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 22),

              if (waitingForCheckpoint &&
                  checkpointPreparationError != null) ...[
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(
                    bottom: 12,
                  ),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0x22F59E0B),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: const Color(0x66F59E0B),
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment:
                    CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.error_outline_rounded,
                        color: Color(0xFFFBBF24),
                        size: 22,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          checkpointPreparationError,
                          style: const TextStyle(
                            color: Color(0xFFFDE68A),
                            fontSize: 12,
                            height: 1.35,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              SizedBox(
                width: double.infinity,
                height: 54,
                child: FilledButton.icon(
                  onPressed: questCompleted
                      ? viewModel.viewQuestReward
                      : waitingForCheckpoint
                      ? (viewModel.isPreparingRemainingCheckpoints
                      ? null
                      : () {
                    unawaited(
                      viewModel
                          .retryPrepareRemainingCheckpoints(),
                    );
                  })
                      : viewModel.beginCheckpoint,
                  style: FilledButton.styleFrom(
                    backgroundColor: questCompleted
                        ? const Color(0xFFF59E0B)
                        : const Color(0xFF0284C7),
                    foregroundColor: questCompleted
                        ? const Color(0xFF0F172A)
                        : Colors.white,
                    disabledBackgroundColor:
                    const Color(0xFF0369A1),
                    disabledForegroundColor:
                    const Color(0xFFBAE6FD),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  icon: waitingForCheckpoint &&
                      viewModel.isPreparingRemainingCheckpoints
                      ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      valueColor:
                      AlwaysStoppedAnimation<Color>(
                        Colors.white,
                      ),
                    ),
                  )
                      : Icon(
                    questCompleted
                        ? Icons.emoji_events_rounded
                        : waitingForCheckpoint
                        ? Icons.refresh_rounded
                        : Icons.explore_rounded,
                  ),
                  label: Text(
                    questCompleted
                        ? 'View Quest Reward'
                        : waitingForCheckpoint
                        ? (viewModel.isPreparingRemainingCheckpoints
                        ? 'Preparing Checkpoint ${viewModel.currentCheckpoint}...'
                        : 'Try Preparing Checkpoint ${viewModel.currentCheckpoint} Again')
                        : 'Begin Checkpoint ${viewModel.currentCheckpoint}',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),

              // Real progress for whichever checkpoint is still preparing in
              // the background, instead of a static "Preparing..." label for
              // however long that search takes.
              if (waitingForCheckpoint &&
                  viewModel.isPreparingRemainingCheckpoints &&
                  viewModel.questPreparationStatus != null) ...[
                const SizedBox(height: 8),
                Text(
                  viewModel.questPreparationStatus!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFF7DD3FC),
                    fontSize: 11.5,
                  ),
                ),
              ],

              if (!questCompleted) ...[
                const SizedBox(height: 12),
                _SaveAndExitQuestButton(
                  viewModel: viewModel,
                  onExitQuest: onExitQuest,
                  darkBackground: true,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================
// QUEST COMPLETE / LOCAL REWARD
// ============================================================

class _QuestCompletePage extends StatelessWidget {
  final TripPathQuestViewModel viewModel;
  final Future<void> Function()? onExitQuest;
  final void Function(BuildContext)? onRewards;

  const _QuestCompletePage({
    required this.viewModel,
    this.onExitQuest,
    this.onRewards,
  });

  @override
  Widget build(BuildContext context) {
    final theme = viewModel.selectedTheme!;
    final style = _getThemeStyle(theme.id);

    return _PhoneFrame(
      child: Scaffold(
        backgroundColor: const Color(0xFF03152E),
        appBar: AppBar(
          backgroundColor: const Color(0xFF03152E),
          foregroundColor: Colors.white,
          elevation: 0,
          centerTitle: true,
          leading: IconButton(
            onPressed: viewModel.goBack,
            icon: const Icon(
              Icons.arrow_back_ios_new_rounded,
            ),
          ),
          title: const Text(
            'Quest Complete',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
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
                'Quest Complete!',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                ),
              ),

              const SizedBox(height: 6),

              Text(
                'You completed the ${theme.name} Quest',
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
                      style.color.withOpacity(0.30),
                      const Color(0xFF0A2A52),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: style.color.withOpacity(0.45),
                  ),
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
                        'THEME SOUVENIR',
                        style: TextStyle(
                          color: Color(0xFFFDE68A),
                          fontSize: 10.5,
                          letterSpacing: 1.2,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),

                    const SizedBox(height: 18),

                    _QuestArtwork(
                      themeStyle: style,
                      completed: viewModel.totalCheckpoints,
                      imageUrl: viewModel.artworkImageUrl,
                    ),

                    const SizedBox(height: 18),

                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          style.icon,
                          color: Colors.white,
                          size: 22,
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            '${theme.name} Quest Souvenir',
                            textAlign: TextAlign.center,
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
                      'Unlocked by completing all checkpoints.',
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
                  color: Colors.white.withOpacity(0.07),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Row(
                  children: [
                    const Expanded(
                      child: _QuestCompleteStat(
                        icon: Icons.check_circle_rounded,
                        value: '3 / 3',
                        label: 'Checkpoints',
                      ),
                    ),
                    Container(
                      width: 1,
                      height: 48,
                      color: Colors.white12,
                    ),
                    const Expanded(
                      child: _QuestCompleteStat(
                        icon: Icons.emoji_events_rounded,
                        value: 'Unlocked',
                        label: 'Souvenir',
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
                  onPressed: onRewards == null
                      ? null
                      : () async {
                          // Leave the finished quest FIRST (saves + pops the
                          // Trip Path route itself). Then also clear anything
                          // further back (e.g. Manage Profile / Game History,
                          // when this quest was opened via "Continue Game"
                          // there rather than directly from Map) all the way
                          // down to the app's root Map screen, before
                          // pushing Rewards on top of it — so backing out of
                          // Rewards always lands on Map, no matter how this
                          // quest was entered. navigator.context (the
                          // Navigator's own element) stays valid even after
                          // this widget's route is gone, unlike `context`.
                          final navigator = Navigator.of(context);
                          await onExitQuest?.call();
                          navigator.popUntil((route) => route.isFirst);
                          onRewards!(navigator.context);
                        },
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFFBBF24),
                    foregroundColor: const Color(0xFF03152E),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(17),
                    ),
                  ),
                  icon: const Icon(
                    Icons.emoji_events_outlined,
                  ),
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
                  onPressed: onExitQuest == null
                      ? null
                      : () async {
                          // Same reasoning as the View Reward button above:
                          // leave the quest first (saves + pops the Trip
                          // Path route itself), then also clear anything
                          // further back (Manage Profile / Game History,
                          // when this quest was opened via "Continue Game"
                          // there) all the way down to the app's root Map
                          // screen — so Home always lands on Map, no matter
                          // how this quest was entered.
                          final navigator = Navigator.of(context);
                          await onExitQuest!();
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

              const SizedBox(height: 10),

              const Text(
                'Quest completion and artwork progress are saved to Supabase.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white38,
                  fontSize: 10.5,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QuestCompleteStat extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;

  const _QuestCompleteStat({
    required this.icon,
    required this.value,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(
          icon,
          color: const Color(0xFF4ADE80),
          size: 22,
        ),
        const SizedBox(height: 5),
        _OneLineFitText(
          value,
          alignment: Alignment.center,
          textAlign: TextAlign.center,
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
          style: const TextStyle(
            color: Colors.white54,
            fontSize: 10.5,
          ),
        ),
      ],
    );
  }
}

// ============================================================
// PAGE 4
// CHECKPOINT CLUE
// ============================================================

class _QuestCluePage extends StatelessWidget {
  final TripPathQuestViewModel viewModel;
  final Future<void> Function() onExitQuest;

  const _QuestCluePage({
    required this.viewModel,
    required this.onExitQuest,
  });

  @override
  Widget build(BuildContext context) {
    final theme = viewModel.selectedTheme!;

    final style = _getThemeStyle(
      theme.id,
    );

    // Wrapped in the same dark-aware Theme as Theme Selection/Quest
    // Information (see _darkAwareTripPathTheme) instead of trusting the
    // module-level pinned-light Theme, so this screen's chrome follows the
    // app's actual light/dark/system choice. The clue card itself stays a
    // fixed navy accent, matching Quest Information's Artwork Reward card.
    return Theme(
      data: _darkAwareTripPathTheme(context),
      child: Builder(
        builder: (context) => _PhoneFrame(
      child: Scaffold(
        backgroundColor: context.colors.surface,
        appBar: AppBar(
          backgroundColor: context.colors.surface,
          elevation: 0,
          centerTitle: true,
          leading: IconButton(
            onPressed: viewModel.goBack,
            icon: const Icon(
              Icons.arrow_back_ios_new_rounded,
            ),
          ),
          title: Text(
            'Checkpoint ${viewModel.currentCheckpoint} of ${viewModel.totalCheckpoints}',
            style: TextStyle(
              color: context.colors.onSurface,
              fontSize: 17,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            20,
            8,
            20,
            30,
          ),
          child: Column(
            children: [
              _CheckpointProgress(
                current:
                viewModel.currentCheckpoint,
              ),

              const SizedBox(
                height: 16,
              ),

              Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: style.background,
                      borderRadius:
                      BorderRadius.circular(
                        14,
                      ),
                    ),
                    child: Icon(
                      style.icon,
                      color: style.color,
                      size: 27,
                    ),
                  ),

                  const SizedBox(
                    width: 12,
                  ),

                  Expanded(
                    child: Column(
                      crossAxisAlignment:
                      CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${theme.name} Quest',
                          style: TextStyle(
                            color:
                            context.colors.onSurface,
                            fontSize: 16,
                            fontWeight:
                            FontWeight.w800,
                          ),
                        ),
                        const SizedBox(
                          height: 2,
                        ),
                        Text(
                          'Checkpoint ${viewModel.currentCheckpoint} · Find the mystery location',
                          style: TextStyle(
                            color:
                            context.colors.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              const SizedBox(
                height: 16,
              ),

              // ==================================================
              // GENERATING
              // ==================================================

              if (viewModel.isGeneratingClue &&
                  !viewModel.hasGeneratedClue)
                Container(
                  width: double.infinity,
                  padding:
                  const EdgeInsets.all(
                    26,
                  ),
                  decoration: BoxDecoration(
                    gradient:
                    const LinearGradient(
                      begin: Alignment.topLeft,
                      end:
                      Alignment.bottomRight,
                      colors: [
                        Color(0xFF03152E),
                        Color(0xFF0E3A6E),
                      ],
                    ),
                    borderRadius:
                    BorderRadius.circular(
                      24,
                    ),
                  ),
                  child: const Column(
                    children: [
                      CircularProgressIndicator(
                        color:
                        Color(0xFF38BDF8),
                      ),
                      SizedBox(
                        height: 18,
                      ),
                      Text(
                        'Preparing your clues...',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight:
                          FontWeight.w700,
                        ),
                      ),
                      SizedBox(
                        height: 6,
                      ),
                      Text(
                        'Gemini is generating 3 clues for this checkpoint.',
                        textAlign:
                        TextAlign.center,
                        style: TextStyle(
                          color:
                          Color(0xFFBAE6FD),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                )

              // ==================================================
              // ERROR
              // ==================================================

              else if (viewModel
                  .clueGenerationError !=
                  null)
                Container(
                  width: double.infinity,
                  padding:
                  const EdgeInsets.all(
                    20,
                  ),
                  decoration: BoxDecoration(
                    color:
                    context.colors.errorContainer,
                    borderRadius:
                    BorderRadius.circular(
                      20,
                    ),
                    border: Border.all(
                      color:
                      context.colors.error.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Column(
                    children: [
                      Icon(
                        Icons
                            .error_outline_rounded,
                        color:
                        context.colors.error,
                        size: 38,
                      ),
                      const SizedBox(
                        height: 10,
                      ),
                      Text(
                        'Unable to Generate Clue',
                        style: TextStyle(
                          color:
                          context.colors.onErrorContainer,
                          fontSize: 16,
                          fontWeight:
                          FontWeight.w800,
                        ),
                      ),
                      const SizedBox(
                        height: 6,
                      ),
                      Text(
                        viewModel
                            .clueGenerationError!,
                        textAlign:
                        TextAlign.center,
                        style: TextStyle(
                          color:
                          context.colors.onErrorContainer,
                          fontSize: 12.5,
                        ),
                      ),
                      const SizedBox(
                        height: 14,
                      ),
                      FilledButton.icon(
                        onPressed: () {
                          viewModel
                              .retryGenerateClue();
                        },
                        icon: const Icon(
                          Icons.refresh_rounded,
                        ),
                        label: const Text(
                          'Retry',
                        ),
                      ),
                    ],
                  ),
                )

              // ==================================================
              // CLUE READY
              // ==================================================

              else if (viewModel
                    .hasGeneratedClue)
                  Container(
                    width: double.infinity,
                    padding:
                    const EdgeInsets.all(
                      24,
                    ),
                    decoration: BoxDecoration(
                      gradient:
                      const LinearGradient(
                        begin: Alignment.topLeft,
                        end:
                        Alignment.bottomRight,
                        colors: [
                          Color(0xFF03152E),
                          Color(0xFF0E3A6E),
                        ],
                      ),
                      borderRadius:
                      BorderRadius.circular(
                        24,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment:
                      CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'CLUE ${viewModel.currentClueIndex + 1} OF 3',
                                style:
                                const TextStyle(
                                  color:
                                  Color(0xFF7DD3FC),
                                  fontSize: 11,
                                  letterSpacing: 1.0,
                                  fontWeight:
                                  FontWeight.w800,
                                ),
                              ),
                            ),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: List.generate(
                                3,
                                    (index) {
                                  final unlocked =
                                      index < viewModel.cluesUsed;
                                  final selected =
                                      unlocked &&
                                          index == viewModel.currentClueIndex;

                                  return Padding(
                                    padding: EdgeInsets.only(
                                      left: index == 0 ? 0 : 5,
                                    ),
                                    child: InkWell(
                                      onTap: unlocked
                                          ? () => viewModel.viewClue(index)
                                          : null,
                                      borderRadius:
                                      BorderRadius.circular(999),
                                      child: AnimatedContainer(
                                        duration: const Duration(
                                          milliseconds: 160,
                                        ),
                                        width: 30,
                                        height: 30,
                                        alignment: Alignment.center,
                                        decoration: BoxDecoration(
                                          color: selected
                                              ? const Color(0xFF0284C7)
                                              : unlocked
                                              ? const Color(0x2238BDF8)
                                              : Colors.white.withOpacity(0.07),
                                          shape: BoxShape.circle,
                                          border: Border.all(
                                            color: selected
                                                ? const Color(0xFF7DD3FC)
                                                : unlocked
                                                ? const Color(0x6638BDF8)
                                                : Colors.white.withOpacity(0.14),
                                          ),
                                        ),
                                        child: unlocked
                                            ? Text(
                                          '${index + 1}',
                                          style: TextStyle(
                                            color: selected
                                                ? Colors.white
                                                : const Color(0xFFBAE6FD),
                                            fontSize: 11,
                                            fontWeight: FontWeight.w900,
                                          ),
                                        )
                                            : const Icon(
                                          Icons.lock_rounded,
                                          size: 13,
                                          color: Color(0xFF94A3B8),
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ],
                        ),

                        const SizedBox(
                          height: 14,
                        ),

                        Text(
                          '"${viewModel.currentClue}"',
                          style:
                          const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            height: 1.5,
                            fontStyle:
                            FontStyle.italic,
                            fontWeight:
                            FontWeight.w600,
                          ),
                        ),

                        const SizedBox(
                          height: 18,
                        ),

                        Row(
                          children:
                          List.generate(
                            3,
                                (index) {
                              final unlocked =
                                  index <
                                      viewModel
                                          .cluesUsed;

                              final selected =
                                  index ==
                                      viewModel
                                          .currentClueIndex;

                              return Expanded(
                                child: Container(
                                  height:
                                  selected
                                      ? 5
                                      : 4,
                                  margin:
                                  EdgeInsets.only(
                                    right:
                                    index == 2
                                        ? 0
                                        : 6,
                                  ),
                                  decoration:
                                  BoxDecoration(
                                    color: selected
                                        ? Colors.white
                                        : unlocked
                                        ? const Color(
                                      0xFF38BDF8,
                                    )
                                        : Colors
                                        .white
                                        .withOpacity(
                                      0.20,
                                    ),
                                    borderRadius:
                                    BorderRadius
                                        .circular(
                                      2,
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  )

                else
                  Container(
                    width: double.infinity,
                    padding:
                    const EdgeInsets.all(
                      20,
                    ),
                    decoration: BoxDecoration(
                      color: context.colors.surface,
                      borderRadius:
                      BorderRadius.circular(
                        18,
                      ),
                    ),
                    child: Text(
                      'Waiting for clue...',
                      textAlign:
                      TextAlign.center,
                      style: TextStyle(
                        color: context.colors.onSurface,
                      ),
                    ),
                  ),

              const SizedBox(
                height: 12,
              ),

              const SizedBox(
                height: 14,
              ),

              Container(
                width: double.infinity,
                padding:
                const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  color: context.colors.surface,
                  borderRadius:
                  BorderRadius.circular(
                    16,
                  ),
                ),
                child: Row(
                  mainAxisAlignment:
                  MainAxisAlignment
                      .spaceBetween,
                  children: [
                    Text(
                      'Clues remaining',
                      style: TextStyle(
                        color:
                        context.colors.onSurfaceVariant,
                        fontSize: 13,
                      ),
                    ),
                    Row(
                      children: [
                        Icon(
                          Icons
                              .lightbulb_rounded,
                          color:
                          context.appColors.warning,
                          size: 18,
                        ),
                        const SizedBox(
                          width: 5,
                        ),
                        Text(
                          '${viewModel.cluesRemaining} left',
                          style:
                          TextStyle(
                            color:
                            context.appColors.warning,
                            fontSize: 14,
                            fontWeight:
                            FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(
                height: 18,
              ),

              Row(
                children: [
                  Expanded(
                    child:
                    OutlinedButton.icon(
                      onPressed: viewModel
                          .canRequestAnotherClue
                          ? viewModel
                          .requestAnotherClue
                          : null,
                      style: OutlinedButton
                          .styleFrom(
                        foregroundColor:
                        context.appColors.warning,
                        backgroundColor:
                        context.appColors.warningSurface,
                        side:
                        BorderSide(
                          color:
                          context.appColors.warning.withValues(alpha: 0.4),
                        ),
                        padding:
                        const EdgeInsets
                            .symmetric(
                          vertical: 14,
                        ),
                        shape:
                        RoundedRectangleBorder(
                          borderRadius:
                          BorderRadius
                              .circular(
                            16,
                          ),
                        ),
                      ),
                      icon: const Icon(
                        Icons
                            .lightbulb_outline_rounded,
                      ),
                      label: const Text(
                        'Another Clue',
                        style: TextStyle(
                          fontWeight:
                          FontWeight.w600,
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(
                    width: 12,
                  ),

                  Expanded(
                    child:
                    FilledButton.icon(
                      onPressed: viewModel
                          .hasGeneratedClue
                          ? viewModel
                          .navigateToCheckpoint
                          : null,
                      style:
                      FilledButton.styleFrom(
                        backgroundColor:
                        context.colors.primary,
                        foregroundColor:
                        context.colors.onPrimary,
                        padding:
                        const EdgeInsets
                            .symmetric(
                          vertical: 14,
                        ),
                        shape:
                        RoundedRectangleBorder(
                          borderRadius:
                          BorderRadius
                              .circular(
                            16,
                          ),
                        ),
                      ),
                      icon: const Icon(
                        Icons
                            .navigation_rounded,
                      ),
                      label: const Text(
                        'Navigate',
                        style: TextStyle(
                          fontWeight:
                          FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 12),

              _SaveAndExitQuestButton(
                viewModel: viewModel,
                onExitQuest: onExitQuest,
              ),
            ],
          ),
        ),
      ),
        ),
      ),
    );
  }
}

// ============================================================
// PAGE 5
// LIVE NAVIGATION
//
// UI goals:
// - edge-to-edge dark Google Map (no left/right page padding on map)
// - header / metrics / verification / button keep normal side padding
// - map is freely draggable / zoomable / rotatable / tiltable
// - LIVE GPS + map controls
// - direct visual guidance line
// - guidance panel inside map
// - direction card shows a rotated arrow beside the direction text
// - important labels stay on ONE line without ellipsis
// - >50 m: Verify locked
// - <=50 m: checkpoint status green + Verify enabled
// ============================================================

class _NavigationPage extends StatefulWidget {
  final TripPathQuestViewModel viewModel;
  final Future<void> Function() onExitQuest;

  const _NavigationPage({
    required this.viewModel,
    required this.onExitQuest,
  });

  @override
  State<_NavigationPage> createState() => _NavigationPageState();
}

class _NavigationPageState extends State<_NavigationPage> {
  // Lets the floating recenter button reach the map, matching Puzzle's
  // _mapKey.currentState?.recenter() pattern.
  final _mapKey = GlobalKey<_QuestGoogleMapCardState>();

  // Measures the top/bottom overlay cards so the map can be told (via
  // GoogleMap's own `padding`) how much of the full-bleed screen they
  // actually cover — otherwise a fitted camera centres markers under
  // whichever card is currently on top of them. See _scheduleMeasureOverlays.
  final _topOverlayKey = GlobalKey();
  final _bottomOverlayKey = GlobalKey();
  EdgeInsets _mapPadding = EdgeInsets.zero;

  void _scheduleMeasureOverlays() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final topHeight =
          _topOverlayKey.currentContext?.size?.height ?? _mapPadding.top;
      final bottomHeight = _bottomOverlayKey.currentContext?.size?.height ??
          _mapPadding.bottom;
      final measured = EdgeInsets.only(top: topHeight, bottom: bottomHeight);
      if (measured != _mapPadding) {
        setState(() => _mapPadding = measured);
      }
    });
  }

  Future<void> _showClueCard() async {
    final viewModel = widget.viewModel;

    if (!viewModel.hasGeneratedClue) {
      return;
    }

    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      builder: (dialogContext) {
        return AnimatedBuilder(
          animation: viewModel,
          builder: (context, child) {
            final themeStyle = _getThemeStyle(
              viewModel.selectedTheme?.id ?? 'food',
            );

            return Dialog(
              backgroundColor: Colors.transparent,
              insetPadding: const EdgeInsets.symmetric(horizontal: 24),
              child: Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxWidth: 430),
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color(0xFF03152E),
                      Color(0xFF0E3A6E),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.10),
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x52000000),
                      blurRadius: 24,
                      offset: Offset(0, 10),
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
                            color: const Color(0xFFF59E0B)
                                .withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(
                            Icons.lightbulb_rounded,
                            color: Color(0xFFFBBF24),
                            size: 22,
                          ),
                        ),
                        const SizedBox(width: 11),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Checkpoint ${viewModel.currentCheckpoint} Clue',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.of(dialogContext).pop(),
                          tooltip: 'Close',
                          icon: const Icon(
                            Icons.close_rounded,
                            color: Color(0xFFCBD5E1),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Text(
                          'CLUE ${viewModel.currentClueIndex + 1} OF 3',
                          style: const TextStyle(
                            color: Color(0xFF7DD3FC),
                            fontSize: 10.5,
                            letterSpacing: 0.9,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const Spacer(),
                        ...List.generate(3, (index) {
                          final unlocked = viewModel.canViewClue(index);
                          final selected =
                              unlocked && index == viewModel.currentClueIndex;

                          return Padding(
                            padding: EdgeInsets.only(left: index == 0 ? 0 : 6),
                            child: InkWell(
                              onTap: unlocked
                                  ? () => viewModel.viewClue(index)
                                  : null,
                              borderRadius: BorderRadius.circular(999),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 160),
                                width: 30,
                                height: 30,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: selected
                                      ? const Color(0xFF0284C7)
                                      : unlocked
                                      ? const Color(0x2238BDF8)
                                      : Colors.white.withValues(alpha: 0.07),
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: selected
                                        ? const Color(0xFF7DD3FC)
                                        : unlocked
                                        ? const Color(0x6638BDF8)
                                        : Colors.white
                                        .withValues(alpha: 0.14),
                                  ),
                                ),
                                child: unlocked
                                    ? Text(
                                  '${index + 1}',
                                  style: TextStyle(
                                    color: selected
                                        ? Colors.white
                                        : const Color(0xFFBAE6FD),
                                    fontSize: 11,
                                    fontWeight: FontWeight.w900,
                                  ),
                                )
                                    : const Icon(
                                  Icons.lock_rounded,
                                  size: 13,
                                  color: Color(0xFF94A3B8),
                                ),
                              ),
                            ),
                          );
                        }),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: themeStyle.color.withValues(alpha: 0.28),
                        ),
                      ),
                      child: Text(
                        '"${viewModel.currentClue}"',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          height: 1.5,
                          fontStyle: FontStyle.italic,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (viewModel.canRequestAnotherClue) ...[
                      const SizedBox(height: 14),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: viewModel.requestAnotherClue,
                          icon: const Icon(
                            Icons.lock_open_rounded,
                            size: 18,
                          ),
                          label: const Text(
                            'Unlock Next Clue',
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF0284C7),
                            foregroundColor: Colors.white,
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(
                              vertical: 13,
                              horizontal: 16,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                            textStyle: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                    ],
                    if (viewModel.cluesUsed > 1) ...[
                      const SizedBox(height: 12),
                      const Text(
                        'Tap a clue number above to review your revealed clues.',
                        style: TextStyle(
                          color: Color(0xFF94A3B8),
                          fontSize: 10.8,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final viewModel = widget.viewModel;
    final onExitQuest = widget.onExitQuest;
    final theme = viewModel.selectedTheme;
    final error = viewModel.navigationError;
    final hasLocation = viewModel.hasCurrentLocation;
    final isLoading = viewModel.isStartingNavigation;
    final canVerify = viewModel.canVerifyVisit;
    final isPreparingReference =
        viewModel.isPreparingCurrentReferencePhoto;
    final referenceError =
        viewModel.referencePreparationError;

    _scheduleMeasureOverlays();

    return _PhoneFrame(
      child: Scaffold(
        backgroundColor: const Color(0xFF03152E),
        // Full-bleed map behind floating controls and cards, matching
        // Puzzle's Navigate screen instead of a separate header bar above
        // a fixed-height map box.
        body: Stack(
          children: [
            Positioned.fill(
              child: _QuestGoogleMapCard(
                key: _mapKey,
                viewModel: viewModel,
                hasLocation: hasLocation,
                isLoading: isLoading,
                canVerify: canVerify,
                mapPadding: _mapPadding,
              ),
            ),

            // Keep the Back button at the normal top-left position used by
            // the earlier Trip Path pages. The fixed height preserves the
            // existing map top-padding behaviour after removing the checkpoint
            // progress card.
            SafeArea(
              key: _topOverlayKey,
              child: SizedBox(
                height: 127,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: _MapControlButton(
                      icon: Icons.arrow_back_ios_new_rounded,
                      onTap: viewModel.goBack,
                    ),
                  ),
                ),
              ),
            ),

            // Same top-right placement as Mystery Place Puzzle navigation.
            // The clue bulb stays directly below the four map controls.
            Positioned(
              right: 14,
              top: MediaQuery.paddingOf(context).top + 10,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _SideMapControlButton(
                    tooltip: 'Recenter map',
                    icon: Icons.gps_fixed_rounded,
                    onTap: () => _mapKey.currentState?.recenter(),
                  ),
                  const SizedBox(height: 10),
                  _SideMapControlButton(
                    tooltip: 'Zoom in',
                    icon: Icons.add_rounded,
                    onTap: () => _mapKey.currentState?.zoomIn(),
                  ),
                  const SizedBox(height: 10),
                  _SideMapControlButton(
                    tooltip: 'Zoom out',
                    icon: Icons.remove_rounded,
                    onTap: () => _mapKey.currentState?.zoomOut(),
                  ),
                  const SizedBox(height: 10),
                  _SideMapControlButton(
                    tooltip: 'Face travel direction',
                    icon: Icons.navigation_rounded,
                    onTap: () => _mapKey.currentState?.focusOnUser(),
                  ),
                  const SizedBox(height: 14),
                  _SideMapControlButton(
                    tooltip: 'View clue',
                    icon: Icons.lightbulb_outline_rounded,
                    iconColor: const Color(0xFFF59E0B),
                    enabled: viewModel.hasGeneratedClue,
                    onTap: _showClueCard,
                  ),
                ],
              ),
            ),

            Align(
              alignment: Alignment.bottomCenter,
              child: SafeArea(
                key: _bottomOverlayKey,
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (error != null) ...[
                        _NavigationErrorCard(
                          message: error,
                          onRetry: viewModel.retryNavigation,
                          onLocationSettings: viewModel.openLocationSettings,
                          onAppSettings: viewModel.openAppSettings,
                        ),
                        const SizedBox(height: 10),
                      ] else if (isLoading && !hasLocation) ...[
                        const _NavigationLoadingCard(),
                        const SizedBox(height: 10),
                      ],

                      // One consolidated card — place header, Distance/Direction,
                      // status banner and the Verify button together — instead
                      // of separate stacked sections.
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
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _NavigationMetricsRow(
                              distance:
                              hasLocation ? viewModel.distanceText : '--',
                              direction:
                              hasLocation ? viewModel.directionText : '--',
                            ),
                            const SizedBox(height: 10),
                            _VerificationRangeCard(
                              canVerify: canVerify,
                              hasLocation: hasLocation,
                              distanceText: viewModel.distanceText,
                            ),
                            if (referenceError != null) ...[
                              const SizedBox(height: 8),
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 11,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFFFF7ED),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: const Color(0xFFFED7AA),
                                  ),
                                ),
                                child: Text(
                                  referenceError,
                                  style: const TextStyle(
                                    color: Color(0xFF9A3412),
                                    fontSize: 11.8,
                                    height: 1.35,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                            const SizedBox(height: 14),
                            SizedBox(
                              width: double.infinity,
                              height: 50,
                              child: FilledButton(
                                onPressed:
                                canVerify && !isPreparingReference
                                    ? viewModel.openVerification
                                    : null,
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
                                  elevation: canVerify ? 5 : 0,
                                  shadowColor: const Color(0x55087FF5),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 18),
                                ),
                                child: isPreparingReference
                                    ? const SizedBox(
                                  width: 23,
                                  height: 23,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.4,
                                    valueColor:
                                    AlwaysStoppedAnimation<Color>(
                                      Color(0xFF64748B),
                                    ),
                                  ),
                                )
                                    : Row(
                                  mainAxisAlignment:
                                  MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      canVerify
                                          ? Icons.verified_rounded
                                          : Icons.lock_rounded,
                                      size: 22,
                                    ),
                                    const SizedBox(width: 10),
                                    Flexible(
                                      child: _OneLineFitText(
                                        canVerify
                                            ? 'Verify Visit'
                                            : 'Move Within 50 m to Verify',
                                        alignment: Alignment.center,
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

                      _SaveAndExitQuestButton(
                        viewModel: viewModel,
                        onExitQuest: onExitQuest,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// SAVE & EXIT QUEST BUTTON
// ============================================================

class _SaveAndExitQuestButton extends StatelessWidget {
  final TripPathQuestViewModel viewModel;
  final Future<void> Function() onExitQuest;
  final bool darkBackground;

  const _SaveAndExitQuestButton({
    required this.viewModel,
    required this.onExitQuest,
    this.darkBackground = false,
  });

  @override
  Widget build(BuildContext context) {
    final saving = viewModel.isSavingAndExiting;

    return SizedBox(
      width: double.infinity,
      height: 48,
      child: OutlinedButton.icon(
        onPressed: saving
            ? null
            : () => _confirmSaveAndExitQuest(
          context,
          viewModel,
          onExitQuest,
        ),
        style: OutlinedButton.styleFrom(
          foregroundColor: darkBackground
              ? const Color(0xFFCBD5E1)
              : context.colors.onSurfaceVariant,
          disabledForegroundColor: darkBackground
              ? const Color(0xFF94A3B8)
              : context.colors.onSurfaceVariant.withValues(alpha: 0.5),
          side: BorderSide(
            color: darkBackground
                ? const Color(0x33FFFFFF)
                : context.colors.outlineVariant,
          ),
          backgroundColor: darkBackground
              ? const Color(0x0FFFFFFF)
              : context.colors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        icon: saving
            ? const SizedBox(
          width: 17,
          height: 17,
          child: CircularProgressIndicator(
            strokeWidth: 2,
          ),
        )
            : const Icon(
          Icons.exit_to_app_rounded,
          size: 19,
        ),
        label: Text(
          saving
              ? 'Saving Progress...'
              : 'Save & Exit Quest · Back to Home',
          maxLines: 1,
          overflow: TextOverflow.fade,
          softWrap: false,
          style: const TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

// ============================================================
// ONE-LINE TEXT HELPER
// Keeps important text complete instead of "Checkp..." or bad wrapping.
// ============================================================

class _OneLineFitText extends StatelessWidget {
  final String text;
  final TextStyle style;
  final Alignment alignment;
  final TextAlign textAlign;

  const _OneLineFitText(
      this.text, {
        required this.style,
        this.alignment = Alignment.centerLeft,
        this.textAlign = TextAlign.left,
      });

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: alignment,
      child: Text(
        text,
        maxLines: 1,
        softWrap: false,
        textAlign: textAlign,
        style: style,
      ),
    );
  }
}

// ============================================================
// NAVIGATION PROGRESS BADGE
// Floats over the map below the back/recenter row, instead of a
// solid full-width header bar — matches Puzzle's map-fills-the-screen
// layout while still surfacing Trip Path's multi-checkpoint progress.
// ============================================================

class _NavigationProgressBadge extends StatelessWidget {
  final int currentCheckpoint;
  final int totalCheckpoints;
  final String themeName;
  final VoidCallback onBack;

  const _NavigationProgressBadge({
    required this.currentCheckpoint,
    required this.totalCheckpoints,
    required this.themeName,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    // Keep the same overlay height and the same back-button position as the
    // previous checkpoint card. This means the right-side map controls do not
    // move when the checkpoint card is hidden.
    //
    // Previous layout position:
    // outer padding = 10 px from the SafeArea top
    // card padding  = another 10 px
    // so the back button starts at the same visual position here.
    return SizedBox(
      width: double.infinity,
      height: 127,
      child: Stack(
        children: [
          Positioned(
            left: 10,
            top: 10,
            child: _MapControlButton(
              icon: Icons.arrow_back_ios_new_rounded,
              onTap: onBack,
            ),
          ),
        ],
      ),
    );
  }
}

class _NavigationProgressLine extends StatelessWidget {
  final int currentCheckpoint;
  final int totalCheckpoints;

  const _NavigationProgressLine({
    required this.currentCheckpoint,
    required this.totalCheckpoints,
  });

  @override
  Widget build(BuildContext context) {
    final total = totalCheckpoints <= 0 ? 1 : totalCheckpoints;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: List.generate(total * 2 - 1, (index) {
          if (index.isOdd) {
            final leftCheckpoint = (index + 1) ~/ 2;
            final completed = leftCheckpoint < currentCheckpoint;
            return Expanded(
              child: Padding(
                // Centres the connector on the (up to 34px-tall) dots above,
                // ignoring the label line below them.
                padding: const EdgeInsets.only(top: 15.5),
                child: Container(
                  height: 3,
                  color: completed
                      ? const Color(0xFF22C55E)
                      : const Color(0xFF466581),
                ),
              ),
            );
          }

          final checkpoint = (index ~/ 2) + 1;
          final completed = checkpoint < currentCheckpoint;
          final current = checkpoint == currentCheckpoint;
          final label = completed ? 'Done' : (current ? 'Now' : 'Locked');

          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: current ? 34 : 28,
                height: current ? 34 : 28,
                decoration: BoxDecoration(
                  color: completed
                      ? const Color(0xFF22C55E)
                      : current
                      ? const Color(0xFF168AF5)
                      : const Color(0xFF0B2B50),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: completed
                        ? const Color(0xFF4ADE80)
                        : current
                        ? const Color(0xFF93C5FD)
                        : const Color(0xFF6685A1),
                    width: current ? 3 : 2.5,
                  ),
                  boxShadow: current
                      ? const [
                    BoxShadow(
                      color: Color(0x55168AF5),
                      blurRadius: 9,
                      spreadRadius: 1,
                    ),
                  ]
                      : null,
                ),
                alignment: Alignment.center,
                child: completed
                    ? const Icon(
                  Icons.check_rounded,
                  color: Colors.white,
                  size: 16,
                )
                    : null,
              ),
              const SizedBox(height: 5),
              Text(
                label,
                style: TextStyle(
                  color: completed
                      ? const Color(0xFF4ADE80)
                      : current
                      ? const Color(0xFF93C5FD)
                      : const Color(0xFF6685A1),
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          );
        }),
      ),
    );
  }
}

// ============================================================
// EDGE-TO-EDGE DARK GOOGLE MAP
// ============================================================

class _QuestGoogleMapCard extends StatefulWidget {
  final TripPathQuestViewModel viewModel;
  final bool hasLocation;
  final bool isLoading;
  final bool canVerify;
  // Reserves space on each edge so the fitted camera keeps the user/
  // checkpoint markers inside the strip that's actually visible between
  // the floating overlays, instead of framing them for the full screen
  // and letting the cards on top hide them.
  final EdgeInsets mapPadding;

  const _QuestGoogleMapCard({
    super.key,
    required this.viewModel,
    required this.hasLocation,
    required this.isLoading,
    required this.canVerify,
    this.mapPadding = EdgeInsets.zero,
  });

  @override
  State<_QuestGoogleMapCard> createState() =>
      _QuestGoogleMapCardState();
}

class _QuestGoogleMapCardState extends State<_QuestGoogleMapCard> {
  GoogleMapController? _controller;
  bool _fittedWithUserLocation = false;
  double? _lastDistanceMeters;
  String _movementMessage = 'Continue toward the checkpoint';

  // ============================================================
  // PHONE COMPASS / USER MARKER HEADING
  //
  // This is NOT the same as checkpoint direction.
  //
  // checkpoint direction:
  //   User GPS -> Checkpoint GPS
  //
  // device heading:
  //   Direction the TOP of the phone is facing.
  //
  // Only the blue USER marker rotates with this heading.
  // ============================================================

  StreamSubscription<CompassEvent>? _compassSubscription;

  double? _deviceHeadingDegrees;

  // Small smoothing factor so the marker does not shake from
  // magnetometer noise.
  static const double _headingSmoothingFactor = 0.24;

  BitmapDescriptor? _userHeadingMarkerIcon;

  bool _reportedCompassUnavailable = false;

  static const String _darkMapStyle = '''
[
  {"elementType":"geometry","stylers":[{"color":"#14263D"}]},
  {"elementType":"labels.text.fill","stylers":[{"color":"#AFC3D9"}]},
  {"elementType":"labels.text.stroke","stylers":[{"color":"#0B1726"}]},
  {"featureType":"administrative","elementType":"geometry","stylers":[{"color":"#29415C"}]},
  {"featureType":"poi","elementType":"geometry","stylers":[{"color":"#17334A"}]},
  {"featureType":"poi","elementType":"labels","stylers":[{"visibility":"off"}]},
  {"featureType":"poi.park","elementType":"geometry","stylers":[{"color":"#123F39"}]},
  {"featureType":"poi.park","elementType":"labels.text.fill","stylers":[{"color":"#8EE0B1"}]},
  {"featureType":"road","elementType":"geometry","stylers":[{"color":"#263B53"}]},
  {"featureType":"road","elementType":"geometry.stroke","stylers":[{"color":"#13253A"}]},
  {"featureType":"road.highway","elementType":"geometry","stylers":[{"color":"#31506D"}]},
  {"featureType":"transit","elementType":"geometry","stylers":[{"color":"#20364E"}]},
  {"featureType":"water","elementType":"geometry","stylers":[{"color":"#062D4E"}]},
  {"featureType":"water","elementType":"labels.text.fill","stylers":[{"color":"#72B8EF"}]}
]
''';

  LatLng? get _userPosition {
    final lat = widget.viewModel.currentLatitude;
    final lng = widget.viewModel.currentLongitude;
    if (lat == null || lng == null) return null;
    return LatLng(lat, lng);
  }

  LatLng? get _checkpointPosition {
    final lat = widget.viewModel.checkpointLatitude;
    final lng = widget.viewModel.checkpointLongitude;
    if (lat == null || lng == null) return null;
    return LatLng(lat, lng);
  }

  LatLng get _initialPosition =>
      _userPosition ??
          _checkpointPosition ??
          const LatLng(3.1390, 101.6869);

  @override
  void initState() {
    super.initState();

    _lastDistanceMeters = _parseDistanceMeters(
      widget.viewModel.distanceText,
    );

    unawaited(
      _prepareUserHeadingMarkerIcon(),
    );

    _startCompassTracking();
  }

  // ============================================================
  // LIVE PHONE COMPASS
  // ============================================================

  void _startCompassTracking() {
    final compassEvents =
        FlutterCompass.events;

    if (compassEvents == null) {
      if (kDebugMode) {
        debugPrint(
          '[COMPASS] No compass stream is available on this device.',
        );
      }

      return;
    }

    _compassSubscription =
        compassEvents.listen(
              (event) {
            final rawHeading =
                event.heading;

            if (rawHeading == null ||
                rawHeading.isNaN ||
                rawHeading.isInfinite) {
              if (!_reportedCompassUnavailable &&
                  kDebugMode) {
                _reportedCompassUnavailable = true;

                debugPrint(
                  '[COMPASS] Heading unavailable. '
                      'Test the rotating user arrow on a real phone '
                      'with a supported compass sensor.',
                );
              }

              return;
            }

            final normalizedHeading =
            _normalizeHeading(
              rawHeading,
            );

            final previousHeading =
                _deviceHeadingDegrees;

            final nextHeading =
            previousHeading == null
                ? normalizedHeading
                : _smoothHeading(
              previousHeading,
              normalizedHeading,
            );

            // Ignore tiny sensor changes to reduce visible shaking.
            if (previousHeading != null &&
                _absoluteAngleDifference(
                  previousHeading,
                  nextHeading,
                ) <
                    0.8) {
              return;
            }

            if (!mounted) {
              return;
            }

            setState(() {
              _deviceHeadingDegrees =
                  nextHeading;
            });
          },
          onError: (Object error) {
            if (kDebugMode) {
              debugPrint(
                '[COMPASS] Stream error: $error',
              );
            }
          },
        );
  }

  double _normalizeHeading(
      double value,
      ) {
    final normalized =
        value % 360;

    return normalized < 0
        ? normalized + 360
        : normalized;
  }

  double _shortestAngleDelta(
      double from,
      double to,
      ) {
    return ((to - from + 540) % 360) - 180;
  }

  double _absoluteAngleDifference(
      double first,
      double second,
      ) {
    return _shortestAngleDelta(
      first,
      second,
    ).abs();
  }

  double _smoothHeading(
      double current,
      double target,
      ) {
    final delta =
    _shortestAngleDelta(
      current,
      target,
    );

    return _normalizeHeading(
      current +
          delta *
              _headingSmoothingFactor,
    );
  }

  // ============================================================
  // RUNTIME USER MARKER ICON
  //
  // Blue circle + white navigation arrow.
  // No external image asset is required.
  // ============================================================

  Future<void>
  _prepareUserHeadingMarkerIcon() async {
    const size = 96;

    final recorder =
    ui.PictureRecorder();

    final canvas =
    ui.Canvas(
      recorder,
    );

    const center =
    ui.Offset(
      size / 2,
      size / 2,
    );

    final shadowPaint =
    ui.Paint()
      ..color =
      const Color(
        0x55000000,
      )
      ..maskFilter =
      const ui.MaskFilter.blur(
        ui.BlurStyle.normal,
        5,
      );

    canvas.drawCircle(
      center.translate(
        0,
        2,
      ),
      31,
      shadowPaint,
    );

    final whiteHalo =
    ui.Paint()
      ..color =
          Colors.white;

    canvas.drawCircle(
      center,
      29,
      whiteHalo,
    );

    final blueBody =
    ui.Paint()
      ..color =
      const Color(
        0xFF168AF5,
      );

    canvas.drawCircle(
      center,
      24,
      blueBody,
    );

    final arrowPath =
    ui.Path()
      ..moveTo(
        48,
        22,
      )
      ..lineTo(
        62,
        61,
      )
      ..lineTo(
        48,
        54,
      )
      ..lineTo(
        34,
        61,
      )
      ..close();

    final arrowPaint =
    ui.Paint()
      ..color =
          Colors.white
      ..style =
          ui.PaintingStyle.fill;

    canvas.drawPath(
      arrowPath,
      arrowPaint,
    );

    final picture =
    recorder.endRecording();

    final image =
    await picture.toImage(
      size,
      size,
    );

    final byteData =
    await image.toByteData(
      format:
      ui.ImageByteFormat.png,
    );

    if (byteData == null ||
        !mounted) {
      return;
    }

    final icon =
    BitmapDescriptor.fromBytes(
      byteData.buffer
          .asUint8List(),
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _userHeadingMarkerIcon =
          icon;
    });
  }

  @override
  void didUpdateWidget(covariant _QuestGoogleMapCard oldWidget) {
    super.didUpdateWidget(oldWidget);

    final currentDistance = _parseDistanceMeters(
      widget.viewModel.distanceText,
    );

    if (widget.canVerify) {
      _movementMessage = 'Checkpoint area reached';
    } else if (!widget.hasLocation) {
      _movementMessage = widget.isLoading
          ? 'Finding your position'
          : 'Waiting for GPS position';
    } else if (currentDistance != null && _lastDistanceMeters != null) {
      final change = currentDistance - _lastDistanceMeters!;
      if (change <= -2) {
        _movementMessage = "You're getting closer";
      } else if (change >= 2) {
        _movementMessage = "You're moving away from the checkpoint";
      }
    }

    if (currentDistance != null) {
      _lastDistanceMeters = currentDistance;
    }

    if (!_fittedWithUserLocation &&
        !oldWidget.hasLocation &&
        widget.hasLocation &&
        _userPosition != null) {
      _fittedWithUserLocation = true;
      _scheduleFit();
    }

    // The overlay cards' measured heights (see _NavigationPageState) land a
    // frame or two after this widget's first fit, once the padding they
    // imply is known. Re-fit so markers already placed under a padding of
    // zero move back into the visible strip.
    if (widget.mapPadding != oldWidget.mapPadding) {
      _scheduleFit();
    }
  }

  double? _parseDistanceMeters(String value) {
    final match = RegExp(r'([0-9]+(?:\.[0-9]+)?)')
        .firstMatch(value.replaceAll(',', ''));
    if (match == null) return null;
    final number = double.tryParse(match.group(1)!);
    if (number == null) return null;
    return value.toLowerCase().contains('km') ? number * 1000 : number;
  }

  String _guidanceDirection(String raw) {
    if (raw.trim().isEmpty || raw.contains('--')) {
      return 'the checkpoint';
    }

    // North-East / North East / NORTH_EAST -> NORTHEAST
    final normalized = raw
        .split('(')
        .first
        .trim()
        .toUpperCase()
        .replaceAll(
      RegExp(r'[^A-Z]'),
      '',
    );

    const names = {
      'N': 'north',
      'NE': 'northeast',
      'E': 'east',
      'SE': 'southeast',
      'S': 'south',
      'SW': 'southwest',
      'W': 'west',
      'NW': 'northwest',
      'NORTH': 'north',
      'NORTHEAST': 'northeast',
      'EAST': 'east',
      'SOUTHEAST': 'southeast',
      'SOUTH': 'south',
      'SOUTHWEST': 'southwest',
      'WEST': 'west',
      'NORTHWEST': 'northwest',
    };

    return names[normalized] ??
        raw.split('(').first.trim().toLowerCase();
  }

  void _scheduleFit() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fitMap();
    });
  }

  // Public entry point for the recenter button, which now lives in
  // _NavigationPage's floating overlay instead of inside this widget —
  // matching Puzzle's _mapKey.currentState?.recenter() pattern.
  Future<void> recenter() => _fitMap();

  Future<void> zoomIn() async {
    final controller = _controller;
    if (controller == null) return;

    await controller.animateCamera(
      CameraUpdate.zoomIn(),
    );
  }

  Future<void> zoomOut() async {
    final controller = _controller;
    if (controller == null) return;

    await controller.animateCamera(
      CameraUpdate.zoomOut(),
    );
  }

  Future<void> focusOnUser() async {
    final controller = _controller;
    if (controller == null) return;

    final user = _userPosition;
    if (user == null) {
      await _fitMap();
      return;
    }

    var zoom = 17.0;

    try {
      final currentZoom = await controller.getZoomLevel();
      if (currentZoom > zoom) {
        zoom = currentZoom;
      }
    } catch (_) {
      // Keep the safe default zoom if the current level is unavailable.
    }

    await controller.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(
          target: user,
          zoom: zoom,
          bearing: _deviceHeadingDegrees ?? 0,
          tilt: 0,
        ),
      ),
    );
  }

  Future<void> _fitMap() async {
    final controller = _controller;
    if (controller == null) return;

    final user = _userPosition;
    final checkpoint = _checkpointPosition;

    if (user != null && checkpoint != null) {
      final latDifference =
      (user.latitude - checkpoint.latitude).abs();
      final lngDifference =
      (user.longitude - checkpoint.longitude).abs();

      if (latDifference < 0.0001 && lngDifference < 0.0001) {
        await controller.animateCamera(
          CameraUpdate.newLatLngZoom(checkpoint, 17.5),
        );
        return;
      }

      final southWest = LatLng(
        user.latitude < checkpoint.latitude
            ? user.latitude
            : checkpoint.latitude,
        user.longitude < checkpoint.longitude
            ? user.longitude
            : checkpoint.longitude,
      );
      final northEast = LatLng(
        user.latitude > checkpoint.latitude
            ? user.latitude
            : checkpoint.latitude,
        user.longitude > checkpoint.longitude
            ? user.longitude
            : checkpoint.longitude,
      );

      try {
        await controller.animateCamera(
          CameraUpdate.newLatLngBounds(
            LatLngBounds(
              southwest: southWest,
              northeast: northEast,
            ),
            78,
          ),
        );
      } catch (_) {
        // Padding (badge + card heights) plus the 78px inset above can
        // exceed the viewport on a very small/short screen or while an
        // error banner is showing — newLatLngBounds throws rather than
        // just clamping. Leave the camera as-is rather than crash.
      }
      return;
    }

    final one = user ?? checkpoint;
    if (one != null) {
      await controller.animateCamera(
        CameraUpdate.newLatLngZoom(one, 15.8),
      );
    }
  }

  Set<Marker> _buildMarkers() {
    final markers =
    <Marker>{};

    final checkpoint =
        _checkpointPosition;

    if (checkpoint != null) {
      markers.add(
        Marker(
          markerId:
          const MarkerId(
            'trip_path_checkpoint',
          ),
          position:
          checkpoint,
          // Brand blue instead of the default red pin, to match the rest
          // of the app instead of reading as a warning/error colour.
          icon:
          BitmapDescriptor
              .defaultMarkerWithHue(
            BitmapDescriptor.hueAzure,
          ),
        ),
      );
    }

    // ==========================================================
    // ROTATING USER MARKER
    //
    // Position = live GPS
    // Rotation = physical phone compass heading
    // ==========================================================

    final user =
        _userPosition;

    final userIcon =
        _userHeadingMarkerIcon;

    if (user != null &&
        userIcon != null) {
      markers.add(
        Marker(
          markerId:
          const MarkerId(
            'trip_path_user_heading',
          ),
          position:
          user,
          icon:
          userIcon,
          anchor:
          const Offset(
            0.5,
            0.5,
          ),
          flat:
          true,
          rotation:
          _deviceHeadingDegrees ??
              0,
          zIndex:
          20,
          consumeTapEvents:
          false,
        ),
      );
    }

    return markers;
  }

  Set<Circle> _buildCircles() {
    final checkpoint = _checkpointPosition;
    if (checkpoint == null) return const <Circle>{};

    return {
      Circle(
        circleId: const CircleId('verification_radius'),
        center: checkpoint,
        radius: 50.0,
        strokeWidth: 2,
        strokeColor: widget.canVerify
            ? const Color(0xFF22C55E)
            : const Color(0xFF168AF5),
        fillColor: widget.canVerify
            ? const Color(0x2822C55E)
            : const Color(0x28168AF5),
      ),
    };
  }

  Set<Polyline> _buildPolylines() {
    final user = _userPosition;
    final checkpoint = _checkpointPosition;
    if (user == null || checkpoint == null) {
      return const <Polyline>{};
    }

    return {
      Polyline(
        polylineId: const PolylineId('direct_guidance_line'),
        points: [user, checkpoint],
        color: const Color(0xFF168AF5),
        width: 5,
        patterns: [
          PatternItem.dash(18.0),
          PatternItem.gap(10.0),
        ],
      ),
    };
  }

  @override
  void dispose() {
    _compassSubscription?.cancel();
    _compassSubscription = null;

    _controller?.dispose();
    _controller = null;

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Distance/direction/guidance used to also show here as a floating bar
    // over the map — removed as redundant with the Distance/Direction row
    // in the card below it (and to match the design reference, which keeps
    // the map itself free of overlaid text).
    // Full-bleed: this fills whatever it's given (Positioned.fill in
    // _NavigationPage's Stack, matching Puzzle's Navigate screen instead of
    // a fixed-height box above separate sections).
    //
    // The surrounding info cards/buttons stay fixed navy regardless of
    // theme (by explicit request — the "night explorer" brand look), but
    // the map tiles themselves follow the app's real light/dark/system
    // choice here, the same way the main Map screen's Google tiles already
    // do (see MapTilesService.createSession(dark:)) — a dark map skin
    // looked like a bug when the rest of the app was in light mode.
    final isDark =
        _darkAwareTripPathTheme(context).brightness == Brightness.dark;

    return ColoredBox(
      color: isDark ? const Color(0xFF0B1726) : Colors.white,
      child: Stack(
        children: [
          Positioned.fill(
            child: GoogleMap(
              initialCameraPosition: CameraPosition(
                target: _initialPosition,
                zoom: 15.5,
              ),
              onMapCreated: (controller) async {
                _controller = controller;
                await controller.setMapStyle(isDark ? _darkMapStyle : null);
                _scheduleFit();
              },
              markers: _buildMarkers(),
              circles: _buildCircles(),
              polylines: _buildPolylines(),
              // Custom heading-aware user marker is used instead
              // of Google's standard blue dot.
              myLocationEnabled: false,
              myLocationButtonEnabled: false,
              zoomControlsEnabled: false,
              compassEnabled: false,
              mapToolbarEnabled: false,
              buildingsEnabled: true,
              trafficEnabled: false,
              // Keeps newLatLngBounds fits (and the visible region generally)
              // clear of the floating overlay cards on top of the map.
              padding: widget.mapPadding,

              // The map sits under floating overlay cards in a Stack, not a
              // scroll view, but still needs to win the gesture arena for
              // one-finger drags. EagerGestureRecognizer gives the map the drag.
              gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
                Factory<OneSequenceGestureRecognizer>(
                      () => EagerGestureRecognizer(),
                ),
              },

              // User can freely move the map just like Google Maps.
              scrollGesturesEnabled: true,
              zoomGesturesEnabled: true,
              rotateGesturesEnabled: true,
              tiltGesturesEnabled: true,
            ),
          ),
        ],
      ),
    );
  }
}

/// White rounded button used by the map's right-side control rail.
class _SideMapControlButton extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;
  final bool enabled;
  final Color? iconColor;

  const _SideMapControlButton({
    required this.tooltip,
    required this.icon,
    required this.onTap,
    this.enabled = true,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    // Matches _MapControlButton's dark navy chip (the back button uses the
    // same look) instead of a plain white circle — this screen is part of
    // the fixed-navy "night explorer" family, so a light button here read
    // as a mismatched leftover rather than a deliberate accent.
    final foreground = enabled
        ? (iconColor ?? Colors.white)
        : Colors.white38;

    return Tooltip(
      message: tooltip,
      child: Material(
        color: enabled
            ? const Color(0xCC0B1F3D)
            : const Color(0x660B1F3D),
        elevation: enabled ? 4 : 1,
        shadowColor: const Color(0x66000000),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(14),
          child: SizedBox(
            width: 42,
            height: 42,
            child: Icon(
              icon,
              color: foreground,
              size: 19,
            ),
          ),
        ),
      ),
    );
  }
}

/// Same circular style as Puzzle's Navigate map controls (_NavRoundIconButton)
/// — kept as its own copy since the two screens live in separate files, but
/// deliberately visually identical.
class _MapControlButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _MapControlButton({
    required this.icon,
    required this.onTap,
  });

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

// ============================================================
// DISTANCE / DIRECTION CARDS
// ============================================================

class _NavigationMetricsRow extends StatelessWidget {
  final String distance;
  final String direction;

  const _NavigationMetricsRow({
    required this.distance,
    required this.direction,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _NavigationMetricCard(
            icon: Icons.navigation_rounded,
            label: 'Distance',
            value: distance,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _DirectionMetricCard(
            direction: direction,
          ),
        ),
      ],
    );
  }
}

class _NavigationMetricCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _NavigationMetricCard({
    required this.icon,
    required this.label,
    required this.value,
  });

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
            decoration: const BoxDecoration(
              color: Color(0xFFEAF4FF),
              shape: BoxShape.circle,
            ),
            child: Icon(
              icon,
              color: const Color(0xFF087FF5),
              size: 18,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Distance',
                  maxLines: 1,
                  softWrap: false,
                  style: TextStyle(
                    color: Color(0xFF64748B),
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                _OneLineFitText(
                  value,
                  style: const TextStyle(
                    color: Color(0xFF0F172A),
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

class _DirectionMetricCard extends StatelessWidget {
  final String direction;

  const _DirectionMetricCard({
    required this.direction,
  });

  IconData _directionArrowIcon(String raw) {
    // Use Material icons instead of Unicode arrow characters so all
    // eight directions use the same visual style on Android/iOS.
    //
    // North-East / North East / NORTH_EAST -> NORTHEAST
    final text = raw
        .split('(')
        .first
        .trim()
        .toUpperCase()
        .replaceAll(
      RegExp(r'[^A-Z]'),
      '',
    );

    switch (text) {
      case 'NE':
      case 'NORTHEAST':
        return Icons.north_east_rounded;

      case 'SE':
      case 'SOUTHEAST':
        return Icons.south_east_rounded;

      case 'SW':
      case 'SOUTHWEST':
        return Icons.south_west_rounded;

      case 'NW':
      case 'NORTHWEST':
        return Icons.north_west_rounded;

      case 'N':
      case 'NORTH':
        return Icons.north_rounded;

      case 'E':
      case 'EAST':
        return Icons.east_rounded;

      case 'S':
      case 'SOUTH':
        return Icons.south_rounded;

      case 'W':
      case 'WEST':
        return Icons.west_rounded;

      default:
        return Icons.navigation_rounded;
    }
  }

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
            decoration: const BoxDecoration(
              color: Color(0xFFFFF4DF),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.explore_rounded,
              color: Color(0xFFF08A00),
              size: 18,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Direction',
                  maxLines: 1,
                  softWrap: false,
                  style: TextStyle(
                    color: Color(0xFF64748B),
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Icon(
                      _directionArrowIcon(direction),
                      color: const Color(0xFFF08A00),
                      size: 17,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: _OneLineFitText(
                        direction,
                        style: const TextStyle(
                          color: Color(0xFF0F172A),
                          fontSize: 15,
                          fontWeight: FontWeight.w900,
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
    );
  }
}

// ============================================================
// 50 M VERIFICATION STATUS
// ============================================================

class _VerificationRangeCard extends StatelessWidget {
  final bool canVerify;
  final bool hasLocation;
  final String distanceText;

  const _VerificationRangeCard({
    required this.canVerify,
    required this.hasLocation,
    required this.distanceText,
  });

  @override
  Widget build(BuildContext context) {
    final reached = canVerify && hasLocation;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 9, 10, 9),
      decoration: BoxDecoration(
        color: reached
            ? const Color(0xFFE9FFF2)
            : const Color(0xFFF1F7FD),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: reached
              ? const Color(0xFFB7F1CF)
              : const Color(0xFFD7E6F5),
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
              reached
                  ? Icons.location_on_rounded
                  : Icons.lock_rounded,
              color: reached
                  ? const Color(0xFF18A957)
                  : const Color(0xFF64748B),
              size: 19,
            ),
          ),
          const SizedBox(width: 11),
          // No distance number here — it's already the Distance box right
          // above this card, so this is status text only (matches the
          // design reference's plain "You're close enough!" banner).
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _OneLineFitText(
                  reached
                      ? "You're close enough! Verification is now available."
                      : hasLocation
                      ? 'Keep moving toward the checkpoint'
                      : 'Waiting for your GPS position',
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
                  _OneLineFitText(
                    hasLocation
                        ? 'Verify unlocks within 50 m'
                        : 'Location is required to unlock verification.',
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

// ============================================================
// GPS LOADING
// ============================================================

class _NavigationLoadingCard extends StatelessWidget {
  const _NavigationLoadingCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFEFF8FF),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFBAE6FD)),
      ),
      child: const Row(
        children: [
          SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2.4,
              color: Color(0xFF0284C7),
            ),
          ),
          SizedBox(width: 11),
          Expanded(
            child: Text(
              'Getting your live GPS position...',
              maxLines: 1,
              softWrap: false,
              style: TextStyle(
                color: Color(0xFF075985),
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// NAVIGATION ERROR
// ============================================================

class _NavigationErrorCard extends StatelessWidget {
  final String message;
  final Future<void> Function() onRetry;
  final Future<void> Function() onLocationSettings;
  final Future<void> Function() onAppSettings;

  const _NavigationErrorCard({
    required this.message,
    required this.onRetry,
    required this.onLocationSettings,
    required this.onAppSettings,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF1F2),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFFECACA)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.location_off_rounded,
                color: Color(0xFFDC2626),
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message,
                  style: const TextStyle(
                    color: Color(0xFF991B1B),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 9),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              TextButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded, size: 17),
                label: const Text('Retry'),
              ),
              TextButton.icon(
                onPressed: onLocationSettings,
                icon: const Icon(Icons.location_on_outlined, size: 17),
                label: const Text('Location Settings'),
              ),
              TextButton.icon(
                onPressed: onAppSettings,
                icon: const Icon(Icons.settings_outlined, size: 17),
                label: const Text('App Settings'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ============================================================
// REUSABLE
// INFORMATION CARD
// ============================================================

class _InformationCard
    extends StatelessWidget {
  final String title;
  final Widget child;

  const _InformationCard({
    required this.title,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding:
      const EdgeInsets.all(
        20,
      ),
      decoration: BoxDecoration(
        color: context.colors.surfaceContainerLow,
        borderRadius:
        BorderRadius.circular(
          20,
        ),
        boxShadow: [
          BoxShadow(
            color:
            Colors.black.withValues(alpha: context.isDark ? 0.3 : 0.06),
            blurRadius: 12,
            offset: const Offset(
              0,
              2,
            ),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment:
        CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color:
              context.colors.onSurface,
              fontSize: 17,
              fontWeight:
              FontWeight.w800,
            ),
          ),

          const SizedBox(
            height: 12,
          ),

          child,
        ],
      ),
    );
  }
}

// ============================================================
// DETAIL ROW
// ============================================================

class _DetailRow
    extends StatelessWidget {
  final String label;
  final String value;
  final bool showBorder;

  const _DetailRow({
    required this.label,
    required this.value,
    this.showBorder = true,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding:
      const EdgeInsets.symmetric(
        vertical: 10,
      ),
      decoration: BoxDecoration(
        border: showBorder
            ? Border(
          bottom: BorderSide(
            color:
            context.colors.outlineVariant,
          ),
        )
            : null,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color:
                context.colors.onSurfaceVariant,
                fontSize: 14,
              ),
            ),
          ),

          const SizedBox(
            width: 12,
          ),

          Flexible(
            child: Text(
              value,
              textAlign:
              TextAlign.right,
              style: TextStyle(
                color:
                context.colors.onSurface,
                fontSize: 14,
                fontWeight:
                FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// MYSTERY CHECKPOINT ROW
// ============================================================

class _MysteryCheckpointRow
    extends StatelessWidget {
  final int number;
  final String theme;
  final String area;
  final bool showBorder;

  const _MysteryCheckpointRow({
    required this.number,
    required this.theme,
    required this.area,
    required this.showBorder,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding:
      const EdgeInsets.symmetric(
        vertical: 10,
      ),
      decoration: BoxDecoration(
        border: showBorder
            ? Border(
          bottom: BorderSide(
            color:
            context.colors.outlineVariant,
          ),
        )
            : null,
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: context.colors.primaryContainer,
              borderRadius:
              BorderRadius.circular(
                10,
              ),
            ),
            child: Text(
              '$number',
              style: TextStyle(
                fontWeight:
                FontWeight.w800,
                color:
                context.colors.onPrimaryContainer,
              ),
            ),
          ),

          const SizedBox(
            width: 12,
          ),

          Expanded(
            child: Column(
              crossAxisAlignment:
              CrossAxisAlignment.start,
              children: [
                Text(
                  'Mystery Location #$number',
                  style: TextStyle(
                    color:
                    context.colors.onSurface,
                    fontSize: 14,
                    fontWeight:
                    FontWeight.w700,
                  ),
                ),

                const SizedBox(
                  height: 2,
                ),

                Text(
                  '$theme · $area',
                  style: TextStyle(
                    color:
                    context.colors.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),

          Icon(
            Icons.lock_rounded,
            color: context.colors.onSurfaceVariant,
            size: 18,
          ),
        ],
      ),
    );
  }
}

// ============================================================
// RULE ROW
// ============================================================

class _RuleRow extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool showBottomSpace;

  const _RuleRow({
    required this.icon,
    required this.text,
    this.showBottomSpace = true,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom:
        showBottomSpace ? 12 : 0,
      ),
      child: Row(
        crossAxisAlignment:
        CrossAxisAlignment.start,
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: context.colors.primaryContainer,
              borderRadius:
              BorderRadius.circular(
                9,
              ),
            ),
            child: Icon(
              icon,
              size: 17,
              color: context.colors.primary,
            ),
          ),

          const SizedBox(
            width: 10,
          ),

          Expanded(
            child: Padding(
              padding:
              const EdgeInsets.only(
                top: 4,
              ),
              child: Text(
                text,
                style:
                TextStyle(
                  color:
                  context.colors.onSurfaceVariant,
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// QUEST ARTWORK
//
// Temporary artwork visual.
// Real Theme Souvenir photo can replace this later.
// ============================================================

bool _isLoadableImageUrl(String url) {
  if (url.isEmpty) return false;
  final uri = Uri.tryParse(url);
  return uri != null &&
      const {'http', 'https'}.contains(uri.scheme) &&
      uri.host.isNotEmpty;
}

class _QuestArtwork extends StatelessWidget {
  final _ThemeStyle themeStyle;
  final int completed;
  final String? imageUrl;

  const _QuestArtwork({
    required this.themeStyle,
    required this.completed,
    required this.imageUrl,
  });

  @override
  Widget build(BuildContext context) {
    final normalizedUrl = imageUrl?.trim() ?? '';

    return ConstrainedBox(
      constraints: const BoxConstraints(
        maxWidth: 340,
      ),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: Colors.white24,
              width: 2,
            ),
            boxShadow: const [
              BoxShadow(
                color: Color(0x44000000),
                blurRadius: 24,
                offset: Offset(0, 10),
              ),
            ],
          ),
          child: _isLoadableImageUrl(normalizedUrl)
              ? _ProgressiveArtworkImage(
            imageUrl: normalizedUrl,
            completed: completed,
            themeStyle: themeStyle,
          )
              : _FallbackQuestArtwork(
            themeStyle: themeStyle,
            completed: completed,
          ),
        ),
      ),
    );
  }
}

class _ProgressiveArtworkImage extends StatefulWidget {
  final String imageUrl;
  final int completed;
  final _ThemeStyle themeStyle;

  const _ProgressiveArtworkImage({
    required this.imageUrl,
    required this.completed,
    required this.themeStyle,
  });

  @override
  State<_ProgressiveArtworkImage> createState() =>
      _ProgressiveArtworkImageState();
}

class _ProgressiveArtworkImageState extends State<_ProgressiveArtworkImage> {
  bool _failed = false;
  bool _loaded = false;

  static const ColorFilter _grayscaleFilter = ColorFilter.matrix(
    <double>[
      0.2126, 0.7152, 0.0722, 0, 0,
      0.2126, 0.7152, 0.0722, 0, 0,
      0.2126, 0.7152, 0.0722, 0, 0,
      0, 0, 0, 1, 0,
    ],
  );

  @override
  Widget build(BuildContext context) {
    // Generation is best-effort (free Pollinations API, no uptime
    // guarantee) — if the stored URL 404s or the network drops mid-load,
    // fall back to the same themed placeholder used when no URL exists at
    // all, instead of Flutter's default broken-image icon.
    if (_failed) {
      return _FallbackQuestArtwork(
        themeStyle: widget.themeStyle,
        completed: widget.completed,
      );
    }

    final imageProvider = NetworkImage(widget.imageUrl);
    final safeCompleted = widget.completed.clamp(0, 3).toInt();

    void onError(Object error, StackTrace? stack) {
      if (!mounted) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _failed = true);
      });
    }

    // Preloaded artwork (see TripPathQuestViewModel._precacheArtworkImage)
    // usually already has a decoded frame sitting in the cache by the time
    // this screen builds, so `frame` arrives on the very first build and
    // this spinner never actually shows. It only appears on a cold load —
    // e.g. preload hadn't finished yet, or the cache was evicted.
    void onFirstFrame() {
      if (!mounted || _loaded) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _loaded = true);
      });
    }

    // Puzzle reveal order for a landscape artwork:
    // CP1 -> left puzzle piece
    // CP2 -> centre puzzle piece
    // CP3 -> right puzzle piece / full colour
    final colouredPieces = <int>[
      if (safeCompleted >= 1) 0,
      if (safeCompleted >= 2) 1,
      if (safeCompleted >= 3) 2,
    ];

    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(
          color: const Color(0xFF475569),
          child: ColorFiltered(
            colorFilter: _grayscaleFilter,
            child: Image(
              image: imageProvider,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.medium,
              frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                if (frame != null) onFirstFrame();
                return child;
              },
              errorBuilder: (_, error, stack) {
                onError(error, stack);
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
        if (!_loaded)
          const Positioned.fill(
            child: IgnorePointer(
              child: Center(
                child: SizedBox(
                  width: 34,
                  height: 34,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.6,
                    color: Colors.white70,
                  ),
                ),
              ),
            ),
          ),
        for (final piece in colouredPieces)
          Positioned.fill(
            child: ClipPath(
              clipper: _ArtworkPuzzlePieceClipper(
                pieceIndex: piece,
              ),
              child: Image(
                image: imageProvider,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.medium,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          ),
        const Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _ArtworkPuzzleBoundaryPainter(),
            ),
          ),
        ),
      ],
    );
  }
}

class _ArtworkPuzzlePieceClipper extends CustomClipper<Path> {
  final int pieceIndex;

  const _ArtworkPuzzlePieceClipper({
    required this.pieceIndex,
  });

  static double boundaryOne(Size size, double t) {
    final width = size.width;
    final base = width * 0.335;
    final subtleWave =
        ui.lerpDouble(-width * 0.008, width * 0.008, (t + 1) / 2) ?? 0;

    double tab = 0;
    if (t >= 0.22 && t <= 0.58) {
      final local = (t - 0.22) / 0.36;
      tab = width * 0.075 * _smoothPuzzlePulse(local);
    }

    // A tiny opposite notch lower down makes the division feel less
    // like a simple wavy stripe and more like an interlocking piece.
    double notch = 0;
    if (t >= 0.68 && t <= 0.88) {
      final local = (t - 0.68) / 0.20;
      notch = -width * 0.030 * _smoothPuzzlePulse(local);
    }

    return base + subtleWave + tab + notch;
  }

  static double boundaryTwo(Size size, double t) {
    final width = size.width;
    final base = width * 0.665;
    final subtleWave =
        ui.lerpDouble(width * 0.008, -width * 0.008, (t + 1) / 2) ?? 0;

    double notch = 0;
    if (t >= 0.18 && t <= 0.38) {
      final local = (t - 0.18) / 0.20;
      notch = width * 0.028 * _smoothPuzzlePulse(local);
    }

    double tab = 0;
    if (t >= 0.46 && t <= 0.80) {
      final local = (t - 0.46) / 0.34;
      tab = -width * 0.075 * _smoothPuzzlePulse(local);
    }

    return base + subtleWave + notch + tab;
  }

  static double _smoothPuzzlePulse(double value) {
    // 0 -> 1 -> 0 with softened shoulders. Avoid dart:math so this
    // stays lightweight and deterministic.
    final x = value.clamp(0.0, 1.0);
    if (x <= 0.5) {
      final t = x * 2;
      return t * t * (3 - 2 * t);
    }
    final t = (1 - x) * 2;
    return t * t * (3 - 2 * t);
  }

  @override
  Path getClip(Size size) {
    const steps = 48;
    final path = Path();

    double b1(double t) => boundaryOne(size, t);
    double b2(double t) => boundaryTwo(size, t);
    double y(double t) => size.height * t;

    switch (pieceIndex) {
      case 0:
        path.moveTo(0, 0);
        path.lineTo(b1(0), 0);
        for (var i = 1; i <= steps; i++) {
          final t = i / steps;
          path.lineTo(b1(t), y(t));
        }
        path.lineTo(0, size.height);
        break;

      case 1:
        path.moveTo(b1(0), 0);
        path.lineTo(b2(0), 0);
        for (var i = 1; i <= steps; i++) {
          final t = i / steps;
          path.lineTo(b2(t), y(t));
        }
        path.lineTo(b1(1), size.height);
        for (var i = steps - 1; i >= 0; i--) {
          final t = i / steps;
          path.lineTo(b1(t), y(t));
        }
        break;

      case 2:
      default:
        path.moveTo(b2(0), 0);
        path.lineTo(size.width, 0);
        path.lineTo(size.width, size.height);
        path.lineTo(b2(1), size.height);
        for (var i = steps - 1; i >= 0; i--) {
          final t = i / steps;
          path.lineTo(b2(t), y(t));
        }
        break;
    }

    path.close();
    return path;
  }

  @override
  bool shouldReclip(
      covariant _ArtworkPuzzlePieceClipper oldClipper,
      ) {
    return oldClipper.pieceIndex != pieceIndex;
  }
}

class _ArtworkPuzzleBoundaryPainter extends CustomPainter {
  const _ArtworkPuzzleBoundaryPainter();

  @override
  void paint(Canvas canvas, Size size) {
    const steps = 48;
    final paint = Paint()
      ..color = const Color(0x66FFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;

    Path buildBoundary(double Function(Size, double) boundary) {
      final path = Path()
        ..moveTo(boundary(size, 0), 0);

      for (var i = 1; i <= steps; i++) {
        final t = i / steps;
        path.lineTo(
          boundary(size, t),
          size.height * t,
        );
      }

      return path;
    }

    canvas.drawPath(
      buildBoundary(_ArtworkPuzzlePieceClipper.boundaryOne),
      paint,
    );
    canvas.drawPath(
      buildBoundary(_ArtworkPuzzlePieceClipper.boundaryTwo),
      paint,
    );
  }

  @override
  bool shouldRepaint(
      covariant _ArtworkPuzzleBoundaryPainter oldDelegate,
      ) => false;
}

class _FallbackQuestArtwork extends StatelessWidget {
  final _ThemeStyle themeStyle;
  final int completed;

  const _FallbackQuestArtwork({
    required this.themeStyle,
    required this.completed,
  });

  @override
  Widget build(BuildContext context) {
    final safeCompleted = completed.clamp(0, 3).toInt();

    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(
          color: Color(0xFF475569),
        ),
        for (var piece = 0; piece < safeCompleted; piece++)
          Positioned.fill(
            child: ClipPath(
              clipper: _ArtworkPuzzlePieceClipper(
                pieceIndex: piece,
              ),
              child: ColoredBox(
                color: themeStyle.color,
              ),
            ),
          ),
        Center(
          child: Icon(
            themeStyle.icon,
            size: 54,
            color: safeCompleted > 1
                ? Colors.white
                : Colors.white54,
          ),
        ),
        const Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _ArtworkPuzzleBoundaryPainter(),
            ),
          ),
        ),
      ],
    );
  }
}

// ============================================================
// ARTWORK PROGRESS ROW
// ============================================================

class _ArtworkProgressRow
    extends StatelessWidget {
  final int number;
  final String section;
  final bool completed;
  final bool showBorder;

  const _ArtworkProgressRow({
    required this.number,
    required this.section,
    required this.completed,
    this.showBorder = true,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding:
      const EdgeInsets.symmetric(
        vertical: 9,
      ),
      decoration: BoxDecoration(
        border: showBorder
            ? const Border(
          bottom: BorderSide(
            color: Colors.white12,
          ),
        )
            : null,
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: completed
                  ? const Color(
                0xFF16A34A,
              )
                  : Colors.white.withOpacity(
                0.09,
              ),
              borderRadius:
              BorderRadius.circular(
                10,
              ),
            ),
            child: completed
                ? const Icon(
              Icons.check_rounded,
              color: Colors.white,
              size: 18,
            )
                : Text(
              '$number',
              style:
              const TextStyle(
                color: Colors.white,
                fontWeight:
                FontWeight.w700,
              ),
            ),
          ),

          const SizedBox(
            width: 12,
          ),

          Expanded(
            child: Column(
              crossAxisAlignment:
              CrossAxisAlignment.start,
              children: [
                Text(
                  'Checkpoint $number',
                  style: TextStyle(
                    color: completed
                        ? const Color(
                      0xFF4ADE80,
                    )
                        : Colors.white,
                    fontSize: 13,
                    fontWeight:
                    FontWeight.w700,
                  ),
                ),

                const SizedBox(
                  height: 2,
                ),

                Text(
                  'Restores $section of the artwork in colour',
                  style:
                  const TextStyle(
                    color:
                    Colors.white38,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),

          Text(
            '$number/3',
            style: const TextStyle(
              color: Colors.white38,
              fontSize: 11,
              fontWeight:
              FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// CHECKPOINT PROGRESS
// ============================================================

class _CheckpointProgress
    extends StatelessWidget {
  final int current;

  const _CheckpointProgress({
    required this.current,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding:
      const EdgeInsets.fromLTRB(
        20,
        16,
        20,
        10,
      ),
      decoration: BoxDecoration(
        color: context.colors.surfaceContainerLow,
        borderRadius:
        BorderRadius.circular(
          20,
        ),
        boxShadow: [
          BoxShadow(
            color:
            Colors.black.withValues(alpha: context.isDark ? 0.3 : 0.06),
            blurRadius: 12,
            offset: const Offset(
              0,
              2,
            ),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment:
            MainAxisAlignment
                .spaceBetween,
            children: [
              Text(
                'Quest Progress',
                style: TextStyle(
                  color:
                  context.colors.onSurface,
                  fontSize: 14,
                  fontWeight:
                  FontWeight.w700,
                ),
              ),

              Text(
                '${current - 1} / 3 done',
                style: TextStyle(
                  color:
                  context.colors.primary,
                  fontSize: 13,
                  fontWeight:
                  FontWeight.w600,
                ),
              ),
            ],
          ),

          const SizedBox(
            height: 16,
          ),

          Row(
            children: [
              for (
              int i = 1;
              i <= 3;
              i++
              ) ...[
                _CheckpointCircle(
                  number: i,
                  current: i == current,
                  completed:
                  i < current,
                ),

                if (i < 3)
                  Expanded(
                    child: Container(
                      height: 3,
                      margin:
                      const EdgeInsets
                          .symmetric(
                        horizontal: 5,
                      ),
                      color: i < current
                          ? context.appColors.success
                          : context.colors.outlineVariant,
                    ),
                  ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

// ============================================================
// CHECKPOINT CIRCLE
// ============================================================

class _CheckpointCircle
    extends StatelessWidget {
  final int number;
  final bool current;
  final bool completed;

  const _CheckpointCircle({
    required this.number,
    required this.current,
    required this.completed,
  });

  @override
  Widget build(BuildContext context) {
    Color background;
    Color foreground;

    if (completed) {
      background = context.appColors.success;
      foreground = context.appColors.onSuccess;
    } else if (current) {
      background = context.colors.primary;
      foreground = context.colors.onPrimary;
    } else {
      background = context.colors.surfaceContainerHighest;
      foreground = context.colors.onSurfaceVariant;
    }

    return Column(
      children: [
        Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: background,
            shape: BoxShape.circle,
            border: current
                ? Border.all(
              color: context.colors.primary.withValues(alpha: 0.4),
              width: 2,
            )
                : null,
          ),
          child: completed
              ? Icon(
            Icons.check_rounded,
            color: foreground,
            size: 18,
          )
              : Text(
            '$number',
            style: TextStyle(
              color: foreground,
              fontWeight:
              FontWeight.w700,
            ),
          ),
        ),

        const SizedBox(
          height: 4,
        ),

        Text(
          completed
              ? 'Done'
              : current
              ? 'Now'
              : 'Locked',
          style: TextStyle(
            color: completed
                ? context.appColors.success
                : current
                ? context.colors.primary
                : context.colors.onSurfaceVariant,
            fontSize: 9,
            fontWeight:
            FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
