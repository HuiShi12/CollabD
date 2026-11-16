import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../Data_layer/service/Trip Path Quest Service/trip_path_location_service.dart';

// ============================================================
// PHOTO-VERIFICATION GPS RECHECK RESULT
//
// A fresh GPS sample is requested immediately before photo verification.
// GPS is supporting anti-spoof / wrong-branch evidence; it never proves that
// the photo is correct by itself. Poor GPS accuracy also never turns a photo
// into Not Verified -- the app asks the user to retry the location check.
// ============================================================

enum TripPathGpsVerificationStatus {
  confirmed,
  uncertain,
  outside,
  unavailable,
}

class TripPathGpsVerificationCheck {
  final TripPathGpsVerificationStatus status;
  final double? distanceMeters;
  final double? accuracyMeters;
  final String message;

  const TripPathGpsVerificationCheck({
    required this.status,
    required this.distanceMeters,
    required this.accuracyMeters,
    required this.message,
  });

  bool get confirmed => status == TripPathGpsVerificationStatus.confirmed;
}

// ============================================================
// TRIP PATH QUEST NAVIGATION
//
// Responsibilities:
//
// - Get real phone GPS
// - Monitor user's live location
// - Calculate distance to checkpoint
// - Calculate direction / bearing
// - Unlock Verify Visit within 50 metres
// - Handle navigation loading / error state
//
// This class does NOT know anything about:
// - Theme
// - Gemini
// - Clues
// - Quest progress
//
// Those remain inside TripPathQuestViewModel.
// ============================================================

class TripPathQuestNavigation extends ChangeNotifier {
  final LocationService locationService;

  TripPathQuestNavigation({
    required this.locationService,
  });

  // ============================================================
  // VERIFY VISIT DISTANCE
  // ============================================================

  static const double verifyDistanceMeters = 50.0;

  // ============================================================
  // TARGET CHECKPOINT
  // ============================================================

  double? _targetLatitude;
  double? _targetLongitude;

  // Debug-only context so terminal logs clearly show which
  // checkpoint the current navigation session belongs to.
  int? _targetCheckpointNumber;

  // ============================================================
  // USER LOCATION
  // ============================================================

  CurrentLocation? _currentLocation;

  // ============================================================
  // NAVIGATION STATE
  // ============================================================

  double? _distanceMeters;
  double? _bearingDegrees;

  bool _isLoading = false;
  bool _isTracking = false;

  // Manual "Refresh Location" state.
  //
  // This is intentionally separate from _isLoading because a manual
  // refresh should NOT blank the map / distance and should never make
  // the whole Navigation page look stuck on loading.
  bool _isRefreshingLocation = false;

  String? _errorMessage;

  // ============================================================
  // LOCATION STREAM
  // ============================================================

  StreamSubscription<CurrentLocation>? _locationSubscription;

  // ============================================================
  // SESSION VERSION
  //
  // Prevents old GPS callbacks from updating a new checkpoint.
  // ============================================================

  int _navigationSession = 0;

  // ============================================================
  // GETTERS
  // ============================================================

  CurrentLocation? get currentLocation =>
      _currentLocation;

  double? get targetLatitude =>
      _targetLatitude;

  double? get targetLongitude =>
      _targetLongitude;

  int? get targetCheckpointNumber =>
      _targetCheckpointNumber;

  double? get distanceMeters =>
      _distanceMeters;

  double? get bearingDegrees =>
      _bearingDegrees;

  bool get isLoading =>
      _isLoading;

  bool get isTracking =>
      _isTracking;

  bool get isRefreshingLocation =>
      _isRefreshingLocation;

  String? get errorMessage =>
      _errorMessage;

  bool get hasCurrentLocation =>
      _currentLocation != null;

  bool get hasTarget =>
      _targetLatitude != null &&
          _targetLongitude != null;

  // ============================================================
  // VERIFY VISIT
  //
  // UC-05:
  // Tourist must be within 50 metres.
  // ============================================================

  bool get canVerifyVisit {
    final distance = _distanceMeters;

    if (distance == null) {
      return false;
    }

    return distance <=
        verifyDistanceMeters;
  }

  // ============================================================
  // DISTANCE DISPLAY
  // ============================================================

  String get distanceText {
    final distance = _distanceMeters;

    if (distance == null) {
      return 'Calculating distance...';
    }

    if (distance < 1000) {
      return '${distance.round()} m away';
    }

    return '${(distance / 1000).toStringAsFixed(1)} km away';
  }

  // ============================================================
  // GPS ACCURACY DISPLAY
  // ============================================================

  String get accuracyText {
    final accuracy =
        _currentLocation?.accuracy;

    if (accuracy == null) {
      return 'GPS accuracy unavailable';
    }

    return 'GPS accuracy: ${accuracy.round()} m';
  }

  // ============================================================
  // DIRECTION
  //
  // Bearing:
  //
  // 0°   = North
  // 90°  = East
  // 180° = South
  // 270° = West
  // ============================================================

  String get directionText {
    final bearing = _bearingDegrees;

    if (bearing == null) {
      return 'Finding direction...';
    }

    final normalized =
        (bearing + 360) % 360;

    if (normalized >= 337.5 ||
        normalized < 22.5) {
      return 'North';
    }

    if (normalized < 67.5) {
      return 'North-East';
    }

    if (normalized < 112.5) {
      return 'East';
    }

    if (normalized < 157.5) {
      return 'South-East';
    }

    if (normalized < 202.5) {
      return 'South';
    }

    if (normalized < 247.5) {
      return 'South-West';
    }

    if (normalized < 292.5) {
      return 'West';
    }

    return 'North-West';
  }

  // ============================================================
  // START NAVIGATION
  //
  // Called by TripPathQuestViewModel when user presses:
  //
  // Navigate
  //
  // Example:
  //
  // navigation.start(
  //   latitude: attraction.latitude,
  //   longitude: attraction.longitude,
  // );
  // ============================================================

  Future<void> start({
    required double latitude,
    required double longitude,
    int? checkpointNumber,
  }) async {
    // ----------------------------------------------------------
    // IMPORTANT:
    //
    // Invalidate the old session AND reset its distance/bearing
    // synchronously, BEFORE waiting for the old stream to cancel.
    //
    // This prevents Checkpoint 2 / 3 from briefly inheriting
    // Checkpoint 1's distance or Verify Visit state.
    // ----------------------------------------------------------

    _navigationSession++;

    final session =
        _navigationSession;

    final oldSubscription =
        _locationSubscription;

    // Detach immediately. Old callbacks are already invalidated
    // by the new session number.
    _locationSubscription = null;

    // Save the NEW target before any await.
    _targetLatitude = latitude;
    _targetLongitude = longitude;
    _targetCheckpointNumber =
        checkpointNumber;

    // Clear ALL state belonging to the previous checkpoint.
    _currentLocation = null;
    _distanceMeters = null;
    _bearingDegrees = null;
    _errorMessage = null;

    _isLoading = true;
    _isTracking = false;

    debugPrint('');
    debugPrint(
      '==========================================',
    );
    debugPrint(
      '======= START CHECKPOINT NAVIGATION ======',
    );
    debugPrint(
      '==========================================',
    );
    debugPrint(
      'Checkpoint: '
      '${checkpointNumber ?? "-"}',
    );
    debugPrint(
      'New Target GPS: '
      '${latitude.toStringAsFixed(7)}, '
      '${longitude.toStringAsFixed(7)}',
    );
    debugPrint(
      'Old distance/bearing state: CLEARED',
    );
    debugPrint(
      'Verify Visit: LOCKED until new GPS is calculated',
    );
    debugPrint(
      '==========================================',
    );
    debugPrint('');

    notifyListeners();

    // Only now wait for the old location stream to finish
    // cancelling.
    await oldSubscription?.cancel();

    // A newer start()/stop() may have happened while awaiting.
    if (session != _navigationSession) {
      return;
    }

    try {
      // ========================================================
      // FIRST LOCATION
      // ========================================================

      final firstLocation =
      await locationService
          .getCurrentLocation()
          .timeout(
        const Duration(
          seconds: 12,
        ),
      );

      if (session !=
          _navigationSession) {
        return;
      }

      _updateLocation(
        firstLocation,
      );

      // ========================================================
      // LIVE TRACKING
      // ========================================================

      _locationSubscription =
          locationService
              .getLocationStream(
            distanceFilterMeters: 5,
          )
              .listen(
                (location) {
              if (session !=
                  _navigationSession) {
                return;
              }

              _updateLocation(
                location,
              );
            },
            onError: (Object error) {
              if (session !=
                  _navigationSession) {
                return;
              }

              _errorMessage =
              'Unable to update your location. '
                  'Please try again.';

              debugPrint(
                'Trip Path Quest GPS stream error: '
                    '$error',
              );

              notifyListeners();
            },
          );

      _isTracking = true;
    } on LocationServiceException catch (
    error) {
      if (session !=
          _navigationSession) {
        return;
      }

      _errorMessage =
          error.message;

      debugPrint(
        'Trip Path Quest navigation error: '
            '${error.message}',
      );
    } catch (error) {
      if (session !=
          _navigationSession) {
        return;
      }

      _errorMessage =
      'Unable to get your current location. '
          'Please try again.';

      debugPrint(
        'Unexpected Trip Path Quest navigation error: '
            '$error',
      );
    } finally {
      if (session ==
          _navigationSession) {
        _isLoading = false;

        notifyListeners();
      }
    }
  }

  // ============================================================
  // UPDATE USER LOCATION
  // ============================================================

  void _updateLocation(
      CurrentLocation location,
      ) {
    final targetLat =
        _targetLatitude;

    final targetLng =
        _targetLongitude;

    if (targetLat == null ||
        targetLng == null) {
      return;
    }

    _currentLocation = location;

    // ==========================================================
    // DISTANCE
    // ==========================================================

    _distanceMeters =
        locationService
            .calculateDistanceInMeters(
          startLatitude:
          location.latitude,
          startLongitude:
          location.longitude,
          endLatitude:
          targetLat,
          endLongitude:
          targetLng,
        );

    // ==========================================================
    // DIRECTION / BEARING
    // ==========================================================

    _bearingDegrees =
        locationService
            .calculateBearing(
          startLatitude:
          location.latitude,
          startLongitude:
          location.longitude,
          endLatitude:
          targetLat,
          endLongitude:
          targetLng,
        );

    _errorMessage = null;

    // ==========================================================
    // DEBUG
    // ==========================================================

    debugPrint(
      '========== NAVIGATION UPDATE ==========',
    );

    debugPrint(
      'Checkpoint: '
          '${_targetCheckpointNumber ?? "-"}',
    );

    debugPrint(
      'User GPS: '
          '${location.latitude}, '
          '${location.longitude}',
    );

    debugPrint(
      'Target GPS: '
          '$targetLat, '
          '$targetLng',
    );

    debugPrint(
      'Distance: '
          '${_distanceMeters?.toStringAsFixed(1)} m',
    );

    debugPrint(
      'Direction: '
          '$directionText',
    );

    debugPrint(
      'GPS accuracy: '
          '${location.accuracy.toStringAsFixed(1)} m',
    );

    debugPrint(
      'Verify Visit: '
          '${canVerifyVisit ? "UNLOCKED" : "LOCKED"}',
    );

    notifyListeners();
  }

  // ============================================================
  // FRESH GPS RECHECK BEFORE PHOTO VERIFICATION
  //
  // The navigation stream may be several seconds old by the time the user
  // presses Verify Photo. Request one fresh high-accuracy sample here so a
  // photo from another branch / remote place cannot rely on stale proximity.
  //
  // Important safety behaviour:
  // - <= 50 m on the fresh fix: confirmed.
  // - If GPS uncertainty overlaps the 50 m boundary: uncertain, ask to retry.
  // - Clearly outside even after accounting for reported accuracy: outside.
  // - GPS failure: unavailable, do not run image verification yet.
  //
  // GPS NEVER verifies an image by itself.
  // ============================================================

  // A fresh fix that is less precise than this is treated as UNCERTAIN rather
  // than pass/fail. This prevents GPS drift from falsely confirming or
  // rejecting a photo-verification attempt.
  static const double photoVerificationMaxAccuracyMeters = 45.0;

  Future<TripPathGpsVerificationCheck> recheckForPhotoVerification() async {
    final targetLat = _targetLatitude;
    final targetLng = _targetLongitude;
    final checkpoint = _targetCheckpointNumber;
    final session = _navigationSession;

    if (targetLat == null || targetLng == null) {
      return const TripPathGpsVerificationCheck(
        status: TripPathGpsVerificationStatus.unavailable,
        distanceMeters: null,
        accuracyMeters: null,
        message: 'Checkpoint location is unavailable. Return to navigation and try again.',
      );
    }

    debugPrint('[GPS VERIFY] Fresh location recheck started for CP${checkpoint ?? "-"}.');

    try {
      final fresh = await locationService
          .getCurrentLocation()
          .timeout(const Duration(seconds: 8));

      if (session != _navigationSession ||
          _targetLatitude != targetLat ||
          _targetLongitude != targetLng) {
        return const TripPathGpsVerificationCheck(
          status: TripPathGpsVerificationStatus.unavailable,
          distanceMeters: null,
          accuracyMeters: null,
          message: 'The checkpoint changed while location was updating. Please try again.',
        );
      }

      _updateLocation(fresh);

      final distance = _distanceMeters;
      if (distance == null) {
        return const TripPathGpsVerificationCheck(
          status: TripPathGpsVerificationStatus.unavailable,
          distanceMeters: null,
          accuracyMeters: null,
          message: 'Unable to calculate your distance from this checkpoint. Please try again.',
        );
      }

      final rawAccuracy = fresh.accuracy;
      final accuracy = rawAccuracy.isFinite && rawAccuracy >= 0
          ? rawAccuracy
          : 999.0;

      if (accuracy > photoVerificationMaxAccuracyMeters) {
        debugPrint(
          '[GPS VERIFY] UNCERTAIN CP${checkpoint ?? "-"}: '
          'GPS accuracy=${accuracy.toStringAsFixed(1)} m is too weak for the final check.',
        );
        return TripPathGpsVerificationCheck(
          status: TripPathGpsVerificationStatus.uncertain,
          distanceMeters: distance,
          accuracyMeters: accuracy,
          message: 'GPS accuracy is temporarily too weak to confirm this visit. '
              'Stay near the checkpoint or move to a more open area, wait a moment, then try Verify Photo again.',
        );
      }

      if (distance <= verifyDistanceMeters) {
        debugPrint(
          '[GPS VERIFY] PASS CP${checkpoint ?? "-"}: '
          '${distance.toStringAsFixed(1)} m away, accuracy=${accuracy.toStringAsFixed(1)} m.',
        );
        return TripPathGpsVerificationCheck(
          status: TripPathGpsVerificationStatus.confirmed,
          distanceMeters: distance,
          accuracyMeters: accuracy,
          message: 'Location confirmed. Photo verification can continue.',
        );
      }

      // If the reported accuracy circle still overlaps the allowed 50 m
      // radius, do not falsely reject the player because of GPS drift.
      final nearestPlausibleDistance = distance - accuracy;
      if (nearestPlausibleDistance <= verifyDistanceMeters) {
        debugPrint(
          '[GPS VERIFY] UNCERTAIN CP${checkpoint ?? "-"}: '
          '${distance.toStringAsFixed(1)} m away, accuracy=${accuracy.toStringAsFixed(1)} m.',
        );
        return TripPathGpsVerificationCheck(
          status: TripPathGpsVerificationStatus.uncertain,
          distanceMeters: distance,
          accuracyMeters: accuracy,
          message: 'GPS is not precise enough to confirm that you are still within 50 m. '
              'Stay near the checkpoint, wait a moment, then try Verify Photo again.',
        );
      }

      debugPrint(
        '[GPS VERIFY] OUTSIDE CP${checkpoint ?? "-"}: '
        '${distance.toStringAsFixed(1)} m away, accuracy=${accuracy.toStringAsFixed(1)} m.',
      );
      return TripPathGpsVerificationCheck(
        status: TripPathGpsVerificationStatus.outside,
        distanceMeters: distance,
        accuracyMeters: accuracy,
        message: 'You are no longer close enough to this checkpoint. Move within 50 m before verifying the photo.',
      );
    } on TimeoutException {
      debugPrint('[GPS VERIFY] Timed out waiting for a fresh GPS fix.');
      return const TripPathGpsVerificationCheck(
        status: TripPathGpsVerificationStatus.unavailable,
        distanceMeters: null,
        accuracyMeters: null,
        message: 'Fresh GPS confirmation timed out. Stay near the checkpoint and try again.',
      );
    } on LocationServiceException catch (error) {
      debugPrint('[GPS VERIFY] Location service error: ${error.message}');
      return TripPathGpsVerificationCheck(
        status: TripPathGpsVerificationStatus.unavailable,
        distanceMeters: null,
        accuracyMeters: null,
        message: error.message,
      );
    } catch (error) {
      debugPrint('[GPS VERIFY] Unexpected GPS recheck error: $error');
      return const TripPathGpsVerificationCheck(
        status: TripPathGpsVerificationStatus.unavailable,
        distanceMeters: null,
        accuracyMeters: null,
        message: 'Unable to confirm your current location. Please try again.',
      );
    }
  }

  // ============================================================
  // REFRESH CURRENT LOCATION
  //
  // Used by the "Refresh Location" menu item.
  //
  // IMPORTANT:
  // This does NOT restart the live GPS stream when a valid
  // navigation session is already running.
  //
  // It only asks the phone for one fresh GPS sample and recalculates:
  // - distance
  // - bearing / direction
  // - Verify Visit state
  //
  // The previous distance stays visible while refreshing.
  // ============================================================

  Future<void> refreshCurrentLocation() async {
    final latitude =
        _targetLatitude;

    final longitude =
        _targetLongitude;

    if (latitude == null ||
        longitude == null) {
      _errorMessage =
          'Checkpoint location is unavailable.';

      notifyListeners();

      return;
    }

    // If the navigation screen never obtained its first GPS fix,
    // perform a safe full restart instead.
    if (_currentLocation == null ||
        !_isTracking) {
      await start(
        latitude:
            latitude,
        longitude:
            longitude,
        checkpointNumber:
            _targetCheckpointNumber,
      );

      return;
    }

    // Prevent repeated taps while one manual refresh is running.
    if (_isRefreshingLocation) {
      return;
    }

    _isRefreshingLocation = true;

    debugPrint('');
    debugPrint(
      '========== REFRESH LOCATION ==========',
    );
    debugPrint(
      'Checkpoint: '
          '${_targetCheckpointNumber ?? "-"}',
    );
    debugPrint(
      'Refreshing one GPS sample...',
    );

    notifyListeners();

    try {
      final freshLocation =
          await locationService
              .getCurrentLocation()
              .timeout(
        const Duration(
          seconds: 8,
        ),
      );

      // A checkpoint change / stop may have happened while waiting.
      if (_targetLatitude != latitude ||
          _targetLongitude != longitude) {
        return;
      }

      _updateLocation(
        freshLocation,
      );

      debugPrint(
        'Refresh Location: SUCCESS',
      );
    } on TimeoutException {
      // Keep the previous valid location/distance on screen.
      _errorMessage =
          'Location refresh timed out. Live GPS will keep updating automatically.';

      debugPrint(
        'Refresh Location: TIMED OUT after 8 seconds',
      );
    } on LocationServiceException catch (
    error) {
      _errorMessage =
          error.message;

      debugPrint(
        'Refresh Location failed: '
            '${error.message}',
      );
    } catch (error) {
      _errorMessage =
          'Unable to refresh your location. Live GPS will keep updating automatically.';

      debugPrint(
        'Unexpected Refresh Location error: $error',
      );
    } finally {
      _isRefreshingLocation = false;

      notifyListeners();
    }
  }

  // ============================================================
  // STOP NAVIGATION
  //
  // Called when:
  //
  // - User presses Back
  // - User completes checkpoint
  // - User resets quest
  // - User selects another theme
  // ============================================================

  Future<void> stop() async {
    // ----------------------------------------------------------
    // Invalidate old callbacks immediately.
    // ----------------------------------------------------------

    _navigationSession++;

    final session =
        _navigationSession;

    final oldSubscription =
        _locationSubscription;

    _locationSubscription = null;

    // ----------------------------------------------------------
    // Clear state synchronously BEFORE await.
    //
    // This is important because completeCheckpoint() calls stop()
    // without waiting. CP2 may begin while the old stream is still
    // cancelling. The old stop must never clear CP2's new target.
    // ----------------------------------------------------------

    _targetLatitude = null;
    _targetLongitude = null;
    _targetCheckpointNumber = null;

    _currentLocation = null;

    _distanceMeters = null;
    _bearingDegrees = null;

    _isLoading = false;
    _isTracking = false;
    _isRefreshingLocation = false;

    _errorMessage = null;

    notifyListeners();

    await oldSubscription?.cancel();

    // If a newer navigation session started during cancellation,
    // do nothing. Its state belongs to the new checkpoint.
    if (session != _navigationSession) {
      return;
    }
  }

  // ============================================================
  // OPEN PHONE LOCATION SETTINGS
  // ============================================================

  Future<void> openLocationSettings() async {
    await locationService
        .openLocationSettings();
  }

  // ============================================================
  // OPEN APP SETTINGS
  //
  // Used if permission is denied forever.
  // ============================================================

  Future<void> openAppSettings() async {
    await locationService
        .openAppSettings();
  }

  // ============================================================
  // DISPOSE
  // ============================================================

  @override
  void dispose() {
    _navigationSession++;

    unawaited(
      _locationSubscription
          ?.cancel() ??
          Future<void>.value(),
    );

    _locationSubscription = null;

    super.dispose();
  }
}