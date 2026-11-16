import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../../../Data_layer/repository/Claimed Places Repository/claimed_places.dart';
import '../../../Data_layer/repository/Reward Repository/reward_repository.dart';
import '../../../Data_layer/repository/Trip Path Quest Repository/trip_path_attraction_repository.dart';
import '../../../Data_layer/repository/Trip Path Quest Repository/landmark_clue_repository.dart';
import '../../../Data_layer/repository/Trip Path Quest Repository/theme_artwork_repository.dart';
import '../../../Data_layer/repository/Trip Path Quest Repository/trip_path_quest_progress_repository.dart';
import '../../../Data_layer/repository/Trip Path Quest Repository/user_landmark_visit_repository.dart';
import '../../../Data_layer/repository/User Repository/current_tourist.dart';
import '../../../Data_layer/service/Trip Path Quest Service/trip_path_gemini_service.dart';
import 'trip_path_quest_navigation.dart';

// ============================================================
// QUEST STAGES
// ============================================================

enum TripPathQuestStage {
  themeSelection,
  questInformation,
  artworkIntro,
  clue,
  navigation,
  verification,
  questComplete,
}

// ============================================================
// QUEST THEME
// ============================================================

class QuestThemeData {
  final String id;
  final String name;
  final String area;

  const QuestThemeData({
    required this.id,
    required this.name,
    required this.area,
  });
}

// ============================================================
// TEMPORARY ATTRACTION
//
// Later this will be replaced by Attraction from:
//
// GPS
// → AttractionRepository
// → Google Places
// ============================================================

class TemporaryQuestAttraction {
  final String name;
  final String address;
  final String generalArea;
  final String placeType;

  final double latitude;
  final double longitude;

  final List<String> verifiedFacts;

  // Google Places metadata.
  final String? placeId;
  final double? rating;
  final int? userRatingCount;
  final String? photoResourceName;
  final String? googleMapsUri;

  // Automatic reference photo selected during Google Places
  // checkpoint preparation. The bytes exist only in this quest
  // session and are never saved to Supabase.
  final Uint8List? referencePhotoBytes;
  final double? referencePhotoScore;
  final int? referencePhotoWidth;
  final int? referencePhotoHeight;
  final int? referencePhotoKeypoints;
  final double? referencePhotoCoverage;
  final double? referencePhotoSharpness;
  final double? referenceSemanticScore;
  final bool referenceOcrNameMatched;
  final List<String> referenceSemanticLabels;
  final int referenceSuitabilityTier;
  final String referenceKind;
  final double? referenceSuitabilityScore;
  final String referenceFingerprint;

  const TemporaryQuestAttraction({
    required this.name,
    required this.address,
    required this.generalArea,
    required this.placeType,
    required this.latitude,
    required this.longitude,
    required this.verifiedFacts,
    this.placeId,
    this.rating,
    this.userRatingCount,
    this.photoResourceName,
    this.googleMapsUri,
    this.referencePhotoBytes,
    this.referencePhotoScore,
    this.referencePhotoWidth,
    this.referencePhotoHeight,
    this.referencePhotoKeypoints,
    this.referencePhotoCoverage,
    this.referencePhotoSharpness,
    this.referenceSemanticScore,
    this.referenceOcrNameMatched = false,
    this.referenceSemanticLabels = const <String>[],
    this.referenceSuitabilityTier = 99,
    this.referenceKind = 'unknown',
    this.referenceSuitabilityScore,
    this.referenceFingerprint = '',
  });

  TemporaryQuestAttraction withReferencePhoto(
      Uint8List bytes, {
        required double score,
        int? width,
        int? height,
        required int keypoints,
        required double coverage,
        required double sharpness,
        double? semanticScore,
        bool? ocrNameMatched,
        List<String>? semanticLabels,
        int? suitabilityTier,
        String? kind,
        double? suitabilityScore,
        String? fingerprint,
      }) {
    return TemporaryQuestAttraction(
      name: name,
      address: address,
      generalArea: generalArea,
      placeType: placeType,
      latitude: latitude,
      longitude: longitude,
      verifiedFacts: verifiedFacts,
      placeId: placeId,
      rating: rating,
      userRatingCount: userRatingCount,
      photoResourceName: null,
      googleMapsUri: googleMapsUri,
      referencePhotoBytes: bytes,
      referencePhotoScore: score,
      referencePhotoWidth: width ?? referencePhotoWidth,
      referencePhotoHeight: height ?? referencePhotoHeight,
      referencePhotoKeypoints: keypoints,
      referencePhotoCoverage: coverage,
      referencePhotoSharpness: sharpness,
      referenceSemanticScore: semanticScore ?? referenceSemanticScore,
      referenceOcrNameMatched: ocrNameMatched ?? referenceOcrNameMatched,
      referenceSemanticLabels: semanticLabels ?? referenceSemanticLabels,
      referenceSuitabilityTier: suitabilityTier ?? referenceSuitabilityTier,
      referenceKind: kind ?? referenceKind,
      referenceSuitabilityScore: suitabilityScore ?? referenceSuitabilityScore,
      referenceFingerprint: fingerprint ?? referenceFingerprint,
    );
  }
}

// ============================================================
// TRIP PATH QUEST VIEWMODEL
// ============================================================

class TripPathQuestViewModel extends ChangeNotifier {
  bool _disposed = false;

  @override
  void notifyListeners() {
    if (!_disposed) {
      super.notifyListeners();
    }
  }

  // ============================================================
  // DEBUG MOCK CLUE MODE
  //
  // true  = Skip Gemini completely and use local hardcoded clues.
  // false = Use the real Gemini flow:
  //         CP1 = 1 request, CP2 + CP3 = 1 batch request.
  // ============================================================

  static const bool _debugUseMockClues = bool.fromEnvironment(
    'USE_MOCK_CLUES',
    defaultValue: false,
  );

  // Real Google Places checkpoints are used by default.
  //
  // For emergency offline UI testing only:
  //
  // flutter run --dart-define=USE_LOCAL_CHECKPOINTS=true
  static const bool _debugUseLocalCheckpoints =
  bool.fromEnvironment(
    'USE_LOCAL_CHECKPOINTS',
    defaultValue: false,
  );

  final GeminiService geminiService;

  // Navigation logic is now separated into another file.
  final TripPathQuestNavigation navigation;

  // GPS -> Google Places -> real checkpoints.
  final AttractionRepository attractionRepository;

  // Optional Supabase cache.
  //
  // null:
  // existing Places + Gemini flow still works.
  //
  // non-null:
  // Supabase HIT -> reuse clues.
  // Supabase MISS -> Gemini -> save clues.
  final LandmarkClueRepository? landmarkClueRepository;

  // Completed landmarks for this user.
  //
  // Used to make sure previously verified places are not
  // recommended again in a future quest.
  final UserLandmarkVisitRepository?
  userLandmarkVisitRepository;

  // Supabase artwork catalogue.
  //
  // The selected artwork ID is persisted with the quest so a
  // resumed game always restores the same image.
  final ThemeArtworkRepository?
  themeArtworkRepository;

  // Supabase save/resume repository.
  final TripPathQuestProgressRepository?
  questProgressRepository;

  /// Places already claimed via Puzzle or another Trip Path quest for this
  /// account — merged into every nearby-checkpoint search's excludedPlaceIds
  /// alongside the existing visited-landmark sources. Optional so this
  /// viewmodel stays constructible without it (treated as "nothing claimed").
  final ClaimedPlacesRepository? claimedPlacesRepository;

  /// Reports the finished quest to Manage Rewards (UC-06 A7) so it appears
  /// on the Reward Dashboard as a claimable Theme Souvenir. Optional so this
  /// viewmodel stays constructible standalone (e.g. in tests) without it —
  /// Trip Path's own progress (theme_artworks / trip_path_quests) is saved
  /// either way; this only adds the Reward-side record on top.
  final RewardRepository? rewardRepository;

  // Same-session protection.
  //
  // A place is added here immediately when the checkpoint is
  // completed, so it cannot be selected again even if the
  // Supabase write is still finishing in the background.
  final Set<String> _sessionVisitedPlaceIds =
  <String>{};

  // An artwork is added here the moment selectForNewQuest() picks it —
  // before checkpoint 1's search/reference-photo screening even starts, and
  // well before createQuest() (which requires CP1 to already be
  // reference-ready) inserts a real trip_path_quests row. If the tourist
  // leaves, or CP1 preparation fails, in that window, no row ever exists
  // for that pick, so the database-only exclusion in selectForNewQuest()
  // has nothing to exclude it by. Tracking it here too closes that gap for
  // the rest of this app session — restarting the theme won't hand back the
  // exact artwork just abandoned, purely by chance.
  final Set<String> _sessionReservedArtworkIds =
  <String>{};

  TripPathQuestViewModel({
    required this.geminiService,
    required this.navigation,
    required this.attractionRepository,
    this.landmarkClueRepository,
    this.userLandmarkVisitRepository,
    this.themeArtworkRepository,
    this.questProgressRepository,
    this.claimedPlacesRepository,
    this.rewardRepository,
  }) {
    navigation.addListener(
      _onNavigationChanged,
    );

    // Supabase.initialize() restores the auth session before this
    // ViewModel is created. Check once for an unfinished quest so
    // the Figma-style Continue Previous Game sheet can be shown.
    unawaited(
      checkForSavedQuest(),
    );
  }

  // ============================================================
  // THEMES
  // ============================================================

  final List<QuestThemeData> availableThemes = const [
    QuestThemeData(
      id: 'food',
      name: 'Food',
      area: 'Nearby Area',
    ),
    QuestThemeData(
      id: 'culture',
      name: 'Culture',
      area: 'Nearby Area',
    ),
    QuestThemeData(
      id: 'heritage',
      name: 'Heritage',
      area: 'Nearby Area',
    ),
    QuestThemeData(
      id: 'nature',
      name: 'Nature',
      area: 'Nearby Area',
    ),
  ];

  // ============================================================
  // TEMPORARY ATTRACTIONS
  //
  // ONLY for development/testing.
  //
  // Google Places will replace these later.
  // ============================================================

  final Map<String, List<TemporaryQuestAttraction>>
  _temporaryAttractions = const {
    // ==========================================================
    // FOOD
    // ==========================================================

    'food': [
      TemporaryQuestAttraction(
        name: 'Jalan Alor Food Street',
        address: 'Jalan Alor, Bukit Bintang, Kuala Lumpur',
        generalArea: 'Bukit Bintang',
        placeType: 'Food street',
        latitude: 3.14569,
        longitude: 101.70867,
        verifiedFacts: [
          'It is an outdoor street with many food stalls and restaurants.',
          'Visitors come here to explore different local food choices.',
          'The dining area stretches along one street lined with food stalls and restaurants.',
        ],
      ),
      TemporaryQuestAttraction(
        name: 'ICC Pudu',
        address: 'Jalan Kijang, Pudu, Kuala Lumpur',
        generalArea: 'Pudu',
        placeType: 'Indoor food centre',
        latitude: 3.13807,
        longitude: 101.71436,
        verifiedFacts: [
          'Many local food stalls are located inside one indoor food centre.',
          'Visitors come here to try Malaysian hawker food.',
          'The food stalls are grouped inside one market complex rather than spread along an outdoor street.',
        ],
      ),
      TemporaryQuestAttraction(
        name: 'Taman Connaught Night Market',
        address: 'Jalan Cerdas, Taman Connaught, Kuala Lumpur',
        generalArea: 'Taman Connaught',
        placeType: 'Night market',
        latitude: 3.08161,
        longitude: 101.73709,
        verifiedFacts: [
          'It is an outdoor market containing many stalls.',
          'Visitors explore the market for street food and other goods.',
          'Food and non-food stalls form one long outdoor night-market layout.',
        ],
      ),
    ],

    // ==========================================================
    // CULTURE
    // ==========================================================

    'culture': [
      TemporaryQuestAttraction(
        name: 'Central Market',
        address: 'Jalan Hang Kasturi, Kuala Lumpur',
        generalArea: 'Pasar Seni',
        placeType: 'Arts and cultural market',
        latitude: 3.14572,
        longitude: 101.69546,
        verifiedFacts: [
          'The market contains Malaysian arts, crafts and souvenirs.',
          'Visitors explore cultural and creative products inside the market.',
          'Arts, crafts and souvenir stalls are gathered inside one market building.',
        ],
      ),
      TemporaryQuestAttraction(
        name: 'Kwai Chai Hong',
        address: 'Lorong Panggung, Kuala Lumpur',
        generalArea: 'Kuala Lumpur Chinatown',
        placeType: 'Cultural alley',
        latitude: 3.14160,
        longitude: 101.69768,
        verifiedFacts: [
          'The location is a restored alley with visible murals.',
          'Visitors walk through the alley to view its cultural artwork.',
          'The restored alley combines murals with traditional shophouse surroundings.',
        ],
      ),
      TemporaryQuestAttraction(
        name: 'Zhongshan Building',
        address: 'Jalan Kampung Attap, Kuala Lumpur',
        generalArea: 'Kampung Attap',
        placeType: 'Creative arts hub',
        latitude: 3.137869,
        longitude: 101.696847,
        verifiedFacts: [
          'Independent creative and arts spaces operate inside the building.',
          'Visitors explore small galleries and creative businesses inside.',
          'Multiple independent creative spaces share the same building.',
        ],
      ),
    ],

    // ==========================================================
    // HERITAGE
    // ==========================================================

    'heritage': [
      TemporaryQuestAttraction(
        name: 'Sultan Abdul Samad Building',
        address: 'Jalan Raja, Kuala Lumpur',
        generalArea: 'Merdeka Square area',
        placeType: 'Historic government building',
        latitude: 3.14827,
        longitude: 101.69454,
        verifiedFacts: [
          'A prominent clock tower is one of the most recognizable physical features.',
          'Visitors observe the historic architecture around the Merdeka Square area.',
          'The clock-tower building directly faces the Merdeka Square area.',
        ],
      ),
      TemporaryQuestAttraction(
        name: 'Sin Sze Si Ya Temple',
        address: 'Lebuh Pudu, Kuala Lumpur',
        generalArea: 'Kuala Lumpur Chinatown',
        placeType: 'Historic Chinese temple',
        latitude: 3.14565,
        longitude: 101.69639,
        verifiedFacts: [
          'Traditional Chinese temple features are visible at the site.',
          'Visitors experience a historic religious place within Chinatown.',
          'The historic temple is positioned within the dense Chinatown surroundings.',
        ],
      ),
      TemporaryQuestAttraction(
        name: 'Old High Court Building',
        address: 'Jalan Raja, Kuala Lumpur',
        generalArea: 'Merdeka Square area',
        placeType: 'Historic civic building',
        latitude: 3.15059,
        longitude: 101.69517,
        verifiedFacts: [
          'The exterior contains distinctive historic architectural features.',
          'Visitors explore the surrounding heritage area on foot.',
          'The civic building forms part of the historic building cluster around Merdeka Square.',
        ],
      ),
    ],

    // ==========================================================
    // NATURE
    // ==========================================================

    'nature': [
      TemporaryQuestAttraction(
        name: 'Taman Tasik Danau Kota',
        address: 'Danau Kota, Kuala Lumpur',
        generalArea: 'Danau Kota',
        placeType: 'Recreational lake park',
        latitude: 3.20432,
        longitude: 101.71875,
        verifiedFacts: [
          'A lake is the central physical feature of the recreational area.',
          'Visitors use paths around the area for walking and jogging.',
          'The recreational space is organised around the central lake rather than being only an open neighbourhood field.',
        ],
      ),
      TemporaryQuestAttraction(
        name: 'Bukit Dinding',
        address: 'Wangsa Maju, Kuala Lumpur',
        generalArea: 'Wangsa Maju',
        placeType: 'Forested hiking hill',
        latitude: 3.19010,
        longitude: 101.75096,
        verifiedFacts: [
          'The attraction is a forested hill with elevated terrain.',
          'Visitors use trails in the area for hiking.',
          'The elevated forested terrain rises within the surrounding urban Wangsa Maju area.',
        ],
      ),
      TemporaryQuestAttraction(
        name: 'Taman Tasik Titiwangsa',
        address: 'Titiwangsa, Kuala Lumpur',
        generalArea: 'Titiwangsa',
        placeType: 'Urban lake park',
        latitude: 3.17783,
        longitude: 101.70692,
        verifiedFacts: [
          'A large lake is a major physical feature of the park.',
          'Visitors use the park for walking and jogging.',
          'The large open lake park sits within a highly urban city environment.',
        ],
      ),
    ],
  };

  // ============================================================
  // REAL QUEST ATTRACTIONS
  //
  // Filled from:
  //
  // Phone GPS
  // -> AttractionRepository
  // -> Google Places API (New)
  // -> 3 selected checkpoints
  // ============================================================

  List<TemporaryQuestAttraction> _questAttractions =
  const [];

  bool _isPreparingQuestLocations = false;

  String? _questLocationError;

  // User-facing progress text (radius tier / candidate being checked) shown
  // while a checkpoint search is running, so "Preparing your quest..." isn't
  // a single static message for however long the search actually takes.
  String? _questPreparationStatus;

  // CP1 is allowed to start as soon as it is reference-ready.
  // CP2/CP3 continue preparing in the background and are appended
  // only after their own reference photos have passed screening.
  bool _isPreparingRemainingCheckpoints = false;
  String? _remainingCheckpointPreparationError;

  double? _pendingBackgroundSearchLatitude;
  double? _pendingBackgroundSearchLongitude;

  bool get isPreparingQuestLocations =>
      _isPreparingQuestLocations;

  String? get questLocationError =>
      _questLocationError;

  String? get questPreparationStatus =>
      _questPreparationStatus;

  void _setQuestPreparationStatus(String message) {
    if (_questPreparationStatus == message) return;
    _questPreparationStatus = message;
    notifyListeners();
  }

  bool get isPreparingRemainingCheckpoints =>
      _isPreparingRemainingCheckpoints;

  String? get remainingCheckpointPreparationError =>
      _remainingCheckpointPreparationError;

  bool get hasPreparedQuestLocations =>
      _questAttractions.isNotEmpty;

  bool get areAllQuestCheckpointsPrepared =>
      _questAttractions.length >= totalCheckpoints;

  bool get isCurrentCheckpointReady {
    final attraction = currentAttraction;

    if (_debugUseLocalCheckpoints) {
      return attraction != null;
    }

    return attraction?.referencePhotoBytes != null &&
        attraction!.referencePhotoBytes!.isNotEmpty;
  }

  List<TemporaryQuestAttraction>
  get preparedQuestAttractions =>
      List.unmodifiable(
        _questAttractions,
      );

  // ============================================================
  // QUEST STATE
  // ============================================================

  TripPathQuestStage _currentStage =
      TripPathQuestStage.themeSelection;

  QuestThemeData? _selectedTheme;

  int _currentCheckpoint = 1;

  int _completedCheckpoints = 0;

  // ============================================================
  // SAVED QUEST / ARTWORK STATE
  // ============================================================

  String? _activeQuestId;

  ThemeArtworkData? _selectedArtwork;

  // All unfinished games for this user, ordered by last played time.
  List<SavedTripPathQuest> _savedQuests = const <SavedTripPathQuest>[];

  // The exact saved quest currently selected for resume.
  SavedTripPathQuest? _savedQuest;

  bool _isCheckingSavedQuest = false;

  bool _showResumePrompt = false;

  bool _isResumingQuest = false;

  bool _isSavingAndExiting = false;

  // Completion is deliberately held in the verification stage until the
  // Supabase write has been confirmed. This prevents a slow/failed request
  // from showing a locally completed artwork that later reappears as 2/3.
  bool _isCompletingCheckpoint = false;

  String? _completionError;

  String? _resumeGameError;

  bool _isPreparingCurrentReferencePhoto = false;

  String? _referencePreparationError;

  // ============================================================
  // GEMINI CLUE STORAGE
  // ============================================================

  final Map<int, List<String>> _checkpointClues = {};

  final Map<int, String> _checkpointClueErrors = {};

  final Map<int, int> _generatingCheckpointVersions = {};

  int _generationVersion = 0;

  final Map<int, int> _revealedClueCounts = {};

  final Map<int, int> _viewingClueIndexes = {};

  // ============================================================
  // BASIC GETTERS
  // ============================================================

  TripPathQuestStage get currentStage => _currentStage;

  QuestThemeData? get selectedTheme => _selectedTheme;

  int get currentCheckpoint => _currentCheckpoint;

  int get completedCheckpoints => _completedCheckpoints;

  int get totalCheckpoints => 3;

  bool get isQuestCompleted =>
      _completedCheckpoints >= totalCheckpoints;

  bool get isFinalCheckpoint =>
      _currentCheckpoint >= totalCheckpoints;

  ThemeArtworkData? get selectedArtwork =>
      _selectedArtwork;

  String? get artworkImageUrl =>
      _selectedArtwork?.imageUrl;

  String get artworkTitle =>
      _selectedArtwork?.title ?? 'Quest Artwork';

  bool get hasSelectedArtwork =>
      _selectedArtwork != null;

  String? get activeQuestId =>
      _activeQuestId;

  bool get isCheckingSavedQuest =>
      _isCheckingSavedQuest;

  bool get showResumePrompt =>
      _showResumePrompt && _savedQuests.isNotEmpty;

  bool get isResumingQuest =>
      _isResumingQuest;

  bool get isSavingAndExiting =>
      _isSavingAndExiting;

  bool get isCompletingCheckpoint =>
      _isCompletingCheckpoint;

  String? get completionError =>
      _completionError;

  void clearCompletionError() {
    if (_completionError == null) {
      return;
    }

    _completionError = null;
    notifyListeners();
  }

  String? get resumeGameError =>
      _resumeGameError;

  List<SavedTripPathQuest> get savedQuests =>
      List.unmodifiable(_savedQuests);

  SavedTripPathQuest? get savedQuest =>
      _savedQuest ??
          (_savedQuests.isEmpty ? null : _savedQuests.first);

  String get savedQuestThemeName =>
      savedQuest?.themeName ?? '';

  int get savedQuestCompletedCheckpoints =>
      savedQuest?.completedCheckpoints ?? 0;

  int get savedQuestCurrentCheckpoint =>
      savedQuest?.currentCheckpoint ?? 1;

  String get savedQuestLastPlayedText =>
      savedQuestLastPlayedTextFor(savedQuest);

  String savedQuestLastPlayedTextFor(
      SavedTripPathQuest? quest,
      ) {
    final value = quest?.lastPlayedAt;

    if (value == null) {
      return 'Recently';
    }

    final now = DateTime.now();
    final difference = now.difference(value);

    if (difference.inMinutes < 1) {
      return 'Just now';
    }

    if (difference.inHours < 1) {
      return '${difference.inMinutes} min ago';
    }

    if (difference.inDays < 1) {
      return '${difference.inHours} hr ago';
    }

    if (difference.inDays == 1) {
      return 'Yesterday';
    }

    return '${value.day.toString().padLeft(2, '0')}/'
        '${value.month.toString().padLeft(2, '0')}/'
        '${value.year}';
  }

  bool get isPreparingCurrentReferencePhoto =>
      _isPreparingCurrentReferencePhoto;

  String? get referencePreparationError =>
      _referencePreparationError;

  // ============================================================
  // CURRENT ATTRACTION
  // ============================================================

  TemporaryQuestAttraction? get currentAttraction {
    final theme = _selectedTheme;

    if (theme == null) {
      return null;
    }

    final attractions =
    _activeAttractionsForTheme(
      theme.id,
    );

    if (attractions == null ||
        attractions.isEmpty) {
      return null;
    }

    final index =
        _currentCheckpoint - 1;

    if (index < 0 ||
        index >= attractions.length) {
      return null;
    }

    return attractions[index];
  }

  List<TemporaryQuestAttraction>?
  _activeAttractionsForTheme(
      String themeId,
      ) {
    // Real quests may intentionally contain only CP1 for a short time
    // while CP2/CP3 are prepared in the background.
    if (_questAttractions.isNotEmpty) {
      return _questAttractions;
    }

    if (_debugUseLocalCheckpoints) {
      return _temporaryAttractions[
      themeId];
    }

    return null;
  }

  // ============================================================
  // CLUE GETTERS
  // ============================================================

  List<String> get _currentPreparedClues {
    return _checkpointClues[_currentCheckpoint] ?? const [];
  }

  bool get areCluesPrepared =>
      _currentPreparedClues.length == 3;

  bool get isGeneratingClue {
    return _generatingCheckpointVersions[_currentCheckpoint] ==
        _generationVersion;
  }

  String? get clueGenerationError {
    return _checkpointClueErrors[_currentCheckpoint];
  }

  int get cluesUsed =>
      _revealedClueCounts[_currentCheckpoint] ?? 0;

  int get cluesRemaining => 3 - cluesUsed;

  int get currentClueIndex {
    final revealed = cluesUsed;

    if (revealed <= 0) {
      return 0;
    }

    final stored =
        _viewingClueIndexes[_currentCheckpoint] ??
            (revealed - 1);

    if (stored < 0) {
      return 0;
    }

    if (stored >= revealed) {
      return revealed - 1;
    }

    return stored;
  }

  bool get hasGeneratedClue {
    return areCluesPrepared && cluesUsed > 0;
  }

  String get currentClue {
    if (!areCluesPrepared || cluesUsed <= 0) {
      return '';
    }

    return _currentPreparedClues[currentClueIndex];
  }

  String get currentClueTypeLabel {
    const labels = [
      'Appearance',
      'Experience',
      'Unique Identifier',
    ];

    return labels[currentClueIndex];
  }

  bool get canRequestAnotherClue {
    return areCluesPrepared &&
        !isGeneratingClue &&
        cluesUsed > 0 &&
        cluesUsed < 3;
  }

  List<String> get generatedClues {
    if (!areCluesPrepared || cluesUsed <= 0) {
      return const [];
    }

    return List.unmodifiable(
      _currentPreparedClues.take(
        cluesUsed,
      ),
    );
  }

  bool canViewClue(
      int index,
      ) {
    return index >= 0 && index < cluesUsed;
  }

  void viewClue(
      int index,
      ) {
    if (!canViewClue(index)) {
      return;
    }

    _viewingClueIndexes[_currentCheckpoint] = index;

    notifyListeners();
  }

  bool isCheckpointPrepared(
      int checkpoint,
      ) {
    return _checkpointClues[checkpoint]?.length == 3;
  }

  bool isCheckpointGenerating(
      int checkpoint,
      ) {
    return _generatingCheckpointVersions[checkpoint] ==
        _generationVersion;
  }

  // ============================================================
  // NAVIGATION GETTERS
  // ============================================================

  // Prevent a distance/bearing from a previous checkpoint from
  // being displayed for the current checkpoint.
  bool get _navigationTargetsCurrentCheckpoint {
    final attraction =
        currentAttraction;

    final targetLat =
        navigation.targetLatitude;

    final targetLng =
        navigation.targetLongitude;

    if (attraction == null ||
        targetLat == null ||
        targetLng == null) {
      return false;
    }

    const tolerance = 0.000001;

    return (targetLat -
        attraction.latitude)
        .abs() <=
        tolerance &&
        (targetLng -
            attraction.longitude)
            .abs() <=
            tolerance;
  }

  bool get isStartingNavigation =>
      _navigationTargetsCurrentCheckpoint &&
          navigation.isLoading;

  bool get isNavigationTracking =>
      _navigationTargetsCurrentCheckpoint &&
          navigation.isTracking;

  bool get isRefreshingLocation =>
      _navigationTargetsCurrentCheckpoint &&
          navigation.isRefreshingLocation;

  String? get navigationError =>
      _navigationTargetsCurrentCheckpoint
          ? navigation.errorMessage
          : null;

  double? get distanceToCheckpointMeters =>
      _navigationTargetsCurrentCheckpoint
          ? navigation.distanceMeters
          : null;

  double? get bearingToCheckpoint =>
      _navigationTargetsCurrentCheckpoint
          ? navigation.bearingDegrees
          : null;

  String get distanceText =>
      _navigationTargetsCurrentCheckpoint
          ? navigation.distanceText
          : 'Calculating distance...';

  String get directionText =>
      _navigationTargetsCurrentCheckpoint
          ? navigation.directionText
          : 'Finding direction...';

  String get locationAccuracyText =>
      _navigationTargetsCurrentCheckpoint
          ? navigation.accuracyText
          : 'GPS accuracy unavailable';

  bool get hasCurrentLocation =>
      _navigationTargetsCurrentCheckpoint &&
          navigation.hasCurrentLocation;

  double? get currentLatitude =>
      _navigationTargetsCurrentCheckpoint
          ? navigation.currentLocation?.latitude
          : null;

  double? get currentLongitude =>
      _navigationTargetsCurrentCheckpoint
          ? navigation.currentLocation?.longitude
          : null;

  double? get checkpointLatitude =>
      currentAttraction?.latitude;

  double? get checkpointLongitude =>
      currentAttraction?.longitude;

  // ============================================================
  // UC-05:
  // Verify Visit unlocks within 50 metres.
  //
  // It is only valid when Navigation's active target is the
  // CURRENT checkpoint.
  // ============================================================

  bool get canVerifyVisit =>
      _navigationTargetsCurrentCheckpoint &&
          navigation.canVerifyVisit;

  // ============================================================
  // NAVIGATION → VIEWMODEL UPDATE
  // ============================================================

  void _onNavigationChanged() {
    notifyListeners();
  }


  // ============================================================
  // SAVED GAME / CONTINUE PREVIOUS GAME
  // ============================================================

  Future<void>? _savedQuestCheckFuture;

  Future<void> checkForSavedQuest() {
    return _savedQuestCheckFuture ??= _checkForSavedQuest().whenComplete(() {
      _savedQuestCheckFuture = null;
    });
  }

  Future<void> _checkForSavedQuest() async {
    final repository = questProgressRepository;

    if (repository == null ||
        !repository.hasAuthenticatedUser) {
      _savedQuests = const <SavedTripPathQuest>[];
      _savedQuest = null;
      _showResumePrompt = false;
      return;
    }

    if (_isCheckingSavedQuest) {
      return;
    }

    _isCheckingSavedQuest = true;
    _resumeGameError = null;

    notifyListeners();

    try {
      final saved = await repository.getActiveQuests();

      _savedQuests = List.unmodifiable(saved);
      _savedQuest = saved.isEmpty ? null : saved.first;

      if (saved.isNotEmpty &&
          _currentStage == TripPathQuestStage.themeSelection &&
          _activeQuestId == null) {
        _showResumePrompt = true;
      } else if (saved.isEmpty) {
        _showResumePrompt = false;
      }
    } catch (error) {
      _resumeGameError =
      'Unable to check saved quest progress.';

      debugPrint(
        '[QUEST PROGRESS] Resume lookup failed: $error',
      );
    } finally {
      _isCheckingSavedQuest = false;
      notifyListeners();
    }
  }

  void dismissSavedQuestPrompt() {
    _showResumePrompt = false;
    _savedQuest = null;
    notifyListeners();
  }

  /// Opens the exact quest selected in Game & Place History. This avoids the
  /// normal resume screen choosing a different, more recently played quest.
  Future<void> continueQuestById(String questId) async {
    // History can open while the constructor is still checking saved games.
    // Wait for that check instead of discarding the selected quest request.
    final pendingCheck = _savedQuestCheckFuture;
    if (pendingCheck != null) {
      await pendingCheck;
    }
    final repository = questProgressRepository;
    if (repository == null || _isCheckingSavedQuest || _isResumingQuest) {
      return;
    }

    _isCheckingSavedQuest = true;
    _resumeGameError = null;
    notifyListeners();

    try {
      final saved = await repository.getActiveQuestById(questId);
      if (saved == null) {
        _resumeGameError = 'This saved quest is no longer available.';
        return;
      }

      // Keep the loading page visible through restoration of this quest.
      await continuePreviousGame(saved);
    } catch (error) {
      _resumeGameError = 'Unable to load this saved quest.';
      debugPrint('[QUEST PROGRESS] Exact resume lookup failed: $error');
    } finally {
      _isCheckingSavedQuest = false;
      notifyListeners();
    }

  }

  // "Start New Quest" keeps every existing unfinished game. It only
  // closes the Continue screen and reveals Theme Selection.
  Future<void> startNewGameFromSavedQuest() async {
    unawaited(
      navigation.stop(),
    );

    _generationVersion++;
    _selectedTheme = null;
    _selectedArtwork = null;
    _activeQuestId = null;
    _savedQuest = null;
    _showResumePrompt = false;
    _resumeGameError = null;
    _completionError = null;
    _currentCheckpoint = 1;
    _completedCheckpoints = 0;
    _questAttractions = const [];
    _questLocationError = null;
    _isPreparingQuestLocations = false;
    _isPreparingRemainingCheckpoints = false;
    _remainingCheckpointPreparationError = null;
    _pendingBackgroundSearchLatitude = null;
    _pendingBackgroundSearchLongitude = null;
    _referencePreparationError = null;
    _clearAllClues();
    _currentStage = TripPathQuestStage.themeSelection;

    notifyListeners();
  }

  Future<void> continuePreviousGame([
    SavedTripPathQuest? selectedQuest
  ]) async {
    final repository =
        questProgressRepository;

    if (repository == null ||
        _isResumingQuest) {
      return;
    }

    _isResumingQuest = true;
    _resumeGameError = null;
    _completionError = null;
    notifyListeners();

    try {
      final candidate = selectedQuest ??
          _savedQuest ??
          (_savedQuests.isEmpty ? null : _savedQuests.first);

      if (candidate == null) {
        _showResumePrompt = false;
        _savedQuest = null;
        return;
      }

      final saved =
      await repository.getActiveQuestById(candidate.id);

      if (saved == null) {
        _savedQuests = List.unmodifiable(
          _savedQuests
              .where((quest) => quest.id != candidate.id)
              .toList(growable: false),
        );
        _savedQuest = _savedQuests.isEmpty
            ? null
            : _savedQuests.first;
        _showResumePrompt = _savedQuests.isNotEmpty;
        _resumeGameError =
        'This saved quest is no longer available.';
        return;
      }

      _savedQuest = saved;

      final restoredTheme =
      availableThemes.firstWhere(
            (theme) => theme.id == saved.themeId,
        orElse: () => QuestThemeData(
          id: saved.themeId,
          name: saved.themeName,
          area: 'Nearby Area',
        ),
      );

      ThemeArtworkData? restoredArtwork;

      final savedArtworkId =
      saved.artworkId?.trim();

      if (savedArtworkId != null &&
          savedArtworkId.isNotEmpty &&
          themeArtworkRepository != null) {
        restoredArtwork =
        await themeArtworkRepository!
            .getById(savedArtworkId);
      }

      final restoredAttractions =
      saved.checkpoints
          .map(
            (checkpoint) =>
            TemporaryQuestAttraction(
              name: checkpoint.landmarkName,
              address: checkpoint.address,
              generalArea: checkpoint.generalArea,
              placeType: checkpoint.primaryType,
              latitude: checkpoint.latitude,
              longitude: checkpoint.longitude,
              verifiedFacts:
              checkpoint.verifiedFacts,
              placeId: checkpoint.googlePlaceId,
              referenceFingerprint: checkpoint.referenceFingerprint,
              referenceKind: checkpoint.referenceKind,
              referencePhotoWidth: checkpoint.referenceWidth,
              referencePhotoHeight: checkpoint.referenceHeight,
            ),
      )
          .toList(growable: false);

      if (restoredAttractions.isEmpty ||
          restoredAttractions.length > totalCheckpoints) {
        throw StateError(
          'Saved quest does not contain a valid prepared checkpoint.',
        );
      }

      unawaited(
        navigation.stop(),
      );

      _generationVersion++;
      _clearAllClues();

      _selectedTheme = restoredTheme;
      _selectedArtwork = restoredArtwork;
      _precacheArtworkImage(restoredArtwork?.imageUrl);
      _activeQuestId = saved.id;
      _questAttractions =
          List.unmodifiable(restoredAttractions);
      _currentCheckpoint =
          saved.currentCheckpoint.clamp(1, totalCheckpoints).toInt();
      _completedCheckpoints =
          saved.completedCheckpoints.clamp(0, totalCheckpoints).toInt();
      _questLocationError = null;
      _isPreparingQuestLocations = false;
      _isPreparingRemainingCheckpoints = false;
      _remainingCheckpointPreparationError = null;
      _pendingBackgroundSearchLatitude = null;
      _pendingBackgroundSearchLongitude = null;
      _referencePreparationError = null;

      for (final checkpoint in saved.checkpoints) {
        if (checkpoint.clues.length == 3 &&
            !_cluesContainForbiddenDatabaseMetadata(checkpoint.clues)) {
          _checkpointClues[
          checkpoint.checkpointNumber] =
              List.unmodifiable(checkpoint.clues);
        } else if (checkpoint.clues.length == 3) {
          debugPrint(
            '[QUEST RESUME] CP${checkpoint.checkpointNumber} '
                'contains old metadata-style clues -> regenerate.',
          );
        }
      }

      final resumeVersion =
          _generationVersion;

      // A quest may have been saved while CP2/CP3 were still preparing.
      // If the player's CURRENT checkpoint has not been locked yet, wait
      // only until that checkpoint finishes. The remaining checkpoints can
      // continue in the background after the screen is visible.
      if (_currentCheckpoint > _questAttractions.length) {
        await _prepareRemainingQuestCheckpointsInBackground(
          version: resumeVersion,
          untilCheckpoint: _currentCheckpoint,
        );

        if (_currentCheckpoint > _questAttractions.length ||
            currentAttraction == null) {
          throw StateError(
            'The current saved checkpoint could not be prepared yet.',
          );
        }
      }

      // A resumed quest loses in-memory photo bytes when the process ends.
      // Restore only the CURRENT checkpoint before showing the quest. The
      // old implementation screened every incomplete checkpoint here, which
      // made Continue wait for several Places/photo/OpenCV requests even
      // though the player could only use one checkpoint at a time.
      final currentReferenceIndex =
      (_currentCheckpoint - 1)
          .clamp(0, _questAttractions.length - 1)
          .toInt();
      final currentReferenceReady =
      await _ensureResumedQuestReferencesReady(
        startIndex: currentReferenceIndex,
        endIndexInclusive: currentReferenceIndex,
        expectedGenerationVersion: resumeVersion,
      );

      if (!currentReferenceReady) {
        throw StateError(
          'The current saved checkpoint could not be prepared safely.',
        );
      }

      _currentStage =
          TripPathQuestStage.artworkIntro;
      _savedQuest = saved;
      _showResumePrompt = false;

      notifyListeners();

      await repository.touchQuest(saved.id);

      final clueVersion =
          _generationVersion;

      // Fill only missing clue sets. Already-saved clue sets are
      // skipped by the existing clue preparation methods.
      unawaited(
        _prepareQuestCluesPrioritized(
          clueVersion,
        ),
      );

      // If CP1 is the current checkpoint, let the player continue now
      // while any missing CP2/CP3 checkpoints prepare in the background.
      if (_questAttractions.length < totalCheckpoints) {
        unawaited(
          _prepareRemainingQuestCheckpointsInBackground(
            version: clueVersion,
          ),
        );
      }

      // Restore reference photos for later saved checkpoints without
      // blocking the Continue transition. If a saved place has become
      // unusable, this background pass still replaces it using the same
      // strict reference-ready rules before the player reaches it.
      if (_questAttractions.length > currentReferenceIndex + 1) {
        unawaited(
          _prepareRemainingResumedReferencesInBackground(
            version: clueVersion,
            startIndex: currentReferenceIndex + 1,
          ),
        );
      }

      debugPrint(
        '[QUEST PROGRESS] CONTINUED ${saved.themeName} '
            '${saved.completedCheckpoints}/${saved.totalCheckpoints} '
            'at CP${saved.currentCheckpoint}.',
      );
    } catch (error) {
      _resumeGameError =
          _friendlyResumeError(error);

      debugPrint(
        '[QUEST PROGRESS] Continue failed: $error',
      );
    } finally {
      _isResumingQuest = false;
      notifyListeners();
    }
  }

  // ============================================================
  // SAVED CHECKPOINT REFERENCE PHOTO
  //
  // Google photo resource names are intentionally NOT stored in
  // Supabase. When a saved quest reaches verification, obtain a
  // fresh photos[] list for the same Google Place ID and run the
  // existing request-saving automatic screening again.
  // ============================================================

  Future<bool>
  prepareCurrentReferencePhotoIfNeeded() async {
    final attraction =
        currentAttraction;

    if (attraction == null) {
      return false;
    }

    if (attraction.referencePhotoBytes != null &&
        attraction.referencePhotoBytes!.isNotEmpty) {
      return true;
    }

    if (_isPreparingCurrentReferencePhoto) {
      return false;
    }

    final placeId =
    attraction.placeId?.trim();

    if (placeId == null ||
        placeId.isEmpty) {
      _referencePreparationError =
      'This checkpoint cannot be verified. '
          'Please return to the quest and try again.';
      notifyListeners();
      return false;
    }

    _isPreparingCurrentReferencePhoto = true;
    _referencePreparationError = null;
    notifyListeners();

    try {
      final placeDetails =
      await attractionRepository
          .googleMapsPlatformService
          .getPlaceCheckpointData(
        placeId: placeId,
      );

      if (!placeDetails.isOperational ||
          placeDetails.isExplicitlyClosedNow) {
        throw StateError(
          'The saved checkpoint is not open now.',
        );
      }

      final candidates =
          placeDetails.photos;

      if (candidates.isEmpty) {
        throw StateError(
          'No reference photo candidates are available.',
        );
      }

      final themeId =
          _selectedTheme?.id;

      if (themeId == null ||
          themeId.trim().isEmpty) {
        throw StateError(
          'The saved quest has no theme for reference-photo validation.',
        );
      }

      final selection =
      await attractionRepository
          .referencePhotoService
          .selectBest(
        placeName: attraction.name,
        themeId: themeId,
        candidates: candidates,
        preferredFingerprint: attraction.referenceFingerprint,
      );

      if (selection == null) {
        throw StateError(
          'No suitable reference photo passed automatic screening.',
        );
      }

      final index =
          _currentCheckpoint - 1;

      if (index < 0 ||
          index >= _questAttractions.length) {
        return false;
      }

      final updated =
      attraction.withReferencePhoto(
        selection.bytes,
        score: selection.totalScore,
        width: selection.width,
        height: selection.height,
        keypoints: selection.keypoints,
        coverage: selection.featureCoverage,
        sharpness: selection.sharpnessVariance,
        semanticScore: selection.semanticScore,
        ocrNameMatched: selection.ocrNameMatched,
        semanticLabels: List.unmodifiable(selection.semanticLabels),
        suitabilityTier: selection.suitabilityTier,
        kind: selection.referenceKind,
        suitabilityScore: selection.suitabilityScore,
        fingerprint: selection.referenceFingerprint,
      );

      final mutable =
      List<TemporaryQuestAttraction>.from(
        _questAttractions,
      );

      mutable[index] = updated;
      _questAttractions =
          List.unmodifiable(mutable);

      final activeQuestId = _activeQuestId?.trim();
      if (activeQuestId != null &&
          activeQuestId.isNotEmpty &&
          questProgressRepository != null &&
          selection.referenceFingerprint.isNotEmpty) {
        await questProgressRepository!.saveCheckpointReferenceFingerprint(
          questId: activeQuestId,
          checkpointNumber: _currentCheckpoint,
          fingerprint: selection.referenceFingerprint,
          referenceKind: selection.referenceKind,
          width: selection.width,
          height: selection.height,
        );
      }

      debugPrint(
        '[REFERENCE PHOTO] Resumed CP$_currentCheckpoint '
            'reference prepared for ${updated.name} | '
            'score=${selection.totalScore.toStringAsFixed(1)}',
      );

      return true;
    } catch (error) {
      _referencePreparationError =
          _friendlyReferenceError(error);

      debugPrint(
        '[REFERENCE PHOTO] Resume preparation failed: $error',
      );

      return false;
    } finally {
      _isPreparingCurrentReferencePhoto = false;
      notifyListeners();
    }
  }


  // ============================================================
  // RESUMED QUEST REFERENCE PREFLIGHT
  //
  // New quests already pass reference screening before checkpoints
  // are committed. A resumed quest loses in-memory image bytes after
  // the app process ends. Continue restores the current checkpoint
  // synchronously and runs the same pass for later checkpoints in the
  // background.
  //
  // If the SAME saved place no longer has a reliable reference,
  // replace only that incomplete checkpoint with another place that:
  // - matches the theme
  // - is currently operational / not explicitly closed now
  // - passes hidden-place rules
  // - has a strict semantic + OpenCV reference photo
  // ============================================================

  Future<bool> _ensureResumedQuestReferencesReady({
    int? startIndex,
    int? endIndexInclusive,
    int? expectedGenerationVersion,
  }) async {
    if (_debugUseLocalCheckpoints) {
      return true;
    }

    if (_selectedTheme == null ||
        _activeQuestId == null ||
        _questAttractions.isEmpty) {
      return false;
    }

    final firstIndex =
    (startIndex ?? _completedCheckpoints)
        .clamp(0, _questAttractions.length - 1)
        .toInt();
    final lastIndex =
    (endIndexInclusive ?? _questAttractions.length - 1)
        .clamp(firstIndex, _questAttractions.length - 1)
        .toInt();

    for (var index = firstIndex;
    index <= lastIndex;
    index++) {
      if (expectedGenerationVersion != null &&
          expectedGenerationVersion != _generationVersion) {
        return false;
      }

      // Older saved quests may contain a place that was accepted before the
      // cross-theme identity guard was added. Do not spend photo-analysis
      // time trying to rescue a stale cross-theme or accommodation checkpoint;
      // replace it using the current selected-theme rules.
      final savedAttraction = _questAttractions[index];
      if (!_savedAttractionMatchesSelectedTheme(savedAttraction)) {
        final selectedThemeName =
        _selectedTheme?.name.trim().isNotEmpty == true
            ? _selectedTheme!.name.trim()
            : (_selectedTheme?.id.trim().isNotEmpty == true
            ? _selectedTheme!.id.trim()
            : 'selected');
        debugPrint(
          '[REFERENCE PREFLIGHT] CP${index + 1} '
              'saved place no longer matches the $selectedThemeName theme: '
              '${savedAttraction.name} (${savedAttraction.placeType}).',
        );

        final replaced =
        await _replaceUnavailableCheckpointAtIndex(
          index,
          expectedGenerationVersion: expectedGenerationVersion,
        );

        if (!replaced) {
          return false;
        }

        continue;
      }

      final prepared =
      await _prepareReferenceForCheckpointIndex(
        index,
        expectedGenerationVersion: expectedGenerationVersion,
      );

      if (expectedGenerationVersion != null &&
          expectedGenerationVersion != _generationVersion) {
        return false;
      }

      if (prepared) {
        continue;
      }

      debugPrint(
        '[REFERENCE PREFLIGHT] CP${index + 1} '
            'saved place unavailable -> selecting replacement.',
      );

      final replaced =
      await _replaceUnavailableCheckpointAtIndex(
        index,
        expectedGenerationVersion: expectedGenerationVersion,
      );

      if (!replaced) {
        return false;
      }
    }

    return true;
  }

  bool _savedAttractionMatchesSelectedTheme(
      TemporaryQuestAttraction attraction,
      ) {
    final themeId =
    _selectedTheme?.id.trim().toLowerCase();

    final normalizedType =
    attraction.placeType.trim().toLowerCase();
    final normalizedName =
    attraction.name.trim().toLowerCase();

    final typeLooksLikeAccommodation =
        normalizedType.contains('hotel') ||
            normalizedType.contains('lodging') ||
            normalizedType.contains('hostel') ||
            normalizedType.contains('motel') ||
            normalizedType.contains('resort') ||
            normalizedType.contains('guest house') ||
            normalizedType.contains('guesthouse') ||
            normalizedType.contains('homestay') ||
            normalizedType.contains('inn') ||
            normalizedType.contains('lodge');

    bool nameContainsTerm(String term) {
      final source = normalizedName
          .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
          .trim();
      final phrase = term
          .trim()
          .toLowerCase()
          .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
          .trim();

      if (source.isEmpty || phrase.isEmpty) {
        return false;
      }

      return ' $source '.contains(' $phrase ');
    }

    const accommodationNameTerms = <String>{
      'hotel',
      'resort',
      'motel',
      'hostel',
      'guest house',
      'guesthouse',
      'homestay',
      'lodging',
      'serviced apartment',
      'apartment hotel',
      'inn',
      'lodge',
    };

    final nameLooksLikeAccommodation =
    accommodationNameTerms.any(nameContainsTerm);

    if (typeLooksLikeAccommodation ||
        nameLooksLikeAccommodation) {
      return false;
    }

    bool typeContainsAny(Set<String> terms) {
      return terms.any(
            (term) => normalizedType.contains(term),
      );
    }

    final typeLooksLikeFood = typeContainsAny(const <String>{
      'restaurant',
      'cafe',
      'coffee',
      'bakery',
      'food court',
      'food stall',
    });
    final typeLooksLikeCulture = typeContainsAny(const <String>{
      'cultural',
      'gallery',
      'museum',
      'theatre',
      'theater',
      'performing art',
    });
    final typeLooksLikeHeritage = typeContainsAny(const <String>{
      'historical',
      'history',
      'heritage',
      'monument',
      'memorial',
    });
    final typeLooksLikeNature = typeContainsAny(const <String>{
      'park',
      'garden',
      'hiking',
      'wildlife',
      'botanical',
      'nature',
    });

    // Saved rows retain only the humanized primary type, so re-apply the
    // same cross-theme identity guard on resume. This repairs old quests that
    // were created before secondary Google types were handled strictly.
    switch (themeId) {
      case 'food':
        return !typeLooksLikeCulture &&
            !typeLooksLikeHeritage &&
            !typeLooksLikeNature;
      case 'culture':
        return !typeLooksLikeFood &&
            !typeLooksLikeNature;
      case 'heritage':
        return !typeLooksLikeFood &&
            !typeLooksLikeNature;
      case 'nature':
        return !typeLooksLikeFood &&
            !typeLooksLikeCulture &&
            !typeLooksLikeHeritage;
      default:
        return true;
    }
  }

  Future<void> _prepareRemainingResumedReferencesInBackground({
    required int version,
    required int startIndex,
  }) async {
    if (_debugUseLocalCheckpoints ||
        version != _generationVersion ||
        startIndex >= _questAttractions.length) {
      return;
    }

    final prepared =
    await _ensureResumedQuestReferencesReady(
      startIndex: startIndex,
      expectedGenerationVersion: version,
    );

    if (version != _generationVersion) {
      return;
    }

    if (!prepared) {
      debugPrint(
        '[REFERENCE PREFLIGHT] Later saved checkpoint preparation '
            'will retry when that checkpoint is opened.',
      );
    }

    // The next checkpoint may have received its fresh reference while the
    // player was on the current screen. Rebuild once, after the batch, rather
    // than notifying for every photo candidate.
    notifyListeners();
  }

  Future<bool> _prepareReferenceForCheckpointIndex(
      int index, {
        int? expectedGenerationVersion,
      }) async {
    if (index < 0 ||
        index >= _questAttractions.length) {
      return false;
    }

    if (expectedGenerationVersion != null &&
        expectedGenerationVersion != _generationVersion) {
      return false;
    }

    final attraction =
    _questAttractions[index];

    if (attraction.referencePhotoBytes != null &&
        attraction.referencePhotoBytes!.isNotEmpty) {
      return true;
    }

    final placeId =
    attraction.placeId?.trim();

    final themeId =
    _selectedTheme?.id.trim();

    if (placeId == null ||
        placeId.isEmpty ||
        themeId == null ||
        themeId.isEmpty) {
      return false;
    }

    try {
      final placeDetails =
      await attractionRepository
          .googleMapsPlatformService
          .getPlaceCheckpointData(
        placeId: placeId,
      );

      if (expectedGenerationVersion != null &&
          expectedGenerationVersion != _generationVersion) {
        return false;
      }

      if (!placeDetails.isOperational ||
          placeDetails.isExplicitlyClosedNow) {
        debugPrint(
          '[REFERENCE PREFLIGHT] CP${index + 1} '
              'saved place is closed/unavailable now.',
        );
        return false;
      }

      final candidates =
          placeDetails.photos;

      if (candidates.isEmpty) {
        return false;
      }

      final selection =
      await attractionRepository
          .referencePhotoService
          .selectBest(
        placeName: attraction.name,
        themeId: themeId,
        candidates: candidates,
        preferredFingerprint: attraction.referenceFingerprint,
      );

      if (expectedGenerationVersion != null &&
          expectedGenerationVersion != _generationVersion) {
        return false;
      }

      if (selection == null) {
        return false;
      }

      if (expectedGenerationVersion != null &&
          expectedGenerationVersion != _generationVersion) {
        return false;
      }

      final updated =
      attraction.withReferencePhoto(
        selection.bytes,
        score: selection.totalScore,
        width: selection.width,
        height: selection.height,
        keypoints: selection.keypoints,
        coverage: selection.featureCoverage,
        sharpness: selection.sharpnessVariance,
        semanticScore: selection.semanticScore,
        ocrNameMatched: selection.ocrNameMatched,
        semanticLabels: List.unmodifiable(selection.semanticLabels),
        suitabilityTier: selection.suitabilityTier,
        kind: selection.referenceKind,
        suitabilityScore: selection.suitabilityScore,
        fingerprint: selection.referenceFingerprint,
      );

      final mutable =
      List<TemporaryQuestAttraction>.from(
        _questAttractions,
      );

      mutable[index] = updated;
      _questAttractions =
          List.unmodifiable(mutable);

      final questId = _activeQuestId?.trim();
      if (questId != null &&
          questId.isNotEmpty &&
          questProgressRepository != null &&
          selection.referenceFingerprint.isNotEmpty) {
        await questProgressRepository!.saveCheckpointReferenceFingerprint(
          questId: questId,
          checkpointNumber: index + 1,
          fingerprint: selection.referenceFingerprint,
          referenceKind: selection.referenceKind,
          width: selection.width,
          height: selection.height,
        );
      }

      debugPrint(
        '[REFERENCE PREFLIGHT] CP${index + 1} READY '
            '${updated.name} | '
            'score=${selection.totalScore.toStringAsFixed(1)}',
      );

      return true;
    } catch (error) {
      debugPrint(
        '[REFERENCE PREFLIGHT] CP${index + 1} '
            'same-place preparation failed: $error',
      );
      return false;
    }
  }

  Future<bool> _replaceUnavailableCheckpointAtIndex(
      int index, {
        int? expectedGenerationVersion,
      }) async {
    final theme =
        _selectedTheme;

    final questId =
        _activeQuestId;

    if (theme == null ||
        questId == null ||
        questId.trim().isEmpty ||
        index < 0 ||
        index >= _questAttractions.length) {
      return false;
    }

    if (expectedGenerationVersion != null &&
        expectedGenerationVersion != _generationVersion) {
      return false;
    }

    try {
      // Preserve the Trip Path route when a saved checkpoint must be
      // replaced. CP2 is searched from CP1; CP3 is searched from CP2.
      // Only CP1 replacement needs the user's current quest-search GPS.
      double replacementOriginLatitude;
      double replacementOriginLongitude;

      if (index > 0) {
        final previous =
        _questAttractions[index - 1];

        replacementOriginLatitude =
            previous.latitude;
        replacementOriginLongitude =
            previous.longitude;
      } else {
        final currentLocation =
        await attractionRepository
            .locationService
            .getQuestSearchLocation();

        replacementOriginLatitude =
            currentLocation.latitude;
        replacementOriginLongitude =
            currentLocation.longitude;
      }

      if (expectedGenerationVersion != null &&
          expectedGenerationVersion != _generationVersion) {
        return false;
      }

      final visitedIds =
          await userLandmarkVisitRepository
              ?.getVisitedGooglePlaceIds() ??
              <String>{};

      // Places already claimed via Puzzle or another Trip Path quest for
      // this account — never offered as a replacement checkpoint.
      final claimedElsewhere =
          await claimedPlacesRepository?.getClaimedPlaceIds() ??
              <String>{};

      if (expectedGenerationVersion != null &&
          expectedGenerationVersion != _generationVersion) {
        return false;
      }

      final existingIds =
      _questAttractions
          .map(
            (item) => item.placeId?.trim(),
      )
          .whereType<String>()
          .where(
            (id) => id.isNotEmpty,
      )
          .toSet();

      final excludedIds =
      <String>{
        ...visitedIds,
        ...existingIds,
        ...claimedElsewhere,
      };

      final excludedAreas = _questAttractions
          .map(
            (item) => QuestCheckpointAreaExclusion(
          name: item.name,
          address: item.address,
          latitude: item.latitude,
          longitude: item.longitude,
        ),
      )
          .toList(growable: false);

      final replacements =
      await attractionRepository
          .findNearbyAttractions(
        latitude: replacementOriginLatitude,
        longitude: replacementOriginLongitude,
        themeId: theme.id,
        limit: 1,
        preferLessPopular: true,
        fastFirstCheckpoint: false,
        excludedPlaceIds: excludedIds,
        excludedCheckpointAreas: excludedAreas,
      );

      if (expectedGenerationVersion != null &&
          expectedGenerationVersion != _generationVersion) {
        return false;
      }

      if (replacements.isEmpty) {
        return false;
      }

      final replacement =
      _convertGoogleAttraction(
        replacements.first,
        themeId: theme.id,
      );

      if (replacement.referencePhotoBytes == null ||
          replacement.referencePhotoBytes!.isEmpty) {
        return false;
      }

      if (expectedGenerationVersion != null &&
          expectedGenerationVersion != _generationVersion) {
        return false;
      }

      final mutable =
      List<TemporaryQuestAttraction>.from(
        _questAttractions,
      );

      mutable[index] = replacement;
      _questAttractions =
          List.unmodifiable(mutable);

      final checkpointNumber =
          index + 1;

      _checkpointClues.remove(checkpointNumber);
      _checkpointClueErrors.remove(checkpointNumber);
      _revealedClueCounts.remove(checkpointNumber);
      _viewingClueIndexes.remove(checkpointNumber);
      _generatingCheckpointVersions.remove(checkpointNumber);

      await questProgressRepository
          ?.replaceIncompleteCheckpoint(
        questId: questId,
        checkpointNumber: checkpointNumber,
        checkpoint: QuestCheckpointSaveData(
          checkpointNumber: checkpointNumber,
          googlePlaceId:
          replacement.placeId ?? '',
          landmarkName:
          replacement.name,
          address:
          replacement.address,
          generalArea:
          replacement.generalArea,
          primaryType:
          replacement.placeType,
          latitude:
          replacement.latitude,
          longitude:
          replacement.longitude,
          verifiedFacts:
          replacement.verifiedFacts,
          referenceFingerprint:
          replacement.referenceFingerprint,
          referenceKind:
          replacement.referenceKind,
          referenceWidth:
          replacement.referencePhotoWidth,
          referenceHeight:
          replacement.referencePhotoHeight,
        ),
      );

      debugPrint(
        '[REFERENCE REPLACEMENT] CP$checkpointNumber -> '
            '${replacement.name}',
      );

      return true;
    } catch (error) {
      debugPrint(
        '[REFERENCE REPLACEMENT] CP${index + 1} failed: $error',
      );

      _referencePreparationError =
          _friendlyReferenceError(error);

      return false;
    }
  }

  // ============================================================
  // USER-FACING ERROR MESSAGES
  //
  // Keep raw API/native details in debugPrint only. UI messages stay
  // actionable and do not expose keys, HTTP bodies or OpenCV internals.
  // ============================================================

  String _friendlyQuestPreparationError(
      Object error,
      ) {
    final text =
    error.toString().toLowerCase();

    if (text.contains('api key') ||
        text.contains('permission_denied') ||
        text.contains('403')) {
      return 'Quest services are not configured correctly. '
          'Please check the Google Places API setup and try again.';
    }

    if (text.contains('429') ||
        text.contains('quota') ||
        text.contains('resource_exhausted')) {
      return 'Quest search is temporarily unavailable because the API '
          'usage limit has been reached. Please try again later.';
    }

    if (text.contains('500') ||
        text.contains('502') ||
        text.contains('503') ||
        text.contains('504')) {
      return 'A quest service is temporarily unavailable. '
          'Please try again in a moment.';
    }

    if (text.contains(
      'multiple_unfinished_quests_database_migration_required',
    )) {
      return 'This app supports multiple unfinished quests, but the '
          'Supabase database still has the old one-active-quest rule. '
          'Apply the included multiple-quest database migration once, '
          'then try again.';
    }

    if (text.contains('supabase') ||
        text.contains('row level security') ||
        text.contains('duplicate key') ||
        text.contains('database')) {
      return 'The quest could not be saved right now. '
          'Please try again. If this happens only when another unfinished '
          'quest exists, apply the included multiple-quest database migration.';
    }

    if (text.contains('timeout') ||
        text.contains('timed out') ||
        text.contains('socket') ||
        text.contains('network') ||
        text.contains('connection')) {
      return 'The network is taking too long. '
          'Check your internet connection and try again.';
    }

    if (text.contains('within 8 seconds')) {
      return 'A GPS fix could not be obtained quickly enough. '
          'Move near a window or open area, then try again.';
    }

    if (text.contains('turned off') ||
        text.contains('service is disabled')) {
      return 'Location is turned off. '
          'Enable your phone location service, then try again.';
    }

    if (text.contains('permanently denied')) {
      return 'Location permission is disabled for this app. '
          'Enable it in App Settings, then try again.';
    }

    if (text.contains('location') ||
        text.contains('gps') ||
        text.contains('permission')) {
      return 'Location permission is required to find nearby checkpoints. '
          'Allow location access and try again.';
    }

    if (text.contains('reference photo') ||
        text.contains('suitable landmarks')) {
      return 'No suitable open checkpoint with a reliable reference '
          'photo could be prepared after expanding the search area. '
          'Try again later, choose another theme, or start from a different area.';
    }

    if (text.contains('sign in') ||
        text.contains('authenticated')) {
      return 'Please sign in before starting a Trip Path Quest.';
    }

    if (text.contains('already been completed') &&
        text.contains('could not be generated')) {
      return 'You have already completed every artwork for this theme, '
          'and a new one could not be generated right now. '
          'Please try again shortly or pick a different theme.';
    }

    return 'Unable to prepare the quest right now. '
        'Please try again.';
  }

  String _friendlyRemainingCheckpointError(
      Object error,
      ) {
    final text =
    error.toString().toLowerCase();

    if (text.contains('429') ||
        text.contains('quota') ||
        text.contains('resource_exhausted')) {
      return 'The next checkpoint cannot be prepared because the API '
          'usage limit is temporarily reached. Please try again later.';
    }

    if (text.contains('500') ||
        text.contains('502') ||
        text.contains('503') ||
        text.contains('504')) {
      return 'The checkpoint service is temporarily unavailable. '
          'Please try again in a moment.';
    }

    if (text.contains('location') ||
        text.contains('gps') ||
        text.contains('permission')) {
      return 'The next checkpoint could not be prepared because your '
          'location is unavailable. Check location permission and try again.';
    }

    if (text.contains('timeout') ||
        text.contains('network') ||
        text.contains('connection') ||
        text.contains('socket')) {
      return 'The next checkpoint is taking too long to prepare. '
          'Check your internet connection and try again.';
    }

    if (text.contains('reference') ||
        text.contains('checkpoint') ||
        text.contains('suitable')) {
      return 'No suitable next checkpoint could be prepared after '
          'expanding the search area and relaxing popularity. '
          'Try again later, or start a new quest from another area.';
    }

    return 'The next checkpoint could not be prepared yet. '
        'Please try again.';
  }

  String _friendlyResumeError(
      Object error,
      ) {
    final text =
    error.toString().toLowerCase();

    if (text.contains('429') ||
        text.contains('quota') ||
        text.contains('resource_exhausted')) {
      return 'The saved quest cannot be restored because the API usage '
          'limit is temporarily reached. Please try again later.';
    }

    if (text.contains('reference') ||
        text.contains('checkpoint')) {
      return 'The next checkpoint could not be prepared or restored. '
          'Your completed progress is saved. Tap Continue Game to retry.';
    }

    if (text.contains('network') ||
        text.contains('timeout') ||
        text.contains('connection')) {
      return 'The saved quest could not be restored because of a '
          'network problem. Check your connection and try again.';
    }

    if (text.contains('sign in') ||
        text.contains('authenticated')) {
      return 'Please sign in again to continue your saved quest.';
    }

    return 'Unable to continue the saved quest right now. '
        'Please try again.';
  }

  String _friendlyCompletionError(
      Object error,
      ) {
    final text = error.toString().toLowerCase();

    if (text.contains('sign in') ||
        text.contains('authenticated')) {
      return 'Please sign in again before saving this checkpoint.';
    }

    if (text.contains('timeout') ||
        text.contains('network') ||
        text.contains('connection') ||
        text.contains('socket')) {
      return 'The checkpoint save took too long. Check your connection and tap Retry Save.';
    }

    if (text.contains('row level security') ||
        text.contains('permission') ||
        text.contains('supabase')) {
      return 'The checkpoint could not be saved to your account. Check your connection and tap Retry Save.';
    }

    return 'The checkpoint could not be saved yet. Your photo is still available; tap Retry Save.';
  }

  String _friendlyReferenceError(
      Object error,
      ) {
    final text =
    error.toString().toLowerCase();

    if (text.contains('429') ||
        text.contains('quota') ||
        text.contains('resource_exhausted')) {
      return 'Reference-photo service usage is temporarily limited. '
          'Please try again later.';
    }

    if (text.contains('network') ||
        text.contains('timeout') ||
        text.contains('connection')) {
      return 'The reference photo could not be prepared because of a '
          'network problem. Please try again.';
    }

    if (text.contains('not open') ||
        text.contains('closed')) {
      return 'This checkpoint is currently closed. '
          'A different open checkpoint will be selected when possible.';
    }

    if (text.contains('photo') ||
        text.contains('reference')) {
      return 'This place no longer has a suitable reference photo. '
          'A different checkpoint will be selected when possible.';
    }

    return 'This checkpoint cannot be prepared for photo verification. '
        'Please try again.';
  }

  // ============================================================
  // SELECT THEME
  // ============================================================

  // FR03_9 — a marker-specific Trip Path entry (see TripPathQuestModule)
  // calls selectTheme(fromMarker: true) to jump straight to Quest Information
  // without ever showing Theme Selection. Pressing back from there should
  // then leave the quest entirely instead of revealing a browse screen the
  // tourist never opened — see [shouldExitOnQuestInfoBack] / goBack().
  bool _skipThemeSelectionOnExit = false;

  bool get shouldExitOnQuestInfoBack => _skipThemeSelectionOnExit;

  void selectTheme(
      QuestThemeData theme, {
        bool fromMarker = false,
      }) {
    unawaited(
      navigation.stop(),
    );

    _generationVersion++;

    _selectedTheme = theme;
    _selectedArtwork = null;
    _activeQuestId = null;
    _skipThemeSelectionOnExit = fromMarker;

    _currentCheckpoint = 1;

    _completedCheckpoints = 0;

    _questAttractions = const [];

    _questLocationError = null;

    _isPreparingQuestLocations = false;
    _isPreparingRemainingCheckpoints = false;
    _remainingCheckpointPreparationError = null;
    _pendingBackgroundSearchLatitude = null;
    _pendingBackgroundSearchLongitude = null;
    _referencePreparationError = null;

    _clearAllClues();

    _currentStage =
        TripPathQuestStage.questInformation;

    notifyListeners();
  }

  // ============================================================
  // START QUEST
  //
  // REAL FLOW:
  //
  // 1. Get current phone GPS.
  // 2. Search Google Places for the selected theme.
  // 3. Keep the 3 selected returned places as CP1 / CP2 / CP3.
  // 4. Print every returned and selected GPS position in terminal.
  // 5. Start the existing Gemini clue flow.
  // ============================================================

  void startQuest() {
    if (_selectedTheme == null ||
        _isPreparingQuestLocations) {
      return;
    }

    // When the user backed up to Quest Information during an
    // already-started quest, Start Quest means return to that same
    // saved quest rather than creating a duplicate active record.
    if (_activeQuestId != null &&
        _questAttractions.isNotEmpty) {
      _currentStage =
          TripPathQuestStage.artworkIntro;
      notifyListeners();
      return;
    }

    unawaited(
      _startQuestWithRealPlaces(),
    );
  }

  Future<void>
  _startQuestWithRealPlaces() async {
    final theme =
        _selectedTheme;

    if (theme == null) {
      return;
    }

    final requestVersion =
        _generationVersion;

    _isPreparingQuestLocations = true;
    _isPreparingRemainingCheckpoints = false;
    _questLocationError = null;
    _questPreparationStatus = null;
    _remainingCheckpointPreparationError = null;
    _pendingBackgroundSearchLatitude = null;
    _pendingBackgroundSearchLongitude = null;

    notifyListeners();

    // Declared outside the try block (not just inside it) so the catch
    // block below can also see whichever artwork was reserved this attempt,
    // to release it again on a genuine failure — see the reservation/release
    // comments further down.
    ThemeArtworkData? selectedArtwork;

    try {
      // Multiple unfinished games are allowed. Reaching this point means
      // the player explicitly chose Start New Quest before selecting a theme.

      // --------------------------------------------------------
      // 1. SELECT THEME ARTWORK
      // --------------------------------------------------------

      if (themeArtworkRepository != null) {
        selectedArtwork =
        await themeArtworkRepository!
            .selectForNewQuest(
          themeId: theme.id,
          alsoExclude: _sessionReservedArtworkIds,
        );

        if (selectedArtwork == null) {
          throw StateError(
            'No active ${theme.name} artwork is available in Supabase.',
          );
        }

        // Reserve it immediately — see _sessionReservedArtworkIds' own doc
        // comment for why this can't wait until createQuest() succeeds.
        if (!selectedArtwork!.wasReused) {
          _sessionReservedArtworkIds.add(selectedArtwork!.id);
        }

        // Trip Path's own pool was exhausted (every artwork for this theme
        // was already completed by this tourist) — ask Manage Rewards for a
        // freshly generated one instead of ever letting this tourist see an
        // artwork they've already completed and claimed a reward for
        // again. Unlike the earlier design, a failure here is NOT allowed
        // to silently fall back to the reused artwork — that would defeat
        // the whole point. If a genuinely fresh artwork can't be produced,
        // the quest start fails outright with a clear message instead.
        if (selectedArtwork!.wasReused) {
          if (rewardRepository == null || themeArtworkRepository == null) {
            throw StateError(
              'Every ${theme.name} artwork has already been completed on '
                  'this account, and a new one could not be generated right '
                  'now. Please try again shortly.',
            );
          }

          ThemeArtworkData? freshArtwork;
          try {
            final freshImage = await rewardRepository!
                .getAvailableThemeSouvenirImage(theme: theme.name);
            // freshImage.id belongs to theme_souvenir_images, a different
            // table -- it can never be used as trip_path_quests.artwork_id
            // (that column has a foreign key into theme_artworks
            // specifically, and inserting a theme_souvenir_images id there
            // fails with a foreign-key-violation, PostgrestException code
            // 23503). Only treat this as a success once we've confirmed the
            // real theme_artworks row it registered (see
            // generateThemeSouvenirImageUrl) can actually be found -- a
            // mock:// fallback means generation itself failed, so there is
            // nothing new to look up.
            if (!freshImage.imageUrl.startsWith('mock://')) {
              freshArtwork = await themeArtworkRepository!
                  .getMostRecentlyAdded(themeId: theme.id);
            }
          } catch (error) {
            debugPrint(
              '[QUEST ARTWORK] Reward catalogue fallback failed: $error',
            );
          }

          if (freshArtwork == null) {
            throw StateError(
              'Every ${theme.name} artwork has already been completed on '
                  'this account, and a new one could not be generated right '
                  'now. Please try again shortly.',
            );
          }

          selectedArtwork = freshArtwork;
        }
      }

      if (requestVersion != _generationVersion ||
          _selectedTheme?.id != theme.id) {
        return;
      }

      List<TemporaryQuestAttraction>
      questAttractions;

      // --------------------------------------------------------
      // OPTIONAL LOCAL MODE
      // --------------------------------------------------------

      if (_debugUseLocalCheckpoints) {
        final local =
        _temporaryAttractions[theme.id];

        if (local == null ||
            local.length < totalCheckpoints) {
          throw StateError(
            'Local checkpoints are missing for theme ${theme.id}.',
          );
        }

        questAttractions =
            List.unmodifiable(
              local.take(totalCheckpoints),
            );

        debugPrint(
          'USE_LOCAL_CHECKPOINTS=true: Google Places skipped.',
        );
      } else {
        // ------------------------------------------------------
        // 2. FAST QUEST-SEARCH GPS
        //
        // Recent position first; otherwise fresh medium-accuracy
        // position with an 8-second maximum wait.
        // Navigation still uses high accuracy separately.
        // ------------------------------------------------------

        debugPrint('');
        debugPrint(
          '==========================================',
        );
        debugPrint(
          '======= PREPARING REAL QUEST PLACES ======',
        );
        debugPrint(
          '==========================================',
        );
        debugPrint(
          'Theme: ${theme.name}',
        );
        debugPrint(
          'Getting fast quest-search GPS...',
        );

        final userLocation =
        await attractionRepository
            .locationService
            .getQuestSearchLocation();

        if (requestVersion != _generationVersion ||
            _selectedTheme?.id != theme.id) {
          return;
        }

        debugPrint(
          'Quest search origin: '
              '${userLocation.latitude.toStringAsFixed(7)}, '
              '${userLocation.longitude.toStringAsFixed(7)} '
              '| accuracy=${userLocation.accuracy.toStringAsFixed(0)} m',
        );

        // ------------------------------------------------------
        // 3. PREVIOUSLY VISITED LANDMARKS
        // ------------------------------------------------------

        final persistedVisited =
            await userLandmarkVisitRepository
                ?.getVisitedGooglePlaceIds() ??
                <String>{};

        // Places already claimed via Puzzle or another Trip Path quest for
        // this account — never offered as a checkpoint (see Claimed Places
        // Repository).
        final claimedElsewhere =
            await claimedPlacesRepository?.getClaimedPlaceIds() ??
                <String>{};

        if (requestVersion != _generationVersion ||
            _selectedTheme?.id != theme.id) {
          return;
        }

        final excludedPlaceIds = <String>{
          ...persistedVisited,
          ..._sessionVisitedPlaceIds,
          ...claimedElsewhere,
        };

        debugPrint(
          'Visited checkpoints excluded: ${excludedPlaceIds.length}',
        );

        // ------------------------------------------------------
        // 4. PREPARE CP1 ONLY
        //
        // CP1 must already have a strict automatic reference photo.
        // As soon as CP1 is ready, gameplay can begin. CP2/CP3 are
        // prepared in the background.
        // ------------------------------------------------------

        final firstPlaces =
        await attractionRepository
            .findNearbyAttractions(
          latitude: userLocation.latitude,
          longitude: userLocation.longitude,
          themeId: theme.id,
          limit: 1,
          preferLessPopular: true,
          fastFirstCheckpoint: true,
          excludedPlaceIds: excludedPlaceIds,
          onProgress: _setQuestPreparationStatus,
        );

        if (requestVersion != _generationVersion ||
            _selectedTheme?.id != theme.id) {
          return;
        }

        if (firstPlaces.isEmpty) {
          throw StateError(
            'No reference-ready open checkpoint was found nearby.',
          );
        }

        final firstCheckpoint =
        _convertGoogleAttraction(
          firstPlaces.first,
          themeId: theme.id,
        );

        if (firstCheckpoint.referencePhotoBytes == null ||
            firstCheckpoint.referencePhotoBytes!.isEmpty) {
          throw StateError(
            'Checkpoint 1 did not have a reliable automatic reference photo.',
          );
        }

        questAttractions =
            List.unmodifiable(
              <TemporaryQuestAttraction>[
                firstCheckpoint,
              ],
            );

        debugPrint('');
        debugPrint(
          '========== CP1 READY - QUEST CAN START ==========',
        );
        debugPrint(
          'CP1: ${firstCheckpoint.name}',
        );
        debugPrint(
          '  Position: '
              '${firstCheckpoint.latitude.toStringAsFixed(7)}, '
              '${firstCheckpoint.longitude.toStringAsFixed(7)}',
        );
        debugPrint(
          '  Reference: READY '
              '| score=${firstCheckpoint.referencePhotoScore?.toStringAsFixed(1) ?? '-'}',
        );
        debugPrint(
          'CP2/CP3 will continue preparing in the background.',
        );
        debugPrint(
          '================================================',
        );

        // Save the search origin for the background task after the
        // in-memory quest state is activated below.
        _pendingBackgroundSearchLatitude =
            userLocation.latitude;
        _pendingBackgroundSearchLongitude =
            userLocation.longitude;
      }

      if (requestVersion != _generationVersion ||
          _selectedTheme?.id != theme.id) {
        return;
      }

      String? createdQuestId;

      // --------------------------------------------------------
      // 5. SAVE THE NEW QUEST
      //
      // Real API mode may initially save CP1 only. CP2/CP3 rows are
      // inserted later only after each is reference-ready.
      // --------------------------------------------------------

      if (questProgressRepository != null) {
        createdQuestId =
        await questProgressRepository!
            .createQuest(
          themeId: theme.id,
          themeName: theme.name,
          artworkId: selectedArtwork?.id,
          checkpoints: List.generate(
            questAttractions.length,
                (index) {
              final attraction =
              questAttractions[index];

              final placeId =
              attraction.placeId?.trim();

              return QuestCheckpointSaveData(
                checkpointNumber: index + 1,
                googlePlaceId:
                placeId != null && placeId.isNotEmpty
                    ? placeId
                    : 'local:${theme.id}:${index + 1}',
                landmarkName: attraction.name,
                address: attraction.address,
                generalArea: attraction.generalArea,
                primaryType: attraction.placeType,
                latitude: attraction.latitude,
                longitude: attraction.longitude,
                verifiedFacts: attraction.verifiedFacts,
                referenceFingerprint: attraction.referenceFingerprint,
                referenceKind: attraction.referenceKind,
                referenceWidth: attraction.referencePhotoWidth,
                referenceHeight: attraction.referencePhotoHeight,
              );
            },
            growable: false,
          ),
        );
      }

      if (requestVersion != _generationVersion ||
          _selectedTheme?.id != theme.id) {
        return;
      }

      _selectedArtwork = selectedArtwork;
      _precacheArtworkImage(selectedArtwork?.imageUrl);
      _activeQuestId = createdQuestId;
      _savedQuest = null;
      _showResumePrompt = false;
      _questAttractions = questAttractions;

      _isPreparingQuestLocations = false;
      _questLocationError = null;
      _questPreparationStatus = null;

      unawaited(
        navigation.stop(),
      );

      _generationVersion++;
      _clearAllClues();

      _currentCheckpoint = 1;
      _completedCheckpoints = 0;
      _currentStage =
          TripPathQuestStage.artworkIntro;

      notifyListeners();

      final clueVersion =
          _generationVersion;

      // CP1 clues can begin immediately.
      unawaited(
        _prepareQuestCluesPrioritized(
          clueVersion,
        ),
      );

      // CP2/CP3 preparation runs independently in the background.
      if (!_debugUseLocalCheckpoints &&
          _questAttractions.length < totalCheckpoints) {
        unawaited(
          _prepareRemainingQuestCheckpointsInBackground(
            version: clueVersion,
            latitude: _pendingBackgroundSearchLatitude,
            longitude: _pendingBackgroundSearchLongitude,
          ),
        );
      }
    } catch (error) {
      if (requestVersion != _generationVersion ||
          _selectedTheme?.id != theme.id) {
        return;
      }

      // This is a genuine failure (checkpoint search/reference-photo
      // screening itself threw), not the tourist leaving — the version
      // check above already sends that case back early instead of reaching
      // here. The artwork was never shown as part of a real quest, so free
      // it back up for this session instead of quietly wasting a pick when
      // the tourist retries the same theme (see _sessionReservedArtworkIds).
      if (selectedArtwork != null && !selectedArtwork!.wasReused) {
        _sessionReservedArtworkIds.remove(selectedArtwork!.id);
      }

      _isPreparingQuestLocations = false;
      _questPreparationStatus = null;
      _questAttractions = const [];
      _questLocationError =
          _friendlyQuestPreparationError(error);

      debugPrint('');
      debugPrint(
        '==========================================',
      );
      debugPrint(
        '======= QUEST PLACE SEARCH FAILED ========',
      );
      debugPrint(
        '==========================================',
      );
      debugPrint(
        '$error',
      );
      debugPrint(
        '==========================================',
      );
      debugPrint('');

      notifyListeners();
    }
  }

  // ============================================================
  // BACKGROUND CP2 / CP3 PREPARATION
  //
  // CP1 is already reference-ready and playable.
  // Missing checkpoints are NOT locked into the quest until the
  // strict reference-photo screening has passed.
  // ============================================================

  Future<void> _prepareRemainingQuestCheckpointsInBackground({
    required int version,
    double? latitude,
    double? longitude,
    int? untilCheckpoint,
  }) async {
    final targetCount =
    (untilCheckpoint ?? totalCheckpoints)
        .clamp(0, totalCheckpoints)
        .toInt();

    if (_debugUseLocalCheckpoints ||
        version != _generationVersion ||
        _selectedTheme == null ||
        _questAttractions.length >= targetCount ||
        _isPreparingRemainingCheckpoints) {
      return;
    }

    final theme = _selectedTheme!;

    _isPreparingRemainingCheckpoints = true;
    _remainingCheckpointPreparationError = null;
    notifyListeners();

    try {
      final persistedVisited =
          await userLandmarkVisitRepository
              ?.getVisitedGooglePlaceIds() ??
              <String>{};

      // Places already claimed via Puzzle or another Trip Path quest for
      // this account — never offered as a checkpoint.
      final claimedElsewhere =
          await claimedPlacesRepository?.getClaimedPlaceIds() ??
              <String>{};

      if (version != _generationVersion) {
        return;
      }

      final excludedPlaceIds = <String>{
        ...persistedVisited,
        ..._sessionVisitedPlaceIds,
        ...claimedElsewhere,
        ..._questAttractions
            .map(
              (item) => item.placeId?.trim(),
        )
            .whereType<String>()
            .where(
              (id) => id.isNotEmpty,
        ),
      };

      debugPrint('');
      debugPrint(
        '==========================================',
      );
      debugPrint(
        '===== BACKGROUND CHECKPOINT PREP ========',
      );
      debugPrint(
        '==========================================',
      );
      debugPrint(
        'Prepared now: ${_questAttractions.length}/$targetCount '
            '(full quest: $totalCheckpoints).',
      );
      debugPrint(
        'Route rule: CP2 searches from CP1; CP3 searches from CP2.',
      );

      // Prepare ONE checkpoint at a time so the route is chained:
      //
      // user GPS -> CP1
      // CP1 GPS  -> CP2
      // CP2 GPS  -> CP3
      //
      // Every checkpoint is persisted immediately after it becomes
      // reference-ready. Therefore Save & Exit / app restart keeps the
      // exact already-prepared remaining places.
      while (_questAttractions.length < targetCount) {
        if (version != _generationVersion) {
          return;
        }

        final checkpointNumber =
            _questAttractions.length + 1;

        double searchLatitude;
        double searchLongitude;

        if (_questAttractions.isNotEmpty) {
          final previous =
              _questAttractions.last;

          searchLatitude = previous.latitude;
          searchLongitude = previous.longitude;

          debugPrint(
            '[ROUTE SEARCH] CP$checkpointNumber origin = '
                'CP${checkpointNumber - 1} ${previous.name} | '
                '${searchLatitude.toStringAsFixed(7)}, '
                '${searchLongitude.toStringAsFixed(7)}',
          );
        } else if (latitude != null &&
            longitude != null) {
          searchLatitude = latitude;
          searchLongitude = longitude;

          debugPrint(
            '[ROUTE SEARCH] CP$checkpointNumber origin = '
                'saved quest search origin.',
          );
        } else {
          final location =
          await attractionRepository
              .locationService
              .getQuestSearchLocation();

          if (version != _generationVersion) {
            return;
          }

          searchLatitude = location.latitude;
          searchLongitude = location.longitude;

          debugPrint(
            '[ROUTE SEARCH] CP$checkpointNumber origin = '
                'fresh/recent quest GPS.',
          );
        }

        final places =
        await attractionRepository
            .findNearbyAttractions(
          latitude: searchLatitude,
          longitude: searchLongitude,
          themeId: theme.id,
          limit: 1,
          preferLessPopular: true,
          // Background CP2 / CP3 use the strict normal reference path:
          // photos 1-3, then 4-5 only when needed.
          fastFirstCheckpoint: false,
          excludedPlaceIds: excludedPlaceIds,
          excludedCheckpointAreas: _questAttractions
              .map(
                (item) => QuestCheckpointAreaExclusion(
              name: item.name,
              address: item.address,
              latitude: item.latitude,
              longitude: item.longitude,
            ),
          )
              .toList(growable: false),
          onProgress: _setQuestPreparationStatus,
        );

        if (version != _generationVersion) {
          return;
        }

        if (places.isEmpty) {
          throw StateError(
            'Checkpoint $checkpointNumber could not be prepared.',
          );
        }

        final checkpoint =
        _convertGoogleAttraction(
          places.first,
          themeId: theme.id,
        );

        // HARD INVARIANT:
        // Never lock or save a checkpoint without an accepted reference.
        if (checkpoint.referencePhotoBytes == null ||
            checkpoint.referencePhotoBytes!.isEmpty) {
          throw StateError(
            'Checkpoint $checkpointNumber did not have a reliable '
                'automatic reference photo.',
          );
        }

        final placeId =
        checkpoint.placeId?.trim();

        if (placeId == null ||
            placeId.isEmpty) {
          throw StateError(
            'Checkpoint $checkpointNumber is missing its Google Place ID.',
          );
        }

        final questId =
        _activeQuestId?.trim();

        // Persist FIRST. If persistence fails, do not claim the checkpoint
        // is locked in memory; the user can retry safely.
        if (questId != null &&
            questId.isNotEmpty &&
            questProgressRepository != null) {
          await questProgressRepository!
              .addPreparedCheckpoint(
            questId: questId,
            checkpoint: QuestCheckpointSaveData(
              checkpointNumber: checkpointNumber,
              googlePlaceId: placeId,
              landmarkName:
              checkpoint.name,
              address:
              checkpoint.address,
              generalArea:
              checkpoint.generalArea,
              primaryType:
              checkpoint.placeType,
              latitude:
              checkpoint.latitude,
              longitude:
              checkpoint.longitude,
              verifiedFacts:
              checkpoint.verifiedFacts,
              referenceFingerprint:
              checkpoint.referenceFingerprint,
              referenceKind:
              checkpoint.referenceKind,
              referenceWidth:
              checkpoint.referencePhotoWidth,
              referenceHeight:
              checkpoint.referencePhotoHeight,
            ),
          );
        }

        if (version != _generationVersion) {
          return;
        }

        final updated =
        List<TemporaryQuestAttraction>.from(
          _questAttractions,
        )
          ..add(checkpoint);

        _questAttractions =
            List.unmodifiable(updated);

        excludedPlaceIds.add(placeId);
        _remainingCheckpointPreparationError = null;

        debugPrint(
          '[BACKGROUND CHECKPOINT READY] '
              'CP$checkpointNumber -> ${checkpoint.name} '
              '| origin chained from previous checkpoint '
              '| reference score='
              '${checkpoint.referencePhotoScore?.toStringAsFixed(1) ?? '-'}',
        );

        notifyListeners();
      }

      _remainingCheckpointPreparationError = null;

      debugPrint(
        'BACKGROUND CHECKPOINT PREP COMPLETE: '
            '${_questAttractions.length}/$totalCheckpoints ready.',
      );

      // Keep the existing request-saving clue design. Do not start the
      // later-clue batch until every checkpoint exists, because clue facts
      // are generated from the complete chained route.
      if (_questAttractions.length >= totalCheckpoints) {
        unawaited(
          _prepareLaterCheckpointCluesBatch(
            version,
          ),
        );
      }
    } catch (error) {
      if (version != _generationVersion) {
        return;
      }

      _remainingCheckpointPreparationError =
          _friendlyRemainingCheckpointError(error);

      debugPrint(
        '[BACKGROUND CHECKPOINT PREP] failed: $error',
      );
    } finally {
      if (version == _generationVersion) {
        _isPreparingRemainingCheckpoints = false;
        notifyListeners();
      }
    }
  }

  Future<void> retryPrepareRemainingCheckpoints() async {
    if (_questAttractions.length >= totalCheckpoints ||
        _selectedTheme == null) {
      return;
    }

    await _prepareRemainingQuestCheckpointsInBackground(
      version: _generationVersion,
    );
  }


  TemporaryQuestAttraction
  _convertGoogleAttraction(
      Attraction attraction, {
        required String themeId,
      }) {
    final generalArea =
    _extractGeneralArea(
      attraction.address,
    );

    final placeType =
    _humanizePlaceType(
      attraction.primaryType,
    );

    return TemporaryQuestAttraction(
      name:
      attraction.name,
      address:
      attraction.address,
      generalArea:
      generalArea,
      placeType:
      placeType,
      latitude:
      attraction.latitude,
      longitude:
      attraction.longitude,

      // Clues must describe the real-world place, not Google database
      // metadata such as rating, review count or OPERATIONAL status.
      // These facts are derived from the accepted reference image,
      // theme and place type without making an additional API request.
      verifiedFacts: _buildQuestVerifiedFacts(
        attraction: attraction,
        themeId: themeId,
        placeType: placeType,
        generalArea: generalArea,
      ),

      placeId:
      attraction.id,
      rating:
      attraction.rating,
      userRatingCount:
      attraction.userRatingCount,
      // Google photo resource names are not persisted/cached.
      photoResourceName: null,
      googleMapsUri:
      attraction.googleMapsUri,
      referencePhotoBytes:
      attraction.referencePhotoBytes,
      referencePhotoScore:
      attraction.referencePhotoScore,
      referencePhotoWidth:
      attraction.referencePhotoWidth,
      referencePhotoHeight:
      attraction.referencePhotoHeight,
      referencePhotoKeypoints:
      attraction.referencePhotoKeypoints,
      referencePhotoCoverage:
      attraction.referencePhotoCoverage,
      referencePhotoSharpness:
      attraction.referencePhotoSharpness,
      referenceSemanticScore:
      attraction.referenceSemanticScore,
      referenceOcrNameMatched:
      attraction.referenceOcrNameMatched,
      referenceSemanticLabels:
      List.unmodifiable(attraction.referenceSemanticLabels),
      referenceSuitabilityTier:
      attraction.referenceSuitabilityTier,
      referenceKind:
      attraction.referenceKind,
      referenceSuitabilityScore:
      attraction.referenceSuitabilityScore,
      referenceFingerprint:
      attraction.referenceFingerprint,
    );
  }

  String _humanizePlaceType(
      String raw,
      ) {
    final cleaned = raw
        .trim()
        .replaceAll(
      '_',
      ' ',
    );

    if (cleaned.isEmpty) {
      return 'tourist attraction';
    }

    return cleaned;
  }

  String _extractGeneralArea(
      String address,
      ) {
    final parts = address
        .split(',')
        .map(
          (part) => part.trim(),
    )
        .where(
          (part) => part.isNotEmpty,
    )
        .toList();

    if (parts.isEmpty) {
      return 'nearby area';
    }

    for (final rawPart
    in parts.reversed) {
      final cleanedPart = _stripPlusCode(rawPart);

      if (cleanedPart.isEmpty) {
        continue;
      }

      final lower =
      cleanedPart.toLowerCase();

      if (lower == 'malaysia' ||
          lower.contains(
            'wilayah persekutuan',
          ) ||
          lower == 'selangor' ||
          lower == 'kuala lumpur' ||
          lower == 'putrajaya') {
        continue;
      }

      final withoutPostcode =
      cleanedPart
          .replaceFirst(
        RegExp(
          r'^\d{5}\s*',
        ),
        '',
      )
          .trim();

      if (withoutPostcode.isEmpty) {
        continue;
      }

      final normalizedArea = withoutPostcode.toLowerCase();
      if (RegExp(r'\b(jalan|jln|lorong|persiaran|lebuh|road|street|lane)\b|\d',
          caseSensitive: false).hasMatch(withoutPostcode)) {
        continue;
      }
      if (normalizedArea == 'kuala lumpur' ||
          normalizedArea == 'putrajaya' ||
          normalizedArea == 'selangor' ||
          normalizedArea.contains('federal territory of kuala lumpur')) {
        continue;
      }

      if (RegExp(
        r'^\d+$',
      ).hasMatch(
        withoutPostcode,
      )) {
        continue;
      }

      return withoutPostcode;
    }

    return 'nearby area';
  }

  String _stripPlusCode(String value) {
    var cleaned = value.trim();

    // Google formattedAddress may begin with a short Open Location Code,
    // e.g. "6PHM+C3 Bukit KL East Retreat". It is too revealing and
    // unnatural for a mystery clue, so remove it before locality extraction.
    cleaned = cleaned.replaceFirst(
      RegExp(
        r'^\s*[23456789CFGHJMPQRVWX]{4,8}\+[23456789CFGHJMPQRVWX]{2,3}\s*',
        caseSensitive: false,
      ),
      '',
    );

    return cleaned.trim();
  }

  bool _containsPlusCode(String value) {
    return RegExp(
      r'\b[23456789CFGHJMPQRVWX]{4,8}\+[23456789CFGHJMPQRVWX]{2,3}\b',
      caseSensitive: false,
    ).hasMatch(value);
  }

  // ============================================================
  // REAL-WORLD CLUE FACTS
  //
  // Do not feed Gemini Google database metadata such as rating,
  // review count, business status or "Google Places classifies".
  // The clue facts below are intentionally grounded in the accepted
  // reference photo, its semantic labels, the place type and locality.
  // ============================================================

  List<String> _buildQuestVerifiedFacts({
    required Attraction attraction,
    required String themeId,
    required String placeType,
    required String generalArea,
  }) {
    final labels = _cleanReferenceSemanticLabels(
      attraction.referenceSemanticLabels,
    );

    final physicalTerms = _observablePhysicalTerms(
      labels,
      themeId,
    );

    final physicalDescription = physicalTerms.isEmpty
        ? _fallbackPhysicalDescription(
      themeId: themeId,
      placeType: placeType,
    )
        : physicalTerms.take(3).join(', ');

    final appearanceFact =
        'On site, the checkpoint is a stable physical place with visible '
        'features suggested by the reference: $physicalDescription. '
        'These are broad categories, not proof of a particular colour, shape or history; '
        'do not invent distinguishing details or turn alternatives into a list of objects present.';

    final experienceFact = _experienceFactForPlace(
      themeId: themeId,
      placeType: placeType,
    );

    final areaIsUseful = generalArea.trim().isNotEmpty &&
        generalArea.toLowerCase() != 'nearby area' &&
        generalArea.toLowerCase() != 'kuala lumpur';

    final identifierTerms = physicalTerms.isEmpty
        ? <String>[]
        : physicalTerms.reversed
        .take(2)
        .toList(growable: false)
        .reversed
        .toList(growable: false);

    final identifierDescription = identifierTerms.isEmpty
        ? physicalDescription
        : identifierTerms.join(', ');

    String identifierFact;
    if (attraction.referenceOcrNameMatched) {
      // Strongest case: the accepted reference contains readable
      // place-name signage. Gemini is told that signage exists, but never
      // receives or reveals the actual place name.
      identifierFact = areaIsUseful
          ? 'A readable place-name sign is visible at this physical place '
          'in the $generalArea locality; nearby stable identifying '
          'features include $identifierDescription. Do not reveal the '
          'sign text.'
          : 'A readable place-name sign is visible at this physical place; '
          'nearby stable identifying features include '
          '$identifierDescription. Do not reveal the sign text.';
    } else if (areaIsUseful) {
      // No readable name sign: combine a useful locality with stable
      // visual identifiers so Clue 3 is stronger than a generic city hint.
      identifierFact =
      'The checkpoint is in the $generalArea locality and is best '
          'identified on site by the combination of stable visible '
          'features $identifierDescription.';
    } else if (identifierTerms.length >= 2) {
      identifierFact =
      'The checkpoint can be distinguished on site by the combination '
          'of stable visible features $identifierDescription.';
    } else {
      identifierFact =
      'The checkpoint is a physical $placeType location whose strongest '
          'stable on-site identifier is $identifierDescription.';
    }

    return <String>[
      appearanceFact,
      experienceFact,
      identifierFact,
    ];
  }

  List<String> _cleanReferenceSemanticLabels(
      List<String> rawLabels,
      ) {
    return rawLabels
        .map(
          (label) => label
          .replaceFirst(
        RegExp(r'\s+\d+%$'),
        '',
      )
          .trim()
          .toLowerCase(),
    )
        .where((label) => label.isNotEmpty)
        .toList(growable: false);
  }

  List<String> _observablePhysicalTerms(
      List<String> labels,
      String themeId,
      ) {
    final theme = themeId.toLowerCase();

    final allowed = <String>{
      if (theme == 'food') ...<String>{
        'building', 'architecture', 'facade', 'door', 'window',
        'entrance', 'storefront', 'shop', 'store', 'stall',
        'food stall', 'market stall', 'roadside stall', 'hawker stall',
        'hawker', 'kiosk', 'booth', 'vendor', 'vendor stand',
        'street vendor', 'food truck', 'cart', 'counter', 'canopy',
        'tent', 'market', 'signage', 'sign', 'awning', 'roof',
      },
      if (theme == 'culture' || theme == 'heritage') ...<String>{
        'building', 'architecture', 'facade', 'door', 'window',
        'entrance', 'temple', 'mosque', 'church', 'cathedral',
        'shrine', 'castle', 'museum', 'monument', 'statue',
        'sculpture', 'mural', 'tower', 'bridge', 'landmark', 'roof',
      },
      if (theme == 'nature') ...<String>{
        'park', 'lake', 'forest', 'waterfall', 'mountain', 'garden',
        'river', 'pond', 'tree', 'vegetation', 'landscape', 'trail',
        'outdoor', 'nature', 'bridge', 'pavilion',
      },
    };

    return labels
        .where(
          (label) => allowed.any(
            (keyword) => label == keyword ||
            label.contains('$keyword ') ||
            label.contains(' $keyword'),
      ),
    )
        .toList(growable: false);
  }

  String _fallbackPhysicalDescription({
    required String themeId,
    required String placeType,
  }) {
    switch (themeId.toLowerCase()) {
      case 'food':
        return 'a storefront, fixed stall, kiosk, booth, or other '
            'physical food-place structure';
      case 'culture':
        return 'a cultural venue; no specific exterior detail has been confirmed';
      case 'heritage':
        return 'historic architecture, a monument, or another durable '
            'heritage structure';
      case 'nature':
        return 'a stable outdoor scene such as a park, lake, garden, '
            'trail, or natural feature';
      default:
        return 'a stable physical $placeType location';
    }
  }

  String _experienceFactForPlace({
    required String themeId,
    required String placeType,
  }) {
    final type = placeType.toLowerCase();

    if (themeId.toLowerCase() == 'food') {
      if (type.contains('bakery')) {
        return 'Visitors come to this physical food place to buy baked '
            'goods or bakery items.';
      }
      if (type.contains('cafe') || type.contains('coffee')) {
        return 'Visitors stop at this physical food place for drinks, '
            'snacks, or light meals.';
      }
      if (type.contains('market')) {
        return 'Visitors browse the physical market or stalls and buy '
            'food from vendors.';
      }
      if (type.contains('restaurant')) {
        return 'Visitors come to this physical food place to eat a meal.';
      }
      return 'Visitors come to this physical checkpoint to obtain or '
          'enjoy food at the location itself.';
    }

    if (themeId.toLowerCase() == 'nature') {
      return 'Visitors come here to experience the outdoor environment '
          'and observe the surrounding natural scenery.';
    }

    if (themeId.toLowerCase() == 'heritage') {
      return 'Visitors come here to observe and appreciate the physical '
          'heritage site or historic structure.';
    }

    return 'Visitors come here to observe, explore, or appreciate the '
        'physical cultural landmark or public site.';
  }

  bool _cluesContainForbiddenDatabaseMetadata(
      List<String> clues,
      ) {
    final joined = clues.join(' ').toLowerCase();

    const forbidden = <String>[
      'durable structure',
      'durable public landmark',
      'google places',
      'classified primarily',
      'classifies primarily',
      'operational place',
      'business status',
      'user reviews',
      'review count',
      'rating of',
      'star rating',
      'no reviews',
      'zero reviews',
      '0 reviews',
      'unrated',
      '0.0 from 0',
      'currently open for business',
      'reference photo',
      'accepted reference',
      'semantic score',
      'orb ',
    ];

    return RegExp(r'\b(jalan|jln|lorong|persiaran|lebuh)\b', caseSensitive: false).hasMatch(joined) ||
        forbidden.any(joined.contains) ||
        _containsPlusCode(clues.join(' '));
  }

  // ============================================================
  // SUPABASE REUSABLE CLUE CACHE
  //
  // Cache key:
  // Google Place ID
  //
  // Same place returned in a future Quest can therefore reuse
  // the same 3 clues without another Gemini request.
  // ============================================================

  Future<List<String>?>
  _loadReusableClues({
    required int checkpoint,
    required TemporaryQuestAttraction attraction,
  }) async {
    final repository =
        landmarkClueRepository;

    final placeId =
    attraction.placeId?.trim();

    if (repository == null ||
        placeId == null ||
        placeId.isEmpty) {
      return null;
    }

    debugPrint(
      '[SUPABASE CLUE CACHE] '
          'CP$checkpoint checking: '
          '${attraction.name}',
    );

    final clues =
    await repository.getReusableClues(
      googlePlaceId:
      placeId,
      name:
      attraction.name,
      address:
      attraction.address,
      primaryType:
      attraction.placeType,
      latitude:
      attraction.latitude,
      longitude:
      attraction.longitude,
      photoResourceName:
      attraction.photoResourceName,
    );

    if (clues == null) {
      debugPrint(
        '[SUPABASE CLUE CACHE] '
            'CP$checkpoint MISS -> Gemini fallback.',
      );

      return null;
    }

    // Old cached clues may contain the previous weak metadata wording
    // (Google Places classification, OPERATIONAL status, rating/reviews).
    // Ignore those entries so a new real-world clue set can replace them.
    if (_cluesContainForbiddenDatabaseMetadata(clues)) {
      debugPrint(
        '[SUPABASE CLUE CACHE] '
            'CP$checkpoint STALE METADATA CLUES -> regenerate.',
      );
      return null;
    }

    debugPrint(
      '[SUPABASE CLUE CACHE] '
          'CP$checkpoint HIT -> Gemini skipped.',
    );

    return clues;
  }

  Future<void>
  _saveReusableClues({
    required int checkpoint,
    required TemporaryQuestAttraction attraction,
    required List<String> clues,
  }) async {
    final repository =
        landmarkClueRepository;

    final placeId =
    attraction.placeId?.trim();

    if (repository == null ||
        placeId == null ||
        placeId.isEmpty) {
      return;
    }

    await repository.saveReusableClues(
      googlePlaceId:
      placeId,
      name:
      attraction.name,
      address:
      attraction.address,
      primaryType:
      attraction.placeType,
      latitude:
      attraction.latitude,
      longitude:
      attraction.longitude,
      photoResourceName:
      attraction.photoResourceName,
      clues:
      clues,
    );

    debugPrint(
      '[SUPABASE CLUE CACHE] '
          'CP$checkpoint save attempt finished.',
    );
  }

  void _applyPreparedClues({
    required int checkpoint,
    required List<String> clues,
  }) {
    _checkpointClues[checkpoint] =
        List.unmodifiable(
          clues,
        );

    _checkpointClueErrors.remove(
      checkpoint,
    );

    _persistQuestCheckpointClues(
      checkpoint: checkpoint,
      clues: clues,
    );

    if (_currentCheckpoint ==
        checkpoint &&
        _currentStage ==
            TripPathQuestStage.clue &&
        cluesUsed == 0) {
      _revealedClueCounts[
      checkpoint] = 1;

      _viewingClueIndexes[
      checkpoint] = 0;
    }
  }

  void _persistQuestCheckpointClues({
    required int checkpoint,
    required List<String> clues,
  }) {
    final questId =
        _activeQuestId;
    final repository =
        questProgressRepository;

    if (questId == null ||
        questId.isEmpty ||
        repository == null ||
        clues.length != 3) {
      return;
    }

    unawaited(
      repository
          .saveCheckpointClues(
        questId: questId,
        checkpointNumber: checkpoint,
        clues: clues,
      )
          .catchError(
            (Object error) {
          debugPrint(
            '[QUEST PROGRESS] Unable to persist CP$checkpoint clues: $error',
          );
        },
      ),
    );
  }

  // ============================================================
  // CLUE PREPARATION
  //
  // REAL MODE:
  //
  // Request #1
  // CP1 → 3 clues
  //
  // Request #2
  // CP2 + CP3 → 6 clues
  //
  // DEBUG MODE:
  //
  // 0 Gemini requests
  // ============================================================

  Future<void> _prepareQuestCluesPrioritized(
      int version,
      ) async {
    if (version != _generationVersion) {
      return;
    }

    // ==========================================================
    // DEBUG MODE
    //
    // Skip Gemini completely.
    //
    // Each checkpoint still gets exactly 3 clues.
    // ==========================================================

    if (_debugUseMockClues) {
      debugPrint(
        'DEBUG MODE: Gemini skipped. Using local mock clues.',
      );

      // ========================================================
      // CHECKPOINT 1
      // ========================================================

      _checkpointClues[1] = const [
        'Look for a nearby place with a distinctive physical appearance.',
        'Visitors often come here to explore and enjoy the surrounding area.',
        'A recognizable feature should help you identify the correct first checkpoint.',
      ];

      // ========================================================
      // CHECKPOINT 2
      // ========================================================

      _checkpointClues[2] = const [
        'Look carefully for a place with noticeable physical features.',
        'People usually visit this area for a particular local experience.',
        'One distinctive detail should make the second checkpoint easier to recognize.',
      ];

      // ========================================================
      // CHECKPOINT 3
      // ========================================================

      _checkpointClues[3] = const [
        'Find a place with a visible feature that stands out from nearby locations.',
        'Visitors commonly spend time here exploring the surrounding area.',
        'Use the strongest visual detail to identify your final checkpoint.',
      ];

      _checkpointClueErrors.clear();

      _persistQuestCheckpointClues(
        checkpoint: 1,
        clues: _checkpointClues[1]!,
      );
      _persistQuestCheckpointClues(
        checkpoint: 2,
        clues: _checkpointClues[2]!,
      );
      _persistQuestCheckpointClues(
        checkpoint: 3,
        clues: _checkpointClues[3]!,
      );

      _generatingCheckpointVersions.clear();

      debugPrint(
        'DEBUG MODE: CP1 mock clues ready.',
      );

      debugPrint(
        'DEBUG MODE: CP2 mock clues ready.',
      );

      debugPrint(
        'DEBUG MODE: CP3 mock clues ready.',
      );

      notifyListeners();

      return;
    }

    // ==========================================================
    // NORMAL GEMINI MODE
    // ==========================================================

    await _prepareCheckpointClues(
      checkpoint: 1,
      version: version,
    );

    if (version != _generationVersion) {
      return;
    }

    // CP1 generation failed.
    // Do not waste another Gemini request.
    if (!isCheckpointPrepared(1)) {
      return;
    }

    // CP1 ready.
    //
    // Generate CP2 + CP3 together in background.
    unawaited(
      _prepareLaterCheckpointCluesBatch(
        version,
      ),
    );
  }

  // ============================================================
  // PREPARE CP2 + CP3
  //
  // First check Supabase independently for CP2 / CP3.
  //
  // Cases:
  // - both HIT  -> 0 Gemini requests
  // - one HIT   -> 1 single-checkpoint Gemini request
  // - both MISS -> 1 Gemini batch request
  // ============================================================

  Future<void> _prepareLaterCheckpointCluesBatch(
      int version,
      ) async {
    if (version != _generationVersion) {
      return;
    }

    final theme = _selectedTheme;

    if (theme == null) {
      return;
    }

    final attractions =
    _activeAttractionsForTheme(
      theme.id,
    );

    if (attractions == null ||
        attractions.length < 3) {
      return;
    }

    if (isCheckpointPrepared(2) &&
        isCheckpointPrepared(3)) {
      return;
    }

    if (_generatingCheckpointVersions[2] ==
        version ||
        _generatingCheckpointVersions[3] ==
            version) {
      return;
    }

    final checkpoint2 =
    attractions[1];

    final checkpoint3 =
    attractions[2];

    _generatingCheckpointVersions[2] =
        version;

    _generatingCheckpointVersions[3] =
        version;

    _checkpointClueErrors.remove(2);

    _checkpointClueErrors.remove(3);

    notifyListeners();

    debugPrint(
      'CP2 + CP3 clue preparation started.',
    );

    try {
      // ========================================================
      // 1. SUPABASE CACHE CHECK
      // ========================================================

      final cached2 =
      isCheckpointPrepared(2)
          ? _checkpointClues[2]
          : await _loadReusableClues(
        checkpoint:
        2,
        attraction:
        checkpoint2,
      );

      if (version != _generationVersion) {
        return;
      }

      if (cached2 != null &&
          cached2.length == 3) {
        _applyPreparedClues(
          checkpoint:
          2,
          clues:
          cached2,
        );
      }

      final cached3 =
      isCheckpointPrepared(3)
          ? _checkpointClues[3]
          : await _loadReusableClues(
        checkpoint:
        3,
        attraction:
        checkpoint3,
      );

      if (version != _generationVersion) {
        return;
      }

      if (cached3 != null &&
          cached3.length == 3) {
        _applyPreparedClues(
          checkpoint:
          3,
          clues:
          cached3,
        );
      }

      final cp2Ready =
      isCheckpointPrepared(2);

      final cp3Ready =
      isCheckpointPrepared(3);

      // Both cached.
      if (cp2Ready && cp3Ready) {
        debugPrint(
          'CP2 + CP3 ready from Supabase cache. '
              'Gemini batch skipped.',
        );

        return;
      }

      // Only one checkpoint is missing.
      //
      // Generate only that checkpoint rather than spending a
      // two-checkpoint Gemini request.
      if (cp2Ready != cp3Ready) {
        final missing =
        cp2Ready ? 3 : 2;

        debugPrint(
          'Only CP$missing is missing. '
              'Generating one checkpoint with Gemini.',
        );

        _generatingCheckpointVersions
            .remove(
          missing,
        );

        await _prepareCheckpointClues(
          checkpoint:
          missing,
          version:
          version,
        );

        return;
      }

      // ========================================================
      // 2. BOTH MISS -> ONE GEMINI BATCH REQUEST
      // ========================================================

      debugPrint(
        'CP2 + CP3 cache MISS. '
            'Gemini batch generation started.',
      );

      final result =
      await geminiService
          .generateCluesForTwoCheckpoints(
        theme:
        theme.name,
        checkpoint2:
        GeminiCheckpointClueInput(
          attractionName:
          checkpoint2.name,
          attractionAddress:
          checkpoint2.address,
          generalArea:
          checkpoint2.generalArea,
          placeType:
          checkpoint2.placeType,
          verifiedFacts:
          checkpoint2.verifiedFacts,
        ),
        checkpoint3:
        GeminiCheckpointClueInput(
          attractionName:
          checkpoint3.name,
          attractionAddress:
          checkpoint3.address,
          generalArea:
          checkpoint3.generalArea,
          placeType:
          checkpoint3.placeType,
          verifiedFacts:
          checkpoint3.verifiedFacts,
        ),
      );

      if (version != _generationVersion) {
        return;
      }

      _applyPreparedClues(
        checkpoint:
        2,
        clues:
        result.checkpoint2,
      );

      _applyPreparedClues(
        checkpoint:
        3,
        clues:
        result.checkpoint3,
      );

      debugPrint(
        'CP2 + CP3 Gemini batch clues ready.',
      );

      debugPrint(
        'CP2 Clue 1: ${result.checkpoint2[0]}',
      );

      debugPrint(
        'CP2 Clue 2: ${result.checkpoint2[1]}',
      );

      debugPrint(
        'CP2 Clue 3: ${result.checkpoint2[2]}',
      );

      debugPrint(
        'CP3 Clue 1: ${result.checkpoint3[0]}',
      );

      debugPrint(
        'CP3 Clue 2: ${result.checkpoint3[1]}',
      );

      debugPrint(
        'CP3 Clue 3: ${result.checkpoint3[2]}',
      );

      // Saving is not allowed to delay the clue UI.
      unawaited(
        _saveReusableClues(
          checkpoint:
          2,
          attraction:
          checkpoint2,
          clues:
          result.checkpoint2,
        ),
      );

      unawaited(
        _saveReusableClues(
          checkpoint:
          3,
          attraction:
          checkpoint3,
          clues:
          result.checkpoint3,
        ),
      );
    } on GeminiServiceException catch (error) {
      if (version != _generationVersion) {
        return;
      }

      // Do not delete a checkpoint that was already loaded from
      // Supabase. Only mark the still-missing checkpoint(s).
      if (!isCheckpointPrepared(2)) {
        _checkpointClues.remove(2);

        _checkpointClueErrors[2] =
        'Unable to generate clues. '
            'Please try again.';
      }

      if (!isCheckpointPrepared(3)) {
        _checkpointClues.remove(3);

        _checkpointClueErrors[3] =
        'Unable to generate clues. '
            'Please try again.';
      }

      debugPrint(
        'CP2 + CP3 clue generation failed: '
            '${error.message}',
      );
    } catch (error) {
      if (version != _generationVersion) {
        return;
      }

      if (!isCheckpointPrepared(2)) {
        _checkpointClues.remove(2);

        _checkpointClueErrors[2] =
        'Unable to generate clues. '
            'Please try again.';
      }

      if (!isCheckpointPrepared(3)) {
        _checkpointClues.remove(3);

        _checkpointClueErrors[3] =
        'Unable to generate clues. '
            'Please try again.';
      }

      debugPrint(
        'CP2 + CP3 unexpected error: $error',
      );
    } finally {
      if (_generatingCheckpointVersions[2] ==
          version) {
        _generatingCheckpointVersions
            .remove(2);
      }

      if (_generatingCheckpointVersions[3] ==
          version) {
        _generatingCheckpointVersions
            .remove(3);
      }

      if (version == _generationVersion) {
        notifyListeners();
      }
    }
  }

  // ============================================================
  // GENERATE 3 CLUES FOR ONE CHECKPOINT
  //
  // ONE Gemini request
  // → THREE clues
  // ============================================================

  Future<void> _prepareCheckpointClues({
    required int checkpoint,
    required int version,
  }) async {
    if (version != _generationVersion) {
      return;
    }

    final theme = _selectedTheme;

    if (theme == null) {
      return;
    }

    final attractions =
    _activeAttractionsForTheme(
      theme.id,
    );

    if (attractions == null ||
        attractions.length < checkpoint) {
      return;
    }

    // Already prepared.
    if (_checkpointClues[checkpoint]
        ?.length ==
        3) {
      return;
    }

    // Already generating.
    if (_generatingCheckpointVersions[
    checkpoint] ==
        version) {
      return;
    }

    final attraction =
    attractions[checkpoint - 1];

    _generatingCheckpointVersions[
    checkpoint] = version;

    _checkpointClueErrors.remove(
      checkpoint,
    );

    notifyListeners();

    try {
      // ========================================================
      // 1. SUPABASE CACHE
      // ========================================================

      final cachedClues =
      await _loadReusableClues(
        checkpoint:
        checkpoint,
        attraction:
        attraction,
      );

      if (version != _generationVersion) {
        return;
      }

      if (cachedClues != null &&
          cachedClues.length == 3) {
        _applyPreparedClues(
          checkpoint:
          checkpoint,
          clues:
          cachedClues,
        );

        debugPrint(
          'CP$checkpoint clues ready from Supabase. '
              'Gemini skipped.',
        );

        return;
      }

      // ========================================================
      // 2. CACHE MISS -> GEMINI
      // ========================================================

      final clues =
      await geminiService.generateClues(
        attractionName:
        attraction.name,
        attractionAddress:
        attraction.address,
        generalArea:
        attraction.generalArea,
        placeType:
        attraction.placeType,
        theme:
        theme.name,
        verifiedFacts:
        attraction.verifiedFacts,
      );

      // Ignore stale request.
      if (version != _generationVersion) {
        return;
      }

      if (clues.length != 3) {
        throw const GeminiServiceException(
          'Expected exactly 3 clues.',
        );
      }

      _applyPreparedClues(
        checkpoint: checkpoint,
        clues: clues,
      );

      debugPrint(
        'CP$checkpoint clues ready.',
      );

      debugPrint(
        'DEBUG attraction: '
            '${attraction.name}',
      );

      debugPrint(
        'CP$checkpoint Clue 1: '
            '${clues[0]}',
      );

      debugPrint(
        'CP$checkpoint Clue 2: '
            '${clues[1]}',
      );

      debugPrint(
        'CP$checkpoint Clue 3: '
            '${clues[2]}',
      );

      // Save generated clues for future reuse.
      //
      // Do not block the user if Supabase is slow/unavailable.
      unawaited(
        _saveReusableClues(
          checkpoint:
          checkpoint,
          attraction:
          attraction,
          clues:
          clues,
        ),
      );

      // If user is already waiting on clue page,
      // automatically show clue 1.
      if (_currentCheckpoint ==
          checkpoint &&
          _currentStage ==
              TripPathQuestStage.clue &&
          cluesUsed == 0) {
        _revealedClueCounts[
        checkpoint] = 1;

        _viewingClueIndexes[
        checkpoint] = 0;
      }
    } on GeminiServiceException catch (error) {
      if (version != _generationVersion) {
        return;
      }

      _checkpointClues.remove(
        checkpoint,
      );

      _checkpointClueErrors[
      checkpoint] =
      'Unable to generate clues. '
          'Please try again.';

      debugPrint(
        'CP$checkpoint '
            'clue generation failed: '
            '${error.message}',
      );
    } catch (error) {
      if (version != _generationVersion) {
        return;
      }

      _checkpointClues.remove(
        checkpoint,
      );

      _checkpointClueErrors[
      checkpoint] =
      'Unable to generate clues. '
          'Please try again.';

      debugPrint(
        'CP$checkpoint '
            'unexpected error: '
            '$error',
      );
    } finally {
      if (_generatingCheckpointVersions[
      checkpoint] ==
          version) {
        _generatingCheckpointVersions
            .remove(
          checkpoint,
        );
      }

      if (version == _generationVersion) {
        notifyListeners();
      }
    }
  }

  // ============================================================
  // BEGIN CHECKPOINT
  // ============================================================

  void beginCheckpoint() {
    if (_selectedTheme == null ||
        isQuestCompleted) {
      return;
    }

    // CP2/CP3 may still be preparing in the background. Never enter
    // a checkpoint until its own reference-ready attraction exists.
    if (currentAttraction == null ||
        !isCurrentCheckpointReady) {
      if (!_isPreparingRemainingCheckpoints) {
        unawaited(
          retryPrepareRemainingCheckpoints(),
        );
      }

      notifyListeners();
      return;
    }

    _currentStage =
        TripPathQuestStage.clue;

    // Already prepared.
    //
    // Reveal clue 1 first.
    if (areCluesPrepared) {
      if (cluesUsed == 0) {
        _revealedClueCounts[
        _currentCheckpoint] = 1;

        _viewingClueIndexes[
        _currentCheckpoint] = 0;
      }

      notifyListeners();

      return;
    }

    notifyListeners();

    // Still generating.
    if (isGeneratingClue) {
      return;
    }

    // Failed previously.
    //
    // Wait for retry.
    if (clueGenerationError != null) {
      return;
    }

    // Fallback.
    unawaited(
      _prepareCheckpointClues(
        checkpoint:
        _currentCheckpoint,
        version:
        _generationVersion,
      ),
    );
  }

  // ============================================================
  // ANOTHER CLUE
  //
  // IMPORTANT:
  // This does NOT call Gemini.
  //
  // It only reveals another clue already stored locally.
  // ============================================================

  void requestAnotherClue() {
    if (!canRequestAnotherClue) {
      return;
    }

    final newCount =
        cluesUsed + 1;

    _revealedClueCounts[
    _currentCheckpoint] =
        newCount;

    // Show newly unlocked clue.
    _viewingClueIndexes[
    _currentCheckpoint] =
        newCount - 1;

    notifyListeners();
  }

  // ============================================================
  // RETRY CLUE GENERATION
  // ============================================================

  Future<void> retryGenerateClue() async {
    // ==========================================================
    // DEBUG MODE
    //
    // Normally this shouldn't be needed because mock clues are
    // immediately ready.
    // ==========================================================

    if (_debugUseMockClues) {
      final version =
          _generationVersion;

      await _prepareQuestCluesPrioritized(
        version,
      );

      if (areCluesPrepared &&
          cluesUsed == 0) {
        _revealedClueCounts[
        _currentCheckpoint] = 1;

        _viewingClueIndexes[
        _currentCheckpoint] = 0;

        notifyListeners();
      }

      return;
    }

    if (isGeneratingClue) {
      return;
    }

    final checkpoint =
        _currentCheckpoint;

    final shouldRetryBatch =
        (checkpoint == 2 ||
            checkpoint == 3) &&
            !isCheckpointPrepared(2) &&
            !isCheckpointPrepared(3);

    // ==========================================================
    // RETRY CP2 + CP3 TOGETHER
    // ==========================================================

    if (shouldRetryBatch) {
      _checkpointClues.remove(2);

      _checkpointClues.remove(3);

      _checkpointClueErrors.remove(2);

      _checkpointClueErrors.remove(3);

      _revealedClueCounts.remove(2);

      _revealedClueCounts.remove(3);

      _viewingClueIndexes.remove(2);

      _viewingClueIndexes.remove(3);

      notifyListeners();

      await _prepareLaterCheckpointCluesBatch(
        _generationVersion,
      );

      return;
    }

    // ==========================================================
    // RETRY ONE CHECKPOINT
    // ==========================================================

    _checkpointClues.remove(
      checkpoint,
    );

    _checkpointClueErrors.remove(
      checkpoint,
    );

    _revealedClueCounts.remove(
      checkpoint,
    );

    _viewingClueIndexes.remove(
      checkpoint,
    );

    notifyListeners();

    await _prepareCheckpointClues(
      checkpoint: checkpoint,
      version:
      _generationVersion,
    );
  }

  // ============================================================
  // NAVIGATE TO CHECKPOINT
  // ============================================================

  void navigateToCheckpoint() {
    final attraction =
        currentAttraction;

    if (!hasGeneratedClue ||
        attraction == null) {
      return;
    }

    // start() clears the old checkpoint's distance/bearing
    // synchronously before its first await.
    //
    // Do this BEFORE exposing the Navigation page so CP2 / CP3
    // can never render CP1's stale distance or Verify state.
    final navigationFuture =
    navigation.start(
      latitude:
      attraction.latitude,
      longitude:
      attraction.longitude,
      checkpointNumber:
      _currentCheckpoint,
    );

    debugPrint(
      '[QUEST NAVIGATION] '
          'Opening CP$_currentCheckpoint -> '
          '${attraction.name}',
    );

    debugPrint(
      '[QUEST NAVIGATION] '
          'Target GPS: '
          '${attraction.latitude.toStringAsFixed(7)}, '
          '${attraction.longitude.toStringAsFixed(7)}',
    );

    _currentStage =
        TripPathQuestStage.navigation;

    notifyListeners();

    unawaited(
      navigationFuture,
    );
  }

  // ============================================================
  // RETRY NAVIGATION
  // ============================================================

  Future<void> retryNavigation() async {
    // Manual refresh only requests one fresh GPS sample.
    //
    // It does not restart the whole navigation session when live
    // tracking is already active, so the screen will not get stuck
    // showing "Calculating distance..." after pressing Refresh.
    await navigation.refreshCurrentLocation();
  }

  // ============================================================
  // OPEN LOCATION SETTINGS
  // ============================================================

  Future<void> openLocationSettings() async {
    await navigation.openLocationSettings();
  }

  // ============================================================
  // OPEN APP SETTINGS
  // ============================================================

  Future<void> openAppSettings() async {
    await navigation.openAppSettings();
  }

  // ============================================================
  // OPEN VISIT VERIFICATION
  // ============================================================

  Future<void> openVerification() async {
    if (!canVerifyVisit ||
        currentAttraction == null ||
        _isPreparingCurrentReferencePhoto) {
      return;
    }

    // New quests already have an in-memory reference photo.
    // Resumed quests intentionally do not persist Google photo
    // resources, so prepare a fresh reference lazily only when the
    // player actually reaches verification.
    final referenceReady =
    await prepareCurrentReferencePhotoIfNeeded();

    if (!referenceReady) {
      return;
    }

    _currentStage =
        TripPathQuestStage.verification;

    notifyListeners();
  }

  // ============================================================
  // FRESH GPS RECHECK BEFORE PHOTO VERIFICATION
  //
  // The live navigation stream may be several seconds old by the time the
  // player presses Verify Photo. Passthrough to a fresh, one-shot GPS sample
  // so a photo taken away from the checkpoint can't rely on stale proximity.
  // ============================================================

  Future<TripPathGpsVerificationCheck> recheckLocationForPhotoVerification() {
    return navigation.recheckForPhotoVerification();
  }

  // ============================================================
  // COMPLETE CURRENT CHECKPOINT
  //
  // Called only after photo verification succeeds.
  //
  // Checkpoint 1 -> artwork progress -> Checkpoint 2
  // Checkpoint 2 -> artwork progress -> Checkpoint 3
  // Checkpoint 3 -> artwork progress becomes 3 / 3
  //
  // Progress is also written to Supabase. The quest header
  // stores completed_checkpoints, current_checkpoint and status;
  // artwork colouring is reconstructed from completed_checkpoints.
  // ============================================================

  Future<bool> completeCurrentCheckpoint() async {
    final completedAttraction =
        currentAttraction;

    if (_currentStage != TripPathQuestStage.verification ||
        _selectedTheme == null ||
        completedAttraction == null ||
        isQuestCompleted ||
        _isCompletingCheckpoint) {
      return false;
    }

    final completedCheckpoint =
        _currentCheckpoint;
    final questId = _activeQuestId?.trim();
    final repository = questProgressRepository;
    final shouldPersist = repository != null;

    if (shouldPersist &&
        (questId == null || questId.isEmpty)) {
      _completionError =
      'This quest has no saved progress ID. Return to the quest start and try again.';
      notifyListeners();
      return false;
    }

    if (shouldPersist && !repository.hasAuthenticatedUser) {
      _completionError =
      'Please sign in again before saving this checkpoint.';
      notifyListeners();
      return false;
    }

    _isCompletingCheckpoint = true;
    _completionError = null;
    notifyListeners();

    try {
      // Persist first. The local artwork/progress state is changed only
      // after completeCheckpoint has read back the updated Supabase row.
      // This is the important ordering fix for the Food 2/3 display bug.
      if (shouldPersist) {
        await repository!.completeCheckpoint(
          questId: questId!,
          checkpointNumber: completedCheckpoint,
          totalCheckpoints: totalCheckpoints,
        );
      }

      // --------------------------------------------------------
      // RECORD VISITED LANDMARK
      //
      // Only happens after verification and checkpoint persistence
      // both succeeded.
      // --------------------------------------------------------

      final placeId = completedAttraction.placeId?.trim();

      if (placeId != null && placeId.isNotEmpty) {
        // Immediate same-session exclusion.
        _sessionVisitedPlaceIds.add(placeId);

        // Persistent cross-session exclusion is independent of the quest
        // header. It is allowed to finish in the background after the
        // completion row has already been confirmed.
        unawaited(
          userLandmarkVisitRepository?.markVisited(
            googlePlaceId: placeId,
            name: completedAttraction.name,
            address: completedAttraction.address,
            primaryType: completedAttraction.placeType,
            latitude: completedAttraction.latitude,
            longitude: completedAttraction.longitude,
            photoResourceName:
            completedAttraction.photoResourceName,
          ) ??
              Future<void>.value(),
        );

        debugPrint(
          '[VISIT HISTORY] Current session marked visited: '
              '${completedAttraction.name}',
        );
      }

      // The quest is sequential, so the current checkpoint number
      // is also the number of checkpoints that should now be done.
      if (_completedCheckpoints < _currentCheckpoint) {
        _completedCheckpoints = _currentCheckpoint;
      }

      if (_completedCheckpoints >= totalCheckpoints) {
        // The Supabase row is now completed, so it must no longer
        // appear in the Continue Previous Game prompt.
        final completedQuestId = _activeQuestId;
        if (completedQuestId != null) {
          _savedQuests = List.unmodifiable(
            _savedQuests
                .where((quest) => quest.id != completedQuestId)
                .toList(growable: false),
          );
        }
        _savedQuest = null;
        _showResumePrompt = false;

        // Report the finished quest to Manage Rewards (UC-06 A7) so it
        // shows up on the Reward Dashboard. This is independent of Trip
        // Path's own already-confirmed Supabase completion above — a
        // failure here should not undo or block the quest the tourist just
        // finished, so it runs in the background rather than being awaited.
        final theme = _selectedTheme;
        final artwork = _selectedArtwork;
        if (completedQuestId != null &&
            theme != null &&
            artwork != null &&
            rewardRepository != null) {
          unawaited(
                () async {
              try {
                await rewardRepository!.storeCompletedThemeSouvenir(
                  touristId: CurrentTourist.id,
                  questId: completedQuestId,
                  theme: theme.name,
                  imageUrl: artwork.imageUrl,
                  completedCheckpoints: _completedCheckpoints,
                  totalCheckpoints: totalCheckpoints,
                  completedAt: DateTime.now(),
                );
              } catch (error) {
                debugPrint(
                  '[QUEST PROGRESS] Reward hookup failed for '
                      '$completedQuestId: $error',
                );
              }
            }(),
          );
        }
      }

      // Navigation is no longer needed after a verified visit.
      unawaited(navigation.stop());

      // Prepare the next checkpoint number only when one remains.
      // On the final checkpoint we keep currentCheckpoint at 3 so
      // existing artwork UI never tries to access checkpoint 4.
      if (_completedCheckpoints < totalCheckpoints &&
          _currentCheckpoint < totalCheckpoints) {
        _currentCheckpoint++;
      }

      _currentStage = TripPathQuestStage.artworkIntro;
      return true;
    } catch (error) {
      // Keep the player on the verification page with the successful
      // photo still available. They can retry the save without retaking
      // the photo, and the artwork cannot show false progress.
      _completionError = _friendlyCompletionError(error);
      debugPrint(
        '[QUEST PROGRESS] Unable to save CP$completedCheckpoint completion: '
            '$error',
      );
      return false;
    } finally {
      _isCompletingCheckpoint = false;
      notifyListeners();
    }
  }

  // ============================================================
  // VIEW QUEST REWARD
  //
  // The final checkpoint first returns to the Artwork page so
  // the user can see the artwork fully restored (3 / 3).
  // From there, this opens the local Quest Complete / Reward page.
  // The completed quest is already persisted in Supabase; this only
  // opens the local reward presentation screen.
  // ============================================================

  void viewQuestReward() {
    if (!isQuestCompleted || _selectedTheme == null) {
      return;
    }

    unawaited(
      navigation.stop(),
    );

    _currentStage =
        TripPathQuestStage.questComplete;

    notifyListeners();
  }

  // ============================================================
  // SAVE & EXIT QUEST
  //
  // Exit is NOT abandon. Keep the current quest in Supabase as
  // in_progress so the same artwork, checkpoints and checkpoint
  // progress can be resumed later.
  // ============================================================

  Future<void> saveAndExitQuest() async {
    if (_isSavingAndExiting || _isCompletingCheckpoint) {
      return;
    }

    _isSavingAndExiting = true;
    notifyListeners();

    unawaited(
      navigation.stop(),
    );

    final questId = _activeQuestId?.trim();
    final repository = questProgressRepository;

    try {
      if (questId != null &&
          questId.isNotEmpty &&
          repository != null &&
          repository.hasAuthenticatedUser &&
          !isQuestCompleted) {
        // Persist the latest checkpoint-level snapshot before leaving.
        // Clue-view index / map zoom are intentionally not persisted.
        await repository.saveInProgressSnapshot(
          questId: questId,
          currentCheckpoint: _currentCheckpoint,
          completedCheckpoints: _completedCheckpoints,
        );

        _savedQuest =
        await repository.getActiveQuestById(questId);
        _savedQuests = List.unmodifiable(
          await repository.getActiveQuests(),
        );
      }
    } catch (error) {
      // The quest was already created and checkpoint completions are
      // persisted when they happen. A failure here should not trap the
      // user inside the quest screen; it mainly affects last_played_at.
      debugPrint(
        '[QUEST PROGRESS] Save & Exit snapshot failed: $error',
      );
    } finally {
      _generationVersion++;

      _selectedTheme = null;
      _selectedArtwork = null;
      _activeQuestId = null;

      _currentCheckpoint = 1;
      _completedCheckpoints = 0;
      _questAttractions = const [];
      _questLocationError = null;
      _isPreparingQuestLocations = false;
      _isPreparingRemainingCheckpoints = false;
      _remainingCheckpointPreparationError = null;
      _pendingBackgroundSearchLatitude = null;
      _pendingBackgroundSearchLongitude = null;
      _isPreparingCurrentReferencePhoto = false;
      _referencePreparationError = null;
      _completionError = null;
      _clearAllClues();

      _showResumePrompt = _savedQuests.isNotEmpty;
      _savedQuest = _savedQuests.isEmpty
          ? null
          : (_savedQuest ?? _savedQuests.first);
      _currentStage = TripPathQuestStage.themeSelection;
      _isSavingAndExiting = false;

      notifyListeners();
    }
  }

  // ============================================================
  // FINISH QUEST
  //
  // The completed quest is already saved in Supabase. This clears
  // only the current in-memory quest presentation state.
  // ============================================================

  void finishQuest() {
    resetQuest();
  }

  // ============================================================
  // GO BACK
  // ============================================================

  void goBack() {
    if (_isCompletingCheckpoint || _isSavingAndExiting) {
      return;
    }

    switch (_currentStage) {
    // ========================================================
    // THEME SELECTION
    // ========================================================

      case TripPathQuestStage.themeSelection:
        break;

    // ========================================================
    // QUEST INFORMATION
    // ========================================================

      case TripPathQuestStage.questInformation:
        unawaited(
          navigation.stop(),
        );

        final hadActiveQuest =
            _activeQuestId != null;

        _generationVersion++;
        _selectedTheme = null;
        _selectedArtwork = null;
        _activeQuestId = null;
        _currentCheckpoint = 1;
        _completedCheckpoints = 0;
        _questAttractions = const [];
        _questLocationError = null;
        _referencePreparationError = null;
        _clearAllClues();
        _currentStage =
            TripPathQuestStage.themeSelection;

        if (hadActiveQuest) {
          // The database row stays in_progress. Once the user exits
          // back to the game entry, reload it and offer Continue.
          unawaited(
            checkForSavedQuest(),
          );
        }

        break;

    // ========================================================
    // ARTWORK INTRO
    // ========================================================

      case TripPathQuestStage.artworkIntro:
        unawaited(
          navigation.stop(),
        );

        // Keep prepared clues, artwork and checkpoints intact. If
        // the user presses Start Quest again on the information page,
        // startQuest() returns to this same active saved quest.
        _currentStage =
            TripPathQuestStage.questInformation;

        break;

    // ========================================================
    // CLUE
    // ========================================================

      case TripPathQuestStage.clue:
        unawaited(
          navigation.stop(),
        );

        // Keep clues already prepared.
        _currentStage =
            TripPathQuestStage.artworkIntro;

        break;

    // ========================================================
    // NAVIGATION
    // ========================================================

      case TripPathQuestStage.navigation:
        unawaited(
          navigation.stop(),
        );

        _currentStage =
            TripPathQuestStage.clue;

        break;

    // ========================================================
    // VERIFICATION
    // ========================================================

      case TripPathQuestStage.verification:
        _completionError = null;
        _currentStage =
            TripPathQuestStage.navigation;

        break;

    // ========================================================
    // QUEST COMPLETE / REWARD
    // ========================================================

      case TripPathQuestStage.questComplete:
        _currentStage =
            TripPathQuestStage.artworkIntro;

        break;
    }

    notifyListeners();
  }

  // ============================================================
  // RESET QUEST
  // ============================================================

  void resetQuest() {
    unawaited(
      navigation.stop(),
    );

    _generationVersion++;

    _selectedTheme = null;
    _selectedArtwork = null;
    _activeQuestId = null;
    _savedQuest = _savedQuests.isEmpty
        ? null
        : _savedQuests.first;
    _showResumePrompt = _savedQuests.isNotEmpty;
    _resumeGameError = null;
    _completionError = null;

    _currentCheckpoint = 1;

    _completedCheckpoints = 0;

    _questAttractions = const [];

    _questLocationError = null;

    _isPreparingQuestLocations = false;
    _isPreparingRemainingCheckpoints = false;
    _remainingCheckpointPreparationError = null;
    _pendingBackgroundSearchLatitude = null;
    _pendingBackgroundSearchLongitude = null;
    _isPreparingCurrentReferencePhoto = false;
    _referencePreparationError = null;

    _clearAllClues();

    _currentStage =
        TripPathQuestStage.themeSelection;

    notifyListeners();
  }

  // ============================================================
  // ARTWORK PRELOAD
  // ============================================================

  /// Best-effort preload — starts the artwork image's network fetch/decode
  /// the moment its URL is known (right when a quest is created or
  /// restored), well before the tourist actually reaches the artwork intro
  /// screen. By the time that screen builds `Image(NetworkImage(sameUrl))`,
  /// Flutter's image cache already has the decoded frame, so it paints
  /// instantly instead of popping in after a visible delay. Fire-and-forget:
  /// a slow/failed fetch here just means the screen falls back to loading it
  /// itself (and showing its own loading spinner) — never blocks anything.
  void _precacheArtworkImage(String? url) {
    final trimmed = url?.trim();
    if (trimmed == null || trimmed.isEmpty) return;
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !const {'http', 'https'}.contains(uri.scheme)) return;

    final stream = NetworkImage(trimmed).resolve(const ImageConfiguration());
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (image, synchronousCall) => stream.removeListener(listener),
      onError: (error, stackTrace) => stream.removeListener(listener),
    );
    stream.addListener(listener);
  }

  // ============================================================
  // CLEAR CLUES
  // ============================================================

  void _clearAllClues() {
    _checkpointClues.clear();

    _checkpointClueErrors.clear();

    _generatingCheckpointVersions.clear();

    _revealedClueCounts.clear();

    _viewingClueIndexes.clear();
  }

  // ============================================================
  // DISPOSE
  // ============================================================

  @override
  void dispose() {
    _disposed = true;

    navigation.removeListener(
      _onNavigationChanged,
    );

    navigation.dispose();

    super.dispose();
  }
}
