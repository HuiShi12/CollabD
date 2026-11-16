import 'dart:async';

import 'package:flutter/foundation.dart';
import '../../../Data_layer/repository/Reward Repository/reward_repository.dart';
import '../../../Data_layer/repository/Reward Repository/reward_observer.dart';
import '../../../Data_layer/repository/User Repository/current_tourist.dart';

class RewardViewModel extends ChangeNotifier
    implements RewardObserver {
  final RewardRepository rewardRepository;
  // Not stored: this ViewModel is constructed once at app startup, before
  // login happens, so a captured value would freeze at whoever (if anyone)
  // was signed in at that instant. Reading CurrentTourist.id fresh means
  // every call always targets whoever is actually logged in right now.
  @override
  String get touristId => CurrentTourist.id;
  RewardViewModel({required this.rewardRepository}) {
    rewardRepository.attachObserver(this);
  }
  bool isLoading = false, isBusy = false, _disposed = false;
  String? errorMessage;
  List<TouristReward> rewards = [];
  List<DigitalPostcard> postcards = [];
  TouristReward? selectedReward;
  int _loadVersion = 0;
  List<TouristReward> get digitalTravelStamps =>
      rewards.where((r) => r.type == RewardType.digitalTravelStamp).toList();
  List<TouristReward> get themeSouvenirs =>
      rewards.where((r) => r.type == RewardType.themeSouvenir).toList();
  List<TouristReward> get postcardEligibleRewards =>
      rewards.where((r) => r.postcardEligible).toList();
  List<TouristReward> get markerSkins =>
      rewards.where((r) => r.type == RewardType.explorerMarkerSkin).toList();

  // Earned-only counts for the Rewards dashboard tiles, so they match
  // Profile's "Rewards Earned" stat (tourist_rewards.status = 'earned') —
  // digitalTravelStamps/themeSouvenirs/markerSkins above stay unfiltered by
  // status on purpose, since progress tracking elsewhere in this file
  // (progressFor, tripPathSkinLevel, gamesCompletedCount) intentionally
  // counts a reward the moment it exists, before the tourist taps to claim
  // it. Digital Travel Stamps are always already 'earned' (see reward.dart),
  // so this is a no-op for stampCount; it only matters for souvenirs/skins,
  // which can sit at 'readyToClaim' until claimed.
  int get earnedStampCount =>
      digitalTravelStamps
          .where((r) => r.status == RewardStatus.earned)
          .length;
  int get earnedSouvenirCount =>
      themeSouvenirs.where((r) => r.status == RewardStatus.earned).length;
  int get earnedSkinCount =>
      markerSkins.where((r) => r.status == RewardStatus.earned).length;

  // "Games completed" = one earned Digital Travel Stamp or Theme Souvenir,
  // both already tracked here.
  int get gamesCompletedCount =>
      digitalTravelStamps.length + themeSouvenirs.length;

  /// Whether the tourist has anything sitting unclaimed right now — same
  /// condition as the red dot on a Theme Souvenir card in the Rewards list
  /// itself (only Theme Souvenirs have a "ready to claim" state; Digital
  /// Travel Stamps are always already earned). Surfaced as the same red
  /// notification dot on the Map's reward icon, so it's visible without
  /// having to open Rewards first.
  bool get hasUnclaimedRewards =>
      rewards.any((r) => r.status == RewardStatus.readyToClaim);

  /// Earned Theme Souvenirs for one specific Trip Path theme (e.g. 'Food')
  /// — the progress metric for MarkerSkinCategory.theme designs.
  int themeSouvenirCountFor(String theme) => themeSouvenirs
      .where((r) => r.theme == theme && r.status == RewardStatus.earned)
      .length;

  /// The right progress number for [design], per its category (UC's own
  /// "Explorer / Puzzle / Theme" tracks each count something different).
  int progressFor(MarkerSkinDesign design) => switch (design.category) {
    MarkerSkinCategory.explorer => gamesCompletedCount,
    MarkerSkinCategory.puzzle => digitalTravelStamps.length,
    MarkerSkinCategory.theme => themeSouvenirCountFor(design.theme!),
  };

  /// Trip Path's own 4-level meta-progression: one level per distinct
  /// theme skin owned (Food/Culture/Heritage/Nature), out of
  /// RewardRepository.themes.length.
  int get tripPathSkinLevel {
    final themeSkinIds = RewardRepository.markerSkinDesigns
        .where((d) => d.category == MarkerSkinCategory.theme)
        .map((d) => d.id)
        .toSet();
    return markerSkins.where((r) => themeSkinIds.contains(r.sourceId)).length;
  }
  void _emit() {
    if (!_disposed) notifyListeners();
  }

  @override
  void onRewardReady(TouristReward reward) {
    if (_disposed || reward.touristId != touristId) return;
    rewards = [...rewards.where((r) => r.id != reward.id), reward];
    if (selectedReward?.id == reward.id) selectedReward = reward;
    _emit();
  }

  @override
  void onCatalogueUpdated(String theme, int available) {
    if (_disposed) return;
    _emit();
  }

  @override
  void onPostcardSaved(DigitalPostcard card) {
    if (_disposed || card.touristId != touristId) return;
    postcards = [...postcards.where((p) => p.id != card.id), card];
    _emit();
  }

  Future<void> loadRewards() async {
    final version = ++_loadVersion;
    isLoading = true;
    _emit();
    try {
      final loaded = await rewardRepository.getRewardsForTourist(touristId);
      final cards = await rewardRepository.getPostcards(touristId);
      if (_disposed || version != _loadVersion) return;
      rewards = loaded;
      postcards = cards;
      if (selectedReward != null) {
        final matches = rewards.where((r) => r.id == selectedReward!.id);
        selectedReward = matches.isEmpty ? null : matches.first;
      }
      errorMessage = null;
      // Best-effort repair for Puzzle sessions that reached "Completed"
      // without their Digital Travel Stamp ever being created (see
      // RewardRepository.backfillMissingDigitalTravelStamps for why that
      // could happen). Runs in the background — any stamp it creates
      // arrives through onRewardReady like any other reward, so this load
      // doesn't need to wait for it or reload afterward.
      unawaited(rewardRepository.backfillMissingDigitalTravelStamps(touristId));
      unawaited(rewardRepository.backfillMissingThemeSouvenirs(touristId));
    } catch (e) {
      if (version == _loadVersion) {
        errorMessage = 'Your reward information cannot currently be loaded. $e';
      }
    } finally {
      if (version == _loadVersion) {
        isLoading = false;
        _emit();
      }
    }
  }

  Future<void> refreshRewards() => loadRewards();
  Future<void> loadPostcardEligibleRewards() => loadRewards();
  void clearError() {
    errorMessage = null;
    _emit();
  }

  Future<bool> _perform(Future<void> Function() action) async {
    if (isBusy) return false;
    isBusy = true;
    errorMessage = null;
    _emit();
    try {
      await action();
      return true;
    } catch (e) {
      errorMessage = e.toString();
      return false;
    } finally {
      isBusy = false;
      _emit();
    }
  }

  Future<bool> selectReward(String id) => _perform(() async {
    selectedReward = await rewardRepository.getRewardById(
      touristId: touristId,
      rewardId: id,
    );
  });
  // Neither method below re-fetches via loadRewards() after its repository
  // call succeeds: RewardRepository already pushes the updated reward/
  // postcard straight into this ViewModel via the Observer notification
  // (onRewardReady / onPostcardSaved) before the call even returns, so a
  // second network round-trip here was pure redundant latency — and if it
  // ever hung, isBusy would stay stuck true, freezing every reward row's
  // tap until the timeout (or an app restart) cleared it.
  Future<bool> claimThemeSouvenir(String id) => _perform(() async {
    selectedReward = await rewardRepository.claimThemeSouvenir(
      touristId: touristId,
      rewardId: id,
    );
  });

  /// UC-06 A3.2-A3.7 — call when the Marker Skins page opens. For every
  /// configured design whose milestone is now met but isn't yet owned,
  /// unlocks it (generating the master image via Gemini on first-ever
  /// unlock of that design, reusing it otherwise). Already-owned designs
  /// are skipped without a network call. Not wrapped in _perform/isBusy
  /// since it may unlock several designs in one pass and none of them
  /// should block the others or the page's own reward taps.
  Future<void> checkMarkerSkinUnlocks() async {
    final owned = markerSkins.map((r) => r.sourceId).toSet();
    for (final design in RewardRepository.markerSkinDesigns) {
      if (progressFor(design) < design.milestoneTarget ||
          owned.contains(design.id)) {
        continue;
      }
      try {
        await rewardRepository.unlockMarkerSkin(
          touristId: touristId,
          designId: design.id,
        );
      } catch (e) {
        errorMessage = 'Could not unlock ${design.name}: $e';
        _emit();
      }
    }
  }

  Future<bool> equipMarkerSkin(String rewardId) => _perform(() async {
    selectedReward = await rewardRepository.equipMarkerSkinReward(
      touristId: touristId,
      rewardId: rewardId,
    );
  });

  /// UC-03 A3 — explicitly go back to the original default marker instead
  /// of any skin.
  Future<bool> unequipMarkerSkin() => _perform(() async {
    await rewardRepository.unequipMarkerSkin(touristId: touristId);
  });

  Future<bool> savePostcard({
    required String backgroundType,
    required int backgroundColor,
    required List<String> selectedRewardIds,
    required String message,
  }) => _perform(() async {
    await rewardRepository.savePostcard(
      touristId: touristId,
      backgroundType: backgroundType,
      backgroundColor: backgroundColor,
      selectedRewardIds: selectedRewardIds,
      message: message,
    );
  });

  Future<bool> deletePostcard(String postcardId) => _perform(() async {
    await rewardRepository.deletePostcard(
      touristId: touristId,
      postcardId: postcardId,
    );
    postcards = postcards.where((p) => p.id != postcardId).toList();
  });
  @override
  void dispose() {
    _disposed = true;
    rewardRepository.detachObserver(this);
    super.dispose();
  }
}
