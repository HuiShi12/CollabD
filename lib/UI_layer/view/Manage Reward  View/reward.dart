import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../main.dart';
import '../../../Data_layer/repository/Reward Repository/reward_repository.dart';
import '../../viewmodel/Manage Reward  ViewModel/reward_viewmodel.dart';
import 'reward_image.dart';
import 'postcard.dart';
import 'marker_skins.dart';

/// Per-theme icon for a Theme Souvenir row, so Food/Culture/Heritage/Nature
/// are distinguishable at a glance instead of sharing one generic icon.
/// Same icon choices as the matching Marker Skin design (map.dart's
/// `_designIcon` for food_trailblazer/culture_keeper/heritage_guardian/
/// nature_ranger) — kept consistent rather than inventing a second set.
IconData _iconForTheme(String? theme) => switch (theme) {
  'Food' => Icons.restaurant_rounded,
  'Culture' => Icons.festival_rounded,
  'Heritage' => Icons.account_balance_rounded,
  'Nature' => Icons.park_rounded,
  _ => Icons.landscape_outlined,
};

/// Same theme → colour mapping as the matching Marker Skin design's `color`
/// field in RewardRepository.markerSkinDesigns (food_trailblazer,
/// culture_keeper, heritage_guardian, nature_ranger) — reused here so a
/// theme reads as the same colour everywhere in the app, not just a
/// different icon shape. Deliberately fixed (not theme/light-dark aware),
/// same as the source MarkerSkinDesign.color values themselves — a theme's
/// identity colour shouldn't change with the device's light/dark setting.
Color _colorForTheme(String? theme) => switch (theme) {
  'Food' => const Color(0xFFE8743B),
  'Culture' => const Color(0xFF7660D6),
  'Heritage' => const Color(0xFF267568),
  'Nature' => const Color(0xFF2E7D32),
  _ => const Color(0xFF0284C7),
};

/// A soft, low-contrast drop shadow used on every card-like surface on this
/// screen instead of a flat `elevation: 0` + hairline border — that
/// combination read as visually dead/flat. Kept as one shared constant so
/// every card lifts off the page background by the same amount. Black-based
/// regardless of theme — the usual Material convention for a drop shadow,
/// so it stays subtle rather than tracking text colour.
const _cardShadow = [
  BoxShadow(
    color: Color(0x0F000000),
    blurRadius: 16,
    offset: Offset(0, 4),
  ),
];

/// A circular tinted badge behind a reward-type icon — a plain bare icon on
/// a card had no visual weight; this gives it one, and doubles as the
/// per-theme colour cue (see [_colorForTheme]). Falls back to the app's
/// primary colour when no explicit colour is given.
class _IconBadge extends StatelessWidget {
  final IconData icon;
  final Color? color;
  final double size;
  const _IconBadge({
    required this.icon,
    this.color,
    this.size = 44,
  });
  @override
  Widget build(BuildContext context) {
    final resolved = color ?? context.colors.primary;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: resolved.withValues(alpha: 0.14),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, color: resolved, size: size * 0.5),
    );
  }
}

/// Three at-a-glance counts (Stamps / Souvenirs / Skins) shown above the
/// summary cards — a closer visual match to the app's earlier "Manage
/// Rewards" dashboard design, rebuilt with theme tokens (context.colors)
/// instead of that design's original hardcoded colours so it follows
/// light/dark/system correctly.
class _RewardStatsRow extends StatelessWidget {
  final int stampCount;
  final int souvenirCount;
  final int skinCount;
  const _RewardStatsRow({
    required this.stampCount,
    required this.souvenirCount,
    required this.skinCount,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _RewardStatCard(
            icon: Icons.local_post_office_outlined,
            count: stampCount,
            label: 'Stamps',
            color: context.colors.primary,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _RewardStatCard(
            icon: Icons.landscape_outlined,
            count: souvenirCount,
            label: 'Souvenirs',
            color: const Color(0xFF7660D6),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _RewardStatCard(
            icon: Icons.military_tech_rounded,
            count: skinCount,
            label: 'Skins',
            color: const Color(0xFFCA8A04),
          ),
        ),
      ],
    );
  }
}

class _RewardStatCard extends StatelessWidget {
  final IconData icon;
  final int count;
  final String label;
  final Color color;
  const _RewardStatCard({
    required this.icon,
    required this.count,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          color.withValues(alpha: 0.10),
          colors.surfaceContainerHigh,
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withValues(alpha: 0.22)),
        boxShadow: _cardShadow,
      ),
      child: Column(
        children: [
          _IconBadge(icon: icon, color: color, size: 38),
          const SizedBox(height: 10),
          Text(
            '$count',
            style: TextStyle(
              color: colors.onSurface,
              fontSize: 20,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              color: colors.onSurfaceVariant,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _confirmDeletePostcard(
  BuildContext context,
  RewardViewModel vm,
  DigitalPostcard card,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Delete this postcard?'),
      content: const Text('This cannot be undone.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(c, true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;
  final ok = await vm.deletePostcard(card.id);
  if (!context.mounted) return;
  if (!ok && vm.errorMessage != null) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(vm.errorMessage!)));
  }
}

class ManageRewardView extends StatelessWidget {
  const ManageRewardView({super.key});
  @override
  Widget build(BuildContext context) {
    final vm = context.watch<RewardViewModel>();
    final colors = context.colors;

    void openStampsList() => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => ChangeNotifierProvider.value(
              value: vm,
              child: const RewardCategoryListView(
                title: 'Digital Travel Stamps',
                icon: Icons.local_post_office_outlined,
                type: RewardType.digitalTravelStamp,
              ),
            ),
          ),
        );
    void openSouvenirsList() => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => ChangeNotifierProvider.value(
              value: vm,
              child: const RewardCategoryListView(
                title: 'Theme Souvenir Images',
                icon: Icons.landscape_outlined,
                type: RewardType.themeSouvenir,
              ),
            ),
          ),
        );
    void openMarkerSkins() => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => ChangeNotifierProvider.value(
              value: vm,
              child: const MarkerSkinsView(),
            ),
          ),
        );

    return Scaffold(
      backgroundColor: colors.surface,
      appBar: AppBar(
        backgroundColor: colors.surface,
        elevation: 0,
        foregroundColor: colors.onSurface,
        title: Text(
          'Rewards',
          style: TextStyle(color: colors.onSurface, fontWeight: FontWeight.w800),
        ),
      ),
      body: RefreshIndicator(
        color: colors.primary,
        onRefresh: vm.refreshRewards,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            Text(
              'Your Malaysian memories',
              style: TextStyle(
                color: colors.onSurface,
                fontSize: 24,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Collect moments from your explorations and turn them into a postcard.',
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 18),
            _RewardStatsRow(
              stampCount: vm.earnedStampCount,
              souvenirCount: vm.earnedSouvenirCount,
              skinCount: vm.earnedSkinCount,
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: colors.primary,
                  foregroundColor: colors.onPrimary,
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  textStyle: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                  elevation: 3,
                  shadowColor: colors.primary.withValues(alpha: 0.45),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                icon: const Icon(Icons.mail_outline),
                label: const Text('Create Digital Postcard'),
                onPressed: vm.isLoading
                    ? null
                    : () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => ChangeNotifierProvider.value(
                            value: vm,
                            child: const PostcardEditor(),
                          ),
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 18, key: ValueKey('header_spacer')),
            // Every conditional entry below gets its own stable key. With
            // none of these keyed, Flutter's default reconciliation
            // matches old/new children by (type, position) alone — when
            // isLoading/errorMessage/rewards.isEmpty toggle (which
            // happens on every load, including the very first one, the
            // instant loadRewards() finishes), whichever real content
            // sits right after these conditionals can have its element
            // identity — and with it, gesture recognizers — mismatched
            // against a stale element. That's the "Digital Travel
            // Stamps" section: first fixed content after this block, so
            // it absorbs the mismatch; the section below it is far
            // enough away to be unaffected.
            if (vm.isLoading || vm.isBusy)
              LinearProgressIndicator(
                key: const ValueKey('loading_indicator'),
                color: colors.primary,
              ),
            if (vm.errorMessage != null)
              Padding(
                key: const ValueKey('error_card'),
                padding: const EdgeInsets.only(top: 12),
                child: _ErrorCard(
                  message: vm.errorMessage!,
                  onRetry: vm.refreshRewards,
                ),
              ),
            if (!vm.isLoading && vm.rewards.isEmpty)
              const Padding(
                key: ValueKey('empty_banner'),
                padding: EdgeInsets.only(top: 24),
                child: _EmptyBanner(),
              ),
            _CategorySummaryCard(
              key: const ValueKey('stamps_section'),
              title: 'Digital Travel Stamps',
              icon: Icons.local_post_office_outlined,
              color: colors.primary,
              // Digital Travel Stamps are always already earned — there is
              // no "ready to claim" state for this type.
              unclaimedCount: 0,
              onTap: openStampsList,
            ),
            _CategorySummaryCard(
              key: const ValueKey('souvenirs_section'),
              title: 'Theme Souvenir Images',
              icon: Icons.landscape_outlined,
              color: const Color(0xFF7660D6),
              unclaimedCount: vm.themeSouvenirs
                  .where((r) => r.status == RewardStatus.readyToClaim)
                  .length,
              onTap: openSouvenirsList,
            ),
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                color: Color.alphaBlend(
                  const Color(0xFFCA8A04).withValues(alpha: 0.10),
                  colors.surfaceContainerHigh,
                ),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: const Color(0xFFCA8A04).withValues(alpha: 0.22),
                ),
                boxShadow: _cardShadow,
              ),
              clipBehavior: Clip.antiAlias,
              child: Material(
                color: Colors.transparent,
                child: ListTile(
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  leading: const _IconBadge(
                    icon: Icons.military_tech_rounded,
                    color: Color(0xFFCA8A04),
                  ),
                  title: Text(
                    'Marker Skins',
                    style:
                        TextStyle(color: colors.onSurface, fontWeight: FontWeight.w700),
                  ),
                  subtitle: Text(
                    'Unlock and equip map marker designs',
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                  trailing: Icon(Icons.chevron_right, color: colors.onSurfaceVariant),
                  onTap: openMarkerSkins,
                ),
              ),
            ),
            if (vm.postcards.isNotEmpty) ...[
              const SizedBox(height: 24),
              Text(
                'Saved postcards',
                style: TextStyle(
                  color: colors.onSurface,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              ...vm.postcards.map(
                (card) => _RewardCard(
                  key: ValueKey('postcard_${card.id}'),
                  leading: Icon(
                    Icons.mark_email_read_outlined,
                    color: colors.primary,
                  ),
                  title: card.message.isEmpty
                      ? 'Digital Postcard'
                      : card.message,
                  subtitle:
                      '${card.backgroundType} • ${rewardDate(card.createdAt)}',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ChangeNotifierProvider.value(
                        value: vm,
                        child: SavedPostcardView(
                          card: card,
                          rewards: vm.rewards,
                        ),
                      ),
                    ),
                  ),
                  onDelete: () => _confirmDeletePostcard(context, vm, card),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Dashboard-level entry for one reward category (Digital Travel Stamps /
/// Theme Souvenir Images). Used to keep "Your Malaysian memories" from
/// growing into one long scrolling list as the tourist earns more rewards —
/// this shows just a count + status summary and hands off to
/// [RewardCategoryListView] for the full collection.
class _CategorySummaryCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color color;
  final int unclaimedCount;
  final VoidCallback onTap;
  const _CategorySummaryCard({
    super.key,
    required this.title,
    required this.icon,
    required this.color,
    required this.unclaimedCount,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          color.withValues(alpha: 0.10),
          colors.surfaceContainerHigh,
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withValues(alpha: 0.22)),
        boxShadow: _cardShadow,
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: ListTile(
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          leading: _RewardLeadingIcon(
            icon: icon,
            color: color,
            showUnclaimedBadge: unclaimedCount > 0,
          ),
          title: Text(
            title,
            style: TextStyle(
              color: colors.onSurface,
              fontWeight: FontWeight.w700,
              fontSize: 15.5,
            ),
          ),
          trailing: Icon(Icons.chevron_right, color: colors.onSurfaceVariant),
          onTap: onTap,
        ),
      ),
    );
  }
}

/// The full collection for one reward category, opened from
/// [_CategorySummaryCard]. Reads live off [RewardViewModel] (rather than a
/// snapshot list) so claiming a Theme Souvenir from here updates this page
/// immediately, same as the old inline dashboard section did.
///
/// Carries its own search text + status/theme filters as local state —
/// purely a client-side view over whatever [RewardViewModel] already holds,
/// so it never needs to touch the network or reset when the underlying
/// reward list changes shape (e.g. after a claim).
class RewardCategoryListView extends StatefulWidget {
  final String title;
  final IconData icon;
  final RewardType type;
  const RewardCategoryListView({
    super.key,
    required this.title,
    required this.icon,
    required this.type,
  });

  @override
  State<RewardCategoryListView> createState() =>
      _RewardCategoryListViewState();
}

enum _RewardSort { newestFirst, oldestFirst, nameAZ }

class _RewardCategoryListViewState extends State<RewardCategoryListView> {
  final _searchController = TextEditingController();
  String _query = '';
  RewardStatus? _statusFilter;
  String? _themeFilter;
  _RewardSort _sort = _RewardSort.newestFirst;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  // The date that actually matters for sorting "when did I get this" — for
  // a Digital Travel Stamp this is the same instant as completedAt (it's
  // auto-earned), but for a Theme Souvenir earnedAt can trail completedAt by
  // however long the tourist waited to tap Claim, so earnedAt (when set) is
  // the truer "date I got it".
  DateTime _sortDate(TouristReward r) => r.earnedAt ?? r.completedAt;

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<RewardViewModel>();
    final colors = context.colors;
    final allRewards = widget.type == RewardType.digitalTravelStamp
        ? vm.digitalTravelStamps
        : vm.themeSouvenirs;

    final query = _query.trim().toLowerCase();
    final filtered = allRewards.where((r) {
      if (_statusFilter != null && r.status != _statusFilter) return false;
      if (_themeFilter != null && r.theme != _themeFilter) return false;
      if (query.isNotEmpty && !r.title.toLowerCase().contains(query)) {
        return false;
      }
      return true;
    }).toList()
      ..sort(switch (_sort) {
        _RewardSort.newestFirst => (a, b) =>
            _sortDate(b).compareTo(_sortDate(a)),
        _RewardSort.oldestFirst => (a, b) =>
            _sortDate(a).compareTo(_sortDate(b)),
        _RewardSort.nameAZ => (a, b) =>
            a.title.toLowerCase().compareTo(b.title.toLowerCase()),
      });

    final hasActiveFilter =
        query.isNotEmpty || _statusFilter != null || _themeFilter != null;

    return Scaffold(
      backgroundColor: colors.surface,
      appBar: AppBar(
        backgroundColor: colors.surface,
        elevation: 0,
        foregroundColor: colors.onSurface,
        title: Text(
          widget.title,
          style: TextStyle(color: colors.onSurface, fontWeight: FontWeight.w800),
        ),
        actions: [
          PopupMenuButton<_RewardSort>(
            tooltip: 'Sort',
            icon: Icon(Icons.sort_rounded, color: colors.onSurface),
            initialValue: _sort,
            onSelected: (v) => setState(() => _sort = v),
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: _RewardSort.newestFirst,
                child: Text('Newest first'),
              ),
              PopupMenuItem(
                value: _RewardSort.oldestFirst,
                child: Text('Oldest first'),
              ),
              PopupMenuItem(
                value: _RewardSort.nameAZ,
                child: Text('Name (A-Z)'),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
            child: _SearchField(
              controller: _searchController,
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          _FilterChipsRow(
            type: widget.type,
            statusFilter: _statusFilter,
            themeFilter: _themeFilter,
            onStatusChanged: (v) => setState(() => _statusFilter = v),
            onThemeChanged: (v) => setState(() => _themeFilter = v),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: allRewards.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      'Your collection will appear here.',
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                  )
                : filtered.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(20),
                        child: Text(
                          hasActiveFilter
                              ? 'No rewards match your search/filter.'
                              : 'Your collection will appear here.',
                          style: TextStyle(color: colors.onSurfaceVariant),
                        ),
                      )
                    : ListView.builder(
                        padding:
                            const EdgeInsets.fromLTRB(20, 4, 20, 32),
                        itemCount: filtered.length,
                        itemBuilder: (context, index) {
                          final reward = filtered[index];
                          return _RewardCard(
                            key: ValueKey(reward.id),
                            leading: _RewardLeadingIcon(
                              icon: widget.type == RewardType.themeSouvenir
                                  ? _iconForTheme(reward.theme)
                                  : widget.icon,
                              color: widget.type == RewardType.themeSouvenir
                                  ? _colorForTheme(reward.theme)
                                  : null,
                              // UC-06 — a Theme Souvenir the tourist hasn't
                              // claimed yet gets a red notification dot so
                              // it doesn't get lost among earned ones;
                              // Digital Travel Stamps are always earned
                              // already (no "ready to claim" state), so
                              // this never shows on that page.
                              showUnclaimedBadge: reward.type ==
                                      RewardType.themeSouvenir &&
                                  reward.status ==
                                      RewardStatus.readyToClaim,
                            ),
                            title: reward.title,
                            subtitle:
                                '${reward.statusLabel} • ${rewardDate(_sortDate(reward))}',
                            onTap: vm.isBusy
                                ? null
                                : () async {
                                    final ok =
                                        await vm.selectReward(reward.id);
                                    if (!context.mounted || !ok) return;
                                    Navigator.of(context).push(
                                      MaterialPageRoute<void>(
                                        builder: (_) =>
                                            ChangeNotifierProvider.value(
                                          value: vm,
                                          child: const RewardDetailView(),
                                        ),
                                      ),
                                    );
                                  },
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  const _SearchField({required this.controller, required this.onChanged});
  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: _cardShadow,
      ),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        style: TextStyle(color: colors.onSurface, fontWeight: FontWeight.w600),
        decoration: InputDecoration(
          hintText: 'Search by name',
          hintStyle:
              TextStyle(color: colors.onSurfaceVariant, fontWeight: FontWeight.w500),
          prefixIcon: Icon(Icons.search_rounded, color: colors.onSurfaceVariant),
          suffixIcon: controller.text.isEmpty
              ? null
              : IconButton(
                  icon: Icon(Icons.close_rounded, color: colors.onSurfaceVariant),
                  onPressed: () {
                    controller.clear();
                    onChanged('');
                  },
                ),
          filled: true,
          fillColor: colors.surfaceContainerHigh,
          contentPadding: const EdgeInsets.symmetric(vertical: 0),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide(color: colors.primary, width: 1.5),
          ),
        ),
      ),
    );
  }
}

/// Status chips always shown ("All" / "Earned" / "Ready to claim" — the
/// latter only makes sense for Theme Souvenirs, but leaving it visible for
/// Digital Travel Stamps too is harmless: it will just always show 0
/// results there, since that type has no ready-to-claim state).
/// Theme chips ("Food" / "Culture" / "Heritage" / "Nature") only show for
/// [RewardType.themeSouvenir] — Digital Travel Stamps aren't theme-tagged.
class _FilterChipsRow extends StatelessWidget {
  final RewardType type;
  final RewardStatus? statusFilter;
  final String? themeFilter;
  final ValueChanged<RewardStatus?> onStatusChanged;
  final ValueChanged<String?> onThemeChanged;
  const _FilterChipsRow({
    required this.type,
    required this.statusFilter,
    required this.themeFilter,
    required this.onStatusChanged,
    required this.onThemeChanged,
  });

  @override
  Widget build(BuildContext context) {
    // Digital Travel Stamps have no "ready to claim" state — every one is
    // earned the instant it's created — so an Earned/Ready-to-claim status
    // filter would always be a no-op there. Only Theme Souvenirs (which do
    // sit unclaimed for a while) get status + theme chips at all.
    if (type != RewardType.themeSouvenir) return const SizedBox.shrink();

    final colors = context.colors;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
      child: Row(
        children: [
          _FilterChip(
            label: 'All',
            selected: statusFilter == null,
            onTap: () => onStatusChanged(null),
          ),
          const SizedBox(width: 6),
          _FilterChip(
            label: 'Earned',
            selected: statusFilter == RewardStatus.earned,
            onTap: () => onStatusChanged(RewardStatus.earned),
          ),
          const SizedBox(width: 6),
          _FilterChip(
            label: 'Ready to claim',
            selected: statusFilter == RewardStatus.readyToClaim,
            onTap: () => onStatusChanged(RewardStatus.readyToClaim),
          ),
          const SizedBox(width: 12),
          Container(width: 1, height: 20, color: colors.outlineVariant),
          const SizedBox(width: 12),
          _FilterChip(
            label: 'All themes',
            selected: themeFilter == null,
            onTap: () => onThemeChanged(null),
          ),
          for (final theme in RewardRepository.themes) ...[
            const SizedBox(width: 6),
            _FilterChip(
              label: theme,
              selected: themeFilter == theme,
              color: _colorForTheme(theme),
              onTap: () => onThemeChanged(theme),
            ),
          ],
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color? color;
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.color,
  });
  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final resolved = color ?? colors.primary;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      showCheckmark: false,
      labelStyle: TextStyle(
        color: selected ? Colors.white : colors.onSurface,
        fontWeight: FontWeight.w700,
        fontSize: 12.5,
      ),
      backgroundColor: colors.surfaceContainerHigh,
      selectedColor: resolved,
      side: BorderSide(
        color: selected ? resolved : colors.outlineVariant,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      elevation: 0,
      pressElevation: 0,
    );
  }
}

/// A reward-type icon with a small red notification dot layered on top when
/// [showUnclaimedBadge] is true — flags a Theme Souvenir the tourist hasn't
/// claimed yet so it doesn't blend in with already-earned ones.
class _RewardLeadingIcon extends StatelessWidget {
  final IconData icon;
  final bool showUnclaimedBadge;
  final Color? color;
  const _RewardLeadingIcon({
    required this.icon,
    required this.showUnclaimedBadge,
    this.color,
  });
  @override
  Widget build(BuildContext context) {
    final badge = _IconBadge(icon: icon, color: color);
    if (!showUnclaimedBadge) return badge;
    final colors = context.colors;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        badge,
        Positioned(
          top: -2,
          right: -2,
          child: Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: colors.error,
              shape: BoxShape.circle,
              border: Border.all(color: colors.surfaceContainerHigh, width: 1.5),
            ),
          ),
        ),
      ],
    );
  }
}

class _RewardCard extends StatelessWidget {
  final Widget leading;
  final String title, subtitle;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;
  const _RewardCard({
    super.key,
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.onDelete,
  });
  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
        boxShadow: _cardShadow,
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: ListTile(
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          leading: leading,
          title: Text(
            title,
            style: TextStyle(color: colors.onSurface, fontWeight: FontWeight.w700),
          ),
          subtitle: Text(subtitle, style: TextStyle(color: colors.onSurfaceVariant)),
          trailing: onDelete == null
              ? Icon(Icons.chevron_right, color: colors.onSurfaceVariant)
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Delete',
                      onPressed: onDelete,
                      icon: Icon(
                        Icons.delete_outline,
                        color: colors.error,
                      ),
                    ),
                    Icon(Icons.chevron_right, color: colors.onSurfaceVariant),
                  ],
                ),
          onTap: onTap,
        ),
      ),
    );
  }
}

class _EmptyBanner extends StatelessWidget {
  const _EmptyBanner();
  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: colors.primaryContainer,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        children: [
          const _IconBadge(icon: Icons.emoji_events_rounded, size: 52),
          const SizedBox(height: 12),
          Text(
            'You have not earned any rewards yet.',
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.onPrimaryContainer, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            'Complete exploration games or milestones to unlock rewards.',
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.onPrimaryContainer, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorCard({required this.message, required this.onRetry});
  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.errorContainer,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.error.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(message, style: TextStyle(color: colors.onErrorContainer)),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(onPressed: onRetry, child: const Text('Retry')),
          ),
        ],
      ),
    );
  }
}

class RewardDetailView extends StatelessWidget {
  const RewardDetailView({super.key});
  @override
  Widget build(BuildContext context) {
    final vm = context.watch<RewardViewModel>();
    final reward = vm.selectedReward;
    final colors = context.colors;
    return Scaffold(
      backgroundColor: colors.surface,
      appBar: AppBar(
        backgroundColor: colors.surface,
        elevation: 0,
        foregroundColor: colors.onSurface,
        title: Text(
          'Reward details',
          style: TextStyle(color: colors.onSurface, fontWeight: FontWeight.w800),
        ),
      ),
      body: reward == null
          ? Center(
              child: Text(
                'Reward unavailable. Go back and retry.',
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Text(
                  reward.title,
                  style: TextStyle(
                    color: colors.onSurface,
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 16),
                RewardVisual(reward: reward),
                const SizedBox(height: 20),
                _DetailRow(
                  'Type',
                  reward.type == RewardType.digitalTravelStamp
                      ? 'Digital Travel Stamp'
                      : 'Theme Souvenir Image',
                ),
                _DetailRow('Status', reward.statusLabel),
                _DetailRow('Related game', reward.sourceId),
                if (reward.theme != null) _DetailRow('Theme', reward.theme!),
                if (reward.completedCheckpoints != null)
                  _DetailRow(
                    'Stored progress',
                    '${reward.completedCheckpoints}/${reward.totalCheckpoints} checkpoints',
                  ),
                // Digital Travel Stamps are auto-earned the instant
                // they're completed (no separate claim step), so
                // Completed/Earned are always the same date for that type
                // — showing both invites the "why are there two identical
                // dates" question. One label covers it. Theme Souvenirs
                // can genuinely differ (earnedAt trails completedAt until
                // the tourist taps Claim), so those keep both rows.
                if (reward.type == RewardType.digitalTravelStamp)
                  _DetailRow('Earned', rewardDate(reward.completedAt))
                else ...[
                  _DetailRow('Completed', rewardDate(reward.completedAt)),
                  if (reward.earnedAt != null)
                    _DetailRow('Earned', rewardDate(reward.earnedAt!)),
                ],
                if (vm.errorMessage != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    vm.errorMessage!,
                    style: TextStyle(color: colors.error),
                  ),
                ],
                if (reward.status == RewardStatus.readyToClaim) ...[
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: colors.primary,
                        foregroundColor: colors.onPrimary,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed: vm.isBusy
                          ? null
                          : () => vm.claimThemeSouvenir(reward.id),
                      child: const Text('Claim'),
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label, value;
  const _DetailRow(this.label, this.value);
  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 13),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(color: colors.onSurface, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
