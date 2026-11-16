import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class UserLandmarkVisitRepository {
  final SupabaseClient client;

  const UserLandmarkVisitRepository({
    required this.client,
  });

  String? get currentUserId =>
      client.auth.currentUser?.id;

  bool get hasUserIdentity =>
      currentUserId != null;

  Future<Set<String>> getVisitedGooglePlaceIds() async {
    final userId = currentUserId;

    if (userId == null) {
      _log(
        'No authenticated user. Visited-place exclusion is skipped.',
      );
      return <String>{};
    }

    try {
      final rows = await client
          .from('user_landmark_visits')
          .select(
            'landmark_id, landmarks(google_place_id, name)',
          )
          .eq('user_id', userId);

      final placeIds = <String>{};

      if (rows is List) {
        for (final rawRow in rows) {
          if (rawRow is! Map) {
            continue;
          }

          final rawLandmark = rawRow['landmarks'];

          if (rawLandmark is Map) {
            final placeId =
                '${rawLandmark['google_place_id'] ?? ''}'
                    .trim();

            if (placeId.isNotEmpty) {
              placeIds.add(placeId);
            }
          }
        }
      }

      _log(
        'Loaded ${placeIds.length} previously visited place(s) '
        'for user $userId.',
      );

      return placeIds;
    } catch (error) {
      _log(
        'Unable to load visited landmarks: $error',
      );
      return <String>{};
    }
  }

  Future<void> markVisited({
    required String googlePlaceId,
    required String name,
    required String address,
    required String primaryType,
    required double latitude,
    required double longitude,
    String? photoResourceName,
  }) async {
    final userId = currentUserId;

    if (userId == null) {
      _log(
        'Visit not persisted because no authenticated user is available.',
      );
      return;
    }

    final normalizedPlaceId =
        googlePlaceId.trim();

    if (normalizedPlaceId.isEmpty) {
      _log(
        'Visit not persisted because Google Place ID is empty.',
      );
      return;
    }

    try {
      final landmarkId = await _upsertLandmark(
        googlePlaceId: normalizedPlaceId,
        name: name,
        address: address,
        primaryType: primaryType,
        latitude: latitude,
        longitude: longitude,
        photoResourceName: photoResourceName,
      );

      await client
          .from('user_landmark_visits')
          .upsert(
            {
              'user_id': userId,
              'landmark_id': landmarkId,
              'visited_at':
                  DateTime.now().toUtc().toIso8601String(),
            },
            onConflict: 'user_id,landmark_id',
          );

      _log(
        'VISITED SAVED: $name '
        '(Google Place ID: $normalizedPlaceId)',
      );
    } catch (error) {
      _log(
        'Unable to save visited landmark $name: $error',
      );
    }
  }

  Future<String> _upsertLandmark({
    required String googlePlaceId,
    required String name,
    required String address,
    required String primaryType,
    required double latitude,
    required double longitude,
    String? photoResourceName,
  }) async {
    final row = await client
        .from('landmarks')
        .upsert(
          {
            'google_place_id': googlePlaceId,
            'name': name,
            'address': address,
            'primary_type': primaryType,
            'latitude': latitude,
            'longitude': longitude,
            'photo_resource_name': photoResourceName,
            'updated_at':
                DateTime.now().toUtc().toIso8601String(),
          },
          onConflict: 'google_place_id',
        )
        .select('id')
        .single();

    final landmarkId = '${row['id'] ?? ''}'.trim();

    if (landmarkId.isEmpty) {
      throw StateError(
        'Invalid landmark id returned by Supabase: ${row['id']}',
      );
    }

    return landmarkId;
  }

  void _log(String message) {
    if (kDebugMode) {
      debugPrint(
        '[VISIT HISTORY] $message',
      );
    }
  }
}
