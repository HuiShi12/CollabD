import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'UI_layer/view/Manage Reward  View/reward.dart';
import 'UI_layer/view/Trip Path Quest Game View/trip_path_module.dart';
import 'UI_layer/viewmodel/Manage Reward  ViewModel/reward_viewmodel.dart';
import 'Data_layer/repository/User Repository/current_tourist.dart';

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

import 'UI_layer/view/Map View/map.dart';
import 'UI_layer/viewmodel/Map ViewModel/map_viewmodel.dart';
import 'UI_layer/view/Mystery Place Puzzle Game View/mystery_place_puzzle_game.dart';
import 'UI_layer/viewmodel/Mystery Place Puzzle Game ViewModel/mystery_place_puzzle_game_viewmodel.dart';
import 'UI_layer/view/Authentication Login View/login_view.dart';
import 'UI_layer/view/Authentication Login View/register_view.dart';
import 'UI_layer/view/Authentication Login View/forgot_password_view.dart';
import 'UI_layer/viewmodel/Authentication Login ViewModel/auth_viewmodel.dart';
import 'UI_layer/view/Manage Profile View/manage_profile_view.dart';
import 'UI_layer/viewmodel/Manage Profile ViewModel/profile_viewmodel.dart';
import 'UI_layer/view/Chatbot View/chatbot.dart';
import 'UI_layer/viewmodel/Chatbot ViewModel/chatbot_viewmodel.dart';

// ============================================================
// THEME
//
// The app's whole theme system (colours, spacing, ThemeData assembly, the
// context.colors/appColors/text shortcuts, the light/dark/system controller,
// shared button affordances and the appearance-picker sheet) lives directly
// in this file rather than its own UI_layer/theme/ package, so UI_layer only
// ever contains view/ and viewmodel/.
// ============================================================

/// Brand palette — Tailwind Sky + Slate, plus the "night explorer" navy family
/// the immersive screens use. Reference only; screens should read colours from
/// [ColorScheme] or [AppColors], never from here directly.
abstract final class Brand {
  // Sky
  static const sky300 = Color(0xFF7DD3FC);
  static const sky400 = Color(0xFF38BDF8);
  static const sky500 = Color(0xFF0EA5E9);
  static const sky600 = Color(0xFF0284C7);
  static const sky700 = Color(0xFF0369A1);
  static const accentCyan = Color(0xFF1FB1FF);

  // Slate
  static const slate50 = Color(0xFFF8FAFC);
  static const slate100 = Color(0xFFF1F5F9);
  static const slate200 = Color(0xFFE2E8F0);
  static const slate400 = Color(0xFF94A3B8);
  static const slate500 = Color(0xFF64748B);
  static const slate700 = Color(0xFF334155);
  static const slate800 = Color(0xFF1E293B);
  static const slate900 = Color(0xFF0F172A);

  // Night navy (immersive surfaces)
  static const navy950 = Color(0xFF03152E);
  static const navy900 = Color(0xFF041428);
  static const navy800 = Color(0xFF0B203A);
  static const navy700 = Color(0xFF0E3A6E);

  // Semantic
  static const green600 = Color(0xFF16A34A);
  static const amber500 = Color(0xFFF59E0B);
  static const red600 = Color(0xFFDC2626);
}

/// App-specific colour roles that Material's [ColorScheme] doesn't provide.
/// Read via `Theme.of(context).extension<AppColors>()!` or `context.appColors`.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.success,
    required this.onSuccess,
    required this.successSurface,
    required this.warning,
    required this.warningSurface,
    required this.accent,
    required this.onAccent,
    required this.brandGradient,
    required this.heroGradient,
    required this.onHero,
    required this.heroMuted,
    required this.mapPanel,
    required this.onMapPanel,
    required this.mapPanelMuted,
    required this.marker,
    required this.markerSelected,
  });

  final Color success;
  final Color onSuccess;
  final Color successSurface;
  final Color warning;
  final Color warningSurface;

  /// Bright cyan game highlight (send buttons, active states).
  final Color accent;
  final Color onAccent;

  /// Fill for the primary call-to-action button.
  final List<Color> brandGradient;

  /// Full-bleed background of the auth / game hero areas.
  final List<Color> heroGradient;
  final Color onHero;
  final Color heroMuted;

  /// Cards / chips floating on top of the map — must stay legible over any tile.
  final Color mapPanel;
  final Color onMapPanel;
  final Color mapPanelMuted;

  final Color marker;
  final Color markerSelected;

  static const light = AppColors(
    success: Brand.green600,
    onSuccess: Colors.white,
    successSurface: Color(0xFFF0FDF4),
    warning: Brand.amber500,
    warningSurface: Color(0xFFFFFBEB),
    accent: Brand.sky600,
    onAccent: Colors.white,
    brandGradient: [Brand.sky500, Brand.sky600],
    heroGradient: [Color(0xFFE8F4FB), Color(0xFFCDE7F7)],
    onHero: Brand.slate900,
    heroMuted: Brand.slate500,
    mapPanel: Colors.white,
    onMapPanel: Brand.slate900,
    mapPanelMuted: Brand.slate500,
    marker: Brand.sky600,
    markerSelected: Brand.sky700,
  );

  static const dark = AppColors(
    success: Color(0xFF34D399),
    onSuccess: Color(0xFF04231A),
    successSurface: Color(0xFF0C2A22),
    warning: Color(0xFFFBBF24),
    warningSurface: Color(0xFF2A2410),
    accent: Brand.accentCyan,
    onAccent: Brand.navy950,
    brandGradient: [Brand.sky400, Brand.sky500],
    heroGradient: [Brand.navy950, Brand.navy700],
    onHero: Colors.white,
    heroMuted: Brand.sky300,
    mapPanel: Brand.navy800,
    onMapPanel: Colors.white,
    mapPanelMuted: Brand.slate400,
    marker: Brand.accentCyan,
    markerSelected: Brand.sky300,
  );

  @override
  AppColors copyWith({
    Color? success,
    Color? onSuccess,
    Color? successSurface,
    Color? warning,
    Color? warningSurface,
    Color? accent,
    Color? onAccent,
    List<Color>? brandGradient,
    List<Color>? heroGradient,
    Color? onHero,
    Color? heroMuted,
    Color? mapPanel,
    Color? onMapPanel,
    Color? mapPanelMuted,
    Color? marker,
    Color? markerSelected,
  }) {
    return AppColors(
      success: success ?? this.success,
      onSuccess: onSuccess ?? this.onSuccess,
      successSurface: successSurface ?? this.successSurface,
      warning: warning ?? this.warning,
      warningSurface: warningSurface ?? this.warningSurface,
      accent: accent ?? this.accent,
      onAccent: onAccent ?? this.onAccent,
      brandGradient: brandGradient ?? this.brandGradient,
      heroGradient: heroGradient ?? this.heroGradient,
      onHero: onHero ?? this.onHero,
      heroMuted: heroMuted ?? this.heroMuted,
      mapPanel: mapPanel ?? this.mapPanel,
      onMapPanel: onMapPanel ?? this.onMapPanel,
      mapPanelMuted: mapPanelMuted ?? this.mapPanelMuted,
      marker: marker ?? this.marker,
      markerSelected: markerSelected ?? this.markerSelected,
    );
  }

  @override
  AppColors lerp(covariant AppColors? other, double t) {
    if (other == null) return this;
    return AppColors(
      success: Color.lerp(success, other.success, t)!,
      onSuccess: Color.lerp(onSuccess, other.onSuccess, t)!,
      successSurface: Color.lerp(successSurface, other.successSurface, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      warningSurface: Color.lerp(warningSurface, other.warningSurface, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
      brandGradient: _lerpColorList(brandGradient, other.brandGradient, t),
      heroGradient: _lerpColorList(heroGradient, other.heroGradient, t),
      onHero: Color.lerp(onHero, other.onHero, t)!,
      heroMuted: Color.lerp(heroMuted, other.heroMuted, t)!,
      mapPanel: Color.lerp(mapPanel, other.mapPanel, t)!,
      onMapPanel: Color.lerp(onMapPanel, other.onMapPanel, t)!,
      mapPanelMuted: Color.lerp(mapPanelMuted, other.mapPanelMuted, t)!,
      marker: Color.lerp(marker, other.marker, t)!,
      markerSelected: Color.lerp(markerSelected, other.markerSelected, t)!,
    );
  }

  static List<Color> _lerpColorList(List<Color> a, List<Color> b, double t) {
    return [
      for (var i = 0; i < a.length; i++) Color.lerp(a[i], b[i], t)!,
    ];
  }
}

/// 4-pt spacing scale. Use these instead of raw numbers so padding / gaps stay
/// consistent across every screen.
abstract final class AppSpacing {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 48;

  static const EdgeInsets pageH = EdgeInsets.symmetric(horizontal: lg);
  static const EdgeInsets card = EdgeInsets.all(lg);
  static const EdgeInsets field =
      EdgeInsets.symmetric(horizontal: lg, vertical: 14);

  /// Vertical gaps as ready-made widgets.
  static const SizedBox gapXs = SizedBox(height: xs);
  static const SizedBox gapSm = SizedBox(height: sm);
  static const SizedBox gapMd = SizedBox(height: md);
  static const SizedBox gapLg = SizedBox(height: lg);
  static const SizedBox gapXl = SizedBox(height: xl);
  static const SizedBox gapXxl = SizedBox(height: xxl);
}

/// Corner-radius scale.
abstract final class AppRadius {
  static const double xs = 6;
  static const double sm = 10;
  static const double md = 14;
  static const double lg = 20;
  static const double xl = 28;
  static const double pill = 999;

  static const BorderRadius brXs = BorderRadius.all(Radius.circular(xs));
  static const BorderRadius brSm = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius brMd = BorderRadius.all(Radius.circular(md));
  static const BorderRadius brLg = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius brXl = BorderRadius.all(Radius.circular(xl));
}

/// Animation durations.
abstract final class AppDurations {
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration normal = Duration(milliseconds: 250);
  static const Duration slow = Duration(milliseconds: 400);
}

/// Central theme. `main.dart` passes the device dynamic scheme (Android 12+)
/// and this falls back to the brand seed when there isn't one.
abstract final class AppTheme {
  static const _seed = Brand.sky600;

  static ThemeData light([ColorScheme? dynamicScheme]) =>
      _build(Brightness.light, dynamicScheme, AppColors.light);

  static ThemeData dark([ColorScheme? dynamicScheme]) =>
      _build(Brightness.dark, dynamicScheme, AppColors.dark);

  static ThemeData _build(
    Brightness brightness,
    ColorScheme? dynamicScheme,
    AppColors appColors,
  ) {
    final scheme = (dynamicScheme ??
            ColorScheme.fromSeed(seedColor: _seed, brightness: brightness))
        .copyWith(brightness: brightness);

    final textTheme = _textTheme(scheme);

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      textTheme: textTheme,
      extensions: [appColors],
      splashFactory: InkSparkle.splashFactory,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 1,
        centerTitle: true,
        titleTextStyle: textTheme.titleLarge,
      ),
      cardTheme: CardThemeData(
        color: scheme.surfaceContainerLow,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.brLg),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: 1,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          textStyle: textTheme.labelLarge,
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.brMd),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          elevation: 0,
          textStyle: textTheme.labelLarge,
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.brMd),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          textStyle: textTheme.labelLarge,
          side: BorderSide(color: scheme.outline),
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.brMd),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          textStyle: textTheme.labelLarge,
          foregroundColor: scheme.primary,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onInverseSurface,
        ),
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.brSm),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest,
        hintStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
        contentPadding: AppSpacing.field,
        border: const OutlineInputBorder(
          borderRadius: AppRadius.brMd,
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: AppRadius.brMd,
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: AppRadius.brMd,
          borderSide: BorderSide(color: scheme.primary, width: 1.6),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: AppRadius.brMd,
          borderSide: BorderSide(color: scheme.error, width: 1.4),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: AppRadius.brMd,
          borderSide: BorderSide(color: scheme.error, width: 1.6),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainerHighest,
        labelStyle: textTheme.labelMedium,
        side: BorderSide(color: scheme.outlineVariant),
        shape: const StadiumBorder(),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.primary),
    );
  }

  /// Inter for body/UI, Poppins for the punchy display + title sizes.
  static TextTheme _textTheme(ColorScheme scheme) {
    final base = ThemeData(brightness: scheme.brightness).textTheme;
    final body = GoogleFonts.interTextTheme(base);
    final display = GoogleFonts.poppinsTextTheme(base);

    return body
        .copyWith(
          displayLarge: display.displayLarge,
          displayMedium: display.displayMedium,
          displaySmall: display.displaySmall,
          headlineLarge: display.headlineLarge,
          headlineMedium: display.headlineMedium,
          headlineSmall: display.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
          titleLarge: display.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        )
        .apply(
          bodyColor: scheme.onSurface,
          displayColor: scheme.onSurface,
        );
  }
}

/// Ergonomic shortcuts so screens read `context.colors.primary` /
/// `context.appColors.accent` / `context.text.titleLarge` instead of the
/// longer `Theme.of(context)...` chains.
extension ThemeX on BuildContext {
  ThemeData get theme => Theme.of(this);
  ColorScheme get colors => Theme.of(this).colorScheme;
  TextTheme get text => Theme.of(this).textTheme;

  /// The [AppColors] extension registered by [AppTheme]. Falls back to the
  /// brightness-appropriate palette when a screen is shown without the app
  /// theme (widget tests, previews), so reading it can never throw.
  AppColors get appColors {
    final theme = Theme.of(this);
    return theme.extension<AppColors>() ??
        (theme.brightness == Brightness.dark
            ? AppColors.dark
            : AppColors.light);
  }

  bool get isDark => Theme.of(this).brightness == Brightness.dark;
}

/// The single "go back" affordance used across the app. Every screen that can be
/// popped should use this instead of hand-rolling an icon / chevron so the
/// gesture, icon and hit target stay identical everywhere.
class AppBackButton extends StatelessWidget {
  const AppBackButton({
    super.key,
    this.onTap,
    this.color,
    this.tooltip = 'Go back',
  });

  /// Defaults to `Navigator.maybePop(context)`.
  final VoidCallback? onTap;

  /// Icon tint — pass the on-colour when the button sits on a coloured/hero
  /// surface. Defaults to the theme's icon colour.
  final Color? color;

  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      color: color,
      onPressed: onTap ?? () => Navigator.maybePop(context),
      icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
    );
  }
}

/// The shared "dismiss / close" affordance for sheets, dialogs and floating
/// panels — the counterpart to [AppBackButton].
class AppCloseButton extends StatelessWidget {
  const AppCloseButton({
    super.key,
    required this.onTap,
    this.color,
    this.tooltip = 'Close',
  });

  final VoidCallback onTap;
  final Color? color;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      color: color,
      onPressed: onTap,
      icon: const Icon(Icons.close_rounded, size: 22),
    );
  }
}

/// Holds the user's light / dark / system choice and persists it.
class ThemeController extends ChangeNotifier {
  ThemeController._(this._prefs, this._mode);

  static const _key = 'theme_mode';

  final SharedPreferences _prefs;
  ThemeMode _mode;

  ThemeMode get mode => _mode;

  static Future<ThemeController> load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_key);
    final mode = ThemeMode.values.firstWhere(
      (m) => m.name == saved,
      orElse: () => ThemeMode.system,
    );
    return ThemeController._(prefs, mode);
  }

  Future<void> setMode(ThemeMode mode) async {
    if (mode == _mode) return;
    _mode = mode;
    notifyListeners();
    await _prefs.setString(_key, mode.name);
  }

  /// Toggle between light and dark (leaving "system" for the settings screen).
  Future<void> toggle(Brightness platformBrightness) {
    final isDark = _mode == ThemeMode.dark ||
        (_mode == ThemeMode.system && platformBrightness == Brightness.dark);
    return setMode(isDark ? ThemeMode.light : ThemeMode.dark);
  }
}

/// Bottom sheet to pick Light / Dark / System appearance.
Future<void> showAppearanceSheet(BuildContext context) {
  final controller = context.read<ThemeController>();

  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            0,
            AppSpacing.lg,
            AppSpacing.lg,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Appearance', style: sheetContext.text.titleLarge),
              AppSpacing.gapSm,
              AnimatedBuilder(
                animation: controller,
                builder: (context, _) => Column(
                  children: [
                    for (final (mode, label, icon) in const [
                      (ThemeMode.system, 'System default', Icons.brightness_auto),
                      (ThemeMode.light, 'Light', Icons.light_mode_outlined),
                      (ThemeMode.dark, 'Dark', Icons.dark_mode_outlined),
                    ])
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(icon),
                        title: Text(label),
                        trailing: controller.mode == mode
                            ? Icon(
                                Icons.check_circle_rounded,
                                color: context.colors.primary,
                              )
                            : null,
                        onTap: () => controller.setMode(mode),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // UC-01/UC-02/UC-07 — real Supabase Auth + profiles table.
  await Supabase.initialize(
    url: 'https://umlcjnlubupncwbdntkt.supabase.co',
    publishableKey: 'sb_publishable_fw4Umycv8H3usButMNB8cA_kMMshZJt',
  );

  final themeController = await ThemeController.load();

  runApp(
    ChangeNotifierProvider.value(
      value: themeController,
      child: const MysteryMalaysiaApp(),
    ),
  );
}

/// Wires the shared external services, data-layer services and repositories.
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

  MysteryPlacePuzzleGameViewModel createPuzzleViewModel({
    String? placeId,
    String? placeCategory,
    String? placeRouteGroup,
    double? distanceKm,
    List<HiddenPlaceMarker> nearbyMarkers = const [],
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
      preselectedRouteGroup: placeRouteGroup,
      preselectedDistanceKm: distanceKm,
      nearbyMarkers: nearbyMarkers,
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
}

/// Slides the destination up from the bottom of the screen, like a sheet
/// rising over what's already there, instead of the platform-default
/// horizontal push — used for Trip Path.
///
/// `opaque: false` keeps the Map route mounted and visible underneath
/// instead of Flutter dropping it from the tree once covered, so Trip Path's
/// pre-quest screens can show the real, live Map exactly as the tourist left
/// it (not a lookalike) behind their translucent scrim, and popping back
/// feels instant since Map was never torn down.
Route<void> _slideUpFromMapRoute(WidgetBuilder builder) {
  return PageRouteBuilder<void>(
    opaque: false,
    pageBuilder: (context, animation, secondaryAnimation) => builder(context),
    transitionDuration: const Duration(milliseconds: 340),
    reverseTransitionDuration: const Duration(milliseconds: 260),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final offset = Tween<Offset>(
        begin: const Offset(0, 1),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic));
      return SlideTransition(position: offset, child: child);
    },
  );
}

class MysteryMalaysiaApp extends StatefulWidget {
  const MysteryMalaysiaApp({super.key});

  @override
  State<MysteryMalaysiaApp> createState() => _MysteryMalaysiaAppState();
}

class _MysteryMalaysiaAppState extends State<MysteryMalaysiaApp> {
  late final AppDependencies _deps = AppDependencies();

  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  final AppLinks _appLinks = AppLinks();

  StreamSubscription<AuthState>? _authSubscription;
  StreamSubscription<Uri>? _appLinkSubscription;

  bool _isCheckingSession = true;
  bool _isLoggedIn = false;
  bool _isPasswordRecovery = false;
  bool _handlingEmailChange = false;

  @override
  void initState() {
    super.initState();

    // UC-07 – restore a previous login session, then watch for auth changes
    // and "mysterymalaysia://" deep links (reset-password / email-change).
    _checkExistingSession();
    _listenToAuthChanges();
    _listenToAppLinks();

    if (kIsWeb) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (Uri.base.queryParameters['email_change'] == 'success') {
          _handleEmailChangeSuccess();
        }
      });
    }
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    _appLinkSubscription?.cancel();
    _deps.rewardViewModel.dispose();
    super.dispose();
  }

  // UC-07 – auto-login when a Supabase session already exists.
  Future<void> _checkExistingSession() async {
    final session = Supabase.instance.client.auth.currentSession;
    if (session == null) {
      if (!mounted) return;
      setState(() {
        _isLoggedIn = false;
        _isCheckingSession = false;
      });
      return;
    }

    try {
      await _deps.profileViewModel
          .loadProfile()
          .timeout(const Duration(seconds: 8));
      if (!mounted) return;
      setState(() {
        _isLoggedIn = _deps.profileViewModel.user != null;
        _isCheckingSession = false;
      });
    } on TimeoutException {
      // Backend unreachable, but a session token exists — enter the app on the
      // cached session instead of hanging on the splash screen. The auth
      // listener reconciles the real state once the network is back.
      if (!mounted) return;
      setState(() {
        _isLoggedIn = true;
        _isCheckingSession = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoggedIn = false;
        _isCheckingSession = false;
      });
    }
  }

  void _listenToAuthChanges() {
    _authSubscription =
        Supabase.instance.client.auth.onAuthStateChange.listen((data) async {
      switch (data.event) {
        // UC-01 A1 – Supabase reopens the app here after the reset-password link.
        case AuthChangeEvent.passwordRecovery:
          if (!mounted) return;
          setState(() {
            _isPasswordRecovery = true;
            _isCheckingSession = false;
          });
          break;
        case AuthChangeEvent.signedIn:
          try {
            await _deps.profileViewModel.loadProfile();
          } catch (_) {}
          if (!mounted) return;
          setState(() {
            _isLoggedIn = true;
            _isCheckingSession = false;
          });
          break;
        case AuthChangeEvent.signedOut:
          if (!mounted) return;
          setState(() {
            _isLoggedIn = false;
            _isPasswordRecovery = false;
            _isCheckingSession = false;
          });
          break;
        default:
          break;
      }
    }, onError: (_) {});
  }

  void _listenToAppLinks() {
    if (kIsWeb) return;
    _appLinkSubscription = _appLinks.uriLinkStream.listen((uri) {
      if (uri.scheme == 'mysterymalaysia' &&
          uri.host == 'email-change' &&
          uri.queryParameters['email_change'] == 'success') {
        _handleEmailChangeSuccess();
      }
      // A reset-password link surfaces as AuthChangeEvent.passwordRecovery above.
    }, onError: (_) {});
  }

  // UC-07 A2 – reload the profile and reopen it after an email-change callback.
  Future<void> _handleEmailChangeSuccess() async {
    if (_handlingEmailChange) return;
    _handlingEmailChange = true;

    try {
      await Future.delayed(const Duration(milliseconds: 500));

      final auth = Supabase.instance.client.auth;
      if (auth.currentSession != null) {
        try {
          await auth.refreshSession();
        } catch (_) {}
      }

      await _deps.profileViewModel.loadProfile();
      if (!mounted || _deps.profileViewModel.user == null) {
        _handlingEmailChange = false;
        return;
      }

      setState(() {
        _isLoggedIn = true;
        _isCheckingSession = false;
      });

      WidgetsBinding.instance.addPostFrameCallback((_) {
        _navigatorKey.currentState?.pushAndRemoveUntil(
          MaterialPageRoute<void>(
            builder: (_) => ManageProfileView(
              viewModel: _deps.profileViewModel,
              successMessage: 'Email address updated successfully.',
            ),
          ),
          (route) => false,
        );
        _handlingEmailChange = false;
      });
    } catch (_) {
      _handlingEmailChange = false;
    }
  }

  // Returns the push's Future (instead of plain void) so callers that care
  // when the tourist comes back — currently only Map's own onRewards
  // wrapper below — can chain a refresh onto it. Dart allows a
  // Future<void>-returning function wherever void Function(BuildContext)
  // is expected, so this doesn't break the other call sites (Puzzle, Trip
  // Path) that don't care about the return value at all.
  Future<void> _openRewards(BuildContext context) {
    _deps.rewardViewModel.loadRewards();
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChangeNotifierProvider.value(
          value: _deps.rewardViewModel,
          child: const ManageRewardView(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final deps = _deps;

    final themeMode = context.watch<ThemeController>().mode;

    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) => MaterialApp(
        navigatorKey: _navigatorKey,
        debugShowCheckedModeBanner: false,
        title: 'Mystery Malaysia',
        theme: AppTheme.light(lightDynamic?.harmonized()),
        darkTheme: AppTheme.dark(darkDynamic?.harmonized()),
        themeMode: themeMode,
        home: _buildHome(deps),
        routes: {
          '/login': (context) => LoginView(viewModel: deps.authViewModel),
          '/register': (context) => RegisterView(viewModel: deps.authViewModel),
          '/forgot-password': (context) =>
              ForgotPasswordView(viewModel: deps.authViewModel),
          '/profile': (context) =>
              ManageProfileView(viewModel: deps.profileViewModel),
          '/map': (context) => _buildMap(deps),
          '/trip-path-quest': (context) {
            final questId = ModalRoute.of(context)?.settings.arguments as String?;
            final navigator = Navigator.of(context);
            return TripPathQuestModule(
              initialQuestId: questId,
              onExit: () => navigator.maybePop(),
              rewardRepository: deps._rewardRepository,
              onRewards: _openRewards,
            );
          },
          '/mystery-place-puzzle': (context) {
            final sessionId =
                ModalRoute.of(context)?.settings.arguments as String?;
            return ChangeNotifierProvider(
              create: (_) => deps.createPuzzleViewModel(),
              child: MysteryPlacePuzzleGameView(
                touristId: CurrentTourist.id,
                initialSessionId: sessionId,
                onRewards: _openRewards,
              ),
            );
          },
        },
      ),
    );
  }

  Widget _buildHome(AppDependencies deps) {
    if (_isCheckingSession) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (_isPasswordRecovery) {
      return ForgotPasswordView(
        viewModel: deps.authViewModel,
        startWithResetStep: true,
      );
    }
    // UC-01 BF-7 – after successful login the tourist lands on the Map Home.
    if (_isLoggedIn) {
      return _buildMap(deps);
    }
    return LoginView(viewModel: deps.authViewModel);
  }

  Widget _buildMap(AppDependencies deps) {
    return ChangeNotifierProvider.value(
      // So the profile button (_TopControls) can show the tourist's own
      // avatar/name and stay in sync the moment Edit Profile changes it —
      // this is the same instance ManageProfileView edits, so no extra
      // reload wiring is needed here.
      value: deps.profileViewModel,
      child: ChangeNotifierProvider.value(
        // So the reward-icon notification dot (_TopControls) can watch
        // hasUnclaimedRewards without waiting for the tourist to open Rewards
        // first — that page only calls loadRewards() when opened directly.
        value: deps.rewardViewModel,
        child: ChangeNotifierProvider(
          create: (_) {
            // Runs once, right when Map first mounts — same reasoning as
            // above, done here since this create callback is a convenient
            // one-time hook regardless of which provider it's attached to.
            deps.rewardViewModel.loadRewards();
            return MapViewModel(
              mapRepository: deps.mapRepository,
              locationService: deps.locationService,
              claimedPlacesRepository: deps.claimedPlacesRepository,
              rewardRepository: deps._rewardRepository,
            );
          },
          child: MapView(
            // Not the plain _openRewards: that's also used from Puzzle/Trip
            // Path, whose contexts have no MapViewModel ancestor to read. This
            // one captures Map's own MapViewModel before pushing and reloads
            // it once the tourist comes back — otherwise equipping a skin (or
            // anything else reward-related) never shows up on the map marker
            // until the whole app is restarted, since nothing else re-runs
            // loadMap() for a screen that was already alive underneath.
            onRewards: (context) {
              final mapViewModel = context.read<MapViewModel>();
              _openRewards(context).then((_) => mapViewModel.loadMap());
            },
            onGameHandoff: (context, handoff) {
              _routeToGame(context, deps, handoff);
            },
            // Same reasoning as onRewards above: Profile (Game History) is
            // where a tourist deletes a Puzzle/Trip Path history item, which
            // un-claims that real place (ClaimedPlacesRepository reads the
            // claim live from game_sessions/trip_path_quest_checkpoints — an
            // empty row set there means an empty exclusion set). Reloading Map
            // on return re-runs the search, radius-expansion included, so a
            // newly-unclaimed place can reappear as a marker without needing
            // an app restart.
            onProfileTap: (context) {
              final mapViewModel = context.read<MapViewModel>();
              Navigator.of(context)
                  .pushNamed('/profile')
                  .then((_) => mapViewModel.loadMap());
            },
            onAssistantTap: (context) => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ChangeNotifierProvider(
                  create: (_) => deps.createChatbotViewModel(),
                  child: const ChatbotView(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// UC-03 FR03_9 – hands the selected place, mode and entry source to UC-05.
  void _routeToGame(
    BuildContext context,
    AppDependencies deps,
    MapGameHandoff handoff,
  ) {
    // Map's route is kept alive underneath (opaque:false) rather than
    // recreated, so its markers are whatever `loadMap()` last fetched —
    // stale the moment a place gets claimed mid-game. Re-running it as soon
    // as the game route pops back re-applies the claimed-places exclusion
    // immediately, instead of only after the app is fully restarted.
    final mapViewModel = context.read<MapViewModel>();

    if (handoff.mode == ProximityGameMode.tripPath) {
      final navigator = Navigator.of(context);
      navigator
          .push(
            _slideUpFromMapRoute(
              (_) => TripPathQuestModule(
                onExit: () => navigator.maybePop(),
                initialLatitude: handoff.touristLatitude,
                initialLongitude: handoff.touristLongitude,
                // Only a marker-specific entry jumps straight into that marker's
                // theme (FR03_9) — the Theme button keeps the normal browse flow,
                // since it never had a specific place in mind.
                initialThemeId: handoff.isMarkerSpecific
                    ? handoff.marker?.routeGroup
                    : null,
                rewardRepository: deps._rewardRepository,
                onRewards: _openRewards,
              ),
            ),
          )
          .then((_) => mapViewModel.loadMap());
      return;
    }

    final marker = handoff.marker;
    final note = marker == null
        ? 'Started from the Puzzle button — searching all nearby hidden places.'
        : 'Started from a Proximity Game marker · ${marker.questCategoryLabel} · ${marker.approximateDistanceLabel}';

    Navigator.of(context)
        .push(
          // Matches Trip Path's entrance so both game buttons open the same way.
          _slideUpFromMapRoute(
            (_) => ChangeNotifierProvider(
              // UC-03 FR03_9 — a marker entry hands the chosen hidden place straight
              // to UC-05; the Puzzle button starts a general search instead.
              create: (_) => deps.createPuzzleViewModel(
                placeId: marker?.id,
                placeCategory: marker?.generalCategory,
                placeRouteGroup: marker?.routeGroup,
                distanceKm: marker?.distanceKm,
                // Puzzle-button entry (no preselected marker) — hand over
                // the map's already-fetched, already-screened markers so
                // loadNearbyPuzzleOptions() can hydrate its nearest 3
                // directly instead of re-running that whole search.
                nearbyMarkers: marker == null ? mapViewModel.markers : const [],
              ),
              child: MysteryPlacePuzzleGameView(
                touristId: CurrentTourist.id,
                entrySourceNote: note,
                onRewards: _openRewards,
              ),
            ),
          ),
        )
        .then((_) => mapViewModel.loadMap());
  }
}
