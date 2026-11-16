import 'dart:math' as math;

/// Local photo evidence, not a calibrated probability of visiting a place.
enum TripPathPhotoMatchStatus { matched, retake, notMatched, error }

typedef MatchPoint = ({double x, double y});

/// Normalized RANSAC INLIERS only. Unvalidated descriptor matches must never
/// supply the spatial evidence that turns a result into MATCHED.
class MatchSpread {
  final int occupiedCells;
  final int distinctRows;
  final int distinctCols;
  final double widthSpan;
  final double heightSpan;
  final double hullArea;

  const MatchSpread({
    required this.occupiedCells,
    required this.distinctRows,
    required this.distinctCols,
    required this.widthSpan,
    required this.heightSpan,
    required this.hullArea,
  });

  double get coverage => occupiedCells / 9;
  double get boundingBoxArea => widthSpan * heightSpan;

  factory MatchSpread.fromPoints(List<MatchPoint> points, int width, int height) {
    final normalized = points
        .where((p) => p.x.isFinite && p.y.isFinite &&
            p.x >= 0 && p.y >= 0 && p.x < width && p.y < height)
        .map((p) => (x: p.x / width, y: p.y / height))
        .toList();
    if (width <= 0 || height <= 0 || normalized.isEmpty) {
      return const MatchSpread(occupiedCells: 0, distinctRows: 0,
          distinctCols: 0, widthSpan: 0, heightSpan: 0, hullArea: 0);
    }
    final cells = List<int>.filled(9, 0);
    final rows = <int>{};
    final cols = <int>{};
    for (final p in normalized) {
      cells[(p.y * 3).floor() * 3 + (p.x * 3).floor()]++;
    }
    var occupied = 0;
    for (var i = 0; i < 9; i++) {
      // A single accidental point may not unlock a new part of the scene.
      if (cells[i] < 2) continue;
      occupied++;
      rows.add(i ~/ 3);
      cols.add(i % 3);
    }
    normalized.sort((a, b) {
      final x = a.x.compareTo(b.x);
      return x == 0 ? a.y.compareTo(b.y) : x;
    });
    double cross(MatchPoint a, MatchPoint b, MatchPoint c) =>
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
    final lower = <MatchPoint>[];
    final upper = <MatchPoint>[];
    for (final p in normalized) {
      while (lower.length >= 2 &&
          cross(lower[lower.length - 2], lower.last, p) <= 0) {
        lower.removeLast();
      }
      lower.add(p);
    }
    for (final p in normalized.reversed) {
      while (upper.length >= 2 &&
          cross(upper[upper.length - 2], upper.last, p) <= 0) {
        upper.removeLast();
      }
      upper.add(p);
    }
    final hull = <MatchPoint>[
      ...lower.take(lower.length > 1 ? lower.length - 1 : 0),
      ...upper.take(upper.length > 1 ? upper.length - 1 : 0),
    ];
    var twiceArea = 0.0;
    for (var i = 0; i < hull.length; i++) {
      final a = hull[i];
      final b = hull[(i + 1) % hull.length];
      twiceArea += a.x * b.y - b.x * a.y;
    }
    var minY = normalized.first.y;
    var maxY = normalized.first.y;
    for (final p in normalized) {
      minY = math.min(minY, p.y);
      maxY = math.max(maxY, p.y);
    }
    return MatchSpread(
      occupiedCells: occupied,
      distinctRows: rows.length,
      distinctCols: cols.length,
      widthSpan: normalized.last.x - normalized.first.x,
      heightSpan: maxY - minY,
      hullArea: twiceArea.abs() / 2,
    );
  }

  bool covers({required double width, required double height,
      required double area, required int cells}) =>
      widthSpan.isFinite && heightSpan.isFinite && hullArea.isFinite &&
      widthSpan >= width && heightSpan >= height && hullArea >= area &&
      occupiedCells >= cells && distinctRows >= 2 && distinctCols >= 2;

  /// Perspective-aware footprint used only for strong geometric matches.
  /// An oblique camera angle can compress one axis of a facade while the
  /// other axis still spans a meaningful part of the image. Requiring both
  /// widthSpan and heightSpan to stay large would incorrectly reject some
  /// legitimate angled photos. A tiny sign/logo crop still fails because its
  /// longest span, hull area and 3x3-cell footprint remain too small.
  bool coversPerspective({
    required double longSpan,
    required double shortSpan,
    required double area,
    required int cells,
  }) {
    if (!widthSpan.isFinite ||
        !heightSpan.isFinite ||
        !hullArea.isFinite) {
      return false;
    }
    final longest = math.max(widthSpan, heightSpan);
    final shortest = math.min(widthSpan, heightSpan);
    return longest >= longSpan &&
        shortest >= shortSpan &&
        hullArea >= area &&
        occupiedCells >= cells &&
        distinctRows >= 2 &&
        distinctCols >= 2;
  }

  /// V19 storefront footprint. Long shop fascias/signboards naturally put
  /// many correct RANSAC inliers in one horizontal grid row, especially when
  /// cars, people or tables temporarily hide the lower storefront. This gate
  /// permits one row only when the evidence is broad and non-trivial.
  bool coversWideStorefrontBand({
    required double minWidthSpan,
    required double minHeightSpan,
    required double minHullArea,
    required int minCells,
    required int minCols,
  }) {
    if (!widthSpan.isFinite || !heightSpan.isFinite || !hullArea.isFinite) {
      return false;
    }
    return widthSpan >= minWidthSpan &&
        heightSpan >= minHeightSpan &&
        hullArea >= minHullArea &&
        occupiedCells >= minCells &&
        distinctCols >= minCols &&
        distinctRows >= 1;
  }

  /// Sparse-but-broad footprint used only with independent storefront OCR.
  /// This does not rely on occupied-cell counts because four/five valid
  /// inliers may land one-per-cell after a strong day/night or oblique change.
  bool coversSparseStorefrontFacade({
    required double minWidthSpan,
    required double minHeightSpan,
    required double minHullArea,
  }) {
    if (!widthSpan.isFinite || !heightSpan.isFinite || !hullArea.isFinite) {
      return false;
    }
    return widthSpan >= minWidthSpan &&
        heightSpan >= minHeightSpan &&
        hullArea >= minHullArea;
  }
}

class PhotoMatchEvidence {
  final String themeId;
  final String referenceKind;
  final int goodMatches;
  final int inliers;
  final MatchSpread reference;
  final MatchSpread captured;
  final double globalSimilarity;

  // 0..1 supplementary OCR agreement for distinctive wording across a
  // storefront pair. It is optional and can never verify a photo by itself.
  final double storefrontTextSimilarity;

  // V27 storefront identity evidence. referenceNameSimilarity tells us whether
  // the Google reference itself clearly exposes the selected place name;
  // expectedNameSimilarity measures the same identity in the captured image.
  // identityConflict is true only when OCR sees a strong alternative identity.
  final double storefrontReferenceNameSimilarity;
  final double storefrontExpectedNameSimilarity;
  final bool storefrontIdentityConflict;

  // V20 stable upper-facade structural similarity. Optional and only used
  // for storefront profiles together with OCR + successful RANSAC geometry.
  final double storefrontStructureSimilarity;

  // True when the pair needed CLAHE / lighting normalization because the
  // reference and captured photo differ strongly in brightness. It may relax
  // descriptor-count requirements, but NEVER the whole-scene coverage gate.
  final bool lightingNormalized;

  const PhotoMatchEvidence({required this.themeId, required this.referenceKind,
    required this.goodMatches, required this.inliers, required this.reference,
    required this.captured, required this.globalSimilarity,
    this.storefrontTextSimilarity = 0,
    this.storefrontReferenceNameSimilarity = 0,
    this.storefrontExpectedNameSimilarity = 0,
    this.storefrontIdentityConflict = false,
    this.storefrontStructureSimilarity = 0,
    required this.lightingNormalized});

  double get ratio => goodMatches == 0 ? 0 : inliers / goodMatches;
}

class PhotoMatchDecision {
  final TripPathPhotoMatchStatus status;
  final String reasonCode;
  final String message;
  const PhotoMatchDecision(this.status, this.reasonCode, this.message);
}


/// V31 SINGLE-REFERENCE EVIDENCE FUSION
///
/// This is deliberately not a probability. It normalizes the independent
/// evidence already produced from ONE reference photo so one isolated signal
/// (for example, generic railings or similar colours) cannot decide the result
/// by itself. Hard contradictions such as a conflicting storefront identity
/// are still handled before this score is allowed to verify anything.
class PhotoEvidenceFusion {
  final double score;
  final double geometryScore;
  final double footprintScore;
  final double sceneScore;
  final double identityScore;
  final double structureScore;

  const PhotoEvidenceFusion({
    required this.score,
    required this.geometryScore,
    required this.footprintScore,
    required this.sceneScore,
    required this.identityScore,
    required this.structureScore,
  });
}

/// Single, testable decision path. These are provisional operating thresholds,
/// not "70% of the image = matched" and not proof of physical presence.
class TripPathMatchPolicy {
  static double _unit(double value) => value.clamp(0.0, 1.0).toDouble();

  static double _spreadStrength(MatchSpread spread) {
    final longest = math.max(spread.widthSpan, spread.heightSpan);
    final shortest = math.min(spread.widthSpan, spread.heightSpan);

    final longScore = _unit(longest / 0.30);
    final shortScore = _unit(shortest / 0.16);
    final hullScore = _unit(spread.hullArea / 0.030);
    final cellScore = _unit(spread.occupiedCells / 4.0);

    return longScore * 0.28 +
        shortScore * 0.24 +
        hullScore * 0.30 +
        cellScore * 0.18;
  }

  /// Public for debug logging and deterministic regression tests.
  static PhotoEvidenceFusion fuse(PhotoMatchEvidence e) {
    final theme = e.themeId.trim().toLowerCase();
    final kind = e.referenceKind.trim().toLowerCase();
    final nature = theme == 'nature' || kind.startsWith('nature_');
    final storefrontLike = const {
      'storefront_exterior',
      'food_stall_or_kiosk',
    }.contains(kind);

    final matchCount = _unit(e.goodMatches / 24.0);
    final inlierCount = _unit(e.inliers / 15.0);
    final ratio = _unit((e.ratio - 0.20) / 0.50);
    final geometry =
        matchCount * 0.25 + inlierCount * 0.35 + ratio * 0.40;

    final footprint = math.min(
      _spreadStrength(e.reference),
      _spreadStrength(e.captured),
    );
    final scene = _unit(e.globalSimilarity);
    final structure = _unit(e.storefrontStructureSimilarity);

    final referenceIdentityReadable =
        e.storefrontReferenceNameSimilarity >= 0.68;
    final observedIdentity = math.max(
      _unit(e.storefrontExpectedNameSimilarity),
      _unit(e.storefrontTextSimilarity),
    );

    // No readable identity in the Google reference is neutral rather than a
    // penalty. When identity IS readable, the captured image must earn it,
    // unless overwhelming geometry/structure later qualifies for the bounded
    // same-place recovery path.
    final identity = storefrontLike
        ? (referenceIdentityReadable
            ? observedIdentity
            : math.max(0.62, observedIdentity).toDouble())
        : 0.0;

    double score;
    if (nature) {
      score = geometry * 0.42 + footprint * 0.23 + scene * 0.35;
    } else if (storefrontLike) {
      score = geometry * 0.30 +
          footprint * 0.15 +
          scene * 0.15 +
          structure * 0.16 +
          identity * 0.24;
    } else {
      score = geometry * 0.48 + footprint * 0.25 + scene * 0.27;
    }

    return PhotoEvidenceFusion(
      score: _unit(score),
      geometryScore: _unit(geometry),
      footprintScore: _unit(footprint),
      sceneScore: scene,
      identityScore: _unit(identity),
      structureScore: structure,
    );
  }

  static PhotoMatchDecision decide(PhotoMatchEvidence e) {
    if (e.goodMatches < 0 ||
        e.inliers < 0 ||
        e.inliers > e.goodMatches ||
        !e.globalSimilarity.isFinite ||
        !e.storefrontTextSimilarity.isFinite ||
        e.storefrontTextSimilarity < 0 ||
        e.storefrontTextSimilarity > 1 ||
        !e.storefrontReferenceNameSimilarity.isFinite ||
        e.storefrontReferenceNameSimilarity < 0 ||
        e.storefrontReferenceNameSimilarity > 1 ||
        !e.storefrontExpectedNameSimilarity.isFinite ||
        e.storefrontExpectedNameSimilarity < 0 ||
        e.storefrontExpectedNameSimilarity > 1 ||
        !e.storefrontStructureSimilarity.isFinite ||
        e.storefrontStructureSimilarity < 0 ||
        e.storefrontStructureSimilarity > 1) {
      return const PhotoMatchDecision(
        TripPathPhotoMatchStatus.error,
        'invalid_evidence',
        'Photo comparison produced invalid evidence. Try again.',
      );
    }

    final theme = e.themeId.trim().toLowerCase();
    final kind = e.referenceKind.trim().toLowerCase();
    final nature = theme == 'nature' || kind.startsWith('nature_');
    final storefrontLike = const {
      'storefront_exterior',
      'food_stall_or_kiosk',
    }.contains(kind);

    // V37 theme-aware profiles. Large fixed landmarks need different
    // tolerance from storefronts and repetitive nature scenes.
    final largeLandmarkLike =
        !storefrontLike &&
        (kind == 'building_exterior' ||
            theme == 'culture' ||
            theme == 'heritage');

    final storefrontReferenceIdentityReadable =
        e.storefrontReferenceNameSimilarity >= 0.68;
    final storefrontIdentityConfirmed =
        e.storefrontExpectedNameSimilarity >= 0.68;
    final storefrontPairTextConfirmed = e.storefrontTextSimilarity >= 0.72;
    // If the reference clearly shows the selected shop name, daytime matches
    // should normally reproduce that identity. At night OCR may disappear, so
    // the dedicated night path is allowed to rely on strong geometry instead.
    final storefrontIdentitySupported =
        !storefrontReferenceIdentityReadable ||
        storefrontIdentityConfirmed ||
        storefrontPairTextConfirmed;

    // V46 PRIMARY-ANCHOR PRINCIPLE:
    // When the trusted exterior reference visibly exposes the checkpoint
    // identity, generic surrounding environment is not allowed to borrow a
    // storefront match path. Identity/text must support the local match, or
    // the result must be reviewed by the AI anchor contract in the ViewModel.
    // Conversely, identity alone is still not enough: every MATCHED path below
    // keeps real facade geometry/coverage requirements, so a sign-only crop
    // cannot be treated as a complete storefront visit.
    final fusion = fuse(e);

    // V27 STOREFRONT IDENTITY GUARD
    // Geometry alone can confuse neighbouring shop rows that share railings,
    // columns and facade proportions. If OCR provides strong evidence that the
    // captured shop identity conflicts with the selected checkpoint, fail fast.
    // OCR absence is NOT a conflict, so night/glare captures can still use the
    // geometric storefront paths below.
    if (storefrontLike && e.storefrontIdentityConflict) {
      return const PhotoMatchDecision(
        TripPathPhotoMatchStatus.notMatched,
        'storefront_identity_mismatch',
        'The visible storefront identity does not match this checkpoint. Make sure you are photographing the correct shop.',
      );
    }

    // V20/V21: five reciprocal correspondences may reach the storefront
    // policy, but only with >=4 RANSAC inliers plus either the original strong
    // distinctive-text path or V21's stricter OCR-independent facade path.
    // The normal non-storefront floor remains unchanged.
    final sparseStorefrontException =
        storefrontLike &&
        e.goodMatches >= 5 &&
        e.inliers >= 4 &&
        ((e.ratio >= 0.22 &&
                (e.storefrontTextSimilarity >= 0.88 ||
                    storefrontIdentityConfirmed) &&
                e.storefrontStructureSimilarity >= 0.62 &&
                e.globalSimilarity >= 0.30) ||
            (e.ratio >= 0.55 &&
                e.reference.coversSparseStorefrontFacade(
                  minWidthSpan: 0.25,
                  minHeightSpan: 0.07,
                  minHullArea: 0.008,
                ) &&
                e.captured.coversSparseStorefrontFacade(
                  minWidthSpan: 0.25,
                  minHeightSpan: 0.07,
                  minHullArea: 0.008,
                ) &&
                e.storefrontStructureSimilarity >= 0.75 &&
                e.globalSimilarity >= 0.56));

    // V23 early storefront triage. Facade/global resemblance is deliberately
    // NOT enough for RETAKE: rows of unrelated shops can look structurally
    // similar. We need either credible geometric consistency or distinctive
    // shared text before treating a weak match as a plausible same-place
    // capture problem.
    // V34: RETAKE must mean "probably the same storefront", not merely
    // "some shop-like geometry exists". A weak 3-inlier resemblance is too
    // easy for neighbouring shop lots, railings and columns to reproduce.
    // Identity/text can still justify an early RETAKE; geometry-only RETAKE
    // now needs substantially stronger fixed-facade consensus.
    final earlyStorefrontUncertain =
        storefrontLike &&
        e.goodMatches >= 4 &&
        e.storefrontStructureSimilarity >= 0.60 &&
        e.globalSimilarity >= 0.40 &&
        (storefrontIdentityConfirmed ||
            e.storefrontTextSimilarity >= 0.72 ||
            (e.inliers >= 4 &&
                e.ratio >= 0.45 &&
                e.storefrontStructureSimilarity >= 0.72 &&
                e.globalSimilarity >= 0.50));

    // V37: close/low-angle views of large fixed landmarks can keep only a
    // smaller set of highly consistent correspondences. Do not hard-fail them
    // before the dedicated partial-view bridge gets a chance to adjudicate.
    final sparseLargeLandmarkException =
        largeLandmarkLike &&
        e.goodMatches >= 5 &&
        e.inliers >= 4 &&
        e.ratio >= 0.32 &&
        e.globalSimilarity >= (e.lightingNormalized ? 0.28 : 0.32);

    if (!sparseStorefrontException &&
        !sparseLargeLandmarkException &&
        (e.goodMatches < 6 || e.inliers < 4 || e.ratio < 0.22)) {
      if (earlyStorefrontUncertain) {
        return const PhotoMatchDecision(
          TripPathPhotoMatchStatus.retake,
          'storefront_borderline_evidence',
          'This may be the same storefront, but the evidence is not stable enough yet. Retake with more of the fixed facade and signboard visible.',
        );
      }
      return const PhotoMatchDecision(
        TripPathPhotoMatchStatus.notMatched,
        'no_shared_structure',
        'This photo does not match the checkpoint strongly enough. Check the place and photograph the same physical landmark or storefront.',
      );
    }

    bool spread(double width, double height, double area, int cells) =>
        e.reference.covers(
          width: width,
          height: height,
          area: area,
          cells: cells,
        ) &&
        e.captured.covers(
          width: width,
          height: height,
          area: area,
          cells: cells,
        );

    bool geometry(int good, int inliers, double ratio) =>
        e.goodMatches >= good &&
        e.inliers >= inliers &&
        e.ratio >= ratio;

    bool perspectiveSpread(
      double longSpan,
      double shortSpan,
      double area,
      int cells,
    ) =>
        e.reference.coversPerspective(
          longSpan: longSpan,
          shortSpan: shortSpan,
          area: area,
          cells: cells,
        ) &&
        e.captured.coversPerspective(
          longSpan: longSpan,
          shortSpan: shortSpan,
          area: area,
          cells: cells,
        );

    if (nature) {
      // Parks/paths/gardens are visually repetitive, so Nature remains stricter.
      final distinctive = kind == 'nature_distinctive_landmark';

      final wholeLayout =
          geometry(26, 16, 0.55) &&
          spread(0.35, 0.24, 0.055, 4) &&
          e.globalSimilarity >= 0.76;

      final fixedAnchor =
          distinctive &&
          geometry(24, 15, 0.55) &&
          spread(0.28, 0.20, 0.040, 4);

      // V27 NATURE DAY/NIGHT BRIDGE
      // Nature scenes lose many local descriptors after dark. Keep the global
      // threshold deliberately high because foliage/path textures repeat, but
      // permit a lower descriptor count when RANSAC still covers a real 2-D
      // fixed scene footprint (path/bridge/rock/pavilion and surroundings).
      final dayNightNature =
          e.lightingNormalized &&
          geometry(14, 8, 0.42) &&
          perspectiveSpread(0.24, 0.12, 0.020, 3) &&
          e.globalSimilarity >= (distinctive ? 0.56 : 0.64);

      // V37 NATURE SCENE ROBUSTNESS BRIDGE
      // Nature changes with weather, vegetation and water level, so require a
      // combination of geometry + broad 2-D layout + whole-scene support.
      // This deliberately cannot be triggered by one tree, a patch of grass,
      // sky, or a generic water surface alone.
      final v37NatureSceneBridge =
          geometry(e.lightingNormalized ? 10 : 12,
              e.lightingNormalized ? 6 : 7,
              e.lightingNormalized ? 0.38 : 0.42) &&
          perspectiveSpread(0.20, 0.09, 0.012, 3) &&
          e.globalSimilarity >=
              (distinctive
                  ? (e.lightingNormalized ? 0.48 : 0.52)
                  : (e.lightingNormalized ? 0.56 : 0.60)) &&
          fusion.score >= (e.lightingNormalized ? 0.64 : 0.67) &&
          fusion.geometryScore >= 0.48 &&
          fusion.footprintScore >= 0.38;

      if (wholeLayout || fixedAnchor || dayNightNature || v37NatureSceneBridge) {
        return PhotoMatchDecision(
          TripPathPhotoMatchStatus.matched,
          v37NatureSceneBridge ? 'v37_nature_scene_bridge' : 'nature_structure',
          v37NatureSceneBridge
              ? 'Your photo matches this nature checkpoint. Broad scene layout and fixed structural evidence agree despite normal environmental variation.'
              : 'Matching nature structure and scene layout were confirmed.',
        );
      }

      // V31: fuse the same single-reference evidence before declaring a false
      // negative. Nature stays stricter because vegetation and paths repeat.
      final natureFusionMatched =
          fusion.score >= 0.76 &&
          fusion.geometryScore >= 0.58 &&
          fusion.footprintScore >= 0.50 &&
          fusion.sceneScore >= (distinctive ? 0.52 : 0.58);
      if (natureFusionMatched) {
        return const PhotoMatchDecision(
          TripPathPhotoMatchStatus.matched,
          'v31_nature_evidence_fusion',
          'Your photo matches this nature checkpoint. Multiple independent scene and geometry signals agree on the same place.',
        );
      }

      final dayNightNatureUncertain =
          e.lightingNormalized &&
          e.goodMatches >= 8 &&
          e.inliers >= 5 &&
          e.ratio >= 0.32 &&
          e.globalSimilarity >= 0.52 &&
          e.reference.coversPerspective(
            longSpan: 0.18, shortSpan: 0.07, area: 0.009, cells: 3) &&
          e.captured.coversPerspective(
            longSpan: 0.18, shortSpan: 0.07, area: 0.009, cells: 3);
      if (dayNightNatureUncertain) {
        return const PhotoMatchDecision(
          TripPathPhotoMatchStatus.retake,
          'nature_day_night_uncertain',
          'This may be the same nature checkpoint, but the lighting difference leaves too little stable structure. Retake with the same fixed path, bridge, rock or pavilion and more surroundings visible.',
        );
      }

      if (e.goodMatches < 10 || e.inliers < 7 || e.ratio < 0.30) {
        return const PhotoMatchDecision(
          TripPathPhotoMatchStatus.notMatched,
          'nature_structure_mismatch',
          'This photo does not provide a reliable match to the nature checkpoint. Photograph the same path section or fixed landmark.',
        );
      }

      return const PhotoMatchDecision(
        TripPathPhotoMatchStatus.retake,
        'nature_layout_uncertain',
        'Some details are similar, but they do not confirm the same nature viewpoint. Include the same path, bridge, rock or other fixed feature and its surroundings.',
      );
    }

    final physical =
        const {'food', 'culture', 'heritage'}.contains(theme) ||
        const {
          'storefront_exterior',
          'food_stall_or_kiosk',
          'building_exterior',
        }.contains(kind);

    // V19/V20 are profile-based, not Food-theme-only. Any reference that the
    // existing reference-photo screening classified as a storefront/open
    // front can use the storefront robustness paths below.

    bool wideStorefrontBand({
      required double minWidth,
      required double minHeight,
      required double minHull,
      required int minCells,
      required int minCols,
    }) =>
        e.reference.coversWideStorefrontBand(
          minWidthSpan: minWidth,
          minHeightSpan: minHeight,
          minHullArea: minHull,
          minCells: minCells,
          minCols: minCols,
        ) &&
        e.captured.coversWideStorefrontBand(
          minWidthSpan: minWidth,
          minHeightSpan: minHeight,
          minHullArea: minHull,
          minCells: minCells,
          minCols: minCols,
        );

    bool sparseStorefrontFacade({
      required double minWidth,
      required double minHeight,
      required double minHull,
    }) =>
        e.reference.coversSparseStorefrontFacade(
          minWidthSpan: minWidth,
          minHeightSpan: minHeight,
          minHullArea: minHull,
        ) &&
        e.captured.coversSparseStorefrontFacade(
          minWidthSpan: minWidth,
          minHeightSpan: minHeight,
          minHullArea: minHull,
        );

    // V23 LOW-CONSENSUS STOREFRONT MISMATCH
    // Real-device negative example: 25 descriptor matches but only 6 RANSAC
    // inliers (24%), OCR 0%, while coarse facade/global scores were high. That
    // is characteristic of many ambiguous local features, not a photo-quality
    // problem. Do not spend the RETAKE bucket on it.
    final storefrontGeometryMismatch =
        storefrontLike &&
        e.goodMatches >= 8 &&
        e.inliers >= 4 &&
        e.ratio < 0.30 &&
        !storefrontIdentityConfirmed &&
        !storefrontPairTextConfirmed;
    if (storefrontGeometryMismatch) {
      return const PhotoMatchDecision(
        TripPathPhotoMatchStatus.notMatched,
        'storefront_geometry_mismatch',
        'The storefront has some similar-looking details, but the geometric matches do not agree strongly enough. Make sure you are photographing the correct checkpoint.',
      );
    }

    // V13 WHOLE-SCENE GATE
    // A small crop can have excellent ORB/RANSAC numbers. Therefore MATCHED
    // must cover a meaningful 2-D footprint in BOTH the reference and capture.
    final standardWholeScene =
        !storefrontLike &&
        geometry(24, 15, 0.55) &&
        spread(0.28, 0.21, 0.038, 4);

    // Real camera viewpoint changes are allowed, but still need four spatial
    // cells and a meaningful 2-D hull. This remains the normal path.
    final physicalViewpoint =
        physical &&
        !storefrontLike &&
        geometry(21, 13, 0.50) &&
        spread(0.24, 0.18, 0.030, 4);

    // V19 WIDE STOREFRONT / TEMPORARY-OCCLUSION BRIDGE
    // Cars, people and tables can hide the lower half of a real storefront,
    // leaving the long fascia/sign and upper facade as the strongest stable
    // geometry. Permit a one-row footprint only with strong RANSAC evidence,
    // broad width in BOTH images and corroborating whole-image similarity.
    final wideStorefrontOcclusion =
        storefrontLike &&
        storefrontIdentitySupported &&
        geometry(32, 22, 0.60) &&
        wideStorefrontBand(
          minWidth: 0.50,
          minHeight: 0.045,
          minHull: 0.018,
          minCells: 2,
          minCols: 2,
        ) &&
        e.globalSimilarity >= 0.56;

    // V19 TEXT-ANCHORED STOREFRONT BRIDGE
    // Day/night lighting and oblique views may leave only a handful of ORB
    // correspondences. On-device OCR can be used as an independent anchor,
    // but only together with successful RANSAC, a broad facade footprint in
    // BOTH images, and plausible global scene structure. Generic words such
    // as RESTAURANT/CAFE/SHOP are removed before this score is computed.
    final textAnchoredStorefront =
        storefrontLike &&
        storefrontIdentitySupported &&
        e.storefrontTextSimilarity >= 0.72 &&
        geometry(8, 4, 0.30) &&
        sparseStorefrontFacade(
          minWidth: 0.40,
          minHeight: 0.12,
          minHull: 0.022,
        ) &&
        e.globalSimilarity >= 0.42;

    // V20 ADAPTIVE STOREFRONT BRIDGE
    // Real storefront captures can differ in three ways at once: moving
    // people/cars/tables obscure the lower facade, night lighting changes local
    // descriptors, and a closer/oblique camera angle compresses the surviving
    // geometry. Four RANSAC inliers are still mandatory. We then require:
    // - distinctive OCR agreement (not generic RESTAURANT/CAFE words),
    // - stable upper-facade edge structure,
    // - a non-trivial width + height span in BOTH images, and
    // - some full-frame scene agreement.
    //
    // Two or more distinctive shared text tokens (score >= .88) may use the
    // five-match path. A weaker single long token (score >= .72) still needs
    // at least eight descriptor matches and stronger full-frame support.
    final adaptiveStorefront =
        storefrontLike &&
        storefrontIdentitySupported &&
        geometry(5, 4, 0.22) &&
        sparseStorefrontFacade(
          minWidth: 0.28,
          minHeight: 0.08,
          minHull: 0.0,
        ) &&
        e.storefrontStructureSimilarity >= 0.62 &&
        e.globalSimilarity >= 0.30 &&
        (e.storefrontTextSimilarity >= 0.88 ||
            (e.storefrontTextSimilarity >= 0.72 &&
                e.goodMatches >= 8 &&
                e.globalSimilarity >= 0.42));


    // V27 EXPECTED-IDENTITY STOREFRONT BRIDGE
    // When the checkpoint name is actually visible in the captured photo, it
    // is a much safer anchor than generic railings/columns shared by adjacent
    // shop rows. This path is intentionally paired with RANSAC + a real 2-D
    // facade footprint; OCR alone can never verify a visit.
    final identityAnchoredStorefront =
        storefrontLike &&
        storefrontIdentityConfirmed &&
        geometry(6, 4, 0.32) &&
        sparseStorefrontFacade(
          minWidth: 0.20,
          minHeight: 0.055,
          minHull: 0.004,
        ) &&
        e.storefrontStructureSimilarity >= 0.58 &&
        e.globalSimilarity >= 0.34;

    // V21 HIGH-STRUCTURE STOREFRONT BRIDGE
    // OCR is supplementary when the reference itself has no readable shop
    // identity. If the reference clearly exposes the selected shop name, V28
    // requires positive identity support before this geometry-only fallback
    // may auto-verify. The structural gate remains strict: >=5 reciprocal
    // matches, >=4 RANSAC inliers,
    // >=55% inlier ratio, a genuine 2-D inlier footprint in BOTH images,
    // strong stable-facade similarity, and strong whole-frame support.
    // A sign-only crop is blocked by the hull/vertical-footprint requirement.
    final highStructureStorefront =
        storefrontLike &&
        storefrontIdentitySupported &&
        geometry(5, 4, 0.55) &&
        sparseStorefrontFacade(
          minWidth: 0.25,
          minHeight: 0.07,
          minHull: 0.008,
        ) &&
        e.storefrontStructureSimilarity >= 0.75 &&
        e.globalSimilarity >= 0.56;

    // V22 STABLE STOREFRONT CONSENSUS
    // Real-device testing showed that the same shop can keep excellent facade
    // and whole-scene agreement while RANSAC inliers compress into a thinner
    // band. This path slightly relaxes only the inlier footprint, not the
    // identity evidence: >=7 reciprocal matches, >=4 inliers, >=50% ratio,
    // strong fixed-facade similarity and strong whole-frame similarity are
    // still required together.
    final stableStorefrontConsensus =
        storefrontLike &&
        storefrontIdentitySupported &&
        geometry(7, 4, 0.50) &&
        sparseStorefrontFacade(
          minWidth: 0.18,
          minHeight: 0.04,
          minHull: 0.004,
        ) &&
        e.storefrontStructureSimilarity >= 0.74 &&
        e.globalSimilarity >= 0.55;

    // V23 NIGHT STOREFRONT CONSENSUS
    // Preserve the day/night geometry that worked before V22 widened the ORB
    // candidate pool. V28 keeps OCR optional only when the reference has no
    // readable shop identity. Otherwise positive identity support is required
    // before a lighting-normalized storefront may auto-verify with fewer
    // correspondences when RANSAC still has meaningful
    // consensus and the fixed facade + whole frame independently agree. The
    // 0.38 ratio floor deliberately excludes the user's unrelated 24% case.
    final nightStorefrontConsensus =
        storefrontLike &&
        e.lightingNormalized &&
        storefrontIdentitySupported &&
        geometry(6, 4, 0.38) &&
        sparseStorefrontFacade(
          minWidth: 0.20,
          minHeight: 0.05,
          minHull: 0.004,
        ) &&
        e.storefrontStructureSimilarity >= 0.72 &&
        e.globalSimilarity >= 0.48;

    // V25 BALANCED SCALE / DISTANCE BRIDGE
    // Real-device testing showed that normal closer/farther captures could
    // fall into RETAKE even when the same fixed facade was clearly present.
    // The cause was mainly the symmetric scene-spread gate: after a scale
    // change, the shared inliers can cover a smaller fraction of the farther
    // image while covering a much larger fraction of the closer image.
    //
    // This bridge therefore keeps strong RANSAC consensus, requires a real
    // 2-D footprint in BOTH images, and requires at least one side to cover a
    // broader footprint. It does NOT lower the unrelated-photo guard and it
    // deliberately does not handle lighting-normalized/night pairs; the
    // existing dedicated day/night paths remain responsible for those.
    bool scaleSideMinimum(MatchSpread s) =>
        s.widthSpan >= 0.14 &&
        s.heightSpan >= 0.09 &&
        s.hullArea >= 0.010 &&
        s.occupiedCells >= 3 &&
        s.distinctRows >= 2 &&
        s.distinctCols >= 2;

    bool scaleSideBroad(MatchSpread s) =>
        s.widthSpan >= 0.20 &&
        s.heightSpan >= 0.13 &&
        s.hullArea >= 0.018 &&
        s.occupiedCells >= 3 &&
        s.distinctRows >= 2 &&
        s.distinctCols >= 2;

    final balancedScaleViewpoint =
        physical &&
        !storefrontLike &&
        !e.lightingNormalized &&
        geometry(20, 12, 0.52) &&
        scaleSideMinimum(e.reference) &&
        scaleSideMinimum(e.captured) &&
        (scaleSideBroad(e.reference) || scaleSideBroad(e.captured)) &&
        e.globalSimilarity >= 0.36;


    // Storefront-specific closer/farther bridge. If the reference exposes a
    // readable shop identity, require that identity in a normal-light capture;
    // this is what prevents a neighbouring shop with the same building frame
    // from borrowing the generic V25 scale bridge.
    final storefrontScaleViewpoint =
        storefrontLike &&
        !e.lightingNormalized &&
        storefrontIdentitySupported &&
        geometry(12, 7, 0.42) &&
        scaleSideMinimum(e.reference) &&
        scaleSideMinimum(e.captured) &&
        (scaleSideBroad(e.reference) || scaleSideBroad(e.captured)) &&
        e.storefrontStructureSimilarity >= 0.56 &&
        e.globalSimilarity >= 0.34;


    // V34 DAY/NIGHT + VIEWPOINT STOREFRONT BRIDGE
    // A genuine player can be closer/farther, slightly left/right, or hold the
    // phone higher/lower while also crossing from day to night. Previously the
    // normal storefront scale bridge was disabled whenever CLAHE lighting
    // normalization was active, which pushed these valid captures into RETAKE.
    //
    // This bridge does NOT lower the wrong-shop gate: when the Google reference
    // exposes a readable place identity, positive captured identity/text is
    // mandatory. Geometry, facade structure and whole-scene evidence are still
    // required, so a similar shop row or same-colour object cannot use it.
    final v34StorefrontIdentityPositive =
        storefrontIdentityConfirmed || storefrontPairTextConfirmed;
    final dayNightStorefrontViewpointBridge =
        storefrontLike &&
        e.lightingNormalized &&
        v34StorefrontIdentityPositive &&
        geometry(6, 4, 0.34) &&
        sparseStorefrontFacade(
          minWidth: 0.16,
          minHeight: 0.035,
          minHull: 0.003,
        ) &&
        e.storefrontStructureSimilarity >= 0.62 &&
        e.globalSimilarity >= 0.34 &&
        fusion.score >= 0.58 &&
        fusion.geometryScore >= 0.40;

    // If the reference itself has no readable shop identity, OCR cannot be a
    // mandatory anchor. Permit day/night viewpoint recovery only with much
    // stronger fixed-facade and scene consensus than the identity-positive
    // bridge above.
    final dayNightStorefrontNoIdentityBridge =
        storefrontLike &&
        e.lightingNormalized &&
        !storefrontReferenceIdentityReadable &&
        geometry(10, 6, 0.50) &&
        sparseStorefrontFacade(
          minWidth: 0.22,
          minHeight: 0.06,
          minHull: 0.006,
        ) &&
        e.storefrontStructureSimilarity >= 0.78 &&
        e.globalSimilarity >= 0.56;

    // V35 SINGLE-REFERENCE AUGMENTATION SAFETY BRIDGE
    // Internal reference augmentation is approximated conservatively here by
    // recognising the asymmetric inlier footprint that a closer/farther crop,
    // mild height change or slight oblique framing produces. This only helps
    // when identity / fixed-facade evidence already supports the same place;
    // it is NOT a generic easier-threshold path for unrelated storefronts.
    bool augmentedAsymmetry(MatchSpread a, MatchSpread b) {
      final minWidth = math.max(0.001, math.min(a.widthSpan, b.widthSpan));
      final maxWidth = math.max(a.widthSpan, b.widthSpan);
      final minHeight = math.max(0.001, math.min(a.heightSpan, b.heightSpan));
      final maxHeight = math.max(a.heightSpan, b.heightSpan);
      final minHull = math.max(0.0005, math.min(a.hullArea, b.hullArea));
      final maxHull = math.max(a.hullArea, b.hullArea);
      final widthScale = maxWidth / minWidth;
      final heightScale = maxHeight / minHeight;
      final hullScale = maxHull / minHull;
      return a.occupiedCells >= 3 &&
          b.occupiedCells >= 3 &&
          a.distinctRows >= 2 &&
          b.distinctRows >= 2 &&
          a.distinctCols >= 2 &&
          b.distinctCols >= 2 &&
          (widthScale >= 1.18 || heightScale >= 1.18 || hullScale >= 1.45);
    }

    final v35SingleReferenceAugmentedStorefront =
        storefrontLike &&
        augmentedAsymmetry(e.reference, e.captured) &&
        (v34StorefrontIdentityPositive ||
            (!storefrontReferenceIdentityReadable &&
                fusion.structureScore >= 0.70 &&
                fusion.sceneScore >= 0.50)) &&
        geometry(e.lightingNormalized ? 5 : 6, 4,
            e.lightingNormalized ? 0.32 : 0.36) &&
        sparseStorefrontFacade(
          minWidth: e.lightingNormalized ? 0.14 : 0.16,
          minHeight: e.lightingNormalized ? 0.030 : 0.035,
          minHull: e.lightingNormalized ? 0.0025 : 0.0030,
        ) &&
        e.storefrontStructureSimilarity >=
            (e.lightingNormalized ? 0.60 : 0.56) &&
        e.globalSimilarity >= 0.32 &&
        fusion.score >= (e.lightingNormalized ? 0.58 : 0.60) &&
        fusion.geometryScore >= 0.38 &&
        fusion.footprintScore >= 0.28 &&
        fusion.structureScore >= (e.lightingNormalized ? 0.48 : 0.46);

    // V14 CLOSER / FARTHER VIEWPOINT BRIDGE
    // A user can legitimately stand a few metres closer or farther away than
    // the reference photographer. Zoom/perspective changes can concentrate the
    // surviving RANSAC inliers into three grid cells even when the same fixed
    // building/landmark is clearly present. Allow that case only when the
    // reciprocal descriptor + homography evidence is substantially stronger.
    //
    // We intentionally KEEP a minimum 2-D footprint (3 cells, 2 rows/cols,
    // non-trivial hull), so a tiny sign/logo/window crop still cannot pass.
    final strongViewpointShift =
        physical &&
        !storefrontLike &&
        geometry(26, 17, 0.58) &&
        spread(0.18, 0.13, 0.018, 3);

    // V15 MODERATE VIEWING-ANGLE BRIDGE
    // A real left/right or slightly elevated viewpoint can foreshorten one
    // axis of a building facade. Accept that perspective compression only
    // when reciprocal ORB + RANSAC evidence is very strong and the inliers
    // still occupy a genuine 2-D footprint in BOTH images. This is NOT a
    // generic angle bypass: a tiny sign/window crop cannot satisfy the
    // longest-span, hull-area and 3-cell requirements.
    final moderateViewingAngle =
        physical &&
        !storefrontLike &&
        geometry(28, 18, 0.60) &&
        perspectiveSpread(0.18, 0.09, 0.013, 3);

    // Day/night path: lighting normalization may reduce the number of stable
    // descriptors. We relax match COUNTS only when the whole image still has
    // corroborating global structure. Spatial coverage is NOT relaxed to a
    // tiny sign/corner, so a crop cannot use this path.
    final dayNightStructuralBridge =
        physical &&
        !storefrontLike &&
        e.lightingNormalized &&
        geometry(18, 11, 0.48) &&
        spread(0.20, 0.16, 0.022, 3) &&
        e.globalSimilarity >= 0.56;

    // V27 BALANCED DAY/NIGHT BRIDGE FOR CULTURE / HERITAGE / BUILDINGS
    // A lit facade can keep reliable geometric layout while descriptor counts
    // fall below the older 18/11 threshold. Storefronts are excluded because
    // they use identity-aware paths; nature has its own stricter branch above.
    final balancedDayNightPhysical =
        physical &&
        !storefrontLike &&
        e.lightingNormalized &&
        geometry(12, 7, 0.42) &&
        perspectiveSpread(0.18, 0.08, 0.010, 3) &&
        e.globalSimilarity >= 0.52;

    // V37 LARGE LANDMARK PARTIAL-VIEW + PERSPECTIVE BRIDGE
    // Towers, temples, churches, monuments and historic buildings are often
    // photographed from much closer / lower than the Google reference. The
    // full silhouette may disappear, but a large fixed structural region can
    // still be geometrically consistent. Require a real 2-D footprint in both
    // images and one broad side, plus fused scene evidence. Storefronts and
    // Nature are intentionally excluded because their false-positive modes are
    // different.
    bool landmarkSideMinimum(MatchSpread s) =>
        s.widthSpan >= 0.12 &&
        s.heightSpan >= 0.08 &&
        s.hullArea >= 0.007 &&
        s.occupiedCells >= 3 &&
        s.distinctRows >= 2 &&
        s.distinctCols >= 2;

    bool landmarkSideBroad(MatchSpread s) =>
        s.widthSpan >= 0.20 &&
        s.heightSpan >= 0.13 &&
        s.hullArea >= 0.016 &&
        s.occupiedCells >= 3 &&
        s.distinctRows >= 2 &&
        s.distinctCols >= 2;

    final v37LargeLandmarkPartialView =
        largeLandmarkLike &&
        geometry(e.lightingNormalized ? 8 : 10,
            e.lightingNormalized ? 5 : 6,
            e.lightingNormalized ? 0.36 : 0.40) &&
        landmarkSideMinimum(e.reference) &&
        landmarkSideMinimum(e.captured) &&
        (landmarkSideBroad(e.reference) || landmarkSideBroad(e.captured)) &&
        e.globalSimilarity >= (e.lightingNormalized ? 0.30 : 0.34) &&
        fusion.score >= (e.lightingNormalized ? 0.57 : 0.60) &&
        fusion.geometryScore >= 0.44 &&
        fusion.footprintScore >= 0.30;

    // Food stalls/open-front shops may have moving people/tables. Keep a
    // bounded fallback, but require stronger scene footprint than V11/V12.
    final foodOpenFront =
        (theme == 'food' || kind == 'food_stall_or_kiosk') &&
        (!storefrontLike || storefrontIdentitySupported) &&
        geometry(18, 11, 0.50) &&
        spread(0.26, 0.19, 0.032, 4) &&
        e.globalSimilarity >= 0.50;

    if (standardWholeScene ||
        physicalViewpoint ||
        wideStorefrontOcclusion ||
        textAnchoredStorefront ||
        adaptiveStorefront ||
        identityAnchoredStorefront ||
        highStructureStorefront ||
        stableStorefrontConsensus ||
        nightStorefrontConsensus ||
        storefrontScaleViewpoint ||
        dayNightStorefrontViewpointBridge ||
        dayNightStorefrontNoIdentityBridge ||
        v35SingleReferenceAugmentedStorefront ||
        balancedScaleViewpoint ||
        strongViewpointShift ||
        moderateViewingAngle ||
        dayNightStructuralBridge ||
        balancedDayNightPhysical ||
        v37LargeLandmarkPartialView ||
        foodOpenFront) {
      final reason = wideStorefrontOcclusion &&
              !standardWholeScene &&
              !physicalViewpoint
          ? 'storefront_occlusion_structure'
          : textAnchoredStorefront &&
                  !standardWholeScene &&
                  !physicalViewpoint
              ? 'storefront_text_structure'
              : adaptiveStorefront &&
                      !standardWholeScene &&
                      !physicalViewpoint
                  ? 'storefront_adaptive_structure'
                  : identityAnchoredStorefront &&
                          !standardWholeScene &&
                          !physicalViewpoint
                      ? 'storefront_expected_identity'
                      : highStructureStorefront &&
                          !standardWholeScene &&
                          !physicalViewpoint
                      ? 'storefront_high_structure'
                      : stableStorefrontConsensus &&
                              !standardWholeScene &&
                              !physicalViewpoint
                          ? 'storefront_stable_consensus'
                      : nightStorefrontConsensus &&
                              !standardWholeScene &&
                              !physicalViewpoint
                          ? 'storefront_night_consensus'
                      : storefrontScaleViewpoint &&
                              !standardWholeScene &&
                              !physicalViewpoint
                          ? 'storefront_scale_viewpoint'
                      : dayNightStorefrontViewpointBridge &&
                              !standardWholeScene &&
                              !physicalViewpoint
                          ? 'v34_storefront_day_night_viewpoint'
                      : dayNightStorefrontNoIdentityBridge &&
                              !standardWholeScene &&
                              !physicalViewpoint
                          ? 'v34_storefront_day_night_strong_geometry'
                      : v35SingleReferenceAugmentedStorefront &&
                              !standardWholeScene &&
                              !physicalViewpoint
                          ? 'v35_single_reference_augmented_storefront'
                      : balancedScaleViewpoint &&
                              !standardWholeScene &&
                              !physicalViewpoint
                          ? 'balanced_scale_viewpoint'
                      : moderateViewingAngle &&
                      !standardWholeScene &&
                      !physicalViewpoint &&
                      !strongViewpointShift
                  ? 'moderate_viewing_angle'
                  : strongViewpointShift &&
                          !standardWholeScene &&
                          !physicalViewpoint
                      ? 'strong_viewpoint_shift'
                      : dayNightStructuralBridge &&
                              !standardWholeScene &&
                              !physicalViewpoint
                          ? 'day_night_structure'
                          : balancedDayNightPhysical &&
                                  !standardWholeScene &&
                                  !physicalViewpoint
                              ? 'balanced_day_night_structure'
                              : v37LargeLandmarkPartialView &&
                                      !standardWholeScene &&
                                      !physicalViewpoint
                                  ? 'v37_large_landmark_partial_view'
                              : foodOpenFront &&
                                  !standardWholeScene &&
                                  !physicalViewpoint
                              ? 'food_open_front_structure'
                              : 'physical_structure';

      return PhotoMatchDecision(
        TripPathPhotoMatchStatus.matched,
        reason,
        reason == 'v35_single_reference_augmented_storefront'
            ? (e.lightingNormalized
                ? 'Your photo matches this storefront. Identity, facade and scene evidence remain consistent despite the lighting and viewpoint difference.'
                : 'Your photo matches this storefront. Identity, facade and scene evidence remain consistent despite the viewpoint difference.')
            : reason == 'v37_large_landmark_partial_view'
                ? (e.lightingNormalized
                    ? 'Your photo matches this large landmark. Fixed structural geometry remains consistent despite the closer viewpoint and lighting difference.'
                    : 'Your photo matches this large landmark. Fixed structural geometry remains consistent despite the closer or lower viewpoint.')
            : e.lightingNormalized
                ? 'Your photo matches this checkpoint. Shared structure was confirmed despite the lighting difference.'
                : 'Your photo matches this checkpoint. Shared structure was confirmed across the two views.',
      );
    }

    // V29 SAME-STOREFRONT RECOVERY
    // OCR can miss the correct shop name because of glare, stylized fonts,
    // distance or partial cropping. Do not make readable reference identity a
    // hard dependency when the fixed storefront geometry is independently
    // overwhelming and there is no explicit alternative-brand conflict.
    // This recovery is deliberately much stricter than the normal storefront
    // paths so neighbouring shop lots cannot pass on generic columns/railings.
    final strongSameStorefrontRecovery =
        storefrontLike &&
        storefrontReferenceIdentityReadable &&
        !storefrontIdentitySupported &&
        !e.storefrontIdentityConflict &&
        geometry(e.lightingNormalized ? 10 : 12,
            e.lightingNormalized ? 6 : 8,
            e.lightingNormalized ? 0.50 : 0.58) &&
        sparseStorefrontFacade(
          minWidth: e.lightingNormalized ? 0.24 : 0.28,
          minHeight: e.lightingNormalized ? 0.07 : 0.085,
          minHull: e.lightingNormalized ? 0.007 : 0.010,
        ) &&
        e.storefrontStructureSimilarity >=
            (e.lightingNormalized ? 0.80 : 0.82) &&
        e.globalSimilarity >= (e.lightingNormalized ? 0.58 : 0.62);

    if (strongSameStorefrontRecovery) {
      return PhotoMatchDecision(
        TripPathPhotoMatchStatus.matched,
        'storefront_strong_same_place_recovery',
        e.lightingNormalized
            ? 'Your photo matches this storefront. Strong fixed-facade geometry confirms the same place despite the lighting and OCR difference.'
            : 'Your photo matches this storefront. Strong fixed-facade geometry confirms the same place even though the shop text was not read clearly.',
      );
    }

    // V31 SINGLE-REFERENCE EVIDENCE FUSION
    // This adjudicates cases where no one legacy bridge is individually strong
    // enough, but several independent signals consistently support the same
    // physical place. A readable storefront identity remains privileged; if it
    // disappears, auto-verify needs overwhelming geometry + facade + scene.
    final v31StorefrontIdentityPositive =
        storefrontIdentityConfirmed || storefrontPairTextConfirmed;
    final v31StorefrontRecovery =
        storefrontLike &&
        storefrontReferenceIdentityReadable &&
        !v31StorefrontIdentityPositive &&
        fusion.score >= 0.78 &&
        fusion.geometryScore >= 0.72 &&
        fusion.footprintScore >= 0.52 &&
        fusion.structureScore >= 0.78 &&
        fusion.sceneScore >= 0.56;
    final v31StorefrontIdentityFusion =
        storefrontLike &&
        v31StorefrontIdentityPositive &&
        fusion.score >= (e.lightingNormalized ? 0.64 : 0.66) &&
        fusion.geometryScore >= 0.46 &&
        fusion.footprintScore >= 0.34 &&
        fusion.structureScore >= 0.50 &&
        fusion.sceneScore >= 0.32;
    final v31StorefrontNoReadableIdentityFusion =
        storefrontLike &&
        !storefrontReferenceIdentityReadable &&
        fusion.score >= 0.72 &&
        fusion.geometryScore >= 0.60 &&
        fusion.footprintScore >= 0.44 &&
        fusion.structureScore >= 0.68 &&
        fusion.sceneScore >= 0.48;
    final v31PhysicalFusion =
        physical &&
        !storefrontLike &&
        fusion.score >= (e.lightingNormalized ? 0.69 : 0.72) &&
        fusion.geometryScore >= 0.58 &&
        fusion.footprintScore >= 0.48 &&
        fusion.sceneScore >= (e.lightingNormalized ? 0.38 : 0.42);

    if (v31StorefrontIdentityFusion ||
        v31StorefrontNoReadableIdentityFusion ||
        v31StorefrontRecovery ||
        v31PhysicalFusion) {
      return PhotoMatchDecision(
        TripPathPhotoMatchStatus.matched,
        storefrontLike
            ? 'v31_storefront_evidence_fusion'
            : 'v31_physical_evidence_fusion',
        storefrontLike
            ? 'Your photo matches this storefront. Identity, fixed-facade, scene and geometric evidence agree on the same place.'
            : 'Your photo matches this checkpoint. Multiple independent scene and geometric signals agree on the same physical place.',
      );
    }

    // V28 NIGHT STOREFRONT IDENTITY SAFETY
    // If the reference clearly exposes the selected shop identity, a night
    // capture may not auto-verify on facade geometry alone. OCR can fail at
    // night because of glare, exposure or stylized signage, so strong same-
    // storefront geometry becomes RETAKE rather than NOT MATCHED. A captured
    // alternative identity is already rejected by the V27 conflict guard.
    final storefrontIdentityUnreadableAtNight =
        storefrontLike &&
        e.lightingNormalized &&
        storefrontReferenceIdentityReadable &&
        !storefrontIdentityConfirmed &&
        !storefrontPairTextConfirmed &&
        geometry(8, 5, 0.44) &&
        sparseStorefrontFacade(
          minWidth: 0.22,
          minHeight: 0.055,
          minHull: 0.005,
        ) &&
        e.storefrontStructureSimilarity >= 0.76 &&
        e.globalSimilarity >= 0.52;

    if (storefrontIdentityUnreadableAtNight) {
      return const PhotoMatchDecision(
        TripPathPhotoMatchStatus.retake,
        'storefront_night_identity_unreadable',
        'The facade looks consistent, but the shop identity is not readable enough under this lighting. Retake with the signboard or distinctive shop name clearly visible.',
      );
    }

    // V24 ANGLE / NIGHT RETAKE PRECISION
    // RETAKE is reserved for a plausible same-place capture problem, not for
    // generic visual resemblance. A large viewing-angle or day/night change
    // can lower ORB counts, but we still require RANSAC consensus plus broad
    // fixed-scene support. The V23 low-consensus (<30%, OCR absent) mismatch
    // gate above therefore continues to send unrelated storefronts to
    // NOT MATCHED even when their coarse facade/global scores look high.
    // V22 STOREFRONT UNCERTAINTY BUCKET
    // V23 STOREFRONT UNCERTAINTY BUCKET
    final storefrontAngleUncertain =
        storefrontLike &&
        !e.lightingNormalized &&
        geometry(5, 4, 0.40) &&
        sparseStorefrontFacade(
          minWidth: 0.16,
          minHeight: 0.035,
          minHull: 0.003,
        ) &&
        e.storefrontStructureSimilarity >= 0.70 &&
        e.globalSimilarity >= 0.46 &&
        (v34StorefrontIdentityPositive ||
            (!storefrontReferenceIdentityReadable &&
                e.ratio >= 0.50 &&
                e.storefrontStructureSimilarity >= 0.76 &&
                e.globalSimilarity >= 0.52) ||
            (storefrontReferenceIdentityReadable &&
                e.ratio >= 0.56 &&
                e.storefrontStructureSimilarity >= 0.80 &&
                e.globalSimilarity >= 0.56));

    final storefrontNightUncertain =
        storefrontLike &&
        e.lightingNormalized &&
        geometry(5, 4, 0.32) &&
        sparseStorefrontFacade(
          minWidth: 0.16,
          minHeight: 0.035,
          minHull: 0.003,
        ) &&
        e.storefrontStructureSimilarity >= 0.68 &&
        e.globalSimilarity >= 0.42 &&
        (v34StorefrontIdentityPositive ||
            (!storefrontReferenceIdentityReadable &&
                e.ratio >= 0.48 &&
                e.storefrontStructureSimilarity >= 0.76 &&
                e.globalSimilarity >= 0.52) ||
            (storefrontReferenceIdentityReadable &&
                e.ratio >= 0.54 &&
                e.storefrontStructureSimilarity >= 0.80 &&
                e.globalSimilarity >= 0.56));

    final storefrontTextUncertain =
        storefrontLike &&
        e.goodMatches >= 5 &&
        e.storefrontStructureSimilarity >= 0.60 &&
        e.globalSimilarity >= 0.40 &&
        ((e.inliers >= 3 &&
                e.ratio >= 0.25 &&
                e.storefrontTextSimilarity >= 0.72) ||
            (e.storefrontTextSimilarity >= 0.88 && e.inliers >= 2));

    if (storefrontAngleUncertain ||
        storefrontNightUncertain ||
        storefrontTextUncertain) {
      final reason = storefrontNightUncertain
          ? 'storefront_night_uncertain'
          : storefrontAngleUncertain
              ? 'storefront_viewing_angle_uncertain'
              : 'storefront_text_uncertain';
      return PhotoMatchDecision(
        TripPathPhotoMatchStatus.retake,
        reason,
        storefrontNightUncertain
            ? 'This may be the same storefront, but the lighting difference leaves too little stable geometry to verify safely. Retake with the fixed facade and signboard clearly visible.'
            : storefrontAngleUncertain
                ? 'This may be the same storefront, but the viewing angle is too different to verify safely. Retake from a direction closer to the reference photo and include more of the fixed facade.'
                : 'This may be the same storefront, but the visual geometry is not stable enough yet. Retake with more of the fixed facade and signboard visible.',
      );
    }

    // Non-storefront landmarks use a separate, still-conservative angle
    // uncertainty gate. It requires credible 2-D RANSAC evidence; a few weak
    // or accidental correspondences remain NOT MATCHED.
    final viewingAngleUncertain =
        physical &&
        !storefrontLike &&
        geometry(11, 7, 0.42) &&
        perspectiveSpread(0.14, 0.055, 0.007, 3);
    if (viewingAngleUncertain) {
      return const PhotoMatchDecision(
        TripPathPhotoMatchStatus.retake,
        'viewing_angle_uncertain',
        'The landmark may be the same, but the viewing angle is too different to verify safely. Retake from a direction closer to the reference photo and include more of the facade or surrounding structure.',
      );
    }

    // V26 RETAKE EVIDENCE GATE
    // RETAKE means "there is credible evidence of the checkpoint, but the
    // photo was framed badly / from too extreme an angle". Local RANSAC
    // geometry by itself is not enough: a parked car, chair, poster or other
    // temporary object can produce many internally consistent feature matches
    // if that same object happens to appear in the reference. Such a dynamic-
    // object-only crop must be NOT MATCHED, not RETAKE.
    //
    // Keep V25's MATCHED bridges untouched. This gate is consulted only after
    // all normal closer/farther, angle and night verification paths failed.
    final retakeFixedSceneCorroborated = storefrontLike
        ? (v34StorefrontIdentityPositive ||
            (!storefrontReferenceIdentityReadable &&
                e.storefrontStructureSimilarity >= 0.72 &&
                e.globalSimilarity >= 0.50) ||
            (storefrontReferenceIdentityReadable &&
                e.storefrontStructureSimilarity >= 0.78 &&
                e.globalSimilarity >= 0.54))
        : e.globalSimilarity >= 0.34;

    // Strong geometry concentrated in one fixed landmark region is still a
    // RETAKE, but only when the rest of the scene independently supports that
    // interpretation. A car-only/local temporary-object match therefore no
    // longer reaches this branch.
    final strongButLocal =
        geometry(14, 9, 0.45) && retakeFixedSceneCorroborated;
    if (strongButLocal) {
      return const PhotoMatchDecision(
        TripPathPhotoMatchStatus.retake,
        'matched_region_too_local',
        'Some matching landmark details were found, but they are concentrated in too small an area. Retake the photo and include more of the entrance, facade or surrounding structure, not only a sign or one corner.',
      );
    }

    // Weak accidental similarity should not consume the RETAKE bucket. V26
    // additionally requires independent fixed-scene corroboration so a lone
    // car/person/table or other temporary foreground object cannot turn an
    // otherwise unrelated crop into RETAKE.
    final legacyPlausibleSamePlaceEvidence =
        e.goodMatches >= 9 &&
        e.inliers >= 7 &&
        e.ratio >= 0.32 &&
        retakeFixedSceneCorroborated;

    // V31: RETAKE is also allowed when the fused evidence says "probably the
    // same place" but not strongly enough for automatic verification. This is
    // exactly the bucket for a close/far/oblique/day-night capture that needs a
    // cleaner frame. Completely unrelated photos stay below these corroborated
    // floors and remain NOT VERIFIED.
    final fusedPlausibleSamePlaceEvidence = storefrontLike
        ? (fusion.score >= 0.52 &&
            fusion.geometryScore >= 0.38 &&
            (fusion.identityScore >= 0.55 ||
                (!storefrontReferenceIdentityReadable &&
                    fusion.structureScore >= 0.62 &&
                    fusion.sceneScore >= 0.42) ||
                (storefrontReferenceIdentityReadable &&
                    fusion.geometryScore >= 0.68 &&
                    fusion.structureScore >= 0.76 &&
                    fusion.sceneScore >= 0.54)))
        : (physical &&
            fusion.score >= 0.52 &&
            fusion.geometryScore >= 0.42 &&
            fusion.sceneScore >= 0.30);

    final plausibleSamePlaceEvidence =
        legacyPlausibleSamePlaceEvidence ||
        fusedPlausibleSamePlaceEvidence;

    if (!plausibleSamePlaceEvidence ||
        (e.globalSimilarity < 0.18 && e.inliers < 10)) {
      return const PhotoMatchDecision(
        TripPathPhotoMatchStatus.notMatched,
        'structure_mismatch',
        'The captured scene does not match this checkpoint strongly enough. Make sure you are photographing the same physical landmark.',
      );
    }

    return const PhotoMatchDecision(
      TripPathPhotoMatchStatus.retake,
      'partial_or_uncertain_structure',
      'There are some shared details, but not enough of the physical place is confirmed. Retake from a clearer angle and include more of the landmark.',
    );
  }

  /// Conservative obstruction heuristic on a small grayscale thumbnail.
  /// Only contiguous, almost-flat dark bands at the sides/bottom count.
  /// A dark sky (top edge) or average night-time brightness is not a veto.
  static double darkBorderFraction(List<int> gray, int width, int height) {
    if (width < 8 || height < 8 || gray.length != width * height) return 0;
    bool flatDark(Iterable<int> values) {
      var sum = 0.0;
      var square = 0.0;
      var count = 0;
      var dark = 0;
      for (final value in values) {
        sum += value;
        square += value * value;
        count++;
        if (value < 40) dark++;
      }
      if (count == 0) return false;
      final mean = sum / count;
      final variance = math.max(0.0, square / count - mean * mean);
      return mean < 32 && variance < 90 && dark / count >= 0.95;
    }
    int columns(bool right) {
      var n = 0;
      for (var i = 0; i < width ~/ 2; i++) {
        final x = right ? width - 1 - i : i;
        if (!flatDark(Iterable<int>.generate(height,
            (y) => gray[y * width + x]))) break;
        n++;
      }
      return n;
    }
    var bottom = 0;
    for (var i = 0; i < height ~/ 2; i++) {
      final y = height - 1 - i;
      if (!flatDark(gray.getRange(y * width, (y + 1) * width))) break;
      bottom++;
    }
    return math.max((columns(false) + columns(true)) / width, bottom / height);
  }
}
