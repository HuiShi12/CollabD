import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart'
    as ml_label;
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart'
    as ml_text;
import 'package:opencv_dart/opencv_dart.dart' as cv;

import 'gemini_photo_verification.dart';
import 'trip_path_places_service.dart';

class TripPathReferencePhotoSelection {
  final Uint8List bytes;
  final double totalScore;
  final int width;
  final int height;
  final int keypoints;
  final double featureCoverage;
  final double sharpnessVariance;

  // Local semantic screening metadata.
  final double semanticScore;
  final bool ocrNameMatched;
  final List<String> semanticLabels;

  // Semantic suitability for real-world quest verification.
  // Tier 1 = preferred stable exterior/landmark reference.
  // Tier 2 = acceptable fallback (mainly nature scenes).
  // Larger values should not be used as a checkpoint reference.
  final int suitabilityTier;
  final String referenceKind;
  final double suitabilityScore;
  final bool strongOutdoorContext;

  // Stable, locally-computed perceptual fingerprint of the selected image.
  // This is safe to persist because it is our own derived data, not a Google
  // photo resource name/URI or cached image bytes. It lets a resumed quest
  // re-identify the same photo from a fresh Places photos[] list.
  final String referenceFingerprint;

  const TripPathReferencePhotoSelection({
    required this.bytes,
    required this.totalScore,
    required this.width,
    required this.height,
    required this.keypoints,
    required this.featureCoverage,
    required this.sharpnessVariance,
    required this.semanticScore,
    required this.ocrNameMatched,
    required this.semanticLabels,
    required this.suitabilityTier,
    required this.referenceKind,
    required this.suitabilityScore,
    this.strongOutdoorContext = false,
    required this.referenceFingerprint,
  });
}

class TripPathReferencePhotoService {
  final GoogleMapsPlatformService googleMapsPlatformService;

  /// Optional — when supplied, a candidate photo the local ML Kit rules
  /// rejected in a narrow borderline confidence band gets one extra Gemini
  /// vision call asking for a second opinion before it's given up on (see
  /// _ReferenceSemanticAnalysis.eligibleForAiSecondOpinion). Left `null` in
  /// tests or when Gemini isn't configured — the service still works
  /// exactly as before, purely on-device.
  final GeminiPhotoVerificationService? aiSecondOpinionService;

  TripPathReferencePhotoService({
    required this.googleMapsPlatformService,
    this.aiSecondOpinionService,
  });

  // Reuse the on-device ML Kit processors across the whole quest session.
  // Recreating them for every Google Place adds noticeable startup cost.
  ml_label.ImageLabeler? _sharedImageLabeler;
  ml_text.TextRecognizer? _sharedTextRecognizer;
  bool _disposed = false;

  // Maximum number of Google Places photos analysed per landmark.
  static const int maximumCandidates = 5;

  // Initial automatic OpenCV quality-screening thresholds.
  // These should be calibrated later using real landmark photos.
  static const int minimumShortSidePx = 480;
  static const int minimumKeypoints = 120;
  static const double minimumCoverage = 5 / 9;
  static const double minimumSharpnessVariance = 35;
  static const double minimumTotalScore = 55;

  // If a candidate reaches this OpenCV quality score AND passes the
  // theme-aware ML Kit semantic filter, stop requesting more photos.
  static const double immediateAcceptScore = 85;

  // Lightweight local framing preference. A sharp photo can still be
  // zoomed too tightly and show only part of a facade. Weak framing does
  // not hard-reject a candidate; it only prevents premature early-accept
  // while a better Google Places photo may still be available.
  // No extra network/API request is introduced by this score.
  static const double minimumEarlyAcceptFramingScore = 50;

  static const int analysisMaxDimension = 1280;
  static const int orbFeatureCount = 1500;

  // ML Kit's base image-labeling model is local/on-device.
  // OCR is only a bonus signal and is never mandatory.
  static const double mlLabelConfidenceThreshold = 0.45;
  static const double minimumThemePositiveConfidence = 0.50;

  Future<TripPathReferencePhotoSelection?> selectBest({
    required String placeName,
    required String themeId,
    required List<GooglePlacePhotoData> candidates,
    String? preferredFingerprint,
    // Optional per-photo status (not just per-place) so a slow place — up
    // to maximumCandidates photos, each with its own OpenCV/ML Kit/Gemini
    // steps — doesn't leave a caller's loading screen showing the same
    // static "Checking reference photo for X..." line for minutes with no
    // visible sign it's still working.
    void Function(String message)? onProgress,
  }) async {
    if (candidates.isEmpty) {
      _log(
        '$placeName -> REJECT: no Google Places photos.',
      );
      return null;
    }

    _log('');
    _log('========== AUTOMATIC REFERENCE PHOTO ==========');
    _log('Place: $placeName');
    _log('Theme: $themeId');
    _log(
      'Candidates available: ${candidates.length} '
      '(checking sequentially, maximum $maximumCandidates)',
    );
    _log(
      'Pipeline: Google Place photo -> OpenCV quality -> '
      'ML Kit real-world suitability gate -> OCR/context checks -> OpenCV ranking.',
    );

    final normalizedPreferredFingerprint =
        preferredFingerprint?.trim().toLowerCase() ?? '';
    if (normalizedPreferredFingerprint.isNotEmpty) {
      _log(
        'Resume preference: trying to re-identify the previously selected reference via local perceptual fingerprint.',
      );
    }

    if (_disposed) {
      throw StateError(
        'Reference photo service has already been disposed.',
      );
    }

    final mlKitSupported = _isMlKitSupportedPlatform;

    final imageLabeler =
        mlKitSupported
            ? (_sharedImageLabeler ??=
                ml_label.ImageLabeler(
                  options: ml_label.ImageLabelerOptions(
                    confidenceThreshold:
                        mlLabelConfidenceThreshold,
                  ),
                ))
            : null;

    // Nature does not need OCR. For Food / Culture / Heritage the same
    // recognizer is reused across candidates and places.
    final textRecognizer =
        mlKitSupported &&
                themeId.toLowerCase() != 'nature'
            ? (_sharedTextRecognizer ??=
                ml_text.TextRecognizer(
                  script:
                      ml_text.TextRecognitionScript.latin,
                ))
            : null;

    if (!mlKitSupported) {
      throw UnsupportedError('Reference photo screening requires an Android or iOS device.');
    }

    TripPathReferencePhotoSelection? best;
    double bestRank = -1;

    // A candidate whose on-photo text (signage/storefront/entrance sign)
    // actually contains the place's name is a much stronger identity proof
    // than generic theme/quality screening alone. Track the best such
    // candidate separately so it always wins over a same-quality candidate
    // with no name evidence; only fall back to the best overall candidate
    // when nothing in this batch had a legible name match.
    TripPathReferencePhotoSelection? bestNameMatched;
    double bestNameMatchedRank = -1;

    final candidatesToTest = candidates
        .take(maximumCandidates)
        .toList(growable: false);

    for (var index = 0;
        index < candidatesToTest.length;
        index++) {
        final candidate = candidatesToTest[index];

        onProgress?.call(
          'Checking photo ${index + 1}/${candidatesToTest.length} '
          'for $placeName...',
        );

        try {
          // One Google Place Photo request is made here.
          // Candidates are processed sequentially so a strong result
          // can stop the loop early and save further photo requests.
          final bytes = await googleMapsPlatformService
              .downloadPlacePhoto(
            photoResourceName: candidate.name,
            maxWidthPx: 1280,
          );

          // ------------------------------------------------------
          // STEP 1: OpenCV quality screening.
          // ------------------------------------------------------
          //
          // compute() has no built-in timeout — on-device OpenCV work
          // (ORB/feature detection) can pathologically hang on some
          // images/devices with no error ever thrown, which otherwise
          // freezes this whole candidate (and the "Preparing your
          // quest..." screen above it) forever. The outer catch below
          // already treats any failure here as "reject this candidate,
          // try the next one", so timing out is safe to fold into that.

          final analysis = await compute(_analyse,
            bytes,
          ).timeout(const Duration(seconds: 10));

          final qualityAccepted =
              analysis.shortSidePx >= minimumShortSidePx &&
              analysis.keypoints >= minimumKeypoints &&
              analysis.featureCoverage >= minimumCoverage &&
              analysis.sharpnessVariance >=
                  minimumSharpnessVariance &&
              analysis.totalScore >= minimumTotalScore;

          _log(
            'Candidate ${index + 1}/${candidatesToTest.length}: '
            '${analysis.width}x${analysis.height} | '
            'sharp=${analysis.sharpnessVariance.toStringAsFixed(1)} | '
            'ORB=${analysis.keypoints} | '
            'coverage=${(analysis.featureCoverage * 100).toStringAsFixed(0)}% | '
            'framing=${analysis.framingScore.toStringAsFixed(0)} | '
            'quality=${analysis.totalScore.toStringAsFixed(1)} | '
            '${qualityAccepted ? 'QUALITY PASS' : 'QUALITY REJECT'}',
          );

          if (!qualityAccepted) {
            continue;
          }

          // ------------------------------------------------------
          // STEP 2: Theme-aware semantic filtering on-device.
          //
          // Food:
          //   prefer exterior/store/building/signage;
          //   reject food/menu/interior-only/selfie content.
          //
          // Culture:
          //   prefer cultural buildings, art, temples, statues,
          //   architecture and identifiable public places.
          //
          // Heritage:
          //   prefer historic buildings, monuments, temples,
          //   towers, bridges and architectural structures.
          //
          // Nature:
          //   prefer parks, lakes, forests, waterfalls, mountains,
          //   gardens and other outdoor natural scenes.
          //
          // OCR is an OPTIONAL bonus for non-nature themes.
          // ------------------------------------------------------

          var semantic = await _analyseSemantic(
            bytes: bytes,
            placeName: placeName,
            themeId: themeId,
            imageLabeler: imageLabeler,
            textRecognizer: textRecognizer,
            mlKitSupported: mlKitSupported,
            imageWidth: analysis.width,
            imageHeight: analysis.height,
          );

          _log(
            '  Semantic: '
            '${semantic.passed ? 'PASS' : 'REJECT'} | '
            'score=${semantic.semanticScore.toStringAsFixed(0)} | '
            'positive=${semantic.positiveConfidence.toStringAsFixed(2)} | '
            'negative=${semantic.negativeConfidence.toStringAsFixed(2)} | '
            'OCR-name=${semantic.ocrNameMatched ? 'YES' : 'NO'} | '
            'kind=${semantic.referenceKind} | tier=${semantic.suitabilityTier} | '
            'labels=${semantic.labels.isEmpty ? 'none' : semantic.labels.join(', ')} | '
            '${semantic.reason}',
          );

          // Local ML Kit rules rejected this candidate but flagged the call
          // as genuinely borderline (see eligibleForAiSecondOpinion) — spend
          // one Gemini vision call asking for a second opinion before giving
          // up on it. Low-volume by design: only reached for a narrow
          // confidence band just above each reject threshold, never for a
          // confident reject or an unrelated rejection reason.
          if (!semantic.passed &&
              semantic.eligibleForAiSecondOpinion &&
              aiSecondOpinionService != null) {
            try {
              final secondOpinion = await aiSecondOpinionService!
                  .reviewRejectedReferenceCandidate(
                photo: bytes,
                themeId: themeId,
                rejectionReason: semantic.reason,
              ).timeout(const Duration(seconds: 12));

              final overrideAccepted = secondOpinion.rejectionIsWrong &&
                  secondOpinion.recognisable;

              _log(
                '  AI second opinion: '
                '${overrideAccepted ? 'OVERRIDE -> ACCEPT' : secondOpinion.rejectionIsWrong ? 'outdoor but not recognisable -> keep reject' : 'agrees with reject'} '
                '| ${secondOpinion.reason}',
              );

              // Being genuinely outdoor is necessary but not sufficient — a
              // generic corridor, courtyard or car park is outdoor but gives
              // a tourist nothing to recognise the actual place by. Both
              // signals must agree before this rescues a local rejection.
              if (overrideAccepted) {
                semantic = _ReferenceSemanticAnalysis(
                  passed: true,
                  semanticScore: 55,
                  positiveConfidence: semantic.positiveConfidence,
                  negativeConfidence: semantic.negativeConfidence,
                  ocrNameMatched: semantic.ocrNameMatched,
                  labels: semantic.labels,
                  reason: 'AI second opinion overrode local rejection '
                      '(${semantic.reason}): ${secondOpinion.reason}',
                  suitabilityTier: 2,
                  referenceKind: 'ai_reviewed_override',
                  suitabilityScore: 55,
                );
              }
            } catch (error) {
              // Fails closed — keep the original local rejection rather than
              // risk letting a bad photo through on a Gemini/network error.
              _log('  AI second opinion failed, keeping local rejection: $error');
            }
          }

          if (!semantic.passed) {
            continue;
          }

          final fingerprint = await _computePerceptualFingerprint(bytes);
          final fingerprintDistance = normalizedPreferredFingerprint.isEmpty
              ? null
              : _fingerprintHammingDistance(
                  normalizedPreferredFingerprint,
                  fingerprint,
                );

          final selection =
              TripPathReferencePhotoSelection(
            bytes: bytes,
            totalScore: analysis.totalScore,
            width: analysis.width,
            height: analysis.height,
            keypoints: analysis.keypoints,
            featureCoverage: analysis.featureCoverage,
            sharpnessVariance:
                analysis.sharpnessVariance,
            semanticScore: semantic.semanticScore,
            ocrNameMatched: semantic.ocrNameMatched,
            semanticLabels:
                List.unmodifiable(semantic.labels),
            suitabilityTier: semantic.suitabilityTier,
            referenceKind: semantic.referenceKind,
            suitabilityScore: semantic.suitabilityScore,
            strongOutdoorContext: semantic.strongOutdoorContext,
            referenceFingerprint: fingerprint,
          );

          // Use semantic strength plus a small local framing bonus.
          // Framing is deliberately soft because tall towers/statues and
          // nature scenes can legitimately have unusual composition.
          final normalizedTheme =
              themeId.trim().toLowerCase();

          final framingWeight =
              normalizedTheme == 'nature' ? 0.04 : 0.10;

          // Suitability dominates raw ORB quality. A 100-point poster or
          // restaurant interior must never outrank an 80-point storefront.
          // A saved Food fingerprint is only a preference when the fresh
          // candidate still proves an outdoor reference. This prevents an
          // old indoor Food photo from winning forever after the stricter
          // exterior policy is introduced.
          final resumeFingerprintUsable =
              normalizedTheme != 'food' ||
              selection.strongOutdoorContext;

          final resumeFingerprintBonus =
              fingerprintDistance == null ||
                  !resumeFingerprintUsable
              ? 0.0
              : fingerprintDistance <= 4
                  ? 10000.0
                  : fingerprintDistance <= 8
                      ? 5000.0
                      : fingerprintDistance <= 12
                          ? 1200.0
                          : 0.0;

          final candidateRank =
              resumeFingerprintBonus +
              (3 - selection.suitabilityTier) * 1000 +
              selection.suitabilityScore * 3.0 +
              selection.totalScore +
              selection.semanticScore * 0.10 +
              analysis.framingScore * framingWeight +
              // For Food, an outdoor facade is the primary reference. Give
              // outdoor context and a readable logo/name an explicit rank
              // bonus so raw sharpness cannot make an indoor image win.
              (selection.strongOutdoorContext ? 30 : 0) +
              // Nature's OCR bonus is weighted higher than other themes'
              // (60 vs 20): a legible entrance/landmark sign is the closest
              // thing Nature has to Food's storefront signage, and the
              // user asked for it to be a genuine soft preference between
              // otherwise-similar park/garden candidates, not just a
              // symbolic tie-breaker.
              (selection.ocrNameMatched
                  ? (normalizedTheme == 'nature' ? 60 : 20)
                  : 0);

          if (fingerprintDistance != null) {
            _log(
              '  Resume fingerprint: distance=$fingerprintDistance/64 '
              '${fingerprintDistance <= 8 ? 'STRONG SAME-PHOTO CANDIDATE' : 'different/weak'}.',
            );
          }

          // Early accept is now intentionally rare. It is allowed only for
          // Tier-1 stable references (storefront/exterior/monument etc.),
          // never merely because ORB quality is high. This avoids selecting
          // posters and indoor photos before a later storefront is checked.
          final framingStrongEnoughForEarlyAccept =
              normalizedTheme == 'nature' ||
              analysis.framingScore >=
                  minimumEarlyAcceptFramingScore;

          final semanticStrongEnoughForEarlyAccept =
              selection.suitabilityTier == 1 &&
              selection.suitabilityScore >= 82;

          final isVeryStrongResumeMatch =
              fingerprintDistance != null &&
              fingerprintDistance <= 4 &&
              resumeFingerprintUsable;

          // Food photos are especially noisy in Google Places: a listing can
          // start with dishes, menus or interiors before a real storefront.
          // Screen every available Food candidate before selecting one so a
          // later outdoor facade/logo can beat an earlier indoor photo. The
          // exact saved fingerprint remains the only Food early-return path;
          // it avoids re-downloading a known-good reference on resume.
          final allowEarlyAccept =
              normalizedTheme != 'food' ||
              isVeryStrongResumeMatch;

          if ((isVeryStrongResumeMatch ||
                  selection.totalScore >= immediateAcceptScore) &&
              framingStrongEnoughForEarlyAccept &&
              semanticStrongEnoughForEarlyAccept &&
              allowEarlyAccept) {
            _log(
              'EARLY ACCEPT: Tier-1 ${selection.referenceKind} reference | '
              'quality=${selection.totalScore.toStringAsFixed(1)} | '
              'suitability=${selection.suitabilityScore.toStringAsFixed(0)} | '
              'framing=${analysis.framingScore.toStringAsFixed(0)}.',
            );

            _log(
              'RESULT: SELECTED REFERENCE PHOTO | '
              'kind=${selection.referenceKind} | '
              'quality=${selection.totalScore.toStringAsFixed(1)} | '
              'semantic=${selection.semanticScore.toStringAsFixed(0)} | '
              'ORB=${selection.keypoints} | '
              'coverage=${(selection.featureCoverage * 100).toStringAsFixed(0)}%',
            );
            _log(
              '===============================================',
            );

            return selection;
          }

          // Acceptable but not excellent:
          // keep it as fallback and continue checking for a stronger
          // theme-appropriate candidate, up to maximumCandidates.
          if (best == null ||
              candidateRank > bestRank) {
            best = selection;
            bestRank = candidateRank;
          }

          if (selection.ocrNameMatched &&
              (bestNameMatched == null ||
                  candidateRank > bestNameMatchedRank)) {
            bestNameMatched = selection;
            bestNameMatchedRank = candidateRank;
          }
        } catch (error, stackTrace) {
          _log(
            'Candidate ${index + 1}/${candidatesToTest.length}: '
            'ERROR -> $error',
          );

          if (kDebugMode) {
            debugPrintStack(
              label: '[REFERENCE PHOTO] candidate error',
              stackTrace: stackTrace,
            );
          }
        }
      }

    if (best == null) {
      _log(
        'RESULT: REJECT LANDMARK - no candidate passed both '
        'quality and theme-aware semantic screening.',
      );
      _log(
        'The AttractionRepository will continue to the next '
        'Google Place candidate.',
      );
      _log('===============================================');
      return null;
    }

    // Prefer a candidate whose on-photo text actually named this place.
    // Only fall back to the best overall candidate when none of the
    // screened photos had a legible, matching name on them.
    final selected = bestNameMatched ?? best;

    _log(
      'RESULT: SELECTED BEST PHOTO | '
      'kind=${selected.referenceKind} | tier=${selected.suitabilityTier} | '
      'quality=${selected.totalScore.toStringAsFixed(1)} | '
      'semantic=${selected.semanticScore.toStringAsFixed(0)} | '
      'OCR-name=${selected.ocrNameMatched ? 'YES' : 'NO'} '
      '${bestNameMatched != null ? '(preferred: name matched on signage)' : '(fallback: no name match found, best overall used)'} | '
      'ORB=${selected.keypoints} | '
      'coverage=${(selected.featureCoverage * 100).toStringAsFixed(0)}% | '
      'fingerprint=${selected.referenceFingerprint}',
    );
    _log('===============================================');

    return selected;
  }


  // ============================================================
  // LOCAL REFERENCE FINGERPRINT
  //
  // 8x8 average-hash (64 bits). This is deliberately derived locally from
  // decoded pixels and contains no Google photo identifier or image bytes.
  // The same image requested again at a different download size normally
  // remains within a very small Hamming distance.
  // ============================================================

  Future<String> _computePerceptualFingerprint(Uint8List bytes) async {
    ui.Codec? codec;
    ui.Image? image;

    try {
      codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: 8,
        targetHeight: 8,
      );
      final frame = await codec.getNextFrame();
      image = frame.image;
      final data = await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );

      if (data == null || data.lengthInBytes < 8 * 8 * 4) {
        return '';
      }

      final values = <double>[];
      var sum = 0.0;

      for (var i = 0; i < 64; i++) {
        final offset = i * 4;
        final r = data.getUint8(offset).toDouble();
        final g = data.getUint8(offset + 1).toDouble();
        final b = data.getUint8(offset + 2).toDouble();
        final luminance = 0.299 * r + 0.587 * g + 0.114 * b;
        values.add(luminance);
        sum += luminance;
      }

      final average = sum / values.length;
      var result = '';

      for (var nibble = 0; nibble < 16; nibble++) {
        var value = 0;
        for (var bit = 0; bit < 4; bit++) {
          final index = nibble * 4 + bit;
          value = (value << 1) | (values[index] >= average ? 1 : 0);
        }
        result += value.toRadixString(16);
      }

      return result;
    } catch (_) {
      return '';
    } finally {
      image?.dispose();
      codec?.dispose();
    }
  }

  int _fingerprintHammingDistance(String a, String b) {
    if (a.length != 16 || b.length != 16) {
      return 64;
    }

    var distance = 0;
    for (var i = 0; i < 16; i++) {
      final left = int.tryParse(a[i], radix: 16);
      final right = int.tryParse(b[i], radix: 16);
      if (left == null || right == null) {
        return 64;
      }
      var value = left ^ right;
      while (value != 0) {
        distance += value & 1;
        value >>= 1;
      }
    }
    return distance;
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }

    _disposed = true;

    final textRecognizer = _sharedTextRecognizer;
    final imageLabeler = _sharedImageLabeler;

    _sharedTextRecognizer = null;
    _sharedImageLabeler = null;

    if (textRecognizer != null) {
      await textRecognizer.close();
    }

    if (imageLabeler != null) {
      await imageLabeler.close();
    }
  }

  bool get _isMlKitSupportedPlatform {
    if (kIsWeb) {
      return false;
    }

    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  Future<_ReferenceSemanticAnalysis> _analyseSemantic({
    required Uint8List bytes,
    required String placeName,
    required String themeId,
    required ml_label.ImageLabeler? imageLabeler,
    required ml_text.TextRecognizer? textRecognizer,
    required bool mlKitSupported,
    required int imageWidth,
    required int imageHeight,
  }) async {
    // ML Kit plugins are Android/iOS only. Keeping a quality-only
    // fallback lets desktop/web UI debugging continue, while the real
    // phone build uses the semantic gate.
    if (!mlKitSupported || imageLabeler == null) {
      return const _ReferenceSemanticAnalysis(
        passed: false,
        semanticScore: 50,
        positiveConfidence: 0.50,
        negativeConfidence: 0,
        ocrNameMatched: false,
        labels: <String>['ML Kit unavailable - quality-only fallback'],
        reason: 'Reference screening requires Android or iOS; no quality-only acceptance.',
        suitabilityTier: 2,
        referenceKind: 'unknown',
        suitabilityScore: 50,
      );
    }

    try {
      final inputImage =
          await _toMlKitInputImage(
        bytes,
      );

      // Same reasoning as the OpenCV compute() above — a native ML Kit call
      // has no built-in timeout of its own, and a hang here would otherwise
      // freeze this candidate forever with no exception ever thrown.
      final labels =
          await imageLabeler.processImage(
        inputImage,
      ).timeout(const Duration(seconds: 10));

      String recognizedText = '';

      if (textRecognizer != null) {
        try {
          final recognized =
              await textRecognizer.processImage(
            inputImage,
          ).timeout(const Duration(seconds: 8));
          recognizedText = recognized.text;
        } catch (error) {
          // OCR is only a bonus. Its failure must not reject a photo
          // that otherwise has a strong theme-semantic match.
          _log(
            '  OCR bonus unavailable for this candidate: $error',
          );
        }
      }

      return _evaluateThemeSemantic(
        labels: labels,
        recognizedText: recognizedText,
        placeName: placeName,
        themeId: themeId,
        imageWidth: imageWidth,
        imageHeight: imageHeight,
      );
    } catch (error) {
      // On a supported phone build, semantic analysis is a real gate.
      // If it fails, reject this candidate and try the next Google
      // Places photo rather than silently accepting an unknown image.
      return _ReferenceSemanticAnalysis(
        passed: false,
        semanticScore: 0,
        positiveConfidence: 0,
        negativeConfidence: 0,
        ocrNameMatched: false,
        labels: const <String>[],
        reason: 'ML Kit semantic analysis error: $error',
        suitabilityTier: 99,
        referenceKind: 'rejected',
        suitabilityScore: 0,
      );
    }
  }

  Future<ml_label.InputImage> _toMlKitInputImage(
    Uint8List encodedBytes,
  ) async {
    final codec =
        await ui.instantiateImageCodec(
      encodedBytes,
    );

    try {
      final frame =
          await codec.getNextFrame();

      final image = frame.image;

      try {
        final byteData =
            await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );

        if (byteData == null) {
          throw const FormatException(
            'Unable to convert image to RGBA bitmap for ML Kit.',
          );
        }

        final rgba =
            Uint8List.fromList(
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

  _ReferenceSemanticAnalysis _evaluateThemeSemantic({
    required List<ml_label.ImageLabel> labels,
    required String recognizedText,
    required String placeName,
    required String themeId,
    required int imageWidth,
    required int imageHeight,
  }) {
    final policy = _ThemeSemanticPolicy.forTheme(themeId);

    final normalizedLabels = labels
        .map(
          (label) => _SemanticLabel(
            text: label.label.trim(),
            normalized: _normalizeLabel(label.label),
            confidence: label.confidence,
          ),
        )
        .where((label) => label.text.isNotEmpty)
        .toList(growable: false)
      ..sort((a, b) => b.confidence.compareTo(a.confidence));

    final positive = _bestMatchingLabel(
      normalizedLabels,
      policy.positiveKeywords,
    );

    final negative = _bestMatchingLabel(
      normalizedLabels,
      policy.negativeKeywords,
    );

    final hardReject = _bestMatchingLabel(
      normalizedLabels,
      policy.hardRejectKeywords,
    );

    final exterior = _bestMatchingLabel(
      normalizedLabels,
      _stableExteriorKeywords,
    );

    final indoor = _bestMatchingLabel(
      normalizedLabels,
      _indoorSceneKeywords,
    );

    final poster = _bestMatchingLabel(
      normalizedLabels,
      _posterAndGraphicKeywords,
    );

    final durableObject = _bestMatchingLabel(
      normalizedLabels,
      _durableLandmarkKeywords,
    );

    final stableNature = _bestMatchingLabel(
      normalizedLabels,
      _stableNatureKeywords,
    );

    final positiveConfidence = positive?.confidence ?? 0;
    final negativeConfidence = negative?.confidence ?? 0;
    final exteriorConfidence = exterior?.confidence ?? 0;
    final indoorConfidence = indoor?.confidence ?? 0;
    final posterConfidence = poster?.confidence ?? 0;
    final durableConfidence = durableObject?.confidence ?? 0;
    final stableNatureConfidence = stableNature?.confidence ?? 0;
    final outdoorContextConfidence = _bestMatchingLabel(
          normalizedLabels,
          _outdoorContextKeywords,
        )?.confidence ??
        0;

    final ocrNameMatched = policy.allowOcrBonus &&
        _ocrContainsPlaceName(
          recognizedText: recognizedText,
          placeName: placeName,
        );

    final normalizedOcr = _normalizeLabel(recognizedText);
    final rawOcr = recognizedText.toLowerCase();

    final ocrTokenCount = normalizedOcr.isEmpty
        ? 0
        : normalizedOcr
            .split(' ')
            .where((token) => token.trim().isNotEmpty)
            .length;

    final hasPriceText = RegExp(
      r'\b(?:rm|myr)\s*\d+(?:[.,]\d{1,2})?\b|\b\d+(?:[.,]\d{1,2})?\s*(?:rm|myr)\b',
      caseSensitive: false,
    ).hasMatch(rawOcr);

    const promotionWords = <String>{
      'promo',
      'promotion',
      'special',
      'offer',
      'discount',
      'voucher',
      'delivery',
      'order',
      'bucket',
      'combo',
      'set',
      'menu',
      'price',
    };

    final hasPromotionWords = promotionWords.any(
      (word) => (' $normalizedOcr ').contains(' $word '),
    );

    final portraitLike = imageHeight > imageWidth * 1.12;
    final textHeavy = ocrTokenCount >= 18;

    // A promotion/menu/poster can have excellent ORB quality because text,
    // prices and graphics create thousands of corners. Detect it BEFORE the
    // quality score is allowed to influence selection.
    final likelyPosterOrMenu =
        (posterConfidence >= 0.65 &&
            exteriorConfidence < 0.58 &&
            durableConfidence < 0.55) ||
        ((hasPriceText || hasPromotionWords) &&
            (portraitLike || textHeavy) &&
            exteriorConfidence < 0.62) ||
        (negativeConfidence >= 0.72 &&
            posterConfidence >= 0.45 &&
            exteriorConfidence < 0.68);

    _ReferenceSemanticAnalysis reject(
      String reason, {
      bool eligibleForAiSecondOpinion = false,
    }) {
      return _ReferenceSemanticAnalysis(
        passed: false,
        semanticScore: 0,
        positiveConfidence: positiveConfidence,
        negativeConfidence: negativeConfidence,
        ocrNameMatched: ocrNameMatched,
        labels: _displayLabels(normalizedLabels),
        reason: reason,
        suitabilityTier: 99,
        referenceKind: 'rejected',
        suitabilityScore: 0,
        eligibleForAiSecondOpinion: eligibleForAiSecondOpinion,
      );
    }

    _ReferenceSemanticAnalysis accept({
      required String kind,
      required int tier,
      required double suitability,
      required String reason,
      bool strongOutdoorContext = false,
    }) {
      final semanticScore =
          ((positiveConfidence * 100) +
                  (ocrNameMatched ? 10 : 0) +
                  (exteriorConfidence * 15) +
                  (durableConfidence * 10) -
                  (negativeConfidence * 15) -
                  (indoorConfidence * 12))
              .clamp(0.0, 100.0)
              .toDouble();

      return _ReferenceSemanticAnalysis(
        passed: true,
        semanticScore: semanticScore,
        positiveConfidence: positiveConfidence,
        negativeConfidence: negativeConfidence,
        ocrNameMatched: ocrNameMatched,
        labels: _displayLabels(normalizedLabels),
        reason: reason,
        suitabilityTier: tier,
        referenceKind: kind,
        suitabilityScore: suitability.clamp(0.0, 100.0).toDouble(),
        strongOutdoorContext: strongOutdoorContext,
      );
    }

    // Selfies are never suitable reference photos. A generic "person" label
    // may occur in an otherwise excellent storefront and is handled below.
    if (hardReject != null &&
        hardReject.normalized.contains('selfie') &&
        hardReject.confidence >= 0.55) {
      return reject(
        'selfie/person-focused image: ${hardReject.text} '
        '(${hardReject.confidence.toStringAsFixed(2)})',
      );
    }

    final normalizedTheme = themeId.trim().toLowerCase();

    // Check every unwanted label, not only the strongest negative label.
    final transientSubject = _bestMatchingLabel(normalizedLabels, <String>{
      'selfie', 'stage', 'performance', 'concert', 'presentation',
      'audience', 'screenshot', 'poster', 'advertisement',
    });
    if (transientSubject != null && transientSubject.confidence >= 0.50) {
      return reject('temporary event, graphic or screen content');
    }
    final personSubject = _bestMatchingLabel(normalizedLabels, <String>{'person'});
    if (personSubject != null && personSubject.confidence >= 0.70 &&
        outdoorContextConfidence < 0.60) {
      return reject(
        'people-focused scene without clear outdoor context',
        // Below 0.85, ML Kit's "person" call itself is often the uncertain
        // part (e.g. a statue, mannequin or reflection can trigger this) —
        // worth a Gemini second look. At/above 0.85 a real person is almost
        // certainly in frame, so trust the reject outright.
        eligibleForAiSecondOpinion: personSubject.confidence < 0.85,
      );
    }

    if (normalizedTheme == 'food') {
      // ----------------------------------------------------------
      // FOOD REFERENCE POLICY -- POSITIVE PROOF, NOT SCORE RESCUE
      //
      // A Food checkpoint reference must prove that it shows a stable,
      // re-photographable physical place (storefront/stall/kiosk/food truck).
      // Food close-ups, menus, posters and indoor dining scenes are rejected
      // even when ORB/coverage is excellent. OpenCV quality is only used AFTER
      // this semantic gate passes.
      // ----------------------------------------------------------

      if (likelyPosterOrMenu) {
        return reject(
          'promotion/menu/poster-like image; a food checkpoint requires '
          'the physical storefront, stall, kiosk or entrance',
        );
      }

      final foodExteriorConfidence = _bestMatchingLabel(
            normalizedLabels,
            _foodExteriorKeywords,
          )?.confidence ??
          0;

      final strongFoodExteriorConfidence = _bestMatchingLabel(
            normalizedLabels,
            _foodStrongExteriorKeywords,
          )?.confidence ??
          0;

      final stallConfidence = _bestMatchingLabel(
            normalizedLabels,
            _foodStallKeywords,
          )?.confidence ??
          0;

      final broadBuildingConfidence = _bestMatchingLabel(
            normalizedLabels,
            _broadBuildingKeywords,
          )?.confidence ??
          0;

      final logoOrSignConfidence = _bestMatchingLabel(
            normalizedLabels,
            _foodLogoOrSignKeywords,
          )?.confidence ??
          0;

      final foodCloseUpConfidence = _bestMatchingLabel(
            normalizedLabels,
            _foodCloseUpKeywords,
          )?.confidence ??
          0;

      final foodGraphicConfidence = _bestMatchingLabel(
            normalizedLabels,
            _foodGraphicRejectKeywords,
          )?.confidence ??
          0;

      final strongOutdoorContext = outdoorContextConfidence >= 0.48;
      final strongStorefrontSignal = strongFoodExteriorConfidence >= 0.56;
      final strongStallSignal = stallConfidence >= 0.58;
      final strongBuildingSignal = broadBuildingConfidence >= 0.60;

      final hasSceneScaleEvidence =
          strongOutdoorContext ||
          strongBuildingSignal ||
          strongStallSignal;

      // A readable logo/name is useful only when the frame also shows the
      // physical place. A logo/sign close-up must never become the reference
      // by itself, even when OCR and ORB quality are excellent.
      final logoOnlyReference =
          !hasSceneScaleEvidence &&
          logoOrSignConfidence >= 0.60 &&
          (strongFoodExteriorConfidence < 0.66 ||
              strongFoodExteriorConfidence <
                  logoOrSignConfidence + 0.05);

      final nameOnlyReference =
          ocrNameMatched &&
          !hasSceneScaleEvidence &&
          strongFoodExteriorConfidence < 0.66;

      if (logoOnlyReference || nameOnlyReference) {
        return reject(
          'logo/sign-only image; show the complete outdoor storefront, stall or building',
        );
      }

      // A generic label such as "building" or "sign" is too weak by itself.
      // Require independent evidence that the photo is actually an outdoor
      // physical food place. This prevents a plate of food, a menu or a wall
      // poster from being rescued by a misleading generic ML Kit label.
      final storefrontProof =
          strongStorefrontSignal &&
          (strongOutdoorContext || ocrNameMatched);

      final stallProof =
          strongStallSignal &&
          (strongOutdoorContext || ocrNameMatched);

      // Conservative fallback for storefronts when ML Kit only says
      // "building/architecture". The exact Place name must be visible AND
      // there must be outdoor context. This is ideal for photos such as the
      // Banna Thai facade where the shop sign and street are both visible.
      final namedBuildingExteriorProof =
          strongBuildingSignal &&
          ocrNameMatched &&
          strongOutdoorContext &&
          indoorConfidence < 0.45;

      // Covered cafes, hawker counters and shop-house entrances can be
      // labelled as indoor even though the front of the physical place is
      // open and can be photographed from the pavement. Keep this rescue
      // conservative: it still needs a strong storefront/stall signal plus
      // either clear outdoor context or the exact place name. A generic
      // "building"/"sign" label is not enough to rescue an indoor image.
      final openFrontFoodPlaceProof =
          (strongStorefrontSignal || strongStallSignal) &&
          (strongOutdoorContext || ocrNameMatched) &&
          (foodExteriorConfidence >= 0.52 ||
              exteriorConfidence >= 0.48 ||
              strongBuildingSignal);

      final hasPhysicalFoodPlaceProof =
          storefrontProof ||
          stallProof ||
          namedBuildingExteriorProof ||
          openFrontFoodPlaceProof;

      final indoorOverrideProof =
          hasPhysicalFoodPlaceProof &&
          strongOutdoorContext &&
          indoorConfidence < 0.72;

      // Indoor dining scenes are unstable (tables, plants, decor) and may be
      // inaccessible. They never become a reference unless the same frame has
      // overwhelming storefront/stall evidence plus outdoor context.
      if (indoorConfidence >= 0.52 &&
          !indoorOverrideProof) {
        return reject(
          'restaurant interior detected; use an exterior storefront/stall reference',
          // The local indoorOverrideProof rescue already gives up above 0.72
          // (see its own < 0.72 condition), so only ask Gemini below that —
          // a confident >= 0.72 "indoor" call isn't worth a second opinion.
          eligibleForAiSecondOpinion: indoorConfidence < 0.72,
        );
      }

      // Strong food/dish/product evidence is a hard semantic rejection unless
      // the photo simultaneously proves a real exterior. This catches Google
      // listing photos such as mixed-rice plates, burgers, drinks and desserts.
      if (foodCloseUpConfidence >= 0.55) {
        final exteriorClearlyDominates =
            hasPhysicalFoodPlaceProof &&
            (strongOutdoorContext || openFrontFoodPlaceProof) &&
            (strongFoodExteriorConfidence >= 0.66 ||
                stallConfidence >= 0.68) &&
            foodCloseUpConfidence <=
                ((strongFoodExteriorConfidence > stallConfidence
                        ? strongFoodExteriorConfidence
                        : stallConfidence) +
                    0.05);

        if (!exteriorClearlyDominates) {
          return reject(
            'food/dish close-up detected without dominant storefront/stall evidence',
          );
        }
      }

      // Graphic/product content such as menus, advertisements and packaging
      // is not a stable real-world landmark. OCR name matches cannot rescue it.
      if (foodGraphicConfidence >= 0.52 &&
          !(hasPhysicalFoodPlaceProof &&
              (strongOutdoorContext || openFrontFoodPlaceProof) &&
              foodGraphicConfidence < 0.68)) {
        return reject(
          'menu/advertisement/product image is not a stable storefront reference',
        );
      }

      // Portrait food photos are a common Google Places failure mode. Do not
      // reject portrait storefronts blindly, but require much stronger proof.
      if (portraitLike &&
          !ocrNameMatched &&
          !strongStallSignal &&
          strongFoodExteriorConfidence < 0.68) {
        return reject(
          'portrait food-place photo lacks strong storefront/stall identity proof',
        );
      }

      if (!hasPhysicalFoodPlaceProof) {
        return reject(
          'no positive proof of a re-photographable storefront/stall/kiosk exterior',
        );
      }

      // Person labels can occur in a valid storefront. Other hard-reject
      // content must be clearly weaker than the physical-place evidence.
      if (hardReject != null &&
          hardReject.confidence >= 0.65) {
        final hardLabel = hardReject.normalized;
        final personOnly = hardLabel.contains('person');
        final strongestPhysical = <double>[
          strongFoodExteriorConfidence,
          stallConfidence,
          namedBuildingExteriorProof ? broadBuildingConfidence : 0,
        ].reduce((a, b) => a > b ? a : b);

        if ((!personOnly &&
                hardReject.confidence >= strongestPhysical - 0.02) ||
            (personOnly && strongestPhysical < 0.56)) {
          return reject(
            'food/product/person content dominates the physical-place view',
          );
        }
      }

      final kind = stallProof &&
              stallConfidence >= strongFoodExteriorConfidence
          ? 'food_stall_or_kiosk'
          : 'storefront_exterior';

      final strongestPhysical = <double>[
        strongFoodExteriorConfidence,
        stallConfidence,
        namedBuildingExteriorProof ? broadBuildingConfidence : 0,
      ].reduce((a, b) => a > b ? a : b);

      final suitability = 72 +
          strongestPhysical * 24 +
          // Prefer the reference that exposes the real exterior and readable
          // logo/name. This keeps a high-quality indoor dining photo from
          // outranking a slightly less sharp but re-photographable facade.
          (ocrNameMatched ? 14 : 0) +
          (strongOutdoorContext ? 12 : 0) -
          indoorConfidence * 28 -
          foodCloseUpConfidence * 14 -
          foodGraphicConfidence * 12;

      return accept(
        kind: kind,
        tier: 1,
        suitability: suitability,
        strongOutdoorContext: strongOutdoorContext,
        reason:
            'positive proof of a stable food-place exterior suitable for on-site re-photography',
      );
    }

    if (normalizedTheme == 'culture' || normalizedTheme == 'heritage') {
      if (indoorConfidence >= 0.45) {
        return reject(
          'indoor scene: an exterior or fixed public landmark is required',
          eligibleForAiSecondOpinion: indoorConfidence < 0.65,
        );
      }
      if (outdoorContextConfidence < 0.50 && !ocrNameMatched) {
        return reject('insufficient exterior context or place identity');
      }
      if (likelyPosterOrMenu) {
        return reject(
          'poster/graphic content is not a stable physical cultural landmark',
        );
      }

      final culturalExteriorConfidence = _bestMatchingLabel(
            normalizedLabels,
            _cultureHeritageExteriorKeywords,
          )?.confidence ??
          0;

      // Statues, sculptures and murals are valid even when "building" is
      // absent; random museum interiors, rooms and furniture are not.
      final stablePhysical =
          culturalExteriorConfidence > durableConfidence
              ? culturalExteriorConfidence
              : durableConfidence;

      if (indoorConfidence >= 0.62 &&
          stablePhysical < 0.64) {
        return reject(
          'indoor/interior scene without a strong permanent landmark signal',
          eligibleForAiSecondOpinion: indoorConfidence < 0.80,
        );
      }

      if (stablePhysical < 0.65 ||
          positiveConfidence < minimumThemePositiveConfidence) {
        return reject(
          'no confident exterior/monument/permanent landmark signal',
        );
      }

      if (hardReject != null &&
          hardReject.confidence >= 0.72) {
        final hardLabel = hardReject.normalized;
        final personOnly = hardLabel.contains('person');

        if ((!personOnly && stablePhysical < 0.65) ||
            (personOnly && stablePhysical < 0.50)) {
          return reject(
            'person/product content dominates the landmark view',
          );
        }
      }

      final kind = durableConfidence >= culturalExteriorConfidence
          ? 'monument_or_public_art'
          : 'building_exterior';

      final suitability = 70 +
          stablePhysical * 24 +
          (ocrNameMatched ? 5 : 0) -
          indoorConfidence * 12;

      return accept(
        kind: kind,
        tier: 1,
        suitability: suitability,
        reason:
            'stable exterior/permanent landmark suitable for on-site verification',
      );
    }

    if (normalizedTheme == 'nature') {
      if (indoorConfidence >= 0.62) {
        return reject(
          'indoor scene is unsuitable for a nature checkpoint',
          eligibleForAiSecondOpinion: indoorConfidence < 0.80,
        );
      }

      if (positiveConfidence < minimumThemePositiveConfidence) {
        return reject('no confident outdoor/nature scene signal');
      }

      // Person/product content dominating the frame — was gated behind
      // confidence >= 0.78 with an escape hatch at stableNatureConfidence
      // < 0.62, the most lenient combination of any theme (food/culture use
      // 0.65-0.72). That let a selfie or a person standing in front of the
      // scenery through as long as *some* greenery was also visible. 0.55 /
      // 0.70 brings this in line with how aggressively the other themes
      // reject a person occupying most of the frame.
      if (hardReject != null &&
          hardReject.confidence >= 0.55 &&
          stableNatureConfidence < 0.70) {
        return reject('person/product content dominates the nature scene');
      }

      // A legible entrance/park signboard (e.g. "Taman Tasik", "Danau Kota")
      // is a stronger, more specific reference than generic scenery — it
      // proves the exact place, not just "some park somewhere". Preferred
      // over a plain landmark/viewpoint shot whenever OCR actually matched
      // the place name (requires allowOcrBonus: true on this theme's policy,
      // set above — nature used to be the only theme with this switched off).
      if (ocrNameMatched && indoorConfidence < 0.45) {
        return accept(
          kind: 'nature_entrance_signage',
          tier: 1,
          suitability: 88 +
              positiveConfidence * 10 -
              negativeConfidence * 6,
          reason:
              'legible entrance/park signage naming the exact place — preferred over generic scenery',
        );
      }

      // Stable nature anchors (waterfall, mountain, rock, bridge, trail,
      // lookout etc.) are preferred. Generic forest/trees remain usable as
      // fallback because GPS + tolerant verification will support them.
      final isStableNatureReference = stableNatureConfidence >= 0.50;
      if (!isStableNatureReference) {
        return reject('generic vegetation without a stable reference anchor');
      }
      final kind = isStableNatureReference
          ? 'nature_landmark_or_viewpoint'
          : 'nature_landscape';
      final tier = isStableNatureReference ? 1 : 2;

      final suitability = (isStableNatureReference ? 72 : 55) +
          positiveConfidence * 22 +
          stableNatureConfidence * 10 -
          negativeConfidence * 8;

      return accept(
        kind: kind,
        tier: tier,
        suitability: suitability,
        reason: isStableNatureReference
            ? 'stable outdoor nature feature/viewpoint'
            : 'generic nature landscape accepted as fallback',
      );
    }

    // Generic fallback for future themes: require a real stable physical
    // landmark and reject clear indoor/poster content.
    if (likelyPosterOrMenu || indoorConfidence >= 0.68) {
      return reject(
        'image is not a stable exterior physical landmark',
        // A poster/menu call is not ambiguous — only the indoor call can be.
        eligibleForAiSecondOpinion:
            !likelyPosterOrMenu && indoorConfidence < 0.85,
      );
    }

    final genericStable = exteriorConfidence > durableConfidence
        ? exteriorConfidence
        : durableConfidence;

    if (genericStable < 0.50) {
      return reject('no confident stable physical landmark signal');
    }

    return accept(
      kind: durableConfidence >= exteriorConfidence
          ? 'monument_or_public_art'
          : 'building_exterior',
      tier: 1,
      suitability: 70 + genericStable * 25,
      reason: 'stable physical landmark',
    );
  }

  _SemanticLabel? _bestMatchingLabel(
    List<_SemanticLabel> labels,
    Set<String> keywords,
  ) {
    _SemanticLabel? best;

    for (final label in labels) {
      final matches =
          keywords.any(
        (keyword) =>
            _labelMatchesKeyword(
          label.normalized,
          keyword,
        ),
      );

      if (!matches) {
        continue;
      }

      if (best == null ||
          label.confidence >
              best.confidence) {
        best = label;
      }
    }

    return best;
  }

  bool _labelMatchesKeyword(
    String normalizedLabel,
    String keyword,
  ) {
    final normalizedKeyword =
        _normalizeLabel(keyword);

    if (normalizedLabel ==
        normalizedKeyword) {
      return true;
    }

    // Match complete normalized words/phrases instead of arbitrary
    // substrings. For example, keyword "sign" must not match
    // an unrelated label such as "design".
    final paddedLabel =
        ' $normalizedLabel ';
    final paddedKeyword =
        ' $normalizedKeyword ';

    return paddedLabel.contains(
          paddedKeyword,
        ) ||
        paddedKeyword.contains(
          paddedLabel,
        );
  }

  List<String> _displayLabels(
    List<_SemanticLabel> labels,
  ) {
    return labels
        .take(6)
        .map(
          (label) =>
              '${label.text} '
              '${(label.confidence * 100).toStringAsFixed(0)}%',
        )
        .toList(growable: false);
  }

  String _normalizeLabel(
    String value,
  ) {
    return value
        .toLowerCase()
        .replaceAll(
          RegExp(r'[^a-z0-9]+'),
          ' ',
        )
        .trim();
  }

  bool _ocrContainsPlaceName({
    required String recognizedText,
    required String placeName,
  }) {
    if (recognizedText.trim().isEmpty ||
        placeName.trim().isEmpty) {
      return false;
    }

    final normalizedOcr =
        ' ${_normalizeLabel(recognizedText)} ';

    final placeTokens =
        _normalizeLabel(placeName)
            .split(' ')
            .where(
              (token) =>
                  token.length >= 4 &&
                  !_genericPlaceNameTokens.contains(
                    token,
                  ),
            )
            .toList(growable: false);

    if (placeTokens.isEmpty) {
      return false;
    }

    // One distinctive place-name token is enough for an OCR bonus.
    // It does not independently prove identity; the photo still comes
    // from the exact Google Place ID listing and must pass OpenCV.
    return placeTokens.any(
      (token) => normalizedOcr.contains(
        ' $token ',
      ),
    );
  }

  static const Set<String>
      _genericPlaceNameTokens = <String>{
    'restaurant',
    'restoran',
    'cafe',
    'coffee',
    'food',
    'market',
    'store',
    'shop',
    'mall',
    'centre',
    'center',
    'hotel',
    'museum',
    'gallery',
    'temple',
    'park',
    'taman',
    'jalan',
    'street',
    'kuala',
    'lumpur',
    'malaysia',
  };

  static _ReferenceAnalysis _analyse(
    Uint8List bytes,
  ) {
    cv.Mat? decoded;
    cv.Mat? analysisImage;
    cv.Mat? laplacian;
    cv.Mat? mask;
    cv.ORB? orb;
    cv.VecKeyPoint? keypoints;
    cv.Scalar? mean;
    cv.Scalar? stddev;

    try {
      decoded = cv.imdecode(
        bytes,
        cv.IMREAD_GRAYSCALE,
      );

      if (decoded.isEmpty) {
        throw const FormatException(
          'OpenCV could not decode reference candidate.',
        );
      }

      final originalWidth = decoded.cols;
      final originalHeight = decoded.rows;
      final shortSide =
          originalWidth < originalHeight
              ? originalWidth
              : originalHeight;

      final largestDimension =
          originalWidth > originalHeight
              ? originalWidth
              : originalHeight;

      if (largestDimension > analysisMaxDimension) {
        final scale =
            analysisMaxDimension /
                largestDimension;

        final resizedWidth =
            (originalWidth * scale)
                .round()
                .clamp(
                  1,
                  analysisMaxDimension,
                )
                .toInt();

        final resizedHeight =
            (originalHeight * scale)
                .round()
                .clamp(
                  1,
                  analysisMaxDimension,
                )
                .toInt();

        analysisImage = cv.resize(
          decoded,
          (
            resizedWidth,
            resizedHeight,
          ),
          interpolation: cv.INTER_AREA,
        );
      } else {
        analysisImage = decoded.clone();
      }

      // --------------------------------------------------------
      // Sharpness: variance of the Laplacian.
      // --------------------------------------------------------

      laplacian = cv.laplacian(
        analysisImage,
        cv.MatType.CV_64F,
      );

      final stats = cv.meanStdDev(
        laplacian,
      );

      mean = stats.$1;
      stddev = stats.$2;

      final sharpnessVariance =
          stddev.val1 * stddev.val1;

      // --------------------------------------------------------
      // ORB keypoints + spatial coverage.
      // --------------------------------------------------------

      orb = cv.ORB.create(
        nFeatures: orbFeatureCount,
        scaleFactor: 1.2,
        nLevels: 8,
        edgeThreshold: 31,
        firstLevel: 0,
        WTA_K: 2,
        scoreType:
            cv.ORBScoreType.HARRIS_SCORE,
        patchSize: 31,
        fastThreshold: 20,
      );

      mask = cv.Mat.empty();
      keypoints = orb.detect(
        analysisImage,
        mask: mask,
      );

      final keypointCount =
          keypoints.length;

      final cellCounts = List<int>.filled(
        9,
        0,
      );

      var borderKeypointCount = 0;

      final width = analysisImage.cols;
      final height = analysisImage.rows;

      if (width > 0 &&
          height > 0) {
        for (var index = 0;
            index < keypointCount;
            index++) {
          final keypoint =
              keypoints[index];

          final normalizedX =
              keypoint.x / width;
          final normalizedY =
              keypoint.y / height;

          final column =
              (normalizedX * 3)
                  .floor()
                  .clamp(0, 2)
                  .toInt();

          final row =
              (normalizedY * 3)
                  .floor()
                  .clamp(0, 2)
                  .toInt();

          cellCounts[
              row * 3 + column]++;

          // Too many strong features touching the outer frame is often a
          // useful hint that the photo is zoomed/cropped very tightly.
          // This remains a ranking hint only, never an independent reject.
          if (normalizedX < 0.12 ||
              normalizedX > 0.88 ||
              normalizedY < 0.12 ||
              normalizedY > 0.88) {
            borderKeypointCount++;
          }
        }
      }

      // A cell needs several keypoints before it counts as useful.
      final occupiedCells = cellCounts
          .where(
            (count) => count >= 5,
          )
          .length;

      final featureCoverage =
          occupiedCells / 9;

      // --------------------------------------------------------
      // Lightweight framing/composition score (0-100).
      //
      // It prefers distributed features, less edge crowding and a
      // non-extreme aspect ratio. This cannot prove that an entire building
      // is visible, but it cheaply reduces the chance of selecting a very
      // tight partial-facade photo without another API/ML request.
      // --------------------------------------------------------

      final borderFeatureRatio =
          keypointCount == 0
              ? 1.0
              : borderKeypointCount / keypointCount;

      final rawAspectRatio =
          originalHeight == 0
              ? 1.0
              : originalWidth / originalHeight;

      final aspectScore =
          rawAspectRatio >= 0.75 &&
                  rawAspectRatio <= 2.20
              ? 100.0
              : rawAspectRatio >= 0.55 &&
                      rawAspectRatio <= 3.00
                  ? 75.0
                  : 45.0;

      final edgeCrowdingPenalty =
          ((borderFeatureRatio - 0.25) / 0.50)
              .clamp(0.0, 1.0)
              .toDouble();

      final edgeContextScore =
          (1.0 - edgeCrowdingPenalty) * 100;

      final framingScore =
          aspectScore * 0.25 +
          edgeContextScore * 0.35 +
          featureCoverage * 100 * 0.40;

      // --------------------------------------------------------
      // 100-point score.
      // Resolution 15% + Sharpness 20% + ORB 35% + Coverage 30%.
      // --------------------------------------------------------

      final resolutionComponent =
          (shortSide / 900)
              .clamp(0.0, 1.0)
              .toDouble() *
              15;

      final sharpnessComponent =
          ((sharpnessVariance - 30) / 270)
              .clamp(0.0, 1.0)
              .toDouble() *
              20;

      final keypointComponent =
          (keypointCount / 600)
              .clamp(0.0, 1.0)
              .toDouble() *
              35;

      final coverageComponent =
          featureCoverage * 30;

      final totalScore =
          resolutionComponent +
          sharpnessComponent +
          keypointComponent +
          coverageComponent;

      return _ReferenceAnalysis(
        width: originalWidth,
        height: originalHeight,
        shortSidePx: shortSide,
        keypoints: keypointCount,
        featureCoverage:
            featureCoverage,
        sharpnessVariance:
            sharpnessVariance,
        framingScore: framingScore,
        totalScore: totalScore,
      );
    } finally {
      stddev?.dispose();
      mean?.dispose();
      keypoints?.dispose();
      orb?.dispose();
      mask?.dispose();
      laplacian?.dispose();
      analysisImage?.dispose();
      decoded?.dispose();
    }
  }

  void _log(
    String message,
  ) {
    if (!kDebugMode) {
      return;
    }

    debugPrint(
      '[REFERENCE PHOTO] $message',
    );
  }
}

class _ReferenceAnalysis {
  final int width;
  final int height;
  final int shortSidePx;
  final int keypoints;
  final double featureCoverage;
  final double sharpnessVariance;
  final double framingScore;
  final double totalScore;

  const _ReferenceAnalysis({
    required this.width,
    required this.height,
    required this.shortSidePx,
    required this.keypoints,
    required this.featureCoverage,
    required this.sharpnessVariance,
    required this.framingScore,
    required this.totalScore,
  });
}


class _ReferenceSemanticAnalysis {
  final bool passed;
  final double semanticScore;
  final double positiveConfidence;
  final double negativeConfidence;
  final bool ocrNameMatched;
  final List<String> labels;
  final String reason;
  final int suitabilityTier;
  final String referenceKind;
  final double suitabilityScore;
  final bool strongOutdoorContext;

  /// True only for a REJECTED result whose "person visible" / "looks indoor"
  /// call sits in a deliberately narrow confidence band just above ML Kit's
  /// reject threshold — i.e. genuinely uncertain, not a confident reject.
  /// The async caller (selectBest) uses this to decide whether it's worth
  /// spending one Gemini vision call asking for a second opinion before
  /// giving up on this candidate photo. Never set for a confident reject
  /// (well above threshold) or for unrelated rejection reasons (poster,
  /// food close-up, wrong theme, etc.) — those are not ambiguous, so asking
  /// Gemini would only spend quota for no benefit.
  final bool eligibleForAiSecondOpinion;

  const _ReferenceSemanticAnalysis({
    required this.passed,
    required this.semanticScore,
    required this.positiveConfidence,
    required this.negativeConfidence,
    required this.ocrNameMatched,
    required this.labels,
    required this.reason,
    required this.suitabilityTier,
    required this.referenceKind,
    required this.suitabilityScore,
    this.strongOutdoorContext = false,
    this.eligibleForAiSecondOpinion = false,
  });
}

class _SemanticLabel {
  final String text;
  final String normalized;
  final double confidence;

  const _SemanticLabel({
    required this.text,
    required this.normalized,
    required this.confidence,
  });
}

const Set<String> _stableExteriorKeywords = <String>{
  'building', 'architecture', 'facade', 'exterior', 'storefront',
  'entrance', 'door', 'window', 'signage', 'sign', 'awning', 'roof',
  'shop', 'store', 'market', 'kiosk', 'stall', 'booth', 'food truck',
  'sidewalk', 'street', 'road', 'infrastructure',
};

// Deliberately EXCLUDES bare "shop"/"store" — ML Kit labels a display
// case, buffet counter or "Grocery store"-style interior shot with the same
// word it would use for the actual outdoor storefront, so treating it as
// exterior evidence let an indoor food-display photo pass as a genuine
// storefront reference. Kept to words that specifically describe the
// building's OUTSIDE (facade, entrance, awning, sidewalk/street context).
const Set<String> _foodExteriorKeywords = <String>{
  'storefront', 'facade', 'exterior', 'entrance', 'door', 'window',
  'signage', 'sign', 'awning',
  'sidewalk', 'street', 'road',
};

// Stronger than the generic exterior set. These labels must describe the
// physical business frontage itself rather than merely a sign/object that may
// appear in a menu, poster or indoor scene. Same "shop"/"store" exclusion as
// _foodExteriorKeywords above.
const Set<String> _foodStrongExteriorKeywords = <String>{
  'storefront', 'shop front', 'facade', 'exterior', 'building exterior',
  'entrance', 'awning', 'commercial building',
};

const Set<String> _foodLogoOrSignKeywords = <String>{
  'logo', 'brand', 'trademark', 'emblem', 'sign', 'signage',
};

// Food/content signals that are excellent for recognising a dish but poor for
// verifying that the player reached a physical restaurant/stall location.
const Set<String> _foodCloseUpKeywords = <String>{
  'food', 'dish', 'meal', 'cuisine', 'plate', 'tableware', 'recipe',
  'ingredient', 'rice', 'noodle', 'noodles', 'soup', 'meat', 'chicken',
  'beef', 'pork', 'fish', 'seafood', 'vegetable', 'fruit', 'dessert',
  'cake', 'bread', 'pastry', 'snack', 'breakfast', 'lunch', 'dinner',
  'fast food', 'burger', 'cheeseburger', 'hot dog', 'pizza', 'beverage',
  'drink', 'juice', 'coffee', 'tea', 'alcohol',
};

const Set<String> _foodGraphicRejectKeywords = <String>{
  'menu', 'poster', 'advertising', 'advertisement', 'graphic design',
  'graphics', 'brochure', 'flyer', 'banner', 'packaging', 'product',
};

const Set<String> _broadBuildingKeywords = <String>{
  'building', 'architecture', 'property', 'real estate', 'house', 'roof',
};

const Set<String> _foodStallKeywords = <String>{
  'stall', 'food stall', 'market stall', 'roadside stall', 'hawker stall',
  'hawker', 'kiosk', 'booth', 'vendor', 'vendor stand', 'street vendor',
  'food truck', 'cart', 'canopy', 'tent',
};

// Deliberately EXCLUDES building-type words like "temple"/"mosque"/
// "church"/"cathedral"/"shrine"/"castle"/"museum" — those name what KIND of
// building it is, not that the CAMERA is outside it. A generic image
// classifier labels an interior shot of a mosque's dome/prayer hall
// "Mosque" just as readily as an exterior facade shot, so treating that
// label as exterior evidence let an interior photo (with a crowd inside)
// score high enough here to bypass every indoor/person rejection gate below
// — see the "Madrasah As-Saadah" real-world case that surfaced this.
// Deliberately excludes 'bridge' — a generic image classifier labels any
// highway overpass/flyover "Bridge" just as readily as a genuine bridge
// landmark, and most Culture/Heritage checkpoints are not bridges at all.
// That let an unrelated highway photo (taken near, but not of, the actual
// checkpoint) score as strong exterior evidence here — see the "Petronas
// Geoscience Centre" real-world case that surfaced this.
const Set<String> _cultureHeritageExteriorKeywords = <String>{
  'building', 'architecture', 'facade', 'exterior', 'entrance', 'door',
  'window', 'roof', 'tower', 'historic site', 'landmark',
};

// Same reasoning as _cultureHeritageExteriorKeywords above — building-type
// words removed since they don't indicate an exterior vantage point, and
// 'bridge' removed since it matches any highway overpass, not just a
// genuine bridge landmark.
const Set<String> _durableLandmarkKeywords = <String>{
  'monument', 'statue', 'sculpture', 'mural', 'tower',
  'landmark', 'historic site',
};

const Set<String> _indoorSceneKeywords = <String>{
  'interior design', 'interior', 'room', 'dining room',
  'furniture', 'table', 'chair', 'couch', 'desk', 'cabinetry', 'shelf',
  'ceiling', 'floor', 'kitchen', 'bedroom', 'bathroom', 'lobby',
};

const Set<String> _posterAndGraphicKeywords = <String>{
  'poster', 'advertising', 'advertisement', 'graphic design', 'graphics',
  'font', 'menu', 'product', 'brochure', 'flyer', 'banner', 'packaging',
};

const Set<String> _outdoorContextKeywords = <String>{
  'sky', 'street', 'road', 'sidewalk', 'pavement', 'outdoor', 'vehicle',
  'car', 'parking', 'tree', 'building exterior',
};

// Deliberately EXCLUDES generic material/texture words like "rock" —
// a macro close-up of wet gravel/pavement can trigger that same label just
// as readily as a genuine, distant, photographable cliff or rock formation,
// with no way for a bare keyword match to tell scale/framing apart. Kept to
// large-scale, recognizable landscape features a close-up shot is very
// unlikely to accidentally trigger.
const Set<String> _stableNatureKeywords = <String>{
  'waterfall', 'mountain', 'cliff', 'cave', 'lake', 'river',
  'beach', 'pier', 'bridge', 'trail', 'dam', 'canyon', 'viewpoint',
  'lookout', 'garden', 'park',
};

class _ThemeSemanticPolicy {
  final String description;
  final Set<String> positiveKeywords;
  final Set<String> negativeKeywords;
  final Set<String> hardRejectKeywords;
  final bool allowOcrBonus;

  const _ThemeSemanticPolicy({
    required this.description,
    required this.positiveKeywords,
    required this.negativeKeywords,
    required this.hardRejectKeywords,
    required this.allowOcrBonus,
  });

  factory _ThemeSemanticPolicy.forTheme(
    String themeId,
  ) {
    switch (themeId.toLowerCase()) {
      case 'food':
        return const _ThemeSemanticPolicy(
          description:
              'storefront/stall/kiosk/physical food-place exterior',
          // Food checkpoints must show a stable physical food place that the
          // player can re-photograph on site. This includes storefronts,
          // roadside/hawker stalls, kiosks, booths and food trucks.
          // Food/menu-only photos do NOT count.
          // Deliberately excludes bare "shop"/"store" — see the matching
          // comment on _foodExteriorKeywords above.
          positiveKeywords: <String>{
            'building',
            'architecture',
            'facade',
            'property',
            'real estate',
            'house',
            'roof',
            'brick',
            'door',
            'window',
            'entrance',
            'storefront',
            'stall',
            'food stall',
            'market stall',
            'roadside stall',
            'hawker stall',
            'hawker',
            'kiosk',
            'booth',
            'vendor',
            'vendor stand',
            'street vendor',
            'food truck',
            'cart',
            'canopy',
            'tent',
            'market',
            'shopping mall',
            'market building',
            'signage',
            'sign',
            'awning',
            'infrastructure',
          },
          negativeKeywords: <String>{
            'food',
            'fast food',
            'meal',
            'cuisine',
            'eating',
            'lunch',
            'supper',
            'dinner',
            'breakfast',
            'menu',
            'bento',
            'cheeseburger',
            'hot dog',
            'cake',
            'pie',
            'vegetable',
            'juice',
            'alcohol',
            'cookware',
            'kitchen',
            'chair',
            'couch',
            'armrest',
            'shelf',
            'cabinetry',
            'desk',
            'bedroom',
            'bathroom',
            'person',
            'product',
          },
          hardRejectKeywords: <String>{
            'selfie',
            'person',
            'human',
            'face',
            'crowd',
            'audience',
            'menu',
            'food',
            'dish',
            'meal',
            'plate',
            'tableware',
            'recipe',
            'ingredient',
            'fast food',
            'cuisine',
            'bento',
            'rice',
            'noodle',
            'noodles',
            'soup',
            'meat',
            'chicken',
            'beef',
            'fish',
            'vegetable',
            'fruit',
            'dessert',
            'burger',
            'cheeseburger',
            'hot dog',
            'pizza',
            'cake',
            'pie',
            'beverage',
            'drink',
            'product',
            'packaging',
            'advertisement',
            'advertising',
            'poster',
          },
          allowOcrBonus: true,
        );

      case 'culture':
        return const _ThemeSemanticPolicy(
          description:
              'cultural building/monument/public landmark',
          // Culture may use a building OR a durable public landmark
          // such as a statue/sculpture/mural that can be matched again.
          // Deliberately excludes building-TYPE words ('temple', 'mosque',
          // 'church', 'cathedral', 'shrine', 'castle', 'museum') — those
          // name what kind of building it is, not that the photo was taken
          // from outside it. A generic classifier labels an interior shot
          // just as readily, which let an interior photo (with a crowd
          // inside) score as strong positive evidence here.
          positiveKeywords: <String>{
            'building',
            'architecture',
            'facade',
            'property',
            'house',
            'roof',
            'brick',
            'door',
            'window',
            'entrance',
            'infrastructure',
            'monument',
            'statue',
            'sculpture',
            'mural',
            'tower',
            'landmark',
          },
          negativeKeywords: <String>{
            'selfie',
            'person',
            'food',
            'meal',
            'cuisine',
            'menu',
            'eating',
            'kitchen',
            'bedroom',
            'bathroom',
            'chair',
            'couch',
            'desk',
            'product',
            'receipt',
          },
          hardRejectKeywords: <String>{
            'selfie',
            'person',
            'human',
            'face',
            'crowd',
            'audience',
            'menu',
            'meal',
            'fast food',
            'product',
          },
          allowOcrBonus: true,
        );

      case 'heritage':
        return const _ThemeSemanticPolicy(
          description:
              'historic building/monument/architecture',
          // Deliberately excludes building-TYPE words ('temple', 'mosque',
          // 'church', 'cathedral', 'shrine', 'castle', 'museum') — see the
          // matching comment on the 'culture' case above.
          positiveKeywords: <String>{
            'building',
            'architecture',
            'facade',
            'property',
            'house',
            'roof',
            'brick',
            'door',
            'window',
            'entrance',
            'infrastructure',
            'monument',
            'statue',
            'sculpture',
            'tower',
            'landmark',
            'historic site',
          },
          negativeKeywords: <String>{
            'selfie',
            'person',
            'food',
            'meal',
            'cuisine',
            'menu',
            'eating',
            'kitchen',
            'bedroom',
            'bathroom',
            'chair',
            'couch',
            'desk',
            'product',
            'receipt',
          },
          hardRejectKeywords: <String>{
            'selfie',
            'person',
            'human',
            'face',
            'crowd',
            'audience',
            'menu',
            'meal',
            'fast food',
            'product',
          },
          allowOcrBonus: true,
        );

      case 'nature':
        return const _ThemeSemanticPolicy(
          description:
              'park/natural outdoor landscape',
          // Nature does not require a building, but it must still show
          // a stable outdoor scene that a player can re-photograph.
          // Deliberately excludes "rock" — see the matching comment on
          // _stableNatureKeywords above.
          positiveKeywords: <String>{
            'park',
            'landscape',
            'sky',
            'cliff',
            'reef',
            'cave',
            'jungle',
            'dune',
            'desert',
            'waterfall',
            'canyon',
            'swamp',
            'garden',
            'field',
            'flower',
            'prairie',
            'beach',
            'lake',
            'mountain',
            'forest',
            'tree',
            'plant',
            'grass',
            'river',
            'water',
            'dam',
            'pier',
            'trail',
          },
          negativeKeywords: <String>{
            'selfie',
            'person',
            'food',
            'meal',
            'cuisine',
            'menu',
            'eating',
            'kitchen',
            'bedroom',
            'bathroom',
            'chair',
            'couch',
            'desk',
            'product',
            'receipt',
            'vehicle',
            'car',
          },
          hardRejectKeywords: <String>{
            'selfie',
            'person',
            'human',
            'face',
            'crowd',
            'audience',
            'menu',
            'meal',
            'fast food',
            'product',
          },
          // Was false: nature was the only theme ignoring OCR entirely, so a
          // legible park/forest entrance signboard (e.g. "Taman Tasik",
          // "Danau Kota") never got any credit for proving a real, specific
          // place — it scored the same as an anonymous patch of trees. Now
          // matches every other theme's OCR-bonus handling.
          allowOcrBonus: true,
        );

      default:
        return const _ThemeSemanticPolicy(
          description:
              'recognizable physical landmark/exterior',
          positiveKeywords: <String>{
            'building',
            'architecture',
            'facade',
            'property',
            'house',
            'infrastructure',
            'temple',
            'mosque',
            'church',
            'cathedral',
            'castle',
            'museum',
            'monument',
            'statue',
            'sculpture',
            'tower',
            'bridge',
            'landmark',
            'park',
            'garden',
            'waterfall',
            'mountain',
            'lake',
          },
          negativeKeywords: <String>{
            'selfie',
            'person',
            'food',
            'meal',
            'menu',
            'kitchen',
            'bedroom',
            'bathroom',
            'product',
          },
          hardRejectKeywords: <String>{
            'selfie',
            'person',
            'human',
            'face',
            'crowd',
            'audience',
            'menu',
            'meal',
            'product',
          },
          allowOcrBonus: true,
        );
    }
  }
}
