import 'package:flutter/material.dart';

import '../../../main.dart';
import '../../viewmodel/Manage Profile ViewModel/profile_viewmodel.dart';
import 'widgets/profile_widgets.dart';

class ChangePasswordView extends StatefulWidget {
  final ManageProfileViewModel viewModel;

  const ChangePasswordView({
    super.key,
    required this.viewModel,
  });

  @override
  State<ChangePasswordView> createState() => _ChangePasswordViewState();
}

class _ChangePasswordViewState extends State<ChangePasswordView> {
  final _currentPasswordController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  bool _showCurrentPassword = false;
  bool _showNewPassword = false;
  bool _showConfirmPassword = false;

  String? _successMessage;

  @override
  void initState() {
    super.initState();
    widget.viewModel.clearError();
  }

  @override
  void dispose() {
    _currentPasswordController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _changePassword() async {
    widget.viewModel.clearError();
    setState(() => _successMessage = null);

    final success = await widget.viewModel.changePassword(
      currentPassword: _currentPasswordController.text,
      newPassword: _newPasswordController.text,
      confirmPassword: _confirmPasswordController.text,
    );

    if (!mounted) return;

    if (!success) {
      setState(() {});
      return;
    }

    _currentPasswordController.clear();
    _newPasswordController.clear();
    _confirmPasswordController.clear();

    setState(() {
      _showCurrentPassword = false;
      _showNewPassword = false;
      _showConfirmPassword = false;
      _successMessage = 'Password changed successfully.';
    });
  }

  void _clearMessage() {
    if (widget.viewModel.errorMessage != null) {
      widget.viewModel.clearError();
    }
    if (_successMessage != null) {
      setState(() => _successMessage = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final loading = widget.viewModel.isLoading;

    return ProfilePage(
      title: 'Change Password',
      canPop: !loading,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.sm,
          AppSpacing.lg,
          AppSpacing.xxl,
        ),
        child: Column(
          children: [
            Container(
              width: 76,
              height: 76,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: context.appColors.brandGradient,
                ),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.lock_outline_rounded,
                color: Colors.white,
                size: 34,
              ),
            ),
            AppSpacing.gapLg,
            Text('Update Your Password', style: context.text.titleLarge),
            AppSpacing.gapXs,
            Text(
              'Enter your current password and create a new secure password.',
              textAlign: TextAlign.center,
              style: context.text.bodyMedium?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
            AppSpacing.gapXl,
            ProfileCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.viewModel.errorMessage != null) ...[
                    ProfileBanner.error(widget.viewModel.errorMessage!),
                    AppSpacing.gapLg,
                  ],
                  if (_successMessage != null) ...[
                    ProfileBanner.success(_successMessage!),
                    AppSpacing.gapLg,
                  ],
                  _label(context, 'Current Password'),
                  AppSpacing.gapXs,
                  TextField(
                    controller: _currentPasswordController,
                    obscureText: !_showCurrentPassword,
                    enableSuggestions: false,
                    autocorrect: false,
                    onChanged: (_) => _clearMessage(),
                    decoration: InputDecoration(
                      hintText: 'Enter current password',
                      suffixIcon: _visibilityToggle(
                        visible: _showCurrentPassword,
                        onPressed: () => setState(
                          () => _showCurrentPassword = !_showCurrentPassword,
                        ),
                      ),
                    ),
                  ),
                  AppSpacing.gapLg,
                  _label(context, 'New Password'),
                  AppSpacing.gapXs,
                  TextField(
                    controller: _newPasswordController,
                    obscureText: !_showNewPassword,
                    enableSuggestions: false,
                    autocorrect: false,
                    onChanged: (_) => _clearMessage(),
                    decoration: InputDecoration(
                      hintText: 'Enter new password',
                      suffixIcon: _visibilityToggle(
                        visible: _showNewPassword,
                        onPressed: () => setState(
                          () => _showNewPassword = !_showNewPassword,
                        ),
                      ),
                    ),
                  ),
                  AppSpacing.gapSm,
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.info_outline_rounded,
                        color: context.colors.onSurfaceVariant,
                        size: 15,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'At least 8 characters with uppercase, lowercase, '
                          'number and special character.',
                          style: context.text.bodySmall?.copyWith(
                            color: context.colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                  AppSpacing.gapLg,
                  _label(context, 'Confirm New Password'),
                  AppSpacing.gapXs,
                  TextField(
                    controller: _confirmPasswordController,
                    obscureText: !_showConfirmPassword,
                    enableSuggestions: false,
                    autocorrect: false,
                    onChanged: (_) => _clearMessage(),
                    decoration: InputDecoration(
                      hintText: 'Confirm new password',
                      suffixIcon: _visibilityToggle(
                        visible: _showConfirmPassword,
                        onPressed: () => setState(
                          () => _showConfirmPassword = !_showConfirmPassword,
                        ),
                      ),
                    ),
                  ),
                  AppSpacing.gapXl,
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: FilledButton(
                      onPressed: loading ? null : _changePassword,
                      child: loading
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: Colors.white,
                              ),
                            )
                          : const Text('Change Password'),
                    ),
                  ),
                  AppSpacing.gapMd,
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: OutlinedButton(
                      onPressed:
                          loading ? null : () => Navigator.pop(context),
                      child: const Text('Cancel'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _label(BuildContext context, String text) {
    return Text(
      text,
      style: context.text.labelLarge?.copyWith(
        color: context.colors.onSurface,
      ),
    );
  }

  Widget _visibilityToggle({
    required bool visible,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      onPressed: onPressed,
      icon: Icon(
        visible ? Icons.visibility_off_outlined : Icons.visibility_outlined,
      ),
    );
  }
}
