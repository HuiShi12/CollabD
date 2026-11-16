import '../Reward Repository/reward_repository.dart';
import '../Attraction Repository/attraction.dart';
import '../Mission Repository/mission.dart';
import '../Puzzle Repository/puzzle.dart';
import '../Visit Proof Repository/visit_proof.dart';
import '../../service/Supabase Service/supabase.dart';

class MysteryGameProgressResult {
  final String sessionId;
  final String touristId;
  final String hiddenPlaceId;
  final String hiddenPlaceName;
  final String township;
  final String verifiedTouristPhotoUrl;
  final DateTime completionDate;
  final bool visitVerified;

  MysteryGameProgressResult({
    required this.sessionId,
    required this.touristId,
    required this.hiddenPlaceId,
    required this.hiddenPlaceName,
    required this.township,
    required this.verifiedTouristPhotoUrl,
    required this.completionDate,
    required this.visitVerified,
  });

  Map<String, dynamic> toMap() {
    return {
      'session_id': sessionId,
      'tourist_id': touristId,
      'hidden_place_id': hiddenPlaceId,
      'hidden_place_name': hiddenPlaceName,
      'township': township,
      'verified_tourist_photo_url': verifiedTouristPhotoUrl,
      'completion_date': completionDate.toIso8601String(),
      'visit_verified': visitVerified,
    };
  }
}

/// UC-05 — a resumable game_sessions row (status = 'In Progress'), either
/// still mid-jigsaw ([stage] == 'puzzle') or already solved and mid-navigate
/// ([stage] == 'navigate').
class SavedPuzzleSession {
  final String id;
  final String hiddenPlaceId;
  final String hiddenPlaceName;
  final String township;
  final String category;
  final String referenceImageUrl;
  final double latitude;
  final double longitude;
  final String stage;
  final List<PuzzlePieceData>? pieces;
  final int hintsLeft;
  final int elapsedSeconds;
  final DateTime? updatedAt;

  const SavedPuzzleSession({
    required this.id,
    required this.hiddenPlaceId,
    required this.hiddenPlaceName,
    required this.township,
    required this.category,
    required this.referenceImageUrl,
    required this.latitude,
    required this.longitude,
    required this.stage,
    required this.pieces,
    required this.hintsLeft,
    required this.elapsedSeconds,
    required this.updatedAt,
  });
}

class ProgressRepository {
  final MissionRepository missionRepository;
  final VisitProofRepository visitProofRepository;
  final SupabaseService supabaseService;
  final RewardRepository rewardRepository;

  ProgressRepository({
    required this.missionRepository,
    required this.visitProofRepository,
    required this.supabaseService,
    required this.rewardRepository,
  });

  Future<String> createGameSession({
    required String touristId,
    required MysteryPlaceOption selectedOption,
  }) {
    return supabaseService.createGameSession(
      data: {
        'tourist_id': touristId,
        'user_id': supabaseService.currentUserId,
        'mission_id': 'mission_mystery_place_puzzle',
        'hidden_place_id': selectedOption.id,
        'hidden_place_name': selectedOption.name,
        'township': selectedOption.township,
        'category': selectedOption.category,
        'reference_image_url': selectedOption.imageUrl,
        'latitude': selectedOption.latitude,
        'longitude': selectedOption.longitude,
        'status': 'In Progress',
        'stage': 'puzzle',
        'puzzle_completed': false,
        'visit_verified': false,
        'created_at': DateTime.now().toIso8601String(),
        // getActiveSessions() sorts "Continue Your Mystery" by updated_at
        // DESC. Without this, a brand-new session has no updated_at until
        // the tourist explicitly resumes it once (touchSession bumps it),
        // so it sorted to the back of the list instead of showing first
        // right after starting it.
        'updated_at': DateTime.now().toIso8601String(),
      },
    );
  }

  Future<void> savePuzzleCompleted({required String sessionId}) {
    return supabaseService.updateGameSession(
      sessionId: sessionId,
      data: {
        'puzzle_completed': true,
        'puzzle_completed_at': DateTime.now().toIso8601String(),
        'stage': 'navigate',
        'updated_at': DateTime.now().toIso8601String(),
      },
    );
  }

  /// UC-05 — the puzzle resume prompt's "Continue Your Mystery" list.
  Future<List<SavedPuzzleSession>> getActiveSessions() async {
    final userId = supabaseService.currentUserId;
    if (userId == null) return const <SavedPuzzleSession>[];

    final rows = await supabaseService.getActiveGameSessions(userId);
    return [
      for (final row in rows) ?_parseSession(row),
    ];
  }

  /// Fire-and-forget autosave, called after every tile swap / hint use while
  /// the jigsaw is being solved. Fails silently — a missed autosave should
  /// never interrupt play.
  Future<void> saveProgressSnapshot({
    required String sessionId,
    required List<PuzzlePieceData> pieces,
    required int hintsLeft,
    required int elapsedSeconds,
  }) async {
    try {
      await supabaseService.updateGameSession(
        sessionId: sessionId,
        data: {
          'stage': 'puzzle',
          'puzzle_pieces': [
            for (final piece in pieces)
              {
                'pieceId': piece.pieceId,
                'correctIndex': piece.correctIndex,
                'currentIndex': piece.currentIndex,
              },
          ],
          'hints_left': hintsLeft,
          'elapsed_seconds': elapsedSeconds,
          'updated_at': DateTime.now().toIso8601String(),
        },
      );
    } catch (_) {
      // Best-effort — the next successful autosave (or the puzzle-completed
      // write) will catch up.
    }
  }

  /// Bumps updated_at on resume, so "Continue Your Mystery" sorts the most
  /// recently played session first.
  Future<void> touchSession(String sessionId) async {
    try {
      await supabaseService.updateGameSession(
        sessionId: sessionId,
        data: {'updated_at': DateTime.now().toIso8601String()},
      );
    } catch (_) {}
  }

  SavedPuzzleSession? _parseSession(Map<String, dynamic> row) {
    final id = '${row['id'] ?? ''}'.trim();
    final placeId = '${row['hidden_place_id'] ?? ''}'.trim();
    final name = '${row['hidden_place_name'] ?? ''}'.trim();
    final lat = (row['latitude'] as num?)?.toDouble();
    final lng = (row['longitude'] as num?)?.toDouble();
    if (id.isEmpty || placeId.isEmpty || name.isEmpty || lat == null || lng == null) {
      // Sessions created before latitude/longitude were tracked can't be
      // resumed into Navigate — leave them out of the list rather than
      // resuming to an unknown destination.
      return null;
    }

    List<PuzzlePieceData>? pieces;
    final rawPieces = row['puzzle_pieces'];
    if (rawPieces is List && rawPieces.isNotEmpty) {
      pieces = [
        for (final raw in rawPieces)
          if (raw is Map)
            PuzzlePieceData(
              pieceId: (raw['pieceId'] as num?)?.toInt() ?? 0,
              correctIndex: (raw['correctIndex'] as num?)?.toInt() ?? 0,
              currentIndex: (raw['currentIndex'] as num?)?.toInt() ?? 0,
            ),
      ];
    }

    return SavedPuzzleSession(
      id: id,
      hiddenPlaceId: placeId,
      hiddenPlaceName: name,
      township: '${row['township'] ?? 'Nearby'}'.trim(),
      category: '${row['category'] ?? 'Hidden Place'}'.trim(),
      referenceImageUrl: '${row['reference_image_url'] ?? ''}'.trim(),
      latitude: lat,
      longitude: lng,
      stage: '${row['stage'] ?? 'puzzle'}'.trim(),
      pieces: pieces,
      hintsLeft: (row['hints_left'] as num?)?.toInt() ?? 3,
      elapsedSeconds: (row['elapsed_seconds'] as num?)?.toInt() ?? 0,
      updatedAt: DateTime.tryParse('${row['updated_at'] ?? ''}'),
    );
  }

  Future<MysteryGameProgressResult> saveVisitVerifiedAndCompleteGame({
    required String sessionId,
    required String touristId,
    required MysteryPlaceOption selectedOption,
    required VisitProofResult visitProofResult,
  }) async {
    final session = await supabaseService.getGameSession(sessionId: sessionId);
    if (session['tourist_id'] != touristId ||
        session['hidden_place_id'] != selectedOption.id) {
      throw StateError(
        'The completed session does not belong to this tourist and place.',
      );
    }
    final completionDate = session['completion_date'] == null
        ? DateTime.now()
        : DateTime.parse(session['completion_date'] as String);

    final result = MysteryGameProgressResult(
      sessionId: sessionId,
      touristId: touristId,
      hiddenPlaceId: selectedOption.id,
      hiddenPlaceName: selectedOption.name,
      township: selectedOption.township,
      verifiedTouristPhotoUrl: visitProofResult.uploadedPhotoPath,
      completionDate: completionDate,
      visitVerified: visitProofResult.isSuccess,
    );

    // Generate the Digital Travel Stamp *before* marking the session
    // Completed, not after. If stamp generation fails (frame/photo fetch,
    // storage upload, etc.), the session must stay exactly as it was so the
    // tourist can simply retry the same photo — previously, the session was
    // flipped to Completed first, so a failure here left it permanently
    // stuck showing "Completed" in Game History with no stamp and no way to
    // get one. generateDigitalTravelStamp is idempotent (keyed by
    // sessionId), so retrying after a partial failure here is always safe.
    if (result.visitVerified) {
      await rewardRepository.generateDigitalTravelStamp(
        touristId: result.touristId,
        completionId: result.sessionId,
        hiddenPlaceId: result.hiddenPlaceId,
        hiddenPlaceName: result.hiddenPlaceName,
        township: result.township,
        verifiedPhotoUrl: result.verifiedTouristPhotoUrl,
        completionDate: result.completionDate,
        visitVerified: result.visitVerified,
      );
    }

    await supabaseService.updateGameSession(
      sessionId: sessionId,
      data: {
        'visit_verified': visitProofResult.isSuccess,
        'verified_tourist_photo_url': visitProofResult.uploadedPhotoPath,
        'verification_message': visitProofResult.message,
        'status': visitProofResult.isSuccess ? 'Completed' : 'In Progress',
        'completion_date': visitProofResult.isSuccess
            ? completionDate.toIso8601String()
            : null,
        'updated_at': completionDate.toIso8601String(),
      },
    );

    return result;
  }

  Future<Map<String, dynamic>> getGameSession({required String sessionId}) {
    return supabaseService.getGameSession(sessionId: sessionId);
  }

  /// Saves final Trip Path progress before handing the result to Rewards.
  Future<TouristReward> saveTripPathCompletion({
    required String touristId,
    required String questId,
    required String theme,
    required String imageUrl,
    required int completedCheckpoints,
    required int totalCheckpoints,
    required DateTime completedAt,
  }) async {
    if (touristId.isEmpty ||
        questId.isEmpty ||
        imageUrl.isEmpty ||
        totalCheckpoints <= 0 ||
        completedCheckpoints != totalCheckpoints ||
        !RewardRepository.themes.contains(theme)) {
      throw StateError('A complete Trip Path result is required.');
    }
    await supabaseService.saveCompletedQuest({
      'tourist_id': touristId,
      'quest_id': questId,
      'theme': theme,
      'image_url': imageUrl,
      'completed_checkpoints': completedCheckpoints,
      'total_checkpoints': totalCheckpoints,
      'completed_at': completedAt.toIso8601String(),
      'status': 'Completed',
    });
    final stored = await supabaseService.getCompletedQuest(touristId, questId);
    if (stored == null) {
      throw StateError('Completed quest could not be retrieved.');
    }
    return rewardRepository.storeCompletedThemeSouvenir(
      touristId: touristId,
      questId: questId,
      theme: stored['theme'] as String,
      imageUrl: stored['image_url'] as String,
      completedCheckpoints: stored['completed_checkpoints'] as int,
      totalCheckpoints: stored['total_checkpoints'] as int,
      completedAt: DateTime.parse(stored['completed_at'] as String),
    );
  }
}
