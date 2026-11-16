import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../main.dart';
import '../../viewmodel/Authentication Login ViewModel/auth_viewmodel.dart';

enum ForgotPasswordStep {
  email,
  sent,
  reset,
  success,
}

class ForgotPasswordView extends StatefulWidget {
  final AuthenticationViewModel viewModel;
  final bool startWithResetStep;

  const ForgotPasswordView({
    super.key,
    required this.viewModel,
    this.startWithResetStep = false,
  });

  @override
  State<ForgotPasswordView> createState() =>
      _ForgotPasswordViewState();
}

class _ForgotPasswordViewState extends State<ForgotPasswordView> {
  // =========================================================
  // CONTROLLERS
  // =========================================================

  final TextEditingController _emailController =
  TextEditingController();

  final TextEditingController _newPasswordController =
  TextEditingController();

  final TextEditingController _confirmPasswordController =
  TextEditingController();

  // =========================================================
  // SUPABASE AUTH LISTENER
  // =========================================================

  StreamSubscription<AuthState>? _authSubscription;

  // =========================================================
  // PAGE STATE
  // =========================================================

  late ForgotPasswordStep _step;

  bool _showNewPassword = false;
  bool _showConfirmPassword = false;

  // =========================================================
  // INIT
  // =========================================================

  @override
  void initState() {
    super.initState();

    _step = widget.startWithResetStep
        ? ForgotPasswordStep.reset
        : ForgotPasswordStep.email;

    // Listen for the Supabase password recovery event.
    //
    // When the user clicks the recovery link from the email,
    // Supabase will create a recovery session and emit
    // AuthChangeEvent.passwordRecovery.
    _authSubscription =
        Supabase.instance.client.auth.onAuthStateChange.listen(
              (data) {
            debugPrint(
              'FORGOT PASSWORD AUTH EVENT: ${data.event}',
            );

            if (data.event == AuthChangeEvent.passwordRecovery) {
              if (!mounted) {
                return;
              }

              widget.viewModel.clearError();

              setState(() {
                _step = ForgotPasswordStep.reset;
              });

              debugPrint(
                'PASSWORD RECOVERY DETECTED - OPEN RESET FORM',
              );
            }
          },
          onError: (error, stackTrace) {
            debugPrint(
              'PASSWORD RECOVERY ERROR: $error',
            );
          },
        );
  }

  // =========================================================
  // DISPOSE
  // =========================================================

  @override
  void dispose() {
    _authSubscription?.cancel();

    _emailController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();

    super.dispose();
  }

  // =========================================================
  // SEND RESET EMAIL
  // =========================================================

  Future<void> _sendResetLink() async {
    widget.viewModel.clearError();

    setState(() {});

    final success =
    await widget.viewModel.sendPasswordResetEmail(
      email: _emailController.text,
    );

    if (!mounted) {
      return;
    }

    setState(() {});

    if (success) {
      setState(() {
        _step = ForgotPasswordStep.sent;
      });
    }
  }

  // =========================================================
  // UPDATE PASSWORD
  // =========================================================

  Future<void> _updatePassword() async {
    widget.viewModel.clearError();

    setState(() {});

    final success =
    await widget.viewModel.resetPassword(
      newPassword: _newPasswordController.text,
      confirmPassword:
      _confirmPasswordController.text,
    );

    if (!mounted) {
      return;
    }

    setState(() {});

    if (success) {
      setState(() {
        _step = ForgotPasswordStep.success;
      });
    }
  }

  // =========================================================
  // CLEAR ERROR
  // =========================================================

  void _clearError() {
    if (widget.viewModel.errorMessage != null) {
      widget.viewModel.clearError();

      setState(() {});
    }
  }

  // =========================================================
  // BACK TO LOGIN
  // =========================================================

  void _backToLogin() {
    widget.viewModel.clearError();

    Navigator.pushNamedAndRemoveUntil(
      context,
      '/login',
          (route) => false,
    );
  }

  // =========================================================
  // BUILD
  // =========================================================

  @override
  Widget build(BuildContext context) {
    final appColors = context.appColors;
    final colors = context.colors;

    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: appColors.heroGradient,
          ),
        ),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: 430,
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  28,
                  40,
                  28,
                  40,
                ),
                child: Column(
                  children: [
                    if (_step == ForgotPasswordStep.reset)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: AppBackButton(
                          onTap: _backToLogin,
                          color: appColors.onHero,
                        ),
                      ),

                    const SizedBox(height: 25),

                    // =================================================
                    // LOGO
                    // =================================================

                    Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: appColors.brandGradient,
                        ),
                        borderRadius:
                        BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: colors.primary.withValues(
                              alpha: 0.40,
                            ),
                            blurRadius: 20,
                            offset: const Offset(
                              0,
                              6,
                            ),
                          ),
                        ],
                      ),
                      alignment: Alignment.center,
                      child: const Text(
                        '🗺️',
                        style: TextStyle(
                          fontSize: 28,
                        ),
                      ),
                    ),

                    const SizedBox(height: 32),

                    // =================================================
                    // CARD
                    // =================================================

                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(28),
                      decoration: BoxDecoration(
                        color: colors.surface,
                        borderRadius:
                        BorderRadius.circular(28),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(
                              alpha: context.isDark ? 0.35 : 0.12,
                            ),
                            blurRadius: 60,
                            offset: const Offset(
                              0,
                              20,
                            ),
                          ),
                        ],
                      ),
                      child: _buildCurrentStep(),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // =========================================================
  // CURRENT STEP
  // =========================================================

  Widget _buildCurrentStep() {
    switch (_step) {
      case ForgotPasswordStep.email:
        return _emailStep();

      case ForgotPasswordStep.sent:
        return _sentStep();

      case ForgotPasswordStep.reset:
        return _resetStep();

      case ForgotPasswordStep.success:
        return _successStep();
    }
  }

  // =========================================================
  // STEP 1: ENTER EMAIL
  // =========================================================

  Widget _emailStep() {
    final colors = context.colors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Forgot Password',
          style: GoogleFonts.poppins(
            color: colors.onSurface,
            fontSize: 22,
            fontWeight: FontWeight.w700,
          ),
        ),

        const SizedBox(height: 8),

        Text(
          "Enter your email and we'll send a reset link.",
          style: GoogleFonts.inter(
            color: colors.onSurfaceVariant,
            fontSize: 14,
          ),
        ),

        if (widget.viewModel.errorMessage != null) ...[
          const SizedBox(height: 16),
          _errorBanner(
            widget.viewModel.errorMessage!,
          ),
        ],

        const SizedBox(height: 24),

        _fieldLabel('Email'),

        const SizedBox(height: 6),

        TextField(
          controller: _emailController,
          keyboardType: TextInputType.emailAddress,
          onChanged: (_) => _clearError(),
          style: _inputTextStyle(),
          decoration: _inputDecoration(
            hintText: 'you@example.com',
          ),
        ),

        const SizedBox(height: 24),

        _primaryButton(
          text: widget.viewModel.isLoading
              ? 'Sending...'
              : 'Send Reset Link',
          onTap: widget.viewModel.isLoading
              ? null
              : _sendResetLink,
        ),

        const SizedBox(height: 16),

        Center(
          child: TextButton(
            onPressed: _backToLogin,
            child: Text(
              '← Back to Login',
              style: GoogleFonts.inter(
                color: colors.primary,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ],
    );
  }

  // =========================================================
  // STEP 2: CHECK EMAIL
  // =========================================================

  Widget _sentStep() {
    final colors = context.colors;

    return Column(
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            color: colors.primaryContainer,
            borderRadius:
            BorderRadius.circular(22),
          ),
          alignment: Alignment.center,
          child: Icon(
            Icons.mail_outline_rounded,
            color: colors.onPrimaryContainer,
            size: 38,
          ),
        ),

        const SizedBox(height: 20),

        Text(
          'Check Your Email',
          style: GoogleFonts.poppins(
            color: colors.onSurface,
            fontSize: 22,
            fontWeight: FontWeight.w700,
          ),
        ),

        const SizedBox(height: 8),

        Text.rich(
          TextSpan(
            children: [
              const TextSpan(
                text:
                'A password reset link has been sent to ',
              ),
              TextSpan(
                text:
                _emailController.text.trim(),
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const TextSpan(
                text:
                '.\n\nOpen the link in the email to continue resetting your password.',
              ),
            ],
          ),
          textAlign: TextAlign.center,
          style: GoogleFonts.inter(
            color: colors.onSurfaceVariant,
            fontSize: 14,
            height: 1.5,
          ),
        ),

        const SizedBox(height: 24),

        TextButton(
          onPressed: _backToLogin,
          child: Text(
            '← Back to Login',
            style: GoogleFonts.inter(
              color: colors.onSurfaceVariant,
              fontSize: 13,
            ),
          ),
        ),
      ],
    );
  }

  // =========================================================
  // STEP 3: RESET PASSWORD
  // =========================================================

  Widget _resetStep() {
    final colors = context.colors;

    return Column(
      crossAxisAlignment:
      CrossAxisAlignment.start,
      children: [
        Text(
          'Reset Password',
          style: GoogleFonts.poppins(
            color: colors.onSurface,
            fontSize: 22,
            fontWeight: FontWeight.w700,
          ),
        ),

        const SizedBox(height: 8),

        Text(
          'Create a strong new password.',
          style: GoogleFonts.inter(
            color: colors.onSurfaceVariant,
            fontSize: 14,
          ),
        ),

        if (widget.viewModel.errorMessage != null) ...[
          const SizedBox(height: 16),
          _errorBanner(
            widget.viewModel.errorMessage!,
          ),
        ],

        const SizedBox(height: 24),

        // =====================================================
        // NEW PASSWORD
        // =====================================================

        _fieldLabel('New Password'),

        const SizedBox(height: 6),

        TextField(
          controller:
          _newPasswordController,
          obscureText: !_showNewPassword,
          onChanged: (_) => _clearError(),
          style: _inputTextStyle(),
          decoration: _inputDecoration(
            hintText: 'Min 8 characters',
            suffixIcon: TextButton(
              onPressed: () {
                setState(() {
                  _showNewPassword =
                  !_showNewPassword;
                });
              },
              child: Text(
                _showNewPassword
                    ? 'HIDE'
                    : 'SHOW',
                style: GoogleFonts.inter(
                  color: colors.onSurfaceVariant,
                  fontSize: 12,
                  fontWeight:
                  FontWeight.w600,
                ),
              ),
            ),
          ),
        ),

        const SizedBox(height: 16),

        // =====================================================
        // CONFIRM PASSWORD
        // =====================================================

        _fieldLabel('Confirm Password'),

        const SizedBox(height: 6),

        TextField(
          controller:
          _confirmPasswordController,
          obscureText:
          !_showConfirmPassword,
          onChanged: (_) => _clearError(),
          style: _inputTextStyle(),
          decoration: _inputDecoration(
            hintText: 'Repeat password',
            suffixIcon: TextButton(
              onPressed: () {
                setState(() {
                  _showConfirmPassword =
                  !_showConfirmPassword;
                });
              },
              child: Text(
                _showConfirmPassword
                    ? 'HIDE'
                    : 'SHOW',
                style: GoogleFonts.inter(
                  color: colors.onSurfaceVariant,
                  fontSize: 12,
                  fontWeight:
                  FontWeight.w600,
                ),
              ),
            ),
          ),
        ),

        const SizedBox(height: 24),

        _primaryButton(
          text: widget.viewModel.isLoading
              ? 'Updating...'
              : 'Update Password',
          onTap: widget.viewModel.isLoading
              ? null
              : _updatePassword,
        ),
      ],
    );
  }

  // =========================================================
  // STEP 4: SUCCESS
  // =========================================================

  Widget _successStep() {
    final colors = context.colors;
    final appColors = context.appColors;

    return Column(
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            color: appColors.successSurface,
            borderRadius:
            BorderRadius.circular(22),
          ),
          alignment: Alignment.center,
          child: Icon(
            Icons.check_circle_outline,
            color: appColors.success,
            size: 40,
          ),
        ),

        const SizedBox(height: 20),

        Text(
          'Password Updated',
          style: GoogleFonts.poppins(
            color: colors.onSurface,
            fontSize: 22,
            fontWeight: FontWeight.w700,
          ),
        ),

        const SizedBox(height: 8),

        Text(
          'Your password has been updated successfully. You can now log in with your new password.',
          textAlign: TextAlign.center,
          style: GoogleFonts.inter(
            color: colors.onSurfaceVariant,
            fontSize: 14,
            height: 1.5,
          ),
        ),

        const SizedBox(height: 24),

        _successBanner(
          'Password updated successfully!',
        ),

        const SizedBox(height: 24),

        _primaryButton(
          text: 'Back to Login',
          onTap: _backToLogin,
        ),
      ],
    );
  }

  // =========================================================
  // FIELD LABEL
  // =========================================================

  Widget _fieldLabel(String text) {
    return Text(
      text,
      style: GoogleFonts.inter(
        color: context.colors.onSurface,
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
    );
  }

  // =========================================================
  // INPUT TEXT STYLE
  // =========================================================

  TextStyle _inputTextStyle() {
    return GoogleFonts.inter(
      color: context.colors.onSurface,
      fontSize: 15,
    );
  }

  // =========================================================
  // INPUT DECORATION
  // =========================================================

  InputDecoration _inputDecoration({
    required String hintText,
    Widget? suffixIcon,
  }) {
    final colors = context.colors;

    return InputDecoration(
      hintText: hintText,
      hintStyle: GoogleFonts.inter(
        color: colors.onSurfaceVariant,
        fontSize: 15,
      ),
      suffixIcon: suffixIcon,
      filled: true,
      fillColor: colors.surfaceContainerHighest,
      contentPadding:
      const EdgeInsets.symmetric(
        horizontal: 16,
        vertical: 14,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius:
        BorderRadius.circular(14),
        borderSide: BorderSide(
          color: colors.outlineVariant,
          width: 1.5,
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius:
        BorderRadius.circular(14),
        borderSide: BorderSide(
          color: colors.primary,
          width: 1.5,
        ),
      ),
    );
  }

  // =========================================================
  // ERROR BANNER
  // =========================================================

  Widget _errorBanner(String message) {
    final colors = context.colors;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: 16,
        vertical: 14,
      ),
      decoration: BoxDecoration(
        color: colors.errorContainer,
        borderRadius:
        BorderRadius.circular(14),
        border: Border.all(
          color: colors.error.withValues(alpha: 0.4),
          width: 1.5,
        ),
      ),
      child: Row(
        crossAxisAlignment:
        CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.error_outline,
            color: colors.onErrorContainer,
            size: 20,
          ),

          const SizedBox(width: 10),

          Expanded(
            child: Text(
              message,
              style: GoogleFonts.inter(
                color: colors.onErrorContainer,
                fontSize: 14,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // =========================================================
  // SUCCESS BANNER
  // =========================================================

  Widget _successBanner(String message) {
    final appColors = context.appColors;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: 16,
        vertical: 14,
      ),
      decoration: BoxDecoration(
        color: appColors.successSurface,
        borderRadius:
        BorderRadius.circular(14),
        border: Border.all(
          color: appColors.success.withValues(alpha: 0.4),
          width: 1.5,
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.check_circle_outline,
            color: appColors.success,
            size: 20,
          ),

          const SizedBox(width: 10),

          Expanded(
            child: Text(
              message,
              style: GoogleFonts.inter(
                color: appColors.success,
                fontSize: 14,
                fontWeight:
                FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // =========================================================
  // PRIMARY BUTTON
  // =========================================================

  Widget _primaryButton({
    required String text,
    required VoidCallback? onTap,
  }) {
    final disabled = onTap == null;
    final colors = context.colors;
    final appColors = context.appColors;

    return Opacity(
      opacity: disabled ? 0.65 : 1,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          gradient: disabled
              ? null
              : LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: appColors.brandGradient,
          ),
          color: disabled
              ? colors.outline
              : null,
          borderRadius:
          BorderRadius.circular(16),
          boxShadow: disabled
              ? []
              : [
            BoxShadow(
              color: colors.primary.withValues(
                alpha: 0.35,
              ),
              blurRadius: 16,
              offset:
              const Offset(0, 4),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius:
            BorderRadius.circular(16),
            onTap: onTap,
            child: Padding(
              padding:
              const EdgeInsets.symmetric(
                vertical: 16,
              ),
              child: Center(
                child: Text(
                  text,
                  style: GoogleFonts.poppins(
                    color: colors.onPrimary,
                    fontSize: 15,
                    fontWeight:
                    FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
