import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'UI_layer/view/Manage Reward  View/reward.dart';
import 'UI_layer/viewmodel/Manage Reward  ViewModel/reward_viewmodel.dart';

import 'External_services/Google Maps Platform and Location Services/gm.dart';
import 'External_services/Gemini API/g.dart';
import 'External_services/Supabase/s.dart';
import 'External_services/Supabase Auth/sa.dart';

import 'Data_layer/service/Location Service/location.dart';
import 'Data_layer/service/Navigation Service/navigation.dart';
import 'Data_layer/service/Image Service/image.dart';
import 'Data_layer/service/Gemini Service/gemini.dart';
import 'Data_layer/service/Supabase Service/supabase.dart';
import 'Data_layer/service/Supabase Auth Service/supabase_auth.dart';

import 'Data_layer/repository/Attraction Repository/attraction.dart';
import 'Data_layer/repository/Claimed Places Repository/claimed_places.dart';
import 'Data_layer/repository/Mission Repository/mission.dart';
import 'Data_layer/repository/Puzzle Repository/puzzle.dart';
import 'Data_layer/repository/Route Repository/route.dart';
import 'Data_layer/repository/Visit Proof Repository/visit_proof.dart';
import 'Data_layer/repository/Progress Repository/progress.dart';
import 'Data_layer/repository/Reward Repository/reward_repository.dart';
import 'Data_layer/repository/Map Repository/map.dart';
import 'Data_layer/repository/User Repository/user.dart';

import 'UI_layer/viewmodel/Mystery Place Puzzle Game ViewModel/mystery_place_puzzle_game_viewmodel.dart';
import 'UI_layer/viewmodel/Authentication Login ViewModel/auth_viewmodel.dart';
import 'UI_layer/viewmodel/Manage Profile ViewModel/profile_viewmodel.dart';
import 'UI_layer/viewmodel/Chatbot ViewModel/chatbot_viewmodel.dart';

/// Wires the shared external services, data-layer services and repositories.
///
/// Kept in its own file (rather than main.dart, where it originated) so
/// screens outside the Map flow — Profile's Game & Place History, in
/// particular — can hold a reference and launch Puzzle/Trip Path/Rewards
/// themselves without main.dart having to import those screens back
/// (which would create an import cycle).
class AppDependencies {
  AppDependencies() {
    // Real device GPS + (when --dart-define=GOOGLE_MAPS_API_KEY=… is supplied)
    // real nearby attractions from the Google Places API.
    final googleMapsExternal = GoogleMapsPlatformExternal(
      useDeviceServices: true,
    );
    final geminiApiExternal = GeminiApiExternal();
    final supabaseExternal = SupabaseExternal(Supabase.instance.client);
    final supabaseAuthExternal = SupabaseAuthExternal();

    locationService = LocationService(googleMapsExternal);
    final navigationService = NavigationService();
    final imageService = ImageService();
    geminiService = GeminiService(geminiApiExternal);
    final supabaseService = SupabaseService(supabaseExternal);
    final supabaseAuthService = SupabaseAuthService(supabaseAuthExternal);

    final attractionRepository =
    AttractionRepository(locationService, geminiService);
    _missionRepository = MissionRepository(attractionRepository);
    _puzzleRepository = PuzzleRepository();
    _routeRepository = RouteRepository(navigationService);
    _visitProofRepository = VisitProofRepository(
      locationService: locationService,
      imageService: imageService,
      supabaseService: supabaseService,
    );
    _rewardRepository = RewardRepository(
      supabaseService: supabaseService,
      geminiService: geminiService,
      imageService: imageService,
    );
    _progressRepository = ProgressRepository(
      missionRepository: _missionRepository,
      visitProofRepository: _visitProofRepository,
      supabaseService: supabaseService,
      rewardRepository: _rewardRepository,
    );

    mapRepository = MapRepository(locationService, geminiService: geminiService);
    claimedPlacesRepository =
        ClaimedPlacesRepository(client: Supabase.instance.client);

    final userRepository = UserRepository(supabaseAuthService);
    authViewModel = AuthenticationViewModel(userRepository);
    profileViewModel = ManageProfileViewModel(userRepository);

    rewardViewModel = RewardViewModel(rewardRepository: _rewardRepository);
  }

  late final LocationService locationService;
  late final MapRepository mapRepository;
  late final ClaimedPlacesRepository claimedPlacesRepository;
  late final GeminiService geminiService;
  late final AuthenticationViewModel authViewModel;
  late final ManageProfileViewModel profileViewModel;
  late final RewardViewModel rewardViewModel;

  late final MissionRepository _missionRepository;
  late final PuzzleRepository _puzzleRepository;
  late final RouteRepository _routeRepository;
  late final VisitProofRepository _visitProofRepository;
  late final ProgressRepository _progressRepository;
  late final RewardRepository _rewardRepository;

  /// Exposed read-only so screens outside Map (Profile's Game & Place
  /// History, resuming a Trip Path Quest directly) can hand it to
  /// TripPathQuestModule the same way main.dart's own Map-entry path does,
  /// without needing their own separate instance.
  RewardRepository get rewardRepository => _rewardRepository;

  MysteryPlacePuzzleGameViewModel createPuzzleViewModel({
    String? placeId,
    String? placeCategory,
    double? distanceKm,
  }) {
    return MysteryPlacePuzzleGameViewModel(
      missionRepository: _missionRepository,
      puzzleRepository: _puzzleRepository,
      routeRepository: _routeRepository,
      visitProofRepository: _visitProofRepository,
      progressRepository: _progressRepository,
      locationService: locationService,
      claimedPlacesRepository: claimedPlacesRepository,
      preselectedPlaceId: placeId,
      preselectedPlaceCategory: placeCategory,
      preselectedDistanceKm: distanceKm,
    );
  }

  RewardViewModel createRewardViewModel() => rewardViewModel;

  /// UC-04 AI Assistant Chat.
  ChatbotViewModel createChatbotViewModel() {
    return ChatbotViewModel(
      locationService: locationService,
      geminiService: geminiService,
    );
  }

  /// Opens the Reward Dashboard. A plain top-level push (no MapViewModel
  /// reload afterward) — callers that need the map marker refreshed too
  /// (Map's own entry point) wrap this instead of using it directly.
  Future<void> openRewards(BuildContext context) {
    rewardViewModel.loadRewards();
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChangeNotifierProvider.value(
          value: rewardViewModel,
          child: const ManageRewardView(),
        ),
      ),
    );
  }
}
