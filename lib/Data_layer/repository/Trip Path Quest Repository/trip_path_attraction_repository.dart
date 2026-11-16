import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../../service/Trip Path Quest Service/trip_path_gemini_service.dart';
import '../../service/Trip Path Quest Service/trip_path_location_service.dart';
import '../../service/Trip Path Quest Service/trip_path_reference_photo_service.dart';
import '../../service/Trip Path Quest Service/trip_path_places_service.dart';

class Attraction {
  final String id;
  final String name;
  final String address;

  final double latitude;
  final double longitude;

  final double rating;
  final int userRatingCount;

  final String primaryType;
  final List<String> types;
  final bool? openNow;

  final double distanceMeters;

  // Google Places photo resource names are deliberately kept out
  // of persistence. The selected reference is transient image bytes.
  final String? photoResourceName;
  final String? googleMapsUri;

  final List<GooglePlacePhotoData> photoCandidates;
  final Uint8List? referencePhotoBytes;
  final double? referencePhotoScore;
  final int? referencePhotoWidth;
  final int? referencePhotoHeight;
  final int? referencePhotoKeypoints;
  final double? referencePhotoCoverage;
  final double? referencePhotoSharpness;
  final double? referenceSemanticScore;
  final bool referenceOcrNameMatched;
  final List<String> referenceSemanticLabels;
  final int referenceSuitabilityTier;
  final String referenceKind;
  final double? referenceSuitabilityScore;
  final String referenceFingerprint;

  const Attraction({
    required this.id,
    required this.name,
    required this.address,
    required this.latitude,
    required this.longitude,
    required this.rating,
    required this.userRatingCount,
    required this.primaryType,
    required this.types,
    required this.openNow,
    required this.distanceMeters,
    this.photoResourceName,
    this.googleMapsUri,
    this.photoCandidates = const <GooglePlacePhotoData>[],
    this.referencePhotoBytes,
    this.referencePhotoScore,
    this.referencePhotoWidth,
    this.referencePhotoHeight,
    this.referencePhotoKeypoints,
    this.referencePhotoCoverage,
    this.referencePhotoSharpness,
    this.referenceSemanticScore,
    this.referenceOcrNameMatched = false,
    this.referenceSemanticLabels = const <String>[],
    this.referenceSuitabilityTier = 99,
    this.referenceKind = 'unknown',
    this.referenceSuitabilityScore,
    this.referenceFingerprint = '',
  });

  double get distanceKilometers {
    return distanceMeters / 1000;
  }

  bool get hasAutomaticReferencePhoto {
    return referencePhotoBytes != null &&
        referencePhotoBytes!.isNotEmpty;
  }

  Attraction withReferencePhoto(
    TripPathReferencePhotoSelection selection,
  ) {
    return Attraction(
      id: id,
      name: name,
      address: address,
      latitude: latitude,
      longitude: longitude,
      rating: rating,
      userRatingCount: userRatingCount,
      primaryType: primaryType,
      types: types,
      openNow: openNow,
      distanceMeters: distanceMeters,
      // Intentionally null: Google photo resource names are not stored.
      photoResourceName: null,
      googleMapsUri: googleMapsUri,
      photoCandidates: const <GooglePlacePhotoData>[],
      referencePhotoBytes: selection.bytes,
      referencePhotoScore: selection.totalScore,
      referencePhotoWidth: selection.width,
      referencePhotoHeight: selection.height,
      referencePhotoKeypoints: selection.keypoints,
      referencePhotoCoverage: selection.featureCoverage,
      referencePhotoSharpness: selection.sharpnessVariance,
      referenceSemanticScore: selection.semanticScore,
      referenceOcrNameMatched: selection.ocrNameMatched,
      referenceSemanticLabels: List.unmodifiable(selection.semanticLabels),
      referenceSuitabilityTier: selection.suitabilityTier,
      referenceKind: selection.referenceKind,
      referenceSuitabilityScore: selection.suitabilityScore,
      referenceFingerprint: selection.referenceFingerprint,
    );
  }
}


class QuestCheckpointAreaExclusion {
  final String name;
  final String address;
  final double latitude;
  final double longitude;

  const QuestCheckpointAreaExclusion({
    required this.name,
    required this.address,
    required this.latitude,
    required this.longitude,
  });
}

class _ReferenceScreeningState {
  Attraction? accepted;
  bool firstPassDone;
  bool fullPassDone;

  _ReferenceScreeningState({
    this.accepted,
    this.firstPassDone = false,
    this.fullPassDone = false,
  });
}

class AttractionRepositoryException implements Exception {
  final String message;

  const AttractionRepositoryException(
    this.message,
  );

  @override
  String toString() {
    return message;
  }
}

class AttractionRepository {
  final GoogleMapsPlatformService googleMapsPlatformService;
  final LocationService locationService;
  final TripPathReferencePhotoService referencePhotoService;

  /// Optional — when supplied, an ambiguous same-site name-similarity pair
  /// (see [_dedupeSameSiteCandidates]) gets one cheap text-only Gemini call
  /// instead of being guessed either way. Left `null` in tests/callers that
  /// don't need it; the free name/distance heuristic still applies.
  final GeminiService? geminiService;

  AttractionRepository({
    required this.googleMapsPlatformService,
    required this.locationService,
    required this.referencePhotoService,
    this.geminiService,
  });

  // ============================================================
  // TRIP PATH QUEST FILTER RULES
  //
  // Trip Path Quest may use popular attractions, so there is no
  // maximum review-count rule here.
  // ============================================================

  static const double minimumTripPathRating = 4.0;
  static const int minimumTripPathReviewCount = 10;

  // ============================================================
  // HIDDEN-PLACE FILTER RULES
  //
  // Trip Path Quest now uses this mode so checkpoints feel local and
  // discoverable instead of simply choosing the most popular attractions.
  // ============================================================

  // Hidden-place quality/popularity balance:
  //
  // 1. Places with real Google popularity data are preferred when:
  //    rating >= 4.0, reviews >= 10, reviews <= 1000.
  // 2. A genuine 0.0 rating + 0 reviews is treated as "no popularity
  //    data", not as a bad rating. It is allowed only as a fallback.
  //    The existing reference-photo semantic/OpenCV screening must still
  //    pass before it can ever become a checkpoint.
  // 3. Partially missing popularity data (rating without reviews or vice
  //    versa) is rejected because it cannot be interpreted reliably.
  //
  // This keeps small stalls/local places possible without letting rating
  // or review count become clue content.
  static const double minimumHiddenPlaceRating = 4.0;
  static const int minimumHiddenPlaceReviewCount = 10;
  static const int maximumHiddenPlaceReviewCount = 1000;

  // ============================================================
  // SEARCH RADIUS
  //
  // Start nearby and only expand when needed — doubling each pass, same
  // shape as MapRepository.getProximityGameMarkers()'s radius-expansion
  // loop (2 -> 4 -> 8 -> 16 -> 32 -> 50 km there). Capped at 50 km — that is
  // a hard limit of the Google Places Nearby Search (New) API itself
  // (TripPathPlacesService.searchNearbyPlaces rejects anything larger; see
  // gm.dart's matching note for Map/Puzzle), not a limit we chose, so this
  // tier list cannot go any further out with a single search circle no
  // matter how "infinite" we want the expansion to feel. Genuinely
  // searching past 50 km would need multiple search circles tiled outward
  // from different center points — a materially bigger feature, not a
  // parameter change — see the conversation for that trade-off if it's
  // still wanted.
  // ============================================================

  static const List<double> searchRadii = [
    5000,  // 5 km
    10000, // 10 km
    20000, // 20 km
    40000, // 40 km
    50000, // 50 km (Google Places API hard cap)
  ];

  // CP1 fast path: inspect a small candidate window and only two
  // photos per place before widening the search. This keeps Start Quest
  // responsive without weakening the "reference-ready before lock" rule.
  static const int fastCheckpointCandidateWindow = 5;
  static const int fastCheckpointInitialPhotoCount = 2;

  // Bound the emergency rescue so a pathological area cannot trigger an
  // excessive number of Place Photo requests.
  static const int finalRescueCandidateLimit = 10;

  // ============================================================
  // FIND NEARBY ATTRACTIONS
  //
  // When preferLessPopular = false:
  // Trip Path Quest rules are used.
  //
  // When preferLessPopular = true:
  // the stricter hidden-place rules are used.
  // ============================================================

  Future<List<Attraction>> findNearbyAttractions({
    required double latitude,
    required double longitude,
    required String themeId,
    int limit = 3,
    bool preferLessPopular = false,
    bool fastFirstCheckpoint = false,
    Set<String> excludedPlaceIds = const <String>{},
    List<QuestCheckpointAreaExclusion> excludedCheckpointAreas =
        const <QuestCheckpointAreaExclusion>[],
    // Optional user-facing status updates (radius tier, candidate being
    // checked) so a caller's loading screen can show real progress instead
    // of a single static message for however long this search takes.
    // Purely additive — never affects the search logic itself.
    void Function(String message)? onProgress,
  }) async {
    final placeTypes = _getGooglePlaceTypes(
      themeId,
    );

    if (placeTypes.isEmpty) {
      throw AttractionRepositoryException(
        'Unsupported Trip Path Quest theme: $themeId',
      );
    }

    if (limit <= 0) {
      throw const AttractionRepositoryException(
        'Attraction limit must be greater than zero.',
      );
    }

    _debugHeader(
      title: 'GOOGLE PLACES QUEST SEARCH',
    );

    _debugPrint(
      'Theme: $themeId',
    );

    _debugPrint(
      'Origin GPS: '
      '${latitude.toStringAsFixed(7)}, '
      '${longitude.toStringAsFixed(7)}',
    );

    _debugPrint(
      'Included types: ${placeTypes.join(', ')}',
    );

    _debugPrint(
      'Mode: '
      '${preferLessPopular ? 'LESS-POPULAR / HIDDEN' : 'TRIP PATH'}',
    );

    _debugPrint(
      'CP1 fast path: ${fastFirstCheckpoint ? 'ON' : 'OFF'}',
    );

    _debugPrint(
      'Previously visited Place IDs excluded: '
      '${excludedPlaceIds.length}',
    );

    _debugPrint(
      'Existing checkpoint areas excluded: '
      '${excludedCheckpointAreas.length}',
    );

    // Nearby Search results are cached for this repository call. Hidden
    // popularity Tier 2 / Tier 3 re-use the SAME Google responses instead
    // of repeating Nearby Search requests for the same radius.
    final Map<double, List<GooglePlaceData>>
        rawPlacesByRadius = {};

    // Prevent duplicate photo downloads / ML analysis when a radius grows
    // or the popularity tier relaxes.
    final Map<String, _ReferenceScreeningState>
        referenceScreeningCache = {};

    // Used only as a last-resort CP1 rescue. It lets the app exhaust
    // remaining photo candidates before finally saying no safe checkpoint
    // exists, without weakening any hard rule.
    final Map<String, Attraction>
        allEligiblePlaces = {};

    final popularityTiers = preferLessPopular
        ? const <int>[1, 2, 3]
        : const <int>[0];

    for (final popularityTier in popularityTiers) {
      final Map<String, Attraction> suitablePlaces = {};

      if (preferLessPopular) {
        _debugPrint('');
        _debugPrint(
          '========== HIDDEN POPULARITY '
          '${_hiddenPopularityTierLabel(popularityTier)} ==========',
        );
      }

      for (final radius in searchRadii) {
        _debugPrint('');
        _debugPrint(
          '>>> Search radius: '
          '${(radius / 1000).toStringAsFixed(0)} km',
        );

        onProgress?.call(
          'Searching within ${(radius / 1000).toStringAsFixed(0)} km...',
        );

        var googlePlaces =
            rawPlacesByRadius[radius];

        if (googlePlaces == null) {
          googlePlaces =
              await googleMapsPlatformService.searchNearbyPlaces(
            latitude: latitude,
            longitude: longitude,
            includedTypes: placeTypes,
            radiusMeters: radius,
            maxResultCount: 20,
            // Larger circles with DISTANCE keep returning the same nearest 20.
            rankPreference: radius == searchRadii.first ? 'DISTANCE' : 'POPULARITY',
          );

          rawPlacesByRadius[radius] =
              List<GooglePlaceData>.unmodifiable(googlePlaces);

          _debugPrint(
            'Places returned by Google: ${googlePlaces.length}',
          );

          for (var index = 0;
              index < googlePlaces.length;
              index++) {
            final place = googlePlaces[index];

            _debugPrint(
              '[RETURN ${index + 1}] '
              '${place.name} | '
              'GPS=${place.latitude.toStringAsFixed(7)},'
              '${place.longitude.toStringAsFixed(7)} | '
              'rating=${place.rating.toStringAsFixed(1)} | '
              'reviews=${place.userRatingCount} | '
              'type=${place.primaryType} | '
              'photos=${place.photos.length} | '
              'status=${place.businessStatus} | '
              'openNow=${place.openNow?.toString() ?? 'UNKNOWN'}',
            );
          }
        } else {
          _debugPrint(
            'Reusing ${googlePlaces.length} cached Nearby Search '
            'result(s) for this radius.',
          );
        }

        for (final place in googlePlaces) {
          // ----------------------------------------------------
          // HARD RULES - NEVER RELAX
          // ----------------------------------------------------

          if (place.id.trim().isEmpty) {
            continue;
          }

          if (excludedPlaceIds.contains(place.id)) {
            _debugPrint(
              '[EXCLUDED VISITED] '
              '${place.name} | Place ID=${place.id}',
            );
            continue;
          }

          final areaConflict = _checkpointAreaConflict(
            place: place,
            themeId: themeId,
            excludedAreas: excludedCheckpointAreas,
          );

          if (areaConflict != null) {
            _debugPrint(
              '[EXCLUDED SAME AREA] ${place.name} -> $areaConflict',
            );
            continue;
          }

          if (place.businessStatus != 'OPERATIONAL') {
            _debugPrint(
              '[CLOSED/UNAVAILABLE] ${place.name} | '
              'businessStatus=${place.businessStatus}',
            );
            continue;
          }

          // Near a border, the search circle can genuinely reach into a
          // neighbouring country (Thailand, Singapore, Indonesia, Brunei).
          // This app is scoped to Malaysia, so a place Google confirms is
          // elsewhere is never a valid checkpoint. countryCode is null when
          // Google didn't return addressComponents for this result — that's
          // treated as "unknown" (kept), not rejected.
          if (place.countryCode != null && place.countryCode != 'MY') {
            _debugPrint(
              '[OUTSIDE MALAYSIA] ${place.name} | '
              'countryCode=${place.countryCode}',
            );
            continue;
          }

          // Explicitly closed = never use as a live checkpoint.
          // null is kept because parks, outdoor landmarks and some small
          // stalls do not publish live opening-hours data.
          if (place.openNow == false) {
            _debugPrint(
              '[CLOSED NOW] ${place.name} -> rejected.',
            );
            continue;
          }

          if (place.photos.isEmpty) {
            _debugPrint(
              '[NO REFERENCE CANDIDATES] ${place.name} -> rejected.',
            );
            continue;
          }

          // ----------------------------------------------------
          // THEME RELEVANCE - NEVER RELAX
          //
          // Google Places can return broad/secondary matches. A place
          // must still make sense for the selected quest theme before
          // any popularity/reference-photo request is spent on it.
          // ----------------------------------------------------

          if (!_isThemeRelevantPlace(
            place: place,
            themeId: themeId,
          )) {
            _debugPrint(
              '[THEME REJECT] ${place.name} | '
              'theme=$themeId | primaryType=${place.primaryType} | '
              'types=${place.types.join(', ')}',
            );
            continue;
          }

          // ----------------------------------------------------
          // POPULARITY RULES
          //
          // Hidden mode tries ALL distance radii in Tier 1 before
          // relaxing to Tier 2, then Tier 3.
          // ----------------------------------------------------

          if (preferLessPopular) {
            final placeTier =
                _hiddenPopularityTier(place);

            if (placeTier == null) {
              continue;
            }

            if (placeTier != popularityTier) {
              continue;
            }
          } else {
            if (place.rating > 0 &&
                place.rating < minimumTripPathRating) {
              continue;
            }

            if (place.userRatingCount > 0 &&
                place.userRatingCount <
                    minimumTripPathReviewCount) {
              continue;
            }
          }

          final distance =
              locationService.calculateDistanceInMeters(
            startLatitude: latitude,
            startLongitude: longitude,
            endLatitude: place.latitude,
            endLongitude: place.longitude,
          );

          if (distance > radius) {
            continue;
          }

          final attraction = Attraction(
            id: place.id,
            name: place.name,
            address: place.address,
            latitude: place.latitude,
            longitude: place.longitude,
            rating: place.rating,
            userRatingCount: place.userRatingCount,
            primaryType: place.primaryType,
            types: List.unmodifiable(place.types),
            openNow: place.openNow,
            distanceMeters: distance,
            photoResourceName: null,
            googleMapsUri: place.googleMapsUri,
            photoCandidates:
                List.unmodifiable(place.photos),
          );

          suitablePlaces[place.id] = attraction;
          allEligiblePlaces[place.id] = attraction;
        }

        final sortedPlacesRaw =
            suitablePlaces.values.toList()
              ..sort(
                (first, second) {
                  // Prefer venues that Google explicitly confirms are open
                  // now. Unknown-hours places remain fallback candidates.
                  final openComparison =
                      (first.openNow == true ? 0 : 1)
                          .compareTo(
                    second.openNow == true ? 0 : 1,
                  );

                  if (openComparison != 0) {
                    return openComparison;
                  }

                  final distanceComparison =
                      first.distanceMeters.compareTo(
                    second.distanceMeters,
                  );

                  if (distanceComparison != 0) {
                    return distanceComparison;
                  }

                  final ratingComparison =
                      second.rating.compareTo(
                    first.rating,
                  );

                  if (ratingComparison != 0) {
                    return ratingComparison;
                  }

                  return second.userRatingCount.compareTo(
                    first.userRatingCount,
                  );
                },
              );

        // Same-list same-site dedup — see _dedupeSameSiteCandidates. Keeps
        // only the most-reviewed candidate per same-physical-site cluster
        // before this in-flight list is walked for reference-ready checkpoints.
        final sortedPlaces =
            await _dedupeSameSiteCandidates(sortedPlacesRaw);

        _debugPrint(
          'Qualified unique places before reference screening: '
          '${sortedPlaces.length}',
        );

        final selected =
            await _selectReferenceReadyPlaces(
          candidates: sortedPlaces,
          limit: limit,
          themeId: themeId,
          screeningCache: referenceScreeningCache,
          fastFirstCheckpoint: fastFirstCheckpoint,
          // CP1 first expands distance before spending requests on
          // photos 3-5. CP2/CP3 run in background and may complete the
          // normal 1-3 -> 4-5 fallback immediately.
          allowFallbackPhotos: !fastFirstCheckpoint,
          onProgress: onProgress,
        );

        _debugPrint(
          'Reference-ready places so far: '
          '${selected.length}',
        );

        if (selected.length >= limit) {
          final finalSelection = selected
              .take(limit)
              .toList(growable: false);

          _printSelectedCheckpoints(
            finalSelection,
          );

          return finalSelection;
        }
      }

      // CP1 fast mode has now exhausted 5 -> 25 km for THIS popularity
      // tier. Only now spend requests on photos 3-5 before popularity
      // is relaxed to the next tier.
      if (fastFirstCheckpoint &&
          suitablePlaces.isNotEmpty) {
        final sortedPlacesRaw =
            suitablePlaces.values.toList()
              ..sort(
                (first, second) {
                  // Prefer venues that Google explicitly confirms are open
                  // now. Unknown-hours places remain fallback candidates.
                  final openComparison =
                      (first.openNow == true ? 0 : 1)
                          .compareTo(
                    second.openNow == true ? 0 : 1,
                  );

                  if (openComparison != 0) {
                    return openComparison;
                  }

                  final distanceComparison =
                      first.distanceMeters.compareTo(
                    second.distanceMeters,
                  );

                  if (distanceComparison != 0) {
                    return distanceComparison;
                  }

                  final ratingComparison =
                      second.rating.compareTo(
                    first.rating,
                  );

                  if (ratingComparison != 0) {
                    return ratingComparison;
                  }

                  return second.userRatingCount.compareTo(
                    first.userRatingCount,
                  );
                },
              );

        final sortedPlaces =
            await _dedupeSameSiteCandidates(sortedPlacesRaw);

        _debugPrint(
          '[CP1 FALLBACK] '
          'No reference-ready checkpoint after expanding to '
          '${(searchRadii.last / 1000).toStringAsFixed(0)} km in '
          '${_hiddenPopularityTierLabel(popularityTier)}. '
          'Checking remaining photos 3-5 before relaxing popularity.',
        );

        final selected =
            await _selectReferenceReadyPlaces(
          candidates: sortedPlaces,
          limit: limit,
          themeId: themeId,
          screeningCache: referenceScreeningCache,
          fastFirstCheckpoint: true,
          allowFallbackPhotos: true,
          onProgress: onProgress,
        );

        if (selected.length >= limit) {
          final finalSelection = selected
              .take(limit)
              .toList(growable: false);

          _printSelectedCheckpoints(
            finalSelection,
          );

          return finalSelection;
        }
      }
    }

    // ==========================================================
    // EMERGENCY CANDIDATE DIVERSIFICATION
    //
    // Nearby Search returns at most a limited result set. If the broad
    // theme query was dominated by one subtype, two small type-group
    // queries at 25 km can surface different valid places.
    //
    // This runs only after the normal 5->25 km + Tier 1->3 strategy failed,
    // so it does not add requests during normal successful games. CP2/CP3
    // use it as a bounded rescue too; otherwise one crowded food block can
    // leave the saved quest with only CP1.
    // ==========================================================

    {
      // Missing CP2/CP3 need the same bounded type diversification as CP1.
      final fallbackTypeGroups =
          _getDiversifiedFallbackTypeGroups(
        themeId,
      );

      for (final typeGroup
          in fallbackTypeGroups) {
        if (typeGroup.isEmpty) {
          continue;
        }

        _debugPrint(
          '[DIVERSIFIED FALLBACK] '
          '25 km types=${typeGroup.join(', ')}',
        );

        final fallbackPlaces =
            await googleMapsPlatformService.searchNearbyPlaces(
          latitude: latitude,
          longitude: longitude,
          includedTypes: typeGroup,
          radiusMeters: searchRadii.last,
          maxResultCount: 20,
          rankPreference: 'POPULARITY',
        );

        for (final place in fallbackPlaces) {
          if (place.id.trim().isEmpty ||
              excludedPlaceIds.contains(place.id) ||
              place.businessStatus != 'OPERATIONAL' ||
              place.openNow == false ||
              place.photos.isEmpty) {
            continue;
          }

          final areaConflict = _checkpointAreaConflict(
            place: place,
            themeId: themeId,
            excludedAreas: excludedCheckpointAreas,
          );

          if (areaConflict != null) {
            _debugPrint(
              '[EXCLUDED SAME AREA - FALLBACK] ${place.name} -> $areaConflict',
            );
            continue;
          }

          if (!_isThemeRelevantPlace(
            place: place,
            themeId: themeId,
          )) {
            _debugPrint(
              '[THEME REJECT - FALLBACK] ${place.name} | '
              'theme=$themeId | primaryType=${place.primaryType}',
            );
            continue;
          }

          if (preferLessPopular) {
            if (_hiddenPopularityTier(place) == null) {
              continue;
            }
          } else {
            if (place.rating > 0 &&
                place.rating < minimumTripPathRating) {
              continue;
            }

            if (place.userRatingCount > 0 &&
                place.userRatingCount <
                    minimumTripPathReviewCount) {
              continue;
            }
          }

          final distance =
              locationService.calculateDistanceInMeters(
            startLatitude: latitude,
            startLongitude: longitude,
            endLatitude: place.latitude,
            endLongitude: place.longitude,
          );

          if (distance > searchRadii.last) {
            continue;
          }

          allEligiblePlaces.putIfAbsent(
            place.id,
            () => Attraction(
              id: place.id,
              name: place.name,
              address: place.address,
              latitude: place.latitude,
              longitude: place.longitude,
              rating: place.rating,
              userRatingCount: place.userRatingCount,
              primaryType: place.primaryType,
              types: List.unmodifiable(place.types),
              openNow: place.openNow,
              distanceMeters: distance,
              photoResourceName: null,
              googleMapsUri: place.googleMapsUri,
              photoCandidates:
                  List.unmodifiable(place.photos),
            ),
          );
        }
      }
    }

    // ==========================================================
    // FINAL SAFE RESCUE
    //
    // The fast path intentionally avoids scanning every photo up front.
    // If all radius + popularity tiers failed, exhaust the remaining
    // already-discovered candidates before reporting "not found".
    //
    // This does NOT relax:
    // - theme
    // - visited-place exclusion
    // - OPERATIONAL / open-now rules
    // - reference semantic gate
    // - OpenCV quality gate
    // ==========================================================

    if (allEligiblePlaces.isNotEmpty) {
      final sortedRescueCandidates =
          allEligiblePlaces.values.toList()
            ..sort(
              (first, second) {
                if (preferLessPopular) {
                  final firstTier =
                      _hiddenPopularityTierFromAttraction(first);
                  final secondTier =
                      _hiddenPopularityTierFromAttraction(second);

                  final tierComparison =
                      firstTier.compareTo(secondTier);

                  if (tierComparison != 0) {
                    return tierComparison;
                  }
                }

                final openComparison =
                    (first.openNow == true ? 0 : 1)
                        .compareTo(
                  second.openNow == true ? 0 : 1,
                );

                if (openComparison != 0) {
                  return openComparison;
                }

                return first.distanceMeters.compareTo(
                  second.distanceMeters,
                );
              },
            );

      final rescueCandidates =
          sortedRescueCandidates
              .take(finalRescueCandidateLimit)
              .toList(growable: false);

      _debugPrint('');
      _debugPrint(
        '[FINAL CHECKPOINT SAFE RESCUE] '
        'Checking up to $finalRescueCandidateLimit strongest remaining '
        'places before giving up.',
      );

      while (true) {
        final beforeProgress =
            referenceScreeningCache.values.fold<int>(
          0,
          (sum, state) =>
              sum +
              (state.firstPassDone ? 1 : 0) +
              (state.fullPassDone ? 1 : 0) +
              (state.accepted != null ? 1 : 0),
        );

        final selected =
            await _selectReferenceReadyPlaces(
          candidates: rescueCandidates,
          limit: limit,
          themeId: themeId,
          screeningCache: referenceScreeningCache,
          fastFirstCheckpoint: true,
          allowFallbackPhotos: true,
          onProgress: onProgress,
        );

        if (selected.length >= limit) {
          final finalSelection =
              selected.take(limit).toList(growable: false);

          _printSelectedCheckpoints(
            finalSelection,
          );

          return finalSelection;
        }

        final afterProgress =
            referenceScreeningCache.values.fold<int>(
          0,
          (sum, state) =>
              sum +
              (state.firstPassDone ? 1 : 0) +
              (state.fullPassDone ? 1 : 0) +
              (state.accepted != null ? 1 : 0),
        );

        if (afterProgress <= beforeProgress) {
          break;
        }
      }
    }

    throw AttractionRepositoryException(
      'No suitable open $themeId checkpoint with a reliable automatic '
      'reference photo was found after searching up to '
      '${(searchRadii.last / 1000).toStringAsFixed(0)} km and applying '
      'all hidden-place fallback tiers.',
    );
  }

  // ============================================================
  // CHECKPOINT AREA DEDUPLICATION
  //
  // Google can expose several Place IDs for entrances, lookout points,
  // trailheads or gates of the SAME real-world site. Place-ID dedup alone
  // therefore cannot prevent CP1/CP2/CP3 from all becoming one park.
  // ============================================================

  static const double minimumCheckpointSeparationMeters = 120.0;
  // Food checkpoints are often separate stalls or shops in one walkable
  // market block. Keeping the generic 120 m exclusion here made CP2/CP3
  // impossible in the supplied Food logs: every eligible place was 14-64 m
  // from CP1. Fifty metres still prevents duplicate entrances while allowing
  // genuinely separate food businesses to form a quest route.
  static const double foodCheckpointSeparationMeters = 50.0;
  static const double sameSiteNameComparisonRadiusMeters = 1500.0;

  String? _checkpointAreaConflict({
    required GooglePlaceData place,
    required String themeId,
    required List<QuestCheckpointAreaExclusion> excludedAreas,
  }) {
    final normalizedTheme = themeId.trim().toLowerCase();
    final minimumSeparation = normalizedTheme == 'food'
        ? foodCheckpointSeparationMeters
        : minimumCheckpointSeparationMeters;

    for (final existing in excludedAreas) {
      final distance = locationService.calculateDistanceInMeters(
        startLatitude: existing.latitude,
        startLongitude: existing.longitude,
        endLatitude: place.latitude,
        endLongitude: place.longitude,
      );

      if (distance < minimumSeparation) {
        return 'only ${distance.toStringAsFixed(0)} m from '
            '${existing.name} (< ${minimumSeparation.toStringAsFixed(0)} m)';
      }

      if (distance <= sameSiteNameComparisonRadiusMeters &&
          (_looksLikeSamePhysicalSite(place.name, existing.name) ||
              _siteNameAppearsInAddress(place.name, existing.address) ||
              _siteNameAppearsInAddress(existing.name, place.address))) {
        return 'appears to be the same physical site as '
            '${existing.name} (${distance.toStringAsFixed(0)} m away)';
      }
    }

    return null;
  }

  // ============================================================
  // SAME-LIST SAME-SITE DEDUP
  //
  // _checkpointAreaConflict above only compares a candidate against
  // checkpoints already LOCKED IN from earlier calls — it never runs
  // between two candidates inside the SAME in-flight sortedPlaces list.
  // Combined with that list being sorted distance-first (not by review
  // count), a low-review sub-entry of a landmark (an entrance, viewpoint,
  // or gate) can sort ahead of, and get accepted before, the landmark's own
  // higher-review entry is ever reached. This clusters same-list candidates
  // by the same name-similarity heuristic and keeps only the most-reviewed
  // one per cluster before ranking/reference-photo screening runs.
  // ============================================================

  Future<List<Attraction>> _dedupeSameSiteCandidates(
    List<Attraction> places,
  ) async {
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

    final gemini = geminiService;

    for (var i = 0; i < places.length; i++) {
      for (var j = i + 1; j < places.length; j++) {
        if (find(i) == find(j)) continue;

        final a = places[i];
        final b = places[j];
        final distance = locationService.calculateDistanceInMeters(
          startLatitude: a.latitude,
          startLongitude: a.longitude,
          endLatitude: b.latitude,
          endLongitude: b.longitude,
        );
        if (distance > sameSiteNameComparisonRadiusMeters) continue;

        if (_looksLikeSamePhysicalSite(a.name, b.name) ||
            _siteNameAppearsInAddress(a.name, b.address) ||
            _siteNameAppearsInAddress(b.name, a.address)) {
          union(i, j);
          continue;
        }

        if (gemini != null) {
          final jaccard = _siteNameJaccard(a.name, b.name);
          if (jaccard >= 0.35 && jaccard < 0.60) {
            final same = await gemini.areSameRealWorldSite(
              nameA: a.name,
              addressA: a.address,
              nameB: b.name,
              addressB: b.address,
            );
            if (same) union(i, j);
          }
        }
      }
    }

    final clusters = <int, List<int>>{};
    for (var i = 0; i < places.length; i++) {
      clusters.putIfAbsent(find(i), () => []).add(i);
    }

    final kept = clusters.values.map((indices) {
      indices.sort((x, y) {
        final byReviews = places[y]
            .userRatingCount
            .compareTo(places[x].userRatingCount);
        if (byReviews != 0) return byReviews;
        return places[y].rating.compareTo(places[x].rating);
      });
      return indices.first;
    }).toList()
      ..sort();

    return kept.map((index) => places[index]).toList(growable: false);
  }

  bool _looksLikeSamePhysicalSite(String firstName, String secondName) {
    final first = _siteTokens(firstName);
    final second = _siteTokens(secondName);

    if (first.isEmpty || second.isEmpty) {
      return false;
    }

    final firstPhrase = first.join(' ');
    final secondPhrase = second.join(' ');

    // Covers examples such as:
    // "KL East Park" vs "Look out point (KL East Park)".
    if (firstPhrase.length >= 6 &&
        secondPhrase.length >= 6 &&
        (firstPhrase.contains(secondPhrase) ||
            secondPhrase.contains(firstPhrase))) {
      return true;
    }

    // A high token overlap within the same local area usually indicates
    // another entrance/gate/viewpoint of the same parent venue.
    return _siteNameJaccard(firstName, secondName) >= 0.60;
  }

  /// Raw token-overlap score behind [_looksLikeSamePhysicalSite]'s 0.60
  /// auto-merge threshold — exposed separately so
  /// [_dedupeSameSiteCandidates] can identify the "similar but not
  /// confident" band and ask Gemini only about those pairs.
  double _siteNameJaccard(String firstName, String secondName) {
    final firstSet = _siteTokens(firstName).toSet();
    final secondSet = _siteTokens(secondName).toSet();
    if (firstSet.isEmpty || secondSet.isEmpty) return 0.0;

    final common = firstSet.intersection(secondSet).length;
    final union = firstSet.union(secondSet).length;
    if (common < 2 || union == 0) return 0.0;

    return common / union;
  }

  bool _siteNameAppearsInAddress(String siteName, String address) {
    final tokens = _siteTokens(siteName);

    if (tokens.length < 2) {
      return false;
    }

    final phrase = tokens.join(' ');
    final normalizedAddress = address
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    return phrase.length >= 6 && normalizedAddress.contains(phrase);
  }

  List<String> _siteTokens(String value) {
    const generic = <String>{
      'the', 'a', 'an', 'at', 'of', 'and',
      'entrance', 'entry', 'exit', 'gate', 'main',
      'lookout', 'look', 'out', 'viewpoint', 'point',
      'trail', 'trailhead', 'parking', 'carpark', 'car',
      'junction', 'intersection', 'access',
      'restaurant', 'restoran', 'cafe', 'coffee', 'shop', 'store',
    };

    return value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .split(' ')
        .map((token) => token.trim())
        .where((token) =>
            token.length >= 2 &&
            !generic.contains(token))
        .toList(growable: false);
  }

  // ============================================================
  // HIDDEN-PLACE POPULARITY FILTER
  //
  // Rating/review data is used only for checkpoint selection. It is never
  // passed into Gemini clue facts.
  // ============================================================

  int? _hiddenPopularityTier(
    GooglePlaceData place,
  ) {
    final hasRating = place.rating > 0;
    final hasReviews = place.userRatingCount > 0;

    // Tier 3: Google has no popularity data at all. This can still be a
    // genuine small stall / local place, but the strict reference-photo
    // semantic + OpenCV gate remains mandatory.
    if (!hasRating && !hasReviews) {
      return 3;
    }

    // Incomplete popularity pairs are unreliable.
    if (!hasRating || !hasReviews) {
      _debugPrint(
        '[HIDDEN REJECT] ${place.name} | '
        'incomplete rating/review data.',
      );
      return null;
    }

    // Low-rated places are never recommended merely to fill a quest.
    if (place.rating < minimumHiddenPlaceRating) {
      _debugPrint(
        '[HIDDEN REJECT] ${place.name} | '
        'rating ${place.rating.toStringAsFixed(1)} < '
        '$minimumHiddenPlaceRating.',
      );
      return null;
    }

    // Tier 1: preferred hidden-place balance.
    if (place.userRatingCount >=
            minimumHiddenPlaceReviewCount &&
        place.userRatingCount <=
            maximumHiddenPlaceReviewCount) {
      return 1;
    }

    // The maximum is never relaxed at any tier — a checkpoint must never be
    // an over-reviewed, heavily touristed landmark (e.g. Merdeka Square),
    // no matter how far the search radius/tier has to widen to find
    // something else instead.
    if (place.userRatingCount > maximumHiddenPlaceReviewCount) {
      _debugPrint(
        '[HIDDEN REJECT] ${place.name} | '
        'reviews ${place.userRatingCount} > '
        '$maximumHiddenPlaceReviewCount.',
      );
      return null;
    }

    // Tier 2: rating remains >= 4.0, but the review-count minimum is
    // relaxed — a small place with 1-9 reviews. Only attempted AFTER
    // Tier 1 has expanded all the way to the radius ceiling.
    return 2;
  }

  String _hiddenPopularityTierLabel(
    int tier,
  ) {
    switch (tier) {
      case 1:
        return 'TIER 1 (rating >= 4.0, reviews 10-1000)';
      case 2:
        return 'TIER 2 (rating >= 4.0, reviews 1-9)';
      case 3:
        return 'TIER 3 (no rating/review data)';
      default:
        return 'STANDARD';
    }
  }

  int _hiddenPopularityTierFromAttraction(
    Attraction attraction,
  ) {
    final hasRating = attraction.rating > 0;
    final hasReviews = attraction.userRatingCount > 0;

    if (!hasRating && !hasReviews) {
      return 3;
    }

    if (hasRating &&
        hasReviews &&
        attraction.rating >= minimumHiddenPlaceRating &&
        attraction.userRatingCount >= minimumHiddenPlaceReviewCount &&
        attraction.userRatingCount <= maximumHiddenPlaceReviewCount) {
      return 1;
    }

    // Callers only ever pass an already-eligible Attraction here (see
    // _hiddenPopularityTier, which rejects anything over the maximum before
    // it can reach allEligiblePlaces), so reaching this point never means
    // "over-reviewed" — just Tier 2/3.
    return 2;
  }

  Future<List<Attraction>> _selectReferenceReadyPlaces({
    required List<Attraction> candidates,
    required int limit,
    required String themeId,
    required Map<String, _ReferenceScreeningState> screeningCache,
    required bool fastFirstCheckpoint,
    required bool allowFallbackPhotos,
    void Function(String message)? onProgress,
  }) async {
    List<Attraction> collectAccepted() {
      final accepted = <Attraction>[];

      for (final candidate in candidates) {
        final value =
            screeningCache[candidate.id]?.accepted;

        if (value != null) {
          accepted.add(value);
        }

        if (accepted.length >= limit) {
          break;
        }
      }

      return accepted;
    }

    if (collectAccepted().length >= limit) {
      return collectAccepted();
    }

    final initialPhotoCount =
        fastFirstCheckpoint
            ? fastCheckpointInitialPhotoCount
            : 3;

    final firstPassBudget =
        fastFirstCheckpoint
            ? fastCheckpointCandidateWindow
            : candidates.length;

    // ==========================================================
    // INITIAL PASS
    //
    // CP1:
    //   top unscreened 5 places, photos 1-2 only.
    //
    // CP2/CP3:
    //   photos 1-3 in background.
    // ==========================================================

    final firstPassCandidates =
        candidates
            .where(
              (candidate) {
                final state =
                    screeningCache[candidate.id];

                return state?.accepted == null &&
                    !(state?.firstPassDone ?? false);
              },
            )
            .take(firstPassBudget)
            .toList(growable: false);

    for (final candidate
        in firstPassCandidates) {
      final state = screeningCache.putIfAbsent(
        candidate.id,
        _ReferenceScreeningState.new,
      );

      if (candidate.photoCandidates.isEmpty) {
        state.firstPassDone = true;
        state.fullPassDone = true;
        continue;
      }

      final firstBatch =
          candidate.photoCandidates
              .take(initialPhotoCount)
              .toList(growable: false);

      _debugPrint(
        fastFirstCheckpoint
            ? '[CP1 FAST REFERENCE] ${candidate.name} -> '
                'checking ${firstBatch.length} photo(s) first.'
            : '[REFERENCE FAST PASS] ${candidate.name} -> '
                'checking first ${firstBatch.length} photo(s).',
      );

      final selection =
          await referencePhotoService.selectBest(
        placeName: candidate.name,
        themeId: themeId,
        candidates: firstBatch,
        onProgress: onProgress,
      );

      state.firstPassDone = true;

      if (selection != null) {
        state.accepted =
            candidate.withReferencePhoto(selection);
        state.fullPassDone = true;
      } else if (candidate.photoCandidates.length <=
          initialPhotoCount) {
        state.fullPassDone = true;
      }

      if (collectAccepted().length >= limit) {
        return collectAccepted();
      }
    }

    var selected = collectAccepted();

    if (selected.length >= limit ||
        !allowFallbackPhotos) {
      return selected;
    }

    // ==========================================================
    // FALLBACK PHOTO PASS
    //
    // CP1 only reaches this after its current popularity tier has
    // already expanded through 25 km.
    //
    // CP2/CP3 use this in the background immediately after photos 1-3
    // are insufficient.
    // ==========================================================

    final fallbackBudget =
        fastFirstCheckpoint
            ? fastCheckpointCandidateWindow
            : candidates.length;

    final fallbackCandidates =
        candidates
            .where(
              (candidate) {
                final state =
                    screeningCache[candidate.id];

                return state != null &&
                    state.accepted == null &&
                    state.firstPassDone &&
                    !state.fullPassDone;
              },
            )
            .take(fallbackBudget)
            .toList(growable: false);

    if (fallbackCandidates.isNotEmpty) {
      _debugPrint(
        fastFirstCheckpoint
            ? '[CP1 REFERENCE FALLBACK] '
                'Checking remaining photos 3-5 for the strongest '
                'already-screened candidates.'
            : '[REFERENCE FALLBACK PASS] '
                '${selected.length}/$limit ready after photos 1-3. '
                'Checking photos 4-5 only where necessary.',
      );
    }

    for (final candidate
        in fallbackCandidates) {
      final state =
          screeningCache[candidate.id]!;

      final fallbackBatch =
          candidate.photoCandidates
              .skip(initialPhotoCount)
              .take(
                TripPathReferencePhotoService.maximumCandidates -
                    initialPhotoCount,
              )
              .toList(growable: false);

      if (fallbackBatch.isEmpty) {
        state.fullPassDone = true;
        continue;
      }

      _debugPrint(
        '[REFERENCE FALLBACK] ${candidate.name} -> '
        'checking remaining ${fallbackBatch.length} photo(s).',
      );

      final selection =
          await referencePhotoService.selectBest(
        placeName: candidate.name,
        themeId: themeId,
        candidates: fallbackBatch,
        onProgress: onProgress,
      );

      state.fullPassDone = true;

      if (selection != null) {
        state.accepted =
            candidate.withReferencePhoto(selection);
      } else {
        _debugPrint(
          '[REFERENCE REJECT] ${candidate.name} -> '
          'no photo passed the complete reference screening.',
        );
      }

      selected = collectAccepted();

      if (selected.length >= limit) {
        return selected;
      }
    }

    return collectAccepted();
  }

  // ============================================================
  // TERMINAL OUTPUT
  // ============================================================

  void _printSelectedCheckpoints(
    List<Attraction> attractions, {
    String label = 'FINAL CHECKPOINTS',
  }) {
    _debugPrint('');
    _debugPrint(
      '========== $label ==========',
    );

    for (var index = 0; index < attractions.length; index++) {
      final attraction = attractions[index];

      _debugPrint(
        'Checkpoint ${index + 1}: ${attraction.name}',
      );

      _debugPrint(
        '  GPS: '
        '${attraction.latitude.toStringAsFixed(7)}, '
        '${attraction.longitude.toStringAsFixed(7)}',
      );

      _debugPrint(
        '  Distance: '
        '${attraction.distanceMeters.toStringAsFixed(1)} m',
      );

      _debugPrint(
        '  Rating: '
        '${attraction.rating.toStringAsFixed(1)} '
        '(${attraction.userRatingCount} reviews)',
      );

      _debugPrint(
        '  Type: ${attraction.primaryType}',
      );

      _debugPrint(
        '  Place ID: ${attraction.id}',
      );
    }

    _debugPrint(
      '==========================================',
    );
  }

  void _debugHeader({
    required String title,
  }) {
    if (!kDebugMode) {
      return;
    }

    debugPrint('');
    debugPrint(
      '==========================================',
    );
    debugPrint(
      '========== $title ==========',
    );
    debugPrint(
      '==========================================',
    );
  }

  void _debugPrint(
    String message,
  ) {
    if (kDebugMode) {
      debugPrint(message);
    }
  }

  // ============================================================
  // QUEST THEME RELEVANCE
  //
  // This is deliberately separate from popularity and reference-photo
  // quality. A high-rated, photo-rich venue is still rejected when it is
  // semantically the wrong kind of place for the selected theme.
  // ============================================================

  bool _isThemeRelevantPlace({
    required GooglePlaceData place,
    required String themeId,
  }) {
    final normalizedTheme = themeId.trim().toLowerCase();
    final normalizedName = place.name.trim().toLowerCase();
    final normalizedPrimary = place.primaryType.trim().toLowerCase();
    final normalizedTypes = place.types
        .map((value) => value.trim().toLowerCase())
        .where((value) => value.isNotEmpty)
        .toSet();

    bool hasAnyType(Set<String> accepted) {
      return accepted.contains(normalizedPrimary) ||
          normalizedTypes.any(accepted.contains);
    }

    bool nameContainsAny(Set<String> terms) {
      return terms.any(
        (term) => _containsThemePhrase(
          normalizedName,
          term,
        ),
      );
    }

    // Keep one canonical type vocabulary for all themes. Nearby Search may
    // attach several secondary types to the same result, so every theme
    // needs to distinguish its primary identity from a secondary amenity.
    const foodPlaceTypes = <String>{
      'restaurant',
      'cafe',
      'coffee_shop',
      'bakery',
      'food_court',
    };
    const culturePlaceTypes = <String>{
      'cultural_landmark',
      'cultural_center',
      'art_gallery',
      'art_museum',
      'museum',
      'performing_arts_theater',
    };
    const heritagePlaceTypes = <String>{
      'historical_place',
      'historical_landmark',
      'monument',
      'history_museum',
    };
    const naturePlaceTypes = <String>{
      'park',
      'city_park',
      'garden',
      'botanical_garden',
      'hiking_area',
      'national_park',
      'state_park',
      'wildlife_park',
    };
    // A golf course, stadium, gym, supermarket or similar recreation/retail
    // venue almost always has an on-site restaurant/cafe/bakery as a
    // secondary Google type (a clubhouse snack bar, an in-store bakery
    // counter), but that amenity is not what makes the venue worth
    // visiting — the venue itself is not food-themed. None of these primary
    // types belong to Culture/Heritage/Nature's own vocabulary either, so
    // primaryIsAnotherTheme below would otherwise miss them entirely and let
    // a golf course or supermarket pass as a Food checkpoint.
    const recreationVenueTypes = <String>{
      'golf_course',
      'stadium',
      'gym',
      'fitness_center',
      'sports_club',
      'sports_complex',
      'bowling_alley',
      'amusement_park',
      'movie_theater',
      'night_club',
      'casino',
      'swimming_pool',
      'ice_skating_rink',
      'ski_resort',
      'arena',
      'country_club',
    };
    const retailVenueTypes = <String>{
      'supermarket',
      'grocery_store',
      'convenience_store',
      'department_store',
      'discount_store',
      'wholesaler',
      'warehouse_store',
      'shopping_mall',
      'gas_station',
      'pharmacy',
      'drugstore',
      'hardware_store',
      'home_goods_store',
      'furniture_store',
      'electronics_store',
      'clothing_store',
    };
    const accommodationTypes = <String>{
      'bed_and_breakfast',
      'campground',
      'camping_cabin',
      'cottage',
      'extended_stay_hotel',
      'farmstay',
      'guest_house',
      'hostel',
      'hotel',
      'inn',
      'japanese_inn',
      'lodging',
      'motel',
      'private_guest_room',
      'resort_hotel',
      'rv_park',
      'serviced_apartment',
      // Some Places responses use the short identity instead of the
      // documented *_hotel / lodging variants. Keep these out of every
      // landmark theme as well.
      'resort',
      'lodge',
    };

    bool primaryLooksLikeAccommodation() {
      return normalizedPrimary.contains('hotel') ||
          normalizedPrimary.contains('lodging') ||
          normalizedPrimary.contains('hostel') ||
          normalizedPrimary.contains('motel') ||
          normalizedPrimary.contains('resort') ||
          normalizedPrimary.contains('lodge') ||
          accommodationTypes.contains(normalizedPrimary);
    }

    bool hasAccommodationType() {
      return primaryLooksLikeAccommodation() ||
          normalizedTypes.any(
            (type) => accommodationTypes.contains(type) ||
                type.contains('hotel') ||
                type.contains('lodging') ||
                type.contains('hostel') ||
                type.contains('motel') ||
                type.contains('resort') ||
                type.contains('lodge'),
          );
    }

    bool secondaryContainsAny(Set<String> accepted) {
      return normalizedTypes.any(accepted.contains);
    }

    // Food already checks this as a final name-based backstop below, since
    // Google's *type* data for a lodging venue is not always reliable (a
    // "lifestyle"/boutique hotel with an in-lobby gallery or art
    // installation — Hotel Indigo's whole brand concept — can pick up a
    // culture-adjacent secondary type like art_gallery without ever getting
    // an explicit hotel/lodging type). Culture/Heritage/Nature previously
    // had no equivalent, so that exact kind of hotel could pass a
    // type-only check as long as its name was never examined. Applied
    // eagerly (same position as hasAccommodationType()) so it always
    // rejects regardless of which type-based sub-path would otherwise
    // accept the place.
    bool nameLooksLikeAccommodation() {
      return nameContainsAny(const <String>{
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
      });
    }

    switch (normalizedTheme) {
      case 'food':
        // Food must actually be a food/drink venue. Google can attach a
        // secondary restaurant/cafe type to a hotel (for example Hotel
        // Indigo), so an accepted food type alone is not enough. Reject
        // accommodation identities before checking the food types.
        final accommodationTypeMatch = hasAccommodationType();

        if (accommodationTypeMatch) {
          return false;
        }

        final foodTypeMatch = hasAnyType(foodPlaceTypes);

        final primaryIsFood =
            foodPlaceTypes.contains(normalizedPrimary);
        final primaryIsAnotherTheme =
            culturePlaceTypes.contains(normalizedPrimary) ||
            heritagePlaceTypes.contains(normalizedPrimary) ||
            naturePlaceTypes.contains(normalizedPrimary);
        final secondaryIsAnotherTheme =
            secondaryContainsAny(culturePlaceTypes) ||
            secondaryContainsAny(heritagePlaceTypes) ||
            secondaryContainsAny(naturePlaceTypes);
        final primaryIsRecreationVenue =
            recreationVenueTypes.contains(normalizedPrimary);
        final primaryIsRetailVenue =
            retailVenueTypes.contains(normalizedPrimary);

        // A cultural centre/park/monument that merely contains a cafe is not
        // a Food checkpoint. A true restaurant may still have a cultural or
        // park amenity as a secondary type because its primary identity is
        // explicitly food. Same reasoning for a golf course/stadium/gym
        // whose clubhouse or snack bar picked up a restaurant/cafe type, or
        // a supermarket whose in-store bakery counter picked up a bakery
        // type — the venue's own primary identity is recreation/retail, not
        // food.
        if (!foodTypeMatch ||
            primaryIsAnotherTheme ||
            primaryIsRecreationVenue ||
            primaryIsRetailVenue ||
            (!primaryIsFood && secondaryIsAnotherTheme)) {
          return false;
        }

        // Keep obvious accommodation names out even when Places omits the
        // lodging type. This is deliberately word-boundary based so a term
        // such as "inn" cannot match an unrelated word inside a name.
        return !nameContainsAny(const <String>{
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
        });

      case 'culture':
        final primaryIsFood =
            foodPlaceTypes.contains(normalizedPrimary);
        final primaryIsNature =
            naturePlaceTypes.contains(normalizedPrimary);

        if (primaryIsFood ||
            hasAccommodationType() ||
            nameLooksLikeAccommodation() ||
            primaryIsNature) {
          return false;
        }

        // Strong culture-specific Google types can pass directly.
        if (hasAnyType(culturePlaceTypes)) {
          // When Culture is only a secondary type, do not let a food or
          // lodging result become a cultural checkpoint. A primary cultural
          // venue is allowed to have a cafe/restaurant amenity.
          if (!culturePlaceTypes.contains(normalizedPrimary) &&
              (secondaryContainsAny(foodPlaceTypes) ||
                  secondaryContainsAny(accommodationTypes))) {
            return false;
          }

          // A result whose real identity is merely a neighbourhood/admin
          // community hall should not become a Culture checkpoint just
          // because Places attached a broad cultural/community type.
          final looksLikeGenericCommunityHall =
              normalizedPrimary == 'community_center' ||
              normalizedTypes.contains('community_center');

          if (!looksLikeGenericCommunityHall) {
            return true;
          }

          return nameContainsAny(const <String>{
            'culture',
            'cultural',
            'budaya',
            'art',
            'arts',
            'seni',
            'gallery',
            'galeri',
            'museum',
            'muzium',
            'theatre',
            'theater',
            'teater',
            'performing',
            'heritage',
            'warisan',
            'traditional',
            'tradition',
            'craft',
            'kraf',
            'handicraft',
            'batik',
          });
        }

        // community_center is intentionally NOT a general Culture type.
        // If Google still returns one as a secondary match, only a clearly
        // culture-oriented name can rescue it.
        if (hasAnyType(const <String>{'community_center'})) {
          if (nameContainsAny(const <String>{
            'krt',
            'rukun tetangga',
            'residents association',
            'resident association',
            'persatuan penduduk',
            'dewan masyarakat',
            'dewan orang ramai',
            'balai raya',
            'community hall',
            'neighbourhood centre',
            'neighborhood center',
            'pusat komuniti',
            'pusat khidmat',
          })) {
            return false;
          }

          return nameContainsAny(const <String>{
            'culture',
            'cultural',
            'budaya',
            'art',
            'arts',
            'seni',
            'gallery',
            'galeri',
            'museum',
            'muzium',
            'theatre',
            'theater',
            'teater',
            'heritage',
            'warisan',
            'traditional',
            'craft',
            'kraf',
            'handicraft',
          });
        }

        return false;

      case 'heritage':
        if (foodPlaceTypes.contains(normalizedPrimary) ||
            hasAccommodationType() ||
            nameLooksLikeAccommodation() ||
            naturePlaceTypes.contains(normalizedPrimary)) {
          return false;
        }

        // Strongly historical types always fit Heritage.
        if (hasAnyType(heritagePlaceTypes)) {
          if (!heritagePlaceTypes.contains(normalizedPrimary) &&
              (secondaryContainsAny(foodPlaceTypes) ||
                  secondaryContainsAny(accommodationTypes))) {
            return false;
          }

          return true;
        }

        // Generic cultural landmarks/museums are allowed only when their
        // name provides a heritage/history signal. This avoids pulling a
        // modern art/science venue into Heritage merely because it is a
        // museum.
        if (hasAnyType(const <String>{
          'cultural_landmark',
          'museum',
        })) {
          return nameContainsAny(const <String>{
            'heritage',
            'warisan',
            'history',
            'sejarah',
            'historical',
            'historic',
            'memorial',
            'monument',
            'national museum',
            'royal museum',
            'war museum',
            'memorial museum',
            'muzium',
            'old',
            'old town',
            'lama',
            'fort',
            'fortress',
            'kota',
            'palace',
            'istana',
            'castle',
            'colonial',
            'traditional',
            'temple',
            'shrine',
            'mosque',
            'church',
          });
        }

        return false;

      case 'nature':
        if (foodPlaceTypes.contains(normalizedPrimary) ||
            culturePlaceTypes.contains(normalizedPrimary) ||
            heritagePlaceTypes.contains(normalizedPrimary) ||
            hasAccommodationType() ||
            nameLooksLikeAccommodation()) {
          return false;
        }

        // Nature uses outdoor/natural-place Google types only. This keeps
        // generic indoor attractions and unrelated businesses out.
        if (!hasAnyType(naturePlaceTypes)) {
          return false;
        }

        // A park/garden attached only as a secondary amenity does not turn a
        // restaurant, museum or hotel into a Nature checkpoint.
        return naturePlaceTypes.contains(normalizedPrimary) ||
            (!secondaryContainsAny(foodPlaceTypes) &&
                !secondaryContainsAny(culturePlaceTypes) &&
                !secondaryContainsAny(heritagePlaceTypes) &&
                !secondaryContainsAny(accommodationTypes));

      default:
        return false;
    }
  }

  bool _containsThemePhrase(
    String source,
    String phrase,
  ) {
    final normalizedPhrase = phrase
        .trim()
        .toLowerCase()
        .replaceAll(
          RegExp(r'[^a-z0-9]+'),
          ' ',
        )
        .trim();

    if (source.isEmpty || normalizedPhrase.isEmpty) {
      return false;
    }

    // Word/phrase boundary matching prevents short terms such as "art"
    // from accidentally matching unrelated names such as "party".
    final normalizedSource = source
        .toLowerCase()
        .replaceAll(
          RegExp(r'[^a-z0-9]+'),
          ' ',
        )
        .trim();

    return ' $normalizedSource '.contains(
      ' $normalizedPhrase ',
    );
  }

  // ============================================================
  // GOOGLE PLACE TYPES BASED ON QUEST THEME
  // ============================================================

  List<List<String>> _getDiversifiedFallbackTypeGroups(
    String themeId,
  ) {
    switch (themeId) {
      case 'food':
        return const [
          <String>[
            'restaurant',
            'cafe',
            'bakery',
          ],
          <String>[
            'coffee_shop',
            'food_court',
          ],
        ];

      case 'culture':
        return const [
          <String>[
            'cultural_landmark',
            'cultural_center',
            'museum',
          ],
          <String>[
            'art_gallery',
            'art_museum',
            'performing_arts_theater',
          ],
        ];

      case 'heritage':
        return const [
          <String>[
            'historical_place',
            'historical_landmark',
            'monument',
          ],
          <String>[
            'cultural_landmark',
            'history_museum',
            'museum',
          ],
        ];

      case 'nature':
        return const [
          <String>[
            'park',
            'city_park',
            'garden',
            'botanical_garden',
          ],
          <String>[
            'hiking_area',
            'national_park',
            'state_park',
            'wildlife_park',
          ],
        ];

      default:
        return const <List<String>>[];
    }
  }

  List<String> _getGooglePlaceTypes(
    String themeId,
  ) {
    switch (themeId) {
      case 'food':
        return const [
          'restaurant',
          'cafe',
          'coffee_shop',
          'bakery',
          'food_court',
        ];

      case 'culture':
        return const [
          'cultural_landmark',
          'cultural_center',
          'art_gallery',
          'art_museum',
          'museum',
          'performing_arts_theater',
        ];

      case 'heritage':
        return const [
          'historical_place',
          'historical_landmark',
          'cultural_landmark',
          'monument',
          'history_museum',
          'museum',
        ];

      case 'nature':
        return const [
          'park',
          'city_park',
          'garden',
          'botanical_garden',
          'hiking_area',
          'national_park',
          'state_park',
          'wildlife_park',
        ];

      default:
        return const [];
    }
  }
}
