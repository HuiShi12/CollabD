import 'dart:async';

import 'package:geolocator/geolocator.dart';

import '../../../External_services/Google Maps Platform and Location Services/gm.dart';

/// Raised when GPS / location permission is unavailable (UC-03 A2).
class LocationPermissionDeniedException implements Exception {
  const LocationPermissionDeniedException();
}

/// Raised when the device location service itself cannot be reached.
class LocationUnavailableException implements Exception {
  const LocationUnavailableException();
}

/// The tourist's current position plus the presentation data the map needs.
class TouristPosition {
  const TouristPosition({
    required this.latitude,
    required this.longitude,
    required this.areaLabel,
    this.equippedMarkerSkinId,
    this.equippedMarkerSkinImageUrl,
  });

  final double latitude;
  final double longitude;
  final String areaLabel;

  /// UC-03 C6 – the currently equipped Explorer Marker Skin, when available.
  final String? equippedMarkerSkinId;

  /// The equipped skin's real generated image, when available — Reward
  /// domain data, so MapViewModel fills this in (from RewardRepository)
  /// after getTouristPosition returns, not this GPS-only service.
  final String? equippedMarkerSkinImageUrl;

  TouristPosition copyWith({
    double? latitude,
    double? longitude,
    String? equippedMarkerSkinId,
    String? equippedMarkerSkinImageUrl,
  }) => TouristPosition(
    latitude: latitude ?? this.latitude,
    longitude: longitude ?? this.longitude,
    areaLabel: areaLabel,
    equippedMarkerSkinId: equippedMarkerSkinId ?? this.equippedMarkerSkinId,
    equippedMarkerSkinImageUrl:
        equippedMarkerSkinImageUrl ?? this.equippedMarkerSkinImageUrl,
  );
}

class LocationService {
  final GoogleMapsPlatformExternal googleMapsPlatformExternal;

  /// When `true`, [getTouristPosition] simulates the location-permission-disabled
  /// path (UC-03 A2) so the map can be exercised without a real GPS stack.
  final bool simulateLocationDenied;

  LocationService(
    this.googleMapsPlatformExternal, {
    this.simulateLocationDenied = false,
  });

  Future<Map<String, dynamic>> getCurrentLocation() async {
    return googleMapsPlatformExternal.getCurrentLocation();
  }

  /// UC-03 BF-1..3 – obtains the tourist's current latitude/longitude.
  Future<TouristPosition> getTouristPosition() async {
    if (simulateLocationDenied) {
      throw const LocationPermissionDeniedException();
    }

    final Map<String, dynamic> raw;
    try {
      raw = await googleMapsPlatformExternal.getCurrentLocation();
    } catch (_) {
      throw const LocationUnavailableException();
    }

    return TouristPosition(
      latitude: (raw['latitude'] as num).toDouble(),
      longitude: (raw['longitude'] as num).toDouble(),
      areaLabel: (raw['area_label'] as String?) ?? 'Wangsa Maju, KL',
      equippedMarkerSkinId: raw['equipped_marker_skin_id'] as String?,
    );
  }

  /// UC-03 — live latitude/longitude updates while the Map screen is open,
  /// so the tourist's marker tracks real movement without reopening the
  /// screen. Emits nothing when [simulateLocationDenied] or the device
  /// stream itself errors (e.g. permission revoked mid-session) — the map
  /// just keeps showing the last known position rather than crashing.
  Stream<({double latitude, double longitude})> watchPosition() {
    if (simulateLocationDenied) return const Stream.empty();
    return googleMapsPlatformExternal
        .watchPosition()
        .map((p) => (latitude: p.latitude, longitude: p.longitude))
        .handleError((_) {});
  }

  bool isWithinVerificationRange({
    required int distanceMeter,
    int maxDistanceMeter = 50,
  }) {
    return distanceMeter <= maxDistanceMeter;
  }

  /// UC-05 — straight-line metres from the tourist's *current* GPS position to
  /// [latitude]/[longitude], or `null` when the location is unavailable.
  Future<double?> distanceMetersTo({
    required double latitude,
    required double longitude,
  }) async {
    final pos = await getCurrentPosition();
    if (pos == null) return null;
    return Geolocator.distanceBetween(
      pos['latitude']!,
      pos['longitude']!,
      latitude,
      longitude,
    );
  }

  // ---------- UC-04 AI Assistant Chat ----------

  /// The name of the tourist's current area (`subLocality` → `locality` → …),
  /// or `'Unknown'` when the location cannot be resolved.
  Future<String> getCurrentArea() async {
    try {
      final location = await googleMapsPlatformExternal.getCurrentLocation();
      if (location.containsKey('error')) return 'Unknown';

      final candidates = [
        location['subLocality'],
        location['locality'],
        location['administrativeArea'],
        location['country'],
      ];
      for (final c in candidates) {
        if (c is String && c.trim().isNotEmpty) return c;
      }
      return 'Unknown';
    } catch (_) {
      return 'Unknown';
    }
  }

  /// The tourist's current latitude/longitude, or `null` when unavailable.
  Future<Map<String, double>?> getCurrentPosition() async {
    try {
      final location = await googleMapsPlatformExternal.getCurrentLocation();
      if (location.containsKey('error')) return null;
      return {
        'latitude': (location['latitude'] as num).toDouble(),
        'longitude': (location['longitude'] as num).toDouble(),
      };
    } catch (_) {
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> searchNearbyAttractions({
    required double latitude,
    required double longitude,
    int radius = 1500,
    String? keyword,
    String? type,
  }) {
    return googleMapsPlatformExternal.searchNearbyAttractions(
      latitude: latitude,
      longitude: longitude,
      radius: radius,
      keyword: keyword,
      type: type,
    );
  }

  Future<bool> isLocationServiceEnabled() =>
      googleMapsPlatformExternal.isLocationServiceEnabled();

  Future<bool> hasLocationPermission() =>
      googleMapsPlatformExternal.hasLocationPermission();
}
