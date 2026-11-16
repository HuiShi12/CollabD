import 'package:collab_d/Data_layer/repository/Map Repository/map.dart';
import 'package:collab_d/Data_layer/service/Location Service/location.dart';
import 'package:collab_d/External_services/Google Maps Platform and Location Services/gm.dart';
import 'package:collab_d/UI_layer/viewmodel/Map ViewModel/map_viewmodel.dart';
import 'package:flutter_test/flutter_test.dart';

LocationService _demoLocation() => LocationService(GoogleMapsPlatformExternal());
// Pinned to the bundled sample data's own calibrated 5km, independent of
// whatever radius MapRepository ships with in production — these tests
// exercise the distance-cutoff behaviour itself, not a specific tuning value.
MapRepository _demoRepo({double? maxProximityRadiusKm}) => MapRepository(
      _demoLocation(),
      maxProximityRadiusKm: maxProximityRadiusKm ?? 5,
    );

void main() {
  group('UC-03 View Map data rules', () {
    test('shows one neutral marker per eligible nearby hidden place, '
        'nearer first, excluding far / ineligible places', () async {
      final vm = MapViewModel(
        // Pinned to 5km (rather than the production default) so this test
        // keeps verifying the distance cutoff itself, independent of
        // whatever radius MapRepository ships with in production.
        mapRepository: _demoRepo(maxProximityRadiusKm: 5),
        locationService: _demoLocation(),
      );

      await vm.loadMap();

      expect(vm.loadState, MapLoadState.ready);
      expect(vm.markers, hasLength(6));
      expect(
        vm.markers.map((m) => m.distanceKm),
        orderedEquals(<double>[1.3, 2.2, 2.6, 3.1, 3.8, 4.6]),
      );
      expect(vm.markers.any((m) => m.id == 'hp_area_07'), isFalse); // > 5 km
      expect(vm.markers.any((m) => m.id == 'hp_area_08'), isFalse); // rating < 4
    });

    test('marker sits on a generalised point, not the real attraction '
        'coordinate (C3 / FR03_6)', () async {
      final vm = MapViewModel(
        mapRepository: _demoRepo(),
        locationService: _demoLocation(),
      );
      await vm.loadMap();

      // hp_area_01 real coordinate is (3.2168, 101.7245).
      final marker = vm.markers.firstWhere((m) => m.id == 'hp_area_01');

      final latShiftKm = (marker.generalAreaLatitude - 3.2168).abs() * 111.0;
      final lngShiftKm = (marker.generalAreaLongitude - 101.7245).abs() * 111.0;
      final offsetKm = latShiftKm + lngShiftKm;

      expect(marker.generalAreaLatitude, isNot(3.2168));
      expect(marker.generalAreaLongitude, isNot(101.7245));
      expect(offsetKm, greaterThan(0.15)); // moved off the real point
      expect(offsetKm, lessThan(0.6)); // but still in the same block/area

      // Deterministic – a second load gives the same generalised point.
      final before = (marker.generalAreaLatitude, marker.generalAreaLongitude);
      await vm.loadMap();
      final again = vm.markers.firstWhere((m) => m.id == 'hp_area_01');
      expect(
        (again.generalAreaLatitude, again.generalAreaLongitude),
        before,
      );
    });

    test('Puzzle and Trip Path are both always available on every marker '
        '(C8) — Trip Path starts the same live checkpoint search the Theme '
        'button uses, so a marker never needs its own weaker pre-check',
        () async {
      final vm = MapViewModel(
        mapRepository: _demoRepo(),
        locationService: _demoLocation(),
      );
      await vm.loadMap();

      expect(vm.markers, isNotEmpty);
      expect(
        vm.markers.every((m) => m.availabilityFor(ProximityGameMode.puzzle)),
        isTrue,
      );
      expect(
        vm.markers
            .every((m) => m.availabilityFor(ProximityGameMode.tripPath)),
        isTrue,
      );
    });

    test('keeps the map available with no markers when location is denied '
        '(A2 / C2)', () async {
      final vm = MapViewModel(
        mapRepository: _demoRepo(),
        locationService:
            LocationService(GoogleMapsPlatformExternal(), simulateLocationDenied: true),
      );

      await vm.loadMap();

      expect(vm.loadState, MapLoadState.ready);
      expect(vm.hasLocation, isFalse);
      expect(vm.locationPermissionDenied, isTrue);
      expect(vm.markers, isEmpty);
      expect(vm.showLocationStatus, isTrue);
    });

    test('exposes a retryable error when the map cannot be loaded (A1)',
        () async {
      final vm = MapViewModel(
        mapRepository: _FailingMapRepository(),
        locationService: _demoLocation(),
      );

      await vm.loadMap();

      expect(vm.loadState, MapLoadState.error);
      expect(vm.mapErrorMessage, contains('Unable to load the map'));
    });

    test('an in-flight load survives the screen being disposed '
        '(provider torn down by an auth-state rebuild)', () async {
      final vm = MapViewModel(
        mapRepository: _demoRepo(),
        locationService: _demoLocation(),
      );

      final pending = vm.loadMap();
      vm.dispose(); // provider disposes the view model mid-load

      // No "used after being disposed" from a late notifyListeners().
      await expectLater(pending, completes);
    });
  });

  group('UC-03 game entry source (C9 / FR03_9)', () {
    test('Puzzle button starts a general search with no preselected place',
        () async {
      final vm = MapViewModel(
        mapRepository: _demoRepo(),
        locationService: _demoLocation(),
      );
      await vm.loadMap();

      final handoff = vm.startGeneralPuzzleSearch();

      expect(handoff.mode, ProximityGameMode.puzzle);
      expect(handoff.entrySource, MapGameEntrySource.puzzleButton);
      expect(handoff.marker, isNull);
      expect(handoff.isMarkerSpecific, isFalse);
    });

    test('Theme button starts a general Trip Path search', () async {
      final vm = MapViewModel(
        mapRepository: _demoRepo(),
        locationService: _demoLocation(),
      );
      await vm.loadMap();

      final handoff = vm.startGeneralTripPathSearch();

      expect(handoff.mode, ProximityGameMode.tripPath);
      expect(handoff.entrySource, MapGameEntrySource.themeButton);
      expect(handoff.marker, isNull);
    });

    test('marker selection passes the place, mode and marker entry source; '
        'both Puzzle and Trip Path are always selectable (C8)', () async {
      final vm = MapViewModel(
        mapRepository: _demoRepo(),
        locationService: _demoLocation(),
      );
      await vm.loadMap();

      final heritage =
          vm.markers.firstWhere((m) => m.generalCategory == 'Heritage Site');
      final other =
          vm.markers.firstWhere((m) => m.generalCategory != 'Heritage Site');

      vm.selectMarker(heritage);
      final puzzleHandoff = vm.selectMarkerGameMode(ProximityGameMode.puzzle);
      final tripHandoff = vm.selectMarkerGameMode(ProximityGameMode.tripPath);

      expect(puzzleHandoff, isNotNull);
      expect(puzzleHandoff!.entrySource,
          MapGameEntrySource.proximityGameMarker);
      expect(puzzleHandoff.marker?.id, heritage.id);
      expect(tripHandoff, isNotNull);
      // FR03_9 — a Trip-Path-eligible marker carries its theme id so the
      // marker entry can jump straight into that theme (see TripPathQuestModule).
      expect(tripHandoff!.marker?.routeGroup, 'heritage');

      vm.selectMarker(other);
      expect(vm.selectMarkerGameMode(ProximityGameMode.puzzle), isNotNull);
      expect(vm.selectMarkerGameMode(ProximityGameMode.tripPath), isNotNull);
    });
  });
}

class _FailingMapRepository extends MapRepository {
  _FailingMapRepository() : super(_demoLocation());

  @override
  Future<List<HiddenPlaceMarker>> getProximityGameMarkers({
    required TouristPosition? position,
    Set<String> excludedPlaceIds = const {},
  }) {
    throw StateError('Map service unavailable');
  }
}
