import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class QuestCheckpointSaveData {
  final int checkpointNumber;
  final String googlePlaceId;
  final String landmarkName;
  final String address;
  final String generalArea;
  final String primaryType;
  final double latitude;
  final double longitude;
  final List<String> verifiedFacts;
  final List<String> clues;
  final String referenceFingerprint;
  final String referenceKind;
  final int? referenceWidth;
  final int? referenceHeight;

  const QuestCheckpointSaveData({
    required this.checkpointNumber,
    required this.googlePlaceId,
    required this.landmarkName,
    required this.address,
    required this.generalArea,
    required this.primaryType,
    required this.latitude,
    required this.longitude,
    required this.verifiedFacts,
    this.clues = const <String>[],
    this.referenceFingerprint = '',
    this.referenceKind = 'unknown',
    this.referenceWidth,
    this.referenceHeight,
  });
}

class SavedTripPathCheckpoint {
  final int checkpointNumber;
  final String googlePlaceId;
  final String landmarkName;
  final String address;
  final String generalArea;
  final String primaryType;
  final double latitude;
  final double longitude;
  final List<String> verifiedFacts;
  final List<String> clues;
  final String status;
  final String referenceFingerprint;
  final String referenceKind;
  final int? referenceWidth;
  final int? referenceHeight;

  const SavedTripPathCheckpoint({
    required this.checkpointNumber,
    required this.googlePlaceId,
    required this.landmarkName,
    required this.address,
    required this.generalArea,
    required this.primaryType,
    required this.latitude,
    required this.longitude,
    required this.verifiedFacts,
    required this.clues,
    required this.status,
    this.referenceFingerprint = '',
    this.referenceKind = 'unknown',
    this.referenceWidth,
    this.referenceHeight,
  });
}

class SavedTripPathQuest {
  final String id;
  final String userId;
  final String themeId;
  final String themeName;
  final String? artworkId;
  final int currentCheckpoint;
  final int completedCheckpoints;
  final int totalCheckpoints;
  final String status;
  final DateTime? startedAt;
  final DateTime? lastPlayedAt;
  final List<SavedTripPathCheckpoint> checkpoints;

  const SavedTripPathQuest({
    required this.id,
    required this.userId,
    required this.themeId,
    required this.themeName,
    required this.artworkId,
    required this.currentCheckpoint,
    required this.completedCheckpoints,
    required this.totalCheckpoints,
    required this.status,
    required this.startedAt,
    required this.lastPlayedAt,
    required this.checkpoints,
  });
}

class TripPathQuestProgressRepository {
  final SupabaseClient client;

  const TripPathQuestProgressRepository({
    required this.client,
  });

  String? get currentUserId =>
      client.auth.currentUser?.id;

  bool get hasAuthenticatedUser =>
      currentUserId != null;

  Future<List<SavedTripPathQuest>> getActiveQuests() async {
    final userId = currentUserId;

    if (userId == null) {
      _log('No authenticated user. Resume lookup skipped.');
      return const <SavedTripPathQuest>[];
    }

    final questRows = await client
        .from('trip_path_quests')
        .select(
          'id, user_id, theme_id, theme_name, artwork_id, status, '
          'current_checkpoint, completed_checkpoints, total_checkpoints, '
          'started_at, last_played_at',
        )
        .eq('user_id', userId)
        .eq('status', 'in_progress')
        .order('last_played_at', ascending: false);

    if (questRows is! List || questRows.isEmpty) {
      return const <SavedTripPathQuest>[];
    }

    final result = <SavedTripPathQuest>[];

    for (final rawQuest in questRows) {
      if (rawQuest is! Map) {
        continue;
      }

      final parsed = await _loadActiveQuestRow(rawQuest);

      if (parsed != null) {
        // Recover rows left behind by older clients that advanced the local
        // artwork before the final Supabase header update completed. If every
        // checkpoint row is already completed, repair the header and keep the
        // finished quest out of the Continue list.
        if (_hasCompletedCheckpointRows(parsed)) {
          await _repairCompletedQuestHeader(
            questId: parsed.id,
            userId: userId,
          );
          continue;
        }

        result.add(parsed);
      }
    }

    _log('Active quests found: ${result.length}.');

    return List.unmodifiable(result);
  }

  // Backwards-compatible helper for code paths that only need the
  // most recently played in-progress quest.
  Future<SavedTripPathQuest?> getActiveQuest() async {
    final quests = await getActiveQuests();
    return quests.isEmpty ? null : quests.first;
  }

  // Resume must target the exact card the user selected. Never fetch
  // "latest" here because a user can now have multiple saved games.
  Future<SavedTripPathQuest?> getActiveQuestById(
    String questId,
  ) async {
    final userId = currentUserId;
    final normalizedQuestId = questId.trim();

    if (userId == null || normalizedQuestId.isEmpty) {
      return null;
    }

    final rawQuest = await client
        .from('trip_path_quests')
        .select(
          'id, user_id, theme_id, theme_name, artwork_id, status, '
          'current_checkpoint, completed_checkpoints, total_checkpoints, '
          'started_at, last_played_at',
        )
        .eq('id', normalizedQuestId)
        .eq('user_id', userId)
        .eq('status', 'in_progress')
        .maybeSingle();

    if (rawQuest == null || rawQuest is! Map) {
      return null;
    }

    return _loadActiveQuestRow(rawQuest);
  }

  Future<SavedTripPathQuest?> _loadActiveQuestRow(
    Map rawQuest,
  ) async {
    final questId = '${rawQuest['id'] ?? ''}'.trim();

    if (questId.isEmpty) {
      return null;
    }

    final checkpointRows = await client
        .from('trip_path_quest_checkpoints')
        .select(
          'checkpoint_number, google_place_id, landmark_name, address, '
          'general_area, primary_type, latitude, longitude, verified_facts, '
          'clue_1, clue_2, clue_3, status, reference_fingerprint, '
          'reference_kind, reference_width, reference_height',
        )
        .eq('quest_id', questId)
        .order('checkpoint_number', ascending: true);

    final checkpoints = <SavedTripPathCheckpoint>[];

    if (checkpointRows is List) {
      for (final raw in checkpointRows) {
        if (raw is! Map) {
          continue;
        }

        final parsed = _parseCheckpoint(raw);

        if (parsed != null) {
          checkpoints.add(parsed);
        }
      }
    }

    if (checkpoints.isEmpty || checkpoints.length > 3) {
      _log(
        'Active quest $questId has an invalid checkpoint row count: '
        '${checkpoints.length}.',
      );
      return null;
    }

    if (checkpoints.length < 3) {
      _log(
        'Active quest $questId is still preparing checkpoints: '
        '${checkpoints.length}/3 ready.',
      );
    }

    final result = SavedTripPathQuest(
      id: questId,
      userId: '${rawQuest['user_id'] ?? ''}'.trim(),
      themeId: '${rawQuest['theme_id'] ?? ''}'.trim(),
      themeName: '${rawQuest['theme_name'] ?? ''}'.trim(),
      artworkId: _nullableString(rawQuest['artwork_id']),
      currentCheckpoint:
          _toInt(rawQuest['current_checkpoint'], fallback: 1),
      completedCheckpoints:
          _toInt(rawQuest['completed_checkpoints'], fallback: 0),
      totalCheckpoints:
          _toInt(rawQuest['total_checkpoints'], fallback: 3),
      status: '${rawQuest['status'] ?? 'in_progress'}'.trim(),
      startedAt: _toDateTime(rawQuest['started_at']),
      lastPlayedAt: _toDateTime(rawQuest['last_played_at']),
      checkpoints: List.unmodifiable(checkpoints),
    );

    _log(
      'Active quest found: ${result.themeName} '
      '${result.completedCheckpoints}/${result.totalCheckpoints}.',
    );

    return result;
  }

  bool _hasCompletedCheckpointRows(SavedTripPathQuest quest) {
    if (quest.totalCheckpoints <= 0 ||
        quest.checkpoints.length < quest.totalCheckpoints) {
      return false;
    }

    return quest.checkpoints
        .take(quest.totalCheckpoints)
        .every((checkpoint) => checkpoint.status == 'completed');
  }

  Future<void> _repairCompletedQuestHeader({
    required String questId,
    required String userId,
  }) async {
    try {
      await client
          .from('trip_path_quests')
          .update({
            'status': 'completed',
            'completed_checkpoints': 3,
            'current_checkpoint': 3,
            'completed_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', questId)
          .eq('user_id', userId)
          .eq('status', 'in_progress');

      _log('Repaired completed quest header: $questId.');
    } catch (error) {
      // The active list is still filtered from this response. A later read
      // can retry the repair if the network was temporarily unavailable.
      _log('Completed quest header repair failed for $questId: $error');
    }
  }

  Future<String> createQuest({
    required String themeId,
    required String themeName,
    required String? artworkId,
    required List<QuestCheckpointSaveData> checkpoints,
  }) async {
    final userId = currentUserId;

    if (userId == null) {
      throw StateError(
        'Please sign in before starting a Trip Path Quest.',
      );
    }

    if (checkpoints.isEmpty ||
        checkpoints.length > 3) {
      throw StateError(
        'A Trip Path Quest must start with between 1 and 3 '
        'reference-ready checkpoints.',
      );
    }

    final numbers = checkpoints
        .map((checkpoint) => checkpoint.checkpointNumber)
        .toSet();

    if (!numbers.contains(1)) {
      throw StateError(
        'Checkpoint 1 must be reference-ready before the quest starts.',
      );
    }

    final now = DateTime.now().toUtc().toIso8601String();

    dynamic questRow;

    try {
      questRow = await client
          .from('trip_path_quests')
          .insert(
            {
              'user_id': userId,
              'theme_id': themeId,
              'theme_name': themeName,
              'artwork_id': artworkId,
              'status': 'in_progress',
              'current_checkpoint': 1,
              'completed_checkpoints': 0,
              'total_checkpoints': 3,
              'started_at': now,
              'last_played_at': now,
            },
          )
          .select('id')
          .single();
    } on PostgrestException catch (error) {
      final combined = <String>[
        error.code ?? '',
        error.message,
        '${error.details ?? ''}',
        '${error.hint ?? ''}',
      ].join(' ').toLowerCase();

      if (error.code == '23505' &&
          (combined.contains('in_progress') ||
              combined.contains('active') ||
              combined.contains('trip_path_quests'))) {
        throw StateError(
          'MULTIPLE_UNFINISHED_QUESTS_DATABASE_MIGRATION_REQUIRED: '
          'Supabase is still enforcing the legacy one-active-quest rule.',
        );
      }

      rethrow;
    }

    final questId = '${questRow['id'] ?? ''}'.trim();

    if (questId.isEmpty) {
      throw StateError(
        'Supabase did not return a Trip Path Quest ID.',
      );
    }

    final checkpointPayload = checkpoints
        .map(
          (checkpoint) => <String, dynamic>{
            'quest_id': questId,
            'checkpoint_number': checkpoint.checkpointNumber,
            'google_place_id': checkpoint.googlePlaceId,
            'landmark_name': checkpoint.landmarkName,
            'address': checkpoint.address,
            'general_area': checkpoint.generalArea,
            'primary_type': checkpoint.primaryType,
            'latitude': checkpoint.latitude,
            'longitude': checkpoint.longitude,
            'verified_facts': checkpoint.verifiedFacts,
            'reference_fingerprint': checkpoint.referenceFingerprint.isEmpty ? null : checkpoint.referenceFingerprint,
            'reference_kind': checkpoint.referenceKind == 'unknown' ? null : checkpoint.referenceKind,
            'reference_width': checkpoint.referenceWidth,
            'reference_height': checkpoint.referenceHeight,
            'clue_1': checkpoint.clues.length >= 1
                ? checkpoint.clues[0]
                : null,
            'clue_2': checkpoint.clues.length >= 2
                ? checkpoint.clues[1]
                : null,
            'clue_3': checkpoint.clues.length >= 3
                ? checkpoint.clues[2]
                : null,
            'status': checkpoint.checkpointNumber == 1
                ? 'current'
                : 'pending',
          },
        )
        .toList(growable: false);

    try {
      await client
          .from('trip_path_quest_checkpoints')
          .insert(checkpointPayload);
    } catch (error) {
      await client
          .from('trip_path_quests')
          .update(
            {
              'status': 'abandoned',
              'abandoned_at': now,
              'last_played_at': now,
            },
          )
          .eq('id', questId)
          .eq('user_id', userId);

      rethrow;
    }

    _log(
      'Quest saved: $questId | $themeName | 0/3.',
    );

    return questId;
  }


  // ============================================================
  // ADD A BACKGROUND-PREPARED CHECKPOINT
  //
  // CP1 may start the game while CP2/CP3 are prepared in the
  // background. A checkpoint row is inserted only AFTER its
  // automatic reference photo has already passed screening.
  // ============================================================

  Future<void> addPreparedCheckpoint({
    required String questId,
    required QuestCheckpointSaveData checkpoint,
  }) async {
    final userId = currentUserId;

    if (userId == null) {
      throw StateError(
        'Please sign in before updating a Trip Path Quest.',
      );
    }

    final normalizedQuestId = questId.trim();

    if (normalizedQuestId.isEmpty ||
        checkpoint.checkpointNumber < 2 ||
        checkpoint.checkpointNumber > 3) {
      throw StateError(
        'Invalid background checkpoint insert request.',
      );
    }

    final existing = await client
        .from('trip_path_quest_checkpoints')
        .select('checkpoint_number')
        .eq('quest_id', normalizedQuestId)
        .eq('checkpoint_number', checkpoint.checkpointNumber)
        .maybeSingle();

    if (existing != null) {
      _log(
        'CP${checkpoint.checkpointNumber} already exists for '
        '$normalizedQuestId; insert skipped.',
      );
      return;
    }

    final quest = await client
        .from('trip_path_quests')
        .select('current_checkpoint, status')
        .eq('id', normalizedQuestId)
        .eq('user_id', userId)
        .maybeSingle();

    if (quest == null ||
        '${quest['status'] ?? ''}'.trim() != 'in_progress') {
      throw StateError(
        'The Trip Path Quest is no longer active.',
      );
    }

    final currentCheckpoint =
        _toInt(
          quest['current_checkpoint'],
          fallback: 1,
        );

    await client
        .from('trip_path_quest_checkpoints')
        .insert(
          {
            'quest_id': normalizedQuestId,
            'checkpoint_number': checkpoint.checkpointNumber,
            'google_place_id': checkpoint.googlePlaceId,
            'landmark_name': checkpoint.landmarkName,
            'address': checkpoint.address,
            'general_area': checkpoint.generalArea,
            'primary_type': checkpoint.primaryType,
            'latitude': checkpoint.latitude,
            'longitude': checkpoint.longitude,
            'verified_facts': checkpoint.verifiedFacts,
            'reference_fingerprint': checkpoint.referenceFingerprint.isEmpty ? null : checkpoint.referenceFingerprint,
            'reference_kind': checkpoint.referenceKind == 'unknown' ? null : checkpoint.referenceKind,
            'reference_width': checkpoint.referenceWidth,
            'reference_height': checkpoint.referenceHeight,
            'clue_1': checkpoint.clues.length >= 1
                ? checkpoint.clues[0]
                : null,
            'clue_2': checkpoint.clues.length >= 2
                ? checkpoint.clues[1]
                : null,
            'clue_3': checkpoint.clues.length >= 3
                ? checkpoint.clues[2]
                : null,
            'status': currentCheckpoint == checkpoint.checkpointNumber
                ? 'current'
                : 'pending',
          },
        );

    _log(
      'Background checkpoint saved: '
      'CP${checkpoint.checkpointNumber} | '
      '${checkpoint.landmarkName}.',
    );
  }


  // ============================================================
  // REPLACE AN INCOMPLETE CHECKPOINT
  //
  // Used only when a resumed checkpoint can no longer obtain a
  // reliable reference photo. Completed checkpoints are never changed.
  // The replacement is already reference-ready before this update.
  // ============================================================

  Future<void> replaceIncompleteCheckpoint({
    required String questId,
    required int checkpointNumber,
    required QuestCheckpointSaveData checkpoint,
  }) async {
    final userId = currentUserId;

    if (userId == null) {
      throw StateError(
        'Please sign in before updating a Trip Path Quest.',
      );
    }

    if (questId.trim().isEmpty ||
        checkpointNumber < 1 ||
        checkpointNumber > 3) {
      throw StateError(
        'Invalid checkpoint replacement request.',
      );
    }

    final existing = await client
        .from('trip_path_quest_checkpoints')
        .select('status')
        .eq('quest_id', questId)
        .eq('checkpoint_number', checkpointNumber)
        .maybeSingle();

    final existingStatus =
        '${existing?['status'] ?? ''}'.trim();

    if (existingStatus == 'completed') {
      throw StateError(
        'A completed checkpoint cannot be replaced.',
      );
    }

    await client
        .from('trip_path_quest_checkpoints')
        .update(
          {
            'google_place_id': checkpoint.googlePlaceId,
            'landmark_name': checkpoint.landmarkName,
            'address': checkpoint.address,
            'general_area': checkpoint.generalArea,
            'primary_type': checkpoint.primaryType,
            'latitude': checkpoint.latitude,
            'longitude': checkpoint.longitude,
            'verified_facts': checkpoint.verifiedFacts,
            'reference_fingerprint': checkpoint.referenceFingerprint.isEmpty ? null : checkpoint.referenceFingerprint,
            'reference_kind': checkpoint.referenceKind == 'unknown' ? null : checkpoint.referenceKind,
            'reference_width': checkpoint.referenceWidth,
            'reference_height': checkpoint.referenceHeight,
            'clue_1': null,
            'clue_2': null,
            'clue_3': null,
            'completed_at': null,
            'status': existingStatus.isNotEmpty
                ? existingStatus
                : (checkpointNumber == 1
                    ? 'current'
                    : 'pending'),
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          },
        )
        .eq('quest_id', questId)
        .eq('checkpoint_number', checkpointNumber);

    _log(
      'Replaced unavailable CP$checkpointNumber for quest $questId.',
    );
  }

  Future<void> saveCheckpointReferenceFingerprint({
    required String questId,
    required int checkpointNumber,
    required String fingerprint,
    required String referenceKind,
    int? width,
    int? height,
  }) async {
    if (questId.trim().isEmpty ||
        checkpointNumber < 1 ||
        checkpointNumber > 3 ||
        fingerprint.trim().isEmpty) {
      return;
    }

    await client
        .from('trip_path_quest_checkpoints')
        .update({
          'reference_fingerprint': fingerprint.trim().toLowerCase(),
          'reference_kind': referenceKind.trim().isEmpty ? 'unknown' : referenceKind.trim(),
          'reference_width': width,
          'reference_height': height,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        })
        .eq('quest_id', questId)
        .eq('checkpoint_number', checkpointNumber);

    _log('Saved CP$checkpointNumber reference fingerprint.');
  }

  Future<void> saveCheckpointClues({
    required String questId,
    required int checkpointNumber,
    required List<String> clues,
  }) async {
    if (questId.trim().isEmpty || clues.length != 3) {
      return;
    }

    await client
        .from('trip_path_quest_checkpoints')
        .update(
          {
            'clue_1': clues[0],
            'clue_2': clues[1],
            'clue_3': clues[2],
          },
        )
        .eq('quest_id', questId)
        .eq('checkpoint_number', checkpointNumber);

    _log(
      'Saved CP$checkpointNumber clues for quest $questId.',
    );
  }

  Future<void> completeCheckpoint({
    required String questId,
    required int checkpointNumber,
    required int totalCheckpoints,
  }) async {
    final userId = currentUserId;
    final normalizedQuestId = questId.trim();

    if (userId == null) {
      throw StateError(
        'Please sign in before saving checkpoint progress.',
      );
    }

    if (normalizedQuestId.isEmpty ||
        totalCheckpoints < 1 ||
        checkpointNumber < 1 ||
        checkpointNumber > totalCheckpoints) {
      throw StateError(
        'Invalid checkpoint completion request.',
      );
    }

    // Read the owned quest first. The old implementation returned early
    // for missing auth and then accepted an update that affected zero rows.
    // That made the UI advance even though Supabase had not saved anything.
    final rawQuest = await client
        .from('trip_path_quests')
        .select(
          'id, status, current_checkpoint, completed_checkpoints, '
          'total_checkpoints',
        )
        .eq('id', normalizedQuestId)
        .eq('user_id', userId)
        .maybeSingle();

    if (rawQuest == null || rawQuest is! Map) {
      throw StateError(
        'The saved quest could not be found for this account.',
      );
    }

    final questStatus = '${rawQuest['status'] ?? ''}'.trim();
    if (questStatus != 'in_progress' && questStatus != 'completed') {
      throw StateError(
        'The saved quest is no longer active.',
      );
    }

    final storedTotal = _toInt(
      rawQuest['total_checkpoints'],
      fallback: totalCheckpoints,
    );
    if (storedTotal != totalCheckpoints) {
      throw StateError(
        'The saved quest has an incompatible checkpoint count.',
      );
    }

    final rawCheckpoint = await client
        .from('trip_path_quest_checkpoints')
        .select('status, completed_at')
        .eq('quest_id', normalizedQuestId)
        .eq('checkpoint_number', checkpointNumber)
        .maybeSingle();

    if (rawCheckpoint == null || rawCheckpoint is! Map) {
      throw StateError(
        'This checkpoint is not available in the saved quest.',
      );
    }

    final now = DateTime.now().toUtc().toIso8601String();

    final checkpointStatus =
        '${rawCheckpoint['status'] ?? ''}'.trim();

    // Retrying a completion is safe. If the first request reached the
    // checkpoint row but failed before the quest header update, this call
    // leaves the row completed and repairs the header below.
    if (checkpointStatus != 'completed') {
      final checkpointUpdate = await client
          .from('trip_path_quest_checkpoints')
          .update(
            {
              'status': 'completed',
              'completed_at': now,
            },
          )
          .eq('quest_id', normalizedQuestId)
          .eq('checkpoint_number', checkpointNumber)
          .select('status')
          .maybeSingle();

      if (checkpointUpdate == null ||
          '${checkpointUpdate['status'] ?? ''}'.trim() != 'completed') {
        throw StateError(
          'Checkpoint completion was not confirmed by Supabase.',
        );
      }
    }

    final isFinal = checkpointNumber >= totalCheckpoints;

    if (!isFinal) {
      await client
          .from('trip_path_quest_checkpoints')
          .update(
            {
              'status': 'current',
            },
          )
          .eq('quest_id', normalizedQuestId)
          .eq('checkpoint_number', checkpointNumber + 1);
    }

    final storedCompleted = _toInt(
      rawQuest['completed_checkpoints'],
      fallback: 0,
    );
    final storedCurrent = _toInt(
      rawQuest['current_checkpoint'],
      fallback: 1,
    );
    final nextCompleted = storedCompleted > checkpointNumber
        ? storedCompleted
        : checkpointNumber;
    final nextCurrent = isFinal
        ? totalCheckpoints
        : (storedCurrent > checkpointNumber + 1
            ? storedCurrent
            : checkpointNumber + 1);

    final questUpdate = <String, dynamic>{
      'completed_checkpoints': nextCompleted,
      'current_checkpoint': nextCurrent,
      'last_played_at': now,
    };

    if (isFinal) {
      questUpdate['status'] = 'completed';
      questUpdate['completed_at'] = now;
    }

    if (questStatus == 'in_progress') {
      final updatedQuest = await client
        .from('trip_path_quests')
        .update(questUpdate)
        .eq('id', normalizedQuestId)
        .eq('user_id', userId)
        .select(
          'status, completed_checkpoints, current_checkpoint',
        )
        .maybeSingle();

      if (updatedQuest == null) {
        throw StateError(
          'Quest progress was not confirmed by Supabase.',
        );
      }
    }

    // Read the header after the write and verify the monotonic progress.
    // This catches RLS/no-row updates and prevents a false local completion.
    final savedQuest = await client
        .from('trip_path_quests')
        .select('status, completed_checkpoints, current_checkpoint')
        .eq('id', normalizedQuestId)
        .eq('user_id', userId)
        .maybeSingle();

    if (savedQuest == null || savedQuest is! Map) {
      throw StateError(
        'Quest progress could not be read back after saving.',
      );
    }

    final savedCompleted = _toInt(
      savedQuest['completed_checkpoints'],
      fallback: 0,
    );
    if (savedCompleted < checkpointNumber ||
        (isFinal && '${savedQuest['status'] ?? ''}'.trim() != 'completed')) {
      throw StateError(
        'Supabase returned an incomplete quest after the save.',
      );
    }

    _log(
      isFinal
          ? 'Quest completed: $normalizedQuestId.'
          : 'Quest $normalizedQuestId progress saved: '
              '$savedCompleted/$totalCheckpoints.',
    );
  }

  Future<void> saveInProgressSnapshot({
    required String questId,
    required int currentCheckpoint,
    required int completedCheckpoints,
  }) async {
    final userId = currentUserId;
    final normalizedQuestId = questId.trim();

    if (userId == null || normalizedQuestId.isEmpty) {
      return;
    }

    final rawQuest = await client
        .from('trip_path_quests')
        .select('current_checkpoint, completed_checkpoints, status')
        .eq('id', normalizedQuestId)
        .eq('user_id', userId)
        .eq('status', 'in_progress')
        .maybeSingle();

    if (rawQuest == null || rawQuest is! Map) {
      throw StateError(
        'The in-progress quest could not be found while saving.',
      );
    }

    final requestedCurrent = currentCheckpoint.clamp(1, 3).toInt();
    final requestedCompleted = completedCheckpoints.clamp(0, 2).toInt();
    final storedCurrent = _toInt(
      rawQuest['current_checkpoint'],
      fallback: 1,
    );
    final storedCompleted = _toInt(
      rawQuest['completed_checkpoints'],
      fallback: 0,
    );

    // Save & Exit can overlap a delayed completion callback. Preserve the
    // greatest progress already in Supabase so an old snapshot can never
    // move a finished checkpoint backwards.
    final safeCurrent = storedCurrent > requestedCurrent
        ? storedCurrent
        : requestedCurrent;
    final safeCompleted = storedCompleted > requestedCompleted
        ? storedCompleted
        : requestedCompleted;
    final now = DateTime.now().toUtc().toIso8601String();

    final updatedQuest = await client
        .from('trip_path_quests')
        .update(
          {
            'current_checkpoint': safeCurrent,
            'completed_checkpoints': safeCompleted,
            'last_played_at': now,
          },
        )
        .eq('id', normalizedQuestId)
        .eq('user_id', userId)
        .eq('status', 'in_progress')
        .select('current_checkpoint, completed_checkpoints')
        .maybeSingle();

    if (updatedQuest == null) {
      throw StateError(
        'Save & Exit progress was not confirmed by Supabase.',
      );
    }

    _log(
      'Save & Exit snapshot: $normalizedQuestId | '
      '$safeCompleted/3 | next CP$safeCurrent.',
    );
  }

  Future<void> touchQuest(String questId) async {
    final userId = currentUserId;

    if (userId == null || questId.trim().isEmpty) {
      return;
    }

    await client
        .from('trip_path_quests')
        .update(
          {
            'last_played_at':
                DateTime.now().toUtc().toIso8601String(),
          },
        )
        .eq('id', questId)
        .eq('user_id', userId)
        .eq('status', 'in_progress');
  }

  Future<void> abandonQuest(String questId) async {
    final userId = currentUserId;

    if (userId == null || questId.trim().isEmpty) {
      return;
    }

    final now = DateTime.now().toUtc().toIso8601String();

    await client
        .from('trip_path_quests')
        .update(
          {
            'status': 'abandoned',
            'abandoned_at': now,
            'last_played_at': now,
          },
        )
        .eq('id', questId)
        .eq('user_id', userId)
        .eq('status', 'in_progress');

    _log('Quest abandoned: $questId.');
  }

  Future<void> abandonActiveQuest() async {
    final active = await getActiveQuest();

    if (active == null) {
      return;
    }

    await abandonQuest(active.id);
  }

  SavedTripPathCheckpoint? _parseCheckpoint(
    Map raw,
  ) {
    final checkpointNumber =
        _toInt(raw['checkpoint_number'], fallback: 0);
    final placeId =
        '${raw['google_place_id'] ?? ''}'.trim();
    final name = '${raw['landmark_name'] ?? ''}'.trim();
    final latitude = _toDouble(raw['latitude']);
    final longitude = _toDouble(raw['longitude']);

    if (checkpointNumber < 1 ||
        checkpointNumber > 3 ||
        placeId.isEmpty ||
        name.isEmpty ||
        latitude == null ||
        longitude == null) {
      return null;
    }

    final verifiedFacts = <String>[];
    final rawFacts = raw['verified_facts'];

    if (rawFacts is List) {
      for (final fact in rawFacts) {
        final text = '$fact'.trim();

        if (text.isNotEmpty) {
          verifiedFacts.add(text);
        }
      }
    }

    final clues = <String>[];

    for (final key in const ['clue_1', 'clue_2', 'clue_3']) {
      final text = '${raw[key] ?? ''}'.trim();

      if (text.isNotEmpty) {
        clues.add(text);
      }
    }

    return SavedTripPathCheckpoint(
      checkpointNumber: checkpointNumber,
      googlePlaceId: placeId,
      landmarkName: name,
      address: '${raw['address'] ?? ''}'.trim(),
      generalArea: '${raw['general_area'] ?? 'Nearby Area'}'.trim(),
      primaryType: '${raw['primary_type'] ?? 'tourist attraction'}'.trim(),
      latitude: latitude,
      longitude: longitude,
      verifiedFacts: List.unmodifiable(verifiedFacts),
      clues: List.unmodifiable(clues),
      status: '${raw['status'] ?? 'pending'}'.trim(),
      referenceFingerprint: '${raw['reference_fingerprint'] ?? ''}'.trim(),
      referenceKind: '${raw['reference_kind'] ?? 'unknown'}'.trim(),
      referenceWidth: _toNullableInt(raw['reference_width']),
      referenceHeight: _toNullableInt(raw['reference_height']),
    );
  }

  int _toInt(
    dynamic value, {
    required int fallback,
  }) {
    if (value is int) {
      return value;
    }

    return int.tryParse('$value') ?? fallback;
  }

  int? _toNullableInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    return int.tryParse('$value');
  }

  double? _toDouble(dynamic value) {
    if (value is num) {
      return value.toDouble();
    }

    return double.tryParse('$value');
  }

  String? _nullableString(dynamic value) {
    if (value == null) {
      return null;
    }

    final text = '$value'.trim();

    return text.isEmpty ? null : text;
  }

  DateTime? _toDateTime(dynamic value) {
    final text = '${value ?? ''}'.trim();

    if (text.isEmpty) {
      return null;
    }

    return DateTime.tryParse(text)?.toLocal();
  }

  void _log(String message) {
    if (kDebugMode) {
      debugPrint(
        '[QUEST PROGRESS] $message',
      );
    }
  }
}
