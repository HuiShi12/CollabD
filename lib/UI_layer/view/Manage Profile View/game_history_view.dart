import 'package:flutter/material.dart';

import '../../../main.dart';
import '../../viewmodel/Manage Profile ViewModel/profile_viewmodel.dart';
import 'widgets/profile_widgets.dart';

class GameHistoryView extends StatefulWidget {
  final ManageProfileViewModel viewModel;

  const GameHistoryView({
    super.key,
    required this.viewModel,
  });

  @override
  State<GameHistoryView> createState() => _GameHistoryViewState();
}

class _GameHistoryViewState extends State<GameHistoryView> {
  bool _initialLoading = true;
  final Set<String> _deletingIds = <String>{};

  // Filter bar state — two independent toggle rows (status, game type) so
  // the tourist can narrow a long history list instead of scrolling through
  // every in-progress/completed/abandoned game of both types at once. All
  // on by default (matches the unfiltered list this screen showed before).
  // Abandoned games aren't behind a toggle of their own (only two statuses
  // were asked for) but still respect the type filter below.
  bool _showInProgress = true;
  bool _showCompleted = true;
  bool _showPuzzle = true;
  bool _showTripPath = true;

  @override
  void initState() {
    super.initState();
    // loadGameHistory() calls notifyListeners() synchronously before its
    // first await (to flip isGameHistoryLoading on immediately) — calling
    // it straight from initState() fires that notify while this screen's
    // own first build is still in progress ("setState() or
    // markNeedsBuild() called during build"). Flutter tolerates it instead
    // of crashing, but it's still a real bug; deferring to the next frame
    // avoids it entirely.
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadHistory());
  }

  Future<void> _loadHistory() async {
    await widget.viewModel.loadGameHistory();

    if (!mounted) {
      return;
    }

    setState(() {
      _initialLoading = false;
    });
  }

  Future<void> _refreshHistory() async {
    await widget.viewModel.loadGameHistory();

    if (!mounted) {
      return;
    }

    setState(() {});
  }

  // =========================================================
  // BUILD
  // =========================================================

  @override
  Widget build(BuildContext context) {
    final gameHistory = widget.viewModel.gameHistory;

    bool typeVisible(GameHistoryItem g) =>
        g.type == 'Mystery Puzzle' ? _showPuzzle : _showTripPath;

    final inProgressGames = _showInProgress
        ? gameHistory
            .where((g) => g.status == 'In Progress' && typeVisible(g))
            .toList()
        : <GameHistoryItem>[];
    final completedGames = _showCompleted
        ? gameHistory
            .where((g) => g.status == 'Completed' && typeVisible(g))
            .toList()
        : <GameHistoryItem>[];
    final abandonedGames = gameHistory
        .where((g) => g.status == 'Abandoned' && typeVisible(g))
        .toList();

    return ProfilePage(
      title: 'Game & Place History',
      trailing: IconButton(
        onPressed: _refreshHistory,
        icon: Icon(Icons.refresh_rounded, color: context.colors.primary),
      ),
      child: _buildContent(
        inProgressGames: inProgressGames,
        completedGames: completedGames,
        abandonedGames: abandonedGames,
        // Whether there's any history at all, ignoring the filters — decides
        // between "you haven't played anything yet" and "nothing matches
        // these filters" when the filtered lists come up empty.
        hasAnyAtAll: gameHistory.isNotEmpty,
      ),
    );
  }

  Widget _buildContent({
    required List<GameHistoryItem> inProgressGames,
    required List<GameHistoryItem> completedGames,
    required List<GameHistoryItem> abandonedGames,
    required bool hasAnyAtAll,
  }) {
    if (_initialLoading || widget.viewModel.isGameHistoryLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (widget.viewModel.gameHistoryErrorMessage != null) {
      return _errorState(widget.viewModel.gameHistoryErrorMessage!);
    }

    if (!hasAnyAtAll) {
      return RefreshIndicator(
        onRefresh: _refreshHistory,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.sm,
            AppSpacing.lg,
            AppSpacing.xxl,
          ),
          children: [_emptyState()],
        ),
      );
    }

    final hasVisible = inProgressGames.isNotEmpty ||
        completedGames.isNotEmpty ||
        abandonedGames.isNotEmpty;

    return Column(
      children: [
        _buildFilterBar(),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _refreshHistory,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.sm,
                AppSpacing.lg,
                AppSpacing.xxl,
              ),
              children: [
                if (!hasVisible)
                  _filteredEmptyState()
                else ...[
                  if (inProgressGames.isNotEmpty) ...[
                    _sectionTitle('In Progress', context.appColors.warning),
                    AppSpacing.gapMd,
                    ...inProgressGames.map(_inProgressCard),
                    AppSpacing.gapSm,
                  ],
                  if (completedGames.isNotEmpty) ...[
                    _sectionTitle('Completed', context.appColors.success),
                    AppSpacing.gapMd,
                    ...completedGames.map(_historyCard),
                    AppSpacing.gapSm,
                  ],
                  if (abandonedGames.isNotEmpty) ...[
                    _sectionTitle('Abandoned', context.colors.error),
                    AppSpacing.gapMd,
                    ...abandonedGames.map(_historyCard),
                  ],
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  // =========================================================
  // FILTER BAR
  // =========================================================

  Widget _buildFilterBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        0,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.xs,
            children: [
              _filterChip(
                label: 'In Progress',
                color: context.appColors.warning,
                selected: _showInProgress,
                onSelected: (v) => setState(() => _showInProgress = v),
              ),
              _filterChip(
                label: 'Completed',
                color: context.appColors.success,
                selected: _showCompleted,
                onSelected: (v) => setState(() => _showCompleted = v),
              ),
            ],
          ),
          AppSpacing.gapXs,
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.xs,
            children: [
              _filterChip(
                label: '🧩 Puzzle',
                color: context.colors.primary,
                selected: _showPuzzle,
                onSelected: (v) => setState(() => _showPuzzle = v),
              ),
              _filterChip(
                label: '🗺️ Trip Path',
                color: context.colors.primary,
                selected: _showTripPath,
                onSelected: (v) => setState(() => _showTripPath = v),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _filterChip({
    required String label,
    required Color color,
    required bool selected,
    required ValueChanged<bool> onSelected,
  }) {
    return FilterChip(
      label: Text(label),
      selected: selected,
      onSelected: onSelected,
      showCheckmark: false,
      selectedColor: color.withValues(alpha: 0.16),
      backgroundColor: context.colors.surfaceContainerHigh,
      labelStyle: context.text.labelMedium?.copyWith(
        color: selected ? color : context.colors.onSurfaceVariant,
        fontWeight: FontWeight.w700,
      ),
      side: BorderSide(
        color: selected
            ? color.withValues(alpha: 0.5)
            : context.colors.outlineVariant,
      ),
      shape: const StadiumBorder(),
    );
  }

  Widget _filteredEmptyState() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxl),
      child: Column(
        children: [
          Icon(
            Icons.filter_alt_off_rounded,
            size: 40,
            color: context.colors.onSurfaceVariant,
          ),
          AppSpacing.gapSm,
          Text(
            'No games match these filters.',
            style: context.text.bodyMedium?.copyWith(
              color: context.colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  // =========================================================
  // TYPE ICON
  // =========================================================

  String _typeEmoji(String type) =>
      type == 'Mystery Puzzle' ? '🧩' : '🗺️';

  // =========================================================
  // SECTION TITLE
  // =========================================================

  Widget _sectionTitle(String title, Color color) {
    return Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: AppSpacing.sm),
        Text(
          title.toUpperCase(),
          style: context.text.labelMedium?.copyWith(
            color: context.colors.onSurface,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
          ),
        ),
      ],
    );
  }

  // =========================================================
  // IN PROGRESS CARD
  // =========================================================

  Widget _inProgressCard(GameHistoryItem game) {
    final hasNumericProgress = game.type == 'Trip Path Quest';
    final progress = _progressValue(game.progress);

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 14),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: context.colors.surfaceContainerHigh,
        borderRadius: AppRadius.brLg,
        border: Border.all(
          color: context.appColors.warning.withValues(alpha: 0.4),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: context.isDark ? 0.32 : 0.07),
            blurRadius: 16,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.sm,
            ),
            color: context.appColors.warningSurface,
            child: Row(
              children: [
                Text(_typeEmoji(game.type), style: const TextStyle(fontSize: 20)),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        game.type,
                        style: context.text.labelLarge?.copyWith(
                          color: context.appColors.warning,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        game.title,
                        style: context.text.labelSmall?.copyWith(
                          color: context.colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                ProfileStatusBadge(
                  text: 'In Progress',
                  background: context.appColors.warningSurface,
                  foreground: context.appColors.warning,
                ),
                IconButton(
                  tooltip: 'Delete history',
                  onPressed: _deletingIds.contains(game.id)
                      ? null
                      : () => _confirmDelete(game),
                  icon: _deletingIds.contains(game.id)
                      ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                      : Icon(
                    Icons.delete_outline_rounded,
                    color: context.colors.error,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            hasNumericProgress ? 'Progress' : 'Current Stage',
                            style: context.text.bodySmall?.copyWith(
                              color: context.colors.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: AppSpacing.xxs),
                          Text(
                            game.subtitle,
                            style: context.text.bodyMedium?.copyWith(
                              color: context.colors.onSurface,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          'Last Played',
                          style: context.text.bodySmall?.copyWith(
                            color: context.colors.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.xxs),
                        Text(
                          game.date,
                          style: context.text.bodySmall?.copyWith(
                            color: context.colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                if (hasNumericProgress) ...[
                  AppSpacing.gapSm,
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      minHeight: 6,
                      value: progress,
                      backgroundColor:
                      context.colors.surfaceContainerHighest,
                    ),
                  ),
                ],
                if (game.placeNames.isNotEmpty) ...[
                  AppSpacing.gapSm,
                  Align(
                    alignment: Alignment.centerLeft,
                    child: _PlaceNamesList(names: game.placeNames),
                  ),
                ],
                AppSpacing.gapMd,
                SizedBox(
                  width: double.infinity,
                  height: 44,
                  child: FilledButton(
                    onPressed: _deletingIds.contains(game.id)
                        ? null
                        : () => _continueGame(game),
                    child: const Text('▶  Continue Game'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // =========================================================
  // COMPLETED / ABANDONED CARD
  // =========================================================

  Widget _historyCard(GameHistoryItem game) {
    final completed = game.status == 'Completed';

    final badgeBackground = completed
        ? context.appColors.successSurface
        : context.colors.errorContainer;
    final badgeForeground =
    completed ? context.appColors.success : context.colors.error;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.lg,
      ),
      decoration: BoxDecoration(
        color: context.colors.surfaceContainerHigh,
        borderRadius: AppRadius.brLg,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: context.isDark ? 0.32 : 0.06),
            blurRadius: 12,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: context.colors.surfaceContainerHighest,
              borderRadius: AppRadius.brMd,
            ),
            child: Text(_typeEmoji(game.type), style: const TextStyle(fontSize: 22)),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  game.type,
                  style: context.text.labelLarge?.copyWith(
                    color: context.colors.onSurface,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: AppSpacing.xxs),
                Text(
                  game.title,
                  style: context.text.bodyMedium?.copyWith(
                    color: context.colors.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: AppSpacing.xxs),
                Text(
                  game.subtitle,
                  style: context.text.bodySmall?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
                ),
                if (game.progress != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    'Progress: ${game.progress}',
                    style: context.text.bodySmall?.copyWith(
                      color: completed
                          ? context.appColors.success
                          : context.colors.onSurfaceVariant,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
                if (game.placeNames.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _PlaceNamesList(names: game.placeNames),
                ],
                AppSpacing.gapSm,
                Row(
                  children: [
                    ProfileStatusBadge(
                      text: game.status,
                      background: badgeBackground,
                      foreground: badgeForeground,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Text(
                      game.date,
                      style: context.text.bodySmall?.copyWith(
                        color: context.colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (!completed)
            IconButton(
              tooltip: 'Delete history',
              onPressed: _deletingIds.contains(game.id)
                  ? null
                  : () => _confirmDelete(game),
              icon: _deletingIds.contains(game.id)
                  ? const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
                  : Icon(
                Icons.delete_outline_rounded,
                color: context.colors.error,
              ),
            ),
        ],
      ),
    );
  }

  // =========================================================
  // PROGRESS VALUE
  // =========================================================

  double _progressValue(String? progress) {
    if (progress == null || !progress.contains('/')) {
      return 0;
    }

    final parts = progress.split('/');
    if (parts.length != 2) {
      return 0;
    }

    final completed = double.tryParse(parts[0]) ?? 0;
    final total = double.tryParse(parts[1]) ?? 0;

    if (total <= 0) {
      return 0;
    }

    return (completed / total).clamp(0.0, 1.0);
  }

  Future<void> _continueGame(GameHistoryItem game) async {
    final routeName = game.type == 'Mystery Puzzle'
        ? '/mystery-place-puzzle'
        : '/trip-path-quest';

    await Navigator.of(context).pushNamed(routeName, arguments: game.id);
    if (!mounted) return;

    // A continued game was opened from Game History, which itself was opened
    // from Manage Profile. Once the game closes, also close Game History so
    // the user returns directly to the Manage Profile menu.
    await Navigator.of(context).maybePop();
  }

  Future<void> _confirmDelete(GameHistoryItem game) async {
    final isInProgress = game.status == 'In Progress';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete history?'),
        content: Text(
          isInProgress
              ? 'This will permanently delete ${game.title} and its saved progress. You cannot continue it afterward.'
              : 'This will permanently remove ${game.title} from your game and place history.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: context.colors.error,
              foregroundColor: context.colors.onError,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _deletingIds.add(game.id));
    final deleted = await widget.viewModel.deleteGameHistoryItem(game);
    if (!mounted) return;
    setState(() => _deletingIds.remove(game.id));

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          deleted
              ? 'History deleted.'
              : widget.viewModel.gameHistoryActionErrorMessage ??
              'Unable to delete this history item.',
        ),
      ),
    );
  }

  // =========================================================
  // ERROR / EMPTY STATES
  // =========================================================

  Widget _errorState(String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline_rounded,
              color: context.colors.error,
              size: 48,
            ),
            AppSpacing.gapMd,
            Text(
              message,
              textAlign: TextAlign.center,
              style: context.text.bodyMedium?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
            AppSpacing.gapLg,
            ElevatedButton(
              onPressed: _refreshHistory,
              child: const Text('Try Again'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyState() {
    return Padding(
      padding: const EdgeInsets.only(
        top: 60,
        left: AppSpacing.lg,
        right: AppSpacing.lg,
      ),
      child: Column(
        children: [
          const Text('🗺️', style: TextStyle(fontSize: 64)),
          AppSpacing.gapLg,
          Text('No History Yet', style: context.text.titleMedium),
          AppSpacing.gapSm,
          Text(
            'Your Trip Path Quest and Mystery Puzzle history will appear here.',
            textAlign: TextAlign.center,
            style: context.text.bodyMedium?.copyWith(
              color: context.colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// Real place names for a Trip Path Quest's checkpoints actually visited so
/// far — never shown for a checkpoint not yet completed (UC-03 C3 / FR03_6:
/// the exact place stays hidden until the game reveals it). Callers only
/// build this when [names] is non-empty.
class _PlaceNamesList extends StatelessWidget {
  final List<String> names;
  const _PlaceNamesList({required this.names});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final name in names)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.place_rounded,
                  size: 14,
                  color: context.colors.primary,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    name,
                    style: context.text.bodySmall?.copyWith(
                      color: context.colors.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
