import 'dart:async';
import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

const _rewardQueryTimeout = Duration(seconds: 15);

/// UC-05 / UC-06 — real Supabase persistence for the exploration-game side
/// (game sessions, visit proofs), plus the Reward/Postcard prototype tables
/// (still in-memory/mock — see the TODO further down).
///
/// Separate from `External_services/Supabase Auth/sa.dart`, which handles
/// UC-01/UC-02/UC-07 auth + profiles. Both share `Supabase.instance.client`.
class SupabaseExternal {
  final SupabaseClient client;

  SupabaseExternal(this.client);

  /// UC-05 — real signed-in user id, used to scope game_sessions rows under
  /// the auth.uid()-based RLS policy (see 20260911184655_puzzle_session_resume.sql).
  String? get currentUserId => client.auth.currentUser?.id;

  // ---------------------------------------------------------------------------
  // Game session  (table: game_sessions)
  // ---------------------------------------------------------------------------

  Future<String> insertGameSession(Map<String, dynamic> data) async {
    final row = await client
        .from('game_sessions')
        .insert(data)
        .select('id')
        .single();
    return row['id'].toString();
  }

  Future<void> updateGameSession({
    required String sessionId,
    required Map<String, dynamic> data,
  }) async {
    await client.from('game_sessions').update(data).eq('id', sessionId);
  }

  Future<Map<String, dynamic>> getGameSession({
    required String sessionId,
  }) async {
    return await client
        .from('game_sessions')
        .select()
        .eq('id', sessionId)
        .single();
  }

  /// UC-05 — resumable puzzle sessions for the signed-in tourist, most
  /// recently updated first.
  Future<List<Map<String, dynamic>>> getActiveGameSessions(
    String userId,
  ) async {
    return await client
        .from('game_sessions')
        .select()
        .eq('user_id', userId)
        .eq('status', 'In Progress')
        .order('updated_at', ascending: false);
  }

  /// UC-06 — completed, visit-verified puzzle sessions, for
  /// RewardRepository.backfillMissingDigitalTravelStamps() to cross-check
  /// against tourist_rewards and regenerate any stamp that never got
  /// created (see that method's own doc comment for why one can be missing).
  Future<List<Map<String, dynamic>>> getCompletedVisitVerifiedGameSessions(
    String userId,
  ) async {
    return await client
        .from('game_sessions')
        .select()
        .eq('user_id', userId)
        .eq('status', 'Completed')
        .eq('visit_verified', true)
        .order('completion_date', ascending: false);
  }

  /// Every completed Trip Path Quest for [userId] — used to backfill a
  /// Theme Souvenir that failed to get created (see
  /// RewardRepository.backfillMissingThemeSouvenirs).
  Future<List<Map<String, dynamic>>> getCompletedTripPathQuests(
    String userId,
  ) async {
    final rows = await client
        .from('trip_path_quests')
        .select(
          'id, theme_name, artwork_id, completed_checkpoints, '
          'total_checkpoints, completed_at',
        )
        .eq('user_id', userId)
        .eq('status', 'completed');
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  /// Public image URL for one theme_artworks row, or null if it no longer
  /// exists. Used by the same Theme Souvenir backfill above — the quest row
  /// only stores artwork_id, not the image itself.
  Future<String?> getThemeArtworkImageUrl(String artworkId) async {
    final row = await client
        .from('theme_artworks')
        .select('bucket_name, storage_path')
        .eq('id', artworkId)
        .maybeSingle();
    if (row == null) return null;
    final bucketName = '${row['bucket_name'] ?? ''}'.trim();
    final storagePath = '${row['storage_path'] ?? ''}'.trim();
    if (bucketName.isEmpty || storagePath.isEmpty) return null;
    return client.storage.from(bucketName).getPublicUrl(storagePath);
  }

  // ---------------------------------------------------------------------------
  // Visit proof  (table: visit_proofs)
  // ---------------------------------------------------------------------------

  Future<void> insertVisitProofRecord(Map<String, dynamic> data) async {
    await client.from('visit_proofs').insert(data);
  }

  // ---------------------------------------------------------------------------
  // Digital Travel Stamp frames  (table: stamp_frames)
  //
  // Unlike the Theme Souvenir Image catalogue below, frame designs are not
  // consumed per use — the same frame is reused across every tourist's
  // stamp. So this table is a real, hand-seeded Supabase table (rows added
  // once via the dashboard, no runtime generation/replenishment), and this
  // is just a read. RewardRepository decides which one to use.
  // ---------------------------------------------------------------------------

  Future<List<Map<String, dynamic>>> getStampFrames() async {
    return await client.from('stamp_frames').select().timeout(_rewardQueryTimeout);
  }

  // ---------------------------------------------------------------------
  // Theme Souvenir Image catalogue (UC-06 Manage Rewards, Phase 1).
  //
  // Real Supabase persistence (table: theme_souvenir_images), replacing the
  // old in-memory map — that map reset every app run, so the catalogue
  // "forgot" it already had images and kept regenerating from zero.
  // ---------------------------------------------------------------------

  /// Inserts one Theme Souvenir Image into the catalogue and returns its id.
  Future<String> insertThemeSouvenirImage(Map<String, dynamic> data) async {
    final row = await client
        .from('theme_souvenir_images')
        .insert(data)
        .select('id')
        .single()
        .timeout(_rewardQueryTimeout);
    return row['id'].toString();
  }

  /// Returns every catalogue image (available or not) for [theme].
  Future<List<Map<String, dynamic>>> getThemeSouvenirImages(
    String theme,
  ) async {
    final rows = await client
        .from('theme_souvenir_images')
        .select()
        .eq('theme', theme)
        .timeout(_rewardQueryTimeout);
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  /// Returns only currently-available images for [theme], oldest first
  /// (C12: Existing Theme Images Prioritised — older available images are
  /// selected before newly generated ones).
  Future<List<Map<String, dynamic>>> getAvailableThemeSouvenirImages(
    String theme,
  ) async {
    final rows = await client
        .from('theme_souvenir_images')
        .select()
        .eq('theme', theme)
        .eq('is_available', true)
        .order('created_at', ascending: true)
        .timeout(_rewardQueryTimeout);
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  /// C9: Available Theme Image Count — only currently-available images
  /// count towards this quantity.
  Future<int> getAvailableThemeSouvenirImageCount(String theme) async {
    final available = await getAvailableThemeSouvenirImages(theme);
    return available.length;
  }

  /// Marks a single catalogue image unavailable and (optionally) associates
  /// it with the requesting quest. The `is_available = true` condition in
  /// the update's WHERE clause makes this atomic against a concurrent
  /// assignment — if another request already claimed this row, this update
  /// matches zero rows and throws instead of double-assigning it.
  Future<void> markThemeSouvenirImageUnavailable({
    required String imageId,
    String? questId,
  }) async {
    final updated = await client
        .from('theme_souvenir_images')
        .update({
          'is_available': false,
          'assigned_quest_id': questId,
          'assigned_at': DateTime.now().toIso8601String(),
        })
        .eq('id', imageId)
        .eq('is_available', true)
        .select()
        .maybeSingle()
        .timeout(_rewardQueryTimeout);
    if (updated == null) {
      throw StateError(
        'Theme Souvenir Image not found or already assigned: $imageId',
      );
    }
  }

  // ---------------------------------------------------------------------
  // Tourist rewards (table: tourist_rewards) — UC-06 Manage Rewards.
  //
  // Real Supabase persistence, replacing the old in-memory `_rewards` map
  // that reset every app run (which is why earned stamps disappeared on
  // the next launch). Named `tourist_rewards`, not `rewards` — a table
  // called `rewards` already exists for Profile Management's unrelated
  // "Rewards Earned" statistic (sa.dart), with a completely different
  // schema (user_id / reward_type / is_unlocked). Postcards below are
  // still the session-only prototype table pending the same migration.
  // ---------------------------------------------------------------------

  Future<Map<String, dynamic>> insertReward(Map<String, dynamic> data) async {
    final id = data['id'] as String;
    final inserted = await client
        .from('tourist_rewards')
        .upsert(data, onConflict: 'id', ignoreDuplicates: true)
        .select()
        .timeout(_rewardQueryTimeout);
    if (inserted.isNotEmpty) {
      return Map<String, dynamic>.from(inserted.first as Map);
    }
    // Already existed (ignoreDuplicates skipped the insert) — return the
    // existing row, matching the previous idempotent-create behaviour.
    final existing = await client
        .from('tourist_rewards')
        .select()
        .eq('id', id)
        .single()
        .timeout(_rewardQueryTimeout);
    return Map<String, dynamic>.from(existing);
  }

  Future<List<Map<String, dynamic>>> getRewardsForTourist(
    String touristId,
  ) async {
    final rows = await client
        .from('tourist_rewards')
        .select()
        .eq('tourist_id', touristId)
        .timeout(_rewardQueryTimeout);
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  Future<Map<String, dynamic>> getRewardById(
    String touristId,
    String id,
  ) async {
    final row = await client
        .from('tourist_rewards')
        .select()
        .eq('id', id)
        .eq('tourist_id', touristId)
        .maybeSingle()
        .timeout(_rewardQueryTimeout);
    if (row == null) {
      throw StateError('Reward not found for this tourist.');
    }
    return Map<String, dynamic>.from(row);
  }

  Future<Map<String, dynamic>?> findReward(
    String touristId,
    String type,
    String sourceId,
  ) async {
    final row = await client
        .from('tourist_rewards')
        .select()
        .eq('tourist_id', touristId)
        .eq('type', type)
        .eq('source_id', sourceId)
        .maybeSingle()
        .timeout(_rewardQueryTimeout);
    return row == null ? null : Map<String, dynamic>.from(row);
  }

  Future<Map<String, dynamic>> updateRewardStatus(
    String touristId,
    String id,
    String status,
    DateTime earnedAt,
  ) async {
    final updated = await client
        .from('tourist_rewards')
        .update({'status': status, 'earned_at': earnedAt.toIso8601String()})
        .eq('id', id)
        .eq('tourist_id', touristId)
        .select()
        .maybeSingle()
        .timeout(_rewardQueryTimeout);
    if (updated == null) {
      throw StateError('Reward not found for this tourist.');
    }
    return Map<String, dynamic>.from(updated);
  }

  // ---------------------------------------------------------------------
  // Explorer Marker Skins (UC-06 A3) — equip state (a column on
  // tourist_rewards, since a skin reward is still a TouristReward). No
  // master-image cache anymore — Marker Skins use a fixed icon per design
  // (see marker_skins.dart's `_designIcon`), not a generated image, so
  // there's nothing to cache.
  // ---------------------------------------------------------------------

  /// Equips [rewardId] as the tourist's marker and un-equips whatever else
  /// they had equipped (C7: One Equipped Marker Skin Only). Two updates in
  /// sequence rather than one query, since Postgres can't easily do
  /// "exactly one true, rest false" atomically through PostgREST — a
  /// narrow window exists, but the failure mode is "briefly zero or two
  /// equipped skins", not data loss.
  Future<void> setEquippedMarkerSkin({
    required String touristId,
    required String rewardId,
  }) async {
    await client
        .from('tourist_rewards')
        .update({'is_equipped': false})
        .eq('tourist_id', touristId)
        .eq('type', 'explorerMarkerSkin')
        .timeout(_rewardQueryTimeout);
    final updated = await client
        .from('tourist_rewards')
        .update({'is_equipped': true})
        .eq('id', rewardId)
        .eq('tourist_id', touristId)
        .select()
        .maybeSingle()
        .timeout(_rewardQueryTimeout);
    if (updated == null) {
      throw StateError('Explorer Marker Skin not found for this tourist.');
    }
  }

  /// UC-03 A3 — clears whatever marker skin is equipped, reverting the map
  /// to its original default marker. Mirrors the "unequip all" half of
  /// [setEquippedMarkerSkin].
  Future<void> clearEquippedMarkerSkin({required String touristId}) async {
    await client
        .from('tourist_rewards')
        .update({'is_equipped': false})
        .eq('tourist_id', touristId)
        .eq('type', 'explorerMarkerSkin')
        .timeout(_rewardQueryTimeout);
  }

  /// UC-03 C6 — the skin View Map should render as the tourist's
  /// current-location marker, or null if none is equipped. A plain select
  /// + take-first rather than .maybeSingle(): that throws outright if it
  /// ever finds more than one row, and setEquippedMarkerSkin's two
  /// sequential updates leave a narrow window where a second equip
  /// request could race in and briefly leave more than one row true — the
  /// map marker should just show *a* deterministic answer then, not throw
  /// and silently keep the previous marker.
  Future<Map<String, dynamic>?> getEquippedMarkerSkin(
    String touristId,
  ) async {
    final rows = await client
        .from('tourist_rewards')
        .select()
        .eq('tourist_id', touristId)
        .eq('type', 'explorerMarkerSkin')
        .eq('is_equipped', true)
        .order('earned_at', ascending: false)
        .limit(1)
        .timeout(_rewardQueryTimeout);
    return rows.isEmpty ? null : Map<String, dynamic>.from(rows.first);
  }

  // Session-only prototype table. TODO: replace with a Supabase table and RLS.
  final Map<String, Map<String, dynamic>> _postcards = {};

  Map<String, dynamic> _copy(Map<String, dynamic> data) =>
      Map<String, dynamic>.from(jsonDecode(jsonEncode(data)) as Map);
  Future<void> insertPostcard(Map<String, dynamic> data) async {
    final id = data['id'] as String;
    final existing = _postcards[id];
    if (existing != null && existing['tourist_id'] != data['tourist_id']) {
      throw StateError('Postcard belongs to another tourist.');
    }
    _postcards[id] = _copy(data);
  }

  Future<List<Map<String, dynamic>>> getPostcards(String touristId) async =>
      _postcards.values
          .where((p) => p['tourist_id'] == touristId)
          .map(_copy)
          .toList();

  Future<void> deletePostcard({
    required String touristId,
    required String postcardId,
  }) async {
    final existing = _postcards[postcardId];
    if (existing == null) return;
    if (existing['tourist_id'] != touristId) {
      throw StateError('Postcard belongs to another tourist.');
    }
    _postcards.remove(postcardId);
  }
  final _completedQuests = <String, Map<String, dynamic>>{};
  String _questKey(String touristId, String questId) =>
      jsonEncode([touristId, questId]);
  Future<void> saveCompletedQuest(Map<String, dynamic> data) async {
    final key = _questKey(
      data['tourist_id'] as String,
      data['quest_id'] as String,
    );
    _completedQuests.putIfAbsent(key, () => _copy(data));
  }

  Future<Map<String, dynamic>?> getCompletedQuest(
    String touristId,
    String questId,
  ) async {
    final data = _completedQuests[_questKey(touristId, questId)];
    return data == null ? null : _copy(data);
  }
}
