import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../../main.dart';
import '../../../Data_layer/repository/Map Repository/map.dart';
import '../../../Data_layer/repository/Reward Repository/reward_repository.dart'
    show RewardRepository, MarkerSkinDesign;
import '../../../Data_layer/service/Map Tiles Service/map_tiles.dart';
import '../../viewmodel/Manage Reward  ViewModel/reward_viewmodel.dart';
import '../../viewmodel/Manage Profile ViewModel/profile_viewmodel.dart';
import '../../viewmodel/Map ViewModel/map_viewmodel.dart';
import '../Manage Profile View/widgets/profile_widgets.dart' show ProfileAvatar;

/// UC-03 View Map.
///
/// The map communicates "a game is available somewhere around this area" using
/// one neutral Proximity Game marker per eligible hidden place. It never reveals
/// the exact attraction, address or coordinates (C3 / FR03_6).
class MapView extends StatefulWidget {
  const MapView({
    super.key,
    this.onGameHandoff,
    this.onRewards,
    this.onProfileTap,
    this.onAssistantTap,
    this.bundledMapForTesting = false,
  });

  /// Invoked with the bundle UC-03 passes to UC-05 (FR03_9).
  final void Function(BuildContext context, MapGameHandoff handoff)?
      onGameHandoff;

  /// UC-07 — opens Profile Management. Falls back to a placeholder snackbar
  /// when not supplied (e.g. in widget tests).
  final void Function(BuildContext context)? onProfileTap;

  /// UC-04 — opens the AI Assistant Chat. Falls back to a placeholder snackbar
  /// when not supplied.
  final void Function(BuildContext context)? onAssistantTap;

  /// Renders a deterministic offline map (used by widget tests).
  final bool bundledMapForTesting;
  final void Function(BuildContext context)? onRewards;

  @override
  State<MapView> createState() => _MapViewState();
}

class _MapViewState extends State<MapView> {
  final MapController _mapController = MapController();
  bool _mapReady = false;

  // Matches _DynamicExplorationMapState's own default — the "overview" zoom
  // a tourist lands on normally, reused here as the fit ceiling/fallback so
  // "show all markers" never zooms in tighter than that baseline.
  static const _overviewZoom = 16.0;

  @override
  void initState() {
    super.initState();
    final vm = context.read<MapViewModel>();
    Future.microtask(() {
      if (vm.loadState == MapLoadState.idle) {
        vm.loadMap();
      }
    });
  }

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  void _recenter(MapViewModel vm) {
    if (widget.bundledMapForTesting) return;
    final position = vm.touristPosition;
    if (position == null) {
      // No fix yet — re-request a location instead of silently jumping to a
      // default spot, and surface why the marker isn't there.
      vm.openLocationStatus();
      if (vm.loadState != MapLoadState.loading) vm.requestLocationAgain();
      return;
    }
    if (!_mapReady) return;
    // Matches Puzzle's Navigate screen recenterOnMe() — same icon, same
    // close zoom level, so "recenter" behaves the same way across the app
    // instead of snapping out to a wider view than the tourist expects.
    _mapController.move(
      LatLng(position.latitude, position.longitude),
      17,
    );
  }

  /// Fits the camera to the tourist's position plus every Proximity Game
  /// marker currently on screen, so one tap reveals the whole hunting ground
  /// instead of the tight street-level view [_recenter] gives — useful now
  /// that markers can sit anywhere out to a 50km search radius (see
  /// MapRepository.getProximityGameMarkers) instead of a fixed nearby patch.
  void _showAllMarkers(MapViewModel vm) {
    if (widget.bundledMapForTesting) return;
    final position = vm.touristPosition;
    if (position == null) {
      vm.openLocationStatus();
      if (vm.loadState != MapLoadState.loading) vm.requestLocationAgain();
      return;
    }
    if (!_mapReady) return;

    final current = LatLng(position.latitude, position.longitude);
    final markers = vm.markers;
    if (markers.isEmpty) {
      // Nothing to fit around yet — an overview of the surrounding area is
      // still more useful than the tight recenter zoom.
      _mapController.move(current, _overviewZoom);
      return;
    }

    var bounds = LatLngBounds(current, current);
    for (final marker in markers) {
      bounds.extend(
        LatLng(marker.generalAreaLatitude, marker.generalAreaLongitude),
      );
    }
    _mapController.fitCamera(
      CameraFit.bounds(
        bounds: bounds,
        // Clears the top button bar and the bottom "Ask about this area"
        // assistant bar so no marker lands hidden behind either.
        padding: const EdgeInsets.fromLTRB(40, 140, 40, 200),
        minZoom: 3,
        maxZoom: _overviewZoom,
      ),
    );
  }

  void _zoomBy(double amount) {
    if (widget.bundledMapForTesting || !_mapReady) return;
    final camera = _mapController.camera;
    _mapController.move(camera.center, (camera.zoom + amount).clamp(3.0, 20.0));
  }

  void _handoff(MapGameHandoff handoff) {
    // No snackbar here — the destination screen (the mystery list, the quest
    // sheet) already shows what was searched, and this dev-debug-style
    // message ("Starting a general Puzzle search (Puzzle button).") added
    // nothing for the tourist while also clashing with the dark theme (a
    // plain light Material SnackBar).
    final callback = widget.onGameHandoff;
    if (callback != null) {
      callback(context, handoff);
      return;
    }
    if (handoff.mode == ProximityGameMode.tripPath) {
      _showTripPathPlaceholder();
    }
  }

  void _showTripPathPlaceholder() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Trip Path Quest'),
        content: const Text(
          'The Trip Path Quest game (UC-05) opens here with the selected '
          'general category and no exact checkpoint revealed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<MapViewModel>(
      builder: (context, vm, _) {
        // Open / close the marker detail sheet in response to VM selection.
        return Scaffold(
          backgroundColor: context.colors.surface,
          body: LayoutBuilder(
            builder: (context, constraints) {
              // Flutter web can emit a degenerate first layout pass before the
              // canvas has a real size – skip it to avoid transient overflows.
              if (constraints.maxWidth < 300 || constraints.maxHeight < 300) {
                return ColoredBox(color: context.colors.surface);
              }
              final viewportSize =
                  Size(constraints.maxWidth, constraints.maxHeight);
              final bottomInset = MediaQuery.paddingOf(context).bottom;

              return Stack(
                children: [
                  Positioned.fill(
                    child: widget.bundledMapForTesting
                        ? _BundledMap(vm: vm, onMarkerTap: vm.selectMarker)
                        : _DynamicExplorationMap(
                            vm: vm,
                            mapController: _mapController,
                            onMapReady: () => _mapReady = true,
                            onMarkerTap: vm.selectMarker,
                          ),
                  ),
                  _TopControls(
                    onPuzzle: () => _handoff(vm.startGeneralPuzzleSearch()),
                    onTheme: () => _handoff(vm.startGeneralTripPathSearch()),
                    onReward: () => widget.onRewards?.call(context),
                    onProfile: () => widget.onProfileTap != null
                        ? widget.onProfileTap!(context)
                        : _snack('Profile Management (UC-07) opens here.'),
                  ),
                  _RightControls(
                    viewportSize: viewportSize,
                    onRecenter: () => _recenter(vm),
                    onZoomIn: () => _zoomBy(1.0),
                    onZoomOut: () => _zoomBy(-1.0),
                    onShowAllMarkers: () => _showAllMarkers(vm),
                  ),
                  _AreaLabel(label: vm.areaLabel, bottomInset: bottomInset),
                  _AssistantBar(
                    bottomInset: bottomInset,
                    onTap: () => widget.onAssistantTap != null
                        ? widget.onAssistantTap!(context)
                        : _snack('AI Assistant Chat (UC-04) opens here.'),
                  ),
                  if (vm.selectedMarker case final marker?)
                    _MarkerDetailPanel(
                      key: ValueKey('marker-panel-${marker.id}'),
                      marker: marker,
                      bottomInset: bottomInset,
                      onClose: vm.clearSelection,
                      onSelectMode: (mode) {
                        final handoff = vm.selectMarkerGameMode(mode);
                        vm.clearSelection();
                        if (handoff != null) _handoff(handoff);
                      },
                    ),
                  if (vm.showLocationStatus)
                    _LocationStatusCard(
                      hasLocation: vm.hasLocation,
                      onEnable: vm.requestLocationAgain,
                      onClose: vm.hideLocationStatus,
                    ),
                  if (vm.loadState == MapLoadState.loading)
                    const _LoadingOverlay(),
                  if (vm.loadState == MapLoadState.error)
                    _MapErrorOverlay(
                      message: vm.mapErrorMessage,
                      onRetry: vm.retry,
                    ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

// ── Marker detail panel (UC-03 BF-11: general category + approx distance) ─────

class _MarkerDetailPanel extends StatelessWidget {
  const _MarkerDetailPanel({
    required this.marker,
    required this.bottomInset,
    required this.onClose,
    required this.onSelectMode,
    super.key,
  });

  final HiddenPlaceMarker marker;
  final double bottomInset;
  final VoidCallback onClose;
  final ValueChanged<ProximityGameMode> onSelectMode;

  @override
  Widget build(BuildContext context) {
    final appColors = context.appColors;
    final colors = context.colors;

    return Positioned.fill(
      // This panel is an inline overlay on the Map screen, not its own
      // route — without this, the system back gesture/button would fall
      // through to whatever Map's own back handling is instead of closing
      // the panel first, same as tapping the scrim or the X button.
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop) onClose();
        },
        child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onClose,
              child: const ColoredBox(color: Color(0x55000000)),
            ),
          ),
          Positioned(
            left: 12,
            right: 12,
            bottom: 14 + bottomInset,
            child: Container(
              decoration: BoxDecoration(
                color: appColors.mapPanel,
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.3),
                    blurRadius: 24,
                  ),
                ],
              ),
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: AppCloseButton(
                      key: const ValueKey('marker-panel-close'),
                      onTap: onClose,
                      color: appColors.mapPanelMuted,
                    ),
                  ),
                  Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: colors.primary.withValues(alpha: 0.1),
                  ),
                  child: Icon(Icons.travel_explore_rounded,
                      color: colors.primary, size: 27),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    marker.questCategoryLabel,
                    style: TextStyle(
                      color: appColors.onMapPanel,
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(13),
              decoration: BoxDecoration(
                color: colors.primaryContainer,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: colors.primary.withValues(alpha: 0.25)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.shield_outlined,
                      color: colors.onPrimaryContainer, size: 19),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      'The exact hidden place stays hidden until the game reveals it.',
                      style: TextStyle(
                          color: colors.onPrimaryContainer, fontSize: 12.5, height: 1.3),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              key: const ValueKey('marker-mode-puzzle'),
              onPressed: () => onSelectMode(ProximityGameMode.puzzle),
              icon: const Icon(Icons.extension_rounded),
              label: const Text('Play Puzzle'),
              style: FilledButton.styleFrom(
                backgroundColor: colors.primary,
                foregroundColor: colors.onPrimary,
                minimumSize: const Size.fromHeight(50),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(15)),
                textStyle:
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              key: const ValueKey('marker-mode-trip-path'),
              onPressed: () => onSelectMode(ProximityGameMode.tripPath),
              icon: const Icon(Icons.route_rounded),
              label: const Text('Start Trip Path'),
              style: OutlinedButton.styleFrom(
                foregroundColor: colors.primary,
                minimumSize: const Size.fromHeight(50),
                side: BorderSide(color: colors.primary),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(15)),
                textStyle:
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
            ),
                ],
              ),
            ),
          ),
        ],
        ),
      ),
    );
  }
}

// ── Real (dynamic) map ───────────────────────────────────────────────────────

class _DynamicExplorationMap extends StatefulWidget {
  const _DynamicExplorationMap({
    required this.vm,
    required this.mapController,
    required this.onMapReady,
    required this.onMarkerTap,
  });

  final MapViewModel vm;
  final MapController mapController;
  final VoidCallback onMapReady;
  final ValueChanged<HiddenPlaceMarker> onMarkerTap;

  @override
  State<_DynamicExplorationMap> createState() => _DynamicExplorationMapState();
}

class _DynamicExplorationMapState extends State<_DynamicExplorationMap> {
  static const _fallbackCenter = LatLng(3.2056, 101.7319);
  // Street-level default the tourist lands on at every login — close enough
  // to read road names and tell markers apart without having to zoom in
  // by hand first.
  static const _defaultZoom = 16.0;
  final MapTilesService _tilesService = const MapTilesService();
  Future<_MapSource>? _source;
  Brightness? _sourceBrightness;
  Timer? _copyrightDebounce;
  String? _googleCopyright;

  bool _mapReady = false;
  bool _autoCentered = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The Google tile session is bound to the style it was created with, so a
    // light↔dark theme switch needs a fresh (dark-styled) session.
    final brightness = Theme.of(context).brightness;
    if (brightness != _sourceBrightness) {
      _sourceBrightness = brightness;
      _googleCopyright = null;
      _source = _resolveSource(dark: brightness == Brightness.dark);
    }
  }

  @override
  void dispose() {
    _copyrightDebounce?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(_DynamicExplorationMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The first GPS fix usually lands after the map is built, so re-center on
    // the tourist once it arrives (only once — the tourist can pan freely
    // after that).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _centreOnFirstFix();
    });
  }

  void _centreOnFirstFix() {
    if (_autoCentered || !_mapReady) return;
    final position = widget.vm.touristPosition;
    if (position == null) return;
    _autoCentered = true;
    widget.mapController.move(
      LatLng(position.latitude, position.longitude),
      _defaultZoom,
    );
  }

  Future<_MapSource> _resolveSource({required bool dark}) async {
    if (!_tilesService.hasApiKey) {
      return const _MapSource.openStreetMap(
        notice: 'Add a Google Map Tiles API key to use Google Maps.',
      );
    }
    try {
      final session = await _tilesService.createSession(dark: dark);
      return _MapSource.google(
        session,
        _tilesService.tileUrlTemplate(session),
      );
    } catch (e) {
      debugPrint('[Map Tiles] session failed: $e');
      return const _MapSource.openStreetMap(
        notice: 'Google Maps is unavailable. Showing the fallback map.',
      );
    }
  }

  LatLng get _initialCenter {
    final position = widget.vm.touristPosition;
    return position == null
        ? _fallbackCenter
        : LatLng(position.latitude, position.longitude);
  }

  void _scheduleCopyright(MapCamera camera, GoogleMapTileSession session) {
    _copyrightDebounce?.cancel();
    _copyrightDebounce = Timer(const Duration(milliseconds: 650), () async {
      final bounds = camera.visibleBounds;
      final copyright = await _tilesService.getViewportCopyright(
        session: session,
        zoom: camera.zoom.round().clamp(0, 22),
        north: bounds.north,
        south: bounds.south,
        east: bounds.east,
        west: bounds.west,
      );
      if (mounted && copyright != null && copyright.isNotEmpty) {
        setState(() => _googleCopyright = copyright);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_MapSource>(
      future: _source,
      builder: (context, snapshot) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        final mapBackground =
            isDark ? const Color(0xFF17263C) : const Color(0xFFE2E8F0);
        final source = snapshot.data;
        if (source == null) {
          return ColoredBox(
            color: mapBackground,
            child: const Center(
              child: CircularProgressIndicator(color: Color(0xFF38BDF8)),
            ),
          );
        }

        return Stack(
          fit: StackFit.expand,
          children: [
            FlutterMap(
              mapController: widget.mapController,
              options: MapOptions(
                initialCenter: _initialCenter,
                initialZoom: _defaultZoom,
                minZoom: 3,
                maxZoom: 20,
                backgroundColor: mapBackground,
                interactionOptions: const InteractionOptions(
                  flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                ),
                onMapReady: () {
                  _mapReady = true;
                  widget.onMapReady();
                  _centreOnFirstFix();
                  final session = source.session;
                  if (session != null) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) {
                        _scheduleCopyright(
                            widget.mapController.camera, session);
                      }
                    });
                  }
                },
                onTap: (_, _) => widget.vm.clearSelection(),
                onPositionChanged: (camera, _) {
                  final session = source.session;
                  if (session != null) _scheduleCopyright(camera, session);
                },
              ),
              children: [
                TileLayer(
                  urlTemplate: source.urlTemplate,
                  userAgentPackageName: 'com.example.collab_d',
                  maxNativeZoom: source.isGoogle ? 22 : 19,
                ),
                // "The hidden place is somewhere in this area" — a real
                // ground circle per marker that scales with zoom, so the
                // generalised place always stays inside it (C3 / FR03_6).
                CircleLayer(circles: _buildMarkerSearchCircles(context)),
                MarkerLayer(markers: _buildMarkers()),
              ],
            ),
            _MapAttribution(
              isGoogle: source.isGoogle,
              googleCopyright: _googleCopyright,
            ),
            if (source.notice case final notice?) _FallbackNotice(notice),
          ],
        );
      },
    );
  }

  /// "The hidden place is somewhere in this area" — only drawn for the
  /// selected marker. Showing one per marker all the time (even faintly)
  /// got unreadable wherever two markers sat close together: at ~260 m each,
  /// their circles overlapped into one indistinguishable blob. Showing it
  /// only on selection keeps the map clean and still answers the question
  /// at the moment it's actually relevant — when the tourist taps a marker.
  List<CircleMarker> _buildMarkerSearchCircles(BuildContext context) {
    final selected = widget.vm.selectedMarker;
    if (selected == null) return const [];

    final marker = context.appColors.marker;
    return [
      CircleMarker(
        point: LatLng(
          selected.generalAreaLatitude,
          selected.generalAreaLongitude,
        ),
        radius: widget.vm.markerSearchRadiusMeters,
        useRadiusInMeter: true,
        color: marker.withValues(alpha: 0.20),
        borderColor: marker.withValues(alpha: 0.9),
        borderStrokeWidth: 1.5,
      ),
    ];
  }

  List<Marker> _buildMarkers() {
    final markers = <Marker>[];
    final position = widget.vm.touristPosition;

    for (final marker in widget.vm.markers) {
      markers.add(
        Marker(
          point: LatLng(
              marker.generalAreaLatitude, marker.generalAreaLongitude),
          width: 78,
          height: 78,
          child: ProximityGameMarker(
            key: ValueKey('proximity-marker-${marker.id}'),
            marker: marker,
            isSelected: widget.vm.selectedMarker?.id == marker.id,
            onTap: () => widget.onMarkerTap(marker),
          ),
        ),
      );
    }

    // Added last so the tourist's own location always paints on top of the
    // Proximity Game markers, which cluster tightly around it.
    if (position != null) {
      markers.add(
        Marker(
          point: LatLng(position.latitude, position.longitude),
          width: 54,
          height: 54,
          child: CurrentLocationMarker(
            equippedSkinId: position.equippedMarkerSkinId,
            equippedSkinImageUrl: position.equippedMarkerSkinImageUrl,
          ),
        ),
      );
    }
    return markers;
  }
}

class _MapSource {
  const _MapSource.google(GoogleMapTileSession this.session, this.urlTemplate)
      : notice = null;

  const _MapSource.openStreetMap({required this.notice})
      : session = null,
        urlTemplate = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

  final GoogleMapTileSession? session;
  final String urlTemplate;
  final String? notice;

  bool get isGoogle => session != null;
}

// ── Bundled offline map (widget tests) ───────────────────────────────────────

class _BundledMap extends StatelessWidget {
  const _BundledMap({required this.vm, required this.onMarkerTap});

  final MapViewModel vm;
  final ValueChanged<HiddenPlaceMarker> onMarkerTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: vm.clearSelection,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset(
            'assets/maps/wangsa_maju_google_map.png',
            key: const ValueKey('bundled-map-image'),
            fit: BoxFit.cover,
          ),
          if (vm.hasLocation)
            const Center(child: IgnorePointer(child: CurrentLocationMarker())),
          for (var i = 0; i < vm.markers.length; i++)
            Align(
              alignment: Alignment(
                -0.6 + (i % 3) * 0.6,
                -0.5 + (i ~/ 3) * 0.5,
              ),
              child: ProximityGameMarker(
                key: ValueKey('proximity-marker-${vm.markers[i].id}'),
                marker: vm.markers[i],
                isSelected: vm.selectedMarker?.id == vm.markers[i].id,
                onTap: () => onMarkerTap(vm.markers[i]),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Markers ──────────────────────────────────────────────────────────────────

/// One neutral Proximity Game marker (UC-03 C7). Every eligible hidden place
/// uses the same neutral styling regardless of which game modes it supports.
class ProximityGameMarker extends StatefulWidget {
  const ProximityGameMarker({
    required this.marker,
    required this.isSelected,
    required this.onTap,
    super.key,
  });

  final HiddenPlaceMarker marker;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  State<ProximityGameMarker> createState() => _ProximityGameMarkerState();
}

class _ProximityGameMarkerState extends State<ProximityGameMarker>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const color = Color(0xFF0284C7);
    return Semantics(
      button: true,
      label:
          'Proximity Game near ${widget.marker.questCategoryLabel}, ${widget.marker.approximateDistanceLabel}',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: SizedBox.square(
          dimension: 78,
          child: Stack(
            alignment: Alignment.center,
            children: [
              AnimatedBuilder(
                animation: _controller,
                builder: (context, child) => Opacity(
                  opacity: 1 - _controller.value,
                  child: Transform.scale(
                    scale: 1 + _controller.value * 0.6,
                    child: child,
                  ),
                ),
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color.withValues(alpha: 0.22),
                  ),
                ),
              ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: widget.isSelected ? 46 : 42,
                height: widget.isSelected ? 46 : 42,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color,
                  border: Border.all(color: Colors.white, width: 3),
                  boxShadow: [
                    BoxShadow(
                      color: color.withValues(alpha: 0.55),
                      blurRadius: widget.isSelected ? 18 : 12,
                      spreadRadius: widget.isSelected ? 3 : 1,
                    ),
                  ],
                ),
                child: const Icon(Icons.travel_explore_rounded,
                    color: Colors.white, size: 20),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class CurrentLocationMarker extends StatefulWidget {
  const CurrentLocationMarker({
    this.equippedSkinId,
    this.equippedSkinImageUrl,
    super.key,
  });

  final String? equippedSkinId;

  /// The equipped skin's real generated image (UC-06 A3). When this is a
  /// usable http(s) URL it replaces the default gradient+icon marker
  /// entirely; a missing/mock/failed URL falls back to that default,
  /// never blocking the marker from rendering.
  final String? equippedSkinImageUrl;

  @override
  State<CurrentLocationMarker> createState() => _CurrentLocationMarkerState();
}

class _CurrentLocationMarkerState extends State<CurrentLocationMarker>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _hasUsableSkinImage {
    final url = widget.equippedSkinImageUrl;
    if (url == null || url.isEmpty) return false;
    final uri = Uri.tryParse(url);
    return uri != null &&
        ['http', 'https'].contains(uri.scheme) &&
        uri.host.isNotEmpty;
  }

  @override
  Widget build(BuildContext context) {
    // UC-03 C6 / A3 – the icon-only default marker is used when no skin is
    // equipped, or its image is missing/mock/fails to load.
    final hasSkin = (widget.equippedSkinId ?? '').isNotEmpty &&
        widget.equippedSkinId != 'default';
    final showSkinImage = hasSkin && _hasUsableSkinImage;
    return Semantics(
      label: 'Your current location',
      child: SizedBox.square(
        dimension: 54,
        child: Stack(
          alignment: Alignment.center,
          children: [
            AnimatedBuilder(
              animation: _controller,
              builder: (context, child) => Opacity(
                opacity: math.max(0, 1 - _controller.value),
                child: Transform.scale(scale: 1 + _controller.value, child: child),
              ),
              child: const DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0x5538BDF8),
                ),
                child: SizedBox.square(dimension: 31),
              ),
            ),
            if (showSkinImage)
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 3),
                  boxShadow: const [
                    BoxShadow(color: Color(0x660284C7), blurRadius: 14),
                  ],
                ),
                child: ClipOval(
                  child: Image.network(
                    widget.equippedSkinImageUrl!,
                    fit: BoxFit.cover,
                    errorBuilder: (_, error, stack) => _defaultMarkerIcon(),
                  ),
                ),
              )
            else
              _defaultMarkerIcon(),
          ],
        ),
      ),
    );
  }

  /// The equipped design's own tier/theme colour (UC-06 A3) — used as a
  /// solid fallback whenever there's no usable Gemini image yet, so
  /// switching skins is visibly different immediately rather than always
  /// showing the same generic blue gradient. Falls back to the default
  /// marker colour when no skin is equipped or the id isn't recognised.
  MarkerSkinDesign? get _equippedDesign {
    final id = widget.equippedSkinId;
    if (id == null || id.isEmpty || id == 'default') return null;
    for (final d in RewardRepository.markerSkinDesigns) {
      if (d.id == id) return d;
    }
    return null;
  }

  // Same fixed per-design icon lookup as marker_skins.dart's own
  // `_designIcon` — duplicated rather than shared across files (this
  // codebase's existing convention for small view-local helpers, see
  // Puzzle's `_categoryIcon`), but must be kept in sync with it so a skin
  // looks the same on the map as it does on the Marker Skins page.
  IconData _designIcon(String designId) => switch (designId) {
    'bronze_explorer' => Icons.explore_rounded,
    'silver_explorer' => Icons.local_florist_rounded,
    'gold_explorer' => Icons.location_city_rounded,
    'platinum_explorer' => Icons.flight_rounded,
    'legend_explorer' => Icons.auto_awesome_rounded,
    'bronze_puzzler' || 'silver_puzzler' || 'gold_puzzler' =>
      Icons.extension_rounded,
    'food_trailblazer' => Icons.restaurant_rounded,
    'culture_keeper' => Icons.festival_rounded,
    'heritage_guardian' => Icons.account_balance_rounded,
    'nature_ranger' => Icons.park_rounded,
    _ => Icons.emoji_events_rounded,
  };

  Widget _defaultMarkerIcon() {
    final design = _equippedDesign;
    if (design != null) {
      return Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Color(design.color),
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: const [
            BoxShadow(color: Color(0x660284C7), blurRadius: 14),
          ],
        ),
        child: Icon(
          _designIcon(design.id),
          color: Colors.white,
          size: 18,
        ),
      );
    }
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          colors: [Color(0xFF38BDF8), Color(0xFF0369A1)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: const [
          BoxShadow(color: Color(0x660284C7), blurRadius: 14),
        ],
      ),
      child: const Icon(
        Icons.navigation_rounded,
        color: Colors.white,
        size: 18,
      ),
    );
  }
}

// ── Overlays & controls ──────────────────────────────────────────────────────

class _TopControls extends StatelessWidget {
  const _TopControls({
    required this.onPuzzle,
    required this.onTheme,
    required this.onReward,
    required this.onProfile,
  });

  final VoidCallback onPuzzle;
  final VoidCallback onTheme;
  final VoidCallback onReward;
  final VoidCallback onProfile;

  @override
  Widget build(BuildContext context) {
    // Same "anything ready to claim?" flag the Rewards page uses for its
    // own Theme Souvenir cards' red dot — surfaced here too so it's visible
    // without having to open Rewards first.
    final hasUnclaimedReward =
        context.watch<RewardViewModel>().hasUnclaimedRewards;
    // UC-07 — the same profile the tourist edits in Manage Profile, so a new
    // avatar (or name) shows here immediately without needing loadMap().
    final user = context.watch<ManageProfileViewModel>().user;

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        minimum: const EdgeInsets.fromLTRB(14, 12, 14, 0),
        child: Row(
          children: [
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _MapChip(
                      key: const ValueKey('puzzle-map-chip'),
                      icon: Icons.extension_rounded,
                      label: 'Puzzle',
                      onTap: onPuzzle,
                    ),
                    const SizedBox(width: 8),
                    _MapChip(
                      key: const ValueKey('theme-map-chip'),
                      icon: Icons.route_rounded,
                      label: 'Theme',
                      onTap: onTheme,
                    ),
                    const SizedBox(width: 8),
                    _MapChip(
                      icon: Icons.card_giftcard_rounded,
                      onTap: onReward,
                      showBadge: hasUnclaimedReward,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            Semantics(
              button: true,
              label: 'Open profile',
              child: InkWell(
                onTap: onProfile,
                customBorder: const CircleBorder(),
                child: ProfileAvatar(
                  fullName: user?.fullName ?? '',
                  avatarUrl: user?.avatarUrl,
                  size: 44,
                  showBorder: true,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RightControls extends StatelessWidget {
  const _RightControls({
    required this.viewportSize,
    required this.onRecenter,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onShowAllMarkers,
  });

  final Size viewportSize;
  final VoidCallback onRecenter;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onShowAllMarkers;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: 14,
      top: math.max(110, viewportSize.height / 2 - 102),
      child: Column(
        children: [
          _MapIconButton(
            icon: Icons.gps_fixed_rounded,
            tooltip: 'Show all markers',
            onTap: onShowAllMarkers,
          ),
          const SizedBox(height: 10),
          _MapIconButton(
            icon: Icons.add_rounded,
            tooltip: 'Zoom in',
            onTap: onZoomIn,
          ),
          const SizedBox(height: 10),
          _MapIconButton(
            icon: Icons.remove_rounded,
            tooltip: 'Zoom out',
            onTap: onZoomOut,
          ),
          const SizedBox(height: 10),
          _MapIconButton(
            icon: Icons.navigation_rounded,
            tooltip: 'Recenter map',
            onTap: onRecenter,
          ),
        ],
      ),
    );
  }
}

class _AreaLabel extends StatelessWidget {
  const _AreaLabel({required this.label, required this.bottomInset});

  final String label;
  final double bottomInset;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      bottom: 92 + bottomInset,
      left: 0,
      right: 0,
      child: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 260),
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 7),
          decoration: BoxDecoration(
            color: context.appColors.mapPanel.withValues(alpha: 0.94),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: context.colors.primary.withValues(alpha: 0.33),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.location_on_rounded,
                  size: 15, color: context.colors.primary),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.labelMedium?.copyWith(
                    color: context.appColors.onMapPanel,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AssistantBar extends StatelessWidget {
  const _AssistantBar({required this.bottomInset, required this.onTap});

  final double bottomInset;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 16,
      right: 16,
      bottom: 20 + bottomInset,
      child: Material(
        color: context.appColors.mapPanel.withValues(alpha: 0.97),
        borderRadius: BorderRadius.circular(20),
        elevation: 12,
        shadowColor: Colors.black.withValues(alpha: 0.5),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
            child: Row(
              children: [
                Icon(Icons.auto_awesome,
                    color: context.colors.primary, size: 21),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Ask about this area…',
                    style: context.text.bodyMedium?.copyWith(
                      color: context.appColors.mapPanelMuted,
                    ),
                  ),
                ),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: context.colors.primary,
                    borderRadius: const BorderRadius.all(Radius.circular(10)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 11, vertical: 6),
                    child: Text(
                      'AI',
                      style: context.text.labelSmall?.copyWith(
                        color: context.colors.onPrimary,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LocationStatusCard extends StatelessWidget {
  const _LocationStatusCard({
    required this.hasLocation,
    required this.onEnable,
    required this.onClose,
  });

  final bool hasLocation;
  final VoidCallback onEnable;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final appColors = context.appColors;
    final colors = context.colors;

    return Positioned(
      top: MediaQuery.paddingOf(context).top + 76,
      left: 16,
      right: 16,
      child: Material(
        color: appColors.mapPanel,
        elevation: 10,
        shadowColor: Colors.black.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 13, 8, 13),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: colors.primary.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  hasLocation
                      ? Icons.gps_fixed_rounded
                      : Icons.location_off_rounded,
                  color: colors.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      hasLocation ? 'Location enabled' : 'Enable location',
                      style: TextStyle(
                        color: appColors.onMapPanel,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      hasLocation
                          ? 'Nearby Proximity Game markers are based on your approximate position.'
                          : 'Location access is disabled. Enable location permission to show your current location.',
                      style: TextStyle(
                        color: appColors.mapPanelMuted,
                        fontSize: 12,
                        height: 1.25,
                      ),
                    ),
                    if (!hasLocation) ...[
                      const SizedBox(height: 7),
                      TextButton(
                        onPressed: onEnable,
                        style: TextButton.styleFrom(
                          padding: EdgeInsets.zero,
                          minimumSize: const Size(0, 28),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: const Text('Enable location'),
                      ),
                    ],
                  ],
                ),
              ),
              AppCloseButton(onTap: onClose, color: appColors.mapPanelMuted),
            ],
          ),
        ),
      ),
    );
  }
}

class _LoadingOverlay extends StatelessWidget {
  const _LoadingOverlay();

  @override
  Widget build(BuildContext context) {
    return const Positioned.fill(
      child: ColoredBox(
        color: Color(0xAA03152E),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: Color(0xFF38BDF8)),
              SizedBox(height: 16),
              Text(
                'Finding nearby games...',
                style:
                    TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MapErrorOverlay extends StatelessWidget {
  const _MapErrorOverlay({required this.message, required this.onRetry});

  final String? message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final appColors = context.appColors;

    return Positioned.fill(
      child: ColoredBox(
        color: const Color(0xD903152E),
        child: Center(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 360),
            margin: const EdgeInsets.all(24),
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              color: appColors.mapPanel,
              borderRadius: BorderRadius.circular(22),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.cloud_off_rounded,
                    color: Color(0xFFDC2626), size: 36),
                const SizedBox(height: 12),
                Text(
                  'Map unavailable',
                  style: TextStyle(
                    color: appColors.onMapPanel,
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  message ?? 'Unable to load the map.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: appColors.mapPanelMuted, height: 1.35),
                ),
                const SizedBox(height: 18),
                FilledButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MapAttribution extends StatelessWidget {
  const _MapAttribution({required this.isGoogle, required this.googleCopyright});

  final bool isGoogle;
  final String? googleCopyright;

  @override
  Widget build(BuildContext context) {
    final label = isGoogle
        ? 'Google  ${googleCopyright ?? '© Google'}'
        : '© OpenStreetMap contributors';
    return Positioned(
      right: 4,
      bottom: 78 + MediaQuery.paddingOf(context).bottom,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(3),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
            child: Text(
              label,
              style: const TextStyle(
                color: Color(0xFF64748B),
                fontSize: 7,
                fontWeight: FontWeight.w500,
                height: 1.1,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FallbackNotice extends StatelessWidget {
  const _FallbackNotice(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 12,
      bottom: 115,
      child: IgnorePointer(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 280),
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xE603152E),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Text(
            message,
            style: const TextStyle(color: Colors.white, fontSize: 10),
          ),
        ),
      ),
    );
  }
}

class _MapChip extends StatelessWidget {
  const _MapChip({
    required this.icon,
    required this.onTap,
    this.label,
    this.showBadge = false,
    super.key,
  });

  final IconData icon;
  final String? label;
  final VoidCallback onTap;

  // A small red notification dot layered on the icon — same purpose and
  // styling as the one on a Theme Souvenir card in the Rewards list itself
  // (_RewardLeadingIcon), so there's something ready to claim without
  // needing to open Rewards first to notice it.
  final bool showBadge;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.appColors.mapPanel,
      elevation: 7,
      shadowColor: Colors.black.withValues(alpha: 0.35),
      borderRadius: AppRadius.brMd,
      child: InkWell(
        borderRadius: AppRadius.brMd,
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: label == null ? 11 : 13,
            vertical: 10,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(icon, color: context.colors.primary, size: 19),
                  if (showBadge)
                    Positioned(
                      top: -3,
                      right: -3,
                      child: Container(
                        width: 10,
                        height: 10,
                        decoration: const BoxDecoration(
                          color: Color(0xFFB3261E),
                          shape: BoxShape.circle,
                          border: Border.fromBorderSide(
                            BorderSide(color: Colors.white, width: 1.5),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              if (label != null) ...[
                const SizedBox(width: 6),
                Text(
                  label!,
                  style: context.text.labelMedium?.copyWith(
                    color: context.appColors.onMapPanel,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _MapIconButton extends StatelessWidget {
  const _MapIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: context.appColors.mapPanel,
        elevation: 8,
        shadowColor: Colors.black.withValues(alpha: 0.4),
        borderRadius: AppRadius.brMd,
        child: InkWell(
          borderRadius: AppRadius.brMd,
          onTap: onTap,
          child: SizedBox.square(
            dimension: 44,
            child: Icon(icon, color: context.appColors.onMapPanel, size: 21),
          ),
        ),
      ),
    );
  }
}
