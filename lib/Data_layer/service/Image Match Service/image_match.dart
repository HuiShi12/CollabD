import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;

/// Result of comparing a tourist's photo with the official reference photo
/// (UC-05 landmark verification).
class ImageMatchResult {
  const ImageMatchResult({
    required this.isMatch,
    required this.goodMatches,
    required this.score,
    this.usedFallback = false,
  });

  final bool isMatch;

  /// Number of ORB descriptor matches that passed Lowe's ratio test.
  final int goodMatches;

  /// `goodMatches / referenceKeypoints`, roughly 0..1.
  final double score;

  /// `true` when OpenCV could not run (native library missing, decode error)
  /// and the result was allowed through so the game is not blocked.
  final bool usedFallback;
}

/// UC-05 — real landmark photo verification with OpenCV ORB feature matching.
class ImageMatchService {
  const ImageMatchService({
    this.minGoodMatches = 18,
    this.loweRatio = 0.75,
    this.maxDimension = 900,
  });

  /// A photo of the same place from a different angle usually still yields
  /// dozens of consistent ORB matches; unrelated photos rarely clear ~15.
  final int minGoodMatches;
  final double loweRatio;
  final int maxDimension;

  Future<ImageMatchResult> compareLandmark({
    required Uint8List referenceBytes,
    required File capturedPhoto,
  }) async {
    try {
      final capturedBytes = await capturedPhoto.readAsBytes();

      final refGray = _decodeGrayResized(referenceBytes);
      final capGray = _decodeGrayResized(capturedBytes);
      if (refGray == null || capGray == null) {
        return const ImageMatchResult(
          isMatch: true,
          goodMatches: -1,
          score: 0,
          usedFallback: true,
        );
      }

      final orb = cv.ORB.create(nFeatures: 1500);
      final (refKp, refDesc) = orb.detectAndCompute(refGray, cv.Mat.empty());
      final (capKp, capDesc) = orb.detectAndCompute(capGray, cv.Mat.empty());

      if (refDesc.isEmpty || capDesc.isEmpty || refKp.length < 10) {
        refGray.dispose();
        capGray.dispose();
        return const ImageMatchResult(isMatch: false, goodMatches: 0, score: 0);
      }

      final matcher = cv.BFMatcher.create(type: cv.NORM_HAMMING);
      final knn = matcher.knnMatch(refDesc, capDesc, 2);

      var good = 0;
      for (final pair in knn.copyToList()) {
        if (pair.length >= 2 &&
            pair[0].distance < loweRatio * pair[1].distance) {
          good++;
        }
      }

      final score = good / refKp.length;
      final isMatch = good >= minGoodMatches;

      refGray.dispose();
      capGray.dispose();

      debugPrint(
        '[image-match] good=$good / ${refKp.length} kp  score=${score.toStringAsFixed(3)}  -> ${isMatch ? "MATCH" : "no match"}',
      );

      return ImageMatchResult(
        isMatch: isMatch,
        goodMatches: good,
        score: score,
      );
    } catch (e) {
      debugPrint('[image-match] OpenCV unavailable, passing through: $e');
      return const ImageMatchResult(
        isMatch: true,
        goodMatches: -1,
        score: 0,
        usedFallback: true,
      );
    }
  }

  cv.Mat? _decodeGrayResized(Uint8List bytes) {
    final decoded = cv.imdecode(bytes, cv.IMREAD_GRAYSCALE);
    if (decoded.isEmpty) {
      decoded.dispose();
      return null;
    }
    final longest =
        decoded.cols > decoded.rows ? decoded.cols : decoded.rows;
    if (longest <= maxDimension) return decoded;

    final scale = maxDimension / longest;
    final resized = cv.resize(
      decoded,
      ((decoded.cols * scale).round(), (decoded.rows * scale).round()),
    );
    decoded.dispose();
    return resized;
  }
}
