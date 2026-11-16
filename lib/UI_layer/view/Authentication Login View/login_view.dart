import 'package:flutter/material.dart';

import '../../../main.dart';
import '../../viewmodel/Authentication Login ViewModel/auth_viewmodel.dart';
import 'widgets/auth_scaffold.dart';
import 'widgets/auth_widgets.dart';

class LoginView extends StatefulWidget {
  final AuthenticationViewModel viewModel;

  const LoginView({super.key, required this.viewModel});

  @override
  State<LoginView> createState() => _LoginViewState();
}

class _LoginViewState extends State<LoginView> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final GlobalKey _errorKey = GlobalKey();

  bool _showPassword = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    widget.viewModel.clearError();
    setState(() {});

    final success = await widget.viewModel.login(
      email: _emailController.text,
      password: _passwordController.text,
    );

    if (!mounted) return;
    setState(() {});

    if (success) {
      Navigator.pushNamedAndRemoveUntil(context, '/map', (route) => false);
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

  void _clearError() {
    if (widget.viewModel.errorMessage != null) {
      widget.viewModel.clearError();
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Mystery Malaysia',
      subtitle: 'Explore. Discover. Experience.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Welcome Back', style: context.text.headlineSmall),
          AppSpacing.gapXs,
          Text(
            'Sign in to continue your adventure.',
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
            label: 'Email',
            controller: _emailController,
            keyboardType: TextInputType.emailAddress,
            hintText: 'you@example.com',
            onChanged: (_) => _clearError(),
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
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () =>
                  Navigator.pushNamed(context, '/forgot-password'),
              child: const Text('Forgot Password?'),
            ),
          ),
          AppSpacing.gapSm,
          AuthPrimaryButton(
            label: 'Login',
            loadingLabel: 'Signing in…',
            loading: widget.viewModel.isLoading,
            onPressed: _login,
          ),
          AppSpacing.gapLg,
          Center(
            child: Text.rich(
              TextSpan(
                text: "Don't have an account? ",
                style: context.text.bodyMedium?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
                children: [
                  WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: GestureDetector(
                      onTap: () => Navigator.pushNamed(context, '/register'),
                      child: Text(
                        'Register',
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
