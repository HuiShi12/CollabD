import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class ThemeArtworkData {
  final String id;
  final String themeId;
  final String title;
  final String bucketName;
  final String storagePath;
  final bool isActive;
  final String imageUrl;

  /// True when selectForNewQuest had to fall back to an artwork this
  /// tourist already completed before (the theme's whole pool was already
  /// used), as opposed to a genuinely fresh pick. Defaults to false for any
  /// artwork read directly from theme_artworks — only selectForNewQuest's
  /// own fallback branch sets this true.
  final bool wasReused;

  const ThemeArtworkData({
    required this.id,
    required this.themeId,
    required this.title,
    required this.bucketName,
    required this.storagePath,
    required this.isActive,
    required this.imageUrl,
    this.wasReused = false,
  });
}

class ThemeArtworkRepository {
  final SupabaseClient client;

  const ThemeArtworkRepository({
    required this.client,
  });

  String? get currentUserId =>
      client.auth.currentUser?.id;

  Future<ThemeArtworkData?> selectForNewQuest({
    required String themeId,
    // Artwork IDs already picked earlier THIS app session for this theme
    // but whose quest never made it into trip_path_quests (the tourist
    // left, or checkpoint preparation failed, before createQuest() — which
    // requires a reference-ready checkpoint 1 — could run). Without this,
    // such a pick has no database row to be excluded by, so leaving right
    // after picking one and starting over could hand back that exact same
    // artwork by pure chance. Session-only by design: once a real quest
    // row exists the database exclusion below is authoritative, and if
    // that quest is later deleted the artwork is meant to free up again —
    // this in-memory set has no opinion on that, it only covers the window
    // before a row exists at all.
    Set<String> alsoExclude = const {},
  }) async {
    final userId = currentUserId;

    if (userId == null) {
      throw StateError(
        'Please sign in before starting a Trip Path Quest.',
      );
    }

    final artworkRows = await client
        .from('theme_artworks')
        .select(
      'id, theme_id, title, bucket_name, storage_path, is_active',
    )
        .eq('theme_id', themeId)
        .eq('is_active', true)
        .order('created_at', ascending: true);

    final artworks = _parseArtworkRows(
      artworkRows,
    );

    if (artworks.isEmpty) {
      _log(
        'No active artwork found for theme $themeId.',
      );
      return null;
    }

    // Excludes both 'completed' (this tourist already painted it — a
    // finished reward, never reused) and 'in_progress' (already reserved by
    // this tourist's own unfinished quest) artworks. Scoped by user_id, so
    // a different tourist may still be assigned the same artwork — only
    // this tourist is blocked from getting a duplicate. 'abandoned' quests
    // are intentionally NOT excluded: since this is a live query rather
    // than a stored lock flag, an artwork frees itself back up the moment
    // its quest's status flips away from 'in_progress' (see "delete
    // progress" in trip_path_quest_progress_repository.dart), with no
    // separate release step required.
    final unavailableRows = await client
        .from('trip_path_quests')
        .select('artwork_id')
        .eq('user_id', userId)
        .eq('theme_id', themeId)
        .inFilter('status', ['completed', 'in_progress']);

    final unavailableArtworkIds = <String>{...alsoExclude};

    for (final raw in unavailableRows) {
      final id = '${raw['artwork_id'] ?? ''}'.trim();

      if (id.isNotEmpty) {
        unavailableArtworkIds.add(id);
      }
    }

    final unused = artworks
        .where(
          (artwork) =>
      !unavailableArtworkIds.contains(artwork.id),
    )
        .toList(growable: false);

    final pool = unused.isNotEmpty
        ? unused
        : artworks;

    final selected = pool.length == 1
        ? pool.first
        : pool[Random().nextInt(pool.length)];

    _log(
      unused.isNotEmpty
          ? 'Selected uncompleted artwork ${selected.title} for $themeId.'
          : 'All $themeId artworks were completed before. Reusing ${selected.title}.',
    );

    return unused.isNotEmpty
        ? selected
        : ThemeArtworkData(
      id: selected.id,
      themeId: selected.themeId,
      title: selected.title,
      bucketName: selected.bucketName,
      storagePath: selected.storagePath,
      isActive: selected.isActive,
      imageUrl: selected.imageUrl,
      wasReused: true,
    );
  }

  /// Looks up the theme_artworks row a generation call just registered
  /// (see GeminiApiExternal.generateThemeSouvenirImageUrl), so callers can
  /// use its *real* id for trip_path_quests.artwork_id. A freshly generated
  /// image's id from theme_souvenir_images must never be used there
  /// directly -- that table is unrelated to theme_artworks, and the two
  /// primary keys are not interchangeable (trip_path_quests.artwork_id has
  /// a foreign key into theme_artworks specifically).
  Future<ThemeArtworkData?> getMostRecentlyAdded({
    required String themeId,
  }) async {
    final rows = await client
        .from('theme_artworks')
        .select(
      'id, theme_id, title, bucket_name, storage_path, is_active',
    )
        .eq('theme_id', themeId)
        .eq('is_active', true)
        .order('created_at', ascending: false)
        .limit(1);

    final parsed = _parseArtworkRows(rows);

    return parsed.isEmpty ? null : parsed.first;
  }

  Future<ThemeArtworkData?> getById(
      String artworkId,
      ) async {
    final normalized = artworkId.trim();

    if (normalized.isEmpty) {
      return null;
    }

    final rows = await client
        .from('theme_artworks')
        .select(
      'id, theme_id, title, bucket_name, storage_path, is_active',
    )
        .eq('id', normalized)
        .limit(1);

    final parsed = _parseArtworkRows(rows);

    if (parsed.isEmpty) {
      return null;
    }

    return parsed.first;
  }

  List<ThemeArtworkData> _parseArtworkRows(
      dynamic rawRows,
      ) {
    if (rawRows is! List) {
      return const <ThemeArtworkData>[];
    }

    final result = <ThemeArtworkData>[];

    for (final raw in rawRows) {
      if (raw is! Map) {
        continue;
      }

      final id = '${raw['id'] ?? ''}'.trim();
      final themeId = '${raw['theme_id'] ?? ''}'.trim();
      final title = '${raw['title'] ?? ''}'.trim();
      final bucketName =
      '${raw['bucket_name'] ?? ''}'.trim();
      final storagePath =
      '${raw['storage_path'] ?? ''}'.trim();
      final isActive = raw['is_active'] != false;

      if (id.isEmpty ||
          themeId.isEmpty ||
          bucketName.isEmpty ||
          storagePath.isEmpty) {
        continue;
      }

      final imageUrl = client.storage
          .from(bucketName)
          .getPublicUrl(storagePath);

      result.add(
        ThemeArtworkData(
          id: id,
          themeId: themeId,
          title: title.isEmpty ? 'Quest Artwork' : title,
          bucketName: bucketName,
          storagePath: storagePath,
          isActive: isActive,
          imageUrl: imageUrl,
        ),
      );
    }

    return List.unmodifiable(result);
  }

  void _log(String message) {
    if (kDebugMode) {
      debugPrint(
        '[QUEST ARTWORK] $message',
      );
    }
  }
}
