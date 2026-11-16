import '../../../External_services/Supabase/s.dart';

class SupabaseService {
  final SupabaseExternal supabaseExternal;

  SupabaseService(this.supabaseExternal);

  String? get currentUserId => supabaseExternal.currentUserId;

  Future<List<Map<String, dynamic>>> getActiveGameSessions(String userId) {
    return supabaseExternal.getActiveGameSessions(userId);
  }

  Future<List<Map<String, dynamic>>> getCompletedVisitVerifiedGameSessions(
    String userId,
  ) {
    return supabaseExternal.getCompletedVisitVerifiedGameSessions(userId);
  }

  Future<List<Map<String, dynamic>>> getCompletedTripPathQuests(
    String userId,
  ) {
    return supabaseExternal.getCompletedTripPathQuests(userId);
  }

  Future<String?> getThemeArtworkImageUrl(String artworkId) {
    return supabaseExternal.getThemeArtworkImageUrl(artworkId);
  }

  Future<String> createGameSession({
    required Map<String, dynamic> data,
  }) {
    return supabaseExternal.insertGameSession(data);
  }

  Future<void> updateGameSession({
    required String sessionId,
    required Map<String, dynamic> data,
  }) {
    return supabaseExternal.updateGameSession(sessionId: sessionId, data: data);
  }

  Future<Map<String, dynamic>> getGameSession({required String sessionId}) {
    return supabaseExternal.getGameSession(sessionId: sessionId);
  }

  Future<void> createVisitProofRecord({required Map<String, dynamic> data}) {
    return supabaseExternal.insertVisitProofRecord(data);
  }

  Future<List<Map<String, dynamic>>> getStampFrames() {
    return supabaseExternal.getStampFrames();
  }

  // ---------------------------------------------------------------------
  // Theme Souvenir Image catalogue (UC-06 Manage Rewards, Phase 1).
  // ViewModels must not call SupabaseExternal directly — RewardRepository
  // goes through these wrappers instead.
  // ---------------------------------------------------------------------

  Future<String> insertThemeSouvenirImage({
    required Map<String, dynamic> data,
  }) {
    return supabaseExternal.insertThemeSouvenirImage(data);
  }

  Future<List<Map<String, dynamic>>> getThemeSouvenirImages({
    required String theme,
  }) {
    return supabaseExternal.getThemeSouvenirImages(theme);
  }

  Future<List<Map<String, dynamic>>> getAvailableThemeSouvenirImages({
    required String theme,
  }) {
    return supabaseExternal.getAvailableThemeSouvenirImages(theme);
  }

  Future<int> getAvailableThemeSouvenirImageCount({required String theme}) {
    return supabaseExternal.getAvailableThemeSouvenirImageCount(theme);
  }

  Future<void> markThemeSouvenirImageUnavailable({
    required String imageId,
    String? questId,
  }) {
    return supabaseExternal.markThemeSouvenirImageUnavailable(
      imageId: imageId,
      questId: questId,
    );
  }

  Future<Map<String, dynamic>> insertReward(Map<String, dynamic> data) =>
      supabaseExternal.insertReward(data);
  Future<List<Map<String, dynamic>>> getRewardsForTourist(String touristId) =>
      supabaseExternal.getRewardsForTourist(touristId);
  Future<Map<String, dynamic>> getRewardById(String touristId, String id) =>
      supabaseExternal.getRewardById(touristId, id);
  Future<Map<String, dynamic>?> findReward(
    String touristId,
    String type,
    String sourceId,
  ) => supabaseExternal.findReward(touristId, type, sourceId);
  Future<Map<String, dynamic>> updateRewardStatus(
    String touristId,
    String id,
    String status,
    DateTime earnedAt,
  ) => supabaseExternal.updateRewardStatus(touristId, id, status, earnedAt);
  Future<void> insertPostcard(Map<String, dynamic> data) =>
      supabaseExternal.insertPostcard(data);
  Future<List<Map<String, dynamic>>> getPostcards(String touristId) =>
      supabaseExternal.getPostcards(touristId);
  Future<void> deletePostcard({
    required String touristId,
    required String postcardId,
  }) => supabaseExternal.deletePostcard(
    touristId: touristId,
    postcardId: postcardId,
  );

  Future<void> saveCompletedQuest(Map<String, dynamic> data) =>
      supabaseExternal.saveCompletedQuest(data);
  Future<Map<String, dynamic>?> getCompletedQuest(
    String touristId,
    String questId,
  ) => supabaseExternal.getCompletedQuest(touristId, questId);

  Future<void> setEquippedMarkerSkin({
    required String touristId,
    required String rewardId,
  }) => supabaseExternal.setEquippedMarkerSkin(
    touristId: touristId,
    rewardId: rewardId,
  );
  Future<Map<String, dynamic>?> getEquippedMarkerSkin(String touristId) =>
      supabaseExternal.getEquippedMarkerSkin(touristId);
  Future<void> clearEquippedMarkerSkin({required String touristId}) =>
      supabaseExternal.clearEquippedMarkerSkin(touristId: touristId);
}
