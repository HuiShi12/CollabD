import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../main.dart';
import '../../../Data_layer/repository/Claimed Places Repository/claimed_places.dart';
import '../../../Data_layer/repository/Reward Repository/reward_repository.dart';
import '../../../Data_layer/repository/Trip Path Quest Repository/landmark_clue_repository.dart';
import '../../../Data_layer/repository/Trip Path Quest Repository/theme_artwork_repository.dart';
import '../../../Data_layer/repository/Trip Path Quest Repository/trip_path_attraction_repository.dart';
import '../../../Data_layer/repository/Trip Path Quest Repository/trip_path_quest_progress_repository.dart';
import '../../../Data_layer/repository/Trip Path Quest Repository/user_landmark_visit_repository.dart';
import '../../../Data_layer/service/Trip Path Quest Service/gemini_photo_verification.dart';
import '../../../Data_layer/service/Trip Path Quest Service/trip_path_gemini_api.dart';
import '../../../Data_layer/service/Trip Path Quest Service/trip_path_gemini_service.dart';
import '../../../Data_layer/service/Trip Path Quest Service/trip_path_location_service.dart';
import '../../../Data_layer/service/Trip Path Quest Service/trip_path_places_service.dart';
import '../../../Data_layer/service/Trip Path Quest Service/trip_path_reference_photo_service.dart';
import 'trip_path_quest.dart';
import '../../viewmodel/Trip Path Quest Game ViewModel/trip_path_quest_navigation.dart';
import '../../viewmodel/Trip Path Quest Game ViewModel/trip_path_quest_viewmodel.dart';

/// Self-contained entry point for **UC-05 Trip Path Quest**.
///
/// Trip Path was contributed as a fork with its own rewritten copies of the
/// shared services (Places / Gemini / Location / Attraction). To avoid a
/// foundational merge that would disturb Map / Puzzle / Chatbot / Profile, that
/// whole dependency graph is vendored under the `Trip Path Quest *` folders and
/// wired up here in isolation — the rest of the app only ever imports this
/// widget.
class TripPathQuestModule extends StatefulWidget {
  const TripPathQuestModule({
    super.key,
    this.onExit,
    this.initialLatitude,
    this.initialLongitude,
    this.initialThemeId,
    this.initialQuestId,
    this.rewardRepository,
    this.onRewards,
  });

  /// Called when the tourist leaves the quest (used to pop back to the map).
  final VoidCallback? onExit;

  /// Shared with the rest of the app (constructed in main.dart) so that
  /// finishing a real quest actually creates a Theme Souvenir reward,
  /// instead of only updating Trip Path's own isolated progress tables.
  /// Optional so this module still works standalone (e.g. in tests) without
  /// pulling in the whole app's dependency graph.
  final RewardRepository? rewardRepository;

  /// Opens the Reward Dashboard from the Quest Complete screen.
  final void Function(BuildContext)? onRewards;

  /// The tourist position the Map screen already fetched (UC-03's
  /// [MapGameHandoff]). When supplied, the very first nearby-attraction
  /// search reuses this fix instead of Trip Path taking its own independent
  /// GPS reading — keeping the checkpoints/photos it finds consistent with
  /// what Map was already showing, rather than drifting to a different spot.
  final double? initialLatitude;
  final double? initialLongitude;

  /// FR03_9 — when the tourist entered from a specific Map marker (not the
  /// Theme button), this is that marker's Trip Path theme id ('food' /
  /// 'culture' / 'heritage' / 'nature'). Always skips straight past
  /// Resume/Theme Selection into that theme's Quest Information, instead of
  /// making the tourist re-browse and pick a theme they already chose by
  /// tapping the marker — even when a quest is already pending elsewhere.
  /// This never touches or deletes any existing saved quest (same as
  /// "Start New Quest" on the resume screen); it only starts a fresh one for
  /// the marker's theme.
  final String? initialThemeId;

  /// Exact in-progress quest chosen from Game & Place History.
  final String? initialQuestId;

  @override
  State<TripPathQuestModule> createState() => _TripPathQuestModuleState();
}

class _TripPathQuestModuleState extends State<TripPathQuestModule> {
  static const _geminiKey = String.fromEnvironment('GEMINI_API_KEY');
  static const _geminiBackupKey =
      String.fromEnvironment('GEMINI_API_KEY_BACKUP');
  static const _placesKey = String.fromEnvironment('GOOGLE_MAPS_API_KEY');

  late final GeminiApi _geminiApi;
  late final GoogleMapsPlatformService _placesService;
  late final TripPathReferencePhotoService _referencePhotoService;
  late final TripPathQuestNavigation _navigation;
  late final TripPathQuestViewModel _viewModel;

  @override
  void initState() {
    super.initState();

    final client = Supabase.instance.client;
    final locationService = LocationService();

    final seedLatitude = widget.initialLatitude;
    final seedLongitude = widget.initialLongitude;
    if (seedLatitude != null && seedLongitude != null) {
      locationService.seedQuestSearchLocation(
        CurrentLocation(
          latitude: seedLatitude,
          longitude: seedLongitude,
          // Map's own fix is high-accuracy (see gm.dart); this is a
          // reasonable placeholder since CurrentLocation always carries one.
          accuracy: 15,
        ),
      );
    }

    _geminiApi = GeminiApi(
      apiKey: _geminiKey,
      backupApiKey: _geminiBackupKey,
    );
    _placesService = GoogleMapsPlatformService(apiKey: _placesKey);
    _referencePhotoService = TripPathReferencePhotoService(
      googleMapsPlatformService: _placesService,
      // Reuses the same GeminiApi instance (and its key/backup-key
      // failover) already configured above, rather than spinning up a
      // second http.Client just for this occasional second-opinion call.
      aiSecondOpinionService: GeminiPhotoVerificationService(api: _geminiApi),
    );
    _navigation = TripPathQuestNavigation(locationService: locationService);

    _viewModel = TripPathQuestViewModel(
      geminiService: GeminiService(geminiApi: _geminiApi),
      navigation: _navigation,
      attractionRepository: AttractionRepository(
        googleMapsPlatformService: _placesService,
        locationService: locationService,
        referencePhotoService: _referencePhotoService,
        // Only used as a same-real-world-site dedup fallback for ambiguous
        // name-similarity pairs — see AttractionRepository.geminiService.
        geminiService: GeminiService(geminiApi: _geminiApi),
      ),
      landmarkClueRepository: LandmarkClueRepository(client: client),
      userLandmarkVisitRepository: UserLandmarkVisitRepository(client: client),
      themeArtworkRepository: ThemeArtworkRepository(client: client),
      questProgressRepository: TripPathQuestProgressRepository(client: client),
      claimedPlacesRepository: ClaimedPlacesRepository(client: client),
      rewardRepository: widget.rewardRepository,
    );

    final themeId = widget.initialThemeId;
    if (themeId != null) {
      unawaited(_autoSelectTheme(themeId));
    }
  }

  /// See [TripPathQuestModule.initialThemeId]. Waits for the saved-quest
  /// check the theme-selection screen itself depends on (so that state is
  /// still populated correctly for e.g. Game History elsewhere), but always
  /// proceeds to Quest Information regardless of what it finds — a marker
  /// entry never shows the resume prompt.
  Future<void> _autoSelectTheme(String themeId) async {
    await _viewModel.checkForSavedQuest();
    if (!mounted) return;

    for (final theme in _viewModel.availableThemes) {
      if (theme.id == themeId) {
        _viewModel.selectTheme(theme, fromMarker: true);
        return;
      }
    }
  }

  @override
  void dispose() {
    // TripPathQuestViewModel.dispose() also detaches + disposes the navigation.
    _viewModel.dispose();
    unawaited(_referencePhotoService.dispose());
    _placesService.dispose();
    _geminiApi.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Trip Path's screens are designed light-only, and its ~8k lines of UI use
    // raw TextStyle() (no fontFamily). Pinning the subtree to AppTheme.light()
    // gives it CollabD's Poppins/Inter text theme and brand colours, and keeps
    // its light screens readable even when the rest of the app is in dark mode.
    return Theme(
      data: AppTheme.light(),
      child: TripPathQuestView(
        viewModel: _viewModel,
        initialQuestId: widget.initialQuestId,
        onExitQuest: widget.onExit,
        onRewards: widget.onRewards,
      ),
    );
  }
}
