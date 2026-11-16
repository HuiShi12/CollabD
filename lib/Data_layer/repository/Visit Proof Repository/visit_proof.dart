import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../Attraction Repository/attraction.dart';
import '../../service/Location Service/location.dart';
import '../../service/Image Service/image.dart';
import '../../service/Supabase Service/supabase.dart';
// Puzzle deliberately shares Trip Path's verification engine (OpenCV
// matcher + policy + Gemini arbitration) so both game modes judge a photo
// the same way — an explicit exception to Trip Path's usual vendored
// isolation (see trip_path_module.dart), not an accident.
import '../../service/Trip Path Quest Service/trip_path_photo_match_service.dart';
import '../../service/Trip Path Quest Service/gemini_photo_verification.dart';

class VisitProofResult {
  final bool isSuccess;
  final String uploadedPhotoPath;
  final String message;
  final DateTime verifiedAt;

  /// Straight-line metres from the tourist to the mystery place at check time.
  final double? distanceMeters;

  /// True when the shared OpenCV/Gemini engine judged this the same place
  /// but wants a clearer photo (Trip Path Quest's `TripPathPhotoMatchStatus
  /// .retake`), rather than a hard reject. Lets the result sheet show
  /// "Retake Photo" instead of "Photo Not Verified" for that middle case.
  /// Always false for the GPS-distance and reference-unavailable paths,
  /// which never run the photo comparison at all.
  final bool shouldRetake;

  VisitProofResult({
    required this.isSuccess,
    required this.uploadedPhotoPath,
    required this.message,
    required this.verifiedAt,
    this.distanceMeters,
    this.shouldRetake = false,
  });
}

class VisitProofRepository {
  final LocationService locationService;
  final ImageService imageService;
  final SupabaseService supabaseService;
  final TripPathPhotoMatchService _photoMatchService;
  final GeminiPhotoVerificationService _geminiPhotoVerificationService;

  /// UC-05 A2 — the tourist must be within this distance of the real place.
  final int maxVerificationMeters;

  VisitProofRepository({
    required this.locationService,
    required this.imageService,
    required this.supabaseService,
    this.maxVerificationMeters = 50,
    TripPathPhotoMatchService? photoMatchService,
    GeminiPhotoVerificationService? geminiPhotoVerificationService,
  })  : _photoMatchService = photoMatchService ?? TripPathPhotoMatchService(),
        _geminiPhotoVerificationService =
            geminiPhotoVerificationService ?? GeminiPhotoVerificationService();

  Future<VisitProofResult> verifyVisit({
    required MysteryPlaceOption option,
    required File capturedPhoto,
    // UC-05 demo fallback — the Navigate screen's "I'm here (skip — demo)"
    // button forces navigationArrived, but this GPS check ran independently
    // and re-failed the same submission anyway. Lets that same forced state
    // reach the real gate instead of only masking it in the UI. Photo
    // matching below still runs as normal — this only skips step 1.
    bool skipDistanceCheck = false,
  }) async {
    // ---------- 1. Real GPS distance check ----------
    final distance = skipDistanceCheck
        ? null
        : await locationService.distanceMetersTo(
            latitude: option.latitude,
            longitude: option.longitude,
          );

    if (!skipDistanceCheck &&
        (distance == null || distance > maxVerificationMeters)) {
      final result = VisitProofResult(
        isSuccess: false,
        uploadedPhotoPath: capturedPhoto.path,
        distanceMeters: distance,
        message: distance == null
            ? 'Your location cannot be detected. Enable GPS and try again.'
            : 'You are ${distance.round()} m away — get within '
                '$maxVerificationMeters m of the mystery location.',
        verifiedAt: DateTime.now(),
      );
      await _record(option, result, matched: false);
      return result;
    }

    final uploadedPhotoPath = await imageService.uploadCapturedPhoto(
      capturedPhoto: capturedPhoto,
    );

    // ---------- 2. Shared OpenCV + Gemini photo verification ----------
    final referenceBytes = await _downloadReference(option.imageUrl);

    VisitProofResult result;
    bool matched;
    if (referenceBytes == null) {
      // Fails open, matching this codebase's existing resilience
      // convention — a missing reference photo must never block a visit.
      result = VisitProofResult(
        isSuccess: true,
        uploadedPhotoPath: uploadedPhotoPath,
        distanceMeters: distance,
        message: 'Visit verified (photo check skipped — reference unavailable).',
        verifiedAt: DateTime.now(),
      );
      matched = true;
    } else {
      final capturedBytes = await capturedPhoto.readAsBytes();
      final themeAndKind = _themeAndKindForCategory(option.category);

      TripPathPhotoMatchResult match;
      try {
        match = await _photoMatchService.compare(
          referenceImageBytes: referenceBytes,
          capturedImageBytes: capturedBytes,
          themeId: themeAndKind.themeId,
          referenceKind: themeAndKind.referenceKind,
          expectedPlaceName: option.name,
        );
      } catch (_) {
        // Fails open on an OpenCV/native failure, same convention as before.
        match = const TripPathPhotoMatchResult(
          status: TripPathPhotoMatchStatus.matched,
          referenceKeypoints: 0,
          capturedKeypoints: 0,
          goodMatches: -1,
          inliers: 0,
          inlierRatio: 0,
          message: 'Visit verified (photo check unavailable on this device).',
        );
      }

      // A borderline local result gets a second opinion from Gemini, same
      // hybrid flow Trip Path uses — never for a clear match/reject.
      if (match.status == TripPathPhotoMatchStatus.retake ||
          match.status == TripPathPhotoMatchStatus.notMatched) {
        match = await _consultGeminiForBorderlineMatch(
          local: match,
          referenceBytes: referenceBytes,
          capturedBytes: capturedBytes,
          themeId: themeAndKind.themeId,
          referenceKind: themeAndKind.referenceKind,
          expectedPlaceName: option.name,
        );
      }

      matched = match.status == TripPathPhotoMatchStatus.matched;
      result = VisitProofResult(
        isSuccess: matched,
        uploadedPhotoPath: uploadedPhotoPath,
        distanceMeters: distance,
        shouldRetake: match.status == TripPathPhotoMatchStatus.retake,
        message: matched
            ? 'Visit verified — your photo matches this place.'
            : match.message.isNotEmpty
                ? match.message
                : 'Your photo does not match the reference landmark. '
                    'Frame the same view and try again.',
        verifiedAt: DateTime.now(),
      );
    }

    await _record(option, result, matched: matched);
    return result;
  }

  /// Puzzle's simpler counterpart to Trip Path's full adaptive AI-fusion
  /// state machine (`TripPathQuestPhotoVerificationViewModel`) — same
  /// underlying engine/policy/Gemini service, but a compact merge instead of
  /// duplicating that ~700-line theme-specific fusion logic at the
  /// repository layer. A hard identity conflict or permanent contradiction
  /// can never be overridden by AI, matching Trip Path's own safety rule.
  Future<TripPathPhotoMatchResult> _consultGeminiForBorderlineMatch({
    required TripPathPhotoMatchResult local,
    required Uint8List referenceBytes,
    required Uint8List capturedBytes,
    required String themeId,
    required String referenceKind,
    required String expectedPlaceName,
  }) async {
    if (local.storefrontIdentityConflict) return local;

    try {
      final ai = await _geminiPhotoVerificationService.compare(
        reference: referenceBytes,
        captured: capturedBytes,
        themeId: themeId,
        referenceKind: referenceKind,
        expectedPlaceName: expectedPlaceName,
      );

      if (ai.identityConflict || ai.hasPermanentContradiction) {
        return local.copyWith(
          status: TripPathPhotoMatchStatus.notMatched,
          message: 'The reference and captured photo show conflicting place details.',
        );
      }

      if (ai.verdict == 'same_place' &&
          ai.confidence >= 0.86 &&
          ai.stableMatches.length >= 2) {
        return local.copyWith(
          status: TripPathPhotoMatchStatus.matched,
          message: 'Visit verified — independent AI review confirmed the same place.',
        );
      }

      if ((ai.verdict == 'probably_same' || ai.verdict == 'same_place') &&
          ai.confidence >= 0.78 &&
          ai.stableMatches.length >= 2 &&
          local.status != TripPathPhotoMatchStatus.notMatched) {
        return local.copyWith(
          status: TripPathPhotoMatchStatus.retake,
          message: 'This looks like it could be the same place. Retake with a bit '
              'more of the fixed scene visible.',
        );
      }

      return local;
    } catch (_) {
      // AI is optional — keep the local decision when Gemini is unavailable.
      return local;
    }
  }

  Future<Uint8List?> _downloadReference(String url) async {
    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
        return response.bodyBytes;
      }
    } catch (_) {}
    return null;
  }

  /// Maps Puzzle's general category text to the theme/reference-kind
  /// vocabulary the shared verification engine understands — the same
  /// keyword approach already used for Puzzle's category icon elsewhere.
  ({String themeId, String referenceKind}) _themeAndKindForCategory(
    String category,
  ) {
    final c = category.toLowerCase();
    if (c.contains('food') || c.contains('restaurant') || c.contains('cafe')) {
      return (themeId: 'food', referenceKind: 'storefront_exterior');
    }
    if (c.contains('park') || c.contains('garden') || c.contains('nature')) {
      return (themeId: 'nature', referenceKind: 'nature_scene');
    }
    if (c.contains('museum') ||
        c.contains('gallery') ||
        c.contains('cultur') ||
        c.contains('heritage')) {
      return (themeId: 'heritage', referenceKind: 'landmark_building_exterior');
    }
    return (themeId: 'general', referenceKind: 'general_place');
  }

  Future<void> _record(
    MysteryPlaceOption option,
    VisitProofResult result, {
    required bool matched,
  }) async {
    // Logging the attempt must never break the verification flow.
    try {
      await supabaseService.createVisitProofRecord(
        data: {
          'hidden_place_id': option.id,
          'hidden_place_name': option.name,
          'township': option.township,
          'reference_image_url': option.imageUrl,
          'submitted_photo_path': result.uploadedPhotoPath,
          'distance_meter': result.distanceMeters?.round(),
          'verification_status': result.isSuccess ? 'Successful' : 'Failed',
          'message': result.message,
          'verified_at': result.verifiedAt.toIso8601String(),
        },
      );
    } catch (_) {}
  }
}
