/// UC-07 A3 — a Trip Path Quest record retrieved for the tourist's
/// Game & Place History (`trip_path_quests` table).
class TripPathQuestModel {
  final String id;
  final String userId;

  final String themeId;
  final String themeName;

  final String status;

  final int currentCheckpoint;
  final int completedCheckpoints;
  final int totalCheckpoints;

  final DateTime startedAt;
  final DateTime lastPlayedAt;

  final DateTime? completedAt;
  final DateTime? abandonedAt;

  final DateTime createdAt;
  final DateTime updatedAt;

  final String? artworkId;

  /// Real place names for checkpoints actually visited (status
  /// 'completed'), ordered by checkpoint number — never includes a
  /// not-yet-visited checkpoint's name, matching Mystery Puzzle's own
  /// "reveal only once verified" history rule. Empty for a fresh quest with
  /// nothing completed yet.
  final List<String> completedCheckpointNames;

  const TripPathQuestModel({
    required this.id,
    required this.userId,
    required this.themeId,
    required this.themeName,
    required this.status,
    required this.currentCheckpoint,
    required this.completedCheckpoints,
    required this.totalCheckpoints,
    required this.startedAt,
    required this.lastPlayedAt,
    required this.createdAt,
    required this.updatedAt,
    this.completedAt,
    this.abandonedAt,
    this.artworkId,
    this.completedCheckpointNames = const <String>[],
  });

  factory TripPathQuestModel.fromMap(Map<String, dynamic> map) {
    final rawCheckpoints = map['_checkpoints'];
    final completedCheckpointNames = <String>[];
    if (rawCheckpoints is List) {
      final sorted = List<Map<String, dynamic>>.from(rawCheckpoints)
        ..sort(
          (a, b) => ((a['checkpoint_number'] as num?)?.toInt() ?? 0)
              .compareTo((b['checkpoint_number'] as num?)?.toInt() ?? 0),
        );
      for (final row in sorted) {
        if (row['status']?.toString() != 'completed') continue;
        final name = row['landmark_name']?.toString().trim() ?? '';
        if (name.isNotEmpty) completedCheckpointNames.add(name);
      }
    }

    return TripPathQuestModel(
      id: map['id']?.toString() ?? '',
      userId: map['user_id']?.toString() ?? '',
      themeId: map['theme_id']?.toString() ?? '',
      themeName: map['theme_name']?.toString() ?? '',
      status: map['status']?.toString() ?? 'in_progress',
      currentCheckpoint: map['current_checkpoint'] ?? 1,
      completedCheckpoints: map['completed_checkpoints'] ?? 0,
      totalCheckpoints: map['total_checkpoints'] ?? 3,
      startedAt: DateTime.parse(map['started_at'].toString()),
      lastPlayedAt: DateTime.parse(map['last_played_at'].toString()),
      completedAt: map['completed_at'] != null
          ? DateTime.tryParse(map['completed_at'].toString())
          : null,
      abandonedAt: map['abandoned_at'] != null
          ? DateTime.tryParse(map['abandoned_at'].toString())
          : null,
      createdAt: DateTime.parse(map['created_at'].toString()),
      updatedAt: DateTime.parse(map['updated_at'].toString()),
      artworkId: map['artwork_id']?.toString(),
      completedCheckpointNames: List.unmodifiable(completedCheckpointNames),
    );
  }

  bool get isInProgress => status == 'in_progress';

  bool get isCompleted => status == 'completed';

  bool get isAbandoned => status == 'abandoned';

  String get progressText =>
      '$completedCheckpoints / $totalCheckpoints checkpoints';
}
