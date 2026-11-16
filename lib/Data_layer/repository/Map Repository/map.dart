import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../../External_services/Google Maps Platform and Location Services/gm.dart';
import '../../service/Gemini Service/gemini.dart';
import '../../service/Location Service/location.dart';

/// The two exploration-game modes that UC-03 can hand to UC-05.
enum ProximityGameMode { puzzle, tripPath }

/// How the tourist entered the exploration game (UC-03 C9). UC-05 uses this to
/// tell a general button search apart from a marker-specific selection.
enum MapGameEntrySource { puzzleButton, themeButton, proximityGameMarker }

extension ProximityGameModeLabel on ProximityGameMode {
  String get label =>
      this == ProximityGameMode.puzzle ? 'Puzzle' : 'Trip Path';
}

extension MapGameEntrySourceLabel on MapGameEntrySource {
  String get label => switch (this) {
    MapGameEntrySource.puzzleButton => 'Puzzle button',
    MapGameEntrySource.themeButton => 'Theme button',
    MapGameEntrySource.proximityGameMarker => 'Proximity Game marker',
  };
}

/// One neutral Proximity Game marker (UC-03 C7).
///
/// It carries only a *general* category, a deliberately offset general-area
/// coordinate and an approximate distance. It never exposes the exact hidden
/// attraction, its address or its real coordinates (UC-03 C3 / FR03_6).
class HiddenPlaceMarker {
  const HiddenPlaceMarker({
    required this.id,
    required this.generalCategory,
    required this.generalAreaLatitude,
    required this.generalAreaLongitude,
    required this.distanceKm,
    this.routeGroup,
  });

  final String id;
  final String generalCategory;
  final double generalAreaLatitude;
  final double generalAreaLongitude;
  final double distanceKm;

  /// FR03_9 – this marker's Trip Path theme id ('food' / 'culture' /
  /// 'heritage' / 'nature'). Lets a marker-specific Trip Path entry jump
  /// straight into that theme instead of the general theme-browsing screen.
  final String? routeGroup;

  /// Displayed category name — renamed to match Trip Path Quest's theme
  /// names ("Food Quest", "Culture Quest", "Heritage Quest", "Nature
  /// Quest") so a Map marker and a Trip Path/Puzzle quest read as the same
  /// kind of thing, instead of exposing gm.dart's raw internal label
  /// ("Local Food", "Park & Garden", ...) straight to the player. Based on
  /// [routeGroup] rather than fuzzy-matching [generalCategory] text, since
  /// routeGroup is already the exact category gm.dart computed. Falls back
  /// to "Mystery Quest" for the generic "Local Attraction" catch-all (no
  /// matching routeGroup), matching Puzzle's own
  /// _categoryDisplayLabel fallback.
  String get questCategoryLabel => switch (routeGroup) {
    'food' => 'Food Quest',
    'culture' => 'Culture Quest',
    'heritage' => 'Heritage Quest',
    'nature' => 'Nature Quest',
    _ => 'Mystery Quest',
  };

  /// UC-03 – approximate distance only, never a precise figure.
  String get approximateDistanceLabel {
    if (distanceKm < 1) return 'Nearby';
    final upperBound = (distanceKm.floor() + 1).clamp(2, 5);
    return 'Less than $upperBound km away';
  }

  /// UC-03 C8 – both Puzzle and Trip Path are always available from a
  /// marker; Trip Path starts the same live checkpoint search used by the
  /// Theme button (see `_routeToGame` in main.dart), so a marker never needs
  /// its own weaker pre-check to decide whether to offer the button.
  bool availabilityFor(ProximityGameMode mode) => true;
}

/// The bundle UC-03 passes to UC-05 (FR03_9).
class MapGameHandoff {
  const MapGameHandoff({
    required this.mode,
    required this.entrySource,
    this.marker,
    required this.touristLatitude,
    required this.touristLongitude,
  });

  final ProximityGameMode mode;
  final MapGameEntrySource entrySource;

  /// The selected hidden place, or `null` for a general button search.
  final HiddenPlaceMarker? marker;
  final double touristLatitude;
  final double touristLongitude;

  bool get isMarkerSpecific =>
      entrySource == MapGameEntrySource.proximityGameMarker;
}

class MapRepository {
  MapRepository(
    this.locationService, {
    this.geminiService,
    this.maxProximityRadiusKm = 4,
    this.minRating = 4.0,
    // Lowered 30 -> 10 by explicit request (matches gm.dart's
    // _minGameReviewCount and Trip Path Quest's own hidden-place review
    // floor) after too few real nearby places cleared 30 once many were
    // already claimed during testing.
    this.minReviewCount = 10,
    // Lowered 20000 -> 1000 to match Trip Path Quest's own hidden-place
    // review ceiling (see AttractionRepository.maximumHiddenPlaceReviewCount)
    // — keeps Map markers feeling like discoverable local spots instead of
    // the most over-touristed landmarks in the area.
    this.maxReviewCount = 1000,
    this.maxPhotoScreenChecks = 8,
  });

  final LocationService locationService;

  /// UC-05 — when supplied, each candidate's photo is screened so only genuine
  /// outdoor landmarks become markers. Left `null` in tests.
  final GeminiService? geminiService;

  /// Cap on how many of the nearest candidates get a (rate-limited) vision
  /// check per map load.
  final int maxPhotoScreenChecks;

  /// placeId → "photo shows an outdoor landmark", reused across map reloads.
  final Map<String, bool> _outdoorPhotoCache = {};

  /// Starting radius for eligible Proximity Game opportunities (UC-03 C4).
  /// [getProximityGameMarkers] widens past this on its own when it doesn't
  /// find [targetMarkerCount] eligible markers — see that method.
  final double maxProximityRadiusKm;

  /// [getProximityGameMarkers] keeps doubling the search radius until at
  /// least this many eligible markers are found, or the radius hits
  /// [_maxSearchRadiusKm]. By explicit request — 2km wasn't reliably enough
  /// candidates in less dense areas.
  static const int targetMarkerCount = 8;

  /// Ceiling for the radius-doubling above. Google's Nearby Search (New)
  /// hard-caps the `radius` parameter at 50000m regardless of what's sent —
  /// searching past this would just get silently clamped server-side, so
  /// there's no point trying further. This is the closest thing to
  /// "unlimited" the underlying API actually allows.
  static const double _maxSearchRadiusKm = 50.0;

  /// UC-03 C3 / FR03_6 — the largest distance [_generalise] moves a marker off
  /// its real place. The map draws a "somewhere in this area" circle a little
  /// larger than this around every marker.
  static const double maxGeneralisationOffsetKm = 0.20;

  /// Configured hidden-place eligibility rules (UC-03 C4).
  final double minRating;

  /// Below this the place is almost always a mislabelled nursery / playground /
  /// shop-lot rather than a landmark.
  final int minReviewCount;
  final int maxReviewCount;

  /// UC-03 BF-4/BF-7 – eligible nearby hidden places as neutral markers,
  /// nearer markers first (C5). Returns an empty list when the tourist's
  /// location is unknown so the map still loads (C2).
  ///
  /// The exact attraction coordinate from the Places service is never used for
  /// the marker – each marker sits on a deliberately generalised point so the
  /// real location stays hidden until the game reveals it (C3 / FR03_6).
  ///
  /// Starts the search at [maxProximityRadiusKm]. When that doesn't turn up
  /// at least [targetMarkerCount] eligible, outdoor-screened markers, the
  /// radius doubles and the whole search (fetch + eligibility filter +
  /// outdoor screening) runs again, up to [_maxSearchRadiusKm] — by explicit
  /// request, so a tourist in a less dense area still gets a full set of
  /// markers instead of getting stuck with whatever a fixed 2km happens to
  /// contain. Each retry is a real network round-trip (and, for the first 8
  /// candidates, a Gemini vision call), so this can take noticeably longer
  /// than a single fixed-radius load in a sparse area — that trade-off is
  /// the explicit ask here.
  Future<List<HiddenPlaceMarker>> getProximityGameMarkers({
    required TouristPosition? position,
    Set<String> excludedPlaceIds = const {},
  }) async {
    if (position == null) return const [];

    var radiusKm = maxProximityRadiusKm;
    // Google's Nearby Search uses POPULARITY ranking (see the comment on
    // this in gm.dart), so a doubled radius is NOT guaranteed to be a
    // superset of a smaller radius's results — a bigger circle can return a
    // completely different, sometimes worse, top-N set, and a place found at
    // a smaller radius can vanish from a bigger one's top-N entirely.
    // Accumulate every real find across every radius tried (deduped by id),
    // instead of trusting only the single latest pass — that way a good
    // candidate found early is never thrown away just because a later,
    // wider pass came back worse while still chasing targetMarkerCount.
    final accumulated = <String, Map<String, dynamic>>{};

    // Widening the radius has clear diminishing returns in practice — once
    // two tiers in a row add zero new eligible markers, later (much more
    // expensive: a fresh Places search plus Gemini photo screening per
    // candidate) tiers essentially never recover, they just keep re-finding
    // the same already-accumulated places. Bailing out early here instead
    // of always chasing the radius ceiling saves real Gemini quota (the
    // free tier's daily limit is easy to exhaust) without weakening any
    // eligibility rule — it only changes when the search gives up.
    var consecutiveTiersWithNoNewMarkers = 0;

    while (true) {
      final raw = await locationService.googleMapsPlatformExternal
          .fetchEligibleNearbyHiddenPlaces(
        latitude: position.latitude,
        longitude: position.longitude,
        radiusMeters: radiusKm * 1000,
      );

      final eligibleUndeduped = raw
          .where((place) {
            final distanceKm = (place['distance_km'] as num).toDouble();
            final rating = (place['rating'] as num?)?.toDouble() ?? 0;
            final reviews = (place['review_count'] as num?)?.toInt() ?? 0;
            // UC-03 C4 – skip venues that have shut down or are outside their
            // opening hours right now (places with no published hours stay).
            final status =
                (place['business_status'] as String?) ?? 'OPERATIONAL';
            final openNow = place['open_now'] as bool?;
            // Already claimed (Puzzle game_sessions row or Trip Path checkpoint
            // for this account, any status) — never shown again, on this or
            // either other search path.
            final id = place['id'] as String;
            // A hotel/resort can still carry a secondary type like
            // tourist_attraction and pass the type filter; exclude it by
            // name so it never becomes a "hidden place" marker (see
            // GoogleMapsPlatformExternal.looksLikeAccommodation).
            final name = (place['name'] as String?) ?? '';
            // Near a border, the search circle can genuinely reach into a
            // neighbouring country — this app is scoped to Malaysia, so a
            // place Google confirms is elsewhere is never a valid hidden
            // place. countryCode is null when Google didn't return
            // addressComponents for this result; that's treated as
            // "unknown" (kept), not rejected.
            final countryCode = place['country_code'] as String?;
            // gm.dart's _categorise() falls back to the generic 'attraction'
            // route group when a place's Google types don't map to any of
            // the 4 real themes. Puzzle's own full search already excludes
            // this (fetchNearbyPuzzlePlaces), but a Map marker built from
            // this route group has no matching theme to label itself with —
            // it fell back to a bare "Mystery Quest" everywhere the label is
            // shown (this marker's own popup, Puzzle's "Continue Game" list
            // reusing it, Trip Path's theme match). Reject it at the source
            // so the label never needs that fallback.
            final routeGroup = place['route_group'] as String?;
            return distanceKm <= radiusKm &&
                rating >= minRating &&
                reviews >= minReviewCount &&
                reviews <= maxReviewCount &&
                status == 'OPERATIONAL' &&
                openNow != false &&
                !excludedPlaceIds.contains(id) &&
                !GoogleMapsPlatformExternal.looksLikeAccommodation(name) &&
                (countryCode == null || countryCode == 'MY') &&
                const {'food', 'culture', 'heritage', 'nature'}
                    .contains(routeGroup);
          })
          .toList()
        ..sort((a, b) => (a['distance_km'] as num)
            .toDouble()
            .compareTo((b['distance_km'] as num).toDouble()));

      // UC-05 — a popular landmark can have several separate Google Place
      // entries nearby (a photo point, an observation deck, a lookout); keep
      // only the most-reviewed one per same-site cluster so a low-review
      // sub-entry never gets offered as its own independent hidden place.
      // Confident matches are free (name/distance heuristic); an ambiguous
      // pair (similar but not confidently the same) gets one cheap text-only
      // Gemini call instead of being guessed either way.
      final gemini = geminiService;
      final eligible = await GoogleMapsPlatformExternal.dedupeSameSitePlaces(
        eligibleUndeduped,
        onAmbiguousPair: gemini == null
            ? null
            : (a, b) => gemini.areSameRealWorldSite(
                  nameA: a['name'] as String? ?? '',
                  addressA: a['address'] as String? ?? '',
                  nameB: b['name'] as String? ?? '',
                  addressB: b['address'] as String? ?? '',
                ),
      );

      // UC-05 — drop candidates whose photo is an indoor scene, shows a
      // person, or fails other eligibility checks before they ever reach the
      // map, so every marker is a real outdoor landmark.
      final visibleThisPass = await _screenOutdoor(eligible);

      final countBeforeThisTier = accumulated.length;

      for (final place in visibleThisPass) {
        accumulated[place['id'] as String] = place;
      }

      final addedThisTier = accumulated.length - countBeforeThisTier;
      consecutiveTiersWithNoNewMarkers =
          addedThisTier > 0 ? 0 : consecutiveTiersWithNoNewMarkers + 1;

      final reachedTarget = accumulated.length >= targetMarkerCount;
      final reachedRadiusCeiling = radiusKm >= _maxSearchRadiusKm;
      // Only bail out early once there is already a reasonable result to
      // show (at least half of targetMarkerCount). Without this floor, a
      // sparse area — the exact case the radius-widening loop exists for —
      // could stall at 0-1 markers for two tiers and give up long before
      // reaching the radius ceiling, defeating the whole point of widening
      // the search at all.
      final noProgressForTwoTiers = consecutiveTiersWithNoNewMarkers >= 2 &&
          accumulated.length >= (targetMarkerCount / 2).ceil();
      debugPrint(
        '[MAP] radiusKm=$radiusKm raw=${raw.length} eligible=${eligible.length} '
        'visible=${visibleThisPass.length} accumulated=${accumulated.length} '
        'addedThisTier=$addedThisTier '
        'reachedTarget=$reachedTarget reachedRadiusCeiling=$reachedRadiusCeiling '
        'noProgressForTwoTiers=$noProgressForTwoTiers',
      );
      if (reachedTarget || reachedRadiusCeiling || noProgressForTwoTiers) {
        break;
      }

      radiusKm = (radiusKm * 2).clamp(0, _maxSearchRadiusKm);
    }

    // A final cross-radius same-site dedup pass: two different radii can
    // each independently surface a different sub-entry of the same
    // real-world site (each already deduped WITHIN its own pass above, but
    // not against a different pass's finds). Heuristic-only — no Gemini
    // call — since this is just a safety net over results that already
    // individually passed the fuller dedup above.
    final visible = await GoogleMapsPlatformExternal.dedupeSameSitePlaces(
      accumulated.values.toList(),
    );

    final generalised = visible.map((place) {
      final id = place['id'] as String;
      final realLat = (place['latitude'] as num).toDouble();
      final realLng = (place['longitude'] as num).toDouble();
      final general = _generalise(realLat, realLng, id);
      return HiddenPlaceMarker(
        id: id,
        generalCategory: place['general_category'] as String,
        generalAreaLatitude: general.$1,
        generalAreaLongitude: general.$2,
        distanceKm: (place['distance_km'] as num).toDouble(),
        routeGroup: place['route_group'] as String?,
      );
    }).toList();

    final result = List<HiddenPlaceMarker>.unmodifiable(
      _spreadOverlappingMarkers(generalised),
    );
    debugPrint('[MAP] getProximityGameMarkers returning ${result.length} markers');
    return result;
  }

  /// UC-03 — pushes apart any two markers whose generalised points ended up
  /// close enough to visually overlap their 78 px pins on the map.
  /// [_generalise] only considers one place at a time, so two real places
  /// that happen to be near each other can still land close together after
  /// generalisation; this nudges each such pair apart (both move, so
  /// neither jumps past the other) rather than leaving overlapping pins the
  /// tourist can't tell apart or tap individually.
  static const double _minMarkerSeparationKm = 0.15;

  List<HiddenPlaceMarker> _spreadOverlappingMarkers(
    List<HiddenPlaceMarker> markers,
  ) {
    if (markers.length < 2) return markers;

    final lats = [for (final m in markers) m.generalAreaLatitude];
    final lngs = [for (final m in markers) m.generalAreaLongitude];

    // A few passes so a cluster of 3+ close markers settles rather than
    // just resolving the first pair and leaving others still touching.
    for (var pass = 0; pass < 3; pass++) {
      for (var i = 0; i < markers.length; i++) {
        for (var j = i + 1; j < markers.length; j++) {
          final distance = _haversineKm(lats[i], lngs[i], lats[j], lngs[j]);
          if (distance >= _minMarkerSeparationKm) continue;

          final shortfallKm = _minMarkerSeparationKm - distance;
          // Arbitrary but deterministic direction when the two points
          // coincide exactly (distance == 0) — astronomically unlikely,
          // just needs to not divide by zero.
          final bearing = distance == 0
              ? 0.0
              : math.atan2(lngs[j] - lngs[i], lats[j] - lats[i]);
          final pushKm = shortfallKm / 2 + 0.01;
          final dLat = pushKm / 111.0 * math.cos(bearing);
          final dLng = pushKm /
              (111.0 * math.cos(lats[i] * math.pi / 180)) *
              math.sin(bearing);
          lats[i] -= dLat;
          lngs[i] -= dLng;
          lats[j] += dLat;
          lngs[j] += dLng;
        }
      }
    }

    return [
      for (var i = 0; i < markers.length; i++)
        HiddenPlaceMarker(
          id: markers[i].id,
          generalCategory: markers[i].generalCategory,
          generalAreaLatitude: lats[i],
          generalAreaLongitude: lngs[i],
          distanceKm: markers[i].distanceKm,
          routeGroup: markers[i].routeGroup,
        ),
    ];
  }

  /// Vision-screens the nearest [maxPhotoScreenChecks] candidates in parallel
  /// (results cached per place id). Tries every available candidate photo in
  /// order (not just the first) until one is a genuine outdoor exterior with
  /// no person visible — matching Puzzle's multi-photo screening, since
  /// Places often returns a food/menu close-up or an indoor shot before the
  /// storefront/exterior photo. For a Nature place, a photo that also shows a
  /// landmark/entrance sign is preferred over an otherwise-eligible one that
  /// doesn't. Fails open — keeps everything when no Gemini service is wired,
  /// no photo is available, or a check errors — and never returns an empty
  /// list when there were candidates.
  Future<List<Map<String, dynamic>>> _screenOutdoor(
    List<Map<String, dynamic>> places,
  ) async {
    final gemini = geminiService;
    if (gemini == null || places.isEmpty) return places;

    final toCheck = places.take(maxPhotoScreenChecks).toList();
    final rest = places.skip(maxPhotoScreenChecks).toList();

    final verdicts = await Future.wait(
      toCheck.map((place) async {
        final id = place['id'] as String;
        final cached = _outdoorPhotoCache[id];
        if (cached != null) return (place, cached);

        final photoUrls = ((place['photo_urls'] as List?)?.cast<String>() ??
                const <String>[])
            .where((url) => url.isNotEmpty)
            .toList();
        if (photoUrls.isEmpty) {
          final fallbackUrl = place['photo_url'] as String?;
          if (fallbackUrl != null && fallbackUrl.isNotEmpty) {
            photoUrls.add(fallbackUrl);
          }
        }
        if (photoUrls.isEmpty) {
          _outdoorPhotoCache[id] = true;
          return (place, true);
        }

        final routeGroup = place['route_group'] as String?;
        final isNature = routeGroup == 'nature';
        var eligibleWithoutSign = false;

        for (final url in photoUrls) {
          final screening = await gemini.screenLandmarkPhoto(
            url,
            routeGroup: routeGroup,
          );
          if (!screening.isEligible) continue;
          if (!isNature || screening.hasLandmarkSign) {
            _outdoorPhotoCache[id] = true;
            return (place, true);
          }
          eligibleWithoutSign = true;
        }

        _outdoorPhotoCache[id] = eligibleWithoutSign;
        return (place, eligibleWithoutSign);
      }),
    );

    final kept = [
      for (final (place, ok) in verdicts)
        if (ok) place,
      ...rest,
    ];
    return kept.isEmpty ? places.take(3).toList() : kept;
  }

  /// UC-03 C3 / FR03_6 – moves a marker off the exact attraction so the real
  /// spot stays hidden until the game reveals it, but only by ~100–200 m so the
  /// marker still sits in the same block/area as the real place. A larger offset
  /// makes the Navigate step feel like it points at a different place. The
  /// offset is deterministic per place id so the marker does not jump between
  /// map loads, and never exceeds [maxGeneralisationOffsetKm].
  static (double, double) _generalise(double lat, double lng, String id) {
    final seed = id.codeUnits.fold<int>(7, (h, c) => (h * 31 + c) & 0x7fffffff);
    final angle = (seed % 360) * math.pi / 180;
    final radiusKm = maxGeneralisationOffsetKm / 2 +
        (seed % (maxGeneralisationOffsetKm * 500).round()) / 1000.0;
    final dLat = radiusKm / 111.0 * math.cos(angle);
    final dLng =
        radiusKm / (111.0 * math.cos(lat * math.pi / 180)) * math.sin(angle);
    double round4(double v) => (v * 1e4).roundToDouble() / 1e4;
    return (round4(lat + dLat), round4(lng + dLng));
  }

  static double _haversineKm(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const earthRadiusKm = 6371.0;
    final dLat = _toRadians(lat2 - lat1);
    final dLon = _toRadians(lon2 - lon1);
    final a = math.pow(math.sin(dLat / 2), 2) +
        math.cos(_toRadians(lat1)) *
            math.cos(_toRadians(lat2)) *
            math.pow(math.sin(dLon / 2), 2);
    return earthRadiusKm * 2 * math.asin(math.sqrt(a.toDouble()));
  }

  static double _toRadians(double degrees) => degrees * math.pi / 180;
}
