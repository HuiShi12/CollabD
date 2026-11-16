import 'package:flutter/foundation.dart';

import '../../../External_services/Google Maps Platform and Location Services/gm.dart';
import '../../service/Gemini Service/gemini.dart';
import '../../service/Location Service/location.dart';

void _logPuzzleReference(String message) {
  if (!kDebugMode) return;
  debugPrint('[PUZZLE REFERENCE] $message');
}

/// UC-05 — the hidden place behind a Proximity Game marker is no longer open
/// (permanently/temporarily closed). The tourist should pick another marker.
class PlaceUnavailableException implements Exception {
  const PlaceUnavailableException();
}

/// UC-05 — every candidate photo Google has for this place failed the
/// outdoor/recognisable eligibility screening. Rather than silently falling
/// back to an unrelated stock placeholder image, callers with other
/// candidates to try should skip this place; a caller with no alternative
/// (a specific marker the tourist tapped) should surface this as an error.
class NoEligibleReferencePhotoException implements Exception {
  const NoEligibleReferencePhotoException();
}

class MysteryPlaceOption {
  final String id;
  final String name;
  final String category;
  final String township;
  final String description;
  final double latitude;
  final double longitude;
  final int distanceMeter;
  final String direction;
  final String imageUrl;

  MysteryPlaceOption({
    required this.id,
    required this.name,
    required this.category,
    required this.township,
    required this.description,
    required this.latitude,
    required this.longitude,
    required this.distanceMeter,
    required this.direction,
    required this.imageUrl,
  });

  MysteryPlaceOption copyWithImage(String imageUrl) => MysteryPlaceOption(
        id: id,
        name: name,
        category: category,
        township: township,
        description: description,
        latitude: latitude,
        longitude: longitude,
        distanceMeter: distanceMeter,
        direction: direction,
        imageUrl: imageUrl,
      );

  factory MysteryPlaceOption.fromMap(Map<String, dynamic> map) {
    return MysteryPlaceOption(
      id: map['id'],
      name: map['name'],
      category: map['category'],
      township: map['township'],
      description: map['description'],
      latitude: (map['latitude'] as num).toDouble(),
      longitude: (map['longitude'] as num).toDouble(),
      distanceMeter: map['distance_meter'] as int,
      direction: map['direction'],
      imageUrl: map['image_url'],
    );
  }
}

class AttractionRepository {
  final LocationService locationService;
  final GeminiService geminiService;

  AttractionRepository(this.locationService, this.geminiService);

  // Doubling ladder starting from Puzzle's original fixed 2 km search —
  // mirrors MapRepository.getProximityGameMarkers() and Trip Path's own
  // searchRadii, capped at 50 km (Google Places Nearby Search (New)'s real
  // hard limit; see the matching notes on those two). Before this, "Choose
  // a Mystery" only ever tried 2 km once and reported "No nearby puzzle
  // missions were found" the moment that single circle came up empty —
  // exactly the failure the doubling below now retries past.
  static const List<double> _puzzleSearchRadiiMeters = [
    2000, 4000, 8000, 16000, 32000, 50000,
  ];
  static const int _puzzleTargetOptionCount = 3;

  Future<List<MysteryPlaceOption>> getNearbyPuzzleOptions({
    Set<String> excludedPlaceIds = const {},
  }) async {
    final currentLocation = await locationService.getCurrentLocation();
    final latitude = (currentLocation['latitude'] as num).toDouble();
    final longitude = (currentLocation['longitude'] as num).toDouble();

    final accepted = <String, MysteryPlaceOption>{};
    // Only ever used as the very last resort (see the end of the loop) —
    // the nearest unscreened candidates from the last radius that had any,
    // so the game never ends with literally nothing to pick even when every
    // radius up to 50 km failed vision screening.
    var fallbackCandidates = const <MysteryPlaceOption>[];

    for (final radiusMeters in _puzzleSearchRadiiMeters) {
      final allResults = await locationService.googleMapsPlatformExternal
          .fetchNearbyPuzzlePlaces(
        latitude: latitude,
        longitude: longitude,
        radiusMeters: radiusMeters,
      );

      // Already claimed (Puzzle game_sessions row or Trip Path checkpoint
      // for this account, any status) — filtered out before the
      // vision-screening loop below so a place that can never be offered
      // doesn't also burn a Gemini call.
      final excludedFiltered = excludedPlaceIds.isEmpty
          ? allResults
          : allResults
              .where((raw) => !excludedPlaceIds.contains(raw['id'] as String?))
              .toList();

      // Second, ambiguous-pairs-only same-site dedup pass.
      // fetchNearbyPuzzlePlaces already merged confident same-site
      // duplicates for free (no Gemini call); this only spends a cheap
      // text-only Gemini call per pair whose name similarity is in the
      // ambiguous band, instead of on every batch.
      final rawResults = await GoogleMapsPlatformExternal.dedupeSameSitePlaces(
        excludedFiltered,
        onAmbiguousPair: (a, b) => geminiService.areSameRealWorldSite(
          nameA: a['name'] as String? ?? '',
          addressA:
              (a['address'] as String?) ?? (a['township'] as String?) ?? '',
          nameB: b['name'] as String? ?? '',
          addressB:
              (b['address'] as String?) ?? (b['township'] as String?) ?? '',
        ),
      );

      // fetchNearbyPuzzlePlaces already sorts by distance ascending.
      final candidates = rawResults.map(MysteryPlaceOption.fromMap).toList();
      if (candidates.isNotEmpty) fallbackCandidates = candidates;

      // UC-05 — screen the 6 nearest candidates in parallel; for each, walk
      // its photos in order and keep the first genuine outdoor exterior /
      // storefront shot (not an indoor scene, not a food/menu/item
      // close-up, and never one showing a person — Places often returns
      // those before the storefront photo). A photo that also shows a
      // readable landmark/entrance/shop-name sign is preferred over one
      // that doesn't — for Food this is the shop's own signage/name, so the
      // tourist can recognise which place to walk to — whenever both are
      // otherwise eligible, across every theme (not just Nature).
      final screened = await Future.wait(
        rawResults.take(6).map((raw) async {
          final option = MysteryPlaceOption.fromMap(raw);
          final photoUrls = ((raw['photo_urls'] as List?)?.cast<String>() ??
                  const <String>[])
              .where((url) => url.isNotEmpty)
              .toList();
          if (photoUrls.isEmpty) photoUrls.add(option.imageUrl);

          MysteryPlaceOption? eligibleWithoutSign;

          final routeGroup = raw['route_group'] as String?;
          for (var i = 0; i < photoUrls.length; i++) {
            final screening = await geminiService.screenLandmarkPhoto(
              photoUrls[i],
              routeGroup: routeGroup,
            );
            _logPuzzleReference(
              '${option.name} | photo ${i + 1}/${photoUrls.length} | '
              '${screening.isEligible ? 'ELIGIBLE' : 'REJECTED'}'
              '${screening.isEligible && screening.hasLandmarkSign ? ', sign visible' : ''}',
            );
            if (!screening.isEligible) continue;
            if (screening.hasLandmarkSign) {
              return (option.copyWithImage(photoUrls[i]), true);
            }
            eligibleWithoutSign ??= option.copyWithImage(photoUrls[i]);
          }
          if (eligibleWithoutSign != null) {
            _logPuzzleReference(
              '${option.name} -> using eligible photo without a visible sign.',
            );
            return (eligibleWithoutSign, true);
          }
          _logPuzzleReference(
            '${option.name} -> REJECTED, no eligible photo among ${photoUrls.length}. Skipping this place.',
          );
          return (option, false);
        }),
      );

      for (final (option, ok) in screened) {
        if (ok) accepted[option.id] = option;
      }

      if (accepted.length >= _puzzleTargetOptionCount) {
        final result = accepted.values.toList()
          ..sort((a, b) => a.distanceMeter.compareTo(b.distanceMeter));
        return result.take(_puzzleTargetOptionCount).toList();
      }
    }

    // Exhausted every radius up to 50 km. Prefer whatever passed vision
    // screening even if fewer than the target; only fall back to
    // unscreened candidates (never leaving the game with nothing to pick)
    // once nothing screened-eligible was found anywhere.
    if (accepted.isNotEmpty) {
      final result = accepted.values.toList()
        ..sort((a, b) => a.distanceMeter.compareTo(b.distanceMeter));
      return result.take(_puzzleTargetOptionCount).toList();
    }
    return fallbackCandidates.take(_puzzleTargetOptionCount).toList();
  }

  /// UC-03 FR03_9 → UC-05 — build the single puzzle option for a hidden place
  /// chosen through a Proximity Game marker on the map. The marker only carries
  /// a real place id, a general category and an approximate distance; the name
  /// / photo / real coordinates are fetched here from Google Places.
  Future<MysteryPlaceOption> getPuzzleOptionForPlaceId(
    String placeId, {
    required String category,
    required double distanceKm,
    // gm.dart's coarse route group ('food' / 'culture' / 'heritage' /
    // 'nature'), when known (marker-specific entry always has it). Lets the
    // reference-photo screening below reject a photo that's outdoor and
    // person-free but doesn't actually look like this kind of place (e.g. a
    // random skyline shot attached to a nearby business's Google listing).
    String? routeGroup,
  }) async {
    Map<String, dynamic> details = const {};
    try {
      details = await locationService.googleMapsPlatformExternal
          .getPlaceDetails(placeId);
    } catch (_) {
      details = const {};
    }

    // UC-05 — a marker should never point at a shut-down place, but Google's
    // data can be stale, so re-check here.
    final status = (details['business_status'] as String?) ?? 'OPERATIONAL';
    if (status != 'OPERATIONAL') {
      throw const PlaceUnavailableException();
    }

    final geometry = details['geometry'] as Map<String, dynamic>?;
    final loc = geometry?['location'] as Map<String, dynamic>?;
    final photos = (details['photos'] as List?) ?? const [];
    final summary = details['editorial_summary'] as Map<String, dynamic>?;
    final gm = locationService.googleMapsPlatformExternal;
    final placeName = (details['name'] as String?)?.trim().isNotEmpty == true
        ? details['name'] as String
        : placeId;

    // A hotel/resort is never a valid "hidden place" — and every one of its
    // photos will fail the eligibility screening below anyway (room/lobby
    // interiors, never a re-photographable exterior). Reject it here, before
    // spending any Gemini calls on it, instead of burning quota walking
    // through up to 6 photos that were always going to fail. This is the
    // same rule Map's own marker search and Puzzle's full search apply
    // (GoogleMapsPlatformExternal.looksLikeAccommodation) — this single-place
    // lookup (marker tap, or the nearby-markers fast path) is the one path
    // that was missing it.
    if (GoogleMapsPlatformExternal.looksLikeAccommodation(placeName)) {
      _logPuzzleReference(
        '$placeName -> REJECTED, looks like accommodation (hotel/resort/etc).',
      );
      throw const NoEligibleReferencePhotoException();
    }

    // UC-05 — walk the place's photos and use the first one that is a real
    // outdoor exterior / landmark, with no person visible. A photo that
    // also shows a readable landmark/entrance/shop-name sign is preferred
    // over one that doesn't — for Food this is the shop's signage/name,
    // letting the tourist recognise which place to walk to — whenever both
    // are eligible, across every theme (not just Nature). If NONE of this
    // place's photos are eligible, this throws instead of silently falling
    // back to an unrelated stock placeholder image (e.g. picsum) — a
    // tourist should never be sent to "verify" a place using a photo that
    // has nothing to do with it.
    String? imageUrl;
    String? eligibleUrlWithoutSign;
    final candidatePhotos = photos.take(6).toList();
    for (var i = 0; i < candidatePhotos.length; i++) {
      final ref = (candidatePhotos[i] as Map<String, dynamic>)['photo_reference'] as String?;
      if (ref == null) continue;
      final url = gm.getPlacePhotoUrl(ref, maxWidth: 900);
      final screening = await geminiService.screenLandmarkPhoto(
        url,
        routeGroup: routeGroup,
      );
      _logPuzzleReference(
        '$placeName | photo ${i + 1}/${candidatePhotos.length} | '
        '${screening.isEligible ? 'ELIGIBLE' : 'REJECTED'}'
        '${screening.isEligible && screening.hasLandmarkSign ? ', sign visible' : ''}',
      );
      if (!screening.isEligible) continue;
      if (screening.hasLandmarkSign) {
        imageUrl = url;
        break;
      }
      eligibleUrlWithoutSign ??= url;
    }
    imageUrl ??= eligibleUrlWithoutSign;
    if (imageUrl == null) {
      _logPuzzleReference(
        '$placeName -> REJECTED, no eligible photo among ${candidatePhotos.length}.',
      );
      throw const NoEligibleReferencePhotoException();
    }

    return MysteryPlaceOption(
      id: placeId,
      name: (details['name'] as String?)?.trim().isNotEmpty == true
          ? details['name'] as String
          : 'Mystery $category',
      category: category,
      township: (details['vicinity'] as String?) ??
          (details['formatted_address'] as String?) ??
          'Nearby',
      description: (summary?['overview'] as String?) ??
          'A hidden $category waiting to be discovered.',
      latitude: (loc?['lat'] as num?)?.toDouble() ?? 0,
      longitude: (loc?['lng'] as num?)?.toDouble() ?? 0,
      distanceMeter: (distanceKm * 1000).round(),
      direction: 'Nearby',
      imageUrl: imageUrl,
    );
  }
}