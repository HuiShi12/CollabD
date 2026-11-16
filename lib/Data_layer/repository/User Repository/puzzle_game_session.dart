/// UC-07 A3 — a Mystery Place Puzzle Game session retrieved for the
/// tourist's Game & Place History (`game_sessions` table).
class PuzzleGameSessionModel {
  final String id;
  final String? category;
  final String? hiddenPlaceName;
  final bool puzzleCompleted;
  final bool visitVerified;

  /// Already stored as 'In Progress' / 'Completed' by
  /// ProgressRepository.createGameSession / saveVisitVerifiedAndCompleteGame
  /// — no snake_case translation needed, unlike trip_path_quests.status.
  final String status;

  final DateTime? completionDate;
  final DateTime createdAt;
  final DateTime updatedAt;

  const PuzzleGameSessionModel({
    required this.id,
    required this.category,
    required this.hiddenPlaceName,
    required this.puzzleCompleted,
    required this.visitVerified,
    required this.status,
    required this.completionDate,
    required this.createdAt,
    required this.updatedAt,
  });

  factory PuzzleGameSessionModel.fromMap(Map<String, dynamic> map) {
    return PuzzleGameSessionModel(
      id: map['id']?.toString() ?? '',
      category: map['category']?.toString(),
      hiddenPlaceName: map['hidden_place_name']?.toString(),
      puzzleCompleted: map['puzzle_completed'] == true,
      visitVerified: map['visit_verified'] == true,
      status: map['status']?.toString() ?? 'In Progress',
      completionDate: map['completion_date'] != null
          ? DateTime.tryParse(map['completion_date'].toString())
          : null,
      createdAt: DateTime.tryParse(map['created_at'].toString()) ??
          DateTime.now(),
      updatedAt: DateTime.tryParse(map['updated_at'].toString()) ??
          DateTime.now(),
    );
  }

  bool get isInProgress => status == 'In Progress';

  bool get isCompleted => status == 'Completed';
}
