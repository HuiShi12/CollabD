import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../../../Data_layer/repository/Claimed Places Repository/claimed_places.dart';
import '../../../Data_layer/repository/Map Repository/map.dart';
import '../../../Data_layer/repository/Reward Repository/reward_repository.dart';
import '../../../Data_layer/repository/User Repository/current_tourist.dart';
import '../../../Data_layer/service/Location Service/location.dart';

enum MapLoadState { idle, loading, ready, error }

/// UC-03 View Map.
class MapViewModel extends ChangeNotifier {
  MapViewModel({
    required MapRepository mapRepository,
    required LocationService locationService,
    ClaimedPlacesRepository? claimedPlacesRepository,
    RewardRepository? rewardRepository,
  })  : _mapRepository = mapRepository,
        _locationService = locationService,
        _claimedPlacesRepository = claimedPlacesRepository,
        _rewardRepository = rewardRepository;

  final MapRepository _mapRepository;
  final LocationService _locationService;

  /// Optional — absent in existing tests, treated as "nothing claimed yet".
  final ClaimedPlacesRepository? _claimedPlacesRepository;

  /// Optional — absent in existing tests, treated as "no skin equipped".
  final RewardRepository? _rewardRepository;

  MapLoadState _loadState = MapLoadState.idle;
  TouristPosition? _touristPosition;
  List<HiddenPlaceMarker> _markers = const [];
  HiddenPlaceMarker? _selectedMarker;
  String? _mapErrorMessage;
  bool _locationPermissionDenied = false;
  bool _showLocationStatus = false;

  /// UC-03 — live position tracking (started once the initial GPS fix
  /// succeeds; see [_startWatchingPosition]).
  StreamSubscription<({double latitude, double longitude})>?
      _positionSubscription;

  /// Where [_markers] was last computed from — re-running the (rate-limited,
  /// billed) Places lookup on every single GPS tick would be wasteful and
  /// noisy; only refresh once the tourist has actually moved a meaningful
  /// distance from here.
  ({double latitude, double longitude})? _markersRefreshedAt;
  static const double _markersRefreshDistanceMeters = 300;

  /// The Map screen's provider disposes this view model when the tourist leaves
  /// (into a game, the profile, or an auth-state rebuild). [loadMap] has long
  /// awaits (GPS fix, Places lookup) that can finish after that, so every
  /// notify goes through [_safeNotify] and post-await code bails on [_disposed].
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    _positionSubscription?.cancel();
    super.dispose();
  }

  void _safeNotify() {
    if (_disposed) return;
    notifyListeners();
  }

  MapLoadState get loadState => _loadState;
  TouristPosition? get touristPosition => _touristPosition;
  List<HiddenPlaceMarker> get markers => _markers;
  HiddenPlaceMarker? get selectedMarker => _selectedMarker;
  String? get mapErrorMessage => _mapErrorMessage;
  bool get hasLocation => _touristPosition != null;
  bool get locationPermissionDenied => _locationPermissionDenied;
  bool get showLocationStatus => _showLocationStatus;

  String get areaLabel => _touristPosition?.areaLabel ?? 'Wangsa Maju, KL';

  /// UC-03 C3 / FR03_6 — the "the hidden place is somewhere in this area" circle
  /// drawn around each Proximity Game marker. It always exceeds the marker's
  /// generalisation offset so the real place stays inside the circle at every
  /// zoom level (the old fixed-pixel ring shrank away from it when zoomed in).
  double get markerSearchRadiusMeters =>
      MapRepository.maxGeneralisationOffsetKm * 1000 + 60;

  /// UC-03 BF-2..7.
  Future<void> loadMap() async {
    _loadState = MapLoadState.loading;
    _mapErrorMessage = null;
    _selectedMarker = null;
    _safeNotify();

    try {
      _touristPosition = await _locationService.getTouristPosition();
      _locationPermissionDenied = false;
      _markersRefreshedAt = (
        latitude: _touristPosition!.latitude,
        longitude: _touristPosition!.longitude,
      );
      _startWatchingPosition();
    } on LocationPermissionDeniedException {
      _touristPosition = null;
      _locationPermissionDenied = true;
      _showLocationStatus = true;
    } on LocationUnavailableException {
      _touristPosition = null;
      _locationPermissionDenied = true;
      _showLocationStatus = true;
    }
    if (_disposed) return;

    // UC-03 C6 — if no skin is equipped, or this fails, the marker just
    // keeps its default appearance; it must never block the map loading.
    if (_touristPosition != null && _rewardRepository != null) {
      try {
        final equipped = await _rewardRepository.getEquippedMarkerSkin(
          touristId: CurrentTourist.id,
        );
        if (equipped != null) {
          _touristPosition = _touristPosition!.copyWith(
            equippedMarkerSkinId: equipped.sourceId,
            equippedMarkerSkinImageUrl: equipped.imageUrl,
          );
        }
      } catch (_) {
        // Keep the position as-is; default marker.
      }
      if (_disposed) return;
    }

    await _refreshMarkers();
  }

  Future<void> _refreshMarkers() async {
    final claimed =
        await _claimedPlacesRepository?.getClaimedPlaceIds() ?? const {};
    if (_disposed) return;

    try {
      _markers = await _mapRepository.getProximityGameMarkers(
        position: _touristPosition,
        excludedPlaceIds: claimed,
      );
      _loadState = MapLoadState.ready;
      debugPrint(
        '[MAP] _refreshMarkers: claimed=${claimed.length} '
        'position=${_touristPosition?.latitude},${_touristPosition?.longitude} '
        'markers=${_markers.length}',
      );
      if (_touristPosition case final p?) {
        _markersRefreshedAt = (latitude: p.latitude, longitude: p.longitude);
      }
    } catch (e, st) {
      debugPrint('[MAP] _refreshMarkers failed: $e\n$st');
      _markers = const [];
      _loadState = MapLoadState.error;
      _mapErrorMessage =
          'Unable to load the map. Please check your Internet connection and try again.';
    }

    _safeNotify();
  }

  /// UC-03 — starts (or restarts) live GPS tracking so the tourist's marker
  /// follows real movement without reopening the Map screen. Once the
  /// tourist has walked [_markersRefreshDistanceMeters] from where the
  /// Proximity Game markers were last fetched, it also re-queries nearby
  /// hidden places — a fresh area can have new eligible places to discover.
  void _startWatchingPosition() {
    _positionSubscription?.cancel();
    _positionSubscription = _locationService.watchPosition().listen((pos) {
      if (_disposed) return;
      _touristPosition = _touristPosition?.copyWith(
        latitude: pos.latitude,
        longitude: pos.longitude,
      );
      _safeNotify();

      final refreshedAt = _markersRefreshedAt;
      if (refreshedAt == null) return;
      final movedMeters = Geolocator.distanceBetween(
        refreshedAt.latitude,
        refreshedAt.longitude,
        pos.latitude,
        pos.longitude,
      );
      if (movedMeters >= _markersRefreshDistanceMeters) {
        _refreshMarkers();
      }
    });
  }

  /// UC-03 A1 / A2 – "Retry" and "Enable location".
  Future<void> retry() => loadMap();
  Future<void> requestLocationAgain() => loadMap();

  /// UC-03 BF-10 – the tourist taps a Proximity Game marker.
  void selectMarker(HiddenPlaceMarker marker) {
    _selectedMarker = _selectedMarker?.id == marker.id ? null : marker;
    _safeNotify();
  }

  /// UC-03 BF-9 / "tap empty map" – dismiss the marker detail.
  void clearSelection() {
    if (_selectedMarker == null) return;
    _selectedMarker = null;
    _safeNotify();
  }

  void toggleLocationStatus() {
    _showLocationStatus = !_showLocationStatus;
    _safeNotify();
  }

  void openLocationStatus() {
    if (_showLocationStatus) return;
    _showLocationStatus = true;
    _safeNotify();
  }

  void hideLocationStatus() {
    if (!_showLocationStatus) return;
    _showLocationStatus = false;
    _safeNotify();
  }

  /// UC-03 A4 – Puzzle button: general Puzzle search, no preselected place.
  MapGameHandoff startGeneralPuzzleSearch() => _buttonHandoff(
        ProximityGameMode.puzzle,
        MapGameEntrySource.puzzleButton,
      );

  /// UC-03 A5 – Theme button: general Trip Path search, no preselected place.
  MapGameHandoff startGeneralTripPathSearch() => _buttonHandoff(
        ProximityGameMode.tripPath,
        MapGameEntrySource.themeButton,
      );

  /// UC-03 BF-12/13 – the tourist picks a game mode on the selected marker.
  /// Both Puzzle and Trip Path are always available from a marker (C8/A6).
  MapGameHandoff? selectMarkerGameMode(ProximityGameMode mode) {
    final marker = _selectedMarker;
    if (marker == null) return null;

    return MapGameHandoff(
      mode: mode,
      entrySource: MapGameEntrySource.proximityGameMarker,
      marker: marker,
      touristLatitude: _touristPosition?.latitude ?? 3.2056,
      touristLongitude: _touristPosition?.longitude ?? 101.7319,
    );
  }

  MapGameHandoff _buttonHandoff(
    ProximityGameMode mode,
    MapGameEntrySource source,
  ) {
    return MapGameHandoff(
      mode: mode,
      entrySource: source,
      marker: null,
      touristLatitude: _touristPosition?.latitude ?? 3.2056,
      touristLongitude: _touristPosition?.longitude ?? 101.7319,
    );
  }
}
