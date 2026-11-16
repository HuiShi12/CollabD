import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';

import '../../../Data_layer/repository/Mission Repository/mission.dart';
import '../../../Data_layer/repository/Attraction Repository/attraction.dart';
import '../../../Data_layer/repository/Claimed Places Repository/claimed_places.dart';
import '../../../Data_layer/repository/Map Repository/map.dart';
import '../../../Data_layer/repository/Puzzle Repository/puzzle.dart';
import '../../../Data_layer/repository/Route Repository/route.dart';
import '../../../Data_layer/repository/Visit Proof Repository/visit_proof.dart';
import '../../../Data_layer/repository/Progress Repository/progress.dart';
import '../../../Data_layer/service/Location Service/location.dart';

enum MysteryPuzzleScreenStage {
  /// Transient first stage while checkForSavedSessions() decides whether to
  /// land on `resume` (an unfinished mystery exists) or `intro` (nothing to
  /// resume, so the instructions show immediately before searching nearby).
  entryCheck,
  intro,
  resume,
  options,
  imagePreview,
  puzzle,
  navigate,
  verifyReference,
  reviewPhoto,
  verified,
  error,
}

class MysteryPlacePuzzleGameViewModel extends ChangeNotifier {
  final MissionRepository missionRepository;
  final PuzzleRepository puzzleRepository;
  final RouteRepository routeRepository;
  final VisitProofRepository visitProofRepository;
  final ProgressRepository progressRepository;
  final LocationService locationService;

  /// Optional — absent in existing tests, treated as "nothing claimed yet".
  final ClaimedPlacesRepository? claimedPlacesRepository;

  MysteryPlacePuzzleGameViewModel({
    required this.missionRepository,
    required this.puzzleRepository,
    required this.routeRepository,
    required this.visitProofRepository,
    required this.progressRepository,
    required this.locationService,
    this.claimedPlacesRepository,
    this.preselectedPlaceId,
    this.preselectedPlaceCategory,
    this.preselectedRouteGroup,
    this.preselectedDistanceKm,
    this.nearbyMarkers = const [],
  });

  /// UC-03 FR03_9 — set when the tourist entered through a Proximity Game
  /// marker. The game then skips the "choose 1 of 3" step and goes straight
  /// into that hidden place's puzzle.
  final String? preselectedPlaceId;
  final String? preselectedPlaceCategory;

  /// gm.dart's coarse route group ('food' / 'culture' / 'heritage' /
  /// 'nature') for the preselected place, when known — lets the reference
  /// photo screening reject a photo that looks nothing like that kind of
  /// place (see AttractionRepository.getPuzzleOptionForPlaceId), instead of
  /// accepting any generically outdoor, person-free photo regardless of
  /// whether it's actually this place.
  final String? preselectedRouteGroup;
  final double? preselectedDistanceKm;

  /// The Map screen's already-fetched, already-screened Proximity Game
  /// markers (UC-03), passed straight in when this game was started from the
  /// Puzzle button. Every marker supports Puzzle, so loadNearbyPuzzleOptions()
  /// can hydrate its nearest 3 of these directly instead of re-running the
  /// whole nearby-search-plus-photo-screening pipeline from scratch — that
  /// search already happened once, to produce these markers.
  final List<HiddenPlaceMarker> nearbyMarkers;

  String _touristId = 'tourist_001';

  MysteryPuzzleScreenStage stage = MysteryPuzzleScreenStage.entryCheck;

  bool isLoading = false;
  String? errorMessage;

  MysteryPuzzleMission? currentMission;
  List<MysteryPlaceOption> availableOptions = [];
  MysteryPlaceOption? selectedOption;

  List<PuzzlePieceData> puzzlePieces = [];
  int? selectedPuzzleIndex;
  int hintsLeft = 3;

  bool showHintPreviewImage = false;

  /// Board positions drawn with a red border. Once a hint (1 or 2) or the
  /// per-minute auto-hint turns this on, it recomputes after every swap and
  /// clears itself when the puzzle is solved.
  Set<int> highlightedWrongTiles = <int>{};
  bool _wrongHighlightActive = false;
  Timer? _wrongHighlightTimer;

  /// Seconds the tourist has spent on the current puzzle (driven by the
  /// puzzle screen's 1-second timer). Every full minute auto-marks the wrong
  /// tiles in red.
  int elapsedSeconds = 0;

  Map<String, dynamic>? routeInfo;

  String? sessionId;
  File? capturedPhoto;
  VisitProofResult? verificationResult;
  MysteryGameProgressResult? completedGameResult;

  /// Set the instant a photo verification attempt resolves (match or not) so
  /// the View can show Trip Path's bottom-sheet result card instead of an
  /// inline banner. Cleared by [acknowledgeVerificationOutcome] once the
  /// tourist dismisses that sheet.
  VisitProofResult? verificationOutcomeForSheet;

  /// True while submitPhotoForVerification() is running — shown as an
  /// inline progress indicator on the same Verify Your Visit page (matching
  /// Trip Path Quest's verification page) instead of navigating to a
  /// separate full-screen "Verifying..." stage.
  bool isVerifying = false;

  bool digitalTravelStampRequested = false;
  bool puzzleCheckedSuccessfully = false;

  // ---------- UC-05 save/resume ----------

  bool isCheckingSavedSessions = false;
  bool showResumePrompt = false;
  List<SavedPuzzleSession> savedSessions = [];
  bool isResumingSession = false;

  Future<void>? _pendingSessionsCheck;
  bool _sessionsCheckedOnce = false;

  /// Runs once on view mount — mirrors Trip Path's checkForSavedQuest().
  /// While it's in flight the entry screen shows a brief loading sheet
  /// (stage == entryCheck); once it resolves, stage moves straight to
  /// `resume` if an unfinished mystery was found, or to `intro` otherwise
  /// (a fresh start still gets the instructions first). A repeat call while
  /// one is already in flight returns that same future instead of starting
  /// a second overlapping fetch or silently no-op'ing.
  Future<void> checkForSavedSessions() {
    final pending = _pendingSessionsCheck;
    if (pending != null) return pending;

    final future = _runSavedSessionsCheck();
    _pendingSessionsCheck = future;
    future.whenComplete(() => _pendingSessionsCheck = null);
    return future;
  }

  Future<void> _runSavedSessionsCheck() async {
    isCheckingSavedSessions = true;
    notifyListeners();

    try {
      savedSessions = await progressRepository.getActiveSessions();
      showResumePrompt = savedSessions.isNotEmpty;
    } catch (_) {
      savedSessions = [];
      showResumePrompt = false;
    } finally {
      isCheckingSavedSessions = false;
      _sessionsCheckedOnce = true;

      // Only decide the very first screen here. Once past entryCheck,
      // stage is driven explicitly elsewhere (e.g. startNewMysteryFromResume
      // re-showing Intro), so this must not stomp on that later.
      if (stage == MysteryPuzzleScreenStage.entryCheck) {
        stage = showResumePrompt
            ? MysteryPuzzleScreenStage.resume
            : MysteryPuzzleScreenStage.intro;
      }

      notifyListeners();
    }
  }

  /// "Start New Mystery" on the resume prompt — leaves every saved session in
  /// Supabase untouched, just stops offering them for this visit. Shows the
  /// Intro/rules screen again before searching nearby, same as a tourist
  /// with nothing saved sees on first entry — its "Start Game" button
  /// (proceedFromIntro) picks up from there.
  void startNewMysteryFromResume() {
    showResumePrompt = false;
    stage = MysteryPuzzleScreenStage.intro;
    notifyListeners();
  }

  /// UC-03 FR03_9 — shows the Intro/rules screen for a Proximity Game marker
  /// entry, which already has a specific place chosen (preselectedPlaceId).
  /// Unlike the normal entry paths, this never runs checkForSavedSessions —
  /// there's no "resume this same place" ambiguity to resolve, only ever a
  /// fresh start — so proceedFromIntro() below recognises this case and
  /// skips straight to that place's puzzle instead of routing through
  /// Continue-Your-Mystery.
  void showIntroForPreselectedPlace() {
    stage = MysteryPuzzleScreenStage.intro;
    notifyListeners();
  }

  /// "Start Game" on the Intro/rules screen. A marker entry
  /// (preselectedPlaceId set) goes straight to that place's puzzle. Otherwise,
  /// by the time this screen can be showing, checkForSavedSessions() has
  /// already resolved (it's what routed here in the first place, or
  /// startNewMysteryFromResume() dismissed the resume prompt) — so this
  /// always proceeds straight to the nearby search.
  Future<void> proceedFromIntro(String touristId) async {
    if (preselectedPlaceId != null) {
      await loadNearbyPuzzleOptions(touristId: touristId);
      return;
    }
    // Once the initial background check has completed, trust the cached
    // result rather than re-querying Supabase on every "Start Game" tap.
    if (!_sessionsCheckedOnce) {
      await checkForSavedSessions();
    }
    if (showResumePrompt) {
      stage = MysteryPuzzleScreenStage.resume;
      notifyListeners();
      return;
    }
    await loadNearbyPuzzleOptions(touristId: touristId);
  }

  /// "Continue" on a saved session — restores it and jumps straight past
  /// Choose-a-Mystery / Memorise-the-Image into wherever the tourist left
  /// off (mid-jigsaw, or already solved and mid-navigate).
  Future<void> resumeSession(SavedPuzzleSession saved) async {
    isResumingSession = true;
    notifyListeners();

    selectedOption = MysteryPlaceOption(
      id: saved.hiddenPlaceId,
      name: saved.hiddenPlaceName,
      category: saved.category,
      township: saved.township,
      description: 'A ${saved.category} near you — solve the puzzle to reveal it.',
      latitude: saved.latitude,
      longitude: saved.longitude,
      // Navigate only ever reads the *live* liveDistanceMeters/directionText
      // below, never these — inert placeholders.
      distanceMeter: 0,
      direction: 'Nearby',
      imageUrl: saved.referenceImageUrl,
    );
    sessionId = saved.id;
    showResumePrompt = false;

    if (saved.stage == 'navigate') {
      routeInfo = routeRepository.buildRouteInfo(selectedOption!);
      puzzleCheckedSuccessfully = true;
      stage = MysteryPuzzleScreenStage.navigate;
    } else {
      puzzlePieces = (saved.pieces != null && saved.pieces!.isNotEmpty)
          ? saved.pieces!
          : puzzleRepository.createNinePiecePuzzle();
      hintsLeft = saved.hintsLeft;
      elapsedSeconds = saved.elapsedSeconds;
      selectedPuzzleIndex = null;
      highlightedWrongTiles = <int>{};
      _wrongHighlightActive = false;
      _wrongHighlightTimer?.cancel();
      stage = MysteryPuzzleScreenStage.puzzle;
    }

    isResumingSession = false;
    notifyListeners();

    await progressRepository.touchSession(saved.id);
  }

  /// UC-05 — deep-link entry from Profile / Game History's "Continue"
  /// action: jumps straight into one specific saved session by id, skipping
  /// Intro and the "Continue Your Mystery" picker entirely. Falls back to
  /// the normal saved-sessions flow if that id can no longer be found (e.g.
  /// already completed, or deleted from another device).
  Future<void> resumeSessionById(String sessionId) async {
    isCheckingSavedSessions = true;
    notifyListeners();

    try {
      final sessions = await progressRepository.getActiveSessions();
      final match = sessions.where((s) => s.id == sessionId);

      isCheckingSavedSessions = false;
      _sessionsCheckedOnce = true;

      if (match.isEmpty) {
        savedSessions = sessions;
        if (sessions.isEmpty) {
          stage = MysteryPuzzleScreenStage.error;
          errorMessage = 'This saved game is no longer available.';
        } else {
          showResumePrompt = true;
          stage = MysteryPuzzleScreenStage.resume;
        }
        notifyListeners();
        return;
      }

      await resumeSession(match.first);
    } catch (_) {
      isCheckingSavedSessions = false;
      _sessionsCheckedOnce = true;
      stage = MysteryPuzzleScreenStage.error;
      errorMessage = 'Failed to load your saved game. Please try again.';
      notifyListeners();
    }
  }

  Future<void> loadNearbyPuzzleOptions({String? touristId}) async {
    if (touristId != null) _touristId = touristId;

    try {
      isLoading = true;
      errorMessage = null;
      notifyListeners();

      // UC-03 marker entry — a hidden place is already chosen, so skip the
      // "choose 1 of 3" screen and start that place's puzzle directly. If
      // this specific place turns out to have no usable reference photo (or
      // closed since the map loaded), fall through to the general nearby
      // search below instead of dead-ending the tourist on a single marker
      // — its Google photos/status won't change, so a "Retry" on that error
      // screen would just repeat the identical failure forever.
      String? unusablePreselectedPlaceId;
      if (preselectedPlaceId != null) {
        try {
          final option = await missionRepository.attractionRepository
              .getPuzzleOptionForPlaceId(
            preselectedPlaceId!,
            category: preselectedPlaceCategory ?? 'Hidden Place',
            routeGroup: preselectedRouteGroup,
            distanceKm: preselectedDistanceKm ?? 1.0,
          );
          availableOptions = [option];
          await _startGameWithOption(_touristId, option);
          return;
        } on PlaceUnavailableException {
          unusablePreselectedPlaceId = preselectedPlaceId;
        } on NoEligibleReferencePhotoException {
          unusablePreselectedPlaceId = preselectedPlaceId;
        }
      }

      final claimed = <String>{
        ...await claimedPlacesRepository?.getClaimedPlaceIds() ?? const {},
        if (unusablePreselectedPlaceId != null) unusablePreselectedPlaceId,
      };

      // Fast path: the Map screen already ran the expensive nearby-search +
      // photo-screening pipeline to produce nearbyMarkers. Reuse its
      // nearest 3 (every marker supports Puzzle) instead of paying for that
      // whole search again from scratch.
      final fastOptions = await _hydrateFromNearbyMarkers(claimed);
      if (fastOptions != null) {
        availableOptions = fastOptions;
        stage = MysteryPuzzleScreenStage.options;
        return;
      }

      currentMission = await missionRepository.detectNearbyPuzzleGameMissions(
        excludedPlaceIds: claimed,
      );

      availableOptions = currentMission?.puzzleOptions ?? [];

      if (availableOptions.isEmpty) {
        stage = MysteryPuzzleScreenStage.error;
        errorMessage = 'No nearby puzzle missions were found.';
      } else {
        stage = MysteryPuzzleScreenStage.options;
      }
    } on PlaceUnavailableException {
      stage = MysteryPuzzleScreenStage.error;
      errorMessage =
          'This place is no longer open. Go back to the map and choose another.';
    } on NoEligibleReferencePhotoException {
      stage = MysteryPuzzleScreenStage.error;
      errorMessage =
          "This place doesn't have a usable reference photo yet. Go back to the map and choose another marker.";
    } catch (e) {
      stage = MysteryPuzzleScreenStage.error;
      errorMessage = 'Failed to load nearby puzzle missions.';
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  /// Hydrates up to 3 puzzle options directly from nearbyMarkers' nearest
  /// unclaimed places, skipping the full nearby-search pipeline. Returns
  /// `null` (not just an empty list) when this shortcut can't be used at all
  /// or comes up completely empty, so the caller falls back to the real
  /// search instead of showing "no missions found" just because the map's
  /// markers weren't ready yet or all 3 nearest happened to fail.
  Future<List<MysteryPlaceOption>?> _hydrateFromNearbyMarkers(
    Set<String> excludedPlaceIds,
  ) async {
    if (nearbyMarkers.isEmpty) return null;

    final candidates =
        nearbyMarkers.where((m) => !excludedPlaceIds.contains(m.id)).toList(
          growable: false,
        )
          ..sort((a, b) => a.distanceKm.compareTo(b.distanceKm));

    if (candidates.isEmpty) return null;

    // Try every available marker (not just the nearest 3), in parallel — a
    // marker can now genuinely fail (NoEligibleReferencePhotoException, see
    // AttractionRepository.getPuzzleOptionForPlaceId) instead of always
    // silently succeeding with a placeholder image. Screening only the
    // nearest 3 would let 1-2 failures shrink "Choose a Mystery" below 3
    // options even when further, still-nearby markers were available as a
    // backfill. nearbyMarkers is already a small, bounded list (Map's own
    // search caps it), so this stays cheap.
    final results = await Future.wait(
      candidates.map((marker) async {
        try {
          return await missionRepository.attractionRepository
              .getPuzzleOptionForPlaceId(
            marker.id,
            category: marker.generalCategory,
            routeGroup: marker.routeGroup,
            distanceKm: marker.distanceKm,
          );
        } catch (_) {
          // One marker failing (closed since the map loaded, its photos no
          // longer screen as eligible, etc.) shouldn't sink the others.
          return null;
        }
      }),
    );

    // results preserves candidates' nearest-first order, so this keeps the
    // nearest 3 markers that actually produced a usable option.
    final options =
        results.whereType<MysteryPlaceOption>().take(3).toList();
    return options.isEmpty ? null : options;
  }

  Future<void> chooseOption({
    required String touristId,
    required MysteryPlaceOption option,
  }) async {
    try {
      await _startGameWithOption(touristId, option);
    } catch (e) {
      isLoading = false;
      stage = MysteryPuzzleScreenStage.error;
      errorMessage = 'Failed to start the selected puzzle game.';
      notifyListeners();
    }
  }

  Future<void> _startGameWithOption(
    String touristId,
    MysteryPlaceOption option,
  ) async {
    _touristId = touristId;
    isLoading = true;
    errorMessage = null;
    notifyListeners();

    selectedOption = option;

    sessionId = await progressRepository.createGameSession(
      touristId: touristId,
      selectedOption: option,
    );

    puzzlePieces = puzzleRepository.createNinePiecePuzzle();

    selectedPuzzleIndex = null;
    hintsLeft = 3;
    highlightedWrongTiles = <int>{};
    _wrongHighlightActive = false;
    _wrongHighlightTimer?.cancel();
    elapsedSeconds = 0;
    liveDistanceMeters = null;
    _navTimer?.cancel();
    showHintPreviewImage = false;

    routeInfo = null;
    capturedPhoto = null;
    verificationResult = null;
    completedGameResult = null;
    digitalTravelStampRequested = false;
    puzzleCheckedSuccessfully = false;

    isLoading = false;
    stage = MysteryPuzzleScreenStage.imagePreview;
    notifyListeners();

    await Future.delayed(const Duration(seconds: 5));

    if (selectedOption?.id == option.id &&
        stage == MysteryPuzzleScreenStage.imagePreview) {
      stage = MysteryPuzzleScreenStage.puzzle;
      notifyListeners();
    }
  }

  Future<void> tapPuzzlePiece(int index) async {
    if (selectedPuzzleIndex == null) {
      selectedPuzzleIndex = index;
      notifyListeners();
      return;
    }

    final firstIndex = selectedPuzzleIndex!;
    final secondIndex = index;

    if (firstIndex != secondIndex) {
      puzzlePieces = puzzleRepository.swapPieces(
        pieces: puzzlePieces,
        firstIndex: firstIndex,
        secondIndex: secondIndex,
      );
      _autosaveProgress();
    }

    selectedPuzzleIndex = null;

    // Keep the red marks in sync with the board once a hint has turned them on.
    _recomputeWrongTiles();

    // 这里不自动去下一页。
    // User 必须 click Check，正确才会进入 Navigate page。
    notifyListeners();
  }

  /// UC-05 — fire-and-forget snapshot after a real tile swap or hint use, so
  /// leaving mid-puzzle can resume to the exact same board.
  void _autosaveProgress() {
    final id = sessionId;
    if (id == null) return;
    unawaited(
      progressRepository.saveProgressSnapshot(
        sessionId: id,
        pieces: puzzlePieces,
        hintsLeft: hintsLeft,
        elapsedSeconds: elapsedSeconds,
      ),
    );
  }

  // ---------- Wrong-tile highlighting (hints 1 & 2 + per-minute auto-hint) ---

  /// Marks every out-of-place tile red for 5 seconds, then clears it.
  /// Called by hint 1, hint 2 and the per-minute auto-hint.
  void revealWrongTiles({bool auto = false}) {
    _wrongHighlightTimer?.cancel();

    final wrong = puzzleRepository.getWrongPieceIndices(puzzlePieces);
    if (wrong.isEmpty) {
      _wrongHighlightActive = false;
      highlightedWrongTiles = <int>{};
      errorMessage = 'Every tile is in place. Press Check to confirm.';
      notifyListeners();
      return;
    }

    _wrongHighlightActive = true;
    highlightedWrongTiles = wrong;
    errorMessage = auto
        ? 'Auto-hint: the tiles still out of place are marked in red for 5s.'
        : 'Incorrect tiles are marked in red for 5s — remember them and swap.';
    notifyListeners();

    _wrongHighlightTimer = Timer(const Duration(seconds: 5), () {
      _wrongHighlightActive = false;
      highlightedWrongTiles = <int>{};
      notifyListeners();
    });
  }

  void _recomputeWrongTiles() {
    if (!_wrongHighlightActive) return;
    highlightedWrongTiles = puzzleRepository.getWrongPieceIndices(puzzlePieces);
    if (highlightedWrongTiles.isEmpty) {
      _wrongHighlightActive = false;
      _wrongHighlightTimer?.cancel();
    }
  }

  @override
  void dispose() {
    _wrongHighlightTimer?.cancel();
    _navTimer?.cancel();
    super.dispose();
  }

  /// Called once per second by the puzzle screen's timer.
  void registerElapsedSecond() {
    if (stage != MysteryPuzzleScreenStage.puzzle) return;
    elapsedSeconds++;
    if (elapsedSeconds % 60 == 0) {
      revealWrongTiles(auto: true);
    } else {
      notifyListeners();
    }
  }

  Future<void> checkPuzzleSolved() async {
    if (selectedOption == null) {
      errorMessage = 'No selected puzzle game.';
      notifyListeners();
      return;
    }

    if (sessionId == null) {
      errorMessage = 'Game session was not created.';
      notifyListeners();
      return;
    }

    final solved = puzzleRepository.isPuzzleSolved(puzzlePieces);

    if (!solved) {
      errorMessage =
          'Puzzle is not solved yet. Please continue swapping the tiles.';
      _recomputeWrongTiles();
      notifyListeners();
      return;
    }

    try {
      isLoading = true;
      errorMessage = null;
      highlightedWrongTiles = <int>{};
      _wrongHighlightActive = false;
      _wrongHighlightTimer?.cancel();
      notifyListeners();

      await progressRepository.savePuzzleCompleted(sessionId: sessionId!);

      routeInfo = routeRepository.buildRouteInfo(selectedOption!);

      puzzleCheckedSuccessfully = true;
      stage = MysteryPuzzleScreenStage.navigate;
    } catch (e) {
      stage = MysteryPuzzleScreenStage.error;
      errorMessage = 'Failed to save puzzle completion.';
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<void> useHint() async {
    if (hintsLeft <= 0) {
      errorMessage = 'No hints left.';
      notifyListeners();
      return;
    }

    final usedHintNumber = 4 - hintsLeft;
    hintsLeft--;
    _autosaveProgress();

    // Hint 1 & Hint 2 — mark every tile that is out of place in red.
    if (usedHintNumber == 1 || usedHintNumber == 2) {
      revealWrongTiles();
      return;
    }

    // Hint 3：显示原图 2 秒
    if (usedHintNumber == 3) {
      errorMessage = 'Hint 3: The original image will be shown for 2 seconds.';
      showHintPreviewImage = true;
      notifyListeners();

      await Future.delayed(const Duration(seconds: 5));

      showHintPreviewImage = false;
      notifyListeners();
      return;
    }
  }

  void clearMessage() {
    errorMessage = null;
    notifyListeners();
  }

  // ---------- Navigate stage: live distance to the real place ----------

  /// Straight-line metres from the tourist's current GPS to the mystery place,
  /// refreshed every few seconds while the Navigate screen is open.
  double? liveDistanceMeters;

  /// Compass bearing (0-360, 0 = north) from the tourist to the mystery
  /// place, refreshed alongside [liveDistanceMeters].
  double? bearingDegrees;

  /// The tourist's last known GPS position (for the Navigate map marker).
  double? currentLat;
  double? currentLng;

  Timer? _navTimer;

  static const int verificationRangeMeters = 50;

  bool get navigationArrived =>
      liveDistanceMeters != null &&
      liveDistanceMeters! <= verificationRangeMeters;

  /// 8-point compass label for [bearingDegrees] (e.g. "North-East"), same
  /// scheme Trip Path's navigation uses.
  String get directionText {
    final bearing = bearingDegrees;
    if (bearing == null) return 'Finding direction...';
    final normalized = (bearing + 360) % 360;
    if (normalized >= 337.5 || normalized < 22.5) return 'North';
    if (normalized < 67.5) return 'North-East';
    if (normalized < 112.5) return 'East';
    if (normalized < 157.5) return 'South-East';
    if (normalized < 202.5) return 'South';
    if (normalized < 247.5) return 'South-West';
    if (normalized < 292.5) return 'West';
    return 'North-West';
  }

  void startNavigationTracking() {
    _navTimer?.cancel();
    _refreshDistance();
    _navTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _refreshDistance(),
    );
  }

  void stopNavigationTracking() {
    _navTimer?.cancel();
    _navTimer = null;
  }

  Future<void> _refreshDistance() async {
    final option = selectedOption;
    if (option == null) return;
    final pos = await locationService.getCurrentPosition();
    if (pos != null) {
      currentLat = pos['latitude'];
      currentLng = pos['longitude'];
      liveDistanceMeters = Geolocator.distanceBetween(
        pos['latitude']!,
        pos['longitude']!,
        option.latitude,
        option.longitude,
      );
      bearingDegrees = Geolocator.bearingBetween(
        pos['latitude']!,
        pos['longitude']!,
        option.latitude,
        option.longitude,
      );
    } else {
      liveDistanceMeters = null;
      bearingDegrees = null;
    }
    notifyListeners();
  }

  /// Final, fresh GPS check run right when "Verify Photo" is tapped — same
  /// safeguard Trip Path Quest's verification page runs before its own
  /// OpenCV/Gemini comparison. The Navigate button itself only ever unlocks
  /// once [navigationArrived] is true from a real GPS reading (no demo
  /// shortcut, matching Trip Path Quest exactly), and this recheck runs
  /// again right before submission as a fresh-GPS safety net in case the
  /// tourist stepped away between unlocking the button and taking the
  /// photo. Returns null when clear to proceed, or a message to show (e.g.
  /// in a SnackBar) when not.
  Future<String?> recheckDistanceForVerification() async {
    final option = selectedOption;
    if (option == null) return null;

    final pos = await locationService.getCurrentPosition();
    if (pos == null) {
      return 'Your location cannot be detected. Enable GPS and try again.';
    }

    final distance = Geolocator.distanceBetween(
      pos['latitude']!,
      pos['longitude']!,
      option.latitude,
      option.longitude,
    );
    currentLat = pos['latitude'];
    currentLng = pos['longitude'];
    liveDistanceMeters = distance;
    notifyListeners();

    if (distance > verificationRangeMeters) {
      return 'You are no longer close enough to this mystery location. '
          'Move within $verificationRangeMeters m before verifying the photo.';
    }
    return null;
  }

  void goToVerifyReference() {
    if (selectedOption == null) {
      errorMessage = 'No selected mystery location.';
      notifyListeners();
      return;
    }

    stage = MysteryPuzzleScreenStage.verifyReference;
    notifyListeners();
  }

  void goToNavigate() {
    if (selectedOption == null) {
      errorMessage = 'No selected mystery location.';
      notifyListeners();
      return;
    }

    stage = MysteryPuzzleScreenStage.navigate;
    notifyListeners();
  }

  Future<void> takePhoto() async {
    try {
      final picker = ImagePicker();

      final XFile? image = await picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 85,
      );

      if (image == null) return;

      capturedPhoto = File(image.path);
      stage = MysteryPuzzleScreenStage.reviewPhoto;

      notifyListeners();
    } catch (e) {
      stage = MysteryPuzzleScreenStage.error;
      errorMessage = 'Failed to open camera.';
      notifyListeners();
    }
  }

  Future<void> submitPhotoForVerification({required String touristId}) async {
    if (selectedOption == null) {
      errorMessage = 'No selected mystery location.';
      notifyListeners();
      return;
    }

    if (sessionId == null) {
      errorMessage = 'Game session was not created.';
      notifyListeners();
      return;
    }

    if (capturedPhoto == null) {
      errorMessage = 'Please capture a landmark photo first.';
      notifyListeners();
      return;
    }

    // Stays on this same page throughout — an inline progress indicator
    // (vm.isVerifying) replaces the old separate "Verifying..." stage/
    // screen, matching Trip Path Quest's verification page.
    isVerifying = true;
    errorMessage = null;
    notifyListeners();

    try {
      verificationResult = await visitProofRepository.verifyVisit(
        option: selectedOption!,
        capturedPhoto: capturedPhoto!,
        // recheckDistanceForVerification() already enforced the real 50 m
        // GPS gate unconditionally right before this call is even reached
        // (matching Trip Path Quest's own verifyVisit-equivalent).
      );

      if (verificationResult == null) {
        // Verification couldn't even run (network/GPS issue) — no result to
        // show in the Trip-Path-style sheet, fall back to the inline banner.
        errorMessage = 'Visit verification failed.';
        capturedPhoto = null;
        stage = MysteryPuzzleScreenStage.verifyReference;
        return;
      }

      if (!verificationResult!.isSuccess) {
        // Photo didn't match / still out of range — reset back to the
        // "take a photo" screen underneath, then surface the reason via the
        // Trip-Path-style result sheet instead of an inline banner.
        capturedPhoto = null;
        stage = MysteryPuzzleScreenStage.verifyReference;
        verificationOutcomeForSheet = verificationResult;
        return;
      }

      completedGameResult = await progressRepository
          .saveVisitVerifiedAndCompleteGame(
            sessionId: sessionId!,
            touristId: touristId,
            selectedOption: selectedOption!,
            visitProofResult: verificationResult!,
          );

      digitalTravelStampRequested = true;
      // Hold off on the celebration screen until the tourist dismisses the
      // matched result sheet (see acknowledgeVerificationOutcome) — the
      // Digital Travel Stamp is already saved above regardless of when that
      // happens.
      verificationOutcomeForSheet = verificationResult;
    } catch (e) {
      // Keep the tourist on the verify screen so a retry doesn't wipe their
      // puzzle progress (the error screen's "Retry" restarts the whole game).
      errorMessage =
          'Visit completion or Digital Travel Stamp saving failed. Please '
          'check your connection and take the photo again. $e';
      capturedPhoto = null;
      verificationResult = null;
      stage = MysteryPuzzleScreenStage.verifyReference;
    } finally {
      isVerifying = false;
      notifyListeners();
    }
  }

  /// Dismisses the Trip-Path-style result sheet shown after a verification
  /// attempt. A matched result advances to the celebration screen; a
  /// non-matched one already reset back to verifyReference when it arrived,
  /// so this just closes the sheet.
  void acknowledgeVerificationOutcome() {
    final outcome = verificationOutcomeForSheet;
    verificationOutcomeForSheet = null;
    if (outcome != null && outcome.isSuccess) {
      stage = MysteryPuzzleScreenStage.verified;
    }
    notifyListeners();
  }

  void retakePhoto() {
    capturedPhoto = null;
    verificationResult = null;
    stage = MysteryPuzzleScreenStage.verifyReference;
    notifyListeners();
  }

  void resetToOptions() {
    selectedOption = null;
    puzzlePieces = [];
    selectedPuzzleIndex = null;
    hintsLeft = 3;
    highlightedWrongTiles = <int>{};
    _wrongHighlightActive = false;
    _wrongHighlightTimer?.cancel();
    elapsedSeconds = 0;
    liveDistanceMeters = null;
    _navTimer?.cancel();
    showHintPreviewImage = false;

    routeInfo = null;
    sessionId = null;
    capturedPhoto = null;
    verificationResult = null;
    completedGameResult = null;
    digitalTravelStampRequested = false;
    errorMessage = null;

    stage = MysteryPuzzleScreenStage.options;
    notifyListeners();
  }
}
