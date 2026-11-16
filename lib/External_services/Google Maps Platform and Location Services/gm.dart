import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';

/// Raised when the device location cannot be obtained (service off / permission
/// denied / no fix). UC-03 A2 treats this as "location permission disabled".
class DeviceLocationUnavailable implements Exception {
  const DeviceLocationUnavailable(this.message);
  final String message;
  @override
  String toString() => 'DeviceLocationUnavailable: $message';
}

/// Raised when the Google Places API request fails (UC-03 A1 / C1).
class PlacesApiException implements Exception {
  const PlacesApiException(this.message);
  final String message;
  @override
  String toString() => 'PlacesApiException: $message';
}

/// Gateway to Google Maps Platform + the device location service.
///
/// * `useDeviceServices == false` (the default, used by tests) → returns the
///   bundled Wangsa Maju sample data with no network or plugin calls.
/// * `useDeviceServices == true` (wired in `main.dart`) → real device GPS via
///   `geolocator`, and – when a `GOOGLE_MAPS_API_KEY` is supplied at run time –
///   real nearby attractions via the Google Places API (New).
class GoogleMapsPlatformExternal {
  GoogleMapsPlatformExternal({this.useDeviceServices = false});

  final bool useDeviceServices;

  /// Pass at run time and never commit it:
  ///   flutter run --dart-define=GOOGLE_MAPS_API_KEY=YOUR_KEY
  static const _apiKey = String.fromEnvironment('GOOGLE_MAPS_API_KEY');

  bool get _useRealPlaces => useDeviceServices && _apiKey.isNotEmpty;

  /// UC-03 BF-1..3 / UC-04 – the tourist's current position, enriched with a
  /// reverse-geocoded area name (`subLocality` / `locality` / …) so the AI
  /// Assistant can name the current area.
  Future<Map<String, dynamic>> getCurrentLocation() async {
    if (!useDeviceServices) {
      await Future.delayed(const Duration(milliseconds: 300));
      return {
        'latitude': 3.2040,
        'longitude': 101.7350,
        'subLocality': 'Wangsa Maju',
        'locality': 'Kuala Lumpur',
        'administrativeArea': 'Federal Territory of Kuala Lumpur',
        'country': 'Malaysia',
        'area_label': 'Wangsa Maju, KL',
      };
    }

    if (!await Geolocator.isLocationServiceEnabled()) {
      throw const DeviceLocationUnavailable('Location services are turned off.');
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw const DeviceLocationUnavailable('Location permission was denied.');
    }

    // A fresh high-accuracy fix, with a hard time limit so we never hang. If it
    // times out (common indoors / cold GPS) fall back to the last known
    // position rather than the demo default, so the map still lands on roughly
    // the right neighbourhood.
    Position? position;
    try {
      position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );
    } catch (e) {
      debugPrint('[location] fresh fix failed ($e); trying last known');
      try {
        position = await Geolocator.getLastKnownPosition();
      } catch (_) {
        position = null;
      }
    }
    if (position == null) {
      throw const DeviceLocationUnavailable('Could not get a GPS fix.');
    }

    final result = <String, dynamic>{
      'latitude': position.latitude,
      'longitude': position.longitude,
      'accuracy': position.accuracy,
    };

    try {
      final placemarks = await placemarkFromCoordinates(
        position.latitude,
        position.longitude,
      );
      if (placemarks.isNotEmpty) {
        final p = placemarks.first;
        // The neighbourhood name lives in different fields depending on the
        // OS geocoder — subLocality on Android, sometimes thoroughfare or
        // subAdministrativeArea. Take the first non-empty, most specific one.
        final area = [
          p.subLocality,
          p.subAdministrativeArea,
          p.thoroughfare,
          p.locality,
        ].firstWhere(
          (s) => s != null && s.trim().isNotEmpty,
          orElse: () => null,
        );
        final city = p.locality?.trim();
        result.addAll({
          'subLocality': p.subLocality ?? '',
          'locality': p.locality ?? '',
          'administrativeArea': p.administrativeArea ?? '',
          'country': p.country ?? '',
          'postalCode': p.postalCode ?? '',
          'street': p.street ?? '',
          'area_label': [
            area,
            if (city != null && city.isNotEmpty && city != area) city,
          ].whereType<String>().join(', '),
        });
      }
    } catch (e) {
      debugPrint('[geocoding] reverse geocode failed: $e');
    }
    return result;
  }

  /// UC-03 — a live feed of the tourist's position while the Map screen is
  /// open, so the "you are here" marker tracks real movement without the
  /// tourist ever needing to reopen the screen. `distanceFilter` throttles
  /// updates to real movement (in metres) rather than firing on every GPS
  /// noise blip. Returns nothing in the non-device (test/demo) mode — the
  /// one-shot [getCurrentLocation] is all those callers need.
  Stream<Position> watchPosition({int distanceFilterMeters = 15}) {
    if (!useDeviceServices) return const Stream.empty();
    return Geolocator.getPositionStream(
      locationSettings: LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: distanceFilterMeters,
      ),
    );
  }

  // ---------- UC-04 – location permission helpers ----------

  Future<bool> hasLocationPermission() async {
    final status = await Permission.location.status;
    return status.isGranted;
  }

  Future<bool> requestLocationPermission() async {
    final status = await Permission.location.request();
    return status.isGranted;
  }

  Future<bool> isLocationServiceEnabled() {
    return Geolocator.isLocationServiceEnabled();
  }

  double calculateDistance({
    required double lat1,
    required double lng1,
    required double lat2,
    required double lng2,
  }) {
    return Geolocator.distanceBetween(lat1, lng1, lat2, lng2);
  }

  /// UC-03 BF-4 – nearby hidden places near [latitude]/[longitude].
  ///
  /// Each record carries the REAL attraction coordinate plus its rating and
  /// review count; [MapRepository] applies the eligibility rules and the
  /// privacy offset before anything reaches the map.
  ///
  /// [radiusMeters] lets [MapRepository] widen the search when the default
  /// radius doesn't turn up enough eligible places — must stay in metres,
  /// and Google's Nearby Search caps it at 50000 regardless of what's passed.
  Future<List<Map<String, dynamic>>> fetchEligibleNearbyHiddenPlaces({
    required double latitude,
    required double longitude,
    double radiusMeters = 2000.0,
  }) async {
    if (!_useRealPlaces) {
      await Future.delayed(const Duration(milliseconds: 700));
      return _sampleHiddenPlaces;
    }
    // Two searches so nearby food places don't crowd landmarks out of the
    // 20-result limit (and vice-versa), each run twice — once POPULARITY
    // (favours famous places, needed for the radius-widening loop to surface
    // a different pool at each tier) and once DISTANCE (favours genuinely
    // nearby places regardless of fame, so a small/local spot a hyper-
    // touristy area's POPULARITY top-20 crowded out still gets a chance —
    // see the long comment on rankPreference in _searchNearbyAttractions).
    // withDetails adds a photo URL per place so MapRepository can
    // Gemini-screen indoor venues before they map.
    final results = await Future.wait([
      _searchNearbyAttractions(latitude, longitude,
          withDetails: true,
          includedTypes: _gamePlaceTypes,
          radiusMeters: radiusMeters),
      _searchNearbyAttractions(latitude, longitude,
          withDetails: true,
          includedTypes: _foodPlaceTypes,
          radiusMeters: radiusMeters),
      _searchNearbyAttractions(latitude, longitude,
          withDetails: true,
          includedTypes: _gamePlaceTypes,
          radiusMeters: radiusMeters,
          rankPreference: 'DISTANCE'),
      _searchNearbyAttractions(latitude, longitude,
          withDetails: true,
          includedTypes: _foodPlaceTypes,
          radiusMeters: radiusMeters,
          rankPreference: 'DISTANCE'),
    ]);

    final byId = <String, Map<String, dynamic>>{};
    for (final batch in results) {
      for (final place in batch) {
        byId.putIfAbsent(place['id'] as String, () => place);
      }
    }
    return byId.values.toList()
      ..sort((a, b) => (a['distance_km'] as num)
          .toDouble()
          .compareTo((b['distance_km'] as num).toDouble()));
  }

  /// Landmark place types for the exploration game. `mosque` / `church` /
  /// `hindu_temple` / `plaza` are excluded on purpose — in residential areas
  /// Google tags every neighbourhood surau, shop-lot congregation and strip
  /// mall with those, which are not tourist landmarks. A genuinely famous one
  /// (Batu Caves, Masjid Negara, St. Mary's Cathedral) is also tagged
  /// `tourist_attraction` / `historical_landmark`, so it still shows.
  ///
  /// The second half (zoo..water_park) widens the candidate pool with more
  /// outdoor-landmark categories — same eligibility rules (rating, review
  /// count, distance) still apply on top; this only adds more real places for
  /// those rules to consider. Verified against the live Places API (New)
  /// type enum before adding — each one returns real results with no error.
  static const _gamePlaceTypes = <String>[
    'tourist_attraction',
    'historical_landmark',
    'park',
    'garden',
    'national_park',
    'monument',
    'museum',
    'art_gallery',
    'zoo',
    'aquarium',
    'amusement_park',
    'hiking_area',
    'cultural_landmark',
    'water_park',
  ];

  /// UC-03 View Map — local food spots, searched separately from landmarks so
  /// each gets its own slice of the 20-result limit. The same eligibility
  /// limits still apply (open now, not closed, enough reviews, and — via
  /// Gemini — a real outdoor photo of the place).
  static const _foodPlaceTypes = <String>[
    'restaurant',
    'cafe',
    'bakery',
    'bar',
    'ice_cream_shop',
  ];

  /// A real landmark has plenty of reviews; this filters out the mislabelled
  /// nurseries, playgrounds and shop-lots Google returns in residential areas.
  /// Matches MapRepository's minReviewCount/maxReviewCount exactly (10..1000)
  /// — this used to be a stricter, independently-tuned 50-with-no-upper-bound,
  /// so a place popular enough to clear 20,000 reviews (or one just short of
  /// 50) could show up as a Puzzle "Mystery" with no matching marker on the
  /// Map screen, or the reverse. Both screens should offer exactly the same
  /// candidate places for a given spot. Lowered 30 -> 10 by explicit request
  /// (matches Trip Path Quest's own hidden-place review floor) after too few
  /// real nearby places cleared 30 once many were already claimed. The upper
  /// bound was later lowered 20000 -> 1000 to also match Trip Path Quest's
  /// own hidden-place review ceiling, so all three modes favour discoverable
  /// local spots over the most over-touristed landmarks nearby.
  static const _minGameReviewCount = 10;
  static const _maxGameReviewCount = 1000;

  /// A hotel/resort/hostel is a place to sleep, not a landmark to discover —
  /// but Google's `_gamePlaceTypes` search can still return one when its
  /// listing also carries a secondary type like `tourist_attraction` (common
  /// for larger hotels "on the Park" or near a landmark). Same word list as
  /// TripPathAttractionRepository's own accommodation exclusion, kept here so
  /// Map/Puzzle apply the identical rule before a hotel ever becomes a
  /// candidate marker or mystery option.
  static const _accommodationNameWords = <String>{
    'hotel',
    'resort',
    'motel',
    'hostel',
    'guest house',
    'guesthouse',
    'homestay',
    'lodging',
    'serviced apartment',
    'apartment hotel',
    'inn',
    'lodge',
  };

  static bool looksLikeAccommodation(String name) {
    final normalized = name.toLowerCase();
    return _accommodationNameWords.any(normalized.contains);
  }

  /// UC-03 C4 / UC-05 — is this Places result eligible as a game place?
  /// Excludes permanently/temporarily closed venues, anything currently
  /// outside its opening hours, and accommodation (see
  /// [looksLikeAccommodation]). Places with no published hours (public
  /// parks, plazas, monuments) are kept.
  static bool isEligibleGamePlace(Map<String, dynamic> place) {
    final status = (place['business_status'] as String?) ?? 'OPERATIONAL';
    if (status != 'OPERATIONAL') return false;
    final openNow = place['open_now'] as bool?;
    if (openNow == false) return false;
    final rating = (place['rating'] as num?)?.toDouble() ?? 0;
    final reviews = (place['review_count'] as num?)?.toInt() ?? 0;
    if (rating < 4.0 ||
        reviews < _minGameReviewCount ||
        reviews > _maxGameReviewCount) {
      return false;
    }
    if (looksLikeAccommodation((place['name'] as String?) ?? '')) {
      return false;
    }
    // Near a border, a search circle can genuinely reach across into a
    // neighbouring country (Thailand, Singapore, Indonesia, Brunei) — this
    // app is scoped to Malaysia, so a place whose own country code isn't
    // 'MY' is never a valid hidden place, however good its rating/photos
    // are. countryCode is null only when Google didn't return
    // addressComponents for this result; keep it rather than guess.
    final countryCode = place['country_code'] as String?;
    if (countryCode != null && countryCode != 'MY') {
      return false;
    }
    return true;
  }

  Future<List<Map<String, dynamic>>> _searchNearbyAttractions(
    double latitude,
    double longitude, {
    bool withDetails = false,
    List<String> includedTypes = _gamePlaceTypes,
    double radiusMeters = 2000.0,
    // POPULARITY by default (see the field's own comment below for why).
    // A caller can pass 'DISTANCE' instead to get the genuinely closest 20
    // places regardless of fame — see [fetchEligibleNearbyHiddenPlaces].
    String rankPreference = 'POPULARITY',
  }) async {
    final fieldMask = <String>[
      'places.id',
      'places.location',
      'places.rating',
      'places.userRatingCount',
      'places.primaryType',
      'places.types',
      'places.businessStatus',
      'places.currentOpeningHours.openNow',
      'places.addressComponents',
      if (withDetails) ...[
        'places.displayName',
        'places.shortFormattedAddress',
        'places.photos',
      ],
    ].join(',');

    final http.Response response;
    try {
      response = await http.post(
        Uri.parse('https://places.googleapis.com/v1/places:searchNearby'),
        headers: {
          'Content-Type': 'application/json',
          'X-Goog-Api-Key': _apiKey,
          'X-Goog-FieldMask': fieldMask,
        },
        body: jsonEncode({
          'includedTypes': includedTypes,
          'maxResultCount': 20,
          // POPULARITY, not DISTANCE (by default) — with DISTANCE ranking,
          // Nearby Search always returns the closest 20 places within the
          // circle, so once a dense area already has 20+ of a type inside
          // the *smallest* radius, every wider radius in MapRepository's
          // expansion loop returns that exact same nearest-20 set (confirmed
          // live: raw stayed at 40 across 2..50km). POPULARITY considers the
          // whole circle's relevance instead of pure distance, so a wider
          // circle can actually surface a different/larger candidate pool —
          // required for that expansion loop to do anything.
          //
          // The reverse problem shows up in a hyper-touristy area (e.g. KL
          // City Centre): POPULARITY's top-20 can be dominated entirely by
          // landmarks with thousands of reviews, silently crowding out any
          // genuinely nearby small/local place that would actually pass the
          // 10-1000 review "hidden place" band — confirmed live (raw=39,
          // eligible=0 at every radius up to 50km, all rejected either as
          // hotels, closed, or reviews far past 1000). A caller can request
          // 'DISTANCE' instead specifically to counter that: the closest
          // places regardless of fame are far more likely to include a
          // low-review local spot the POPULARITY pass never returned.
          'rankPreference': rankPreference,
          'locationRestriction': {
            'circle': {
              'center': {'latitude': latitude, 'longitude': longitude},
              // Google's Nearby Search (New) hard-caps this at 50000m
              // regardless of what's passed — MapRepository's expansion loop
              // relies on that as its natural ceiling.
              'radius': radiusMeters.clamp(1.0, 50000.0),
            },
          },
        }),
      ).timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw PlacesApiException(
        'Could not reach the Places service: request timed out.',
      );
    } catch (e) {
      throw PlacesApiException('Could not reach the Places service: $e');
    }

    if (response.statusCode != 200) {
      debugPrint('[Places API] HTTP ${response.statusCode}: ${response.body}');
      throw PlacesApiException(
        'Places API returned ${response.statusCode}. Check that the API key is '
        'valid and that "Places API (New)" and billing are enabled.',
      );
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final places = (body['places'] as List<dynamic>? ?? const []);

    return places.map((raw) {
      final place = raw as Map<String, dynamic>;
      final location = place['location'] as Map<String, dynamic>? ?? const {};
      final lat = (location['latitude'] as num?)?.toDouble() ?? latitude;
      final lng = (location['longitude'] as num?)?.toDouble() ?? longitude;
      final primaryType = place['primaryType'] as String? ?? '';
      final types = (place['types'] as List<dynamic>? ?? const [])
          .map((t) => t.toString())
          .toList();
      final grouping = _categorise(primaryType, types);
      final openingHours =
          place['currentOpeningHours'] as Map<String, dynamic>?;
      final countryCode = _countryCodeFrom(place['addressComponents']);
      final photos = place['photos'] as List<dynamic>?;
      // Keep a few candidate photo URLs, not just the first — Places often
      // returns a close-up of the food/menu before the storefront, so callers
      // that vision-screen for a genuine exterior/stall shot need more than
      // one to try.
      final photoUrls = (photos ?? const [])
          .take(4)
          .map((p) => (p as Map<String, dynamic>)['name'] as String?)
          .whereType<String>()
          .map((name) => 'https://places.googleapis.com/v1/$name/media'
              '?maxWidthPx=900&key=$_apiKey')
          .toList();

      return <String, dynamic>{
        'id': place['id'] as String? ?? 'place_${lat}_$lng',
        'general_category': grouping.$1,
        'route_group': grouping.$2,
        'latitude': lat,
        'longitude': lng,
        'distance_km': _haversineKm(latitude, longitude, lat, lng),
        'rating': (place['rating'] as num?)?.toDouble() ?? 0.0,
        'review_count': (place['userRatingCount'] as num?)?.toInt() ?? 0,
        'business_status': place['businessStatus'] as String?,
        'open_now': openingHours?['openNow'] as bool?,
        'country_code': countryCode,
        if (withDetails) ...{
          'name': (place['displayName']
                  as Map<String, dynamic>?)?['text'] as String? ??
              grouping.$1,
          'address': place['shortFormattedAddress'] as String?,
          'photo_url': photoUrls.isNotEmpty ? photoUrls.first : null,
          'photo_urls': photoUrls,
        },
      };
    }).toList();
  }

  /// Extracts the 2-letter ISO country code (e.g. "MY") from a Places API
  /// (New) `addressComponents` list, or null when the field wasn't returned
  /// or has no country component (both intentionally treated as "unknown"
  /// rather than "reject" by [isEligibleGamePlace] — a search near a border
  /// should exclude a place confirmed to be in another country, not one
  /// Google simply didn't label).
  static String? _countryCodeFrom(dynamic addressComponents) {
    if (addressComponents is! List) return null;
    for (final component in addressComponents) {
      if (component is! Map<String, dynamic>) continue;
      final types = component['types'];
      if (types is List && types.contains('country')) {
        final shortText = component['shortText'] as String?;
        if (shortText != null && shortText.isNotEmpty) return shortText;
      }
    }
    return null;
  }

  // A supermarket, golf course, stadium, gym or similar recreation/retail
  // venue almost always picks up a restaurant/cafe/bakery secondary type
  // (an in-store bakery counter, a clubhouse snack bar), but that amenity is
  // not what makes the venue worth visiting. Independent copy of Trip Path
  // Quest's own AttractionRepository.recreationVenueTypes/retailVenueTypes —
  // same vocabulary, kept separate since this works on the raw Places
  // primary-type string rather than that repository's typed Attraction
  // model.
  static const _nonFoodPrimaryTypes = <String>{
    'golf_course', 'stadium', 'gym', 'fitness_center', 'sports_club',
    'sports_complex', 'bowling_alley', 'amusement_park', 'movie_theater',
    'night_club', 'casino', 'swimming_pool', 'ice_skating_rink',
    'ski_resort', 'arena', 'country_club',
    'supermarket', 'grocery_store', 'convenience_store', 'department_store',
    'discount_store', 'wholesaler', 'warehouse_store', 'shopping_mall',
    'gas_station', 'pharmacy', 'drugstore', 'hardware_store',
    'home_goods_store', 'furniture_store', 'electronics_store',
    'clothing_store',
  };

  /// Maps Google place types to a display category + a coarse route group.
  /// [primaryType] is checked on its own for a non-food identity before
  /// [types] (which may include secondary types) is allowed to classify the
  /// place as food — a food-ish secondary type must never override what the
  /// place's own primary type says it actually is.
  (String, String) _categorise(String primaryType, List<String> types) {
    bool has(String t) => primaryType == t || types.contains(t);
    if (!_nonFoodPrimaryTypes.contains(primaryType) &&
        (has('restaurant') ||
            has('cafe') ||
            has('bakery') ||
            has('bar') ||
            has('ice_cream_shop') ||
            has('coffee_shop') ||
            has('meal_takeaway'))) {
      return ('Local Food', 'food');
    }
    if (has('museum') || has('art_gallery') || has('cultural_center')) {
      return ('Museum & Gallery', 'culture');
    }
    if (has('park') ||
        has('garden') ||
        has('national_park') ||
        has('botanical_garden')) {
      return ('Park & Garden', 'nature');
    }
    if (has('historical_landmark') ||
        has('historical_place') ||
        has('monument') ||
        has('plaza') ||
        has('church') ||
        has('hindu_temple') ||
        has('mosque') ||
        has('synagogue')) {
      return ('Heritage Site', 'heritage');
    }
    return ('Local Attraction', 'attraction');
  }

  /// Renamed to match Trip Path Quest's theme names ("Food Quest", "Culture
  /// Quest", "Heritage Quest", "Nature Quest") so a Puzzle mystery reads as
  /// the same kind of thing as a quest, instead of exposing [_categorise]'s
  /// raw internal label ("Local Food", "Park & Garden", ...) straight to
  /// the player. Falls back to "Mystery Quest" for the generic "attraction"
  /// route group (fetchNearbyPuzzlePlaces already filters that catch-all
  /// out, so this only matters for callers that don't).
  String _questCategoryLabel(String? routeGroup) => switch (routeGroup) {
    'food' => 'Food Quest',
    'culture' => 'Culture Quest',
    'heritage' => 'Heritage Quest',
    'nature' => 'Nature Quest',
    _ => 'Mystery Quest',
  };

  // ============================================================
  // SAME REAL-WORLD SITE DEDUP
  //
  // A popular landmark (e.g. Petronas Twin Towers) can have several
  // separate Google Place entries nearby — a photo point, an observation
  // deck entrance, a lookout — each with its own, often much lower, review
  // count. Left alone, one of those minor sub-entries can be offered as its
  // own independent "hidden place" instead of (or as well as) the landmark
  // itself. This clusters candidates that look like the same physical site
  // and keeps only the most-reviewed one per cluster. Mirrors Trip Path
  // Quest's own `_checkpointAreaConflict` name-similarity logic
  // (trip_path_attraction_repository.dart) — kept as an independent copy
  // here since that one works on a different, typed model.
  // ============================================================

  static const double _sameSiteComparisonRadiusMeters = 1500.0;

  static const Set<String> _genericSiteTokens = <String>{
    'the', 'a', 'an', 'at', 'of', 'and',
    'entrance', 'entry', 'exit', 'gate', 'main',
    'lookout', 'look', 'out', 'viewpoint', 'point',
    'trail', 'trailhead', 'parking', 'carpark', 'car',
    'junction', 'intersection', 'access',
    'restaurant', 'restoran', 'cafe', 'coffee', 'shop', 'store',
  };

  static List<String> siteNameTokens(String value) {
    return value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .split(' ')
        .map((token) => token.trim())
        .where((token) =>
            token.length >= 2 && !_genericSiteTokens.contains(token))
        .toList(growable: false);
  }

  static double siteNameJaccard(String firstName, String secondName) {
    final first = siteNameTokens(firstName).toSet();
    final second = siteNameTokens(secondName).toSet();
    if (first.isEmpty || second.isEmpty) return 0.0;
    final common = first.intersection(second).length;
    final union = first.union(second).length;
    if (common < 2 || union == 0) return 0.0;
    return common / union;
  }

  static bool looksLikeSamePhysicalSite(String firstName, String secondName) {
    final firstPhrase = siteNameTokens(firstName).join(' ');
    final secondPhrase = siteNameTokens(secondName).join(' ');
    // Covers examples such as "KL East Park" vs "Lookout Point (KL East Park)".
    if (firstPhrase.length >= 6 &&
        secondPhrase.length >= 6 &&
        (firstPhrase.contains(secondPhrase) ||
            secondPhrase.contains(firstPhrase))) {
      return true;
    }
    // A high token overlap within the same local area usually indicates
    // another entrance/gate/viewpoint of the same parent venue.
    return siteNameJaccard(firstName, secondName) >= 0.60;
  }

  static bool siteNameAppearsInAddress(String siteName, String? address) {
    if (address == null || address.trim().isEmpty) return false;
    final tokens = siteNameTokens(siteName);
    if (tokens.length < 2) return false;
    final phrase = tokens.join(' ');
    final normalizedAddress = address
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return phrase.length >= 6 && normalizedAddress.contains(phrase);
  }

  /// Clusters [places] (each expected to carry 'name', optionally 'address',
  /// 'latitude'/'longitude', and 'review_count'/'rating') by same-site
  /// heuristic and keeps only the highest-review-count place per cluster.
  ///
  /// Two places are merged automatically when name similarity is high
  /// (jaccard ≥ 0.60, substring match, or one name appears in the other's
  /// address) within [_sameSiteComparisonRadiusMeters]. When [onAmbiguousPair]
  /// is supplied, pairs in the ambiguous 0.35–0.59 jaccard band (similar but
  /// not confidently the same) are also asked about — merged only if it
  /// resolves `true`. Without a callback (the common, no-Gemini-cost case),
  /// only the confident automatic merges apply.
  static Future<List<Map<String, dynamic>>> dedupeSameSitePlaces(
    List<Map<String, dynamic>> places, {
    Future<bool> Function(Map<String, dynamic> a, Map<String, dynamic> b)?
        onAmbiguousPair,
  }) async {
    if (places.length < 2) return places;

    final parent = List<int>.generate(places.length, (i) => i);
    int find(int x) {
      while (parent[x] != x) {
        parent[x] = parent[parent[x]];
        x = parent[x];
      }
      return x;
    }

    void union(int a, int b) {
      final rootA = find(a);
      final rootB = find(b);
      if (rootA != rootB) parent[rootA] = rootB;
    }

    for (var i = 0; i < places.length; i++) {
      for (var j = i + 1; j < places.length; j++) {
        if (find(i) == find(j)) continue;

        final a = places[i];
        final b = places[j];
        final latA = (a['latitude'] as num?)?.toDouble();
        final lngA = (a['longitude'] as num?)?.toDouble();
        final latB = (b['latitude'] as num?)?.toDouble();
        final lngB = (b['longitude'] as num?)?.toDouble();
        if (latA == null || lngA == null || latB == null || lngB == null) {
          continue;
        }
        if (_haversineKm(latA, lngA, latB, lngB) * 1000 >
            _sameSiteComparisonRadiusMeters) {
          continue;
        }

        final nameA = (a['name'] as String?) ?? '';
        final nameB = (b['name'] as String?) ?? '';
        final addressA = a['address'] as String?;
        final addressB = b['address'] as String?;

        if (looksLikeSamePhysicalSite(nameA, nameB) ||
            siteNameAppearsInAddress(nameA, addressB) ||
            siteNameAppearsInAddress(nameB, addressA)) {
          union(i, j);
          continue;
        }

        if (onAmbiguousPair != null) {
          final jaccard = siteNameJaccard(nameA, nameB);
          if (jaccard >= 0.35 && jaccard < 0.60) {
            if (await onAmbiguousPair(a, b)) {
              union(i, j);
            }
          }
        }
      }
    }

    final clusters = <int, List<int>>{};
    for (var i = 0; i < places.length; i++) {
      clusters.putIfAbsent(find(i), () => []).add(i);
    }

    int reviewsOf(int index) =>
        (places[index]['review_count'] as num?)?.toInt() ?? 0;
    double ratingOf(int index) =>
        (places[index]['rating'] as num?)?.toDouble() ?? 0.0;

    final kept = clusters.values.map((indices) {
      indices.sort((x, y) {
        final byReviews = reviewsOf(y).compareTo(reviewsOf(x));
        if (byReviews != 0) return byReviews;
        return ratingOf(y).compareTo(ratingOf(x));
      });
      return indices.first;
    }).toList()
      ..sort();

    return kept.map((index) => places[index]).toList(growable: false);
  }

  /// UC-05 – up to three nearby hidden places for the "Puzzle" button entry.
  ///
  /// Real Google Places results, filtered to outdoor landmarks that are open
  /// now and not closed down (see [_gamePlaceTypes] / [isEligibleGamePlace]).
  /// Falls back to the bundled sample when no key is configured.
  ///
  /// Searches the same two type groups as [fetchEligibleNearbyHiddenPlaces]
  /// (landmarks + food) with the same eligibility bounds, so a "Mystery"
  /// offered here always corresponds to a real marker on the Map screen —
  /// this used to search landmarks only, which could surface a place the
  /// tourist had never seen as a marker at all.
  Future<List<Map<String, dynamic>>> fetchNearbyPuzzlePlaces({
    required double latitude,
    required double longitude,
    // Kept at the original 2 km default so any other/future caller sees the
    // same behaviour as before — AttractionRepository.getNearbyPuzzleOptions
    // is the one that now widens this across several calls.
    double radiusMeters = 2000.0,
  }) async {
    if (!_useRealPlaces) {
      await Future.delayed(const Duration(milliseconds: 700));
      return _samplePuzzlePlaces;
    }

    // Both POPULARITY and DISTANCE passes — see the long comment on
    // rankPreference in _searchNearbyAttractions. A hyper-touristy area's
    // POPULARITY top-20 can be entirely landmarks past the 1000-review cap,
    // so the DISTANCE pass is what actually gives a genuinely nearby small
    // place a chance to qualify.
    final results = await Future.wait([
      _searchNearbyAttractions(latitude, longitude,
          withDetails: true,
          includedTypes: _gamePlaceTypes,
          radiusMeters: radiusMeters),
      _searchNearbyAttractions(latitude, longitude,
          withDetails: true,
          includedTypes: _foodPlaceTypes,
          radiusMeters: radiusMeters),
      _searchNearbyAttractions(latitude, longitude,
          withDetails: true,
          includedTypes: _gamePlaceTypes,
          radiusMeters: radiusMeters,
          rankPreference: 'DISTANCE'),
      _searchNearbyAttractions(latitude, longitude,
          withDetails: true,
          includedTypes: _foodPlaceTypes,
          radiusMeters: radiusMeters,
          rankPreference: 'DISTANCE'),
    ]);

    final byId = <String, Map<String, dynamic>>{};
    for (final batch in results) {
      for (final place in batch) {
        byId.putIfAbsent(place['id'] as String, () => place);
      }
    }
    final raw = byId.values.toList();

    final eligible = raw
        .where(isEligibleGamePlace)
        // Puzzle mysteries are only ever Food/Culture/Heritage/Nature —
        // same fixed four categories as Trip Path Quest's themes. A place
        // whose Google types don't match any of them falls into
        // _categorise()'s generic 'attraction' catch-all ("Local
        // Attraction"), which has no matching quest name to display, so
        // it's dropped here rather than shown as an unlabelled mystery.
        .where((place) => place['route_group'] != 'attraction')
        .toList()
      ..sort((a, b) => (a['distance_km'] as num)
          .toDouble()
          .compareTo((b['distance_km'] as num).toDouble()));

    // Heuristic-only pass (no Gemini call here — this class has no Gemini
    // dependency); AttractionRepository runs a second, ambiguous-pairs-only
    // pass with Gemini once it has these candidates.
    final deduped = await dedupeSameSitePlaces(eligible);

    // Return a few extra candidates — AttractionRepository screens the photos
    // with Gemini Vision and keeps the first 3 that are genuine outdoor spots.
    return deduped.take(8).map((place) {
      final lat = (place['latitude'] as num).toDouble();
      final lng = (place['longitude'] as num).toDouble();
      final category = place['general_category'] as String? ?? 'Hidden Place';
      final questLabel = _questCategoryLabel(place['route_group'] as String?);
      return <String, dynamic>{
        'id': place['id'],
        'name': place['name'] ?? 'Mystery $questLabel',
        'category': category,
        'route_group': place['route_group'],
        'address': place['address'],
        'rating': place['rating'],
        'review_count': place['review_count'],
        'township': place['address'] ?? 'Nearby',
        'description': 'A $questLabel near you — solve the puzzle to reveal it.',
        'latitude': lat,
        'longitude': lng,
        'distance_meter':
            ((place['distance_km'] as num).toDouble() * 1000).round(),
        'direction': _compassLabel(latitude, longitude, lat, lng),
        'image_url': place['photo_url'] ??
            'https://picsum.photos/seed/${place['id']}/900/900',
        'photo_urls': place['photo_urls'] ?? const <String>[],
      };
    }).toList();
  }

  /// 8-way compass label from the tourist to a place.
  static String _compassLabel(
    double fromLat,
    double fromLng,
    double toLat,
    double toLng,
  ) {
    final dLng = (toLng - fromLng) * math.pi / 180;
    final y = math.sin(dLng) * math.cos(toLat * math.pi / 180);
    final x = math.cos(fromLat * math.pi / 180) * math.sin(toLat * math.pi / 180) -
        math.sin(fromLat * math.pi / 180) *
            math.cos(toLat * math.pi / 180) *
            math.cos(dLng);
    final bearing = (math.atan2(y, x) * 180 / math.pi + 360) % 360;
    const labels = [
      'N ↑', 'NE ↗', 'E →', 'SE ↘', 'S ↓', 'SW ↙', 'W ←', 'NW ↖',
    ];
    return labels[((bearing + 22.5) ~/ 45) % 8];
  }

  static const _samplePuzzlePlaces = <Map<String, dynamic>>[
    {
      'id': 'hp_001',
      'name': 'Wangsa Walk Mall',
      'category': 'Cultural Hub',
      'township': 'Wangsa Maju',
      'description':
          'A vibrant gathering place known for art and community events.',
      'latitude': 3.2050,
      'longitude': 101.7360,
      'distance_meter': 310,
      'direction': 'NE ↗',
      'image_url': 'https://picsum.photos/id/1043/900/900',
    },
    {
      'id': 'hp_002',
      'name': 'Hidden Green Park',
      'category': 'Park',
      'township': 'Wangsa Maju',
      'description': 'A peaceful green space tucked between urban blocks.',
      'latitude': 3.2062,
      'longitude': 101.7341,
      'distance_meter': 220,
      'direction': 'NW ↖',
      'image_url': 'https://picsum.photos/id/1036/900/900',
    },
    {
      'id': 'hp_003',
      'name': 'Old Heritage Corner',
      'category': 'Heritage',
      'township': 'Wangsa Maju',
      'description':
          'An architecturally striking landmark of cultural significance.',
      'latitude': 3.2042,
      'longitude': 101.7378,
      'distance_meter': 180,
      'direction': 'E →',
      'image_url': 'https://picsum.photos/id/1069/900/900',
    },
  ];

  // ---------- UC-04 – real nearby places (Places API, legacy Nearby Search) ----
  ///
  /// Used by the AI Assistant to ground answers about nearby restaurants /
  /// attractions / shops. Requires the (legacy) **Places API** enabled on the
  /// same `GOOGLE_MAPS_API_KEY`.
  Future<List<Map<String, dynamic>>> searchNearbyAttractions({
    required double latitude,
    required double longitude,
    int radius = 1500,
    String? keyword,
    String? type,
  }) async {
    if (_apiKey.isEmpty) return const [];
    try {
      var url = 'https://maps.googleapis.com/maps/api/place/nearbysearch/json'
          '?location=$latitude,$longitude'
          '&radius=$radius'
          '&key=$_apiKey';
      if (keyword != null && keyword.isNotEmpty) {
        url += '&keyword=${Uri.encodeComponent(keyword)}';
      }
      if (type != null && type.isNotEmpty) {
        url += '&type=$type';
      }

      final response = await http.get(Uri.parse(url));
      if (response.statusCode != 200) {
        debugPrint('[Places legacy] HTTP ${response.statusCode}');
        return const [];
      }

      final data = json.decode(response.body) as Map<String, dynamic>;
      if (data['status'] != 'OK') {
        debugPrint('[Places legacy] ${data['status']} - ${data['error_message'] ?? ''}');
        return const [];
      }

      final results = data['results'] as List;
      final mapped = results.map((raw) {
        final place = raw as Map<String, dynamic>;
        final geometry = place['geometry'] as Map<String, dynamic>?;
        final loc = geometry?['location'] as Map<String, dynamic>?;
        final photos = place['photos'] as List?;
        final openingHours = place['opening_hours'] as Map<String, dynamic>?;
        final types = (place['types'] as List?)
                ?.map((t) => t.toString())
                .toList() ??
            const <String>[];
        // Legacy Nearby Search has no dedicated primaryType field like the
        // New API — Google documents its `types` array as most-specific-first,
        // so the first entry is the closest available stand-in.
        final primaryType = types.isNotEmpty ? types.first : '';
        final grouping = _categorise(primaryType, types);
        return <String, dynamic>{
          'name': place['name'] ?? 'Unknown',
          'placeId': place['place_id'] ?? '',
          'rating': place['rating'] ?? 0.0,
          'userRatingsTotal': place['user_ratings_total'] ?? 0,
          'types': types,
          // Same food/culture/heritage/nature classification Map and Puzzle
          // use, so the AI Assistant can be restricted to the same four
          // quest categories instead of showing whatever Google's free-text
          // keyword search loosely matched (see chatbot_viewmodel.dart).
          'route_group': grouping.$2,
          'vicinity': place['vicinity'] ?? '',
          // So callers (the AI Assistant chat) can skip closed-down venues
          // and tell the tourist whether a place is open right now, instead
          // of confidently recommending somewhere that's shut.
          'businessStatus': place['business_status'] ?? 'UNKNOWN',
          'openNow': openingHours?['open_now'] as bool?,
          'location': {'lat': loc?['lat'], 'lng': loc?['lng']},
          'photoReference': (photos != null && photos.isNotEmpty)
              ? photos.first['photo_reference']
              : null,
        };
      }).toList();

      // Near a border (e.g. Bandar Johor Bahru, ~1km from the Singapore
      // causeway) a small search radius can still genuinely return a real
      // place across the border. This app — including the AI Assistant
      // chat — is scoped to Malaysia: once the tourist's own location is
      // detected as being in Malaysia, nothing from another country should
      // ever surface, no matter which country that turns out to be. Nearby
      // Search's response has no structured country field, so each
      // candidate's real country is looked up via a lean Place Details call
      // (address_components only) run in parallel, and anything confirmed
      // to be outside Malaysia is dropped before it ever reaches the
      // chatbot's "REAL DATA" context — otherwise Gemini recommends it as
      // real, current-area data despite the prompt's own "don't discuss
      // other areas" rule. A lookup failure/missing country is kept rather
      // than dropped, matching Map/Puzzle/Trip Path's own "unknown is not
      // the same as confirmed elsewhere" policy.
      final countryCodes = await Future.wait(
        mapped.map((place) => _legacyCountryCode(place['placeId'] as String)),
      );

      return [
        for (var i = 0; i < mapped.length; i++)
          if (countryCodes[i] == null || countryCodes[i] == 'MY') mapped[i],
      ];
    } catch (e) {
      debugPrint('[Places legacy] $e');
      return const [];
    }
  }

  /// The 2-letter ISO country code for a place, via a lean legacy Place
  /// Details call requesting only `address_components` — used to filter
  /// [searchNearbyAttractions] to Malaysia. Null on any failure/missing
  /// country (fails open — callers keep the place rather than drop it on a
  /// lookup error, since a network hiccup is not evidence of a foreign
  /// place).
  Future<String?> _legacyCountryCode(String placeId) async {
    if (_apiKey.isEmpty || placeId.isEmpty) return null;
    try {
      final response = await http
          .get(Uri.parse(
            'https://maps.googleapis.com/maps/api/place/details/json'
            '?place_id=${Uri.encodeComponent(placeId)}'
            '&fields=address_components'
            '&key=$_apiKey',
          ))
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;
      final data = json.decode(response.body) as Map<String, dynamic>;
      if (data['status'] != 'OK') return null;
      final components =
          (data['result'] as Map<String, dynamic>?)?['address_components'];
      if (components is! List) return null;
      for (final component in components) {
        if (component is! Map<String, dynamic>) continue;
        final types = component['types'];
        if (types is List && types.contains('country')) {
          final shortName = component['short_name'] as String?;
          if (shortName != null && shortName.isNotEmpty) return shortName;
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>> getPlaceDetails(String placeId) async {
    if (_apiKey.isEmpty) return const {};
    try {
      final response = await http.get(Uri.parse(
        'https://maps.googleapis.com/maps/api/place/details/json'
        '?place_id=$placeId'
        '&fields=name,formatted_address,vicinity,geometry,photos,'
        'editorial_summary,business_status,opening_hours'
        '&key=$_apiKey',
      ));
      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        if (data['status'] == 'OK') {
          return (data['result'] as Map<String, dynamic>?) ?? const {};
        }
      }
      return const {};
    } catch (_) {
      return const {};
    }
  }

  String getPlacePhotoUrl(String photoReference, {int maxWidth = 400}) {
    return 'https://maps.googleapis.com/maps/api/place/photo'
        '?maxwidth=$maxWidth&photoreference=$photoReference&key=$_apiKey';
  }

  static double _haversineKm(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const earthRadiusKm = 6371.0;
    double toRad(double d) => d * math.pi / 180;
    final dLat = toRad(lat2 - lat1);
    final dLon = toRad(lon2 - lon1);
    final a = math.pow(math.sin(dLat / 2), 2) +
        math.cos(toRad(lat1)) *
            math.cos(toRad(lat2)) *
            math.pow(math.sin(dLon / 2), 2);
    return earthRadiusKm * 2 * math.asin(math.sqrt(a.toDouble()));
  }

  /// Bundled Wangsa Maju sample used when no API key is supplied. Shaped like
  /// the Places API output (real coordinates + rating + review count).
  static const _sampleHiddenPlaces = <Map<String, dynamic>>[
    {
      'id': 'hp_area_01',
      'general_category': 'Heritage Site',
      'route_group': 'heritage',
      'latitude': 3.2168,
      'longitude': 101.7245,
      'distance_km': 1.3,
      'rating': 4.5,
      'review_count': 210,
    },
    {
      'id': 'hp_area_02',
      'general_category': 'Heritage Site',
      'route_group': 'heritage',
      'latitude': 3.1996,
      'longitude': 101.7192,
      'distance_km': 2.2,
      'rating': 4.3,
      'review_count': 130,
    },
    {
      'id': 'hp_area_03',
      'general_category': 'Heritage Site',
      'route_group': 'heritage',
      'latitude': 3.2083,
      'longitude': 101.7521,
      'distance_km': 2.6,
      'rating': 4.6,
      'review_count': 320,
    },
    {
      'id': 'hp_area_04',
      'general_category': 'Park & Garden',
      'route_group': 'nature',
      'latitude': 3.2225,
      'longitude': 101.7452,
      'distance_km': 3.1,
      'rating': 4.4,
      'review_count': 90,
    },
    {
      'id': 'hp_area_05',
      'general_category': 'Cultural Landmark',
      'route_group': 'culture',
      'latitude': 3.1902,
      'longitude': 101.7401,
      'distance_km': 3.8,
      'rating': 4.1,
      'review_count': 60,
    },
    {
      'id': 'hp_area_06',
      'general_category': 'Museum & Gallery',
      'route_group': 'culture',
      'latitude': 3.1846,
      'longitude': 101.7283,
      'distance_km': 4.6,
      'rating': 4.2,
      'review_count': 40,
    },
    {
      // Outside the 5 km sample radius – filtered out by distance.
      'id': 'hp_area_07',
      'general_category': 'Scenic Spot',
      'route_group': 'nature',
      'latitude': 3.2560,
      'longitude': 101.7700,
      'distance_km': 6.4,
      'rating': 4.7,
      'review_count': 150,
    },
    {
      // Rating below the 4.0 threshold – filtered out by eligibility.
      'id': 'hp_area_08',
      'general_category': 'Cultural Landmark',
      'route_group': 'culture',
      'latitude': 3.2020,
      'longitude': 101.7350,
      'distance_km': 0.9,
      'rating': 3.2,
      'review_count': 480,
    },
  ];
}
