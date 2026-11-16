import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../main.dart';
import '../../viewmodel/Authentication Login ViewModel/auth_viewmodel.dart';
import 'widgets/auth_scaffold.dart';
import 'widgets/auth_widgets.dart';

class OtpVerificationView extends StatefulWidget {
  final AuthenticationViewModel viewModel;
  final String email;

  const OtpVerificationView({
    super.key,
    required this.viewModel,
    required this.email,
  });

  @override
  State<OtpVerificationView> createState() =>
      _OtpVerificationViewState();
}

class _OtpVerificationViewState extends State<OtpVerificationView> {
  static const int _resendCooldownSeconds = 60;

  final _otpController = TextEditingController();

  Timer? _resendTimer;

  int _secondsRemaining = _resendCooldownSeconds;

  bool _isResending = false;

  String? _feedbackMessage;
  bool _feedbackIsError = false;

  bool get _canResend =>
      _secondsRemaining == 0 &&
          !_isResending &&
          !widget.viewModel.isLoading;

  @override
  void initState() {
    super.initState();

    _startResendCooldown();
  }

  @override
  void dispose() {
    _resendTimer?.cancel();
    _otpController.dispose();

    super.dispose();
  }

  // =========================================================
  // RESEND COUNTDOWN
  // =========================================================

  void _startResendCooldown() {
    _resendTimer?.cancel();

    setState(() {
      _secondsRemaining = _resendCooldownSeconds;
    });

    _resendTimer = Timer.periodic(
      const Duration(seconds: 1),
          (timer) {
        if (!mounted) {
          timer.cancel();
          return;
        }

        if (_secondsRemaining <= 1) {
          timer.cancel();

          setState(() {
            _secondsRemaining = 0;
          });
        } else {
          setState(() {
            _secondsRemaining--;
          });
        }
      },
    );
  }

  String _formatTime(int seconds) {
    final minutes = seconds ~/ 60;
    final remainingSeconds = seconds % 60;

    return '${minutes.toString().padLeft(2, '0')}:'
        '${remainingSeconds.toString().padLeft(2, '0')}';
  }

  // =========================================================
  // CLEAR MESSAGE
  // =========================================================

  void _clearFeedback() {
    if (_feedbackMessage != null ||
        widget.viewModel.errorMessage != null) {
      widget.viewModel.clearError();

      setState(() {
        _feedbackMessage = null;
        _feedbackIsError = false;
      });
    }
  }

  // =========================================================
  // VERIFY OTP
  // =========================================================

  Future<void> _verify() async {
    FocusScope.of(context).unfocus();

    widget.viewModel.clearError();

    setState(() {
      _feedbackMessage = null;
      _feedbackIsError = false;
    });

    final success = await widget.viewModel.verifyOtp(
      email: widget.email,
      otp: _otpController.text,
    );

    if (!mounted) return;

    setState(() {});

    if (success) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Account successfully verified.',
          ),
        ),
      );

      Navigator.pushNamedAndRemoveUntil(
        context,
        '/login',
            (route) => false,
      );

      return;
    }

    setState(() {
      _feedbackMessage =
          widget.viewModel.errorMessage ??
              'Verification failed.';

      _feedbackIsError = true;
    });
  }

  // =========================================================
  // RESEND OTP
  // =========================================================

  Future<void> _resend() async {
    if (!_canResend) return;

    FocusScope.of(context).unfocus();

    widget.viewModel.clearError();

    setState(() {
      _isResending = true;

      _feedbackMessage = null;
      _feedbackIsError = false;
    });

    final success = await widget.viewModel.resendOtp(
      email: widget.email,
    );

    if (!mounted) return;

    setState(() {
      _isResending = false;
    });

    if (success) {
      setState(() {
        _feedbackMessage =
        'A new verification code has been sent.';

        _feedbackIsError = false;
      });

      // Restart 60-second countdown
      _startResendCooldown();

      return;
    }

    setState(() {
      _feedbackMessage =
          widget.viewModel.errorMessage ??
              'Unable to resend OTP.';

      _feedbackIsError = true;
    });
  }

  // =========================================================
  // UI
  // =========================================================

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // =====================================================
        // MAIN OTP PAGE
        // =====================================================

        AuthScaffold(
          title: '',

          // No map icon / header
          showHeader: false,

          // Keep OTP card in the CENTER
          centerContent: true,

          // IMPORTANT:
          // Do not use AuthScaffold's back button here.
          // Otherwise the back button will move together
          // with the centered card.
          onBack: null,

          // Wider card
          contentPadding: const EdgeInsets.fromLTRB(
            16,
            8,
            16,
            24,
          ),

          cardPadding: const EdgeInsets.fromLTRB(
            24,
            30,
            24,
            30,
          ),

          child: Column(
            crossAxisAlignment:
            CrossAxisAlignment.start,
            children: [
              // =================================================
              // TITLE
              // =================================================

              Center(
                child: Text(
                  'Enter Verification Code',
                  textAlign: TextAlign.center,
                  style:
                  context.text.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),

              AppSpacing.gapXs,

              // =================================================
              // EMAIL
              // =================================================

              Center(
                child: Text.rich(
                  TextSpan(
                    text:
                    'We sent an 8-digit code to\n',
                    style:
                    context.text.bodyMedium?.copyWith(
                      color:
                      context.colors.onSurfaceVariant,
                    ),
                    children: [
                      TextSpan(
                        text: widget.email,
                        style: context.text.bodyMedium
                            ?.copyWith(
                          color:
                          context.colors.primary,
                          fontWeight:
                          FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  textAlign: TextAlign.center,
                ),
              ),

              // =================================================
              // FEEDBACK MESSAGE
              // =================================================

              if (_feedbackMessage != null) ...[
                AppSpacing.gapLg,

                if (_feedbackIsError)
                  AuthErrorBanner(
                    message: _feedbackMessage!,
                  )
                else
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(
                      AppSpacing.md,
                    ),
                    decoration: BoxDecoration(
                      color: context
                          .colors.primaryContainer,
                      borderRadius: AppRadius.brMd,
                    ),
                    child: Row(
                      crossAxisAlignment:
                      CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons
                              .check_circle_outline_rounded,
                          size: 20,
                          color: context.colors
                              .onPrimaryContainer,
                        ),

                        const SizedBox(
                          width: AppSpacing.sm,
                        ),

                        Expanded(
                          child: Text(
                            _feedbackMessage!,
                            style: context
                                .text.bodyMedium
                                ?.copyWith(
                              color: context.colors
                                  .onPrimaryContainer,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],

              AppSpacing.gapXl,

              // =================================================
              // OTP LABEL
              // =================================================

              Text(
                'Verification code',
                style:
                context.text.labelLarge?.copyWith(
                  color: context.colors.onSurface,
                ),
              ),

              AppSpacing.gapXs,

              // =================================================
              // OTP INPUT
              // =================================================

              TextField(
                controller: _otpController,

                keyboardType:
                TextInputType.number,

                textInputAction:
                TextInputAction.done,

                inputFormatters: [
                  FilteringTextInputFormatter
                      .digitsOnly,
                ],

                maxLength: 8,

                textAlign: TextAlign.center,

                style: context.text.headlineSmall
                    ?.copyWith(
                  letterSpacing: 8,
                  fontWeight: FontWeight.w700,
                ),

                onChanged: (_) =>
                    _clearFeedback(),

                onSubmitted: (_) {
                  if (!widget
                      .viewModel.isLoading) {
                    _verify();
                  }
                },

                decoration: InputDecoration(
                  hintText: '00000000',

                  counterText: '',

                  hintStyle: context
                      .text.headlineSmall
                      ?.copyWith(
                    color: context
                        .colors.onSurfaceVariant
                        .withValues(
                      alpha: 0.32,
                    ),
                    letterSpacing: 8,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),

              AppSpacing.gapXl,

              // =================================================
              // VERIFY BUTTON
              // =================================================

              AuthPrimaryButton(
                label: 'Verify OTP',

                loadingLabel:
                'Verifying…',

                loading: widget
                    .viewModel.isLoading &&
                    !_isResending,

                onPressed: _verify,
              ),

              AppSpacing.gapMd,

              // =================================================
              // RESEND OTP
              // =================================================

              Center(
                child: TextButton(
                  onPressed:
                  _canResend ? _resend : null,

                  style: TextButton.styleFrom(
                    foregroundColor:
                    context.colors.primary,

                    disabledForegroundColor:
                    context
                        .colors.onSurfaceVariant
                        .withValues(
                      alpha: 0.55,
                    ),

                    padding:
                    const EdgeInsets.symmetric(
                      horizontal: AppSpacing.sm,
                      vertical: AppSpacing.xs,
                    ),

                    minimumSize: Size.zero,

                    tapTargetSize:
                    MaterialTapTargetSize
                        .shrinkWrap,
                  ),

                  child: Text(
                    _isResending
                        ? 'Sending…'
                        : _secondsRemaining > 0
                        ? 'Resend OTP (${_formatTime(_secondsRemaining)})'
                        : 'Resend OTP',

                    style: context.text.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: _canResend
                          ? context.colors.primary
                          : context.colors.onSurfaceVariant.withValues(
                        alpha: 0.45,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),

        // =====================================================
        // FIXED BACK BUTTON
        // =====================================================
        //
        // This button is OUTSIDE AuthScaffold.
        //
        // Therefore:
        // Back button = top of page
        // OTP card = center of page
        //

        Positioned(
          top: MediaQuery.paddingOf(context).top + 8,
          left: 12,
          child: Material(
            color: Colors.transparent,
            child: IconButton(
              onPressed: () {
                Navigator.maybePop(context);
              },
              icon: Icon(
                Icons.arrow_back_ios_new_rounded,
                color: context.appColors.onHero,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
