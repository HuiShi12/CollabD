import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart' as ml_text;
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart' as ml_label;
import 'package:opencv_dart/opencv_dart.dart' as cv;

import 'trip_path_match_policy.dart';
export 'trip_path_match_policy.dart' show TripPathPhotoMatchStatus;

// ============================================================
// TRIP PATH QUEST - PHOTO MATCH RESULT STATUS
// ============================================================

Future<TripPathPhotoMatchResult> _comparePhotoWorker(Map<String, Object> input) {
  return TripPathPhotoMatchService()._compare(
    referenceImageBytes: input['reference'] as Uint8List,
    capturedImageBytes: input['captured'] as Uint8List,
    themeId: input['theme'] as String,
    referenceKind: input['kind'] as String,
    precomputedScene: input['scene'] as double,
    precomputedStorefrontTextSimilarity: input['storefrontText'] as double,
    precomputedStorefrontReferenceNameSimilarity:
        input['storefrontReferenceName'] as double,
    precomputedStorefrontExpectedNameSimilarity:
        input['storefrontExpectedName'] as double,
    precomputedStorefrontIdentityConflict:
        input['storefrontIdentityConflict'] as bool,
    precomputedStorefrontStructureSimilarity:
        input['storefrontStructure'] as double,
  );
}

// ============================================================
// TRIP PATH QUEST - PHOTO MATCH RESULT
// ============================================================

// ============================================================
// STOREFRONT TEXT / IDENTITY EVIDENCE
// ============================================================

class _StorefrontTextEvidence {
  final double pairSimilarity;
  final double referenceNameSimilarity;
  final double expectedNameSimilarity;
  final bool identityConflict;

  const _StorefrontTextEvidence({
    this.pairSimilarity = 0,
    this.referenceNameSimilarity = 0,
    this.expectedNameSimilarity = 0,
    this.identityConflict = false,
  });
}


// ============================================================
// V46 SCENE-CONTEXT EVIDENCE
// ============================================================
//
// This is a conservative on-device scene check.  It is intentionally not a
// general "AI says indoor/outdoor" oracle.  Only high-confidence, clearly
// separated signals are allowed to create an environment mismatch.
//
// The reference selector already prefers outdoor/re-photographable photos.
// V46 repeats the check at verification time because a user can otherwise
// submit an indoor photo of the same business brand or a generic environment
// that shares textures with an exterior reference.
class _SceneContextEvidence {
  final String referenceEnvironment; // indoor / outdoor / mixed / uncertain
  final String capturedEnvironment;
  final double referenceIndoorScore;
  final double referenceOutdoorScore;
  final double capturedIndoorScore;
  final double capturedOutdoorScore;

  // V47 — a photo dominated by a person/selfie is never a valid landmark
  // capture, regardless of what the indoor/outdoor keyword vocabulary above
  // makes of it. The reference selector already refuses any candidate photo
  // that shows a person; this repeats that same rule at verification time,
  // since only the captured side was previously checked for indoor/outdoor
  // and never for "is this even a photo of the place at all".
  final double capturedPersonScore;

  const _SceneContextEvidence({
    this.referenceEnvironment = 'uncertain',
    this.capturedEnvironment = 'uncertain',
    this.referenceIndoorScore = 0,
    this.referenceOutdoorScore = 0,
    this.capturedIndoorScore = 0,
    this.capturedOutdoorScore = 0,
    this.capturedPersonScore = 0,
  });

  bool get capturedShowsPeople => capturedPersonScore >= 0.55;

  bool get confidentMismatch {
    // Keep this deliberately conservative. Covered walkways, open-front
    // restaurants and pavilions can receive some "indoor" labels even though
    // they are valid outdoor/exterior captures. Only a strong one-sided scene
    // classification may hard-reject before geometry/AI review.
    final refOutdoor = referenceEnvironment == 'outdoor' &&
        referenceOutdoorScore >= 0.62;
    final capIndoor = capturedEnvironment == 'indoor' &&
        capturedIndoorScore >= 0.68 &&
        capturedOutdoorScore <= 0.42 &&
        capturedIndoorScore >= capturedOutdoorScore + 0.16;

    final refIndoor = referenceEnvironment == 'indoor' &&
        referenceIndoorScore >= 0.68;
    final capOutdoor = capturedEnvironment == 'outdoor' &&
        capturedOutdoorScore >= 0.62 &&
        capturedIndoorScore <= 0.42 &&
        capturedOutdoorScore >= capturedIndoorScore + 0.16;

    return (refOutdoor && capIndoor) || (refIndoor && capOutdoor);
  }
}

class _SingleSceneContext {
  final String environment;
  final double indoorScore;
  final double outdoorScore;
  final double personScore;

  const _SingleSceneContext({
    required this.environment,
    required this.indoorScore,
    required this.outdoorScore,
    this.personScore = 0,
  });
}

class TripPathPhotoMatchResult {
  final TripPathPhotoMatchStatus status;

  final int referenceKeypoints;
  final int capturedKeypoints;

  final int goodMatches;
  final int inliers;

  final double inlierRatio;

  // Spatial distribution of RANSAC inliers across each image.
  // 0..1 = occupied cells / 9 in a 3x3 grid.
  // Three occupied cells are enough for a real partially-obstructed
  // storefront/stall, while sign-only crops normally remain too local.
  final double referenceSceneCoverage;
  final double capturedSceneCoverage;

  // Mean grayscale brightness of the captured image (0..255).
  final double capturedBrightness;

  // True when CLAHE was used to normalize low-light or day/night lighting differences.
  final bool lowLightEnhanced;

  final double globalSceneSimilarity;

  // V19 optional on-device OCR agreement for distinctive storefront wording.
  // 0 means unavailable/no useful shared text. It is only supplementary.
  final double storefrontTextSimilarity;

  // V27 expected-place-name evidence for storefront identity.
  final double storefrontReferenceNameSimilarity;
  final double storefrontExpectedNameSimilarity;
  final bool storefrontIdentityConflict;

  // V20/V21 illumination/occlusion-robust structural similarity for the
  // upper storefront/facade region. This intentionally downweights the dynamic
  // lower foreground where people, tables and parked vehicles change often.
  // In V21 it can corroborate a very strong RANSAC + whole-scene match even
  // when on-device OCR returns no useful text.
  final double storefrontStructureSimilarity;

  // V46 scene-context metadata.  Values come from an on-device ML Kit
  // classifier and are used only when confidence is high enough to avoid
  // confusing covered outdoor spaces with true interiors.
  final String referenceEnvironment;
  final String capturedEnvironment;
  final double referenceIndoorScore;
  final double referenceOutdoorScore;
  final double capturedIndoorScore;
  final double capturedOutdoorScore;

  final String reasonCode;
  final double referenceHullArea;
  final double capturedHullArea;
  final double capturedDarkBorderFraction;
  final double capturedSharpness;

  final String message;

  // V39 hybrid AI verification metadata. Local CV remains primary; these are
  // populated only when a borderline result is reviewed by Gemini. Keeping
  // this metadata on the result makes real-device calibration much easier.
  final bool aiReviewed;
  final String aiDecision;
  final double aiConfidence;
  final String aiExplanation;

  const TripPathPhotoMatchResult({
    required this.status,
    required this.referenceKeypoints,
    required this.capturedKeypoints,
    required this.goodMatches,
    required this.inliers,
    required this.inlierRatio,
    this.referenceSceneCoverage = 0,
    this.capturedSceneCoverage = 0,
    this.capturedBrightness = 0,
    this.lowLightEnhanced = false,
    this.globalSceneSimilarity = 0,
    this.storefrontTextSimilarity = 0,
    this.storefrontReferenceNameSimilarity = 0,
    this.storefrontExpectedNameSimilarity = 0,
    this.storefrontIdentityConflict = false,
    this.storefrontStructureSimilarity = 0,
    this.referenceEnvironment = 'uncertain',
    this.capturedEnvironment = 'uncertain',
    this.referenceIndoorScore = 0,
    this.referenceOutdoorScore = 0,
    this.capturedIndoorScore = 0,
    this.capturedOutdoorScore = 0,
    this.reasonCode = '',
    this.referenceHullArea = 0,
    this.capturedHullArea = 0,
    this.capturedDarkBorderFraction = 0,
    this.capturedSharpness = 0,
    this.aiReviewed = false,
    this.aiDecision = '',
    this.aiConfidence = 0,
    this.aiExplanation = '',
    required this.message,
  });

  TripPathPhotoMatchResult copyWith({
    TripPathPhotoMatchStatus? status,
    String? reasonCode,
    String? message,
    bool? aiReviewed,
    String? aiDecision,
    double? aiConfidence,
    String? aiExplanation,
    String? referenceEnvironment,
    String? capturedEnvironment,
    double? referenceIndoorScore,
    double? referenceOutdoorScore,
    double? capturedIndoorScore,
    double? capturedOutdoorScore,
  }) {
    return TripPathPhotoMatchResult(
      status: status ?? this.status,
      referenceKeypoints: referenceKeypoints,
      capturedKeypoints: capturedKeypoints,
      goodMatches: goodMatches,
      inliers: inliers,
      inlierRatio: inlierRatio,
      referenceSceneCoverage: referenceSceneCoverage,
      capturedSceneCoverage: capturedSceneCoverage,
      capturedBrightness: capturedBrightness,
      lowLightEnhanced: lowLightEnhanced,
      globalSceneSimilarity: globalSceneSimilarity,
      storefrontTextSimilarity: storefrontTextSimilarity,
      storefrontReferenceNameSimilarity: storefrontReferenceNameSimilarity,
      storefrontExpectedNameSimilarity: storefrontExpectedNameSimilarity,
      storefrontIdentityConflict: storefrontIdentityConflict,
      storefrontStructureSimilarity: storefrontStructureSimilarity,
      referenceEnvironment:
          referenceEnvironment ?? this.referenceEnvironment,
      capturedEnvironment:
          capturedEnvironment ?? this.capturedEnvironment,
      referenceIndoorScore:
          referenceIndoorScore ?? this.referenceIndoorScore,
      referenceOutdoorScore:
          referenceOutdoorScore ?? this.referenceOutdoorScore,
      capturedIndoorScore:
          capturedIndoorScore ?? this.capturedIndoorScore,
      capturedOutdoorScore:
          capturedOutdoorScore ?? this.capturedOutdoorScore,
      reasonCode: reasonCode ?? this.reasonCode,
      referenceHullArea: referenceHullArea,
      capturedHullArea: capturedHullArea,
      capturedDarkBorderFraction: capturedDarkBorderFraction,
      capturedSharpness: capturedSharpness,
      aiReviewed: aiReviewed ?? this.aiReviewed,
      aiDecision: aiDecision ?? this.aiDecision,
      aiConfidence: aiConfidence ?? this.aiConfidence,
      aiExplanation: aiExplanation ?? this.aiExplanation,
      message: message ?? this.message,
    );
  }

  // ==========================================================
  // CONVENIENCE GETTERS
  // ==========================================================

  bool get isMatched {
    return status == TripPathPhotoMatchStatus.matched;
  }

  bool get shouldRetake {
    return status == TripPathPhotoMatchStatus.retake;
  }

  bool get isNotMatched {
    return status == TripPathPhotoMatchStatus.notMatched;
  }

  bool get hasError {
    return status == TripPathPhotoMatchStatus.error;
  }

  String get statusText {
    switch (status) {
      case TripPathPhotoMatchStatus.matched:
        return 'MATCHED';

      case TripPathPhotoMatchStatus.retake:
        return 'RETAKE PHOTO';

      case TripPathPhotoMatchStatus.notMatched:
        return 'NOT MATCHED';

      case TripPathPhotoMatchStatus.error:
        return 'VERIFICATION ERROR';
    }
  }

  String get inlierRatioText {
    return '${(inlierRatio * 100).toStringAsFixed(1)}%';
  }
}

// ============================================================
// TRIP PATH QUEST - PHOTO MATCH SERVICE
//
// LOCAL IMAGE VERIFICATION:
//
// Reference Photo
//       +
// Camera Photo
//       ↓
// Decode as grayscale
//       ↓
// Resize to maximum 1280 px
//       ↓
// ORB feature detection
//       ↓
// ORB descriptors
//       ↓
// BFMatcher + Hamming
//       ↓
// KNN k = 2
//       ↓
// Lowe Ratio Test
//       ↓
// RANSAC Homography
//       ↓
// Geometric inliers
//       ↓
// MATCHED / RETAKE / NOT MATCHED
//
// IMPORTANT:
//
// These thresholds are INITIAL TESTING VALUES.
//
// They must later be calibrated using:
// - real buildings
// - different camera angles / perspective
// - different lighting
// - different distances
// ============================================================

class TripPathPhotoMatchService {
  // ==========================================================
  // IMAGE PREPROCESSING
  // ==========================================================

  static const int maxImageDimension = 1280;

  // ==========================================================
  // ORB
  // ==========================================================

  static const int orbFeatureCount = 1500;

  // ==========================================================
  // KNN RATIO TEST
  // ==========================================================

  static const double ratioTestThreshold = 0.78;

  // V23: keep storefront Lowe-ratio filtering conservative. V22 widened this
  // pool and real-device testing showed that unrelated storefronts could gain
  // many extra ambiguous matches, depressing the RANSAC inlier ratio and
  // being misclassified as RETAKE. Storefronts now use the same reciprocal
  // ratio thresholds as the stable V20/V21 path.
  static const double storefrontRatioTestThreshold = 0.78;

  // CLAHE makes day/night descriptors comparable. A small amount of extra
  // tolerance remains for lighting-normalized pairs, but storefronts do not
  // get an additional widening beyond the normal day/night threshold.
  static const double lightingNormalizedRatioTestThreshold = 0.82;
  static const double storefrontLightingNormalizedRatioTestThreshold = 0.82;

  // ==========================================================
  // RANSAC
  // ==========================================================

  static const double ransacReprojectionThreshold = 5.0;

  static const int ransacMaxIterations = 2000;

  static const double ransacConfidence = 0.995;

  // ==========================================================
  // INITIAL DECISION THRESHOLDS
  //
  // These are NOT final scientific thresholds.
  //
  // We will tune them after testing with:
  //
  // keyboard
  // book
  // object
  // building
  // ==========================================================

  static const int minimumUsefulKeypoints = 80;

  static const int minimumMatchesForRansac = 6;

  // ==========================================================
  // LOW-LIGHT HANDLING
  // ==========================================================

  static const double veryDarkBrightnessThreshold = 22.0;
  static const double lowLightBrightnessThreshold = 92.0;

  // When the Google reference was captured at night but the player's
  // photo is taken in daylight (or the reverse), ORB can lose otherwise
  // stable correspondences because local contrast changes substantially.
  // If the mean brightness difference is large, normalize BOTH images
  // with CLAHE before feature extraction.
  static const double lightingDifferenceNormalizationThreshold = 28.0;


  // ==========================================================
  // COMPARE PHOTOS
  // ==========================================================

  Future<TripPathPhotoMatchResult> compare({
    required Uint8List referenceImageBytes,
    required Uint8List capturedImageBytes,
    String themeId = 'unknown',
    String referenceKind = 'unknown',
    String expectedPlaceName = '',
  }) async {
    final normalizedKind = referenceKind.trim().toLowerCase();
    final storefrontLike = const {
      'storefront_exterior',
      'food_stall_or_kiosk',
    }.contains(normalizedKind);

    // Global scene evidence remains available to every profile. V19 adds an
    // OPTIONAL on-device OCR anchor only for references already classified as
    // storefront/open-front scenes. OCR failure simply returns 0 and leaves
    // the existing ORB/RANSAC path unchanged.
    final sceneFuture = _computeGlobalSceneSimilarity(
      referenceImageBytes,
      capturedImageBytes,
    );

    // V45 DYNAMIC FOREGROUND SUPPRESSION
    //
    // A second lightweight scene pass compares only the more stable upper
    // portion of both images. This deliberately reduces the influence of
    // people, parked cars, motorcycles, movable tables and other transient
    // foreground objects without adding a new object-detection dependency.
    //
    // It is supporting evidence only: the robust score below can lift the
    // full-frame scene score by a limited amount, but it can never create
    // RANSAC geometry, OCR identity, or a match on its own.
    final stableSceneFuture = _computeDynamicSuppressedSceneSimilarity(
      referenceImageBytes,
      capturedImageBytes,
      themeId: themeId,
      referenceKind: referenceKind,
    );

    // V46: classify BOTH images as indoor/outdoor before geometry is allowed
    // to prove a place. This is intentionally conservative and only produces
    // a hard mismatch when the two scene-context signals are both strong.
    final sceneContextFuture = _computeSceneContextEvidence(
      referenceImageBytes,
      capturedImageBytes,
    );

    final textFuture = storefrontLike
        ? _computeStorefrontTextEvidence(
            referenceImageBytes,
            capturedImageBytes,
            expectedPlaceName: expectedPlaceName,
          )
        : Future<_StorefrontTextEvidence>.value(
            const _StorefrontTextEvidence(),
          );

    // V20/V21: compare the stable upper facade separately. This is never a
    // match by itself. V20 used it with OCR + RANSAC; V21 also permits a much
    // stricter RANSAC + facade + whole-scene path when OCR returns zero.
    final storefrontStructureFuture = storefrontLike
        ? _computeStorefrontStructureSimilarity(
            referenceImageBytes,
            capturedImageBytes,
          )
        : Future<double>.value(0);

    final scene = await sceneFuture;
    final stableScene = await stableSceneFuture;
    final sceneContext = await sceneContextFuture;
    final robustScene = _fuseDynamicSuppressedScene(
      fullScene: scene,
      stableScene: stableScene,
      themeId: themeId,
      referenceKind: referenceKind,
    );
    final storefrontTextEvidence = await textFuture;
    final storefrontStructure = await storefrontStructureFuture;

    if (kDebugMode) {
      debugPrint(
        '[V45 STATIC SCENE] full=${scene.toStringAsFixed(3)} '
        'stable=${stableScene.toStringAsFixed(3)} '
        'fused=${robustScene.toStringAsFixed(3)} '
        'env=${sceneContext.referenceEnvironment}'
        '->${sceneContext.capturedEnvironment} '
        'refOut=${sceneContext.referenceOutdoorScore.toStringAsFixed(2)} '
        'capIn=${sceneContext.capturedIndoorScore.toStringAsFixed(2)}',
      );
    }

    // V47 — a person/selfie-dominated capture is never a valid landmark
    // photo, independent of indoor/outdoor classification (that vocabulary
    // has no words for "person using a laptop/phone" and would otherwise
    // score this ~0/0 and land on 'uncertain', silently passing through).
    // The reference photo is already required to show no person at
    // selection time; this is the same rule applied to what the tourist
    // actually submits here.
    if (sceneContext.capturedShowsPeople) {
      return TripPathPhotoMatchResult(
        status: TripPathPhotoMatchStatus.notMatched,
        referenceKeypoints: 0,
        capturedKeypoints: 0,
        goodMatches: 0,
        inliers: 0,
        inlierRatio: 0,
        globalSceneSimilarity: robustScene,
        referenceEnvironment: sceneContext.referenceEnvironment,
        capturedEnvironment: sceneContext.capturedEnvironment,
        referenceIndoorScore: sceneContext.referenceIndoorScore,
        referenceOutdoorScore: sceneContext.referenceOutdoorScore,
        capturedIndoorScore: sceneContext.capturedIndoorScore,
        capturedOutdoorScore: sceneContext.capturedOutdoorScore,
        reasonCode: 'v47_person_photo',
        message:
            'Your photo appears to show a person rather than the landmark itself. Retake a photo of just the physical location, with no people in frame.',
      );
    }

    // A clear exterior-vs-interior contradiction is a place-context
    // mismatch, not a camera-angle problem. Do not send it into generic
    // Retake or let matching furniture/signage textures verify the visit.
    if (sceneContext.confidentMismatch) {
      return TripPathPhotoMatchResult(
        status: TripPathPhotoMatchStatus.notMatched,
        referenceKeypoints: 0,
        capturedKeypoints: 0,
        goodMatches: 0,
        inliers: 0,
        inlierRatio: 0,
        globalSceneSimilarity: robustScene,
        referenceEnvironment: sceneContext.referenceEnvironment,
        capturedEnvironment: sceneContext.capturedEnvironment,
        referenceIndoorScore: sceneContext.referenceIndoorScore,
        referenceOutdoorScore: sceneContext.referenceOutdoorScore,
        capturedIndoorScore: sceneContext.capturedIndoorScore,
        capturedOutdoorScore: sceneContext.capturedOutdoorScore,
        reasonCode: 'v46_environment_mismatch',
        message:
            'The checkpoint reference and your photo appear to be from different indoor/outdoor contexts. Photograph the same physical exterior or interior shown in the reference.',
      );
    }

    // compute() has no built-in timeout — a blurry/noisy captured photo can
    // pathologically stall ORB/RANSAC feature matching with no error ever
    // thrown, freezing the "Comparing your photo..." screen forever. Time
    // out and fail closed (treat as not matched) rather than hang.
    final TripPathPhotoMatchResult localResult;
    try {
      localResult = await compute(_comparePhotoWorker, <String, Object>{
        'reference': referenceImageBytes,
        'captured': capturedImageBytes,
        'theme': themeId,
        'kind': referenceKind,
        'scene': robustScene,
        'storefrontText': storefrontTextEvidence.pairSimilarity,
        'storefrontReferenceName': storefrontTextEvidence.referenceNameSimilarity,
        'storefrontExpectedName': storefrontTextEvidence.expectedNameSimilarity,
        'storefrontIdentityConflict': storefrontTextEvidence.identityConflict,
        'storefrontStructure': storefrontStructure,
      }).timeout(const Duration(seconds: 15));
    } on TimeoutException {
      return TripPathPhotoMatchResult(
        status: TripPathPhotoMatchStatus.notMatched,
        referenceKeypoints: 0,
        capturedKeypoints: 0,
        goodMatches: 0,
        inliers: 0,
        inlierRatio: 0,
        globalSceneSimilarity: robustScene,
        referenceEnvironment: sceneContext.referenceEnvironment,
        capturedEnvironment: sceneContext.capturedEnvironment,
        referenceIndoorScore: sceneContext.referenceIndoorScore,
        referenceOutdoorScore: sceneContext.referenceOutdoorScore,
        capturedIndoorScore: sceneContext.capturedIndoorScore,
        capturedOutdoorScore: sceneContext.capturedOutdoorScore,
        reasonCode: 'v48_comparison_timeout',
        message:
            'Comparing your photo took too long. Retake a clearer, less blurry photo and try again.',
      );
    }

    return localResult.copyWith(
      referenceEnvironment: sceneContext.referenceEnvironment,
      capturedEnvironment: sceneContext.capturedEnvironment,
      referenceIndoorScore: sceneContext.referenceIndoorScore,
      referenceOutdoorScore: sceneContext.referenceOutdoorScore,
      capturedIndoorScore: sceneContext.capturedIndoorScore,
      capturedOutdoorScore: sceneContext.capturedOutdoorScore,
    );
  }

  Future<TripPathPhotoMatchResult> _compare({
    required Uint8List referenceImageBytes,
    required Uint8List capturedImageBytes,
    String themeId = 'unknown',
    String referenceKind = 'unknown',
    required double precomputedScene,
    required double precomputedStorefrontTextSimilarity,
    required double precomputedStorefrontReferenceNameSimilarity,
    required double precomputedStorefrontExpectedNameSimilarity,
    required bool precomputedStorefrontIdentityConflict,
    required double precomputedStorefrontStructureSimilarity,
  }) async {
    final normalizedTheme = themeId.trim().toLowerCase();
    final normalizedReferenceKind = referenceKind.trim().toLowerCase();
    final isStorefrontProfile = const {
      'storefront_exterior',
      'food_stall_or_kiosk',
    }.contains(normalizedReferenceKind);

    final isNatureProfile =
        normalizedTheme == 'nature' ||
        normalizedReferenceKind.startsWith('nature_');

    final isPhysicalProfile =
        const {'food', 'culture', 'heritage'}.contains(normalizedTheme) ||
        const {
          'storefront_exterior',
          'food_stall_or_kiosk',
          'building_exterior',
        }.contains(normalizedReferenceKind);

    // ========================================================
    // BASIC INPUT CHECK
    // ========================================================

    if (referenceImageBytes.isEmpty ||
        capturedImageBytes.isEmpty) {
      return const TripPathPhotoMatchResult(
        status: TripPathPhotoMatchStatus.error,
        referenceKeypoints: 0,
        capturedKeypoints: 0,
        goodMatches: 0,
        inliers: 0,
        inlierRatio: 0,
        message:
        'One or both photos are empty and cannot be compared.',
      );
    }

    // ========================================================
    // NATIVE OPENCV OBJECTS
    //
    // Stored here so they can be safely disposed in finally.
    // ========================================================

    cv.Mat? referenceImage;
    cv.Mat? capturedImage;

    cv.Mat? enhancedReferenceImage;
    cv.Mat? enhancedCapturedImage;
    cv.CLAHE? clahe;

    cv.Mat? featureMask;

    cv.ORB? orb;

    cv.VecKeyPoint? referenceKeypoints;
    cv.VecKeyPoint? capturedKeypoints;

    cv.Mat? referenceDescriptors;
    cv.Mat? capturedDescriptors;

    cv.BFMatcher? matcher;

    cv.VecVecDMatch? knnMatches;
    cv.VecVecDMatch? reverseMatches;

    cv.VecPoint2f? referenceMatchedPoints;
    cv.VecPoint2f? capturedMatchedPoints;

    cv.Mat? referenceMatchedPointMat;
    cv.Mat? capturedMatchedPointMat;

    cv.Mat? inlierMask;
    cv.Mat? homography;

    int referenceKeypointCount = 0;
    int capturedKeypointCount = 0;

    int goodMatchCount = 0;
    int inlierCount = 0;

    double inlierRatio = 0;
    double referenceSceneCoverage = 0;
    double capturedSceneCoverage = 0;
    double capturedBrightness = 0;
    bool lowLightEnhanced = false;
    double capturedDarkBorderFraction = 0;
    double capturedSharpness = 0;
    double globalSceneSimilarity = precomputedScene;
    final storefrontTextSimilarity =
        precomputedStorefrontTextSimilarity.clamp(0.0, 1.0).toDouble();
    final storefrontReferenceNameSimilarity =
        precomputedStorefrontReferenceNameSimilarity.clamp(0.0, 1.0).toDouble();
    final storefrontExpectedNameSimilarity =
        precomputedStorefrontExpectedNameSimilarity.clamp(0.0, 1.0).toDouble();
    final storefrontIdentityConflict = precomputedStorefrontIdentityConflict;
    final storefrontStructureSimilarity =
        precomputedStorefrontStructureSimilarity.clamp(0.0, 1.0).toDouble();

    try {
      // ======================================================
      // STEP 1
      // DECODE + RESIZE
      // ======================================================

      referenceImage = _decodeAndResize(
        referenceImageBytes,
      );

      capturedImage = _decodeAndResize(
        capturedImageBytes,
      );

      if (isNatureProfile) {
        globalSceneSimilarity = precomputedScene;
        if (kDebugMode) {
          debugPrint(
            '[PHOTO MATCH] Nature global scene similarity='
            '${(globalSceneSimilarity * 100).toStringAsFixed(1)}%',
          );
        }
      }

      // ======================================================
      // LOW-LIGHT PRECHECK + CLAHE
      //
      // ORB is grayscale-based, but very different illumination can
      // still reduce stable keypoints. For dim photos, normalize local
      // contrast on BOTH images before feature extraction.
      // ======================================================

      final referenceBrightnessScalar =
          cv.mean(referenceImage);

      final capturedBrightnessScalar =
          cv.mean(capturedImage);

      final referenceBrightness =
          referenceBrightnessScalar.val1;

      capturedBrightness =
          capturedBrightnessScalar.val1;

      referenceBrightnessScalar.dispose();
      capturedBrightnessScalar.dispose();

      if (capturedBrightness <
          veryDarkBrightnessThreshold) {
        return TripPathPhotoMatchResult(
          status: TripPathPhotoMatchStatus.retake,
          referenceKeypoints: 0,
          capturedKeypoints: 0,
          goodMatches: 0,
          inliers: 0,
          inlierRatio: 0,
          capturedBrightness: capturedBrightness,
          message:
          'The photo is too dark to verify reliably. Move to a brighter position or use better lighting, then retake the landmark.',
        );
      }

      final quality = _captureQuality(capturedImage!);
      capturedDarkBorderFraction = quality.darkBorder;
      capturedSharpness = quality.sharpness;
      if (capturedDarkBorderFraction >= 0.18 || capturedSharpness < 8) {
        final darkBorderRetake = capturedDarkBorderFraction >= 0.18;
        return TripPathPhotoMatchResult(
          status: TripPathPhotoMatchStatus.retake,
          referenceKeypoints: 0, capturedKeypoints: 0,
          goodMatches: 0, inliers: 0, inlierRatio: 0,
          capturedBrightness: capturedBrightness,
          capturedDarkBorderFraction: capturedDarkBorderFraction,
          capturedSharpness: capturedSharpness,
          reasonCode: darkBorderRetake ? 'dark_border' : 'blurred_capture',
          message: darkBorderRetake
              ? 'A large dark edge obscures the view. Reframe to include the physical place without the obstruction, then retake.'
              : 'The photo is too blurred for a reliable comparison. Hold the camera steady, focus on the landmark and retake.',
        );
      }

      cv.Mat referenceFeatureImage =
          referenceImage;
      cv.Mat capturedFeatureImage =
          capturedImage;

      final lightingDifference =
          (referenceBrightness - capturedBrightness).abs();

      final shouldNormalizeLighting =
          referenceBrightness < lowLightBrightnessThreshold ||
          capturedBrightness < lowLightBrightnessThreshold ||
          lightingDifference >=
              lightingDifferenceNormalizationThreshold;

      final effectiveRatioTestThreshold = isStorefrontProfile
          ? (shouldNormalizeLighting
              ? storefrontLightingNormalizedRatioTestThreshold
              : storefrontRatioTestThreshold)
          : (shouldNormalizeLighting
              ? lightingNormalizedRatioTestThreshold
              : ratioTestThreshold);

      if (shouldNormalizeLighting) {
        final lowLightClahe =
            cv.createCLAHE(
          clipLimit: 2.5,
          tileGridSize: (8, 8),
        );

        clahe = lowLightClahe;

        final enhancedReference =
            lowLightClahe.apply(
          referenceImage,
        );

        final enhancedCaptured =
            lowLightClahe.apply(
          capturedImage,
        );

        enhancedReferenceImage =
            enhancedReference;
        enhancedCapturedImage =
            enhancedCaptured;

        if (!enhancedReference.isEmpty &&
            !enhancedCaptured.isEmpty) {
          referenceFeatureImage =
              enhancedReference;
          capturedFeatureImage =
              enhancedCaptured;
          lowLightEnhanced = true;
        }
      }

      // ======================================================
      // STEP 2
      // CREATE ORB
      //
      // 1500 features gives us enough points for:
      // - detailed objects
      // - signs
      // - building facades
      // ======================================================

      orb = cv.ORB.create(
        nFeatures: isStorefrontProfile ? 1800 : orbFeatureCount,
        scaleFactor: 1.2,
        nLevels: 8,
        edgeThreshold: 31,
        firstLevel: 0,
        WTA_K: 2,
        scoreType: cv.ORBScoreType.HARRIS_SCORE,
        patchSize: 31,
        fastThreshold: isStorefrontProfile ? 16 : 20,
      );

      featureMask = cv.Mat.empty();

      // ======================================================
      // STEP 3
      // REFERENCE ORB FEATURES
      // ======================================================

      final referenceFeatures = orb.detectAndCompute(
        referenceFeatureImage,
        featureMask,
      );

      referenceKeypoints = referenceFeatures.$1;
      referenceDescriptors = referenceFeatures.$2;

      // ======================================================
      // STEP 4
      // CAMERA PHOTO ORB FEATURES
      // ======================================================

      final capturedFeatures = orb.detectAndCompute(
        capturedFeatureImage,
        featureMask,
      );

      capturedKeypoints = capturedFeatures.$1;
      capturedDescriptors = capturedFeatures.$2;

      referenceKeypointCount =
          referenceKeypoints.length;

      capturedKeypointCount =
          capturedKeypoints.length;

      // ======================================================
      // STEP 5
      // CHECK IMAGE DETAIL
      //
      // If ORB cannot find enough features, the photo is
      // probably:
      //
      // - blurry
      // - too dark
      // - too plain
      // - object too small
      // ======================================================

      if (referenceKeypointCount <
          minimumUsefulKeypoints ||
          capturedKeypointCount <
              minimumUsefulKeypoints) {
        return TripPathPhotoMatchResult(
          status: TripPathPhotoMatchStatus.retake,
          referenceKeypoints: referenceKeypointCount,
          capturedKeypoints: capturedKeypointCount,
          goodMatches: 0,
          inliers: 0,
          inlierRatio: 0,
          capturedBrightness: capturedBrightness,
          lowLightEnhanced: lowLightEnhanced,
          globalSceneSimilarity: globalSceneSimilarity,
          message: lowLightEnhanced
              ? 'The photo is dim and still does not contain enough stable detail after low-light enhancement. Move closer to better lighting and capture more of the landmark.'
              : 'Not enough visual detail was detected. Take a clearer photo with more visible edges, text or patterns.',
        );
      }

      // ======================================================
      // DESCRIPTOR CHECK
      // ======================================================

      if (referenceDescriptors.isEmpty ||
          capturedDescriptors.isEmpty) {
        return TripPathPhotoMatchResult(
          status: TripPathPhotoMatchStatus.retake,
          referenceKeypoints: referenceKeypointCount,
          capturedKeypoints: capturedKeypointCount,
          goodMatches: 0,
          inliers: 0,
          inlierRatio: 0,
          message:
          'Feature descriptors could not be created. Please retake a clearer photo.',
        );
      }

      // ======================================================
      // STEP 6
      // BF MATCHER
      //
      // ORB produces binary descriptors.
      //
      // Therefore:
      //
      // NORM_HAMMING ✅
      // NORM_L2      ❌
      // ======================================================

      matcher = cv.BFMatcher.create(
        type: cv.NORM_HAMMING,
        crossCheck: false,
      );

      // ======================================================
      // STEP 7
      // KNN MATCH
      //
      // For every reference descriptor:
      //
      // nearest match
      // +
      // second nearest match
      // ======================================================

      knnMatches = matcher.knnMatch(
        referenceDescriptors,
        capturedDescriptors,
        2,
      );
      reverseMatches = matcher.knnMatch(capturedDescriptors, referenceDescriptors, 2);

      // ======================================================
      // STEP 8
      // LOWE RATIO TEST
      //
      // Keep match if:
      //
      // nearest.distance
      // <
      // 0.75 × secondNearest.distance
      //
      // This removes ambiguous matches.
      // ======================================================

      final List<
          ({
          int queryIndex,
          int trainIndex,
          double distance,
          })> goodMatches = [];

      for (var i = 0;
      i < knnMatches.length;
      i++) {
        final candidates = knnMatches[i];

        if (candidates.length < 2) {
          continue;
        }

        final nearest = candidates[0];
        final secondNearest = candidates[1];

        final nearestDistance =
            nearest.distance;

        final secondNearestDistance =
            secondNearest.distance;

        if (secondNearestDistance <= 0) {
          continue;
        }

        if (nearestDistance <
            effectiveRatioTestThreshold *
                secondNearestDistance) {
          final queryIndex =
              nearest.queryIdx;

          final trainIndex =
              nearest.trainIdx;

          // ================================================
          // SAFETY CHECK
          // ================================================

          if (queryIndex < 0 ||
              trainIndex < 0 ||
              queryIndex >=
                  referenceKeypoints.length ||
              trainIndex >=
                  capturedKeypoints.length) {
            continue;
          }

          // Reciprocal ratio test: repeated windows/text must not reuse a
          // captured descriptor as evidence for unrelated reference points.
          final reverse = reverseMatches[trainIndex];
          if (reverse.length < 2 || reverse[0].trainIdx != queryIndex ||
              reverse[1].distance <= 0 ||
              reverse[0].distance >=
                  effectiveRatioTestThreshold * reverse[1].distance) {
            continue;
          }
          goodMatches.add(
            (
            queryIndex: queryIndex,
            trainIndex: trainIndex,
            distance: nearestDistance,
            ),
          );
        }
      }

      goodMatchCount = goodMatches.length;

      // ======================================================
      // STEP 9
      // TOO FEW GOOD MATCHES
      //
      // RANSAC requires geometric correspondences.
      // ======================================================

      final minimumGoodMatchesForCurrentProfile = isNatureProfile
          ? 8
          : (isStorefrontProfile
              ? 5
              : minimumMatchesForRansac);

      if (goodMatchCount <
          minimumGoodMatchesForCurrentProfile) {
        // V15: when a physical landmark has almost enough reciprocal matches
        // for RANSAC, a large viewpoint change may be the reason geometry
        // cannot yet be estimated. Treat that narrow borderline as RETAKE,
        // not as proof that the landmark is wrong. Very weak evidence still
        // remains NOT MATCHED. Nature keeps its stricter behavior.
        // V23: stable-facade/global similarity alone is not enough to call
        // an unrelated storefront a camera-quality problem. Before RANSAC can
        // be estimated, only distinctive shared text is strong enough to move
        // a four-match storefront from NOT MATCHED to RETAKE.
        final borderlineStorefrontTextEvidence =
            isStorefrontProfile &&
            goodMatchCount >= 4 &&
            storefrontTextSimilarity >= 0.72 &&
            storefrontStructureSimilarity >= 0.60 &&
            globalSceneSimilarity >= 0.42;

        // V24: without RANSAC we must be conservative. Coarse storefront
        // structure/global resemblance alone is not enough to call RETAKE,
        // because unrelated shop rows can score surprisingly high. The only
        // OCR-free exception is a lighting-normalized pair with exceptionally
        // strong fixed-facade + whole-frame agreement and almost enough
        // reciprocal correspondences.
        final borderlineStorefrontNightEvidence =
            isStorefrontProfile &&
            lowLightEnhanced &&
            goodMatchCount >= 4 &&
            storefrontStructureSimilarity >= 0.80 &&
            globalSceneSimilarity >= 0.64;

        // V26: before RANSAC exists, descriptor count alone cannot tell a
        // fixed landmark from a temporary foreground object (for example a
        // parked car that also appears in the reference). Require stronger
        // whole-scene corroboration before spending RETAKE on a generic
        // physical-landmark angle case.
        final borderlineGenericViewingAngle =
            isPhysicalProfile &&
            !isStorefrontProfile &&
            goodMatchCount >= 6 &&
            globalSceneSimilarity >= 0.40;

        final borderlineViewingAngle =
            borderlineStorefrontTextEvidence ||
            borderlineStorefrontNightEvidence ||
            borderlineGenericViewingAngle;
        return TripPathPhotoMatchResult(
          status: borderlineViewingAngle
              ? TripPathPhotoMatchStatus.retake
              : TripPathPhotoMatchStatus.notMatched,
          referenceKeypoints:
          referenceKeypointCount,
          capturedKeypoints:
          capturedKeypointCount,
          goodMatches: goodMatchCount,
          inliers: 0,
          inlierRatio: 0,
          capturedBrightness: capturedBrightness,
          capturedDarkBorderFraction: capturedDarkBorderFraction,
          capturedSharpness: capturedSharpness,
          lowLightEnhanced: lowLightEnhanced,
          globalSceneSimilarity: globalSceneSimilarity,
          reasonCode: borderlineStorefrontTextEvidence
              ? 'storefront_insufficient_correspondences'
              : borderlineStorefrontNightEvidence
              ? 'storefront_night_insufficient_correspondences'
              : borderlineViewingAngle
              ? 'viewing_angle_insufficient_correspondences'
              : 'too_few_correspondences',
          message: borderlineStorefrontTextEvidence
              ? 'This may be the same storefront, but there are not enough stable correspondences to verify it safely. Retake with more of the fixed facade and signboard visible.'
              : borderlineStorefrontNightEvidence
              ? 'This may be the same storefront under very different lighting, but there are not enough stable correspondences yet. Retake with the fixed facade and signboard clearly visible.'
              : borderlineViewingAngle
              ? 'Some landmark details are shared, but the viewing angle may be too different to estimate reliable geometry. Retake from a direction closer to the reference photo and keep more of the landmark in frame.'
              : 'This photo does not contain enough reliable shared structure to match the checkpoint. Make sure you are photographing the same physical landmark.',
        );
      }

      // ======================================================
      // STEP 10
      // CREATE MATCHED POINTS
      //
      // Reference:
      //
      // (x1, y1)
      //
      // Camera:
      //
      // (x2, y2)
      // ======================================================

      referenceMatchedPoints =
          cv.VecPoint2f.generate(
            goodMatchCount,
                (index) {
              final match =
              goodMatches[index];

              final keypoint =
              referenceKeypoints![
              match.queryIndex];

              return cv.Point2f(
                keypoint.x,
                keypoint.y,
              );
            },
          );

      capturedMatchedPoints =
          cv.VecPoint2f.generate(
            goodMatchCount,
                (index) {
              final match =
              goodMatches[index];

              final keypoint =
              capturedKeypoints![
              match.trainIndex];

              return cv.Point2f(
                keypoint.x,
                keypoint.y,
              );
            },
          );

      // ======================================================
      // CONVERT POINT VECTORS TO MAT
      //
      // findHomography accepts InputArray.
      // Mat is used here for predictable behaviour.
      // ======================================================

      referenceMatchedPointMat =
          cv.Mat.fromVec(
            referenceMatchedPoints,
          );

      capturedMatchedPointMat =
          cv.Mat.fromVec(
            capturedMatchedPoints,
          );

      // ======================================================
      // STEP 11
      // RANSAC HOMOGRAPHY
      //
      // RANSAC rejects matches that do not agree with the
      // same geometric transformation.
      //
      // This is very important because:
      //
      // ORB descriptor similarity alone can produce
      // false matches.
      // ======================================================

      inlierMask = cv.Mat.empty();

      homography = cv.findHomography(
        referenceMatchedPointMat,
        capturedMatchedPointMat,
        method: cv.HOMOGRAPY_RANSAC,
        ransacReprojThreshold:
        ransacReprojectionThreshold,
        mask: inlierMask,
        maxIters: ransacMaxIterations,
        confidence: ransacConfidence,
      );

      // ======================================================
      // HOMOGRAPHY FAILED
      // ======================================================

      if (homography.isEmpty ||
          inlierMask.isEmpty) {
        // A homography can fail when the camera moves far enough sideways or
        // up/down that a facade becomes strongly foreshortened, or when the
        // visible landmark is not close to a single plane. If there are many
        // reciprocal descriptor correspondences, that is plausible same-place
        // evidence but not enough for a safe MATCHED result, so request a
        // RETAKE. Sparse correspondences still mean NOT MATCHED.
        // V23: if homography itself cannot be formed, facade/global
        // resemblance is only supporting evidence. Many unrelated shop rows
        // have similar horizontal edges. Require distinctive shared OCR for a
        // storefront-specific RETAKE; otherwise fall back to the generic
        // high-correspondence viewing-angle rule below.
        // Legacy V20 name: plausibleStorefrontSamePlace is now split into
        // text/night/angle-specific evidence below.
        final plausibleStorefrontTextSamePlace =
            isStorefrontProfile &&
            goodMatchCount >= 5 &&
            storefrontTextSimilarity >= 0.72 &&
            storefrontStructureSimilarity >= 0.60 &&
            globalSceneSimilarity >= 0.40;

        // V24: a failed homography can be caused by a severe day/night or
        // oblique-view change, but RETAKE still needs strong independent
        // support. This prevents unrelated storefronts from entering RETAKE
        // merely because they have many horizontal edges.
        // Legacy V21 regression thresholds retained in documentation:
        // storefrontStructureSimilarity >= 0.72
        // globalSceneSimilarity >= 0.50
        final plausibleStorefrontNightSamePlace =
            isStorefrontProfile &&
            lowLightEnhanced &&
            goodMatchCount >= 6 &&
            storefrontStructureSimilarity >= 0.78 &&
            globalSceneSimilarity >= 0.58;
        final plausibleStorefrontAngleSamePlace =
            isStorefrontProfile &&
            !lowLightEnhanced &&
            goodMatchCount >= 7 &&
            storefrontStructureSimilarity >= 0.80 &&
            globalSceneSimilarity >= 0.62;

        // V26: failed-homography RETAKE also needs meaningful whole-scene
        // support. This avoids classifying a locally matching temporary
        // object as an angle problem while preserving strong large-angle
        // landmark cases.
        final plausibleGenericLargeViewingAngle =
            isPhysicalProfile &&
            !isStorefrontProfile &&
            goodMatchCount >= 10 &&
            globalSceneSimilarity >= 0.34;

        final plausibleLargeViewingAngle =
            plausibleStorefrontTextSamePlace ||
            plausibleStorefrontNightSamePlace ||
            plausibleStorefrontAngleSamePlace ||
            plausibleGenericLargeViewingAngle;
        return TripPathPhotoMatchResult(
          status: plausibleLargeViewingAngle
              ? TripPathPhotoMatchStatus.retake
              : TripPathPhotoMatchStatus.notMatched,
          referenceKeypoints:
          referenceKeypointCount,
          capturedKeypoints:
          capturedKeypointCount,
          goodMatches: goodMatchCount,
          inliers: 0,
          inlierRatio: 0,
          capturedBrightness: capturedBrightness,
          capturedDarkBorderFraction: capturedDarkBorderFraction,
          capturedSharpness: capturedSharpness,
          lowLightEnhanced: lowLightEnhanced,
          globalSceneSimilarity: globalSceneSimilarity,
          reasonCode: plausibleLargeViewingAngle
              ? 'viewing_angle_geometry_failed'
              : 'homography_failed',
          message: plausibleLargeViewingAngle
              ? 'Several landmark details were found, but the viewing angle is too different for reliable geometric verification. Retake from a direction closer to the reference photo and include more of the same facade.'
              : 'The shared features do not form reliable geometry for the same landmark. Make sure you are photographing the correct physical place.',
        );
      }

      // ======================================================
      // STEP 12
      // COUNT RANSAC INLIERS
      // ======================================================

      inlierCount =
          cv.countNonZero(
            inlierMask,
          );

      if (goodMatchCount > 0) {
        inlierRatio =
            inlierCount /
                goodMatchCount;
      }

      // ======================================================
      // SCENE COVERAGE USING ONLY RANSAC INLIERS
      //
      // A 3x3 grid is intentionally simple and robust. A close crop of
      // only the sign often occupies only the top row in the reference,
      // while a useful storefront/landmark photo spreads inliers across
      // more of the scene.
      // ======================================================

      final referenceInlierPoints =
          <({double x, double y})>[];

      final capturedInlierPoints =
          <({double x, double y})>[];

      for (var i = 0;
          i < goodMatches.length;
          i++) {
        if (!_maskValueIsInlier(
          inlierMask!,
          i,
        )) {
          continue;
        }

        final match =
            goodMatches[i];

        final referencePoint =
            referenceKeypoints![
              match.queryIndex
            ];

        final capturedPoint =
            capturedKeypoints![
              match.trainIndex
            ];

        referenceInlierPoints.add(
          (
            x: referencePoint.x,
            y: referencePoint.y,
          ),
        );

        capturedInlierPoints.add(
          (
            x: capturedPoint.x,
            y: capturedPoint.y,
          ),
        );
      }

      final referenceSpread =
          _gridSpread(
        points: referenceInlierPoints,
        width: referenceImage.cols,
        height: referenceImage.rows,
      );

      final capturedSpread =
          _gridSpread(
        points: capturedInlierPoints,
        width: capturedImage.cols,
        height: capturedImage.rows,
      );

      referenceSceneCoverage = referenceSpread.coverage;
      capturedSceneCoverage = capturedSpread.coverage;
      final evidence = PhotoMatchEvidence(
        themeId: normalizedTheme,
        referenceKind: normalizedReferenceKind,
        goodMatches: goodMatchCount,
        inliers: inlierCount,
        reference: referenceSpread,
        captured: capturedSpread,
        globalSimilarity: globalSceneSimilarity,
        storefrontTextSimilarity: storefrontTextSimilarity,
        storefrontReferenceNameSimilarity: storefrontReferenceNameSimilarity,
        storefrontExpectedNameSimilarity: storefrontExpectedNameSimilarity,
        storefrontIdentityConflict: storefrontIdentityConflict,
        storefrontStructureSimilarity: storefrontStructureSimilarity,
        lightingNormalized: lowLightEnhanced,
      );
      final fusion = TripPathMatchPolicy.fuse(evidence);
      final decision = TripPathMatchPolicy.decide(evidence);
      if (kDebugMode) {
        debugPrint('[PHOTO MATCH] status=${decision.status.name} reason=${decision.reasonCode} '
            'good=$goodMatchCount inliers=$inlierCount ratio=$inlierRatio '
            'refCells=${referenceSpread.occupiedCells} capCells=${capturedSpread.occupiedCells} '
            'refHull=${referenceSpread.hullArea} capHull=${capturedSpread.hullArea} '
            'refSpan=${referenceSpread.widthSpan}x${referenceSpread.heightSpan} '
            'capSpan=${capturedSpread.widthSpan}x${capturedSpread.heightSpan} '
            'global=$globalSceneSimilarity ratioTest=$effectiveRatioTestThreshold '
            'storefrontText=$storefrontTextSimilarity '
            'storefrontRefName=$storefrontReferenceNameSimilarity '
            'storefrontName=$storefrontExpectedNameSimilarity '
            'identityConflict=$storefrontIdentityConflict '
            'storefrontStructure=$storefrontStructureSimilarity '
            'fusion=${fusion.score.toStringAsFixed(3)} '
            'fusionGeometry=${fusion.geometryScore.toStringAsFixed(3)} '
            'fusionFootprint=${fusion.footprintScore.toStringAsFixed(3)} '
            'fusionIdentity=${fusion.identityScore.toStringAsFixed(3)} '
            'darkBorder=$capturedDarkBorderFraction sharpness=$capturedSharpness '
            'CLAHE=$lowLightEnhanced profile=$normalizedTheme/$normalizedReferenceKind');
      }
      return TripPathPhotoMatchResult(
        status: decision.status,
        referenceKeypoints: referenceKeypointCount,
        capturedKeypoints: capturedKeypointCount,
        goodMatches: goodMatchCount,
        inliers: inlierCount,
        inlierRatio: inlierRatio,
        referenceSceneCoverage: referenceSceneCoverage,
        capturedSceneCoverage: capturedSceneCoverage,
        capturedBrightness: capturedBrightness,
        lowLightEnhanced: lowLightEnhanced,
        globalSceneSimilarity: globalSceneSimilarity,
        storefrontTextSimilarity: storefrontTextSimilarity,
        storefrontReferenceNameSimilarity: storefrontReferenceNameSimilarity,
        storefrontExpectedNameSimilarity: storefrontExpectedNameSimilarity,
        storefrontIdentityConflict: storefrontIdentityConflict,
        storefrontStructureSimilarity: storefrontStructureSimilarity,
        reasonCode: decision.reasonCode,
        referenceHullArea: referenceSpread.hullArea,
        capturedHullArea: capturedSpread.hullArea,
        capturedDarkBorderFraction: capturedDarkBorderFraction,
        capturedSharpness: capturedSharpness,
        message: decision.message,
      );
    } catch (error) {
      // ======================================================
      // OPENCV / IMAGE PROCESSING ERROR
      // ======================================================

      return TripPathPhotoMatchResult(
        status: TripPathPhotoMatchStatus.error,
        referenceKeypoints:
        referenceKeypointCount,
        capturedKeypoints:
        capturedKeypointCount,
        goodMatches: goodMatchCount,
        inliers: inlierCount,
        inlierRatio: inlierRatio,
        capturedBrightness:
        capturedBrightness,
        lowLightEnhanced:
        lowLightEnhanced,
        message:
        'Photo verification could not be completed. Please retake the photo and try again.',
      );
    } finally {
      // ======================================================
      // RELEASE NATIVE OPENCV MEMORY
      //
      // Dispose in reverse order of creation.
      // ======================================================

      homography?.dispose();

      inlierMask?.dispose();

      referenceMatchedPointMat?.dispose();

      capturedMatchedPointMat?.dispose();

      referenceMatchedPoints?.dispose();

      capturedMatchedPoints?.dispose();

      knnMatches?.dispose();
      reverseMatches?.dispose();

      matcher?.dispose();

      referenceDescriptors?.dispose();

      capturedDescriptors?.dispose();

      referenceKeypoints?.dispose();

      capturedKeypoints?.dispose();

      featureMask?.dispose();

      orb?.dispose();

      enhancedReferenceImage?.dispose();
      enhancedCapturedImage?.dispose();
      clahe?.dispose();

      referenceImage?.dispose();

      capturedImage?.dispose();
    }
  }


  bool _maskValueIsInlier(
    cv.Mat mask,
    int index,
  ) {
    if (mask.isEmpty ||
        index < 0) {
      return false;
    }

    try {
      if (mask.rows == 1 &&
          index < mask.cols) {
        return mask.atU8(
              0,
              i1: index,
            ) >
            0;
      }

      if (index < mask.rows) {
        return mask.atU8(
              index,
              i1: 0,
            ) >
            0;
      }
    } catch (_) {
      return false;
    }

    return false;
  }

  MatchSpread _gridSpread({
    required List<MatchPoint> points,
    required int width,
    required int height,
  }) => MatchSpread.fromPoints(points, width, height);

  ({double darkBorder, double sharpness}) _captureQuality(cv.Mat gray) {
    cv.Mat? thumb;
    cv.Mat? scaled;
    cv.Mat? laplacian;
    cv.Scalar? mean;
    cv.Scalar? stddev;
    try {
      thumb = cv.resize(gray, (80, 80), interpolation: cv.INTER_AREA);
      final pixels = List<int>.generate(80 * 80,
          (i) => thumb!.atU8(i ~/ 80, i1: i % 80));
      final largestSide = math.max(gray.cols, gray.rows);
      final scale = largestSide <= 640 ? 1.0 : 640 / largestSide;
      scaled = cv.resize(gray,
          (math.max(1, (gray.cols * scale).round()),
           math.max(1, (gray.rows * scale).round())),
          interpolation: cv.INTER_AREA);
      laplacian = cv.laplacian(scaled, cv.MatType.CV_64F);
      final stats = cv.meanStdDev(laplacian);
      mean = stats.$1;
      stddev = stats.$2;
      return (darkBorder: TripPathMatchPolicy.darkBorderFraction(pixels, 80, 80),
          sharpness: stddev.val1 * stddev.val1);
    } finally {
      stddev?.dispose();
      mean?.dispose();
      laplacian?.dispose();
      scaled?.dispose();
      thumb?.dispose();
    }
  }

  // ==========================================================
  // DECODE + RESIZE
  //
  // Image is decoded directly as grayscale.
  //
  // This saves us from:
  //
  // Color image
  // ↓
  // BGR
  // ↓
  // grayscale conversion
  //
  // and makes matching faster.
  // ==========================================================

  cv.Mat _decodeAndResize(
      Uint8List bytes,
      ) {
    final decoded = cv.imdecode(
      bytes,
      cv.IMREAD_GRAYSCALE,
    );

    if (decoded.isEmpty) {
      decoded.dispose();

      throw const FormatException(
        'OpenCV could not decode the image.',
      );
    }

    final width = decoded.cols;
    final height = decoded.rows;

    final largestDimension =
    width > height
        ? width
        : height;

    // ========================================================
    // IMAGE ALREADY SMALL ENOUGH
    // ========================================================

    if (largestDimension <=
        maxImageDimension) {
      return decoded;
    }

    // ========================================================
    // CALCULATE PRESERVED-ASPECT-RATIO SIZE
    // ========================================================

    final scale =
        maxImageDimension /
            largestDimension;

    final resizedWidth =
    (width * scale)
        .round()
        .clamp(
      1,
      maxImageDimension,
    );

    final resizedHeight =
    (height * scale)
        .round()
        .clamp(
      1,
      maxImageDimension,
    );

    cv.Mat? resized;

    try {
      resized = cv.resize(
        decoded,
        (
        resizedWidth,
        resizedHeight,
        ),
        interpolation: cv.INTER_AREA,
      );

      if (resized.isEmpty) {
        resized.dispose();

        throw const FormatException(
          'OpenCV could not resize the image.',
        );
      }

      return resized;
    } finally {
      decoded.dispose();
    }
  }

  bool get _supportsOnDeviceTextRecognition {
    if (kIsWeb) {
      return false;
    }
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  /// V27 storefront text + identity evidence.
  ///
  /// Pair similarity remains supplementary. In addition, when an expected
  /// place name is available we check whether the captured OCR contains
  /// distinctive parts of that name. A hard identity conflict is emitted only
  /// when the reference itself clearly contains the expected name AND the
  /// captured image contains several strong distinctive tokens that do not
  /// match that name. This separates "OCR unavailable" from "OCR says this is
  /// a different shop", which prevents a visually similar neighbouring shop
  /// from passing generic building geometry while preserving night captures
  /// where OCR simply fails.
  Future<_StorefrontTextEvidence> _computeStorefrontTextEvidence(
    Uint8List referenceBytes,
    Uint8List capturedBytes, {
    required String expectedPlaceName,
  }) async {
    if (!_supportsOnDeviceTextRecognition) {
      return const _StorefrontTextEvidence();
    }

    ml_text.TextRecognizer? recognizer;
    try {
      recognizer = ml_text.TextRecognizer(
        script: ml_text.TextRecognitionScript.latin,
      );
      final referenceInput = await _toMlKitTextInputImage(referenceBytes);
      final capturedInput = await _toMlKitTextInputImage(capturedBytes);

      final referenceText = await recognizer
          .processImage(referenceInput)
          .timeout(const Duration(seconds: 8));
      final capturedText = await recognizer
          .processImage(capturedInput)
          .timeout(const Duration(seconds: 8));

      final pairScore = _distinctiveStorefrontTextAgreement(
        referenceText.text,
        capturedText.text,
      );
      final referenceNameScore = _expectedPlaceNameAgreement(
        expectedPlaceName,
        referenceText.text,
      );
      final capturedNameScore = _expectedPlaceNameAgreement(
        expectedPlaceName,
        capturedText.text,
      );
      final capturedHasIndependentIdentity =
          _hasStrongAlternativeStorefrontIdentity(
        expectedPlaceName,
        capturedText.text,
      );
      final identityConflict =
          referenceNameScore >= 0.72 &&
          capturedNameScore < 0.34 &&
          pairScore < 0.50 &&
          capturedHasIndependentIdentity;

      if (kDebugMode) {
        debugPrint(
          '[PHOTO MATCH] storefront OCR agreement='
          '${(pairScore * 100).toStringAsFixed(1)}% '
          'referenceName='
          '${(referenceNameScore * 100).toStringAsFixed(1)}% '
          'expectedName='
          '${(capturedNameScore * 100).toStringAsFixed(1)}% '
          'identityConflict=$identityConflict',
        );
      }
      return _StorefrontTextEvidence(
        pairSimilarity: pairScore,
        referenceNameSimilarity: referenceNameScore,
        expectedNameSimilarity: capturedNameScore,
        identityConflict: identityConflict,
      );
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[PHOTO MATCH] Storefront OCR unavailable: $error');
      }
      return const _StorefrontTextEvidence();
    } finally {
      if (recognizer != null) {
        await recognizer.close();
      }
    }
  }

  // Backwards-compatible helper retained for the V19 regression harness.
  Future<double> _computeStorefrontTextSimilarity(
    Uint8List referenceBytes,
    Uint8List capturedBytes,
  ) async {
    final evidence = await _computeStorefrontTextEvidence(
      referenceBytes,
      capturedBytes,
      expectedPlaceName: '',
    );
    return evidence.pairSimilarity;
  }

  Future<ml_text.InputImage> _toMlKitTextInputImage(
    Uint8List encodedBytes,
  ) async {
    final codec = await ui.instantiateImageCodec(encodedBytes);
    try {
      final frame = await codec.getNextFrame();
      final image = frame.image;
      try {
        final byteData = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        if (byteData == null) {
          throw const FormatException(
            'Unable to convert storefront image to RGBA for text recognition.',
          );
        }
        final rgba = Uint8List.fromList(
          byteData.buffer.asUint8List(
            byteData.offsetInBytes,
            byteData.lengthInBytes,
          ),
        );
        return ml_text.InputImage.fromBitmap(
          bitmap: rgba,
          width: image.width,
          height: image.height,
          rotation: 0,
        );
      } finally {
        image.dispose();
      }
    } finally {
      codec.dispose();
    }
  }

  int _storefrontEditDistance(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;

    var previous = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 1; i <= a.length; i++) {
      final current = List<int>.filled(b.length + 1, 0);
      current[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final substitution = previous[j - 1] +
            (a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1);
        final insertion = current[j - 1] + 1;
        final deletion = previous[j] + 1;
        current[j] = math.min(substitution, math.min(insertion, deletion));
      }
      previous = current;
    }
    return previous[b.length];
  }

  bool _storefrontTokenRelated(String a, String b) {
    if (a == b) return true;
    if (a.length >= 5 && b.length >= 5 && (a.contains(b) || b.contains(a))) {
      return true;
    }
    if (a.length >= 7 && b.length >= 7) {
      final shorter = a.length <= b.length ? a : b;
      final longer = a.length > b.length ? a : b;
      if (longer.endsWith(shorter) || shorter.endsWith(longer)) return true;
    }

    // V29 OCR typo tolerance: storefront signs are frequently read with one
    // wrong character (SURABAYA -> SURABAY4) or, on long names, two errors.
    // Keep this limited to long tokens so short generic words cannot collide.
    final minLength = math.min(a.length, b.length);
    if (minLength >= 6 && (a.length - b.length).abs() <= 2) {
      final distance = _storefrontEditDistance(a, b);
      if (distance <= 1) return true;
      if (minLength >= 9 && distance <= 2) return true;
    }
    return false;
  }

  bool _hasStrongAlternativeStorefrontIdentity(
    String expectedName,
    String observedText,
  ) {
    final expected = _distinctiveStorefrontTokens(expectedName);
    if (expected.isEmpty || observedText.trim().isEmpty) return false;

    // Only treat an independent token as a HARD different-shop identity when
    // it looks like a compact brand/logo. V28 also treated arbitrary long
    // menu/slogan words as an alternative shop name, which caused same-place
    // captures to be rejected whenever OCR missed the actual shop name.
    const generic = <String>{
      'restaurant', 'restoran', 'cafe', 'coffee', 'shop', 'store', 'kedai',
      'food', 'makan', 'open', 'welcome', 'halal', 'menu', 'contact',
      'phone', 'telephone', 'whatsapp', 'level', 'floor', 'jalan', 'smoke',
      'internet', 'wifi', 'free', 'cash', 'card', 'order', 'delivery',
      'authentic', 'original', 'special', 'indonesian', 'malaysia', 'malaysian',
      'kitchen', 'grill', 'bakery', 'seafood', 'chicken', 'rice', 'noodle',
      'noodles', 'nasi', 'ayam', 'goreng', 'since', 'family',
    };

    final rawTokens = RegExp(r"[A-Za-z0-9']{3,}")
        .allMatches(observedText)
        .map((m) => m.group(0)!)
        .toList(growable: false);

    for (final raw in rawTokens) {
      final normalized = raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
      if (normalized.length < 4 || generic.contains(normalized)) continue;
      if (RegExp(r'^\d+$').hasMatch(normalized)) continue;
      if (expected.any((token) => _storefrontTokenRelated(token, normalized))) {
        continue;
      }

      final lettersOnly = raw.replaceAll(RegExp(r'[^A-Za-z]'), '');
      final allCapsBrand = lettersOnly.length >= 4 &&
          lettersOnly.length <= 14 &&
          lettersOnly == lettersOnly.toUpperCase();
      if (allCapsBrand) return true;
    }

    return false;
  }

  double _expectedPlaceNameAgreement(String expectedName, String observedText) {
    final expected = _distinctiveStorefrontTokens(expectedName);
    final observed = _distinctiveStorefrontTokens(observedText);
    if (expected.isEmpty || observed.isEmpty) {
      return 0;
    }

    var matched = 0;
    for (final expectedToken in expected) {
      if (observed.any((token) => _storefrontTokenRelated(expectedToken, token))) {
        matched++;
      }
    }
    if (matched == 0) return 0;
    if (matched >= 2) return 1;
    final token = expected.firstWhere(
      (expectedToken) => observed.any((token) => _storefrontTokenRelated(expectedToken, token)),
    );
    return token.length >= 7 ? 0.82 : 0.68;
  }

  double _distinctiveStorefrontTextAgreement(String a, String b) {
    final left = _distinctiveStorefrontTokens(a);
    final right = _distinctiveStorefrontTokens(b);
    if (left.isEmpty || right.isEmpty) {
      return 0;
    }

    final shared = left.intersection(right);
    if (shared.length >= 3) {
      return 1;
    }
    if (shared.length == 2) {
      return 0.88;
    }
    if (shared.length == 1 && shared.first.length >= 8) {
      return 0.76;
    }
    return 0;
  }

  Set<String> _distinctiveStorefrontTokens(String value) {
    const generic = <String>{
      'restaurant',
      'restoran',
      'cafe',
      'coffee',
      'shop',
      'store',
      'kedai',
      'food',
      'makan',
      'open',
      'welcome',
      'halal',
      'menu',
    };

    final normalized = value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim();
    if (normalized.isEmpty) {
      return <String>{};
    }

    return normalized
        .split(RegExp(r'\s+'))
        .where((token) =>
            token.length >= 3 &&
            !generic.contains(token) &&
            !RegExp(r'^\d+$').hasMatch(token))
        .toSet();
  }

  /// V20 stable storefront-structure descriptor.
  ///
  /// The lower foreground of a real shop can change completely between the
  /// Google reference and the player's camera photo (people, tables, cars,
  /// motorcycles). For storefront references we therefore compare edge
  /// structure in the upper 75% of both frames as an independent supporting
  /// signal. Edges are computed after per-image luminance normalization, which
  /// also makes this signal less sensitive to day/night brightness changes.
  ///
  /// This score can NEVER verify a photo by itself. The policy only consumes
  /// it alongside distinctive storefront OCR and successful RANSAC geometry.
  Future<double> _computeStorefrontStructureSimilarity(
    Uint8List referenceBytes,
    Uint8List capturedBytes,
  ) async {
    try {
      final reference = await _buildGlobalSceneDescriptor(
        referenceBytes,
        activeHeightFraction: 0.75,
      );
      final captured = await _buildGlobalSceneDescriptor(
        capturedBytes,
        activeHeightFraction: 0.75,
      );
      final score = math.max(0.0, _cosine(reference.edges, captured.edges));
      if (kDebugMode) {
        debugPrint(
          '[PHOTO MATCH] storefront stable-structure similarity='
          '${(score * 100).toStringAsFixed(1)}%',
        );
      }
      return score.clamp(0.0, 1.0).toDouble();
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[PHOTO MATCH] Storefront structure descriptor failed: $error');
      }
      return 0;
    }
  }

  /// V45 transient-object-resistant scene pass.
  ///
  /// We intentionally avoid introducing a new bounding-box detector here
  /// because the current project already has a stable local CV pipeline and
  /// no object-detection dependency is required for this improvement.
  /// Instead, the scene descriptor is recomputed on the upper/stable band,
  /// where pedestrians, parked vehicles and movable foreground clutter are
  /// less likely to dominate.
  Future<double> _computeDynamicSuppressedSceneSimilarity(
    Uint8List referenceBytes,
    Uint8List capturedBytes, {
    required String themeId,
    required String referenceKind,
  }) async {
    try {
      final theme = themeId.trim().toLowerCase();
      final kind = referenceKind.trim().toLowerCase();

      final activeHeightFraction = kind == 'storefront_exterior' ||
              kind == 'food_stall_or_kiosk' ||
              theme == 'food'
          ? 0.72
          : (theme == 'nature' || kind.startsWith('nature_'))
              ? 0.88
              : const {'culture', 'heritage'}.contains(theme)
                  ? 0.80
                  : 0.82;

      final reference = await _buildGlobalSceneDescriptor(
        referenceBytes,
        activeHeightFraction: activeHeightFraction,
      );
      final captured = await _buildGlobalSceneDescriptor(
        capturedBytes,
        activeHeightFraction: activeHeightFraction,
      );

      final luminance =
          (_cosine(reference.luminance, captured.luminance) + 1) / 2;
      final edges = math.max(0.0, _cosine(reference.edges, captured.edges));
      final saturation =
          math.max(0.0, _cosine(reference.saturation, captured.saturation));
      final rows = (_cosine(reference.rows, captured.rows) + 1) / 2;
      final columns = (_cosine(reference.columns, captured.columns) + 1) / 2;

      final score = luminance * 0.24 +
          edges * 0.42 +
          saturation * 0.06 +
          rows * 0.14 +
          columns * 0.14;

      return score.clamp(0.0, 1.0).toDouble();
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[V45 STATIC SCENE] stable-band analysis failed: $error');
      }
      return 0;
    }
  }

  /// Fuse the full frame with the transient-suppressed pass conservatively.
  ///
  /// The stable pass may recover evidence lost behind people/vehicles, but
  /// its contribution is capped so a generic skyline/upper wall cannot turn
  /// an unrelated image into a plausible same-place result.
  double _fuseDynamicSuppressedScene({
    required double fullScene,
    required double stableScene,
    required String themeId,
    required String referenceKind,
  }) {
    if (stableScene <= fullScene) {
      return fullScene.clamp(0.0, 1.0).toDouble();
    }

    final theme = themeId.trim().toLowerCase();
    final kind = referenceKind.trim().toLowerCase();
    final maxLift = kind == 'storefront_exterior' ||
            kind == 'food_stall_or_kiosk' ||
            theme == 'food'
        ? 0.10
        : (theme == 'nature' || kind.startsWith('nature_'))
            ? 0.07
            : 0.09;

    final proposedLift = (stableScene - fullScene) * 0.55;
    final lift = math.min(maxLift, proposedLift);
    return (fullScene + lift).clamp(0.0, 1.0).toDouble();
  }

  Future<double> _computeGlobalSceneSimilarity(
    Uint8List referenceBytes,
    Uint8List capturedBytes,
  ) async {
    try {
      final reference = await _buildGlobalSceneDescriptor(referenceBytes);
      final captured = await _buildGlobalSceneDescriptor(capturedBytes);

      final luminance = (_cosine(reference.luminance, captured.luminance) + 1) / 2;
      final edges = math.max(0.0, _cosine(reference.edges, captured.edges));
      final saturation = math.max(0.0, _cosine(reference.saturation, captured.saturation));
      final rows = (_cosine(reference.rows, captured.rows) + 1) / 2;
      final columns = (_cosine(reference.columns, captured.columns) + 1) / 2;

      final score =
          luminance * 0.35 +
          edges * 0.30 +
          saturation * 0.10 +
          rows * 0.125 +
          columns * 0.125;
      return score.clamp(0.0, 1.0).toDouble();
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[PHOTO MATCH] Global scene descriptor failed: $error');
      }
      return 0;
    }
  }

  Future<_GlobalSceneDescriptor> _buildGlobalSceneDescriptor(
    Uint8List bytes, {
    double activeHeightFraction = 1.0,
  }) async {
    ui.Codec? codec;
    ui.Image? image;
    try {
      codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: 48,
        targetHeight: 32,
      );
      final frame = await codec.getNextFrame();
      image = frame.image;
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) {
        throw StateError('Could not decode scene pixels.');
      }

      final width = image.width;
      final fullHeight = image.height;
      final safeHeightFraction =
          activeHeightFraction.clamp(0.50, 1.0).toDouble();
      final height = math.max(
        16,
        math.min(fullHeight, (fullHeight * safeHeightFraction).round()),
      );
      final count = width * height;
      final gray = List<double>.filled(count, 0);
      final saturation = List<double>.filled(count, 0);
      var mean = 0.0;

      for (var i = 0; i < count; i++) {
        final offset = i * 4;
        final r = data.getUint8(offset).toDouble() / 255.0;
        final g = data.getUint8(offset + 1).toDouble() / 255.0;
        final b = data.getUint8(offset + 2).toDouble() / 255.0;
        final lum = 0.299 * r + 0.587 * g + 0.114 * b;
        gray[i] = lum;
        mean += lum;
        final maxChannel = math.max(r, math.max(g, b));
        final minChannel = math.min(r, math.min(g, b));
        saturation[i] = maxChannel <= 0 ? 0 : (maxChannel - minChannel) / maxChannel;
      }
      mean /= count;

      var variance = 0.0;
      for (final value in gray) {
        final delta = value - mean;
        variance += delta * delta;
      }
      final std = math.sqrt(variance / count).clamp(0.02, 1.0).toDouble();
      final normalized = gray.map((value) => (value - mean) / std).toList(growable: false);

      final edge = List<double>.filled(count, 0);
      for (var y = 1; y < height; y++) {
        for (var x = 1; x < width; x++) {
          final i = y * width + x;
          edge[i] = (normalized[i] - normalized[i - 1]).abs() +
              (normalized[i] - normalized[i - width]).abs();
        }
      }

      return _GlobalSceneDescriptor(
        luminance: _poolGrid(normalized, width, height, 12, 8),
        edges: _poolGrid(edge, width, height, 12, 8),
        saturation: _poolGrid(saturation, width, height, 6, 4),
        rows: _poolRows(normalized, width, height, 16),
        columns: _poolColumns(normalized, width, height, 16),
      );
    } finally {
      image?.dispose();
      codec?.dispose();
    }
  }

  List<double> _poolGrid(
    List<double> values,
    int width,
    int height,
    int columns,
    int rows,
  ) {
    final output = <double>[];
    for (var gy = 0; gy < rows; gy++) {
      final y0 = (gy * height / rows).floor();
      final y1 = math.max(y0 + 1, ((gy + 1) * height / rows).floor());
      for (var gx = 0; gx < columns; gx++) {
        final x0 = (gx * width / columns).floor();
        final x1 = math.max(x0 + 1, ((gx + 1) * width / columns).floor());
        var sum = 0.0;
        var n = 0;
        for (var y = y0; y < math.min(y1, height); y++) {
          for (var x = x0; x < math.min(x1, width); x++) {
            sum += values[y * width + x];
            n++;
          }
        }
        output.add(n == 0 ? 0 : sum / n);
      }
    }
    return output;
  }

  List<double> _poolRows(
    List<double> values,
    int width,
    int height,
    int bins,
  ) {
    final result = <double>[];
    for (var b = 0; b < bins; b++) {
      final y0 = (b * height / bins).floor();
      final y1 = math.max(y0 + 1, ((b + 1) * height / bins).floor());
      var sum = 0.0;
      var n = 0;
      for (var y = y0; y < math.min(y1, height); y++) {
        for (var x = 0; x < width; x++) {
          sum += values[y * width + x];
          n++;
        }
      }
      result.add(n == 0 ? 0 : sum / n);
    }
    return result;
  }

  List<double> _poolColumns(
    List<double> values,
    int width,
    int height,
    int bins,
  ) {
    final result = <double>[];
    for (var b = 0; b < bins; b++) {
      final x0 = (b * width / bins).floor();
      final x1 = math.max(x0 + 1, ((b + 1) * width / bins).floor());
      var sum = 0.0;
      var n = 0;
      for (var y = 0; y < height; y++) {
        for (var x = x0; x < math.min(x1, width); x++) {
          sum += values[y * width + x];
          n++;
        }
      }
      result.add(n == 0 ? 0 : sum / n);
    }
    return result;
  }

  double _cosine(List<double> a, List<double> b) {
    if (a.length != b.length || a.isEmpty) return 0;
    var dot = 0.0;
    var aa = 0.0;
    var bb = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      aa += a[i] * a[i];
      bb += b[i] * b[i];
    }
    final denominator = math.sqrt(aa) * math.sqrt(bb);
    if (denominator <= 1e-9) return 0;
    return (dot / denominator).clamp(-1.0, 1.0).toDouble();
  }


  // ==========================================================
  // V46 INDOOR / OUTDOOR CONTEXT CLASSIFICATION
  // ==========================================================

  bool get _supportsOnDeviceImageLabeling {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  Future<_SceneContextEvidence> _computeSceneContextEvidence(
    Uint8List referenceBytes,
    Uint8List capturedBytes,
  ) async {
    if (!_supportsOnDeviceImageLabeling) {
      return const _SceneContextEvidence();
    }

    ml_label.ImageLabeler? labeler;
    try {
      labeler = ml_label.ImageLabeler(
        options: ml_label.ImageLabelerOptions(confidenceThreshold: 0.40),
      );
      final refInput = await _toMlKitLabelInputImage(referenceBytes);
      final capInput = await _toMlKitLabelInputImage(capturedBytes);
      final refLabels = await labeler
          .processImage(refInput)
          .timeout(const Duration(seconds: 10));
      final capLabels = await labeler
          .processImage(capInput)
          .timeout(const Duration(seconds: 10));

      final ref = _evaluateSceneContext(refLabels);
      final cap = _evaluateSceneContext(capLabels);

      if (kDebugMode) {
        debugPrint(
          '[V46 SCENE CONTEXT] reference=${ref.environment} '
          '(in=${ref.indoorScore.toStringAsFixed(2)}, '
          'out=${ref.outdoorScore.toStringAsFixed(2)}) '
          'captured=${cap.environment} '
          '(in=${cap.indoorScore.toStringAsFixed(2)}, '
          'out=${cap.outdoorScore.toStringAsFixed(2)})',
        );
      }

      return _SceneContextEvidence(
        referenceEnvironment: ref.environment,
        capturedEnvironment: cap.environment,
        referenceIndoorScore: ref.indoorScore,
        referenceOutdoorScore: ref.outdoorScore,
        capturedIndoorScore: cap.indoorScore,
        capturedOutdoorScore: cap.outdoorScore,
        capturedPersonScore: cap.personScore,
      );
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[V46 SCENE CONTEXT] unavailable: $error');
      }
      return const _SceneContextEvidence();
    } finally {
      await labeler?.close();
    }
  }

  Future<ml_label.InputImage> _toMlKitLabelInputImage(
    Uint8List encodedBytes,
  ) async {
    final codec = await ui.instantiateImageCodec(encodedBytes);
    try {
      final frame = await codec.getNextFrame();
      final image = frame.image;
      try {
        final byteData = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        if (byteData == null) {
          throw const FormatException(
            'Unable to convert image to RGBA for scene-context analysis.',
          );
        }
        final rgba = Uint8List.fromList(
          byteData.buffer.asUint8List(
            byteData.offsetInBytes,
            byteData.lengthInBytes,
          ),
        );
        return ml_label.InputImage.fromBitmap(
          bitmap: rgba,
          width: image.width,
          height: image.height,
          rotation: 0,
        );
      } finally {
        image.dispose();
      }
    } finally {
      codec.dispose();
    }
  }

  _SingleSceneContext _evaluateSceneContext(
    List<ml_label.ImageLabel> labels,
  ) {
    const indoorWords = <String>{
      'room',
      'interior design',
      'ceiling',
      'floor',
      'furniture',
      'table',
      'chair',
      'dining room',
      'living room',
      'lobby',
      'hall',
      'office',
      'bedroom',
      'kitchen',
      'shelf',
      'shelving',
    };
    const outdoorWords = <String>{
      'sky',
      'road',
      'street',
      'sidewalk',
      'pavement',
      'outdoor',
      'landscape',
      'mountain',
      'hill',
      'forest',
      'park',
      'garden',
      'tree',
      'river',
      'lake',
      'waterfall',
      'bridge',
      'vehicle',
      'car',
      'building',
      'architecture',
      'facade',
      'storefront',
    };
    // V47 — none of the words above fire for "a person using a laptop/
    // phone", so that kind of photo previously scored ~0/0 and landed on
    // 'uncertain', silently passing the environment gate below. This is a
    // separate, unconditional signal: a person-dominated photo is rejected
    // regardless of what the indoor/outdoor words above conclude.
    const personWords = <String>{
      'person',
      'people',
      'face',
      'selfie',
      'human',
      'portrait',
      'man',
      'woman',
      'boy',
      'girl',
      'child',
      'forehead',
      'chin',
      'smile',
    };

    double bestIndoor = 0;
    double bestOutdoor = 0;
    double bestPerson = 0;

    for (final label in labels) {
      final name = label.label
          .trim()
          .toLowerCase()
          .replaceAll(RegExp(r'\s+'), ' ');
      final confidence = label.confidence.clamp(0.0, 1.0).toDouble();

      bool containsKeyword(Set<String> words) {
        for (final word in words) {
          if (name == word || name.contains(word)) return true;
        }
        return false;
      }

      if (containsKeyword(indoorWords)) {
        bestIndoor = math.max(bestIndoor, confidence);
      }
      if (containsKeyword(outdoorWords)) {
        bestOutdoor = math.max(bestOutdoor, confidence);
      }
      if (containsKeyword(personWords)) {
        bestPerson = math.max(bestPerson, confidence);
      }
    }

    String environment = 'uncertain';
    if (bestIndoor >= 0.58 && bestIndoor >= bestOutdoor + 0.08) {
      environment = 'indoor';
    } else if (bestOutdoor >= 0.52 && bestOutdoor + 0.03 >= bestIndoor) {
      environment = 'outdoor';
    } else if (bestIndoor >= 0.46 && bestOutdoor >= 0.46) {
      environment = 'mixed';
    }

    return _SingleSceneContext(
      environment: environment,
      indoorScore: bestIndoor,
      outdoorScore: bestOutdoor,
      personScore: bestPerson,
    );
  }

}

class _GlobalSceneDescriptor {
  final List<double> luminance;
  final List<double> edges;
  final List<double> saturation;
  final List<double> rows;
  final List<double> columns;

  const _GlobalSceneDescriptor({
    required this.luminance,
    required this.edges,
    required this.saturation,
    required this.rows,
    required this.columns,
  });
}
