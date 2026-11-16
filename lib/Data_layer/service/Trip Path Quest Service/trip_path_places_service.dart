import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class GooglePlacePhotoData {
  final String name;
  final int widthPx;
  final int heightPx;

  const GooglePlacePhotoData({
    required this.name,
    required this.widthPx,
    required this.heightPx,
  });
}

class GooglePlaceData {
  final String id;
  final String name;
  final String address;
  final double latitude;
  final double longitude;
  final double rating;
  final int userRatingCount;
  final String primaryType;
  final List<String> types;
  final String businessStatus;
  final bool? openNow;
  final List<GooglePlacePhotoData> photos;
  final String? googleMapsUri;

  /// 2-letter ISO country code (e.g. "MY") Google's addressComponents
  /// attributes this place to, or null when Google didn't return that
  /// component for this result.
  final String? countryCode;

  const GooglePlaceData({
    required this.id,
    required this.name,
    required this.address,
    required this.latitude,
    required this.longitude,
    required this.rating,
    required this.userRatingCount,
    required this.primaryType,
    required this.types,
    required this.businessStatus,
    required this.openNow,
    required this.photos,
    this.googleMapsUri,
    this.countryCode,
  });

  String? get photoResourceName {
    if (photos.isEmpty) {
      return null;
    }

    return photos.first.name;
  }
}


class GooglePlaceCheckpointData {
  final String businessStatus;
  final bool? openNow;
  final List<GooglePlacePhotoData> photos;

  const GooglePlaceCheckpointData({
    required this.businessStatus,
    required this.openNow,
    required this.photos,
  });

  bool get isExplicitlyClosedNow =>
      openNow == false;

  bool get isOperational =>
      businessStatus == 'OPERATIONAL';
}

class GoogleMapsPlatformException implements Exception {
  final String message;

  const GoogleMapsPlatformException(
    this.message,
  );

  @override
  String toString() {
    return message;
  }
}

class GoogleMapsPlatformService {
  final String apiKey;
  final http.Client _client;

  GoogleMapsPlatformService({
    required this.apiKey,
    http.Client? client,
  }) : _client = client ?? http.Client();

  static const String _nearbySearchUrl =
      'https://places.googleapis.com/v1/places:searchNearby';

  Future<List<GooglePlaceData>> searchNearbyPlaces({
    required double latitude,
    required double longitude,
    required List<String> includedTypes,
    double radiusMeters = 5000,
    int maxResultCount = 20,
    String rankPreference = 'DISTANCE',
  }) async {
    if (apiKey.trim().isEmpty) {
      throw const GoogleMapsPlatformException(
        'Google Places API key is missing.',
      );
    }

    if (includedTypes.isEmpty) {
      throw const GoogleMapsPlatformException(
        'At least one Google Places type is required.',
      );
    }

    if (radiusMeters <= 0 ||
        radiusMeters > 50000) {
      throw const GoogleMapsPlatformException(
        'Invalid nearby search radius.',
      );
    }

    if (rankPreference != 'DISTANCE' && rankPreference != 'POPULARITY') {
      throw const GoogleMapsPlatformException('Invalid nearby search ranking.');
    }
    final body = {
      'includedTypes': includedTypes,
      'maxResultCount': maxResultCount,
      'rankPreference': rankPreference,
      'locationRestriction': {
        'circle': {
          'center': {
            'latitude': latitude,
            'longitude': longitude,
          },
          'radius': radiusMeters,
        },
      },
      'languageCode': 'en',
      'regionCode': 'MY',
    };

    final response = await _client
        .post(
          Uri.parse(_nearbySearchUrl),
          headers: {
            'Content-Type': 'application/json',
            'X-Goog-Api-Key': apiKey,
            'X-Goog-FieldMask': [
              'places.id',
              'places.displayName',
              'places.formattedAddress',
              'places.location',
              'places.rating',
              'places.userRatingCount',
              'places.primaryType',
              'places.types',
              'places.businessStatus',
              'places.currentOpeningHours',
              'places.photos',
              'places.googleMapsUri',
              'places.addressComponents',
            ].join(','),
          },
          body: jsonEncode(body),
        )
        .timeout(
          const Duration(
            seconds: 12,
          ),
        );

    if (response.statusCode < 200 ||
        response.statusCode >= 300) {
      throw GoogleMapsPlatformException(
        'Google Places request failed '
        '(${response.statusCode}): '
        '${response.body}',
      );
    }

    final decoded = jsonDecode(response.body);

    if (decoded is! Map<String, dynamic>) {
      throw const GoogleMapsPlatformException(
        'Invalid response from Google Places.',
      );
    }

    final rawPlaces = decoded['places'];

    if (rawPlaces == null) {
      return [];
    }

    if (rawPlaces is! List) {
      throw const GoogleMapsPlatformException(
        'Invalid places data returned by Google.',
      );
    }

    final places = <GooglePlaceData>[];

    for (final item in rawPlaces) {
      if (item is! Map<String, dynamic>) {
        continue;
      }

      final location = item['location'];

      if (location is! Map<String, dynamic>) {
        continue;
      }

      final latitudeValue = location['latitude'];
      final longitudeValue = location['longitude'];

      if (latitudeValue is! num ||
          longitudeValue is! num) {
        continue;
      }

      String displayName = '';
      final displayNameObject = item['displayName'];

      if (displayNameObject is Map<String, dynamic>) {
        displayName =
            displayNameObject['text']?.toString() ?? '';
      }

      if (displayName.trim().isEmpty) {
        continue;
      }

      final photoCandidates = <GooglePlacePhotoData>[];
      final rawPhotos = item['photos'];

      if (rawPhotos is List) {
        for (final rawPhoto in rawPhotos.take(10)) {
          if (rawPhoto is! Map<String, dynamic>) {
            continue;
          }

          final photoName =
              rawPhoto['name']?.toString().trim() ?? '';

          if (photoName.isEmpty) {
            continue;
          }

          photoCandidates.add(
            GooglePlacePhotoData(
              name: photoName,
              widthPx:
                  (rawPhoto['widthPx'] as num?)?.toInt() ?? 0,
              heightPx:
                  (rawPhoto['heightPx'] as num?)?.toInt() ?? 0,
            ),
          );
        }
      }

      final currentOpeningHours =
          item['currentOpeningHours'];

      final bool? openNow =
          currentOpeningHours is Map<String, dynamic>
              ? currentOpeningHours['openNow'] as bool?
              : null;

      final rawTypes = item['types'];
      final types = rawTypes is List
          ? rawTypes
              .map(
                (value) => value.toString(),
              )
              .toList()
          : <String>[];

      places.add(
        GooglePlaceData(
          id: item['id']?.toString() ?? '',
          name: displayName,
          address:
              item['formattedAddress']?.toString() ?? '',
          latitude: latitudeValue.toDouble(),
          longitude: longitudeValue.toDouble(),
          rating:
              (item['rating'] as num?)?.toDouble() ?? 0,
          userRatingCount:
              (item['userRatingCount'] as num?)?.toInt() ?? 0,
          primaryType:
              item['primaryType']?.toString() ?? '',
          types: types,
          businessStatus:
              item['businessStatus']?.toString() ?? '',
          openNow: openNow,
          photos: List.unmodifiable(
            photoCandidates,
          ),
          googleMapsUri:
              item['googleMapsUri']?.toString(),
          countryCode: _countryCodeFrom(item['addressComponents']),
        ),
      );
    }

    return places;
  }

  /// Extracts the 2-letter ISO country code from a Places API (New)
  /// `addressComponents` list, or null when it's missing / has no country
  /// component.
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


  // ============================================================
  // PLACE PHOTO CANDIDATES FOR A SAVED CHECKPOINT
  //
  // Used only when an unfinished quest is resumed. The saved quest
  // stores the Google Place ID, not expiring photo resource names.
  // This request gets a fresh photos[] list for that SAME landmark,
  // then the existing automatic reference-photo screening downloads
  // candidates one by one and early-stops when a strong image is found.
  // ============================================================

  Future<GooglePlaceCheckpointData> getPlaceCheckpointData({
    required String placeId,
  }) async {
    final normalizedPlaceId = placeId.trim();

    if (apiKey.trim().isEmpty) {
      throw const GoogleMapsPlatformException(
        'Google Places API key is missing.',
      );
    }

    if (normalizedPlaceId.isEmpty) {
      throw const GoogleMapsPlatformException(
        'Google Place ID is missing.',
      );
    }

    final uri = Uri.https(
      'places.googleapis.com',
      '/v1/places/${Uri.encodeComponent(normalizedPlaceId)}',
      {
        'languageCode': 'en',
        'regionCode': 'MY',
      },
    );

    final response = await _client
        .get(
          uri,
          headers: {
            'X-Goog-Api-Key': apiKey,
            'X-Goog-FieldMask': [
              'businessStatus',
              'currentOpeningHours',
              'photos',
            ].join(','),
          },
        )
        .timeout(
          const Duration(
            seconds: 15,
          ),
        );

    if (response.statusCode < 200 ||
        response.statusCode >= 300) {
      throw GoogleMapsPlatformException(
        'Google Place Details lookup failed '
        '(${response.statusCode}).',
      );
    }

    final decoded = jsonDecode(response.body);

    if (decoded is! Map<String, dynamic>) {
      throw const GoogleMapsPlatformException(
        'Invalid Google Place Details response.',
      );
    }

    final currentOpeningHours =
        decoded['currentOpeningHours'];

    final bool? openNow =
        currentOpeningHours is Map<String, dynamic>
            ? currentOpeningHours['openNow'] as bool?
            : null;

    final rawPhotos = decoded['photos'];
    final photos = <GooglePlacePhotoData>[];

    if (rawPhotos is List) {
      for (final rawPhoto in rawPhotos.take(10)) {
        if (rawPhoto is! Map<String, dynamic>) {
          continue;
        }

        final name =
            rawPhoto['name']?.toString().trim() ?? '';

        if (name.isEmpty) {
          continue;
        }

        photos.add(
          GooglePlacePhotoData(
            name: name,
            widthPx:
                (rawPhoto['widthPx'] as num?)?.toInt() ?? 0,
            heightPx:
                (rawPhoto['heightPx'] as num?)?.toInt() ?? 0,
          ),
        );
      }
    }

    return GooglePlaceCheckpointData(
      businessStatus:
          decoded['businessStatus']?.toString() ?? '',
      openNow: openNow,
      photos: List.unmodifiable(photos),
    );
  }

  Future<List<GooglePlacePhotoData>> getPlacePhotoCandidates({
    required String placeId,
  }) async {
    final details =
        await getPlaceCheckpointData(
      placeId: placeId,
    );

    return details.photos;
  }

  // ============================================================
  // PLACE PHOTO (NEW)
  //
  // The resource name is used only for this live request.
  // It is not persisted by the automatic reference-photo flow.
  // ============================================================

  Future<Uint8List> downloadPlacePhoto({
    required String photoResourceName,
    int maxWidthPx = 1600,
  }) async {
    final normalizedName =
        photoResourceName.trim();

    if (apiKey.trim().isEmpty) {
      throw const GoogleMapsPlatformException(
        'Google Places API key is missing.',
      );
    }

    if (normalizedName.isEmpty) {
      throw const GoogleMapsPlatformException(
        'Google Places photo resource is missing.',
      );
    }

    final width = maxWidthPx
        .clamp(
          200,
          4800,
        )
        .toInt();

    final uri = Uri.https(
      'places.googleapis.com',
      '/v1/$normalizedName/media',
      {
        'key': apiKey,
        'maxWidthPx': '$width',
      },
    );

    final response = await _client
        .get(uri)
        .timeout(
          const Duration(
            seconds: 15,
          ),
        );

    if (response.statusCode < 200 ||
        response.statusCode >= 300) {
      throw GoogleMapsPlatformException(
        'Google Places photo request failed '
        '(${response.statusCode}).',
      );
    }

    if (response.bodyBytes.isEmpty) {
      throw const GoogleMapsPlatformException(
        'Google Places returned an empty photo.',
      );
    }

    return Uint8List.fromList(
      response.bodyBytes,
    );
  }

  void dispose() {
    _client.close();
  }
}
