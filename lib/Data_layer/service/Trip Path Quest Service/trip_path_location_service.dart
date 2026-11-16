import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

// ============================================================
// CURRENT LOCATION DATA
// ============================================================

class CurrentLocation {
  final double latitude;
  final double longitude;
  final double accuracy;

  const CurrentLocation({
    required this.latitude,
    required this.longitude,
    required this.accuracy,
  });

  @override
  String toString() {
    return 'CurrentLocation('
        'latitude: $latitude, '
        'longitude: $longitude, '
        'accuracy: $accuracy'
        ')';
  }
}

// ============================================================
// LOCATION SERVICE EXCEPTION
// ============================================================

class LocationServiceException implements Exception {
  final String message;

  const LocationServiceException(
    this.message,
  );

  @override
  String toString() => message;
}

// ============================================================
// LOCATION SERVICE
// ============================================================

class LocationService {
  // Quest search only needs a reasonably recent neighbourhood-level
  // position. Navigation still uses a fresh high-accuracy position.
  static const Duration questFreshLocationTimeout =
      Duration(seconds: 8);
  static const Duration recentQuestPositionMaxAge =
      Duration(minutes: 5);
  static const double recentQuestPositionMaxAccuracyMeters = 750;

  // ==========================================================
  // MAP HANDOFF SEED
  //
  // UC-03 -> UC-05: by the time Trip Path opens, the Map screen already has
  // a fresh tourist position. Seeding it here means the very first
  // nearby-attraction search (in startQuest()) starts from the exact same
  // coordinate Map used, instead of Trip Path taking its own independent
  // GPS fix that can drift and surface a different set of places/photos
  // for what should be the same real-world spot. Consumed on first use —
  // every later search (checkpoint replacement, CP2/3 background prep)
  // falls back to a live fix as normal, since the tourist may have moved.
  // ==========================================================

  CurrentLocation? _seed;
  DateTime? _seedAt;
  static const Duration _seedMaxAge = Duration(minutes: 5);

  void seedQuestSearchLocation(CurrentLocation location) {
    _seed = location;
    _seedAt = DateTime.now();
  }

  // ==========================================================
  // CHECK / REQUEST LOCATION PERMISSION
  // ==========================================================

  Future<void> ensureLocationPermission() async {
    final serviceEnabled =
        await Geolocator.isLocationServiceEnabled();

    if (!serviceEnabled) {
      throw const LocationServiceException(
        'Location is turned off. Please enable location services and try again.',
      );
    }

    LocationPermission permission =
        await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission =
          await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied) {
      throw const LocationServiceException(
        'Location permission is required to find nearby checkpoints.',
      );
    }

    if (permission == LocationPermission.deniedForever) {
      throw const LocationServiceException(
        'Location permission is permanently denied. '
        'Please enable it in app settings and try again.',
      );
    }
  }

  // ==========================================================
  // FAST QUEST-SEARCH LOCATION
  //
  // 1. Try a recent last-known position first.
  // 2. Otherwise request a fresh MEDIUM-accuracy position.
  // 3. Never wait more than 8 seconds for the fresh fix.
  //
  // This method is intentionally separate from navigation.
  // ==========================================================

  Future<CurrentLocation> getQuestSearchLocation() async {
    await ensureLocationPermission();

    final seed = _seed;
    final seedAt = _seedAt;
    if (seed != null && seedAt != null) {
      _seed = null;
      _seedAt = null;
      if (DateTime.now().difference(seedAt) <= _seedMaxAge) {
        if (kDebugMode) {
          debugPrint(
            "[GPS] Fast quest search: using the Map screen's position "
            '(${seed.latitude.toStringAsFixed(7)}, '
            '${seed.longitude.toStringAsFixed(7)}).',
          );
        }
        return seed;
      }
    }

    try {
      Position? recent;

      try {
        recent =
            await Geolocator.getLastKnownPosition()
                .timeout(
          const Duration(seconds: 2),
        );
      } on TimeoutException {
        if (kDebugMode) {
          debugPrint(
            '[GPS] Last-known-position lookup exceeded 2 seconds; '
            'switching to a fresh fix.',
          );
        }
      } catch (error) {
        if (kDebugMode) {
          debugPrint(
            '[GPS] Last-known-position unavailable: $error',
          );
        }
      }

      if (recent != null) {
        final age =
            DateTime.now().difference(recent.timestamp).abs();

        final freshEnough =
            age <= recentQuestPositionMaxAge;
        final accurateEnough =
            recent.accuracy <= recentQuestPositionMaxAccuracyMeters;

        if (freshEnough && accurateEnough) {
          if (kDebugMode) {
            debugPrint(
              '[GPS] Fast quest search: using recent position '
              '(${age.inSeconds}s old, '
              'accuracy ${recent.accuracy.toStringAsFixed(0)} m).',
            );
          }

          return _convertPosition(recent);
        }

        if (kDebugMode) {
          debugPrint(
            '[GPS] Recent position ignored: '
            'age=${age.inSeconds}s, '
            'accuracy=${recent.accuracy.toStringAsFixed(0)} m.',
          );
        }
      }

      const questSettings = LocationSettings(
        accuracy: LocationAccuracy.medium,
      );

      if (kDebugMode) {
        debugPrint(
          '[GPS] Requesting fresh medium-accuracy quest position '
          '(timeout ${questFreshLocationTimeout.inSeconds}s)...',
        );
      }

      final position =
          await Geolocator.getCurrentPosition(
        locationSettings: questSettings,
      ).timeout(
        questFreshLocationTimeout,
      );

      if (kDebugMode) {
        debugPrint(
          '[GPS] Fresh quest position ready: '
          '${position.latitude.toStringAsFixed(7)}, '
          '${position.longitude.toStringAsFixed(7)} | '
          'accuracy=${position.accuracy.toStringAsFixed(0)} m',
        );
      }

      return _convertPosition(position);
    } on TimeoutException {
      throw const LocationServiceException(
        'Unable to get your location within 8 seconds. '
        'Move near a window or open area and try again.',
      );
    } on LocationServiceException {
      rethrow;
    } catch (error) {
      throw LocationServiceException(
        'Unable to retrieve your location for quest search: $error',
      );
    }
  }

  // ==========================================================
  // HIGH-ACCURACY CURRENT LOCATION
  //
  // Navigation / Verify Visit continue using this path.
  // ==========================================================

  Future<CurrentLocation> getCurrentLocation() async {
    await ensureLocationPermission();

    try {
      const locationSettings = LocationSettings(
        accuracy: LocationAccuracy.high,
      );

      final position =
          await Geolocator.getCurrentPosition(
        locationSettings: locationSettings,
      );

      return _convertPosition(position);
    } on LocationServiceException {
      rethrow;
    } catch (error) {
      throw LocationServiceException(
        'Unable to retrieve current location: $error',
      );
    }
  }

  // ==========================================================
  // LIVE HIGH-ACCURACY LOCATION STREAM
  //
  // Navigation keeps the original high-accuracy behaviour.
  // ==========================================================

  Stream<CurrentLocation> getLocationStream({
    int distanceFilterMeters = 5,
  }) async* {
    await ensureLocationPermission();

    final locationSettings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: distanceFilterMeters,
    );

    try {
      await for (final position
          in Geolocator.getPositionStream(
        locationSettings: locationSettings,
      )) {
        yield _convertPosition(position);
      }
    } catch (error) {
      throw LocationServiceException(
        'Unable to monitor location: $error',
      );
    }
  }

  double calculateDistanceInMeters({
    required double startLatitude,
    required double startLongitude,
    required double endLatitude,
    required double endLongitude,
  }) {
    return Geolocator.distanceBetween(
      startLatitude,
      startLongitude,
      endLatitude,
      endLongitude,
    );
  }

  double calculateBearing({
    required double startLatitude,
    required double startLongitude,
    required double endLatitude,
    required double endLongitude,
  }) {
    return Geolocator.bearingBetween(
      startLatitude,
      startLongitude,
      endLatitude,
      endLongitude,
    );
  }

  Future<bool> openLocationSettings() {
    return Geolocator.openLocationSettings();
  }

  Future<bool> openAppSettings() {
    return Geolocator.openAppSettings();
  }

  CurrentLocation _convertPosition(
    Position position,
  ) {
    return CurrentLocation(
      latitude: position.latitude,
      longitude: position.longitude,
      accuracy: position.accuracy,
    );
  }
}
