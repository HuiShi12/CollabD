import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class LandmarkClueRepository {
  final SupabaseClient client;

  const LandmarkClueRepository({
    required this.client,
  });

  // ============================================================
  // GET REUSABLE CLUES
  //
  // Google Place ID is the stable identity used to reuse clues.
  //
  // Returns:
  // - exactly 3 clues -> cache HIT
  // - null            -> cache MISS / unavailable
  //
  // Any Supabase failure is allowed to fall back to Gemini.
  // ============================================================

  Future<List<String>?> getReusableClues({
    required String googlePlaceId,
    required String name,
    required String address,
    required String primaryType,
    required double latitude,
    required double longitude,
    String? photoResourceName,
  }) async {
    final normalizedPlaceId = googlePlaceId.trim();

    if (normalizedPlaceId.isEmpty) {
      _log(
        'SKIP: place has no Google Place ID.',
      );
      return null;
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

      final rows = await client
          .from('landmark_clues')
          .select(
            'clue_number, clue_text',
          )
          .eq(
            'landmark_id',
            landmarkId,
          )
          .eq(
            'is_active',
            true,
          )
          .eq('source', 'gemini_grounded_v2')
          .order(
            'clue_number',
            ascending: true,
          );

      if (rows is! List) {
        return null;
      }

      final Map<int, String> byNumber = {};

      for (final rawRow in rows) {
        if (rawRow is! Map) {
          continue;
        }

        final clueNumberValue =
            rawRow['clue_number'];

        final clueTextValue =
            rawRow['clue_text'];

        final clueNumber =
            clueNumberValue is int
                ? clueNumberValue
                : int.tryParse(
                    '$clueNumberValue',
                  );

        final clueText =
            '$clueTextValue'.trim();

        if (clueNumber == null ||
            clueText.isEmpty) {
          continue;
        }

        if (clueNumber >= 1 &&
            clueNumber <= 3) {
          byNumber[clueNumber] =
              clueText;
        }
      }

      if (byNumber.length != 3 ||
          !byNumber.containsKey(1) ||
          !byNumber.containsKey(2) ||
          !byNumber.containsKey(3)) {
        _log(
          'MISS: $name has '
          '${byNumber.length}/3 reusable clue(s).',
        );
        return null;
      }

      final result = List<String>.unmodifiable(
        [
          byNumber[1]!,
          byNumber[2]!,
          byNumber[3]!,
        ],
      );

      _log(
        'HIT: $name -> 3 reusable clues.',
      );

      return result;
    } catch (error) {
      _log(
        'READ ERROR for $name: $error',
      );

      // Supabase cache must never stop the Quest.
      // Gemini remains the fallback.
      return null;
    }
  }

  // ============================================================
  // SAVE GEMINI CLUES FOR FUTURE REUSE
  // ============================================================

  Future<void> saveReusableClues({
    required String googlePlaceId,
    required String name,
    required String address,
    required String primaryType,
    required double latitude,
    required double longitude,
    required List<String> clues,
    String? photoResourceName,
  }) async {
    final normalizedPlaceId =
        googlePlaceId.trim();

    if (normalizedPlaceId.isEmpty) {
      _log(
        'SAVE SKIP: place has no Google Place ID.',
      );
      return;
    }

    if (clues.length != 3) {
      _log(
        'SAVE SKIP: expected 3 clues, '
        'received ${clues.length}.',
      );
      return;
    }

    final normalizedClues = clues
        .map(
          (clue) => clue.trim(),
        )
        .toList(
          growable: false,
        );

    if (normalizedClues.any(
      (clue) => clue.isEmpty,
    )) {
      _log(
        'SAVE SKIP: at least one clue is empty.',
      );
      return;
    }

    try {
      final landmarkId =
          await _upsertLandmark(
        googlePlaceId:
            normalizedPlaceId,
        name:
            name,
        address:
            address,
        primaryType:
            primaryType,
        latitude:
            latitude,
        longitude:
            longitude,
        photoResourceName:
            photoResourceName,
      );

      final payload = List.generate(
        3,
        (index) {
          return {
            'landmark_id':
                landmarkId,
            'clue_number':
                index + 1,
            'clue_text':
                normalizedClues[index],
            'source':
                'gemini_grounded_v2',
            'is_active':
                true,
          };
        },
        growable: false,
      );

      await client
          .from(
            'landmark_clues',
          )
          .upsert(
            payload,
            onConflict:
                'landmark_id,clue_number',
          );

      _log(
        'SAVED: $name -> 3 clues.',
      );
    } catch (error) {
      // Saving the cache is optional.
      // The already-generated Gemini clues should still be used.
      _log(
        'SAVE ERROR for $name: $error',
      );
    }
  }

  // ============================================================
  // LANDMARK UPSERT
  //
  // Same Google Place ID = same reusable landmark record.
  // ============================================================

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
        .from(
          'landmarks',
        )
        .upsert(
          {
            'google_place_id':
                googlePlaceId,
            'name':
                name,
            'address':
                address,
            'primary_type':
                primaryType,
            'latitude':
                latitude,
            'longitude':
                longitude,
            'photo_resource_name':
                photoResourceName,
            'updated_at':
                DateTime.now()
                    .toUtc()
                    .toIso8601String(),
          },
          onConflict:
              'google_place_id',
        )
        .select(
          'id',
        )
        .single();

    final landmarkId = '${row['id'] ?? ''}'.trim();

    if (landmarkId.isEmpty) {
      throw StateError(
        'Supabase landmark id is invalid: ${row['id']}',
      );
    }

    return landmarkId;
  }

  void _log(
    String message,
  ) {
    if (!kDebugMode) {
      return;
    }

    debugPrint(
      '[SUPABASE CLUE CACHE] $message',
    );
  }
}
