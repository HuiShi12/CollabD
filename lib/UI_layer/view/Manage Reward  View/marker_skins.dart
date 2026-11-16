import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../main.dart';
import '../../../Data_layer/repository/Reward Repository/reward_repository.dart';
import '../../viewmodel/Manage Reward  ViewModel/reward_viewmodel.dart';

/// Fixed, hand-picked icon per Marker Skin design — by explicit request,
/// these don't come from AI generation (see RewardRepository.
/// unlockMarkerSkin's doc comment for why), so every design gets its own
/// distinct look purely through this lookup plus the design's own tier/
/// theme colour, instead of every skin rendering identically.
IconData _designIcon(String designId) => switch (designId) {
  'bronze_explorer' => Icons.explore_rounded,
  'silver_explorer' => Icons.local_florist_rounded,
  'gold_explorer' => Icons.location_city_rounded,
  'platinum_explorer' => Icons.flight_rounded,
  'legend_explorer' => Icons.auto_awesome_rounded,
  'bronze_puzzler' || 'silver_puzzler' || 'gold_puzzler' =>
    Icons.extension_rounded,
  'food_trailblazer' => Icons.restaurant_rounded,
  'culture_keeper' => Icons.festival_rounded,
  'heritage_guardian' => Icons.account_balance_rounded,
  'nature_ranger' => Icons.park_rounded,
  _ => Icons.emoji_events_rounded,
};

/// Compact 64x64 thumbnail for a skin tile — locked (no reward yet, shown
/// dimmed) or earned (shown solid), both using the same fixed per-design
/// icon so a design looks consistent whether or not it's unlocked yet.
/// Deliberately not RewardImage: its placeholder is sized for much larger
/// thumbnails and overflows at this tile size.
class _SkinThumb extends StatelessWidget {
  final TouristReward? reward;
  final String designId;
  final int? fallbackColor;
  const _SkinThumb(this.reward, {required this.designId, this.fallbackColor});

  @override
  Widget build(BuildContext context) {
    final color = fallbackColor != null
        ? Color(fallbackColor!)
        : context.colors.primaryContainer;
    if (reward == null) {
      // Locked — show the design's own tier/theme colour (dimmed, so the
      // tourist gets a preview of what they're working toward) with the lock
      // icon layered on top, rather than a flat empty box.
      return Stack(
        fit: StackFit.expand,
        children: [
          Container(color: color.withValues(alpha: 0.35)),
          Center(
            child: Icon(Icons.lock_outline, color: context.colors.onSurfaceVariant),
          ),
        ],
      );
    }
    return Container(
      color: color,
      alignment: Alignment.center,
      child: Icon(_designIcon(designId), color: Colors.white),
    );
  }
}

String _categoryLabel(MarkerSkinCategory category) => switch (category) {
  MarkerSkinCategory.explorer => 'Explorer',
  MarkerSkinCategory.puzzle => 'Puzzle',
  MarkerSkinCategory.theme => 'Theme',
};

String _progressLabel(MarkerSkinDesign design) => switch (design.category) {
  MarkerSkinCategory.explorer => 'games completed',
  MarkerSkinCategory.puzzle => 'puzzles solved',
  MarkerSkinCategory.theme => '${design.theme} souvenirs collected',
};

/// UC-06 A3 — browse configured Marker Skin designs across all three
/// tracks (Explorer / Puzzle / Theme), see progress toward each one's
/// milestone, and equip an Earned skin (or revert to the default marker)
/// as the tourist's map marker.
class MarkerSkinsView extends StatefulWidget {
  const MarkerSkinsView({super.key});
  @override
  State<MarkerSkinsView> createState() => _MarkerSkinsViewState();
}

class _MarkerSkinsViewState extends State<MarkerSkinsView> {
  bool _checking = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await context.read<RewardViewModel>().checkMarkerSkinUnlocks();
      if (mounted) setState(() => _checking = false);
    });
  }

  Future<void> _confirmEquip(RewardViewModel vm, TouristReward reward) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Equip this skin?'),
        content: Text(
          '${reward.title} will become your current-location marker on the map, '
          'replacing whatever skin is equipped now.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Equip'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final ok = await vm.equipMarkerSkin(reward.id);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else if (vm.errorMessage != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(vm.errorMessage!)));
    }
  }

  Future<void> _confirmUnequip(RewardViewModel vm) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Use the default marker?'),
        content: const Text(
          'Your map marker will go back to the original design, with no '
          'skin equipped.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Use Default'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final ok = await vm.unequipMarkerSkin();
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else if (vm.errorMessage != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(vm.errorMessage!)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<RewardViewModel>();
    final colors = context.colors;
    final owned = {for (final r in vm.markerSkins) r.sourceId: r};
    final anyEquipped = vm.markerSkins.any((r) => r.isEquipped);
    final byCategory = <MarkerSkinCategory, List<MarkerSkinDesign>>{
      for (final c in MarkerSkinCategory.values)
        c: RewardRepository.markerSkinDesigns
            .where((d) => d.category == c)
            .toList(),
    };
    return Scaffold(
      backgroundColor: colors.surface,
      appBar: AppBar(
        backgroundColor: colors.surface,
        elevation: 0,
        foregroundColor: colors.onSurface,
        title: Text(
          'Marker Skins',
          style: TextStyle(color: colors.onSurface, fontWeight: FontWeight.w800),
        ),
      ),
      body: _checking
          ? Center(child: CircularProgressIndicator(color: colors.primary))
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(
                  'Complete exploration games to unlock new map markers. '
                  'Explorer tracks every game, Puzzle tracks Mystery Place '
                  'games, and Theme tracks Trip Path Quest by theme.',
                  style: TextStyle(color: colors.onSurfaceVariant, fontSize: 13, height: 1.4),
                ),
                const SizedBox(height: 16),
                if (vm.errorMessage != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      vm.errorMessage!,
                      style: TextStyle(color: colors.error),
                    ),
                  ),
                _DefaultMarkerTile(
                  equipped: !anyEquipped,
                  busy: vm.isBusy,
                  onSelect: () => _confirmUnequip(vm),
                ),
                const SizedBox(height: 20),
                for (final category in MarkerSkinCategory.values) ...[
                  _SectionHeader(
                    category: category,
                    tripPathLevel: category == MarkerSkinCategory.theme
                        ? vm.tripPathSkinLevel
                        : null,
                  ),
                  const SizedBox(height: 10),
                  for (final design in byCategory[category]!)
                    _SkinTile(
                      key: ValueKey(design.id),
                      design: design,
                      reward: owned[design.id],
                      progress: vm.progressFor(design),
                      busy: vm.isBusy,
                      onEquip: (reward) => _confirmEquip(vm, reward),
                    ),
                  const SizedBox(height: 10),
                ],
              ],
            ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final MarkerSkinCategory category;
  final int? tripPathLevel;
  const _SectionHeader({required this.category, this.tripPathLevel});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Row(
      children: [
        Text(
          _categoryLabel(category),
          style: TextStyle(
            color: colors.onSurface,
            fontWeight: FontWeight.w800,
            fontSize: 16,
          ),
        ),
        if (tripPathLevel != null) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: colors.primaryContainer,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              'Trip Path Level $tripPathLevel/${RewardRepository.themes.length}',
              style: TextStyle(
                color: colors.onPrimaryContainer,
                fontWeight: FontWeight.w700,
                fontSize: 11,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _DefaultMarkerTile extends StatelessWidget {
  final bool equipped;
  final bool busy;
  final VoidCallback onSelect;
  const _DefaultMarkerTile({
    required this.equipped,
    required this.busy,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: equipped ? colors.primary : colors.outlineVariant,
          width: equipped ? 1.5 : 1,
        ),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Container(
              width: 64,
              height: 64,
              color: Color(RewardRepository.defaultMarkerColor),
              alignment: Alignment.center,
              child: const Icon(Icons.navigation_rounded, color: Colors.white),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Default Marker',
                  style: TextStyle(
                    color: colors.onSurface,
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  equipped ? 'In use' : 'The original map marker, no skin',
                  style: TextStyle(
                    color: equipped ? colors.primary : colors.onSurfaceVariant,
                    fontWeight: equipped ? FontWeight.w700 : FontWeight.w400,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          if (!equipped)
            // A direct Row child (unlike _SkinTile's Equip button, which
            // lives inside an Expanded/Column) gets an unbounded main-axis
            // width from Flutter's Row layout — IntrinsicWidth resolves
            // that down to the button's own natural width before it
            // reaches OutlinedButton internals.
            IntrinsicWidth(
              child: SizedBox(
                height: 34,
                child: OutlinedButton(
                  onPressed: busy ? null : onSelect,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: colors.primary,
                    side: BorderSide(color: colors.primary),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                  ),
                  child: const Text('Use'),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SkinTile extends StatelessWidget {
  final MarkerSkinDesign design;
  final TouristReward? reward;
  final int progress;
  final bool busy;
  final void Function(TouristReward reward) onEquip;
  const _SkinTile({
    super.key,
    required this.design,
    required this.reward,
    required this.progress,
    required this.busy,
    required this.onEquip,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final owned = reward != null;
    final clamped = progress.clamp(0, design.milestoneTarget);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: reward?.isEquipped == true ? colors.primary : colors.outlineVariant,
          width: reward?.isEquipped == true ? 1.5 : 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: 64,
              height: 64,
              // Not using RewardImage here: its placeholder (icon + two
              // lines of label text) is meant for the much larger
              // dashboard/detail thumbnails and overflows a 64x64 box —
              // this is a compact equivalent for the small tile size.
              child: _SkinThumb(
                reward,
                designId: design.id,
                fallbackColor: design.color,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  design.name,
                  style: TextStyle(
                    color: colors.onSurface,
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 4),
                if (!owned) ...[
                  Text(
                    '$clamped/${design.milestoneTarget} ${_progressLabel(design)}',
                    style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
                  ),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: clamped / design.milestoneTarget,
                      color: colors.primary,
                      backgroundColor: colors.primaryContainer,
                      minHeight: 6,
                    ),
                  ),
                ] else ...[
                  Text(
                    reward!.isEquipped ? 'Equipped' : 'Earned',
                    style: TextStyle(
                      color: reward!.isEquipped ? colors.primary : colors.onSurfaceVariant,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (!reward!.isEquipped)
                    SizedBox(
                      height: 34,
                      child: OutlinedButton(
                        onPressed: busy ? null : () => onEquip(reward!),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: colors.primary,
                          side: BorderSide(color: colors.primary),
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                        ),
                        child: const Text('Equip'),
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
