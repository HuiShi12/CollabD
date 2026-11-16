import 'package:supabase_flutter/supabase_flutter.dart';

/// A place a tourist has already committed to — via a Puzzle `game_sessions`
/// row or a Trip Path Quest checkpoint — should stop being offered as a new
/// discovery by either game mode, or shown as a Map marker, for that same
/// account. Once claimed, a place stays claimed permanently: there is no
/// "release on abandon/complete" exception (confirmed design decision).
///
/// Deliberately standalone (just a raw [SupabaseClient], no shared DI) so it
/// can be instantiated independently by both `main.dart`'s `AppDependencies`
/// (Map + Puzzle) and Trip Path Quest's self-contained `trip_path_module.dart`
/// without crossing that module's existing vendored-isolation boundary.
class ClaimedPlacesRepository {
  ClaimedPlacesRepository({required this.client});

  final SupabaseClient client;

  /// Every Google Places `place.id` this account has ever started a game at,
  /// across both Puzzle and Trip Path, regardless of status. Each source is
  /// queried and caught independently — a schema hiccup on one side (e.g.
  /// Trip Path's checkpoints table) never blocks the other's exclusions, it
  /// just contributes an empty set instead of throwing.
  Future<Set<String>> getClaimedPlaceIds() async {
    final userId = client.auth.currentUser?.id;
    if (userId == null) return const <String>{};

    final claimed = <String>{};

    try {
      final rows = await client
          .from('game_sessions')
          .select('hidden_place_id')
          .eq('user_id', userId);
      claimed.addAll(
        (rows as List)
            .map((row) => (row as Map)['hidden_place_id'] as String?)
            .whereType<String>(),
      );
    } catch (_) {
      // Fails open — matches this codebase's existing resilience convention.
    }

    try {
      final rows = await client
          .from('trip_path_quest_checkpoints')
          .select('google_place_id, trip_path_quests!inner(user_id)')
          .eq('trip_path_quests.user_id', userId);
      claimed.addAll(
        (rows as List)
            .map((row) => (row as Map)['google_place_id'] as String?)
            .whereType<String>(),
      );
    } catch (_) {}

    return claimed;
  }
}
