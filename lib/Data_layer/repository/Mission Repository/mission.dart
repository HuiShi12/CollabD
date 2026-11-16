import '../Attraction Repository/attraction.dart';

class MysteryPuzzleMission {
  final String missionId;
  final String missionName;
  final String description;
  final List<MysteryPlaceOption> puzzleOptions;

  MysteryPuzzleMission({
    required this.missionId,
    required this.missionName,
    required this.description,
    required this.puzzleOptions,
  });
}

class MissionRepository {
  final AttractionRepository attractionRepository;

  MissionRepository(this.attractionRepository);

  Future<MysteryPuzzleMission> detectNearbyPuzzleGameMissions({
    Set<String> excludedPlaceIds = const {},
  }) async {
    final options = await attractionRepository.getNearbyPuzzleOptions(
      excludedPlaceIds: excludedPlaceIds,
    );

    return MysteryPuzzleMission(
      missionId: 'mission_mystery_place_puzzle',
      missionName: 'Mystery Place Puzzle Game',
      description:
      'Detect up to three nearby mystery puzzle game options based on the tourist current location.',
      puzzleOptions: options,
    );
  }
}