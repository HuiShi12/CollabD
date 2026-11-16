import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../main.dart';
import '../../viewmodel/Trip Path Quest Game ViewModel/trip_path_quest_verification_viewmodel.dart';
import '../../viewmodel/Trip Path Quest Game ViewModel/trip_path_quest_viewmodel.dart';

// ============================================================
// TRIP PATH QUEST - VISIT VERIFICATION PAGE
//
// Production flow:
//
// Google Places returns up to 5 candidate landmark photos
// -> OpenCV automatic reference-photo screening
// -> Best ONE reference photo is selected before the quest starts
// -> User only takes a camera photo here
// -> ORB + KNN Hamming + Ratio Test + RANSAC Homography
// -> MATCHED / RETAKE / NOT MATCHED
//
// There is no manual Reference Photo picker in this version.
// ============================================================

class TripPathQuestVerificationPage extends StatefulWidget {
  final TripPathQuestViewModel viewModel;

  const TripPathQuestVerificationPage({
    super.key,
    required this.viewModel,
  });

  @override
  State<TripPathQuestVerificationPage> createState() =>
      _TripPathQuestVerificationPageState();
}

class _TripPathQuestVerificationPageState
    extends State<TripPathQuestVerificationPage> {
  // ============================================================
  // PHOTO VERIFICATION VIEWMODEL
  // ============================================================

  late final TripPathQuestPhotoVerificationViewModel photoViewModel;

  // Fresh GPS recheck runs immediately before OpenCV/Gemini processing —
  // disables the Verify button for that brief window so a double-tap can't
  // fire two concurrent verification attempts.
  bool _isGpsRechecking = false;

  // ============================================================
  // AUTOMATIC REFERENCE PHOTO
  //
  // The best reference was already selected while the quest's
  // Google Places checkpoints were being prepared.
  // ============================================================

  Uint8List? get _referencePhotoBytes {
    return viewModel
        .currentAttraction
        ?.referencePhotoBytes;
  }

  bool get _hasReferencePhoto {
    final bytes =
        _referencePhotoBytes;

    return bytes != null &&
        bytes.isNotEmpty;
  }

  // ============================================================
  // MAIN VIEWMODEL
  // ============================================================

  TripPathQuestViewModel get viewModel {
    return widget.viewModel;
  }

  // ============================================================
  // INITIALISE
  // ============================================================

  @override
  void initState() {
    super.initState();

    photoViewModel =
        TripPathQuestPhotoVerificationViewModel();

    WidgetsBinding.instance.addPostFrameCallback(
          (_) {
        photoViewModel.initialise();
      },
    );
  }

  // ============================================================
  // DISPOSE
  // ============================================================

  @override
  void dispose() {
    photoViewModel.dispose();

    super.dispose();
  }

  // ============================================================
  // VERIFY PHOTO
  //
  // Reference Photo bytes are stored in this View.
  //
  // Camera Photo bytes are stored in photoViewModel.
  //
  // Both are sent to:
  //
  // TripPathPhotoMatchService
  // → ORB
  // → KNN Hamming
  // → Ratio Test
  // → RANSAC
  // ============================================================

  Future<void> _verifyPhoto() async {
    final referenceBytes =
        _referencePhotoBytes;

    if (!viewModel.canVerifyVisit ||
        !_hasReferencePhoto ||
        referenceBytes == null ||
        !photoViewModel.hasPhoto ||
        photoViewModel.isVerifying ||
        _isGpsRechecking ||
        viewModel.isCompletingCheckpoint) {
      return;
    }

    final attraction = viewModel.currentAttraction;

    viewModel.clearCompletionError();

    // ==========================================================
    // FRESH GPS RECHECK
    //
    // The player was already within 50 m when the verification page opened,
    // but that location can become stale. Verify proximity once more using a
    // fresh GPS sample immediately before OpenCV / Gemini processing.
    // ==========================================================
    setState(() {
      _isGpsRechecking = true;
    });

    final gpsCheck = await viewModel.recheckLocationForPhotoVerification();

    if (!mounted) {
      return;
    }

    setState(() {
      _isGpsRechecking = false;
    });

    if (!gpsCheck.confirmed) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(gpsCheck.message)),
      );
      return;
    }

    await photoViewModel.verifyPhoto(
      referenceImageBytes:
      referenceBytes,
      themeId: viewModel.selectedTheme?.id ?? 'unknown',
      referenceKind: attraction?.referenceKind ?? 'unknown',
      expectedPlaceName: attraction?.name ?? '',
    );

    if (!mounted) {
      return;
    }

    final result =
        photoViewModel.verificationResult;

    // ==========================================================
    // VERIFICATION COULD NOT RUN
    // ==========================================================

    if (result == null) {
      final message =
          photoViewModel.verificationError ??
              'Photo verification could not be completed.';

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            message,
          ),
        ),
      );

      return;
    }

    _showVerificationResultSheet();
  }

  // ============================================================
  // RESULT BOTTOM SHEET
  // ============================================================

  void _showVerificationResultSheet() {
    final result =
        photoViewModel.verificationResult;

    if (result == null) {
      return;
    }

    IconData resultIcon;
    Color resultColor;
    Color resultBackground;
    String displayTitle;
    String displayMessage;
    String actionLabel;
    IconData actionIcon;

    // ==========================================================
    // MATCHED
    // ==========================================================

    if (result.isMatched) {
      resultIcon =
          Icons.verified_rounded;

      resultColor =
      context.appColors.success;

      resultBackground =
      context.appColors.successSurface;

      displayTitle =
      'Checkpoint Verified';

      displayMessage =
      'Your photo matches this checkpoint. Complete the checkpoint to update your quest artwork.';

      actionLabel =
      'Complete Checkpoint';

      actionIcon =
          Icons.flag_rounded;

      // ========================================================
      // RETAKE
      // ========================================================
    } else if (result.shouldRetake) {
      resultIcon =
          Icons.camera_alt_rounded;

      resultColor =
      context.appColors.warning;

      resultBackground =
      context.appColors.warningSurface;

      displayTitle =
      'Retake Photo';

      displayMessage =
          result.message;

      actionLabel =
      'Retake Photo';

      actionIcon =
          Icons.camera_alt_rounded;

      // ========================================================
      // NOT MATCHED
      // ========================================================
    } else if (result.isNotMatched) {
      resultIcon =
          Icons.cancel_rounded;

      resultColor =
      context.colors.error;

      resultBackground =
      context.colors.errorContainer;

      displayTitle =
      'Photo Not Verified';

      displayMessage =
          result.message;

      actionLabel =
      'Try Another Photo';

      actionIcon =
          Icons.refresh_rounded;

      // ========================================================
      // ERROR
      // ========================================================
    } else {
      resultIcon =
          Icons.error_outline_rounded;

      resultColor =
      context.colors.error;

      resultBackground =
      context.colors.errorContainer;

      displayTitle =
      'Verification Error';

      displayMessage =
          result.message;

      actionLabel =
      'Close';

      actionIcon =
          Icons.close_rounded;
    }

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor:
      Colors.transparent,
      builder: (sheetContext) {
        return SafeArea(
          top: false,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(
              20,
              14,
              20,
              24,
            ),
            decoration: BoxDecoration(
              color: context.colors.surface,
              borderRadius:
              const BorderRadius.vertical(
                top: Radius.circular(28),
              ),
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize:
                MainAxisSize.min,
                children: [
                  // ==============================================
                  // HANDLE
                  // ==============================================

                  Container(
                    width: 42,
                    height: 4,
                    decoration: BoxDecoration(
                      color:
                      context.colors.outlineVariant,
                      borderRadius:
                      BorderRadius.circular(999),
                    ),
                  ),

                  const SizedBox(height: 22),

                  if (const bool.fromEnvironment('QUEST_MATCH_DIAGNOSTICS'))
                    ExpansionTile(
                      title: const Text('Photo comparison details'),
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: SelectableText(
                            'Result: ${result.status.name}\n'
                            'Reason: ${result.message}\n'
                            'Keypoints: ${result.referenceKeypoints} / ${result.capturedKeypoints}\n'
                            'Reciprocal matches: ${result.goodMatches}\n'
                            'RANSAC inliers: ${result.inliers}\n'
                            'Inlier ratio: ${result.inlierRatio.toStringAsFixed(3)}\n'
                            'Coverage: ${result.referenceSceneCoverage.toStringAsFixed(3)} / ${result.capturedSceneCoverage.toStringAsFixed(3)}\n'
                            'Scene similarity: ${result.globalSceneSimilarity.toStringAsFixed(3)}\n'
                            'Lighting normalized: ${result.lowLightEnhanced}',
                          ),
                        ),
                      ],
                    ),

                  // ==============================================
                  // RESULT ICON
                  // ==============================================

                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: resultBackground,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      resultIcon,
                      color: resultColor,
                      size: 38,
                    ),
                  ),

                  const SizedBox(height: 16),

                  // ==============================================
                  // USER-FRIENDLY RESULT TITLE
                  // ==============================================

                  Text(
                    displayTitle,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: resultColor,
                      fontSize: 21,
                      fontWeight: FontWeight.w900,
                    ),
                  ),

                  const SizedBox(height: 8),

                  Padding(
                    padding:
                    const EdgeInsets.symmetric(
                      horizontal: 8,
                    ),
                    child: Text(
                      displayMessage,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: context.colors.onSurfaceVariant,
                        fontSize: 13,
                        height: 1.45,
                      ),
                    ),
                  ),

                  const SizedBox(height: 22),

                  // ==============================================
                  // RESULT ACTION
                  // ==============================================

                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: FilledButton.icon(
                      onPressed: () {
                        Navigator.of(
                          sheetContext,
                        ).pop();

                        if (result.isMatched) {
                          unawaited(
                            viewModel.completeCurrentCheckpoint(),
                          );
                        } else if (result.shouldRetake || result.isNotMatched) {
                          viewModel.clearCompletionError();
                          photoViewModel.retakePhoto();
                        }
                      },
                      style:
                      FilledButton.styleFrom(
                        backgroundColor:
                        result.isMatched
                            ? context.appColors.success
                            : context.colors.primary,
                        foregroundColor:
                        result.isMatched
                            ? context.appColors.onSuccess
                            : context.colors.onPrimary,
                        shape: RoundedRectangleBorder(
                          borderRadius:
                          BorderRadius.circular(15),
                        ),
                      ),
                      icon: Icon(
                        actionIcon,
                        size: 20,
                      ),
                      label: Text(
                        actionLabel,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ============================================================
  // BUILD
  // ============================================================

  @override
  Widget build(BuildContext context) {
    final theme =
        viewModel.selectedTheme;

    final themeStyle =
    _getVerificationThemeStyle(
      theme?.id ?? '',
    );

    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[
        photoViewModel,
        viewModel,
      ]),
      builder: (context, child) {
        return _VerificationPhoneFrame(
          child: Scaffold(
            backgroundColor:
            context.colors.surface,

            // ==================================================
            // APP BAR
            // ==================================================

            appBar: AppBar(
              backgroundColor:
              context.colors.surface,
              foregroundColor:
              context.colors.onSurface,
              elevation: 0,
              centerTitle: true,
              leading: IconButton(
                onPressed:
                photoViewModel.isVerifying ||
                        viewModel.isCompletingCheckpoint
                    ? null
                    : viewModel.goBack,
                icon: const Icon(
                  Icons
                      .arrow_back_ios_new_rounded,
                ),
              ),
              title: Text(
                'Verify Your Visit',
                style: TextStyle(
                  color: context.colors.onSurface,
                  fontSize: 17,
                  fontWeight:
                  FontWeight.w800,
                ),
              ),
            ),

            // ==================================================
            // BODY
            // ==================================================

            body: SafeArea(
              top: false,
              child:
              SingleChildScrollView(
                padding:
                const EdgeInsets
                    .fromLTRB(
                  18,
                  8,
                  18,
                  30,
                ),
                child: Column(
                  crossAxisAlignment:
                  CrossAxisAlignment
                      .start,
                  children: [
                    // ============================================
                    // CHECKPOINT STATUS
                    // ============================================

                    _buildCheckpointStatus(),

                    const SizedBox(
                      height: 16,
                    ),

                    // ============================================
                    // THEME
                    // ============================================

                    _buildThemeInfo(
                      themeName:
                      theme?.name ??
                          'Trip Path',
                      themeStyle:
                      themeStyle,
                    ),

                    const SizedBox(height: 20),

                    // ============================================
                    // REFERENCE PHOTO
                    // ============================================

                    _buildReferencePhotoSection(),

                    const SizedBox(
                      height: 20,
                    ),

                    // ============================================
                    // CAMERA PHOTO
                    // ============================================

                    _buildCameraPhotoSection(),

                    // ============================================
                    // CAMERA ERROR
                    // ============================================

                    if (photoViewModel
                        .cameraError !=
                        null) ...[
                      const SizedBox(
                        height: 12,
                      ),
                      _buildErrorBox(
                        photoViewModel
                            .cameraError!,
                      ),
                    ],

                    // ============================================
                    // VERIFICATION ERROR
                    // ============================================

                    if (photoViewModel
                        .verificationError !=
                        null) ...[
                      const SizedBox(
                        height: 12,
                      ),
                      _buildErrorBox(
                        photoViewModel
                            .verificationError!,
                      ),
                    ],

                    if (viewModel.completionError != null) ...[
                      const SizedBox(height: 12),
                      _buildCompletionErrorBox(),
                    ],

                    const SizedBox(
                      height: 20,
                    ),

                    // ============================================
                    // BACK
                    // ============================================

                    SizedBox(
                      width:
                      double.infinity,
                      child:
                      TextButton.icon(
                        onPressed:
                        photoViewModel.isVerifying ||
                            viewModel.isCompletingCheckpoint
                            ? null
                            : viewModel
                            .goBack,
                        icon:
                        const Icon(
                          Icons
                              .arrow_back_rounded,
                        ),
                        label:
                        const Text(
                          'Back to Navigation',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // ============================================================
  // CHECKPOINT STATUS
  // ============================================================

  Widget _buildCheckpointStatus() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(
        18,
      ),
      decoration: BoxDecoration(
        gradient:
        const LinearGradient(
          begin:
          Alignment.topLeft,
          end:
          Alignment.bottomRight,
          colors: [
            Color(
              0xFF03152E,
            ),
            Color(
              0xFF0E3A6E,
            ),
          ],
        ),
        borderRadius:
        BorderRadius.circular(
          22,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 50,
            height: 50,
            decoration:
            BoxDecoration(
              color:
              Colors.white
                  .withValues(
                alpha: 0.10,
              ),
              borderRadius:
              BorderRadius.circular(
                15,
              ),
              border:
              Border.all(
                color:
                Colors.white
                    .withValues(
                  alpha: 0.14,
                ),
              ),
            ),
            child:
            const Icon(
              Icons
                  .verified_rounded,
              color:
              Color(
                0xFF86EFAC,
              ),
              size: 28,
            ),
          ),

          const SizedBox(
            width: 13,
          ),

          Expanded(
            child: Column(
              crossAxisAlignment:
              CrossAxisAlignment
                  .start,
              children: [
                Text(
                  'Checkpoint ${viewModel.currentCheckpoint} of ${viewModel.totalCheckpoints}',
                  style:
                  const TextStyle(
                    color:
                    Colors.white,
                    fontSize:
                    17,
                    fontWeight:
                    FontWeight
                        .w900,
                  ),
                ),
                const SizedBox(
                  height: 4,
                ),
                const Text(
                  'You are close enough to verify this visit.',
                  style:
                  TextStyle(
                    color:
                    Color(
                      0xFFBAE6FD,
                    ),
                    fontSize:
                    12.5,
                    height:
                    1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // THEME INFORMATION
  // ============================================================

  Widget _buildThemeInfo({
    required String themeName,
    required _VerificationThemeStyle themeStyle,
  }) {
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration:
          BoxDecoration(
            color:
            themeStyle
                .background,
            borderRadius:
            BorderRadius.circular(
              13,
            ),
          ),
          child: Icon(
            themeStyle.icon,
            color:
            themeStyle.color,
            size: 24,
          ),
        ),

        const SizedBox(
          width: 11,
        ),

        Expanded(
          child: Column(
            crossAxisAlignment:
            CrossAxisAlignment
                .start,
            children: [
              Text(
                '$themeName Quest',
                style:
                TextStyle(
                  color:
                  context.colors.onSurface,
                  fontSize:
                  15,
                  fontWeight:
                  FontWeight
                      .w800,
                ),
              ),
              const SizedBox(
                height: 2,
              ),
              Text(
                'Match the landmark before completing this checkpoint.',
                style:
                TextStyle(
                  color:
                  context.colors.onSurfaceVariant,
                  fontSize:
                  11.5,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ============================================================
  // AUTOMATIC REFERENCE PHOTO SECTION
  // ============================================================

  Widget _buildReferencePhotoSection() {
    final attraction =
        viewModel.currentAttraction;

    final referenceBytes =
        _referencePhotoBytes;

    final ready =
        _hasReferencePhoto &&
            referenceBytes != null;

    return Column(
      crossAxisAlignment:
      CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Reference Photo',
                style: TextStyle(
                  color: context.colors.onSurface,
                  fontSize: 17,
                  fontWeight:
                  FontWeight.w900,
                ),
              ),
            ),
            if (ready)
              const _ReadyBadge(
                text:
                'REFERENCE READY',
              ),
          ],
        ),
        const SizedBox(
          height: 5,
        ),
        Text(
          ready
              ? 'Use this reference when taking your photo of ${attraction?.name ?? 'the landmark'}.'
              : 'The landmark reference is selected automatically before verification.',
          style: TextStyle(
            color: context.colors.onSurfaceVariant,
            fontSize: 12.5,
            height: 1.4,
          ),
        ),
        const SizedBox(
          height: 12,
        ),

        // ========================================================
        // ACTUAL SELECTED REFERENCE IMAGE
        //
        // The player should be able to see what physical landmark /
        // storefront / outdoor scene needs to be photographed.
        // ========================================================

        if (ready) ...[
          ClipRRect(
            borderRadius:
            BorderRadius.circular(
              20,
            ),
            child: AspectRatio(
              aspectRatio: 16 / 10,
              child: Container(
                color: context.colors.surfaceContainerHighest,
                alignment: Alignment.center,
                child: Image.memory(
                  referenceBytes,
                  width: double.infinity,
                  height: double.infinity,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  filterQuality: FilterQuality.medium,
                  errorBuilder: (
                      context,
                      error,
                      stackTrace,
                      ) {
                    return Container(
                      color: context.colors.surfaceContainerHighest,
                      alignment: Alignment.center,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.broken_image_outlined,
                            color: context.colors.onSurfaceVariant,
                            size: 34,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Reference image could not be displayed.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: context.colors.onSurfaceVariant,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
          const SizedBox(
            height: 12,
          ),
        ],

        Container(
          width: double.infinity,
          padding:
          const EdgeInsets.all(
            18,
          ),
          decoration:
          BoxDecoration(
            color: context.colors.surface,
            borderRadius:
            BorderRadius.circular(
              20,
            ),
            border: Border.all(
              color: ready
                  ? context.colors.primary.withValues(alpha: 0.4)
                  : context.colors.error.withValues(alpha: 0.4),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration:
                BoxDecoration(
                  color: ready
                      ? context.colors.primaryContainer
                      : context.colors.errorContainer,
                  borderRadius:
                  BorderRadius.circular(
                    14,
                  ),
                ),
                child: Icon(
                  ready
                      ? Icons.photo_camera_back_rounded
                      : Icons.image_not_supported_outlined,
                  color: ready
                      ? context.colors.primary
                      : context.colors.error,
                ),
              ),
              const SizedBox(
                width: 13,
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment:
                  CrossAxisAlignment.start,
                  children: [
                    Text(
                      ready
                          ? attraction?.name ??
                          'Reference landmark'
                          : 'Reference unavailable',
                      style:
                      TextStyle(
                        color: context.colors.onSurface,
                        fontSize: 14,
                        fontWeight:
                        FontWeight.w800,
                      ),
                    ),
                    const SizedBox(
                      height: 4,
                    ),
                    Text(
                      ready
                          ? 'Take your own photo of the same physical landmark or storefront.'
                          : 'This checkpoint does not have a suitable automatic reference photo.',
                      style:
                      TextStyle(
                        color: context.colors.onSurfaceVariant,
                        fontSize: 11.5,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ============================================================
  // CAMERA SECTION
  // ============================================================

  Widget _buildCameraPhotoSection() {
    return Column(
      crossAxisAlignment:
      CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Your Photo',
                style:
                TextStyle(
                  color:
                  context.colors.onSurface,
                  fontSize:
                  17,
                  fontWeight:
                  FontWeight
                      .w900,
                ),
              ),
            ),

            if (photoViewModel
                .hasPhoto)
              const _ReadyBadge(
                text:
                'PHOTO READY',
              ),
          ],
        ),

        const SizedBox(
          height: 5,
        ),

        Text(
          'Take another photo of the same object or landmark using the Camera.',
          style:
          TextStyle(
            color:
            context.colors.onSurfaceVariant,
            fontSize:
            12.5,
            height:
            1.4,
          ),
        ),

        const SizedBox(
          height: 12,
        ),

        if (!photoViewModel
            .hasPhoto)
          _buildTakePhotoCard()
        else
          _buildPhotoPreview(),
      ],
    );
  }

  Widget _buildCompletionErrorBox() {
    final saving = viewModel.isCompletingCheckpoint;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 12),
      decoration: BoxDecoration(
        color: context.appColors.warningSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.appColors.warning.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.cloud_off_rounded,
                color: context.appColors.warning,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  viewModel.completionError!,
                  style: TextStyle(
                    color: context.colors.onSurface,
                    fontSize: 12,
                    height: 1.35,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            height: 42,
            child: FilledButton.icon(
              onPressed: saving
                  ? null
                  : () {
                      unawaited(
                        viewModel.completeCurrentCheckpoint(),
                      );
                    },
              icon: saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.save_rounded, size: 18),
              label: Text(
                saving ? 'Saving...' : 'Retry Save',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: context.appColors.warning,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // TAKE PHOTO CARD
  // ============================================================

  Widget _buildTakePhotoCard() {
    final openingCamera =
        photoViewModel
            .isOpeningCamera;

    return Container(
      width:
      double.infinity,
      padding:
      const EdgeInsets.all(
        20,
      ),
      decoration:
      BoxDecoration(
        color:
        context.colors.surface,
        borderRadius:
        BorderRadius.circular(
          20,
        ),
        border:
        Border.all(
          color:
          context.colors.outlineVariant,
        ),
      ),
      child: Column(
        children: [
          Container(
            width:
            62,
            height:
            62,
            decoration:
            BoxDecoration(
              color:
              context.colors.primaryContainer,
              shape:
              BoxShape.circle,
            ),
            child:
            Icon(
              Icons
                  .camera_alt_outlined,
              color:
              context.colors.primary,
              size:
              29,
            ),
          ),

          const SizedBox(
            height: 12,
          ),

          Text(
            'No photo taken yet',
            style:
            TextStyle(
              color:
              context.colors.onSurface,
              fontSize:
              14,
              fontWeight:
              FontWeight
                  .w800,
            ),
          ),

          const SizedBox(
            height: 5,
          ),

          Text(
            'Take a clear second photo of the reference object.',
            textAlign:
            TextAlign.center,
            style:
            TextStyle(
              color:
              context.colors.onSurfaceVariant,
              fontSize:
              11.5,
            ),
          ),

          const SizedBox(
            height: 16,
          ),

          SizedBox(
            width:
            double.infinity,
            height:
            48,
            child:
            FilledButton.icon(
              onPressed:
              openingCamera ||
                  photoViewModel
                      .isVerifying ||
                  viewModel.isCompletingCheckpoint
                  ? null
                  : photoViewModel
                  .takePhoto,
              style:
              FilledButton
                  .styleFrom(
                backgroundColor:
                context.colors.primary,
                foregroundColor:
                context.colors.onPrimary,
                disabledBackgroundColor:
                context.colors.surfaceContainerHighest,
                shape:
                RoundedRectangleBorder(
                  borderRadius:
                  BorderRadius.circular(
                    14,
                  ),
                ),
              ),
              icon:
              openingCamera
                  ? SizedBox(
                width:
                18,
                height:
                18,
                child:
                CircularProgressIndicator(
                  strokeWidth:
                  2.2,
                  color:
                  context.colors.onPrimary,
                ),
              )
                  : const Icon(
                Icons
                    .camera_alt_rounded,
              ),
              label:
              Text(
                openingCamera
                    ? 'Opening Camera...'
                    : 'Take Photo',
                style:
                const TextStyle(
                  fontWeight:
                  FontWeight
                      .w800,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // CAMERA PHOTO PREVIEW
  // ============================================================

  Widget _buildPhotoPreview() {
    final openingCamera =
        photoViewModel
            .isOpeningCamera;

    final verifying =
        photoViewModel
            .isVerifying;

    final completing =
        viewModel.isCompletingCheckpoint;

    return Container(
      width:
      double.infinity,
      padding:
      const EdgeInsets.all(
        14,
      ),
      decoration:
      BoxDecoration(
        color:
        context.colors.surface,
        borderRadius:
        BorderRadius.circular(
          20,
        ),
        border:
        Border.all(
          color:
          context.colors.primary.withValues(alpha: 0.35),
        ),
      ),
      child: Column(
        crossAxisAlignment:
        CrossAxisAlignment.start,
        children: [
          // ======================================================
          // IMAGE
          // ======================================================

          ClipRRect(
            borderRadius:
            BorderRadius.circular(
              16,
            ),
            child:
            AspectRatio(
              aspectRatio:
              4 / 3,
              child:
              Image.memory(
                photoViewModel
                    .photoBytes!,
                fit:
                BoxFit.cover,
                errorBuilder:
                    (
                    context,
                    error,
                    stackTrace,
                    ) {
                  return Container(
                    color:
                    context.colors.surfaceContainerHighest,
                    alignment:
                    Alignment.center,
                    child:
                    Icon(
                      Icons
                          .broken_image_outlined,
                      color:
                      context.colors.onSurfaceVariant,
                      size:
                      40,
                    ),
                  );
                },
              ),
            ),
          ),

          const SizedBox(
            height: 12,
          ),

          // ======================================================
          // PHOTO INFO
          // ======================================================

          const _PhotoLabel(
            icon:
            Icons
                .camera_alt_rounded,
            title:
            'Camera Photo',
          ),

          const SizedBox(
            height: 5,
          ),

          Text(
            photoViewModel
                .photoName,
            maxLines:
            1,
            overflow:
            TextOverflow.ellipsis,
            style:
            TextStyle(
              color:
              context.colors.onSurfaceVariant,
              fontSize:
              11.5,
            ),
          ),

          if (photoViewModel
              .photoSizeText
              .isNotEmpty) ...[
            const SizedBox(
              height: 2,
            ),
            Text(
              photoViewModel
                  .photoSizeText,
              style:
              TextStyle(
                color:
                context.colors.onSurfaceVariant.withValues(alpha: 0.75),
                fontSize:
                10.5,
              ),
            ),
          ],

          const SizedBox(
            height: 14,
          ),

          // ======================================================
          // VERIFICATION / CHECKPOINT PROGRESS
          //
          // Shown inside this card, right above the Retake/Verify
          // buttons — same placement as the Puzzle game's own photo
          // preview card.
          // ======================================================

          if (verifying) ...[
            LinearProgressIndicator(color: context.colors.primary),
            const SizedBox(height: 10),
            Text(
              'Comparing landmark structure and scene...\n'
              'Please keep this page open.',
              textAlign: TextAlign.center,
              style: TextStyle(color: context.colors.onSurfaceVariant, fontSize: 12),
            ),
            const SizedBox(height: 14),
          ] else if (completing) ...[
            LinearProgressIndicator(color: context.appColors.success),
            const SizedBox(height: 10),
            Text(
              'Saving checkpoint progress...\n'
              'Please keep this page open.',
              textAlign: TextAlign.center,
              style: TextStyle(color: context.colors.onSurfaceVariant, fontSize: 12),
            ),
            const SizedBox(height: 14),
          ],

          // ======================================================
          // RETAKE + VERIFY
          //
          // THIS IS THE ONLY VERIFY PHOTO BUTTON.
          // ======================================================

          Row(
            children: [
              Expanded(
                child:
                OutlinedButton.icon(
                  onPressed:
                  openingCamera ||
                      verifying ||
                      completing
                      ? null
                      : () {
                          viewModel.clearCompletionError();
                          photoViewModel.retakePhoto();
                        },
                  style:
                  OutlinedButton
                      .styleFrom(
                    foregroundColor:
                    context.colors.primary,
                    minimumSize:
                    const Size
                        .fromHeight(
                      48,
                    ),
                    shape:
                    RoundedRectangleBorder(
                      borderRadius:
                      BorderRadius.circular(
                        14,
                      ),
                    ),
                  ),
                  icon:
                  const Icon(
                    Icons
                        .refresh_rounded,
                    size:
                    19,
                  ),
                  label:
                  const Text(
                    'Retake',
                    style:
                    TextStyle(
                      fontWeight:
                      FontWeight
                          .w800,
                    ),
                  ),
                ),
              ),

              const SizedBox(
                width: 10,
              ),

              Expanded(
                child:
                FilledButton.icon(
                  onPressed:
                  openingCamera ||
                      !_hasReferencePhoto ||
                      verifying ||
                      completing
                      ? null
                      : _verifyPhoto,
                  style:
                  FilledButton
                      .styleFrom(
                    backgroundColor:
                    context.colors.primary,
                    foregroundColor:
                    context.colors.onPrimary,
                    disabledBackgroundColor:
                    context.colors.surfaceContainerHighest,
                    disabledForegroundColor:
                    context.colors.onSurfaceVariant,
                    minimumSize:
                    const Size
                        .fromHeight(
                      48,
                    ),
                    shape:
                    RoundedRectangleBorder(
                      borderRadius:
                      BorderRadius.circular(
                        14,
                      ),
                    ),
                  ),
                  icon:
                  verifying || completing
                      ? SizedBox(
                    width:
                    18,
                    height:
                    18,
                    child:
                    CircularProgressIndicator(
                      strokeWidth:
                      2.2,
                      color:
                      context.colors.onPrimary,
                    ),
                  )
                      : const Icon(
                    Icons
                        .verified_rounded,
                    size:
                    19,
                  ),
                  label:
                  FittedBox(
                    fit:
                    BoxFit.scaleDown,
                    child:
                    Text(
                      completing
                          ? 'Saving...'
                          : verifying
                              ? 'Verifying...'
                              : 'Verify Photo',
                      maxLines:
                      1,
                      softWrap:
                      false,
                      style:
                      const TextStyle(
                        fontWeight:
                        FontWeight
                            .w800,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),

          // ======================================================
          // REFERENCE REQUIRED
          // ======================================================

          if (!_hasReferencePhoto) ...[
            const SizedBox(
              height: 10,
            ),
            Row(
              crossAxisAlignment:
              CrossAxisAlignment
                  .start,
              children: [
                Icon(
                  Icons
                      .info_outline_rounded,
                  color:
                  context.appColors.warning,
                  size:
                  17,
                ),
                const SizedBox(
                  width:
                  7,
                ),
                Expanded(
                  child:
                  Text(
                    'Automatic reference photo is unavailable for this checkpoint.',
                    style:
                    TextStyle(
                      color:
                      context.colors.onSurface,
                      fontSize:
                      11.5,
                      height:
                      1.35,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  // ============================================================
  // ERROR BOX
  // ============================================================

  Widget _buildErrorBox(
      String message,
      ) {
    return Container(
      width:
      double.infinity,
      padding:
      const EdgeInsets.all(
        13,
      ),
      decoration:
      BoxDecoration(
        color:
        context.colors.errorContainer,
        borderRadius:
        BorderRadius.circular(
          14,
        ),
        border:
        Border.all(
          color:
          context.colors.error.withValues(alpha: 0.4),
        ),
      ),
      child: Row(
        crossAxisAlignment:
        CrossAxisAlignment.start,
        children: [
          Icon(
            Icons
                .error_outline_rounded,
            color:
            context.colors.error,
            size:
            18,
          ),
          const SizedBox(
            width:
            8,
          ),
          Expanded(
            child:
            Text(
              message,
              style:
              TextStyle(
                color:
                context.colors.onErrorContainer,
                fontSize:
                11.8,
                height:
                1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// VERIFICATION THEME STYLE
// ============================================================

class _VerificationThemeStyle {
  final Color color;
  final Color background;
  final IconData icon;

  const _VerificationThemeStyle({
    required this.color,
    required this.background,
    required this.icon,
  });
}

_VerificationThemeStyle _getVerificationThemeStyle(String themeId) {
  switch (themeId) {
    case 'food':
      return const _VerificationThemeStyle(
        color: Color(0xFFEA580C),
        background: Color(0xFFFFF7ED),
        icon: Icons.restaurant_rounded,
      );

    case 'culture':
      return const _VerificationThemeStyle(
        color: Color(0xFF7C3AED),
        background: Color(0xFFF5F3FF),
        icon: Icons.theater_comedy_rounded,
      );

    case 'heritage':
      return const _VerificationThemeStyle(
        color: Color(0xFFB45309),
        background: Color(0xFFFFFBEB),
        icon: Icons.account_balance_rounded,
      );

    case 'nature':
      return const _VerificationThemeStyle(
        color: Color(0xFF16A34A),
        background: Color(0xFFF0FDF4),
        icon: Icons.park_rounded,
      );

    default:
      return const _VerificationThemeStyle(
        color: Color(0xFF0284C7),
        background: Color(0xFFF0F9FF),
        icon: Icons.route_rounded,
      );
  }
}

// ============================================================
// VERIFICATION PHONE FRAME
// ============================================================

class _VerificationPhoneFrame extends StatelessWidget {
  final Widget child;

  const _VerificationPhoneFrame({
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF071426),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: 393,
          ),
          child: child,
        ),
      ),
    );
  }
}

// ============================================================
// READY BADGE
// ============================================================

class _ReadyBadge extends StatelessWidget {
  final String text;

  const _ReadyBadge({
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: 9,
        vertical: 5,
      ),
      decoration: BoxDecoration(
        color: context.appColors.successSurface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: context.appColors.success.withValues(alpha: 0.4),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.check_circle_rounded,
            size: 13,
            color: context.appColors.success,
          ),
          const SizedBox(width: 5),
          Text(
            text,
            style: TextStyle(
              color: context.appColors.success,
              fontSize: 10,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.35,
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// PHOTO LABEL
// ============================================================

class _PhotoLabel extends StatelessWidget {
  final IconData icon;
  final String title;

  const _PhotoLabel({
    required this.icon,
    required this.title,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 16,
          color: context.colors.primary,
        ),
        const SizedBox(width: 6),
        Text(
          title,
          style: TextStyle(
            color: context.colors.onSurface,
            fontSize: 12,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }
}
