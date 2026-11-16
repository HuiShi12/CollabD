import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../../Data_layer/service/Trip Path Quest Service/trip_path_photo_match_service.dart';
import '../../../Data_layer/service/Trip Path Quest Service/gemini_photo_verification.dart';

// ============================================================
// TRIP PATH QUEST - PHOTO VERIFICATION VIEWMODEL
//
// Responsibilities:
//
// CAMERA
// - Open real phone camera
// - Keep captured photo for preview
// - Retake photo
// - Recover lost Android camera result
// - Camera loading/error state
//
// PHOTO VERIFICATION
// - Receive Reference Photo bytes from View
// - Send Reference Photo + Camera Photo to OpenCV service
// - Store MATCHED / RETAKE / NOT MATCHED result
// - Expose verification loading/result state to View
//
// IMPORTANT:
//
// Reference Photo selection is still handled by the View
// temporarily for local testing.
//
// Later:
// Gallery Reference
// ↓
// Google Places Reference Photo
// ============================================================

class TripPathQuestPhotoVerificationViewModel extends ChangeNotifier {
  bool _disposed = false;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
  // ============================================================
  // DEPENDENCIES
  // ============================================================

  final ImagePicker _imagePicker;

  final TripPathPhotoMatchService _photoMatchService;
  final GeminiPhotoVerificationService _geminiPhotoVerificationService;

  TripPathQuestPhotoVerificationViewModel({
    ImagePicker? imagePicker,
    TripPathPhotoMatchService? photoMatchService,
    GeminiPhotoVerificationService? geminiPhotoVerificationService,
  })  : _imagePicker = imagePicker ?? ImagePicker(),
        _photoMatchService = photoMatchService ?? TripPathPhotoMatchService(),
        _geminiPhotoVerificationService = geminiPhotoVerificationService ?? GeminiPhotoVerificationService();

  // ============================================================
  // CAMERA PHOTO STATE
  // ============================================================

  XFile? _capturedPhoto;

  Uint8List? _capturedPhotoBytes;

  bool _isOpeningCamera = false;

  String? _cameraError;

  // ============================================================
  // VERIFICATION STATE
  // ============================================================

  bool _isVerifying = false;

  TripPathPhotoMatchResult? _verificationResult;

  String? _verificationError;

  // ============================================================
  // CAMERA GETTERS
  // ============================================================

  bool get hasPhoto {
    return _capturedPhoto != null &&
        _capturedPhotoBytes != null &&
        _capturedPhotoBytes!.isNotEmpty;
  }

  Uint8List? get photoBytes {
    return _capturedPhotoBytes;
  }

  XFile? get photoFile {
    return _capturedPhoto;
  }

  String? get photoPath {
    return _capturedPhoto?.path;
  }

  bool get isOpeningCamera {
    return _isOpeningCamera;
  }

  String? get cameraError {
    return _cameraError;
  }

  // ============================================================
  // VERIFICATION GETTERS
  // ============================================================

  bool get isVerifying {
    return _isVerifying;
  }

  TripPathPhotoMatchResult? get verificationResult {
    return _verificationResult;
  }

  String? get verificationError {
    return _verificationError;
  }

  bool get hasVerificationResult {
    return _verificationResult != null;
  }

  bool get verificationMatched {
    return _verificationResult?.status ==
        TripPathPhotoMatchStatus.matched;
  }

  bool get verificationNeedsRetake {
    return _verificationResult?.status ==
        TripPathPhotoMatchStatus.retake;
  }

  bool get verificationNotMatched {
    return _verificationResult?.status ==
        TripPathPhotoMatchStatus.notMatched;
  }

  // ============================================================
  // PHOTO NAME
  // ============================================================

  String get photoName {
    final name = _capturedPhoto?.name.trim();

    if (name == null || name.isEmpty) {
      return 'Captured landmark photo';
    }

    return name;
  }

  // ============================================================
  // PHOTO SIZE
  // ============================================================

  String get photoSizeText {
    final bytes = _capturedPhotoBytes?.lengthInBytes;

    if (bytes == null || bytes <= 0) {
      return '';
    }

    if (bytes < 1024) {
      return '$bytes B';
    }

    final kilobytes = bytes / 1024;

    if (kilobytes < 1024) {
      return '${kilobytes.toStringAsFixed(1)} KB';
    }

    final megabytes = kilobytes / 1024;

    return '${megabytes.toStringAsFixed(1)} MB';
  }

  // ============================================================
  // INITIALISE
  //
  // Android may destroy MainActivity while the native camera
  // is open.
  //
  // image_picker provides retrieveLostData().
  // ============================================================

  Future<void> initialise() async {
    if (kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android) {
      return;
    }

    try {
      final LostDataResponse response =
      await _imagePicker.retrieveLostData();

      if (response.isEmpty) {
        return;
      }

      final files = response.files;

      if (files != null &&
          files.isNotEmpty) {
        await _storePhoto(
          files.first,
        );

        return;
      }

      final exception = response.exception;

      if (exception != null) {
        _cameraError =
            _messageForPlatformException(
              exception,
            );

        notifyListeners();
      }
    } catch (error) {
      debugPrint(
        'Unable to recover camera result: $error',
      );
    }
  }

  // ============================================================
  // TAKE PHOTO
  // ============================================================

  Future<void> takePhoto() async {
    await _capturePhoto();
  }

  // ============================================================
  // RETAKE PHOTO
  //
  // Previous verification result is cleared because
  // the photo is about to change.
  // ============================================================

  Future<void> retakePhoto() async {
    clearVerificationResult(
      notify: false,
    );

    notifyListeners();

    await _capturePhoto();
  }

  // ============================================================
  // CLEAR PHOTO
  // ============================================================

  void clearPhoto() {
    _capturedPhoto = null;

    _capturedPhotoBytes = null;

    _cameraError = null;

    clearVerificationResult(
      notify: false,
    );

    notifyListeners();
  }

  // ============================================================
  // OPEN REAL CAMERA
  // ============================================================

  Future<void> _capturePhoto() async {
    if (_isOpeningCamera) {
      return;
    }

    _isOpeningCamera = true;

    _cameraError = null;

    notifyListeners();

    try {
      final XFile? photo =
      await _imagePicker.pickImage(
        source: ImageSource.camera,
        preferredCameraDevice:
        CameraDevice.rear,
        imageQuality: 85,
        maxWidth: 1600,
      );

      // ========================================================
      // USER CANCELLED CAMERA
      // ========================================================

      if (photo == null) {
        return;
      }

      await _storePhoto(
        photo,
      );
    } on PlatformException catch (error) {
      _cameraError =
          _messageForPlatformException(
            error,
          );
    } catch (error) {
      _cameraError =
      'Unable to open or read the camera photo. Please try again.';

      debugPrint(
        'Trip Path Quest camera error: $error',
      );
    } finally {
      _isOpeningCamera = false;

      notifyListeners();
    }
  }

  // ============================================================
  // STORE CAMERA PHOTO
  // ============================================================

  Future<void> _storePhoto(
      XFile photo,
      ) async {
    final bytes =
    await photo.readAsBytes();

    if (bytes.isEmpty) {
      throw StateError(
        'The captured image is empty.',
      );
    }

    _capturedPhoto = photo;

    _capturedPhotoBytes = bytes;

    _cameraError = null;

    // ==========================================================
    // NEW PHOTO
    // → OLD VERIFICATION RESULT IS NO LONGER VALID
    // ==========================================================

    clearVerificationResult(
      notify: false,
    );

    notifyListeners();
  }

  // ============================================================
  // VERIFY PHOTO
  //
  // View provides:
  //
  // referenceImageBytes
  //
  // ViewModel already owns:
  //
  // capturedImageBytes
  //
  // Then:
  //
  // Reference
  // +
  // Camera
  // ↓
  // TripPathPhotoMatchService
  // ↓
  // ORB
  // ↓
  // KNN Hamming
  // ↓
  // Ratio Test
  // ↓
  // RANSAC
  // ↓
  // Result
  // ============================================================

  Future<void> verifyPhoto({
    required Uint8List referenceImageBytes,
    required String themeId,
    required String referenceKind,
    String expectedPlaceName = '',
  }) async {
    // ==========================================================
    // PREVENT DOUBLE TAP
    // ==========================================================

    if (_isVerifying) {
      return;
    }

    // ==========================================================
    // CHECK REFERENCE PHOTO
    // ==========================================================

    if (referenceImageBytes.isEmpty) {
      _verificationResult = null;

      _verificationError =
      'The checkpoint reference photo is unavailable. '
          'Return to the quest and try again.';

      notifyListeners();

      return;
    }

    // ==========================================================
    // CHECK CAMERA PHOTO
    // ==========================================================

    if (!hasPhoto ||
        _capturedPhotoBytes == null ||
        _capturedPhotoBytes!.isEmpty) {
      _verificationResult = null;

      _verificationError =
      'Camera photo is missing. Please take a photo first.';

      notifyListeners();

      return;
    }

    // ==========================================================
    // START VERIFYING
    // ==========================================================

    _isVerifying = true;

    _verificationResult = null;

    _verificationError = null;

    notifyListeners();

    try {
      // ========================================================
      // LOCAL OPENCV COMPARISON
      // ========================================================

      // Allow the busy state to paint before any image decoding starts.
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final result =
      await _photoMatchService.compare(
        referenceImageBytes:
        referenceImageBytes,
        capturedImageBytes:
        _capturedPhotoBytes!,
        themeId: themeId,
        referenceKind: referenceKind,
        expectedPlaceName: expectedPlaceName,
      ).timeout(const Duration(seconds: 30));

      var finalResult = result;

      // ========================================================
      // ADAPTIVE AI + OPENCV EVIDENCE FUSION
      //
      // Local verification remains authoritative for clear matches and
      // explicit storefront identity conflicts. Gemini is consulted only for
      // genuine boundary cases where local evidence already suggests the
      // same physical place may be present. AI cannot rescue a completely
      // unrelated image on its own.
      // ========================================================
      final storefrontLocalPrimaryAnchors =
          _localStorefrontPrimaryAnchorsAreStrong(
        result,
        referenceKind: referenceKind,
      );

      // A strong, spatially distributed storefront match doesn't need a
      // mandatory Gemini audit. This keeps obvious correct captures fast and
      // prevents AI quota from becoming a hard dependency. Local direct
      // verify still requires identity/facade/scene evidence spread across
      // multiple RANSAC regions, so a sign-only crop cannot satisfy this
      // branch.
      if (storefrontLocalPrimaryAnchors &&
          result.status == TripPathPhotoMatchStatus.matched) {
        finalResult = result.copyWith(
          reasonCode: 'local_multiregion_storefront',
          message:
              'Your photo matches this checkpoint. The shop identity and fixed storefront structure agree across multiple image regions.',
        );

        if (kDebugMode) {
          debugPrint(
            '[LOCAL STOREFRONT] direct verified without AI: '
            'inliers=${result.inliers} ratio=${result.inlierRatio.toStringAsFixed(2)} '
            'refCoverage=${result.referenceSceneCoverage.toStringAsFixed(2)} '
            'capCoverage=${result.capturedSceneCoverage.toStringAsFixed(2)} '
            'refHull=${result.referenceHullArea.toStringAsFixed(4)} '
            'capHull=${result.capturedHullArea.toStringAsFixed(4)} '
            'structure=${result.storefrontStructureSimilarity.toStringAsFixed(2)} '
            'scene=${result.globalSceneSimilarity.toStringAsFixed(2)}.',
          );
        }
      }

      final storefrontAnchorAudit = _needsStorefrontAnchorAudit(
        result,
        referenceKind: referenceKind,
        localPrimaryAnchorsStrong: storefrontLocalPrimaryAnchors,
      );

      if (storefrontAnchorAudit && kDebugMode) {
        debugPrint(
          '[LOCAL STOREFRONT] localized/ambiguous local match -> AI audit: '
          'inliers=${result.inliers} ratio=${result.inlierRatio.toStringAsFixed(2)} '
          'refCoverage=${result.referenceSceneCoverage.toStringAsFixed(2)} '
          'capCoverage=${result.capturedSceneCoverage.toStringAsFixed(2)} '
          'structure=${result.storefrontStructureSimilarity.toStringAsFixed(2)} '
          'scene=${result.globalSceneSimilarity.toStringAsFixed(2)}.',
        );
      }

      if (storefrontAnchorAudit ||
          _shouldUseAiFallback(
            result,
            themeId: themeId,
            referenceKind: referenceKind,
          )) {
        try {
          final ai = await _geminiPhotoVerificationService.compare(
            reference: referenceImageBytes,
            captured: _capturedPhotoBytes!,
            themeId: themeId,
            referenceKind: referenceKind,
            expectedPlaceName: expectedPlaceName,
          ).timeout(const Duration(seconds: 18));

          finalResult = _mergeAiSecondOpinion(
            local: result,
            ai: ai,
            themeId: themeId,
            referenceKind: referenceKind,
          );

          if (kDebugMode) {
            debugPrint(
              '[AI VERIFY] local=${result.status.name}/${result.reasonCode} '
              'ai=${ai.verdict} confidence=${ai.confidence.toStringAsFixed(2)} '
              'identityConflict=${ai.identityConflict} '
              'stable=${ai.stableMatches.length} contradictions=${ai.permanentContradictions.length} '
              'scope=${ai.evidenceScope} distinctive=${ai.distinctivenessScore.toStringAsFixed(2)} '
              'permanentVisible=${ai.permanentVisibility.toStringAsFixed(2)} '
              'env=${ai.referenceEnvironment}->${ai.capturedEnvironment} '
              'captureScope=${ai.captureScope} '
              'anchors=${ai.matchedPrimaryAnchors.length}/${ai.referencePrimaryAnchors.length} '
              'storefrontContext=${ai.storefrontContextVisible} '
              'ignored=${ai.ignoredTransientObjects.join(",")} '
              'final=${finalResult.status.name}/${finalResult.reasonCode} '
              'reason=${ai.reason}',
            );
          }
        } catch (error) {
          // AI remains optional for ordinary boundary cases. For selective
          // storefront audits, however, a weak/localized match must not
          // silently become VERIFIED just because AI is unavailable.
          if (storefrontAnchorAudit &&
              !_localStorefrontFallbackIsStrong(result)) {
            finalResult = result.copyWith(
              status: TripPathPhotoMatchStatus.retake,
              reasonCode: 'storefront_anchor_audit_unavailable',
              message:
                  'The storefront needs a wider identity-and-facade check. Retake with the shop sign/identity and more of the fixed storefront visible.',
            );
          }
          if (kDebugMode) {
            debugPrint('[AI VERIFY] fallback unavailable: $error');
          }
        }
      }

      _verificationResult = finalResult;

      if (finalResult.status == TripPathPhotoMatchStatus.error) {
        _verificationError = finalResult.message;
      }
    } catch (error) {
      _verificationResult = null;

      _verificationError =
      'Photo verification could not be completed. Please try again.';

      debugPrint(
        'Trip Path Quest verification error: $error',
      );
    } finally {
      _isVerifying = false;

      notifyListeners();
    }
  }

  // ============================================================
  // STOREFRONT MULTI-REGION + SELECTIVE AI AUDIT
  // ============================================================

  bool _isStorefrontReferenceKind(String referenceKind) {
    final kind = referenceKind.trim().toLowerCase();
    return const {
      'storefront_exterior',
      'food_stall_or_kiosk',
    }.contains(kind);
  }

  // ============================================================
  // LOCAL MULTI-REGION PRIMARY-ANCHOR PROOF
  // ============================================================
  //
  // A local storefront MATCH may bypass Gemini only when the RANSAC inliers
  // are distributed across at least two 3x3 image regions in BOTH images and
  // the fixed facade/scene evidence is also strong. A sign/logo-only crop
  // normally concentrates its inliers in one region and therefore still goes
  // to the selective Gemini primary-anchor audit.
  //
  // This is intentionally stricter than the ordinary local MATCH policy. It
  // reduces AI usage without turning OCR/name agreement into proof of the
  // physical branch.
  bool _localStorefrontPrimaryAnchorsAreStrong(
    TripPathPhotoMatchResult r, {
    required String referenceKind,
  }) {
    if (!_isStorefrontReferenceKind(referenceKind) ||
        r.status != TripPathPhotoMatchStatus.matched ||
        r.storefrontIdentityConflict) {
      return false;
    }

    final minHull = r.referenceHullArea < r.capturedHullArea
        ? r.referenceHullArea
        : r.capturedHullArea;
    final minCoverage = r.referenceSceneCoverage < r.capturedSceneCoverage
        ? r.referenceSceneCoverage
        : r.capturedSceneCoverage;

    // MatchSpread.coverage is occupiedCells / 9. Requiring >= 2/9 means
    // RANSAC-supported matches must occupy at least two non-trivial regions
    // in both the reference and capture.
    const twoRegionCoverage = 2 / 9;
    final multiRegion = minCoverage >= twoRegionCoverage;

    // V47 — previously this only rejected the confirmed ref=outdoor vs
    // cap=indoor contradiction, so an unclassified ('uncertain') captured
    // photo silently counted as "compatible" and could still bypass Gemini
    // — the same "unknown treated as safe" gap that let a person/desk photo
    // through before the V47 person-detector was added above in the match
    // service. Storefront references are always outdoor (see reference
    // selection), so bypassing Gemini here now requires the captured photo
    // to have actually been confirmed outdoor/mixed, not merely "no
    // contradiction was detected".
    final outdoorCompatible = r.capturedEnvironment == 'outdoor' ||
        r.capturedEnvironment == 'mixed';
    if (!outdoorCompatible || !multiRegion) return false;

    final referenceIdentityReadable =
        r.storefrontReferenceNameSimilarity >= 0.68;
    final identity = r.storefrontExpectedNameSimilarity >= 0.72 ||
        r.storefrontTextSimilarity >= 0.78;

    // Normal path: readable identity + broad fixed facade geometry.
    final identityAnchored = identity &&
        r.goodMatches >= 12 &&
        r.inliers >= 6 &&
        r.inlierRatio >= 0.34 &&
        minHull >= 0.008 &&
        r.storefrontStructureSimilarity >= 0.70 &&
        r.globalSceneSimilarity >= 0.44;

    // OCR may fail at night or on a text-poor storefront. Only allow a local
    // no-identity bypass when the reference itself has no readable identity
    // and the geometry/facade evidence is substantially stronger.
    final noReadableIdentityGeometry = !referenceIdentityReadable &&
        r.goodMatches >= 18 &&
        r.inliers >= 10 &&
        r.inlierRatio >= 0.48 &&
        minHull >= 0.012 &&
        r.storefrontStructureSimilarity >= 0.80 &&
        r.globalSceneSimilarity >= 0.56;

    return identityAnchored || noReadableIdentityGeometry;
  }

  bool _needsStorefrontAnchorAudit(
    TripPathPhotoMatchResult result, {
    required String referenceKind,
    required bool localPrimaryAnchorsStrong,
  }) {
    if (!_isStorefrontReferenceKind(referenceKind)) return false;

    // Only LOCALIZED / AMBIGUOUS storefront matches require Gemini. Strong
    // multi-region local evidence verifies directly. This protects against
    // sign-only/environment-only false positives without spending an AI
    // request on every correct Food capture.
    return result.status == TripPathPhotoMatchStatus.matched &&
        !localPrimaryAnchorsStrong;
  }

  bool _localStorefrontFallbackIsStrong(TripPathPhotoMatchResult r) {
    final minHull = r.referenceHullArea < r.capturedHullArea
        ? r.referenceHullArea
        : r.capturedHullArea;
    final minCoverage = r.referenceSceneCoverage < r.capturedSceneCoverage
        ? r.referenceSceneCoverage
        : r.capturedSceneCoverage;
    final identity = r.storefrontExpectedNameSimilarity >= 0.72 ||
        r.storefrontTextSimilarity >= 0.78;
    final broadFacade = r.inliers >= 6 &&
        r.inlierRatio >= 0.42 &&
        minHull >= 0.008 &&
        minCoverage >= (2 / 9) &&
        r.storefrontStructureSimilarity >= 0.70 &&
        r.globalSceneSimilarity >= 0.46;

    final outdoorCompatible = !(r.referenceEnvironment == 'outdoor' &&
        r.capturedEnvironment == 'indoor');

    return identity && broadFacade && outdoorCompatible;
  }

  bool _storefrontAiAnchorContractSatisfied(
    GeminiPhotoVerificationDecision ai,
  ) {
    if (ai.environmentMismatch ||
        ai.identityConflict ||
        ai.hasPermanentContradiction) {
      return false;
    }

    if (ai.captureScope == 'sign_only' ||
        ai.captureScope == 'environment_only' ||
        ai.captureScope == 'unclear') {
      return false;
    }

    if (!ai.storefrontContextVisible) return false;

    // Brand/logo alone is one anchor.  Requiring two matched reference
    // anchors forces Gemini to also find branch/facade context such as the
    // entrance, sign position, pillars, window divisions or fixed neighbour.
    return ai.referencePrimaryAnchors.length >= 2 &&
        ai.matchedPrimaryAnchors.length >= 2;
  }

  // ============================================================
  // ADAPTIVE AI REVIEW GATE
  //
  // Strategy:
  // - Very strong local match: already returned MATCHED, no AI cost.
  // - Clear hard contradiction / capture-quality failure: no AI rescue.
  // - Clearly unrelated local image: keep NOT VERIFIED directly.
  // - Everything with a credible hint of same-place overlap may ask Gemini
  //   for structured permanent-feature evidence.
  //
  // This widens AI review for angle / crop / day-night cases WITHOUT widening
  // the Retake entrance. Retake still needs stronger positive local evidence.
  // ============================================================
  bool _shouldUseAiFallback(
    TripPathPhotoMatchResult result, {
    required String themeId,
    required String referenceKind,
  }) {
    if (result.status == TripPathPhotoMatchStatus.matched ||
        result.status == TripPathPhotoMatchStatus.error ||
        result.storefrontIdentityConflict) {
      return false;
    }

    // Capture-quality failures need a better photo, not an AI guess.
    if (const {
      'too_dark',
      'dark_border',
      'blurred_capture',
    }.contains(result.reasonCode)) {
      return false;
    }

    final kind = referenceKind.trim().toLowerCase();
    final theme = themeId.trim().toLowerCase();
    final storefront = const {
      'storefront_exterior',
      'food_stall_or_kiosk',
    }.contains(kind);
    final nature = theme == 'nature' || kind.startsWith('nature_');
    final landmark = theme == 'culture' ||
        theme == 'heritage' ||
        kind.contains('landmark') ||
        kind.contains('monument') ||
        kind.contains('building_exterior');

    if (_isClearlyUnrelatedLocal(
      result,
      storefront: storefront,
      nature: nature,
      landmark: landmark,
    )) {
      if (kDebugMode) {
        debugPrint(
          '[ADAPTIVE AI] skipped: local evidence is clearly unrelated '
          '(good=${result.goodMatches}, inliers=${result.inliers}, '
          'ratio=${result.inlierRatio.toStringAsFixed(2)}, '
          'global=${result.globalSceneSimilarity.toStringAsFixed(2)}).',
        );
      }
      return false;
    }

    return _hasAdaptiveAiReviewEvidence(
      result,
      storefront: storefront,
      nature: nature,
      landmark: landmark,
    );
  }

  bool _isClearlyUnrelatedLocal(
    TripPathPhotoMatchResult r, {
    required bool storefront,
    required bool nature,
    required bool landmark,
  }) {
    if (r.status != TripPathPhotoMatchStatus.notMatched) return false;

    if (storefront) {
      final identityHint = r.storefrontExpectedNameSimilarity >= 0.42 ||
          r.storefrontTextSimilarity >= 0.52;
      return !identityHint &&
          r.inliers <= 1 &&
          r.goodMatches < 5 &&
          r.globalSceneSimilarity < 0.24 &&
          r.storefrontStructureSimilarity < 0.42;
    }

    if (nature) {
      return r.inliers <= 1 &&
          r.goodMatches < 5 &&
          r.globalSceneSimilarity < 0.30;
    }

    if (landmark) {
      return r.inliers == 0 &&
          r.goodMatches < 5 &&
          r.globalSceneSimilarity < 0.24;
    }

    return r.inliers <= 1 &&
        r.goodMatches < 5 &&
        r.globalSceneSimilarity < 0.25;
  }

  bool _hasAdaptiveAiReviewEvidence(
    TripPathPhotoMatchResult r, {
    required bool storefront,
    required bool nature,
    required bool landmark,
  }) {
    final minHull = r.referenceHullArea < r.capturedHullArea
        ? r.referenceHullArea
        : r.capturedHullArea;

    if (storefront) {
      final identityHint = r.storefrontExpectedNameSimilarity >= 0.45 ||
          r.storefrontTextSimilarity >= 0.55;
      final partialGeometry = r.inliers >= 2 &&
          r.inlierRatio >= 0.16 &&
          r.globalSceneSimilarity >= 0.22;
      final facadeHint = r.storefrontStructureSimilarity >= 0.52 &&
          r.globalSceneSimilarity >= 0.28;
      final sceneHint = r.goodMatches >= 6 &&
          r.globalSceneSimilarity >= 0.35;
      return identityHint || partialGeometry || facadeHint || sceneHint;
    }

    if (nature) {
      // Nature changes with weather, foliage and water, so allow AI to review
      // somewhat earlier. Final Verify/Retake still needs much stronger local
      // support and multiple distinctive permanent AI anchors.
      return (r.inliers >= 2 &&
              r.inlierRatio >= 0.16 &&
              minHull >= 0.0015 &&
              r.globalSceneSimilarity >= 0.30) ||
          (r.goodMatches >= 6 && r.globalSceneSimilarity >= 0.40) ||
          (r.inliers >= 1 && r.globalSceneSimilarity >= 0.52);
    }

    if (landmark) {
      // Large landmarks can lose most RANSAC overlap under close-up / low-angle
      // captures. A small but credible overlap is enough to ASK AI, not enough
      // to Verify by itself.
      return (r.inliers >= 1 &&
              r.inlierRatio >= 0.12 &&
              r.globalSceneSimilarity >= 0.25) ||
          (r.goodMatches >= 5 && r.globalSceneSimilarity >= 0.32) ||
          (r.inliers >= 2 && minHull >= 0.0008);
    }

    return (r.inliers >= 2 &&
            r.inlierRatio >= 0.18 &&
            r.globalSceneSimilarity >= 0.26) ||
        (r.goodMatches >= 6 && r.globalSceneSimilarity >= 0.36);
  }

  // Stronger than the adaptive REVIEW gate. This is the minimum local
  // positive evidence required before AI is allowed to CREATE a Retake result.
  // Therefore an unrelated image cannot become Retake merely because Gemini is
  // uncertain or sees generic semantic similarity.
  bool _hasMinimumAiReviewEvidence(
    TripPathPhotoMatchResult r, {
    required bool storefront,
    required bool nature,
    required bool landmark,
  }) {
    final minHull = r.referenceHullArea < r.capturedHullArea
        ? r.referenceHullArea
        : r.capturedHullArea;

    if (storefront) {
      final identityHint = r.storefrontExpectedNameSimilarity >= 0.55 ||
          r.storefrontTextSimilarity >= 0.62;
      final fixedGeometry = r.inliers >= 3 &&
          r.inlierRatio >= 0.24 &&
          minHull >= 0.002 &&
          r.storefrontStructureSimilarity >= 0.55 &&
          r.globalSceneSimilarity >= 0.30;
      final strongFacade = r.inliers >= 4 &&
          r.inlierRatio >= 0.28 &&
          r.storefrontStructureSimilarity >= 0.68 &&
          r.globalSceneSimilarity >= 0.40;
      return identityHint || fixedGeometry || strongFacade;
    }

    if (nature) {
      return (r.inliers >= 3 &&
              r.inlierRatio >= 0.24 &&
              minHull >= 0.004 &&
              r.globalSceneSimilarity >= 0.40) ||
          (r.goodMatches >= 8 && r.globalSceneSimilarity >= 0.56);
    }

    if (landmark) {
      return (r.inliers >= 2 &&
              r.inlierRatio >= 0.20 &&
              minHull >= 0.0015 &&
              r.globalSceneSimilarity >= 0.28) ||
          (r.inliers >= 3 && r.globalSceneSimilarity >= 0.34) ||
          (r.goodMatches >= 7 && r.globalSceneSimilarity >= 0.40);
    }

    return (r.inliers >= 3 &&
            r.inlierRatio >= 0.25 &&
            minHull >= 0.0035 &&
            r.globalSceneSimilarity >= 0.30) ||
        (r.inliers >= 5 && r.globalSceneSimilarity >= 0.40);
  }

  bool _localSafetyAllowsAiMatch(
    TripPathPhotoMatchResult r, {
    required bool storefront,
    required bool nature,
    required bool landmark,
  }) {
    if (r.storefrontIdentityConflict) return false;

    final minHull = r.referenceHullArea < r.capturedHullArea
        ? r.referenceHullArea
        : r.capturedHullArea;

    if (storefront) {
      final identity = r.storefrontExpectedNameSimilarity >= 0.60 ||
          r.storefrontTextSimilarity >= 0.68;
      final geometry = r.inliers >= 4 &&
          r.inlierRatio >= 0.30 &&
          minHull >= 0.0025 &&
          r.storefrontStructureSimilarity >= 0.58 &&
          r.globalSceneSimilarity >= 0.34;
      // Food remains identity-first where readable identity exists; strong
      // fixed-facade geometry can support OCR-unreadable storefronts.
      return identity || geometry;
    }

    if (nature) {
      return (r.inliers >= 4 &&
              r.inlierRatio >= 0.28 &&
              minHull >= 0.0045 &&
              r.globalSceneSimilarity >= 0.42) ||
          (r.inliers >= 5 && r.globalSceneSimilarity >= 0.48);
    }

    if (landmark) {
      // Close-up landmarks may have a small overlap area, so permit a slightly
      // smaller footprint only when RANSAC and whole-scene evidence agree.
      return (r.inliers >= 3 &&
              r.inlierRatio >= 0.25 &&
              minHull >= 0.002 &&
              r.globalSceneSimilarity >= 0.32) ||
          (r.inliers >= 4 &&
              minHull >= 0.0018 &&
              r.globalSceneSimilarity >= 0.38);
    }

    return r.inliers >= 4 &&
        r.inlierRatio >= 0.30 &&
        minHull >= 0.004 &&
        r.globalSceneSimilarity >= 0.34;
  }

  bool _aiEvidenceSupportsSamePlace(
    GeminiPhotoVerificationDecision ai, {
    required bool storefront,
    required bool nature,
    required bool landmark,
    required bool strict,
  }) {
    if (ai.identityConflict || ai.hasPermanentContradiction) return false;
    if (storefront && !_storefrontAiAnchorContractSatisfied(ai)) {
      return false;
    }
    if (ai.evidenceScope == 'tiny_or_generic' ||
        ai.evidenceScope == 'unclear') {
      return false;
    }

    final requiredStable = strict && !landmark ? 3 : 2;
    if (ai.stableMatches.length < requiredStable) return false;

    var minDistinctiveness = 0.68;
    var minVisibility = 0.28;
    if (storefront) {
      minDistinctiveness = 0.72;
      minVisibility = 0.30;
    } else if (nature) {
      minDistinctiveness = 0.74;
      minVisibility = 0.34;
    } else if (landmark) {
      minDistinctiveness = 0.66;
      minVisibility = 0.24;
    }

    if (strict) minDistinctiveness += 0.04;

    return ai.distinctivenessScore >= minDistinctiveness &&
        ai.permanentVisibility >= minVisibility;
  }

  bool _aiEvidenceSupportsProbableSame(
    GeminiPhotoVerificationDecision ai, {
    required bool nature,
    required bool storefront,
  }) {
    if (ai.identityConflict || ai.hasPermanentContradiction) return false;
    if (storefront) {
      if (ai.environmentMismatch ||
          ai.captureScope == 'environment_only' ||
          ai.captureScope == 'unclear') {
        return false;
      }
      // A correct sign-only capture may deserve RETAKE, but never MATCHED.
      // It still needs a real reference anchor rather than generic text.
      if (ai.matchedPrimaryAnchors.isEmpty) return false;
    }
    if (ai.evidenceScope == 'tiny_or_generic' ||
        ai.evidenceScope == 'unclear') {
      return false;
    }

    // Narrow Retake: AI must name at least TWO permanent same-place anchors.
    // Generic "both are buildings/green" similarity never creates Retake.
    final minDistinctiveness = nature ? 0.58 : 0.54;

    return ai.stableMatches.length >= 2 &&
        ai.distinctivenessScore >= minDistinctiveness &&
        ai.permanentVisibility >= 0.22;
  }

  bool _aiEvidenceSupportsDifferentPlace(
    GeminiPhotoVerificationDecision ai,
  ) {
    // Does not accept a bare high-confidence "different" label. Gemini must
    // point to at least one permanent contradiction. This reduces false
    // rejection caused by day/night, viewpoint, people or vehicle changes.
    if (ai.permanentContradictions.isEmpty) return false;

    if (ai.identityConflict && ai.confidence >= 0.86) return true;

    return ai.verdict == 'different_place' && ai.confidence >= 0.86;
  }

  double _requiredAiSameConfidence({
    required TripPathPhotoMatchResult local,
    required bool storefront,
    required bool nature,
    required bool landmark,
  }) {
    final reversingNotMatched =
        local.status == TripPathPhotoMatchStatus.notMatched;

    if (landmark) return reversingNotMatched ? 0.91 : 0.86;
    if (storefront) return reversingNotMatched ? 0.94 : 0.90;
    if (nature) return reversingNotMatched ? 0.94 : 0.90;
    return reversingNotMatched ? 0.93 : 0.89;
  }

  TripPathPhotoMatchResult _mergeAiSecondOpinion({
    required TripPathPhotoMatchResult local,
    required GeminiPhotoVerificationDecision ai,
    required String themeId,
    required String referenceKind,
  }) {
    final kind = referenceKind.trim().toLowerCase();
    final theme = themeId.trim().toLowerCase();
    final storefront = const {
      'storefront_exterior',
      'food_stall_or_kiosk',
    }.contains(kind);
    final nature = theme == 'nature' || kind.startsWith('nature_');
    final landmark = theme == 'culture' ||
        theme == 'heritage' ||
        kind.contains('landmark') ||
        kind.contains('monument') ||
        kind.contains('building_exterior');

    final evidenceExplanation = ai.reason.trim().isEmpty
        ? ai.compactEvidenceSummary
        : '${ai.reason.trim()} | ${ai.compactEvidenceSummary}';

    TripPathPhotoMatchResult stamped(
      TripPathPhotoMatchStatus status,
      String reason,
      String message,
    ) {
      return local.copyWith(
        status: status,
        reasonCode: reason,
        message: message,
        aiReviewed: true,
        aiDecision: ai.verdict,
        aiConfidence: ai.confidence,
        aiExplanation: evidenceExplanation,
      );
    }

    // Hard context contract for storefront/exterior references. These checks
    // run BEFORE the generic AI fusion so neither strong local geometry nor a
    // high AI confidence can turn a sign-only/environment-only capture into a
    // verified storefront visit.
    if (storefront) {
      final aiOutdoorIndoorMismatch = ai.environmentMismatch ||
          (ai.referenceEnvironment == 'outdoor' &&
              ai.capturedEnvironment == 'indoor');

      if (aiOutdoorIndoorMismatch && ai.confidence >= 0.80) {
        return stamped(
          TripPathPhotoMatchStatus.notMatched,
          'ai_environment_mismatch',
          'The reference is an exterior/outdoor view, but the captured photo appears to be indoors. Photograph the same physical storefront exterior shown in the reference.',
        );
      }

      if (ai.captureScope == 'environment_only') {
        return stamped(
          TripPathPhotoMatchStatus.notMatched,
          'storefront_environment_only',
          'The photo shows the surrounding environment but not enough of the target storefront. Include the shop identity or another primary storefront anchor together with the facade.',
        );
      }

      if (ai.captureScope == 'sign_only') {
        if (ai.identityConflict || ai.hasPermanentContradiction) {
          return stamped(
            TripPathPhotoMatchStatus.notMatched,
            'storefront_sign_identity_mismatch',
            'The sign or storefront identity does not match this checkpoint.',
          );
        }
        return stamped(
          TripPathPhotoMatchStatus.retake,
          'storefront_sign_only_retake',
          'The sign may match, but a sign alone cannot verify the physical storefront. Retake wider so the sign/identity and fixed facade or entrance are visible together.',
        );
      }

      if (local.status == TripPathPhotoMatchStatus.matched &&
          !_storefrontAiAnchorContractSatisfied(ai)) {
        final hasOneAnchor = ai.matchedPrimaryAnchors.isNotEmpty;
        return stamped(
          hasOneAnchor
              ? TripPathPhotoMatchStatus.retake
              : TripPathPhotoMatchStatus.notMatched,
          hasOneAnchor
              ? 'storefront_primary_anchor_incomplete'
              : 'storefront_primary_anchor_missing',
          hasOneAnchor
              ? 'Some storefront evidence matches, but more of the target facade is needed. Retake with at least two primary fixed anchors visible together.'
              : 'The captured photo does not show enough of the target storefront primary anchors to verify this checkpoint.',
        );
      }
    }

    // A local OCR identity conflict still never reaches AI. For an AI-only
    // rejection, require an explicit permanent contradiction rather than a
    // bare confidence score.
    if (_aiEvidenceSupportsDifferentPlace(ai)) {
      return stamped(
        TripPathPhotoMatchStatus.notMatched,
        'ai_permanent_contradiction',
        'The reference and captured photo contain conflicting permanent place details.',
      );
    }

    final safeForAiMatch = _localSafetyAllowsAiMatch(
      local,
      storefront: storefront,
      nature: nature,
      landmark: landmark,
    );

    final strictEvidence =
        local.status == TripPathPhotoMatchStatus.notMatched;
    final aiEvidenceStrong = _aiEvidenceSupportsSamePlace(
      ai,
      storefront: storefront,
      nature: nature,
      landmark: landmark,
      strict: strictEvidence,
    );
    final requiredSameConfidence = _requiredAiSameConfidence(
      local: local,
      storefront: storefront,
      nature: nature,
      landmark: landmark,
    );

    if (ai.verdict == 'same_place' &&
        ai.confidence >= requiredSameConfidence &&
        aiEvidenceStrong &&
        safeForAiMatch) {
      return stamped(
        TripPathPhotoMatchStatus.matched,
        'ai_evidence_fused_same_place',
        'Your photo matches this checkpoint. Independent AI identified multiple distinctive permanent features and the local geometry supports the same physical place.',
      );
    }

    // NARROW RETAKE:
    // Retake needs positive same-place evidence; AI uncertainty/generic
    // similarity is not enough. Two paths are allowed:
    //
    // 1) AI says SAME with strong structured evidence but the local safety
    //    threshold is just short of auto-Verify. This is useful for extreme
    //    angle / crop / day-night cases.
    // 2) AI says PROBABLY SAME and the local layer already has the stronger
    //    positive evidence gate.
    final localPositiveForRetake = _hasMinimumAiReviewEvidence(
      local,
      storefront: storefront,
      nature: nature,
      landmark: landmark,
    );
    final localAdaptiveHint = _hasAdaptiveAiReviewEvidence(
      local,
      storefront: storefront,
      nature: nature,
      landmark: landmark,
    );

    final strongAiSameForRetake = ai.verdict == 'same_place' &&
        ai.confidence >= (landmark ? 0.82 : (storefront || nature ? 0.86 : 0.84)) &&
        _aiEvidenceSupportsSamePlace(
          ai,
          storefront: storefront,
          nature: nature,
          landmark: landmark,
          strict: false,
        ) &&
        localAdaptiveHint;

    final probableAiSameForRetake =
        (ai.verdict == 'probably_same' || ai.verdict == 'same_place') &&
            ai.confidence >= 0.78 &&
            _aiEvidenceSupportsProbableSame(
              ai,
              nature: nature,
              storefront: storefront,
            ) &&
            localPositiveForRetake;

    if (strongAiSameForRetake || probableAiSameForRetake) {
      return stamped(
        TripPathPhotoMatchStatus.retake,
        'ai_evidence_probably_same_retake',
        'This is probably the same place, but more permanent landmark detail is needed. Retake with a little more of the fixed scene visible.',
      );
    }

    // If the old local policy produced Retake from only weak evidence and AI
    // cannot provide structured same-place support, narrow that result back to
    // Not Verified. Capture-quality Retakes never reach this path.
    if (local.status == TripPathPhotoMatchStatus.retake &&
        !localPositiveForRetake) {
      return stamped(
        TripPathPhotoMatchStatus.notMatched,
        'weak_retake_not_supported',
        'The photo does not contain enough reliable same-place evidence for this checkpoint.',
      );
    }

    // Keep the local decision when it already contains credible positive
    // evidence, while retaining the AI evidence for calibration.
    return local.copyWith(
      aiReviewed: true,
      aiDecision: ai.verdict,
      aiConfidence: ai.confidence,
      aiExplanation: evidenceExplanation,
    );
  }

  // ============================================================
  // CLEAR VERIFICATION RESULT
  //
  // Used when:
  //
  // - user retakes photo
  // - user changes reference later
  // - user wants to retry
  // ============================================================

  void clearVerificationResult({
    bool notify = true,
  }) {
    _verificationResult = null;

    _verificationError = null;

    if (notify) {
      notifyListeners();
    }
  }

  // ============================================================
  // FRIENDLY CAMERA ERROR
  // ============================================================

  String _messageForPlatformException(
      PlatformException error,
      ) {
    switch (error.code) {
      case 'camera_access_denied':
      case 'camera_access_denied_without_prompt':
      case 'camera_access_restricted':
        return 'Camera access is unavailable. '
            'Allow camera permission in Settings and try again.';

      default:
        return 'Unable to open the camera. '
            'Close other camera apps and try again.';
    }
  }
}
