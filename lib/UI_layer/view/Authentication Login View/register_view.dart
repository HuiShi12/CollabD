import 'package:flutter/material.dart';

import '../../../main.dart';
import '../../viewmodel/Authentication Login ViewModel/auth_viewmodel.dart';
import 'otp_verification_view.dart';
import 'widgets/auth_scaffold.dart';
import 'widgets/auth_widgets.dart';

class RegisterView extends StatefulWidget {
  final AuthenticationViewModel viewModel;

  const RegisterView({super.key, required this.viewModel});

  @override
  State<RegisterView> createState() => _RegisterViewState();
}

class _RegisterViewState extends State<RegisterView> {
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _birthdayController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final GlobalKey _errorKey = GlobalKey();

  DateTime? _dateOfBirth;
  bool _showPassword = false;
  bool _showConfirmPassword = false;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _birthdayController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _register() async {
    widget.viewModel.clearError();
    setState(() {});

    final success = await widget.viewModel.register(
      fullName: _nameController.text,
      email: _emailController.text,
      dateOfBirth: _dateOfBirth,
      password: _passwordController.text,
      confirmPassword: _confirmPasswordController.text,
    );

    if (!mounted) return;
    setState(() {});

    if (success) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => OtpVerificationView(
            viewModel: widget.viewModel,
            email: _emailController.text.trim(),
          ),
        ),
      );
    } else {
      _scrollToError();
    }
  }

  void _scrollToError() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      final errorContext = _errorKey.currentContext;
      if (errorContext == null) return;

      Scrollable.ensureVisible(
        errorContext,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeInOut,
        alignment: 0.15,
      );
    });
  }

  Future<void> _selectBirthday() async {
    widget.viewModel.clearError();
    final today = DateTime.now();

    final selectedDate = await showDatePicker(
      context: context,
      initialDate: _dateOfBirth ?? DateTime(2000, 1, 1),
      firstDate: DateTime(1900, 1, 1),
      lastDate: DateTime(today.year, today.month, today.day),
      helpText: 'Select Date of Birth',
    );

    if (selectedDate == null) return;

    setState(() {
      _dateOfBirth = selectedDate;
      _birthdayController.text =
      '${selectedDate.day.toString().padLeft(2, '0')}/'
          '${selectedDate.month.toString().padLeft(2, '0')}/'
          '${selectedDate.year}';
    });
  }

  void _clearError() {
    if (widget.viewModel.errorMessage != null) {
      widget.viewModel.clearError();
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Create Account',
      subtitle: 'Start your Malaysian adventure.',
      onBack: () => Navigator.maybePop(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Register', style: context.text.headlineSmall),
          AppSpacing.gapXs,
          Text(
            'It only takes a minute.',
            style: context.text.bodyMedium?.copyWith(
              color: context.colors.onSurfaceVariant,
            ),
          ),
          if (widget.viewModel.errorMessage != null) ...[
            AppSpacing.gapMd,
            KeyedSubtree(
              key: _errorKey,
              child: AuthErrorBanner(
                message: widget.viewModel.errorMessage!,
              ),
            ),
          ],
          AppSpacing.gapXl,
          AuthField(
            label: 'Full name',
            controller: _nameController,
            hintText: 'Your Name',
            keyboardType: TextInputType.name,
            onChanged: (_) => _clearError(),
          ),
          AppSpacing.gapLg,
          AuthField(
            label: 'Email',
            controller: _emailController,
            hintText: 'you@example.com',
            keyboardType: TextInputType.emailAddress,
            onChanged: (_) => _clearError(),
          ),
          AppSpacing.gapLg,
          GestureDetector(
            onTap: _selectBirthday,
            child: AbsorbPointer(
              child: AuthField(
                label: 'Date of birth',
                controller: _birthdayController,
                hintText: 'DD/MM/YYYY',
                suffix: const Icon(Icons.calendar_today_rounded, size: 18),
              ),
            ),
          ),
          AppSpacing.gapLg,
          AuthField(
            label: 'Password',
            controller: _passwordController,
            hintText: '••••••••',
            obscureText: !_showPassword,
            onChanged: (_) => _clearError(),
            suffix: TextButton(
              onPressed: () => setState(() => _showPassword = !_showPassword),
              child: Text(_showPassword ? 'HIDE' : 'SHOW'),
            ),
          ),
          AppSpacing.gapLg,
          AuthField(
            label: 'Confirm password',
            controller: _confirmPasswordController,
            hintText: '••••••••',
            obscureText: !_showConfirmPassword,
            onChanged: (_) => _clearError(),
            suffix: TextButton(
              onPressed: () => setState(
                    () => _showConfirmPassword = !_showConfirmPassword,
              ),
              child: Text(_showConfirmPassword ? 'HIDE' : 'SHOW'),
            ),
          ),
          AppSpacing.gapXl,
          AuthPrimaryButton(
            label: 'Create Account',
            loadingLabel: 'Creating…',
            loading: widget.viewModel.isLoading,
            onPressed: _register,
          ),
          AppSpacing.gapLg,
          Center(
            child: Text.rich(
              TextSpan(
                text: 'Already have an account? ',
                style: context.text.bodyMedium?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
                children: [
                  WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: GestureDetector(
                      onTap: () => Navigator.pop(context),
                      child: Text(
                        'Login',
                        style: context.text.bodyMedium?.copyWith(
                          color: context.colors.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
